const std = @import("std");

const Metrics = @import("metrics.zig").Metrics;
const log = @import("log.zig");

pub const Args = struct {
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

    pub fn help() void {
        log.println("Usage: wifidog -t TARGET_IP [OPTIONS] COMMAND [ARGS...]", .{});
        log.println("", .{});
        log.println("Monitor connectivity against a target and execute a specific command to recover the connection.", .{});
        log.println("", .{});
        log.println("Options:", .{});
        log.println("  -t TARGET_IP        (Required) The IP address of the target network or device.", .{});
        log.println("  -m METRICS_PATH     Metrics output path with format 'prometheus:/path/to/file' or 'telegraf:/path/to/socket'.", .{});
        log.println("  -a ATTEMPTS         Total number of attempts to wait for a response (default: 10).", .{});
        log.println("  -i INTERVAL         Ping sending interval in seconds (default: 1).", .{});
        log.println("  -s SUCCESS_BACKOFF  Time in seconds to wait after a successful check (default: 15).", .{});
        log.println("  -f FAIL_BACKOFF     Time in seconds to wait extra after a failed check (default: 30).", .{});
        log.println("  -e ERROR_BACKOFF    Time in minutes to wait after multiple failed checks (default: 5).", .{});
        log.println("  -h                  Print this help message.", .{});
        log.println("", .{});
        log.println("Arguments:", .{});
        log.println("  COMMAND             The command to execute for restoring the connection.", .{});
        log.println("  [ARGS...]           Optional arguments to pass to the command.", .{});
        log.println("", .{});
        log.println("Examples:", .{});
        log.println("  wifidog -t 192.168.1.1 wpa_cli reassociate", .{});
        log.println("  wifidog -m prometheus:/var/lib/node_exporter/wifidog.prom -t 10.0.0.1 reconnect", .{});
        log.println("  wifidog -m telegraf:/run/telegraf/wifidog.sock -t 10.0.0.1 reconnect", .{});
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

    pub fn parse(input: []const [*:0]const u8) Result(Self) {
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

    pub fn display(self: Self) void {
        log.println("Args (", .{});
        log.println("  target_ip: {f}", .{self.target_ip});
        log.println("  attempts: {d}", .{self.attempts});
        log.println("  interval: {d}s", .{self.interval});
        log.println("  backoff_success: {d}s", .{self.backoff_success});
        log.println("  backoff_fail: {d}s", .{self.backoff_fail});
        log.println("  backoff_error: {d}m", .{self.backoff_error});
        switch (self.metrics) {
            .none => {},
            .prometheus => |prom| log.println("  metrics: prometheus:'{s}'", .{prom.path}),
            .telegraf => |tg| log.println("  metrics: telegraf:'{s}'", .{std.mem.sliceTo(&tg.path.path, 0)}),
        }
        if (self.command.len > 0) {
            log.print("  command: '{s}", .{self.command[0]});
            for (self.command[1..]) |arg| {
                log.print(" {s}", .{arg});
            }
            log.println("'", .{});
        }
        log.println(")", .{});
    }
};

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
