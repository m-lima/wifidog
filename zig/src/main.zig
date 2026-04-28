const std = @import("std");
const builtin = @import("builtin");

fn log(
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    nosuspend stderr.print(format, args) catch return;
}

fn logln(
    comptime format: []const u8,
    args: anytype,
) void {
    log(format ++ "\n", args);
}

fn log_cmd(cmd: []const [*:0]const u8) void {
    if (cmd.len > 0) {
        log("{s}", .{cmd[0]});
        for (cmd[1..]) |arg| {
            log(" {s}", .{arg});
        }
    }
}

const IcmpHeader = packed struct {
    type: u8,
    code: u8,
    checksum: u16,
    id: u16,
    sequence: u16,
};

fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i < data.len - 1) : (i += 2) {
        const word = @as(u32, data[i]) << 8 | @as(u32, data[i + 1]);
        sum += word;
    }

    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }

    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @truncate(~sum);
}

fn ping(args: Args) !u8 {
    const ICMP_ECHO = 8;
    const ICMP_ECHOREPLY = 0;

    const sockfd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        std.posix.IPPROTO.ICMP,
    );
    defer std.posix.close(sockfd);

    const timeout = std.posix.timeval{
        .sec = args.interval,
        .usec = 0,
    };
    try std.posix.setsockopt(
        sockfd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    );

    var timer = try std.time.Timer.start();
    for (0..args.attempts) |i| {
        if (i > 0) {
            const elapsed = timer.read();
            if (elapsed < std.time.ns_per_s) {
                std.Thread.sleep(std.time.ns_per_s - elapsed);
            }
            timer = try std.time.Timer.start();
        }

        var header = IcmpHeader{
            .type = ICMP_ECHO,
            .code = 0,
            .checksum = 0,
            .id = if (builtin.os.tag == .macos) std.mem.nativeToBig(u16, @truncate(@as(u32, @intCast(std.c.getpid())))) else 0,
            .sequence = std.mem.nativeToBig(u16, @intCast(i)),
        };

        var packet = [_]u8{0} ** @sizeOf(IcmpHeader);
        @memcpy(packet[0..@sizeOf(IcmpHeader)], std.mem.asBytes(&header));

        if (builtin.os.tag == .macos) {
            header.checksum = std.mem.nativeToBig(u16, checksum(&packet));
            @memcpy(packet[0..@sizeOf(IcmpHeader)], std.mem.asBytes(&header));
        }

        const sent = std.posix.sendto(
            sockfd,
            &packet,
            0,
            &args.target_ip.any,
            args.target_ip.getOsSockLen(),
        ) catch |e| {
            logln("ERR {d}: Failed to send: {}", .{ i, e });
            args.metrics.inc_ping(false);
            continue;
        };

        if (sent != packet.len) {
            args.metrics.inc_ping(false);
            continue;
        }

        var recv_buf: [256]u8 = undefined;
        var icmp_packet: []u8 = undefined;
        const recv_len = std.posix.recvfrom(
            sockfd,
            &recv_buf,
            0,
            null,
            null,
        ) catch |e| {
            logln("ERR {d}: Receive error: {}", .{ i, e });
            args.metrics.inc_ping(false);
            continue;
        };

        if (builtin.os.tag == .macos) {
            const ip_header_len = (recv_buf[0] & 0x0F) * 4;
            icmp_packet = recv_buf[ip_header_len..recv_len];
            if (checksum(icmp_packet) != 0) {
                logln("ERR {d}: Checksum is not zero", .{i});
                args.metrics.inc_ping(false);
                continue;
            }
        } else {
            icmp_packet = recv_buf[0..recv_len];
        }

        if (icmp_packet.len < @sizeOf(IcmpHeader)) {
            logln("ERR {d}: Bad length ({d} < {d})", .{ i, icmp_packet.len, @sizeOf(IcmpHeader) });
            args.metrics.inc_ping(false);
            continue;
        }

        const reply_type = icmp_packet[0];
        if (reply_type == ICMP_ECHOREPLY) {
            if (i > 0) {
                logln("Ok {d}: Recovered connection", .{i});
            }
            args.metrics.inc_ping(true);
            return @intCast(i);
        }
    }

    return args.attempts;
}

