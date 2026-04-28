const std = @import("std");

const log = @import("log.zig");

const Backend = enum {
    none,
    prometheus,
    telegraf,
};

pub const Metrics = union(Backend) {
    none: void,
    prometheus: Prometheus,
    telegraf: Telegraf,

    const Prometheus = struct {
        path: []const u8,
        ping_err: u32,
        recconnect_ok: u32,
        recconnect_err: u32,

        fn inc_ping(self: *@This(), success: bool) void {
            if (!success) {
                self.ping_err +|= 1;
            }
        }

        fn inc_reconnect(self: *@This(), success: bool) void {
            if (success) {
                self.recconnect_ok +|= 1;
            } else {
                self.recconnect_err +|= 1;
            }
        }

        fn flush(self: @This()) void {
            const Inner = struct {
                fn flush(outer: Prometheus) !void {
                    const file = try std.fs.cwd().createFile(outer.path, .{ .mode = 0o644 });
                    defer file.close();

                    var buffer: [4096]u8 = undefined;

                    var file_writer = file.writer(&buffer);
                    const writer = &file_writer.interface;

                    try writer.print("# HELP wifidog_ping_error_total Total number of pings that did not get a successful answer\n", .{});
                    try writer.print("# TYPE wifidog_ping_error_total counter\n", .{});
                    try writer.print("wifidog_ping_error_total {d}\n", .{outer.ping_err});
                    try writer.print("# HELP wifidog_reconnect_total Total number of reconnect attempetd by success\n", .{});
                    try writer.print("# TYPE wifidog_reconnect_total counter\n", .{});
                    try writer.print("wifidog_reconnect_total{{success=\"true\"}} {d}\n", .{outer.recconnect_ok});
                    try writer.print("wifidog_reconnect_total{{success=\"false\"}} {d}\n", .{outer.recconnect_err});
                    try writer.flush();
                }
            };

            Inner.flush(self) catch |e| {
                log.println("ERR: Failed to write metrics: {}", .{e});
            };
        }
    };

    const Telegraf = struct {
        const Tag = enum { ping_ok, ping_err, reconnect_ok, reconnect_err };

        path: std.posix.sockaddr.un,
        queue_tag: [16]Tag,
        queue_time: [16]i128,
        queue_len: u4,

        fn inc_ping(self: *@This(), success: bool) void {
            self.inc(if (success) Tag.ping_ok else Tag.ping_err);
        }

        fn inc_reconnect(self: *@This(), success: bool) void {
            self.inc(if (success) Tag.reconnect_ok else Tag.reconnect_err);
        }

        fn inc(self: *@This(), tag: Tag) void {
            self.queue_tag[self.queue_len] = tag;
            self.queue_time[self.queue_len] = std.time.nanoTimestamp();

            if (self.queue_len == 15) {
                self.flush();
                self.queue_len = 0;
            } else {
                self.queue_len += 1;
            }
        }

        fn flush(self: @This()) void {
            const Inner = struct {
                fn flush(outer: Telegraf) !void {
                    if (outer.queue_len == 0) return;

                    const sockfd = try std.posix.socket(
                        std.posix.AF.UNIX,
                        std.posix.SOCK.DGRAM,
                        0,
                    );
                    defer std.posix.close(sockfd);

                    var buffer: [1024]u8 = undefined;
                    var writer = std.io.Writer.fixed(&buffer);

                    for (outer.queue_tag[0..outer.queue_len], outer.queue_time[0..outer.queue_len]) |tag, time| {
                        const msg = switch (tag) {
                            .ping_ok => "operation=ping,status=ok value=1",
                            .ping_err => "operation=ping,status=fail value=1",
                            .reconnect_ok => "operation=reconnect,status=ok value=1",
                            .reconnect_err => "operation=reconnect,status=fail value=1",
                        };
                        try writer.print("wifidog,{s} {d}\n", .{ msg, time });
                    }
                    const payload = writer.buffered();

                    _ = try std.posix.sendto(
                        sockfd,
                        payload,
                        0,
                        @ptrCast(&outer.path),
                        @sizeOf(@TypeOf(outer.path)),
                    );
                }
            };

            Inner.flush(self) catch |e| {
                log.println("ERR: Failed to write metrics: {}", .{e});
            };
        }
    };

    const Self = @This();

    pub fn inc_ping(self: *Self, success: bool) void {
        switch (self.*) {
            .none => return,
            .prometheus => |*prom| prom.inc_ping(success),
            .telegraf => |*tg| tg.inc_ping(success),
        }
    }

    pub fn inc_reconnect(self: *Self, success: bool) void {
        switch (self.*) {
            .none => return,
            .prometheus => |*prom| prom.inc_reconnect(success),
            .telegraf => |*tg| tg.inc_reconnect(success),
        }
    }

    pub fn flush(self: Self) void {
        switch (self) {
            .none => return,
            .prometheus => |prom| prom.flush(),
            .telegraf => |tg| tg.flush(),
        }
    }
};

test "Metrics.none does nothing" {
    var metrics = Metrics{ .none = {} };
    metrics.inc_ping(false);
    metrics.inc_reconnect(true);
    metrics.flush();
}

test "Prometheus accumulates counters" {
    var prom = Metrics.Prometheus{
        .path = "/nonexistent/path/for/testing/test.prom",
        .ping_err = 0,
        .recconnect_ok = 0,
        .recconnect_err = 0,
    };

    prom.inc_ping(false);
    prom.inc_ping(false);
    prom.inc_ping(true);
    try std.testing.expectEqual(2, prom.ping_err);

    prom.inc_reconnect(true);
    prom.inc_reconnect(false);
    try std.testing.expectEqual(1, prom.recconnect_ok);
    try std.testing.expectEqual(1, prom.recconnect_err);
}

test "Telegraf queues events" {
    var tg = Metrics.Telegraf{
        .path = undefined,
        .queue_tag = undefined,
        .queue_time = undefined,
        .queue_len = 0,
    };

    tg.inc_ping(false);
    try std.testing.expectEqual(1, tg.queue_len);
    try std.testing.expectEqual(Metrics.Telegraf.Tag.ping_err, tg.queue_tag[0]);

    tg.inc_reconnect(true);
    try std.testing.expectEqual(2, tg.queue_len);
    try std.testing.expectEqual(Metrics.Telegraf.Tag.reconnect_ok, tg.queue_tag[1]);
}

test "Telegraf resets queue after reaching capacity" {
    var tg = Metrics.Telegraf{
        .path = undefined,
        .queue_tag = undefined,
        .queue_time = undefined,
        .queue_len = 0,
    };

    for (0..16) |_| {
        tg.inc_ping(true);
    }
    try std.testing.expectEqual(0, tg.queue_len);
}
