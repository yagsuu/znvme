//! Host-side tests for src/commands/sqe.zig. Spec: docs/specs/commands/sqe.md.

const std = @import("std");
const testing = std.testing;

const stdx = @import("stdx");

const nvme = @import("nvme");
const sqe = nvme.commands.sqe;
const prp = nvme.core.prp;
const ids = nvme.core.ids;
const regen = @import("../fixtures/commands/sqe_identify_controller_regen.zig");

const Sqe = sqe.Sqe;
const Cdw0 = sqe.Cdw0;
const Fuse = sqe.Fuse;
const Psdt = sqe.Psdt;
const DataPointers = prp.DataPointers;
const PrpEntry = prp.PrpEntry;

test "unit: sqe extern layout matches NVMe common command format offsets" {
    // Behavioral mirror of the comptime offset assertions in the module.
    try testing.expectEqual(@as(usize, 0x00), @offsetOf(Sqe, "_cdw0"));
    try testing.expectEqual(@as(usize, 0x04), @offsetOf(Sqe, "_nsid"));
    try testing.expectEqual(@as(usize, 0x08), @offsetOf(Sqe, "_reserved_8"));
    try testing.expectEqual(@as(usize, 0x0c), @offsetOf(Sqe, "_reserved_12"));
    try testing.expectEqual(@as(usize, 0x10), @offsetOf(Sqe, "_mptr"));
    try testing.expectEqual(@as(usize, 0x18), @offsetOf(Sqe, "_dptr"));
    try testing.expectEqual(@as(usize, 0x28), @offsetOf(Sqe, "_cdw10"));
    try testing.expectEqual(@as(usize, 0x2c), @offsetOf(Sqe, "_cdw11"));
    try testing.expectEqual(@as(usize, 0x30), @offsetOf(Sqe, "_cdw12"));
    try testing.expectEqual(@as(usize, 0x34), @offsetOf(Sqe, "_cdw13"));
    try testing.expectEqual(@as(usize, 0x38), @offsetOf(Sqe, "_cdw14"));
    try testing.expectEqual(@as(usize, 0x3c), @offsetOf(Sqe, "_cdw15"));
}

test "unit: sqe size is 64 bytes and alignment is 8" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(Sqe));
    try testing.expectEqual(sqe.size_bytes, @sizeOf(Sqe));
    try testing.expectEqual(@as(usize, 8), @alignOf(Sqe));
}

test "unit: Sqe.validate rejects buffer shorter than 64 with ShortBuffer" {
    var b: [63]u8 align(8) = @splat(0);
    try testing.expectError(error.ShortBuffer, Sqe.validate(&b));
}

test "unit: Sqe.validate rejects misaligned byte pointer with Misaligned" {
    // Construct a 64-byte window starting at an odd address by slicing a u8
    // array of 65 bytes from offset 1. `align(8)` ensures base is 8-aligned so
    // the +1 slice is provably u32-misaligned.
    var b: [65]u8 align(8) = @splat(0);
    try testing.expectError(error.Misaligned, Sqe.validate(b[1..65]));
}