fn get_sleep(args: Args, failures: u8) u64 {
    return switch (failures) {
        0 => @as(u64, args.backoff_success) *| std.time.ns_per_s,
        1, 2, 3, 4 => (@as(u64, args.backoff_fail) * @as(u64, failures)) *| std.time.ns_per_s,
        else => @as(u64, args.backoff_error) *| std.time.ns_per_min,
    };
}

fn reconnect(args: Args) !bool {
    logln("Reassociating", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cmd = try allocator.alloc([]const u8, args.command.len);
    for (args.command, 0..) |arg, i| {
        cmd[i] = std.mem.span(arg);
    }

    var child = std.process.Child.init(cmd, allocator);
    const term = try child.spawnAndWait();
    const success = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    args.metrics.inc_reconnect(success);
    return success;
}

const MetricsBackend = enum {
    none,
    prometheus,
    telegraf,
};

const Metrics = union(MetricsBackend) {
    none: void,
    prometheus: PrometheusMetrics,
    telegraf: TelegrafMetrics,

    const PrometheusMetrics = struct {
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
                fn flush(outer: PrometheusMetrics) !void {
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
                logln("ERR: Failed to write metrics: {}", .{e});
            };
        }
    };

    const TelegrafMetrics = struct {
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
                fn flush(outer: TelegrafMetrics) !void {
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
                logln("ERR: Failed to write metrics: {}", .{e});
            };
        }
    };

    const Self = @This();

    fn inc_ping(self: *Self, success: bool) void {
        switch (self.*) {
            .none => return,
            .prometheus => |*prom| prom.inc_ping(success),
            .telegraf => |*tg| tg.inc_ping(success),
        }
    }

    fn inc_reconnect(self: *Self, success: bool) void {
        switch (self.*) {
            .none => return,
            .prometheus => |*prom| prom.inc_reconnect(success),
            .telegraf => |*tg| tg.inc_reconnect(success),
        }
    }

    fn flush(self: Self) void {
        switch (self) {
            .none => return,
            .prometheus => |prom| prom.flush(),
            .telegraf => |tg| tg.flush(),
        }
    }
};

