//! Tests for core PRP construction. Spec: docs/specs/core/prp.md.

const std = @import("std");

const stdx = @import("stdx");

const nvme = @import("nvme");

const prp = nvme.core.prp;

const testing = std.testing;

// Backing for the "rejects transfers requiring chained PRP-list pages" test.
// The `TransferTooLarge` guard trips when the payload requires more than one
// PRP-list page worth of entries. For a 4 KiB page that is 512 entries, so the
// smallest tripping transfer is `4096 + 513 * 4096` bytes when starting
// page-aligned. Lives in .bss to keep it off the stack.
var chained_transfer_backing: [514 * 4096]u8 align(4096) = @splat(0);

test "unit: prp entry layout is native 64-bit lane on little-endian target" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(prp.PrpEntry));
    try testing.expectEqual(@as(usize, @alignOf(u64)), @alignOf(prp.PrpEntry));
    try testing.expectEqual(@as(usize, 0), @offsetOf(prp.PrpEntry, "value"));

    // Little-endian storage: bytes 0..8 mirror the u64 lane.
    const entry = prp.PrpEntry.fromDmaAddr(.fromInt(0x0123_4567_89AB_CDEF));
    const raw_bytes = std.mem.asBytes(&entry);
    try testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), std.mem.readInt(u64, raw_bytes[0..8], .little));
    try testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), entry.raw());
}

test "unit: data pointers layout matches PRP1 PRP2 pair" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(prp.DataPointers));
    try testing.expectEqual(@as(usize, @alignOf(u64)), @alignOf(prp.DataPointers));
    try testing.expectEqual(@as(usize, 0), @offsetOf(prp.DataPointers, "prp1"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(prp.DataPointers, "prp2"));
}

test "unit: page size rejects zero non-power-of-two and below 4 KiB" {
    try testing.expectError(prp.Error.InvalidPageSize, prp.PageSize.fromBytes(0));
    try testing.expectError(prp.Error.InvalidPageSize, prp.PageSize.fromBytes(4095));
    try testing.expectError(prp.Error.InvalidPageSize, prp.PageSize.fromBytes(3000));
    try testing.expectError(prp.Error.InvalidPageSize, prp.PageSize.fromBytes(2048));

    const ps4k = try prp.PageSize.fromBytes(4096);
    try testing.expectEqual(@as(u64, 4096), ps4k.bytes);

    const ps8k = try prp.PageSize.fromBytes(8192);
    try testing.expectEqual(@as(u64, 8192), ps8k.bytes);
}

test "unit: data pointers from contiguous one-page payload clears PRP2" {
    var backing: [4096]u8 align(8) = @splat(0);
    const base = stdx.addr.DmaAddr.fromInt(0x1_0000_0000);
    const payload = try stdx.dma.Buffer(u8).init(backing[0..], base);
    const page_size = try prp.PageSize.fromBytes(4096);

    const dp = try prp.DataPointers.fromContiguous(.{
        .payload = payload,
        .page_size = page_size,
    });

    try testing.expectEqual(base.raw(), dp.prp1.raw());
    try testing.expect(dp.prp2.isZero());
}

test "unit: data pointers from contiguous offset payload uses PRP2 for second page" {
    // Base at page offset 0x800, payload 0x1000 bytes -> spans exactly two
    // pages: 0x800 in the first, 0x800 in the second.
    var backing: [4096]u8 align(8) = @splat(0);
    const offset: u64 = 0x800;
    const base = stdx.addr.DmaAddr.fromInt(0x1_0000_0000 + offset);
    const payload = try stdx.dma.Buffer(u8).init(backing[0..], base);
    const page_size = try prp.PageSize.fromBytes(4096);

    const dp = try prp.DataPointers.fromContiguous(.{
        .payload = payload,
        .page_size = page_size,
    });

    try testing.expectEqual(base.raw(), dp.prp1.raw());
    const first_bytes = page_size.bytes - offset;
    try testing.expectEqual(base.raw() + first_bytes, dp.prp2.raw());
}