test "unit: Sqe.validate accepts aligned 64-byte buffer and returns a decoding pointer" {
    // Stamp a golden SQE through init, reinterpret as bytes, validate, and
    // read every accessor to confirm the returned pointer decodes correctly.
    var scratch: Sqe align(@alignOf(Sqe)) = undefined;
    Sqe.init(&scratch, .{
        .opcode = 0x06,
        .command_id = .from(0x1234),
        .namespace_id = .from(0x0000_00AB),
        .fuse = .first,
        .psdt = .sgl_mptr_addr,
        .metadata_pointer = 0x1122_3344_5566_7788,
        .data_pointers = .{
            .prp1 = .fromDmaAddr(.fromInt(0x0000_1000)),
            .prp2 = .fromDmaAddr(.fromInt(0x0000_2000)),
        },
        .cdw10 = 0xAAAA_AAAA,
        .cdw11 = 0xBBBB_BBBB,
        .cdw12 = 0xCCCC_CCCC,
        .cdw13 = 0xDDDD_DDDD,
        .cdw14 = 0xEEEE_EEEE,
        .cdw15 = 0xFFFF_FFFF,
    });

    var bytes: [64]u8 align(8) = undefined;
    @memcpy(&bytes, std.mem.asBytes(&scratch));

    const view = try Sqe.validate(&bytes);
    try testing.expectEqual(@as(u8, 0x06), view.opcode());
    try testing.expectEqual(Fuse.first, view.fuse());
    try testing.expectEqual(Psdt.sgl_mptr_addr, view.psdt());
    try testing.expectEqual(@as(u16, 0x1234), view.cid().raw());
    try testing.expectEqual(@as(u32, 0x0000_00AB), view.nsid().raw());
    try testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), view.mptr());
    try testing.expectEqual(@as(u64, 0x0000_1000), view.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0x0000_2000), view.dptr().prp2.raw());
    try testing.expectEqual(@as(u32, 0xAAAA_AAAA), view.cdw10());
    try testing.expectEqual(@as(u32, 0xBBBB_BBBB), view.cdw11());
    try testing.expectEqual(@as(u32, 0xCCCC_CCCC), view.cdw12());
    try testing.expectEqual(@as(u32, 0xDDDD_DDDD), view.cdw13());
    try testing.expectEqual(@as(u32, 0xEEEE_EEEE), view.cdw14());
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), view.cdw15());
}

test "unit: cdw0 packs opcode fuse reserved psdt cid at documented bit positions" {
    // Bit slicing: opcode=7:0, fuse=9:8, reserved=13:10 (zero), psdt=15:14, cid=31:16.
    // Compose from packed struct and inspect through raw().
    const packed_val: Cdw0 = .{
        .opcode = 0xA5,
        .fuse = .second,
        .psdt = .sgl_mptr_sgl,
        .cid = 0xBEEF,
    };
    const raw = packed_val.raw();
    try testing.expectEqual(@as(u32, 0xA5), raw & 0xFF);
    try testing.expectEqual(@as(u32, 0b10), (raw >> 8) & 0b11);
    try testing.expectEqual(@as(u32, 0), (raw >> 10) & 0b1111);
    try testing.expectEqual(@as(u32, 0b10), (raw >> 14) & 0b11);
    try testing.expectEqual(@as(u32, 0xBEEF), (raw >> 16) & 0xFFFF);

    // Reverse direction: fromRaw at a chosen bit pattern decodes the four subfields.
    // opcode=0x12, fuse=0b01, reserved=0, psdt=0b01, cid=0xCAFE => 0xCAFE_4112.
    const decoded = Cdw0.fromRaw(0xCAFE_4112);
    try testing.expectEqual(@as(u8, 0x12), decoded.opcode);
    try testing.expectEqual(Fuse.first, decoded.fuse);
    try testing.expectEqual(@as(u4, 0), decoded.reserved_10);
    try testing.expectEqual(Psdt.sgl_mptr_addr, decoded.psdt);
    try testing.expectEqual(@as(u16, 0xCAFE), decoded.cid);

    // fromRaw(0) is the all-zero shape.
    const zero = Cdw0.fromRaw(0);
    try testing.expectEqual(@as(u8, 0), zero.opcode);
    try testing.expectEqual(Fuse.normal, zero.fuse);
    try testing.expectEqual(@as(u4, 0), zero.reserved_10);
    try testing.expectEqual(Psdt.prps, zero.psdt);
    try testing.expectEqual(@as(u16, 0), zero.cid);
}

test "unit: cdw0 fuse round-trips through non-exhaustive enum" {
    // Every documented value plus the reserved 0b11 bit pattern.
    const cases = [_]Fuse{
        .normal,
        .first,
        .second,
        @enumFromInt(0b11),
    };
    inline for (cases) |f| {
        const packed_val: Cdw0 = .{ .opcode = 0, .fuse = f, .psdt = .prps, .cid = 0 };
        const decoded = Cdw0.fromRaw(packed_val.raw());
        try testing.expectEqual(f, decoded.fuse);
        try testing.expectEqual(@intFromEnum(f), @intFromEnum(decoded.fuse));
    }
}