const Args = struct {
    target_ip: std.net.Address,
    metrics: Metrics,
    attempts: u8,
    interval: u8,
    backoff_success: u8,
    backoff_fail: u8,
    backoff_error: u8,
    command: []const [*:0]const u8,

    const Self = @This();

    fn Result(comptime T: type) type {
        return union(enum) {
            ok: T,
            duplicated_option: []const u8,
            missing_option: []const u8,
            invalid_option: []const u8,

            pub fn propagate(self: @This(), comptime R: type) Result(R) {
                return switch (self) {
                    .ok => unreachable,
                    .duplicated_option => |field| .{ .duplicated_option = field },
                    .missing_option => |field| .{ .missing_option = field },
                    .invalid_option => |field| .{ .invalid_option = field },
                };
            }
        };
    }

    fn help() void {
        logln("Usage: wifidog -t TARGET_IP [OPTIONS] COMMAND [ARGS...]", .{});
        logln("", .{});
        logln("Monitor connectivity against a target and execute a specific command to recover the connection.", .{});
        logln("", .{});
        logln("Options:", .{});
        logln("  -t TARGET_IP        (Required) The IP address of the target network or device.", .{});
        logln("  -m METRICS_PATH     Metrics output path with format 'prometheus:/path/to/file' or 'telegraf:/path/to/socket'.", .{});
        logln("  -a ATTEMPTS         Total number of attempts to wait for a response (default: 10).", .{});
        logln("  -i INTERVAL         Ping sending interval in seconds (default: 1).", .{});
        logln("  -s SUCCESS_BACKOFF  Time in seconds to wait after a successful check (default: 15).", .{});
        logln("  -f FAIL_BACKOFF     Time in seconds to wait extra after a failed check (default: 30).", .{});
        logln("  -e ERROR_BACKOFF    Time in minutes to wait after multiple failed checks (default: 5).", .{});
        logln("  -h                  Print this help message.", .{});
        logln("", .{});
        logln("Arguments:", .{});
        logln("  COMMAND             The command to execute for restoring the connection.", .{});
        logln("  [ARGS...]           Optional arguments to pass to the command.", .{});
        logln("", .{});
        logln("Examples:", .{});
        logln("  wifidog -t 192.168.1.1 wpa_cli reassociate", .{});
        logln("  wifidog -m prometheus:/var/lib/node_exporter/wifidog.prom -t 10.0.0.1 reconnect", .{});
        logln("  wifidog -m telegraf:/run/telegraf/wifidog.sock -t 10.0.0.1 reconnect", .{});
    }

    const Parse = struct {
        fn string(comptime name: []const u8, input: []const [*:0]const u8, target: *[]const u8) Result(void) {
            if (target.len > 0) {
                return .{ .duplicated_option = name };
            }
            if (input.len < 2) {
                return .{ .missing_option = name };
            }
            target.* = std.mem.span(input[1]);
            if (target.len == 0) {
                return .{ .missing_option = name };
            }
            return .{ .ok = {} };
        }

        fn int(comptime name: []const u8, input: []const [*:0]const u8, target: *u8) Result(void) {
            if (target.* != 0) {
                return .{ .duplicated_option = name };
            }
            if (input.len < 2) {
                return .{ .missing_option = name };
            }
            target.* = std.fmt.parseInt(u8, std.mem.span(input[1]), 10) catch {
                return .{ .invalid_option = name };
            };
            if (target.* == 0) {
                return .{ .invalid_option = name };
            }
            return .{ .ok = {} };
        }
    };

    fn parse(input: []const [*:0]const u8) Result(Self) {
        var args = Self{
            .target_ip = undefined,
            .metrics = .none,
            .attempts = 0,
            .interval = 0,
            .backoff_success = 0,
            .backoff_fail = 0,
            .backoff_error = 0,
            .command = &.{},
        };
        var target_ip: []const u8 = &.{};
        var metrics: []const u8 = &.{};

        var i: usize = 1;
        while (i < input.len) {
            if (input[i][0] == '-') {
                switch (input[i][1]) {
                    't' => {
                        const result = Parse.string("TARGET_IP", input[i..], &target_ip);
                        if (result != .ok) return result.propagate(Self);
                        i += 1;
                    },
                    'm' => {
                        const result = Parse.string("METRICS_PATH", input[i..], &metrics);
                        if (result != .ok) return result.propagate(Self);
                        i += 1;
                    },
                    'a' => {
                        const result = Parse.int("ATTEMPTS", input[i..], &args.attempts);
                        if (result != .ok) return result.propagate(Self);
                        i += 1;
                    },
                    'i' => {
                        const result = Parse.int("INTERVAL", input[i..], &args.interval);
                        if (result != .ok) return result.propagate(Self);
                        i += 1;
                    },
                    's' => {
                        const result = Parse.int("SUCCESS_BACKOFF", input[i..], &args.backoff_success);
                        if (result != .ok) return result.propagate(Self);
                        i += 1;
                    },
                    'f' => {
                        const result = Parse.int("FAIL_BACKOFF", input[i..], &args.backoff_fail);
                        if (result != .ok) return result.propagate(Self);
                        i += 1;
                    },
                    'e' => {
                        const result = Parse.int("ERROR_BACKOFF", input[i..], &args.backoff_error);
                        if (result != .ok) return result.propagate(Self);
                        i += 1;
                    },
                    'h' => {
                        help();
                        std.process.exit(0);
                    },
                    else => {
                        return .{ .invalid_option = "unknown flag" };
                    },
                }
            } else {
                break;
            }
            i += 1;
        }

        args.command = input[i..];

        if (target_ip.len == 0) {
            return .{ .missing_option = "TARGET_IP" };
        }

        args.target_ip = std.net.Address.parseIp4(target_ip, 0) catch {
            return .{ .invalid_option = "TARGET_IP" };
        };

        if (metrics.len > 0) {
            const prometheus_prefix = "prometheus:";
            const telegraf_prefix = "telegraf:";

            if (std.mem.startsWith(u8, metrics, prometheus_prefix)) {
                const path = metrics[prometheus_prefix.len..];
                if (path.len == 0) {
                    return .{ .invalid_option = "METRICS_PATH (path cannot be empty)" };
                }
                if (path[path.len - 1] == '/') {
                    return .{ .invalid_option = "METRICS_PATH (path cannot end with '/')" };
                }
                args.metrics = Metrics{
                    .prometheus = .{
                        .path = path,
                        .ping_err = 0,
                        .recconnect_ok = 0,
                        .recconnect_err = 0,
                    },
                };
            } else if (std.mem.startsWith(u8, metrics, telegraf_prefix)) {
                const path = metrics[telegraf_prefix.len..];
                if (path.len == 0) {
                    return .{ .invalid_option = "METRICS_PATH (path cannot be empty)" };
                }
                if (path[path.len - 1] == '/') {
                    return .{ .invalid_option = "METRICS_PATH (path cannot end with '/')" };
                }

                var addr = std.posix.sockaddr.un{
                    .family = std.posix.AF.UNIX,
                    .path = undefined,
                };

                if (path.len >= addr.path.len) {
                    return .{ .invalid_option = "METRICS_PATH (unix socket path too long)" };
                }

                @memset(&addr.path, 0);
                @memcpy(addr.path[0..path.len], path);

                args.metrics = Metrics{
                    .telegraf = .{
                        .path = addr,
                        .queue_tag = undefined,
                        .queue_time = undefined,
                        .queue_len = 0,
                    },
                };
            } else {
                return .{ .invalid_option = "METRICS_PATH (must start with 'prometheus:' or 'telegraf:')" };
            }
        }

        if (args.attempts == 0) {
            args.attempts = 10;
        }

        if (args.interval == 0) {
            args.interval = 1;
        }

        if (args.backoff_success == 0) {
            args.backoff_success = 15;
        }

        if (args.backoff_fail == 0) {
            args.backoff_fail = 30;
        }

        if (args.backoff_error == 0) {
            args.backoff_error = 5;
        }

        if (args.command.len == 0) {
            return .{ .missing_option = "COMMAND" };
        }

        return .{ .ok = args };
    }

    fn display(self: Self) void {
        logln("Args (", .{});
        logln("  target_ip: {f}", .{self.target_ip});
        logln("  attempts: {d}", .{self.attempts});
        logln("  interval: {d}s", .{self.interval});
        logln("  backoff_success: {d}s", .{self.backoff_success});
        logln("  backoff_fail: {d}s", .{self.backoff_fail});
        logln("  backoff_error: {d}m", .{self.backoff_error});
        if (self.metrics) |metrics| {
            logln("  metrics: '{s}'", .{metrics.path});
        }
        if (self.command.len > 0) {
            log("  command: '{s}", .{self.command[0]});
            for (self.command[1..]) |arg| {
                log(" {s}", .{arg});
            }
            logln("'", .{});
        }
        logln(")", .{});
    }
};

