//! Tests for src/commands/nvm.zig. Spec: docs/specs/commands/nvm.md.

const std = @import("std");

const stdx = @import("stdx");

const nvme = @import("nvme");

const Cid = nvme.core.ids.Cid;
const CidAllocator = nvme.controller.queue.CidAllocator;
const DataPointers = nvme.core.prp.DataPointers;
const Nsid = nvme.core.ids.Nsid;
const Qid = nvme.core.ids.Qid;
const Sqe = nvme.commands.sqe.Sqe;

const doorbell = nvme.core.doorbell;
const ids = nvme.core.ids;
const nvm = nvme.commands.nvm;
const prp = nvme.core.prp;
const queue = nvme.controller.queue;
const registers = nvme.core.registers;
const testing = std.testing;

// SubmissionQueue substrate identical to test/controller/queue_test.zig: a
// depth-8 caller-owned ring, a CID bitmap wide enough for that depth, and a
// doorbell view over a scratch MMIO byte buffer. No completion queue is needed
// at this layer — the builders only reserve, stamp, and stage.
const sq_depth: u16 = 8;

const Substrate = struct {
    ring_backing: [sq_depth]Sqe,
    cid_words: [1]CidAllocator.Word,
    bar: [0x2000]u8 align(@alignOf(u64)),
    sq: queue.SubmissionQueue,

    fn init(self: *Substrate) !void {
        self.ring_backing = @splat(Sqe{});
        self.cid_words = @splat(0);
        self.bar = @splat(0);
        const regs = try registers.ControllerRegisters.at(&self.bar);
        const dbs = doorbell.Doorbells.fromRegisters(regs, zeroedCap());
        const ring = try stdx.dma.Buffer(Sqe).init(
            self.ring_backing[0..],
            stdx.addr.DmaAddr.fromInt(0x1000),
        );
        self.sq = try queue.SubmissionQueue.init(.{
            .qid = Qid.admin,
            .capacity = sq_depth,
            .ring = ring,
            .cid_words = self.cid_words[0..],
            .doorbell = dbs.submissionQueue(Qid.admin),
        });
    }
};

fn zeroedCap() registers.Cap {
    return .{
        .mqes = 0,
        .cqr = 0,
        .ams = 0,
        .to = 0,
        .dstrd = 0,
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

// Real DataPointers for a 4 KiB single-page payload. The DMA address is
// fabricated (host-side only, never dereferenced) so the test exercises the
// full `DataPointers.fromContiguous` composition and both PRP fields end up in
// the encoded SQE lane.
const PayloadFixture = struct {
    backing: [4096]u8 align(4096) = @splat(0),

    fn dataPointers(self: *PayloadFixture, dma_addr: u64) !DataPointers {
        const buf = try stdx.dma.Buffer(u8).init(
            self.backing[0..],
            stdx.addr.DmaAddr.fromInt(dma_addr),
        );
        const page_size = try prp.PageSize.fromBytes(4096);
        return try DataPointers.fromContiguous(.{
            .payload = buf,
            .page_size = page_size,
        });
    }
};

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

test "unit: nvm read encodes opcode 02h target NSID and SLBA in CDW10 CDW11" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0010_0000);

    const handle = try nvm.Read.encode(&sub.sq, .{
        .namespace_id = .from(0x0000_0007),
        .starting_lba = 0x0000_0000_1234_5678,
        .logical_block_count = 1,
        .data_pointers = dptr,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x02), slot.opcode());
    try testing.expectEqual(@as(u32, 0x0000_0007), slot.nsid().raw());
    try testing.expectEqual(@as(u32, 0x1234_5678), slot.cdw10());
    try testing.expectEqual(@as(u32, 0x0000_0000), slot.cdw11());
}