test "unit: cdw0 psdt round-trips through non-exhaustive enum" {
    // Every documented value plus the reserved 0b11 bit pattern.
    const cases = [_]Psdt{
        .prps,
        .sgl_mptr_addr,
        .sgl_mptr_sgl,
        @enumFromInt(0b11),
    };
    inline for (cases) |p| {
        const packed_val: Cdw0 = .{ .opcode = 0, .fuse = .normal, .psdt = p, .cid = 0 };
        const decoded = Cdw0.fromRaw(packed_val.raw());
        try testing.expectEqual(p, decoded.psdt);
        try testing.expectEqual(@intFromEnum(p), @intFromEnum(decoded.psdt));
    }
}

test "unit: cdw0 reserved 4-bit hole is zeroed on encode" {
    // Construct through the packed struct with every non-reserved field saturated;
    // verify bits 13:10 of the encoded u32 read as zero.
    const packed_val: Cdw0 = .{
        .opcode = 0xFF,
        .fuse = .second,
        .psdt = .sgl_mptr_sgl,
        .cid = 0xFFFF,
    };
    const raw = packed_val.raw();
    try testing.expectEqual(@as(u32, 0), (raw >> 10) & 0b1111);
}

test "unit: sqe default value is all-zero and has psdt prps and fuse normal on decode" {
    const blank: Sqe = .{};
    const bytes = std.mem.asBytes(&blank);
    for (bytes) |b| try testing.expectEqual(@as(u8, 0), b);

    const decoded = blank.cdw0();
    try testing.expectEqual(Fuse.normal, decoded.fuse);
    try testing.expectEqual(Psdt.prps, decoded.psdt);
    try testing.expectEqual(@as(u8, 0), decoded.opcode);
    try testing.expectEqual(@as(u16, 0), decoded.cid);
    try testing.expectEqual(Fuse.normal, blank.fuse());
    try testing.expectEqual(Psdt.prps, blank.psdt());
    try testing.expectEqual(@as(u8, 0), blank.opcode());
}

test "unit: Sqe.init stamps cdw0 and nsid and zeroes every other lane when Init omits them" {
    // Init with only opcode + CID + NSID; every other lane must read back zero.
    var scratch: Sqe align(@alignOf(Sqe)) = undefined;
    // Pre-poison with 0xFF to prove init overwrites every lane.
    @memset(std.mem.asBytes(&scratch), 0xFF);

    Sqe.init(&scratch, .{
        .opcode = 0x06,
        .command_id = .from(0x0042),
        .namespace_id = .from(0x0000_00AB),
    });

    // CDW0 and NSID reflect the caller.
    try testing.expectEqual(@as(u8, 0x06), scratch.opcode());
    try testing.expectEqual(@as(u16, 0x0042), scratch.cid().raw());
    try testing.expectEqual(@as(u32, 0x0000_00AB), scratch.nsid().raw());

    // Every other lane reads zero.
    try testing.expectEqual(@as(u32, 0), scratch._reserved_8);
    try testing.expectEqual(@as(u32, 0), scratch._reserved_12);
    try testing.expectEqual(@as(u64, 0), scratch.mptr());
    try testing.expectEqual(@as(u64, 0), scratch.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0), scratch.dptr().prp2.raw());
    try testing.expectEqual(@as(u32, 0), scratch.cdw10());
    try testing.expectEqual(@as(u32, 0), scratch.cdw11());
    try testing.expectEqual(@as(u32, 0), scratch.cdw12());
    try testing.expectEqual(@as(u32, 0), scratch.cdw13());
    try testing.expectEqual(@as(u32, 0), scratch.cdw14());
    try testing.expectEqual(@as(u32, 0), scratch.cdw15());
}

test "unit: Sqe.init defaults fuse to normal psdt to prps and namespace_id to none" {
    // Omit fuse, psdt, and namespace_id; observe the default wire bits.
    var scratch: Sqe align(@alignOf(Sqe)) = undefined;
    Sqe.init(&scratch, .{
        .opcode = 0x06,
        .command_id = .from(0x0001),
    });
    try testing.expectEqual(Fuse.normal, scratch.fuse());
    try testing.expectEqual(Psdt.prps, scratch.psdt());
    try testing.expect(scratch.nsid().isNone());
    try testing.expectEqual(@as(u32, 0), scratch.nsid().raw());
}

