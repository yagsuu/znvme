//! Regen:
//!   zig run test/fixtures/identify/namespace_4kn_minimal_regen.zig \
//!     -- test/fixtures/identify/namespace_4kn_minimal.bin
//! Spec: docs/specs/identify/namespace.md.

const std = @import("std");
const nvme = @import("nvme");
const namespace = nvme.identify.namespace;

pub const IdentifyNamespace = namespace.IdentifyNamespace;

fn buildLbaf() [namespace.max_lba_formats]namespace.LbaFormat {
    var lbaf: [namespace.max_lba_formats]namespace.LbaFormat = @splat(@bitCast(@as(u32, 0)));
    lbaf[0] = .{
        .metadata_size = 0,
        .lba_data_size_shift = 12,
        .relative_performance = 0,
    };
    return lbaf;
}

pub const golden_init: IdentifyNamespace.Init = .{
    .nsze = 256,
    .ncap = 256,
    .nuse = 0,
    .nlbaf = 0,
    .flbas = 0,
    .lbaf = buildLbaf(),
};

pub fn compose() [namespace.size_bytes]u8 {
    var scratch: IdentifyNamespace = undefined;
    IdentifyNamespace.init(&scratch, golden_init);
    var out: [namespace.size_bytes]u8 = undefined;
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