test "unit: nvm read encodes CDW12 NLB zero-based and LR FUA cleared on default" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0010_0000);

    const handle = try nvm.Read.encode(&sub.sq, .{
        .namespace_id = .from(1),
        .starting_lba = 0,
        .logical_block_count = 8,
        .data_pointers = dptr,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const decoded = nvm.Read.Cdw12.fromRaw(slot.cdw12());
    try testing.expectEqual(@as(u16, 7), decoded.nlb_zero_based);
    try testing.expectEqual(@as(u1, 0), decoded.limited_retry);
    try testing.expectEqual(@as(u1, 0), decoded.force_unit_access);
    try testing.expectEqual(@as(u4, 0), decoded.prinfo);
    try testing.expectEqual(@as(u1, 0), decoded.storage_tag_check);
}

test "unit: nvm read honors limited_retry true and force_unit_access true" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0010_0000);

    const handle = try nvm.Read.encode(&sub.sq, .{
        .namespace_id = .from(1),
        .starting_lba = 0,
        .logical_block_count = 1,
        .data_pointers = dptr,
        .limited_retry = true,
        .force_unit_access = true,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const decoded = nvm.Read.Cdw12.fromRaw(slot.cdw12());
    try testing.expectEqual(@as(u1, 1), decoded.limited_retry);
    try testing.expectEqual(@as(u1, 1), decoded.force_unit_access);
    try testing.expectEqual(@as(u16, 0), decoded.nlb_zero_based);
}

test "unit: nvm read encodes DPTR from Params.data_pointers" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0010_0000);

    const handle = try nvm.Read.encode(&sub.sq, .{
        .namespace_id = .from(1),
        .starting_lba = 0,
        .logical_block_count = 1,
        .data_pointers = dptr,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(dptr.prp1.raw(), slot.dptr().prp1.raw());
    try testing.expectEqual(dptr.prp2.raw(), slot.dptr().prp2.raw());
    // Sanity: a 4 KiB single-page payload has PRP1 = base and PRP2 = 0.
    try testing.expectEqual(@as(u64, 0x0000_0000_0010_0000), slot.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0), slot.dptr().prp2.raw());
}

test "unit: nvm read passes through metadata_pointer to Sqe.mptr" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0010_0000);

    const handle = try nvm.Read.encode(&sub.sq, .{
        .namespace_id = .from(1),
        .starting_lba = 0,
        .logical_block_count = 1,
        .data_pointers = dptr,
        .metadata_pointer = 0xDEAD_BEEF_0000_1000,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_0000_1000), slot.mptr());
}

test "unit: nvm read rejects Nsid.none" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0010_0000);

    try testing.expectError(error.InvalidNamespaceIdentifier, nvm.Read.encode(&sub.sq, .{
        .namespace_id = .none,
        .starting_lba = 0,
        .logical_block_count = 1,
        .data_pointers = dptr,
    }));
}

test "unit: nvm read rejects Nsid.broadcast" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0010_0000);

    try testing.expectError(error.InvalidNamespaceIdentifier, nvm.Read.encode(&sub.sq, .{
        .namespace_id = .broadcast,
        .starting_lba = 0,
        .logical_block_count = 1,
        .data_pointers = dptr,
    }));
}

test "unit: nvm read rejects logical_block_count 0 with InvalidLogicalBlockCount" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0010_0000);

    try testing.expectError(error.InvalidLogicalBlockCount, nvm.Read.encode(&sub.sq, .{
        .namespace_id = .from(1),
        .starting_lba = 0,
        .logical_block_count = 0,
        .data_pointers = dptr,
    }));
}

test "unit: nvm read encodes SLBA high half of a 64-bit LBA above 2^32" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0010_0000);

    const handle = try nvm.Read.encode(&sub.sq, .{
        .namespace_id = .from(1),
        .starting_lba = 0x0000_0001_0000_1234,
        .logical_block_count = 1,
        .data_pointers = dptr,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u32, 0x0000_1234), slot.cdw10());
    try testing.expectEqual(@as(u32, 0x0000_0001), slot.cdw11());
}

test "unit: nvm Read.Cdw12 fromRaw round-trips through raw" {
    // Every field non-default so a bit-shift bug on any lane shows up.
    const original: nvm.Read.Cdw12 = .{
        .nlb_zero_based = 0xABCD,
        .storage_tag_check = 1,
        .prinfo = 0xB,
        .force_unit_access = 1,
        .limited_retry = 1,
    };
    const round = nvm.Read.Cdw12.fromRaw(original.raw());
    try testing.expectEqual(original.nlb_zero_based, round.nlb_zero_based);
    try testing.expectEqual(original.storage_tag_check, round.storage_tag_check);
    try testing.expectEqual(original.prinfo, round.prinfo);
    try testing.expectEqual(original.force_unit_access, round.force_unit_access);
    try testing.expectEqual(original.limited_retry, round.limited_retry);
    try testing.expectEqual(original.raw(), round.raw());

    // Reserved holes stay zero on the wire.
    try testing.expectEqual(@as(u8, 0), round.reserved_16);
    try testing.expectEqual(@as(u1, 0), round.reserved_25);
}

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

