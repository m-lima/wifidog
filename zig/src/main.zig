const std = @import("std");

const log = @import("log.zig");
const network = @import("network.zig");
const Metrics = @import("metrics.zig").Metrics;
const Args = @import("args.zig").Args;

fn get_sleep(args: Args, failures: u8) u64 {
    return switch (failures) {
        0 => @as(u64, args.backoff_success) *| std.time.ns_per_s,
        1, 2, 3, 4 => (@as(u64, args.backoff_fail) * @as(u64, failures)) *| std.time.ns_per_s,
        else => @as(u64, args.backoff_error) *| std.time.ns_per_min,
    };
}

pub fn main() !void {
    var args = switch (Args.parse(std.os.argv)) {
        .ok => |a| a,
        .duplicated_option => |field| {
            log.println("ERR: Duplicated {s} option", .{field});
            log.println("", .{});
            Args.help();
            std.process.exit(1);
        },
        .missing_option => |field| {
            log.println("ERR: Missing {s} option", .{field});
            log.println("", .{});
            Args.help();
            std.process.exit(1);
        },
        .invalid_option => |field| {
            log.println("ERR: Invalid {s} option", .{field});
            log.println("", .{});
            Args.help();
            std.process.exit(1);
        },
    };

    log.println("Starting wifi watchdog", .{});
    args.display();

    args.metrics.flush();

    var failures: u8 = 0;

    while (true) {
        const attempts = try network.ping(&args);
        if (attempts < args.attempts) {
            failures = 0;
        } else {
            if (try network.reconnect(&args)) {
                failures +|= 1;
            } else {
                failures = std.math.maxInt(u8);
            }
        }
        args.metrics.flush();
        std.Thread.sleep(get_sleep(args, failures));
    }
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

test {
    std.testing.refAllDecls(@This());
}
