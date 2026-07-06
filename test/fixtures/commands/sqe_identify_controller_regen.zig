//! Regen:
//!   zig run test/fixtures/commands/sqe_identify_controller_regen.zig \
//!     -- test/fixtures/commands/sqe_identify_controller.bin
//! Spec: docs/specs/commands/sqe.md.

const std = @import("std");
const nvme = @import("nvme");
const sqe = nvme.commands.sqe;

pub const Sqe = sqe.Sqe;

pub const golden_init: Sqe.Init = .{
    .opcode = 0x06,
    .command_id = .from(0x0001),
    .namespace_id = .none,
    .data_pointers = .zero,
    .cdw10 = 0x0000_0001,
};

pub fn compose() [sqe.size_bytes]u8 {
    var scratch: Sqe = undefined;
    Sqe.init(&scratch, golden_init);
    var out: [sqe.size_bytes]u8 = undefined;
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