test "unit: nvm write encodes opcode 01h target NSID and SLBA in CDW10 CDW11" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0020_0000);

    const handle = try nvm.Write.encode(&sub.sq, .{
        .namespace_id = .from(0x0000_00AB),
        .starting_lba = 0x0000_0000_89AB_CDEF,
        .logical_block_count = 1,
        .data_pointers = dptr,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x01), slot.opcode());
    try testing.expectEqual(@as(u32, 0x0000_00AB), slot.nsid().raw());
    try testing.expectEqual(@as(u32, 0x89AB_CDEF), slot.cdw10());
    try testing.expectEqual(@as(u32, 0x0000_0000), slot.cdw11());
}

test "unit: nvm write encodes CDW12 NLB zero-based and LR FUA cleared on default with DTYPE zero" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0020_0000);

    const handle = try nvm.Write.encode(&sub.sq, .{
        .namespace_id = .from(1),
        .starting_lba = 0,
        .logical_block_count = 16,
        .data_pointers = dptr,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const decoded = nvm.Write.Cdw12.fromRaw(slot.cdw12());
    try testing.expectEqual(@as(u16, 15), decoded.nlb_zero_based);
    try testing.expectEqual(@as(u1, 0), decoded.limited_retry);
    try testing.expectEqual(@as(u1, 0), decoded.force_unit_access);
    try testing.expectEqual(@as(u4, 0), decoded.directive_type);
    try testing.expectEqual(@as(u4, 0), decoded.prinfo);
    try testing.expectEqual(@as(u1, 0), decoded.storage_tag_check);
}

test "unit: nvm write honors limited_retry true and force_unit_access true" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0020_0000);

    const handle = try nvm.Write.encode(&sub.sq, .{
        .namespace_id = .from(1),
        .starting_lba = 0,
        .logical_block_count = 1,
        .data_pointers = dptr,
        .limited_retry = true,
        .force_unit_access = true,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const decoded = nvm.Write.Cdw12.fromRaw(slot.cdw12());
    try testing.expectEqual(@as(u1, 1), decoded.limited_retry);
    try testing.expectEqual(@as(u1, 1), decoded.force_unit_access);
}

test "unit: nvm write encodes DPTR from Params.data_pointers" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0020_0000);

    const handle = try nvm.Write.encode(&sub.sq, .{
        .namespace_id = .from(1),
        .starting_lba = 0,
        .logical_block_count = 1,
        .data_pointers = dptr,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(dptr.prp1.raw(), slot.dptr().prp1.raw());
    try testing.expectEqual(dptr.prp2.raw(), slot.dptr().prp2.raw());
    try testing.expectEqual(@as(u64, 0x0000_0000_0020_0000), slot.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0), slot.dptr().prp2.raw());
}

test "unit: nvm write passes through metadata_pointer to Sqe.mptr" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0020_0000);

    const handle = try nvm.Write.encode(&sub.sq, .{
        .namespace_id = .from(1),
        .starting_lba = 0,
        .logical_block_count = 1,
        .data_pointers = dptr,
        .metadata_pointer = 0xDEAD_BEEF_0000_1000,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_0000_1000), slot.mptr());
}

test "unit: nvm write rejects Nsid.none" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0020_0000);

    try testing.expectError(error.InvalidNamespaceIdentifier, nvm.Write.encode(&sub.sq, .{
        .namespace_id = .none,
        .starting_lba = 0,
        .logical_block_count = 1,
        .data_pointers = dptr,
    }));
}

test "unit: nvm write rejects Nsid.broadcast" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0020_0000);

    try testing.expectError(error.InvalidNamespaceIdentifier, nvm.Write.encode(&sub.sq, .{
        .namespace_id = .broadcast,
        .starting_lba = 0,
        .logical_block_count = 1,
        .data_pointers = dptr,
    }));
}

