const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const host_target = b.standardTargetOptions(.{});

    const stdx_host = b.dependency("stdx", .{
        .target = host_target,
        .optimize = optimize,
    });

    // Public `nvme` module: the surface zfw consumes via @import("nvme").
    // znvme depends on stdx for domain-neutral primitives.
    const nvme_mod = b.addModule("nvme", .{
        .root_source_file = b.path("src/nvme.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "stdx", .module = stdx_host.module("stdx") }},
    });

    // Host-side unit tests: every module is byte-level and host-provable.
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("test/all.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nvme", .module = nvme_mod },
            .{ .name = "stdx", .module = stdx_host.module("stdx") },
        },
    });
    // Expose src/identify/controller.zig source bytes as an @import so the
    // barrier-audit test can grep them at comptime without reaching outside
    // the tests module's file tree.
    const audit_options = b.addOptions();
    const io = b.graph.io;
    const controller_src = b.build_root.handle.readFileAlloc(
        io,
        "src/identify/controller.zig",
        b.allocator,
        .unlimited,
    ) catch @panic("read controller.zig for audit fixture");
    audit_options.addOption([]const u8, "controller_source", controller_src);
    tests_mod.addImport("audit_sources", audit_options.createModule());
    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run host-side tests");
    test_step.dependOn(&run_tests.step);

    // Freestanding type-check: proves the wire-layout ABI assertions on a
    // non-host target on every build (docs/guidelines/conventions.md).
    const free_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const stdx_free = b.dependency("stdx", .{
        .target = free_target,
        .optimize = optimize,
    });
    const free_mod = b.createModule(.{
        .root_source_file = b.path("src/nvme.zig"),
        .target = free_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "stdx", .module = stdx_free.module("stdx") }},
    });
    const free_check = b.addObject(.{ .name = "znvme", .root_module = free_mod });
    const check_step = b.step("check", "Type-check the nvme module (x86_64-freestanding)");
    check_step.dependOn(&free_check.step);
}
