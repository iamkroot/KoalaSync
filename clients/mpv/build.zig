const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Module ──────────────────────────────────────────────────
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("include"));
    mod.linkSystemLibrary("ssl", .{});
    mod.linkSystemLibrary("crypto", .{});

    // ── Shared library (mpv cplugin) ────────────────────────────
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "koalasync",
        .root_module = mod,
    });

    b.installArtifact(lib);

    // ── Convenience: install into mpv scripts dir ───────────────
    const install_step = b.step("install-mpv", "Copy plugin to ~/.config/mpv/scripts/");
    const install_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        "mkdir -p ~/.config/mpv/scripts && " ++
            "cp zig-out/lib/libkoalasync.so ~/.config/mpv/scripts/koalasync.so 2>/dev/null || " ++
            "cp zig-out/lib/libkoalasync.dylib ~/.config/mpv/scripts/koalasync.dylib 2>/dev/null || " ++
            "cp zig-out/lib/koalasync.dll ~/.config/mpv/scripts/koalasync.dll 2>/dev/null",
    });
    install_cmd.step.dependOn(b.getInstallStep());
    install_step.dependOn(&install_cmd.step);

    // ── Tests ───────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/socketio.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
