const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = std.builtin.OptimizeMode.ReleaseSafe });

    const exe = b.addExecutable(.{
        .name = "http-server",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption(bool, "production_build", target.result.os.tag == std.Target.Os.Tag.linux);
    exe.root_module.addOptions("config", options);

    if (target.result.os.tag == std.Target.Os.Tag.linux) {
        // linux x86_64 openssl
        exe.addIncludePath(.{ .path = "deps/linux_deps/include" });
        exe.addLibraryPath(.{ .path = "deps/linux_deps/lib/openssl" });
    } else { // annoyingly target.os_tag is null for native so I can't check macos specifically
        // macos aarch64 openssl
        exe.addIncludePath(.{ .path = "/opt/homebrew/Cellar/openssl@3/3.1.4/include" });
        exe.addLibraryPath(.{ .path = "/opt/homebrew/Cellar/openssl@3/3.1.4/lib" });
    }

    exe.linkLibC();
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");

    const zig_cli_module = b.dependency("zig-cli", .{ .target = target }).module("zig-cli");
    exe.root_module.addImport("zig-cli", zig_cli_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