test "unit: Sqe.init writes metadata_pointer into the mptr lane and leaves others unchanged" {
    // Baseline: init with a known non-zero shape but zero MPTR.
    var scratch: Sqe align(@alignOf(Sqe)) = undefined;
    const base_init: Sqe.Init = .{
        .opcode = 0x02,
        .command_id = .from(0x0007),
        .namespace_id = .from(0x0000_0001),
        .cdw10 = 0x1111_1111,
        .cdw11 = 0x2222_2222,
        .cdw12 = 0x3333_3333,
        .cdw13 = 0x4444_4444,
        .cdw14 = 0x5555_5555,
        .cdw15 = 0x6666_6666,
    };
    Sqe.init(&scratch, base_init);
    try testing.expectEqual(@as(u64, 0), scratch.mptr());

    // Same lanes; only metadata_pointer changes.
    var with_mptr: Sqe align(@alignOf(Sqe)) = undefined;
    var mptr_init = base_init;
    mptr_init.metadata_pointer = 0xDEAD_BEEF_CAFE_F00D;
    Sqe.init(&with_mptr, mptr_init);

    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE_F00D), with_mptr.mptr());
    // Every other lane reads identically to the baseline.
    try testing.expectEqual(scratch._cdw0, with_mptr._cdw0);
    try testing.expectEqual(scratch._nsid, with_mptr._nsid);
    try testing.expectEqual(scratch._reserved_8, with_mptr._reserved_8);
    try testing.expectEqual(scratch._reserved_12, with_mptr._reserved_12);
    try testing.expectEqual(scratch.dptr().prp1.raw(), with_mptr.dptr().prp1.raw());
    try testing.expectEqual(scratch.dptr().prp2.raw(), with_mptr.dptr().prp2.raw());
    try testing.expectEqual(scratch.cdw10(), with_mptr.cdw10());
    try testing.expectEqual(scratch.cdw11(), with_mptr.cdw11());
    try testing.expectEqual(scratch.cdw12(), with_mptr.cdw12());
    try testing.expectEqual(scratch.cdw13(), with_mptr.cdw13());
    try testing.expectEqual(scratch.cdw14(), with_mptr.cdw14());
    try testing.expectEqual(scratch.cdw15(), with_mptr.cdw15());
}

test "unit: Sqe.init writes data_pointers prp1 at offset 0x18 and prp2 at offset 0x20" {
    // Stamp a known DPTR shape, cast the slot to bytes, and read the two 64-bit
    // lanes back through their documented offsets.
    var scratch: Sqe align(@alignOf(Sqe)) = undefined;
    const dptr: DataPointers = .{
        .prp1 = .fromDmaAddr(.fromInt(0x0000_1122_3344_5566)),
        .prp2 = .fromDmaAddr(.fromInt(0x0000_7788_99AA_BBCC)),
    };
    Sqe.init(&scratch, .{
        .opcode = 0x06,
        .command_id = .from(0x0001),
        .data_pointers = dptr,
    });

    const bytes = std.mem.asBytes(&scratch);
    try testing.expectEqual(
        @as(u64, 0x0000_1122_3344_5566),
        std.mem.readInt(u64, bytes[0x18..][0..8], .little),
    );
    try testing.expectEqual(
        @as(u64, 0x0000_7788_99AA_BBCC),
        std.mem.readInt(u64, bytes[0x20..][0..8], .little),
    );
    try testing.expectEqual(dptr.prp1.raw(), scratch.dptr().prp1.raw());
    try testing.expectEqual(dptr.prp2.raw(), scratch.dptr().prp2.raw());
}

