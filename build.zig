//! The Google Drive plugin for fizzy — a third-party plugin in the canonical shape: depend on
//! the fizzy SDK, call `fizzy.plugin.create` + `.install`. `zig build` produces
//! `drive.<dylib|dll|so>`; `zig build test` runs the Drive client and OAuth tests.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });
    fizzy.plugin.install(b, plugin.lib, .{});

    // The plugin module carries the tests that need `core` (the Drive client over a scripted
    // transport) and the pure ones (OAuth pieces) alike.
    const test_step = b.step("test", "Run the Drive client and OAuth tests");
    const tests = b.addTest(.{ .name = "drive-tests", .root_module = plugin.module });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
