const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    const bin_exe = b.addExecutable(.{
        .name = "wifidog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(bin_exe);

    const exe_cmd = b.addRunArtifact(bin_exe);
    const exe_step = b.step("run", "Run the app");
    exe_step.dependOn(&exe_cmd.step);

    exe_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        exe_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const test_exe = b.addTest(.{
        .root_module = bin_exe.root_module,
    });

    // A run step that will run the second test executable.
    const test_cmd = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_cmd.step);

    const check_exe = b.addExecutable(.{
        .name = "check",
        .root_module = bin_exe.root_module,
    });
    const check = b.step("check", "Check if it compiles");
    check.dependOn(&check_exe.step);
}