pub fn main() !void {
    var args = switch (Args.parse(std.os.argv)) {
        .ok => |a| a,
        .duplicated_option => |field| {
            logln("ERR: Duplicated {s} option", .{field});
            logln("", .{});
            Args.help();
            std.process.exit(1);
        },
        .missing_option => |field| {
            logln("ERR: Missing {s} option", .{field});
            logln("", .{});
            Args.help();
            std.process.exit(1);
        },
        .invalid_option => |field| {
            logln("ERR: Invalid {s} option", .{field});
            logln("", .{});
            Args.help();
            std.process.exit(1);
        },
    };

    logln("Starting wifi watchdog", .{});
    args.display();

    if (args.metrics) |metrics| {
        metrics.emit();
    }

    var failures: u8 = 0;

    while (true) {
        const attempts = try ping(args);
        if (attempts < args.attempts) {
            failures = 0;
        } else {
            if (try reconnect(args)) {
                failures +|= 1;
            } else {
                failures = std.math.maxInt(u8);
            }
        }
        args.metrics.flush();
        std.Thread.sleep(get_sleep(args, failures));
    }
}

test "Args.parse with minimal arguments" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "wpa_cli",
        "reassociate",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .ok);
    const args = result.ok;

    try std.testing.expectEqual(10, args.attempts);
    try std.testing.expectEqual(1, args.interval);
    try std.testing.expectEqual(15, args.backoff_success);
    try std.testing.expectEqual(30, args.backoff_fail);
    try std.testing.expectEqual(5, args.backoff_error);
    try std.testing.expect(args.metrics == .none);
    try std.testing.expectEqual(2, args.command.len);
    try std.testing.expectEqualStrings("wpa_cli", std.mem.span(args.command[0]));
    try std.testing.expectEqualStrings("reassociate", std.mem.span(args.command[1]));

    const expected_ip = try std.net.Address.parseIp4("192.168.1.1", 0);
    try std.testing.expectEqual(expected_ip.in.sa.addr, args.target_ip.in.sa.addr);
}