test "unit: Sqe.init writes cdw10 through cdw15 into their addressed lanes" {
    // For each cdw* lane, run init with only that lane set to a sentinel and
    // assert the five sibling lanes remain zero.
    const sentinel: u32 = 0xC0DE_C0DE;
    const base: Sqe.Init = .{ .opcode = 0, .command_id = .from(0) };

    {
        var s: Sqe align(@alignOf(Sqe)) = undefined;
        var init = base;
        init.cdw10 = sentinel;
        Sqe.init(&s, init);
        try testing.expectEqual(sentinel, s.cdw10());
        try testing.expectEqual(@as(u32, 0), s.cdw11());
        try testing.expectEqual(@as(u32, 0), s.cdw12());
        try testing.expectEqual(@as(u32, 0), s.cdw13());
        try testing.expectEqual(@as(u32, 0), s.cdw14());
        try testing.expectEqual(@as(u32, 0), s.cdw15());
    }
    {
        var s: Sqe align(@alignOf(Sqe)) = undefined;
        var init = base;
        init.cdw11 = sentinel;
        Sqe.init(&s, init);
        try testing.expectEqual(@as(u32, 0), s.cdw10());
        try testing.expectEqual(sentinel, s.cdw11());
        try testing.expectEqual(@as(u32, 0), s.cdw12());
        try testing.expectEqual(@as(u32, 0), s.cdw13());
        try testing.expectEqual(@as(u32, 0), s.cdw14());
        try testing.expectEqual(@as(u32, 0), s.cdw15());
    }
    {
        var s: Sqe align(@alignOf(Sqe)) = undefined;
        var init = base;
        init.cdw12 = sentinel;
        Sqe.init(&s, init);
        try testing.expectEqual(@as(u32, 0), s.cdw10());
        try testing.expectEqual(@as(u32, 0), s.cdw11());
        try testing.expectEqual(sentinel, s.cdw12());
        try testing.expectEqual(@as(u32, 0), s.cdw13());
        try testing.expectEqual(@as(u32, 0), s.cdw14());
        try testing.expectEqual(@as(u32, 0), s.cdw15());
    }
    {
        var s: Sqe align(@alignOf(Sqe)) = undefined;
        var init = base;
        init.cdw13 = sentinel;
        Sqe.init(&s, init);
        try testing.expectEqual(@as(u32, 0), s.cdw10());
        try testing.expectEqual(@as(u32, 0), s.cdw11());
        try testing.expectEqual(@as(u32, 0), s.cdw12());
        try testing.expectEqual(sentinel, s.cdw13());
        try testing.expectEqual(@as(u32, 0), s.cdw14());
        try testing.expectEqual(@as(u32, 0), s.cdw15());
    }
    {
        var s: Sqe align(@alignOf(Sqe)) = undefined;
        var init = base;
        init.cdw14 = sentinel;
        Sqe.init(&s, init);
        try testing.expectEqual(@as(u32, 0), s.cdw10());
        try testing.expectEqual(@as(u32, 0), s.cdw11());
        try testing.expectEqual(@as(u32, 0), s.cdw12());
        try testing.expectEqual(@as(u32, 0), s.cdw13());
        try testing.expectEqual(sentinel, s.cdw14());
        try testing.expectEqual(@as(u32, 0), s.cdw15());
    }
    {
        var s: Sqe align(@alignOf(Sqe)) = undefined;
        var init = base;
        init.cdw15 = sentinel;
        Sqe.init(&s, init);
        try testing.expectEqual(@as(u32, 0), s.cdw10());
        try testing.expectEqual(@as(u32, 0), s.cdw11());
        try testing.expectEqual(@as(u32, 0), s.cdw12());
        try testing.expectEqual(@as(u32, 0), s.cdw13());
        try testing.expectEqual(@as(u32, 0), s.cdw14());
        try testing.expectEqual(sentinel, s.cdw15());
    }
}

test "roundtrip: Sqe.init then accessors decode every scalar field the caller wrote" {
    // Identify-shaped input exercising every documented scalar lane; every
    // accessor must return the caller-supplied value.
    const params: Sqe.Init = .{
        .opcode = 0x06,
        .command_id = .from(0x7ABC),
        .namespace_id = .from(0x0000_0055),
        .fuse = .second,
        .psdt = .sgl_mptr_sgl,
        .metadata_pointer = 0x1122_3344_5566_7788,
        .data_pointers = .{
            .prp1 = .fromDmaAddr(.fromInt(0x0000_0000_ABCD_0000)),
            .prp2 = .fromDmaAddr(.fromInt(0x0000_0000_DCBA_0000)),
        },
        .cdw10 = 0x0000_0001,
        .cdw11 = 0x1010_1010,
        .cdw12 = 0x2020_2020,
        .cdw13 = 0x3030_3030,
        .cdw14 = 0x4040_4040,
        .cdw15 = 0x5050_5050,
    };

    var slot: Sqe align(@alignOf(Sqe)) = undefined;
    Sqe.init(&slot, params);

    try testing.expectEqual(params.opcode, slot.opcode());
    try testing.expectEqual(params.fuse, slot.fuse());
    try testing.expectEqual(params.psdt, slot.psdt());
    try testing.expectEqual(params.command_id.raw(), slot.cid().raw());
    try testing.expectEqual(params.namespace_id.raw(), slot.nsid().raw());
    try testing.expectEqual(params.metadata_pointer, slot.mptr());
    try testing.expectEqual(params.data_pointers.prp1.raw(), slot.dptr().prp1.raw());
    try testing.expectEqual(params.data_pointers.prp2.raw(), slot.dptr().prp2.raw());
    try testing.expectEqual(params.cdw10, slot.cdw10());
    try testing.expectEqual(params.cdw11, slot.cdw11());
    try testing.expectEqual(params.cdw12, slot.cdw12());
    try testing.expectEqual(params.cdw13, slot.cdw13());
    try testing.expectEqual(params.cdw14, slot.cdw14());
    try testing.expectEqual(params.cdw15, slot.cdw15());
}

