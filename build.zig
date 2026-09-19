const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zig_drive", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .name = "zig_drive-tests",
        .root_module = mod,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    addWasmCheck(b);
}

/// `zig build check-wasm` — compile and link for wasm32-freestanding. The
/// regular `-Dtarget=` build only produces a module, so it cannot catch an
/// unresolved libc / std.http symbol; this can.
fn addWasmCheck(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_check.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        .single_threaded = true,
    });

    const exe = b.addExecutable(.{
        .name = "zig_drive-wasm-check",
        .root_module = mod,
    });
    exe.entry = .disabled;
    exe.root_module.export_symbol_names = &.{"zig_drive_wasm_check"};

    b.step("check-wasm", "Compile and link for wasm32-freestanding").dependOn(&exe.step);
}