test "unit: data pointers from contiguous multi-page payload fills PRP list" {
    // Page-aligned base, four 4 KiB pages total. PRP1 covers page 0; PRP2
    // points at the list which holds entries for pages 1, 2, and 3.
    var backing: [4 * 4096]u8 align(4096) = @splat(0);
    const base = stdx.addr.DmaAddr.fromInt(0x1_0000_0000);
    const payload = try stdx.dma.Buffer(u8).init(backing[0..], base);
    const page_size = try prp.PageSize.fromBytes(4096);

    var list_backing: [512]prp.PrpEntry align(8) = @splat(.zero);
    const list_dma = stdx.addr.DmaAddr.fromInt(0x2_0000_0000);
    const list_buf = try stdx.dma.Buffer(prp.PrpEntry).init(list_backing[0..], list_dma);
    const list = try prp.PrpList.wrap(list_buf, page_size);

    const dp = try prp.DataPointers.fromContiguous(.{
        .payload = payload,
        .page_size = page_size,
        .prp_list_output = list,
    });

    try testing.expectEqual(base.raw(), dp.prp1.raw());
    try testing.expectEqual(list_dma.raw(), dp.prp2.raw());
    try testing.expectEqual(base.raw() + page_size.bytes, list_backing[0].raw());
    try testing.expectEqual(base.raw() + 2 * page_size.bytes, list_backing[1].raw());
    try testing.expectEqual(base.raw() + 3 * page_size.bytes, list_backing[2].raw());
    // Untouched slots stay zero (implementation writes exactly `required` entries).
    try testing.expect(list_backing[3].isZero());
}

test "unit: PRP construction rejects empty payload" {
    var backing: [16]u8 align(8) = @splat(0);
    const base = stdx.addr.DmaAddr.fromInt(0x1_0000_0000);
    const empty = try stdx.dma.Buffer(u8).init(backing[0..0], base);
    const page_size = try prp.PageSize.fromBytes(4096);

    try testing.expectError(prp.Error.EmptyPayload, prp.DataPointers.fromContiguous(.{
        .payload = empty,
        .page_size = page_size,
    }));
}

test "unit: PRP construction rejects low reserved PRP bits" {
    // Low two bits of the payload DMA address must be zero.
    var backing: [4096]u8 align(8) = @splat(0);
    const base = stdx.addr.DmaAddr.fromInt(0x1_0000_0001);
    const payload = try stdx.dma.Buffer(u8).init(backing[0..], base);
    const page_size = try prp.PageSize.fromBytes(4096);

    try testing.expectError(prp.Error.MisalignedPrpEntry, prp.DataPointers.fromContiguous(.{
        .payload = payload,
        .page_size = page_size,
    }));
}

test "unit: PRP construction requires list for more than two PRP regions" {
    // Four pages page-aligned needs a PRP list; omit it.
    var backing: [4 * 4096]u8 align(4096) = @splat(0);
    const base = stdx.addr.DmaAddr.fromInt(0x1_0000_0000);
    const payload = try stdx.dma.Buffer(u8).init(backing[0..], base);
    const page_size = try prp.PageSize.fromBytes(4096);

    try testing.expectError(prp.Error.PrpListRequired, prp.DataPointers.fromContiguous(.{
        .payload = payload,
        .page_size = page_size,
        .prp_list_output = null,
    }));
}

test "unit: PRP construction rejects short PRP list" {
    // Payload needs 3 list entries; give it a 2-entry list.
    var backing: [4 * 4096]u8 align(4096) = @splat(0);
    const base = stdx.addr.DmaAddr.fromInt(0x1_0000_0000);
    const payload = try stdx.dma.Buffer(u8).init(backing[0..], base);
    const page_size = try prp.PageSize.fromBytes(4096);

    var list_backing: [2]prp.PrpEntry align(8) = @splat(.zero);
    const list_dma = stdx.addr.DmaAddr.fromInt(0x2_0000_0000);
    const list_buf = try stdx.dma.Buffer(prp.PrpEntry).init(list_backing[0..], list_dma);
    const list = try prp.PrpList.wrap(list_buf, page_size);

    try testing.expectError(prp.Error.PrpListTooSmall, prp.DataPointers.fromContiguous(.{
        .payload = payload,
        .page_size = page_size,
        .prp_list_output = list,
    }));
}