test "roundtrip: Sqe.init composes prp list dptr from prp construction" {
    // Four-page page-aligned payload requires a PRP list; Sqe.init must carry
    // prp.DataPointers.fromContiguous straight into the slot's DPTR lane.
    var payload_backing: [4 * 4096]u8 align(4096) = @splat(0);
    const payload_base = stdx.addr.DmaAddr.fromInt(0x1_0000_0000);
    const payload = try stdx.dma.Buffer(u8).init(payload_backing[0..], payload_base);
    const page_size = try prp.PageSize.fromBytes(4096);

    var list_backing: [512]PrpEntry align(8) = @splat(.zero);
    const list_dma = stdx.addr.DmaAddr.fromInt(0x2_0000_0000);
    const list_buf = try stdx.dma.Buffer(PrpEntry).init(list_backing[0..], list_dma);
    const list = try prp.PrpList.wrap(list_buf, page_size);

    const dptr = try DataPointers.fromContiguous(.{
        .payload = payload,
        .page_size = page_size,
        .prp_list_output = list,
    });

    var slot: Sqe align(@alignOf(Sqe)) = undefined;
    Sqe.init(&slot, .{
        .opcode = 0x02,
        .command_id = .from(0x0009),
        .namespace_id = .from(0x0000_0001),
        .data_pointers = dptr,
    });

    // PRP1 points at the payload base; PRP2 points at the PRP list.
    try testing.expectEqual(payload_base.raw(), slot.dptr().prp1.raw());
    try testing.expectEqual(list_dma.raw(), slot.dptr().prp2.raw());
    // And the list itself holds the follow-on page addresses.
    try testing.expectEqual(payload_base.raw() + page_size.bytes, list_backing[0].raw());
    try testing.expectEqual(payload_base.raw() + 2 * page_size.bytes, list_backing[1].raw());
    try testing.expectEqual(payload_base.raw() + 3 * page_size.bytes, list_backing[2].raw());
}

test "golden: sqe identify controller minimal bytes" {
    // Compose bytes from the same golden Init the regen program uses and
    // compare byte-for-byte against the on-disk fixture.
    const composed = regen.compose();
    const embedded = @embedFile("../fixtures/commands/sqe_identify_controller.bin");
    try testing.expectEqual(@as(usize, sqe.size_bytes), embedded.len);
    try testing.expectEqualSlices(u8, embedded, &composed);

    // Validate the golden bytes as an emulator seam would; copy into an
    // aligned buffer since `@embedFile` yields byte-aligned storage.
    var golden: [sqe.size_bytes]u8 align(@alignOf(Sqe)) = undefined;
    @memcpy(&golden, embedded);
    const view = try Sqe.validate(&golden);

    // One accessor round-trip against the golden Init's declared fields.
    try testing.expectEqual(regen.golden_init.opcode, view.opcode());
    try testing.expectEqual(regen.golden_init.command_id.raw(), view.cid().raw());
    try testing.expectEqual(Fuse.normal, view.fuse());
    try testing.expectEqual(Psdt.prps, view.psdt());
    try testing.expect(view.nsid().isNone());
    try testing.expectEqual(@as(u64, 0), view.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0), view.dptr().prp2.raw());
    try testing.expectEqual(regen.golden_init.cdw10, view.cdw10());
}
