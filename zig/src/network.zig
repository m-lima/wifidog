const std = @import("std");
const builtin = @import("builtin");

const log = @import("log.zig");
const Args = @import("args.zig").Args;

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

pub fn ping(args: *Args) !u8 {
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
            log.println("ERR {d}: Failed to send: {}", .{ i, e });
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
            log.println("ERR {d}: Receive error: {}", .{ i, e });
            args.metrics.inc_ping(false);
            continue;
        };

        if (builtin.os.tag == .macos) {
            const ip_header_len = (recv_buf[0] & 0x0F) * 4;
            icmp_packet = recv_buf[ip_header_len..recv_len];
            if (checksum(icmp_packet) != 0) {
                log.println("ERR {d}: Checksum is not zero", .{i});
                args.metrics.inc_ping(false);
                continue;
            }
        } else {
            icmp_packet = recv_buf[0..recv_len];
        }

        if (icmp_packet.len < @sizeOf(IcmpHeader)) {
            log.println("ERR {d}: Bad length ({d} < {d})", .{ i, icmp_packet.len, @sizeOf(IcmpHeader) });
            args.metrics.inc_ping(false);
            continue;
        }

        const reply_type = icmp_packet[0];
        if (reply_type == ICMP_ECHOREPLY) {
            if (i > 0) {
                log.println("Ok {d}: Recovered connection", .{i});
            }
            args.metrics.inc_ping(true);
            return @intCast(i);
        }
    }

    return args.attempts;
}

pub fn reconnect(args: *Args) !bool {
    log.println("Reassociating", .{});

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
