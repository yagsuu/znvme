//! Regen:
//!   zig run test/fixtures/commands/cqe_success_regen.zig \
//!     -- test/fixtures/commands/cqe_success.bin
//! Spec: docs/specs/commands/cqe.md.

const std = @import("std");
const nvme = @import("nvme");
const cqe = nvme.commands.cqe;

const CompletionStatus = nvme.core.status.CompletionStatus;

pub const Cqe = cqe.Cqe;

pub const golden_init: Cqe.Init = .{
    .cid = 0x0001,
    .sqid = 0x0000,
    .sqhd = 0x0002,
    .dw0 = 0,
    .dw1 = 0,
    .status = CompletionStatus.success(true).raw(),
};

pub fn compose() [cqe.size_bytes]u8 {
    var scratch: Cqe = undefined;
    Cqe.init(&scratch, golden_init);
    var out: [cqe.size_bytes]u8 = undefined;
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
