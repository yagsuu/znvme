//! Regen:
//!   zig run test/fixtures/identify/controller_minimal_regen.zig \
//!     -- test/fixtures/identify/controller_minimal.bin
//! Spec: docs/specs/identify/controller.md.

const std = @import("std");
const nvme = @import("nvme");
const controller = nvme.identify.controller;

pub const IdentifyController = controller.IdentifyController;

fn buildSubnqn() [256]u8 {
    var b: [256]u8 = @splat(0);
    const s = "nqn.2026-07.dev.znvme:znvme-mock";
    @memcpy(b[0..s.len], s);
    return b;
}

pub const golden_init: IdentifyController.Init = .{
    .vid = 0x1234,
    .cntrltype = .io,
    .sqes = .{ .required_shift = 6, .max_shift = 6 },
    .cqes = .{ .required_shift = 4, .max_shift = 4 },
    .nn = 1,
    .sn = "SN0000000000000001  ".*,
    .mn = "znvme-mock                              ".*,
    .fr = "1.0.0.0 ".*,
    .subnqn = buildSubnqn(),
};

pub fn compose() [controller.size_bytes]u8 {
    var scratch: IdentifyController = undefined;
    IdentifyController.init(&scratch, golden_init);
    var out: [controller.size_bytes]u8 = undefined;
    @memcpy(&out, std.mem.asBytes(&scratch));
    return out;
}

pub fn main(init: std.process.Init) !u8 {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next(); // exe
    const out_path = it.next() orelse {
        std.debug.print("usage: regen <out.bin>\n", .{});
        return 2;
    };
    const bytes = compose();
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = &bytes });
    return 0;
}
