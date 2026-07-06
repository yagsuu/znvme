//! Host-side tests for core identifiers. Spec: docs/specs/core/ids.md.

const std = @import("std");
const testing = std.testing;

const nvme = @import("nvme");
const ids = nvme.core.ids;

test "unit: ids Nsid.none and Nsid.broadcast match spec sentinels" {
    try testing.expectEqual(@as(u32, 0x0000_0000), ids.Nsid.none.raw());
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), ids.Nsid.broadcast.raw());
}

test "unit: ids Nsid predicates classify none / broadcast / valid namespace" {
    const zero = ids.Nsid.from(0x0000_0000);
    try testing.expect(zero.isNone());
    try testing.expect(!zero.isBroadcast());
    try testing.expect(!zero.isValidNamespace());

    const one = ids.Nsid.from(0x0000_0001);
    try testing.expect(!one.isNone());
    try testing.expect(!one.isBroadcast());
    try testing.expect(one.isValidNamespace());

    const mid = ids.Nsid.from(0x0000_1234);
    try testing.expect(!mid.isNone());
    try testing.expect(!mid.isBroadcast());
    try testing.expect(mid.isValidNamespace());

    const high = ids.Nsid.from(0xFFFF_FFFE);
    try testing.expect(!high.isNone());
    try testing.expect(!high.isBroadcast());
    try testing.expect(high.isValidNamespace());

    const bcast = ids.Nsid.from(0xFFFF_FFFF);
    try testing.expect(!bcast.isNone());
    try testing.expect(bcast.isBroadcast());
    try testing.expect(!bcast.isValidNamespace());

    try testing.expect(ids.Nsid.none.isNone());
    try testing.expect(ids.Nsid.broadcast.isBroadcast());
}

test "unit: ids Cid round-trips every boundary u16" {
    const cases = [_]u16{ 0, 1, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF };
    inline for (cases) |v| {
        try testing.expectEqual(v, ids.Cid.from(v).raw());
    }
}

test "unit: ids Qid.admin and Qid.reserved_max match spec sentinels" {
    try testing.expectEqual(@as(u16, 0x0000), ids.Qid.admin.raw());
    try testing.expectEqual(@as(u16, 0xFFFF), ids.Qid.reserved_max.raw());
}

test "unit: ids Qid predicates classify admin / io queue / reserved" {
    const zero = ids.Qid.from(0x0000);
    try testing.expect(zero.isAdmin());
    try testing.expect(!zero.isIoQueue());
    try testing.expect(!zero.isReserved());

    const one = ids.Qid.from(0x0001);
    try testing.expect(!one.isAdmin());
    try testing.expect(one.isIoQueue());
    try testing.expect(!one.isReserved());

    const high = ids.Qid.from(0xFFFE);
    try testing.expect(!high.isAdmin());
    try testing.expect(high.isIoQueue());
    try testing.expect(!high.isReserved());

    const reserved = ids.Qid.from(0xFFFF);
    try testing.expect(!reserved.isAdmin());
    try testing.expect(!reserved.isIoQueue());
    try testing.expect(reserved.isReserved());
}

test "unit: ids sizes and alignments match wire widths" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(ids.Nsid));
    try testing.expectEqual(@alignOf(u32), @alignOf(ids.Nsid));
    try testing.expectEqual(@as(usize, 32), @bitSizeOf(ids.Nsid));

    try testing.expectEqual(@as(usize, 2), @sizeOf(ids.Cid));
    try testing.expectEqual(@alignOf(u16), @alignOf(ids.Cid));
    try testing.expectEqual(@as(usize, 16), @bitSizeOf(ids.Cid));

    try testing.expectEqual(@as(usize, 2), @sizeOf(ids.Qid));
    try testing.expectEqual(@alignOf(u16), @alignOf(ids.Qid));
    try testing.expectEqual(@as(usize, 16), @bitSizeOf(ids.Qid));
}

test "unit: ids distinct domains do not implicitly convert" {
    comptime {
        std.debug.assert(@TypeOf(ids.Nsid.none) != @TypeOf(ids.Cid.from(0)));
        std.debug.assert(@TypeOf(ids.Cid.from(0)) != @TypeOf(ids.Qid.from(0)));
        std.debug.assert(@TypeOf(ids.Nsid.none) != @TypeOf(ids.Qid.from(0)));
    }
}