test "unit: nvm write rejects logical_block_count 0 with InvalidLogicalBlockCount" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0020_0000);

    try testing.expectError(error.InvalidLogicalBlockCount, nvm.Write.encode(&sub.sq, .{
        .namespace_id = .from(1),
        .starting_lba = 0,
        .logical_block_count = 0,
        .data_pointers = dptr,
    }));
}

test "unit: nvm Write.Cdw12 fromRaw round-trips through raw with DTYPE preserved" {
    // Every field non-default, DTYPE at 0x0F to cover all four bits of the
    // Write-only lane; the round-trip proves DTYPE and every neighbouring
    // field survive `raw()`/`fromRaw()`.
    const original: nvm.Write.Cdw12 = .{
        .nlb_zero_based = 0x1234,
        .directive_type = 0x0F,
        .storage_tag_check = 1,
        .prinfo = 0x5,
        .force_unit_access = 1,
        .limited_retry = 1,
    };
    const round = nvm.Write.Cdw12.fromRaw(original.raw());
    try testing.expectEqual(original.nlb_zero_based, round.nlb_zero_based);
    try testing.expectEqual(original.directive_type, round.directive_type);
    try testing.expectEqual(original.storage_tag_check, round.storage_tag_check);
    try testing.expectEqual(original.prinfo, round.prinfo);
    try testing.expectEqual(original.force_unit_access, round.force_unit_access);
    try testing.expectEqual(original.limited_retry, round.limited_retry);
    try testing.expectEqual(original.raw(), round.raw());

    // Reserved holes stay zero on the wire.
    try testing.expectEqual(@as(u4, 0), round.reserved_16);
    try testing.expectEqual(@as(u1, 0), round.reserved_25);
}

// ---------------------------------------------------------------------------
// Flush
// ---------------------------------------------------------------------------

test "unit: nvm flush encodes opcode 00h target NSID and every other lane zero" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try nvm.Flush.encode(&sub.sq, .{
        .namespace_id = .from(0x0000_0042),
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x00), slot.opcode());
    try testing.expectEqual(@as(u32, 0x0000_0042), slot.nsid().raw());
    try testing.expectEqual(@as(u64, 0), slot.mptr());
    try testing.expectEqual(@as(u64, 0), slot.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0), slot.dptr().prp2.raw());
    try testing.expectEqual(@as(u32, 0), slot.cdw10());
    try testing.expectEqual(@as(u32, 0), slot.cdw11());
    try testing.expectEqual(@as(u32, 0), slot.cdw12());
    try testing.expectEqual(@as(u32, 0), slot.cdw13());
    try testing.expectEqual(@as(u32, 0), slot.cdw14());
    try testing.expectEqual(@as(u32, 0), slot.cdw15());
}

test "unit: nvm flush accepts Nsid.broadcast" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try nvm.Flush.encode(&sub.sq, .{
        .namespace_id = .broadcast,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), slot.nsid().raw());
    try testing.expectEqual(@as(u8, 0x00), slot.opcode());
}

test "unit: nvm flush rejects Nsid.none" {
    var sub: Substrate = undefined;
    try sub.init();

    try testing.expectError(error.InvalidNamespaceIdentifier, nvm.Flush.encode(&sub.sq, .{
        .namespace_id = .none,
    }));
}

// ---------------------------------------------------------------------------
// Roundtrips
// ---------------------------------------------------------------------------

