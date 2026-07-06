//! Host-side tests for core doorbells. Spec: docs/specs/core/doorbell.md.

const std = @import("std");

const nvme = @import("nvme");

const testing = std.testing;

const ids = nvme.core.ids;
const registers = nvme.core.registers;
const doorbell = nvme.core.doorbell;

const Qid = ids.Qid;
const Stride = doorbell.Stride;
const Value = doorbell.Value;
const Doorbells = doorbell.Doorbells;

fn zeroedCap(dstrd: u4) registers.Cap {
    return .{
        .mqes = 0,
        .cqr = 0,
        .ams = 0,
        .to = 0,
        .dstrd = dstrd,
        .nssrs = 0,
        .css = 0x01,
        .bps = 0,
        .cps = 0,
        .mpsmin = 0,
        .mpsmax = 0,
        .pmrs = 0,
        .cmbs = 0,
        .nsss = 0,
        .crms = 0,
    };
}

test "unit: doorbell stride expands CAP DSTRD" {
    // Goal: Stride.fromDstrd matches NVMe formula 4 << DSTRD for the boundary DSTRD values.
    try testing.expectEqual(@as(usize, 4), Stride.fromDstrd(0).bytes);
    try testing.expectEqual(@as(usize, 16), Stride.fromDstrd(2).bytes);
    try testing.expectEqual(@as(usize, 131072), Stride.fromDstrd(15).bytes);
}

test "unit: submission doorbell offset for admin queue with packed stride" {
    // Goal: SQ0 tail doorbell sits at 0x1000 regardless of DSTRD; verify via
    // Doorbells composed with a caller-owned MMIO window.
    var bar_bytes: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try registers.ControllerRegisters.at(&bar_bytes);
    const db = Doorbells.fromRegisters(regs, zeroedCap(0));
    const sq = db.submissionQueue(Qid.admin);
    try testing.expectEqual(@as(usize, 0x1000), sq.offset());
}

test "unit: completion doorbell offset for admin queue with packed stride" {
    // Goal: CQ0 head doorbell sits at 0x1004 when DSTRD=0.
    var bar_bytes: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try registers.ControllerRegisters.at(&bar_bytes);
    const db = Doorbells.fromRegisters(regs, zeroedCap(0));
    const cq = db.completionQueue(Qid.admin);
    try testing.expectEqual(@as(usize, 0x1004), cq.offset());
}

test "unit: submission doorbell offset for io queue with packed stride" {
    // Goal: QID 1 SQ tail doorbell sits at 0x1008 with the packed (DSTRD=0) stride.
    var bar_bytes: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try registers.ControllerRegisters.at(&bar_bytes);
    const db = Doorbells.fromRegisters(regs, zeroedCap(0));
    const sq = db.submissionQueue(Qid.from(1));
    try testing.expectEqual(@as(usize, 0x1008), sq.offset());
}

test "unit: completion doorbell offset for io queue with packed stride" {
    // Goal: QID 1 CQ head doorbell sits at 0x100c with the packed (DSTRD=0) stride.
    var bar_bytes: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try registers.ControllerRegisters.at(&bar_bytes);
    const db = Doorbells.fromRegisters(regs, zeroedCap(0));
    const cq = db.completionQueue(Qid.from(1));
    try testing.expectEqual(@as(usize, 0x100c), cq.offset());
}

test "unit: doorbell offsets honor expanded stride" {
    // Goal: with DSTRD=2 (stride 16 B), QID 1 lands SQ1 at 0x1020 and CQ1 at 0x1030.
    var bar_bytes: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try registers.ControllerRegisters.at(&bar_bytes);
    const db = Doorbells.fromRegisters(regs, zeroedCap(2));
    const sq = db.submissionQueue(Qid.from(1));
    const cq = db.completionQueue(Qid.from(1));
    try testing.expectEqual(@as(usize, 0x1020), sq.offset());
    try testing.expectEqual(@as(usize, 0x1030), cq.offset());
}

test "unit: doorbell value stores index and clears reserved bits" {
    // Goal: Value.fromIndex places the index in bits 15:0 and leaves bits 31:16 zero.
    try testing.expectEqual(@as(u32, 0x0000_0000), Value.fromIndex(0).raw());
    try testing.expectEqual(@as(u32, 0x0000_0001), Value.fromIndex(1).raw());
    try testing.expectEqual(@as(u32, 0x0000_ABCD), Value.fromIndex(0xABCD).raw());
    try testing.expectEqual(@as(u32, 0x0000_FFFF), Value.fromIndex(0xFFFF).raw());

    const v = Value.fromIndex(0x1234);
    try testing.expectEqual(@as(u16, 0x1234), v.index);
    try testing.expectEqual(@as(u16, 0), v.reserved_16);
}

test "unit: submission queue setTail writes expected MMIO lane" {
    // Goal: setTail lands a 32-bit little-endian store at the SQ tail offset and
    // does not touch neighboring lanes. Verify by reading the raw scratch bytes
    // back through std.mem.readInt over the caller-owned buffer.
    var bar_bytes: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try registers.ControllerRegisters.at(&bar_bytes);
    const db = Doorbells.fromRegisters(regs, zeroedCap(2));
    const sq = db.submissionQueue(Qid.from(1));

    try sq.setTail(0xBEEF);

    // SQ1 offset with DSTRD=2 is 0x1020.
    try testing.expectEqual(@as(u32, 0x0000_BEEF), std.mem.readInt(u32, bar_bytes[0x1020..0x1024], .little));
    // Neighbor CQ1 lane at 0x1030 stays zero — doorbell wrote exactly one 32-bit lane.
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bar_bytes[0x1030..0x1034], .little));
    // Lane immediately preceding the target also untouched.
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bar_bytes[0x101c..0x1020], .little));
}

test "unit: completion queue setHead writes expected MMIO lane" {
    // Goal: setHead lands a 32-bit little-endian store at the CQ head offset and
    // does not touch neighboring lanes.
    var bar_bytes: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try registers.ControllerRegisters.at(&bar_bytes);
    const db = Doorbells.fromRegisters(regs, zeroedCap(2));
    const cq = db.completionQueue(Qid.from(1));

    try cq.setHead(0x00A5);

    // CQ1 offset with DSTRD=2 is 0x1030.
    try testing.expectEqual(@as(u32, 0x0000_00A5), std.mem.readInt(u32, bar_bytes[0x1030..0x1034], .little));
    // Neighbor SQ1 lane at 0x1020 stays zero.
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bar_bytes[0x1020..0x1024], .little));
    // Lane immediately after the target also untouched.
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bar_bytes[0x1034..0x1038], .little));
}

test "unit: doorbell write rejects short window" {
    // Goal: a BAR window sized to the register block minimum (0x1000 B) has no
    // room for any doorbell lane; setTail and setHead must surface
    // Mmio.Window.Error.OutOfBounds instead of writing past the buffer.
    var bar_bytes: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try registers.ControllerRegisters.at(&bar_bytes);
    const db = Doorbells.fromRegisters(regs, zeroedCap(0));

    const sq = db.submissionQueue(Qid.admin);
    try testing.expectError(error.OutOfBounds, sq.setTail(0));

    const cq = db.completionQueue(Qid.admin);
    try testing.expectError(error.OutOfBounds, cq.setHead(0));
}
