const std = @import("std");

pub fn print(
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    nosuspend stderr.print(format, args) catch return;
}

pub fn println(
    comptime format: []const u8,
    args: anytype,
) void {
    print(format ++ "\n", args);
}
