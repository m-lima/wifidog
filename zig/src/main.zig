const std = @import("std");
const builtin = @import("builtin");

const Metrics = struct {
    path: [*:0]const u8,
    failures: u64,
    reassociations: u64,
};

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

fn ping(args: Args) !bool {
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
            logln("ERR {d}: Receive error: {}", .{ i, e });
            continue;
        };

        if (builtin.os.tag == .macos) {
            const ip_header_len = (recv_buf[0] & 0x0F) * 4;
            icmp_packet = recv_buf[ip_header_len..recv_len];
            if (checksum(icmp_packet) != 0) {
                logln("ERR {d}: Checksum is not zero", .{i});
                continue;
            }
        } else {
            icmp_packet = recv_buf[0..recv_len];
        }

        if (icmp_packet.len < @sizeOf(IcmpHeader)) {
            logln("ERR {d}: Bad length ({d} < {d})", .{ i, icmp_packet.len, @sizeOf(IcmpHeader) });
            continue;
        }

        const reply_type = icmp_packet[0];
        if (reply_type == ICMP_ECHOREPLY) {
            if (i > 0) {
                logln("Ok {d}: Recovered connection", .{i});
            }
            return true;
        }
    }
    return false;
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
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

const Args = struct {
    target_ip: std.net.Address,
    metrics: []const u8,
    attempts: u8,
    interval: u8,
    backoff_success: u8,
    backoff_fail: u8,
    backoff_error: u8,
    command: []const [*:0]const u8,

    const Self = @This();

    fn help() void {
        logln("Usage: wifidog -t TARGET_IP [OPTIONS] COMMAND [ARGS...]", .{});
        logln("", .{});
        logln("Monitor connectivity against a target and execute a specific command to recover the connection.", .{});
        logln("", .{});
        logln("Options:", .{});
        logln("  -t TARGET_IP        (Required) The IP address of the target network or device.", .{});
        logln("  -m METRICS_FILE     Path to the file where metrics will be saved.", .{});
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
        logln("  wifidog -m output.prom -t 10.0.0.1 -i 10 reconnect", .{});
    }

    const Parse = struct {
        fn string(comptime name: []const u8, input: []const [*:0]const u8, target: *[]const u8) void {
            if (target.len > 0) {
                fatal("Duplicated " ++ name ++ " options", .{});
            }
            if (input.len < 2) {
                fatal("Missing " ++ name ++ " option", .{});
            }
            target.* = std.mem.span(input[1]);
            if (target.len == 0) {
                fatal("Missing " ++ name ++ " option", .{});
            }
        }

        fn int(comptime name: []const u8, input: []const [*:0]const u8, target: *u8) void {
            if (target.* != 0) {
                fatal("Duplicated " ++ name ++ " options", .{});
            }
            if (input.len < 2) {
                fatal("Missing " ++ name ++ " option", .{});
            }
            target.* = std.fmt.parseInt(u8, std.mem.span(input[1]), 10) catch |e| {
                fatal("Invalid " ++ name ++ " option: {}", .{e});
            };
            if (target.* == 0) {
                fatal("Invalid " ++ name ++ " option: must be greater than zero", .{});
            }
        }

        fn fatal(comptime msg: []const u8, args: anytype) noreturn {
            logln("ERR: " ++ msg, args);
            logln("", .{});
            help();
            std.process.exit(1);
        }
    };

    fn parse(input: []const [*:0]const u8) Self {
        var args = Self{
            .target_ip = undefined,
            .metrics = &.{},
            .attempts = 0,
            .interval = 0,
            .backoff_success = 0,
            .backoff_fail = 0,
            .backoff_error = 0,
            .command = &.{},
        };
        var target: []const u8 = &.{};

        var i: usize = 1;
        while (i < input.len) {
            if (input[i][0] == '-') {
                switch (input[i][1]) {
                    't' => {
                        Parse.string("TARGET_IP", input[i..], &target);
                        i += 1;
                    },
                    'm' => {
                        Parse.string("METRICS_FILE", input[i..], &args.metrics);
                        i += 1;
                    },
                    'a' => {
                        Parse.int("ATTEMPTS", input[i..], &args.attempts);
                        i += 1;
                    },
                    'i' => {
                        Parse.int("INTERVAL", input[i..], &args.interval);
                        i += 1;
                    },
                    's' => {
                        Parse.int("SUCCESS_BACKOFF", input[i..], &args.backoff_success);
                        i += 1;
                    },
                    'f' => {
                        Parse.int("FAIL_BACKOFF", input[i..], &args.backoff_fail);
                        i += 1;
                    },
                    'e' => {
                        Parse.int("ERROR_BACKOFF", input[i..], &args.backoff_error);
                        i += 1;
                    },
                    'h' => {
                        help();
                        std.process.exit(0);
                    },
                    else => {
                        Parse.fatal("Invalid option", .{});
                    },
                }
            } else {
                break;
            }
            i += 1;
        }

        args.command = input[i..];

        if (target.len == 0) {
            Parse.fatal("Missing TARGET_IP option", .{});
        }

        args.target_ip = std.net.Address.parseIp4(target, 0) catch |e| {
            Parse.fatal("Invalid IP address '{s}': {}", .{ target, e });
        };

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
            Parse.fatal("Missing COMMAND option", .{});
        }

        return args;
    }

    fn display(self: Self) void {
        logln("Args (", .{});
        logln("  target_ip: {f}", .{self.target_ip});
        logln("  attempts: {d}", .{self.attempts});
        logln("  interval: {d}s", .{self.interval});
        logln("  backoff_success: {d}s", .{self.backoff_success});
        logln("  backoff_fail: {d}s", .{self.backoff_fail});
        logln("  backoff_error: {d}m", .{self.backoff_error});
        if (self.metrics.len > 0) {
            logln("  metrics: '{s}'", .{self.metrics});
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
    const args = Args.parse(std.os.argv);

    logln("Starting wifi watchdog", .{});
    args.display();

    var failures: u8 = 0;

    while (true) {
        if (try ping(args)) {
            failures = 0;
        } else {
            if (try reconnect(args)) {
                failures +|= 1;
            } else {
                failures = std.math.maxInt(u8);
            }
        }
        std.Thread.sleep(get_sleep(args, failures));
    }
}