test "Args.parse with all options" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "10.0.0.1",
        "-m",
        "prometheus:/tmp/metrics.prom",
        "-a",
        "5",
        "-i",
        "2",
        "-s",
        "20",
        "-f",
        "40",
        "-e",
        "10",
        "reconnect",
        "arg1",
        "arg2",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .ok);
    const args = result.ok;

    try std.testing.expectEqual(5, args.attempts);
    try std.testing.expectEqual(2, args.interval);
    try std.testing.expectEqual(20, args.backoff_success);
    try std.testing.expectEqual(40, args.backoff_fail);
    try std.testing.expectEqual(10, args.backoff_error);
    try std.testing.expect(args.metrics == .prometheus);
    try std.testing.expectEqualStrings("/tmp/metrics.prom", args.metrics.prometheus.path);
    try std.testing.expectEqual(3, args.command.len);
    try std.testing.expectEqualStrings("reconnect", std.mem.span(args.command[0]));
    try std.testing.expectEqualStrings("arg1", std.mem.span(args.command[1]));
    try std.testing.expectEqualStrings("arg2", std.mem.span(args.command[2]));
}

test "Args.parse with command that has flags" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "8.8.8.8",
        "sh",
        "-c",
        "echo test",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .ok);
    const args = result.ok;

    try std.testing.expectEqual(3, args.command.len);
    try std.testing.expectEqualStrings("sh", std.mem.span(args.command[0]));
    try std.testing.expectEqualStrings("-c", std.mem.span(args.command[1]));
    try std.testing.expectEqualStrings("echo test", std.mem.span(args.command[2]));
}

test "Args.parse errors on missing target IP" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .missing_option);
    try std.testing.expectEqualStrings("TARGET_IP", result.missing_option);
}

test "Args.parse errors on missing command" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .missing_option);
    try std.testing.expectEqualStrings("COMMAND", result.missing_option);
}

test "Args.parse errors on invalid IP address" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "not.an.ip",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .invalid_option);
    try std.testing.expectEqualStrings("TARGET_IP", result.invalid_option);
}

test "Args.parse errors on duplicated target IP" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-t",
        "10.0.0.1",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .duplicated_option);
    try std.testing.expectEqualStrings("TARGET_IP", result.duplicated_option);
}

test "Args.parse errors on duplicated attempts" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-a",
        "5",
        "-a",
        "10",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .duplicated_option);
    try std.testing.expectEqualStrings("ATTEMPTS", result.duplicated_option);
}

test "Args.parse errors on invalid attempts value" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-a",
        "not_a_number",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .invalid_option);
    try std.testing.expectEqualStrings("ATTEMPTS", result.invalid_option);
}

test "Args.parse errors on zero attempts value" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-a",
        "0",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .invalid_option);
    try std.testing.expectEqualStrings("ATTEMPTS", result.invalid_option);
}

test "Args.parse errors on unknown option" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-z",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .invalid_option);
    try std.testing.expectEqualStrings("unknown flag", result.invalid_option);
}

test "Args.parse errors on missing option value" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .missing_option);
    try std.testing.expectEqualStrings("TARGET_IP", result.missing_option);
}

test "get_sleep returns correct values" {
    const args = Args{
        .target_ip = try std.net.Address.parseIp4("127.0.0.1", 0),
        .metrics = .none,
        .attempts = 10,
        .interval = 1,
        .backoff_success = 15,
        .backoff_fail = 30,
        .backoff_error = 5,
        .command = &.{},
    };

    try std.testing.expectEqual(15 * std.time.ns_per_s, get_sleep(args, 0));
    try std.testing.expectEqual(30 * 1 * std.time.ns_per_s, get_sleep(args, 1));
    try std.testing.expectEqual(30 * 2 * std.time.ns_per_s, get_sleep(args, 2));
    try std.testing.expectEqual(30 * 3 * std.time.ns_per_s, get_sleep(args, 3));
    try std.testing.expectEqual(30 * 4 * std.time.ns_per_s, get_sleep(args, 4));
    try std.testing.expectEqual(5 * std.time.ns_per_min, get_sleep(args, 5));
    try std.testing.expectEqual(5 * std.time.ns_per_min, get_sleep(args, 100));
}