test "roundtrip: nvm read encoded slot decodes through Sqe accessors for opcode nsid cdw10 cdw11 cdw12 dptr" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0030_0000);

    const params: nvm.Read.Params = .{
        .namespace_id = .from(0x0000_0055),
        .starting_lba = 0x0000_0002_1122_3344,
        .logical_block_count = 4,
        .data_pointers = dptr,
        .limited_retry = true,
        .force_unit_access = true,
    };
    const handle = try nvm.Read.encode(&sub.sq, params);

    // Reinterpret the slot's bytes through Sqe.validate and read every field
    // referenced by the bullet through the *const Sqe decoding accessors.
    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    var bytes: [64]u8 align(8) = undefined;
    @memcpy(&bytes, std.mem.asBytes(slot));
    const view = try Sqe.validate(&bytes);

    try testing.expectEqual(@as(u8, 0x02), view.opcode());
    try testing.expectEqual(params.namespace_id.raw(), view.nsid().raw());
    try testing.expectEqual(@as(u32, 0x1122_3344), view.cdw10());
    try testing.expectEqual(@as(u32, 0x0000_0002), view.cdw11());

    const decoded_cdw12 = nvm.Read.Cdw12.fromRaw(view.cdw12());
    try testing.expectEqual(@as(u16, 3), decoded_cdw12.nlb_zero_based);
    try testing.expectEqual(@as(u1, 1), decoded_cdw12.limited_retry);
    try testing.expectEqual(@as(u1, 1), decoded_cdw12.force_unit_access);

    try testing.expectEqual(dptr.prp1.raw(), view.dptr().prp1.raw());
    try testing.expectEqual(dptr.prp2.raw(), view.dptr().prp2.raw());

    // Handle CID matches the encoded CDW0 CID lane.
    try testing.expectEqual(handle.command_id.raw(), view.cid().raw());
}

test "roundtrip: nvm write encoded slot decodes through Sqe accessors for opcode nsid cdw10 cdw11 cdw12 dptr" {
    var sub: Substrate = undefined;
    try sub.init();
    var payload: PayloadFixture = .{};
    const dptr = try payload.dataPointers(0x0000_0000_0040_0000);

    const params: nvm.Write.Params = .{
        .namespace_id = .from(0x0000_0099),
        .starting_lba = 0x0000_0003_AABB_CCDD,
        .logical_block_count = 32,
        .data_pointers = dptr,
        .limited_retry = false,
        .force_unit_access = true,
    };
    const handle = try nvm.Write.encode(&sub.sq, params);

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    var bytes: [64]u8 align(8) = undefined;
    @memcpy(&bytes, std.mem.asBytes(slot));
    const view = try Sqe.validate(&bytes);

    try testing.expectEqual(@as(u8, 0x01), view.opcode());
    try testing.expectEqual(params.namespace_id.raw(), view.nsid().raw());
    try testing.expectEqual(@as(u32, 0xAABB_CCDD), view.cdw10());
    try testing.expectEqual(@as(u32, 0x0000_0003), view.cdw11());

    const decoded_cdw12 = nvm.Write.Cdw12.fromRaw(view.cdw12());
    try testing.expectEqual(@as(u16, 31), decoded_cdw12.nlb_zero_based);
    try testing.expectEqual(@as(u1, 0), decoded_cdw12.limited_retry);
    try testing.expectEqual(@as(u1, 1), decoded_cdw12.force_unit_access);
    try testing.expectEqual(@as(u4, 0), decoded_cdw12.directive_type);

    try testing.expectEqual(dptr.prp1.raw(), view.dptr().prp1.raw());
    try testing.expectEqual(dptr.prp2.raw(), view.dptr().prp2.raw());

    try testing.expectEqual(handle.command_id.raw(), view.cid().raw());
}

test "roundtrip: nvm flush encoded slot decodes through Sqe accessors for opcode and NSID with cdw10..cdw15 zero" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try nvm.Flush.encode(&sub.sq, .{
        .namespace_id = .from(0x0000_0123),
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    var bytes: [64]u8 align(8) = undefined;
    @memcpy(&bytes, std.mem.asBytes(slot));
    const view = try Sqe.validate(&bytes);

    try testing.expectEqual(@as(u8, 0x00), view.opcode());
    try testing.expectEqual(@as(u32, 0x0000_0123), view.nsid().raw());
    try testing.expectEqual(@as(u32, 0), view.cdw10());
    try testing.expectEqual(@as(u32, 0), view.cdw11());
    try testing.expectEqual(@as(u32, 0), view.cdw12());
    try testing.expectEqual(@as(u32, 0), view.cdw13());
    try testing.expectEqual(@as(u32, 0), view.cdw14());
    try testing.expectEqual(@as(u32, 0), view.cdw15());
    try testing.expectEqual(handle.command_id.raw(), view.cid().raw());
}
