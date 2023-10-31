const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "http-server",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    if (target.os_tag == std.Target.Os.Tag.linux) {
        // linux x86_64 openssl
        exe.addIncludePath(.{ .path = "deps/linux_deps/include" });
        exe.addLibraryPath(.{ .path = "deps/linux_deps/lib/openssl" });
    } else { // annoyingly target.os_tag is null for native so I can't check macos specifically
        // macos aarch64 openssl
        exe.addIncludePath(.{ .path = "/opt/homebrew/Cellar/openssl@3/3.1.4/include" });
        exe.addLibraryPath(.{ .path = "/opt/homebrew/Cellar/openssl@3/3.1.4/lib" });
    }

    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");

    const zig_cli_module = b.dependency("zig-cli", .{}).module("zig-cli");
    exe.addModule("zig-cli", zig_cli_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