test "unit: PRP construction rejects misaligned PRP list DMA address" {
    var list_backing: [8]prp.PrpEntry align(8) = @splat(.zero);
    const list_dma = stdx.addr.DmaAddr.fromInt(0x2_0000_0008);
    const list_buf = try stdx.dma.Buffer(prp.PrpEntry).init(list_backing[0..], list_dma);
    const page_size = try prp.PageSize.fromBytes(4096);

    try testing.expectError(prp.Error.MisalignedPrpList, prp.PrpList.wrap(list_buf, page_size));
}

test "unit: PRP construction rejects oversized PRP list buffer" {
    // 4 KiB page => entriesPerListPage == 512. 513 slots trips PrpListTooLarge.
    var list_backing: [513]prp.PrpEntry align(8) = @splat(.zero);
    const list_dma = stdx.addr.DmaAddr.fromInt(0x2_0000_0000);
    const list_buf = try stdx.dma.Buffer(prp.PrpEntry).init(list_backing[0..], list_dma);
    const page_size = try prp.PageSize.fromBytes(4096);

    try testing.expectError(prp.Error.PrpListTooLarge, prp.PrpList.wrap(list_buf, page_size));
}

test "unit: PRP construction rejects transfers requiring chained PRP-list pages" {
    // Page-aligned base + 514 * 4096 bytes -> first_bytes=4096, remaining=
    // 513*4096, required=513 > entriesPerListPage(512).
    const base = stdx.addr.DmaAddr.fromInt(0x1_0000_0000);
    const payload = try stdx.dma.Buffer(u8).init(chained_transfer_backing[0..], base);
    const page_size = try prp.PageSize.fromBytes(4096);

    // Supply a maximum-capacity list so the TransferTooLarge guard fires
    // strictly before the capacity check.
    var list_backing: [512]prp.PrpEntry align(8) = @splat(.zero);
    const list_dma = stdx.addr.DmaAddr.fromInt(0x2_0000_0000);
    const list_buf = try stdx.dma.Buffer(prp.PrpEntry).init(list_backing[0..], list_dma);
    const list = try prp.PrpList.wrap(list_buf, page_size);

    try testing.expectError(prp.Error.TransferTooLarge, prp.DataPointers.fromContiguous(.{
        .payload = payload,
        .page_size = page_size,
        .prp_list_output = list,
    }));
}

test "unit: io queue base fromContiguous rejects empty buffer" {
    var backing: [16]u8 align(8) = @splat(0);
    const base = stdx.addr.DmaAddr.fromInt(0x1_0000_0000);
    const empty = try stdx.dma.Buffer(u8).init(backing[0..0], base);
    const page_size = try prp.PageSize.fromBytes(4096);

    try testing.expectError(prp.Error.EmptyPayload, prp.IoQueueBase.fromContiguous(empty, page_size));
}

test "unit: io queue base fromContiguous rejects non-page-aligned base with MisalignedQueueBase" {
    var backing: [4096]u8 align(8) = @splat(0);
    const base = stdx.addr.DmaAddr.fromInt(0x800);
    const buffer = try stdx.dma.Buffer(u8).init(backing[0..], base);
    const page_size = try prp.PageSize.fromBytes(4096);

    try testing.expectError(prp.Error.MisalignedQueueBase, prp.IoQueueBase.fromContiguous(buffer, page_size));
}

test "unit: io queue base fromContiguous returns PRP1 equal to buffer dmaAddr for a page-aligned buffer" {
    var backing: [4096]u8 align(4096) = @splat(0);
    const base = stdx.addr.DmaAddr.fromInt(0x1000);
    const buffer = try stdx.dma.Buffer(u8).init(backing[0..], base);
    const page_size = try prp.PageSize.fromBytes(4096);

    const result = try prp.IoQueueBase.fromContiguous(buffer, page_size);
    try testing.expectEqual(base.raw(), result.prp1.raw());
    try testing.expectEqual(buffer.dmaAddr().raw(), result.prp1.raw());
}

test "unit: io queue base layout is a single PRP entry at offset zero" {
    try testing.expectEqual(@as(usize, @sizeOf(prp.PrpEntry)), @sizeOf(prp.IoQueueBase));
    try testing.expectEqual(@as(usize, @alignOf(u64)), @alignOf(prp.IoQueueBase));
    try testing.expectEqual(@as(usize, 0), @offsetOf(prp.IoQueueBase, "prp1"));
}