test "checksum calculates correctly" {
    const data1 = [_]u8{ 0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01 };
    const csum = checksum(&data1);
    try std.testing.expect(csum != 0);

    var data2 = [_]u8{ 0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01 };
    const csum2 = checksum(&data2);
    const csum_bytes = std.mem.toBytes(std.mem.nativeToBig(u16, csum2));
    data2[2] = csum_bytes[0];
    data2[3] = csum_bytes[1];
    try std.testing.expectEqual(0, checksum(&data2));
}

test "IcmpHeader has correct size" {
    try std.testing.expectEqual(8, @sizeOf(IcmpHeader));
}

test "Metrics.none does nothing" {
    var metrics = Metrics{ .none = {} };
    metrics.inc_ping(false);
    metrics.inc_reconnect(true);
    metrics.flush();
}

test "PrometheusMetrics accumulates counters" {
    var prom = Metrics.PrometheusMetrics{
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

test "TelegrafMetrics queues events" {
    var tg = Metrics.TelegrafMetrics{
        .path = undefined,
        .queue_tag = undefined,
        .queue_time = undefined,
        .queue_len = 0,
    };

    tg.inc_ping(false);
    try std.testing.expectEqual(1, tg.queue_len);
    try std.testing.expectEqual(Metrics.TelegrafMetrics.Tag.ping_err, tg.queue_tag[0]);

    tg.inc_reconnect(true);
    try std.testing.expectEqual(2, tg.queue_len);
    try std.testing.expectEqual(Metrics.TelegrafMetrics.Tag.reconnect_ok, tg.queue_tag[1]);
}

test "TelegrafMetrics resets queue after reaching capacity" {
    var tg = Metrics.TelegrafMetrics{
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

test "Args.parse with prometheus metrics" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-m",
        "prometheus:/tmp/metrics.prom",
        "wpa_cli",
        "reassociate",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .ok);
    const args = result.ok;

    try std.testing.expect(args.metrics == .prometheus);
    try std.testing.expectEqualStrings("/tmp/metrics.prom", args.metrics.prometheus.path);
    try std.testing.expectEqual(0, args.metrics.prometheus.ping_err);
    try std.testing.expectEqual(0, args.metrics.prometheus.recconnect_ok);
    try std.testing.expectEqual(0, args.metrics.prometheus.recconnect_err);
}

test "Args.parse with telegraf metrics" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-m",
        "telegraf:/run/telegraf/wifidog.sock",
        "wpa_cli",
        "reassociate",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .ok);
    const args = result.ok;

    try std.testing.expect(args.metrics == .telegraf);
    try std.testing.expectEqual(0, args.metrics.telegraf.queue_len);
}

test "Args.parse with no metrics defaults to none" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "wpa_cli",
        "reassociate",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .ok);
    const args = result.ok;

    try std.testing.expect(args.metrics == .none);
}

test "Args.parse errors on empty prometheus path" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-m",
        "prometheus:",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .invalid_option);
}

test "Args.parse errors on empty telegraf path" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-m",
        "telegraf:",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .invalid_option);
}

test "Args.parse errors on prometheus path ending with slash" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-m",
        "prometheus:/tmp/",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .invalid_option);
}

test "Args.parse errors on telegraf path ending with slash" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-m",
        "telegraf:/tmp/",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .invalid_option);
}

test "Args.parse errors on missing metrics prefix" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-m",
        "/tmp/metrics.prom",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .invalid_option);
}

test "Args.parse errors on invalid metrics prefix" {
    const argv = [_][*:0]const u8{
        "wifidog",
        "-t",
        "192.168.1.1",
        "-m",
        "influx:/tmp/metrics",
        "command",
    };

    const result = Args.parse(&argv);
    try std.testing.expect(result == .invalid_option);
}
