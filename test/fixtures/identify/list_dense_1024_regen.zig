//! Regen:
//!   zig run test/fixtures/identify/list_dense_1024_regen.zig \
//!     -- test/fixtures/identify/list_dense_1024.bin
//! Spec: docs/specs/identify/namespace.md.

const std = @import("std");
const nvme = @import("nvme");
const namespace = nvme.identify.namespace;
const ids = nvme.core.ids;

pub const List = namespace.List;

fn buildNsids() [namespace.List.max_entries]ids.Nsid {
    @setEvalBranchQuota(namespace.List.max_entries * 4);
    var arr: [namespace.List.max_entries]ids.Nsid = undefined;
    var i: usize = 0;
    while (i < namespace.List.max_entries) : (i += 1) {
        arr[i] = ids.Nsid.from(@as(u32, @intCast(i + 1)));
    }
    return arr;
}

const nsids_slice: [namespace.List.max_entries]ids.Nsid = buildNsids();

pub const golden_init: List.Init = .{
    .nsids = &nsids_slice,
};

pub fn compose() [namespace.size_bytes]u8 {
    var scratch: List = undefined;
    List.init(&scratch, golden_init);
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
