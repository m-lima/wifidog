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

fn logCmd(cmd: []const [*:0]const u8) void {
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

fn calculateChecksum(data: []const u8) u16 {
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

fn ping(target_addr: std.net.Address) !bool {
    const ICMP_ECHO = 8;
    const ICMP_ECHOREPLY = 0;

    const sockfd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        std.posix.IPPROTO.ICMP,
    );
    defer std.posix.close(sockfd);

    const timeout = std.posix.timeval{
        .sec = 1,
        .usec = 0,
    };
    try std.posix.setsockopt(
        sockfd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    );

    var timer = try std.time.Timer.start();
    for (0..10) |i| {
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

        var packet = [_]u8{0} ** 8;
        @memcpy(packet[0..@sizeOf(IcmpHeader)], std.mem.asBytes(&header));

        if (builtin.os.tag == .macos) {
            header.checksum = std.mem.nativeToBig(u16, calculateChecksum(&packet));
            @memcpy(packet[0..@sizeOf(IcmpHeader)], std.mem.asBytes(&header));
        }

        const sent = std.posix.sendto(
            sockfd,
            &packet,
            0,
            &target_addr.any,
            target_addr.getOsSockLen(),
        ) catch |e| {
            logln("ERR: Failed to send: {}", .{e});
            continue;
        };

        if (sent != packet.len) {
            return false;
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
            logln("ERR: Receive error: {}", .{e});
            continue;
        };

        if (builtin.os.tag == .macos) {
            const ip_header_len = (recv_buf[0] & 0x0F) * 4;
            icmp_packet = recv_buf[ip_header_len..recv_len];
            if (calculateChecksum(icmp_packet) != 0) {
                logln("ERR: Checksum is not zero", .{});
                continue;
            }
        } else {
            icmp_packet = recv_buf[0..recv_len];
        }

        if (icmp_packet.len < @sizeOf(IcmpHeader)) {
            logln("ERR: Bad length ({d} < {d})", .{ icmp_packet.len, @sizeOf(IcmpHeader) });
            continue;
        }

        const reply_type = icmp_packet[0];
        if (reply_type == ICMP_ECHOREPLY) {
            return true;
        }
    }
    return false;
}

fn getSleep(failures: i8) u64 {
    return switch (failures) {
        0 => 15 * std.time.ns_per_s,
        1 => 30 * std.time.ns_per_s,
        2 => 60 * std.time.ns_per_s,
        3 => 90 * std.time.ns_per_s,
        4 => 2 * std.time.ns_per_min,
        else => 5 * std.time.ns_per_min,
    };
}

// fn reassociate(allocator: std.mem.Allocator, cmd: []const u8, args: []const []const u8) !bool {
fn reassociate() !bool {
    // logln("Reassociating", .{});
    //
    // var argv: std.ArrayList([]const u8) = .{};
    // defer argv.deinit(allocator);
    //
    // try argv.append(allocator, cmd);
    // for (args) |arg| {
    //     try argv.append(allocator, arg);
    // }
    //
    // var child = std.process.Child.init(argv.items, allocator);
    // child.stdout_behavior = .Ignore;
    // child.stderr_behavior = .Ignore;
    //
    // const term = child.spawnAndWait() catch |err| {
    //     log("Failed to call '", .{});
    //     logCmd(cmd, args);
    //     logln("': {}", .{err});
    //     return false;
    // };
    //
    // return switch (term) {
    //     .Exited => |code| code == 0,
    //     else => false,
    // };
    return false;
}

pub fn main() !void {
    if (std.os.argv.len < 2) {
        logln("Missing target IP", .{});
        std.process.exit(1);
    }

    if (std.os.argv.len < 3) {
        logln("Missing reassociate command", .{});
        std.process.exit(1);
    }

    const targetIP = std.os.argv[1];
    const reassociateCmd = std.os.argv[2..];

    const target_addr = std.net.Address.parseIp4(std.mem.span(targetIP), 0) catch {
        logln("Invalid IP address: {s}", .{targetIP});
        std.process.exit(1);
    };

    log("Starting wifi watchdog for '{s}' with '", .{targetIP});
    logCmd(reassociateCmd);
    logln("'", .{});

    var failures: i8 = 0;

    while (true) {
        if (try ping(target_addr)) {
            failures = 0;
        } else {
            // if (try reassociate(allocator, reassociateCmd, reassociateCmdArgs)) {
            if (try reassociate()) {
                if (failures < 5) {
                    failures += 1;
                }
            } else {
                failures = 5;
            }
        }
        std.Thread.sleep(getSleep(failures));
    }
}
