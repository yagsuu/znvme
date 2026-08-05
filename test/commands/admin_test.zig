//! Tests for src/commands/admin.zig. Spec: docs/specs/commands/admin.md.

const std = @import("std");

const stdx = @import("stdx");

const nvme = @import("nvme");

const Cid = nvme.core.ids.Cid;
const CidAllocator = nvme.controller.queue.CidAllocator;
const DataPointers = nvme.core.prp.DataPointers;
const IoQueueBase = nvme.core.prp.IoQueueBase;
const Nsid = nvme.core.ids.Nsid;
const Qid = nvme.core.ids.Qid;
const Sqe = nvme.commands.sqe.Sqe;

const admin = nvme.commands.admin;
const doorbell = nvme.core.doorbell;
const ids = nvme.core.ids;
const prp = nvme.core.prp;
const queue = nvme.controller.queue;
const registers = nvme.core.registers;
const testing = std.testing;

// SubmissionQueue substrate mirroring test/controller/queue_test.zig and
// test/commands/nvm_test.zig: caller-owned depth-8 ring, a CID bitmap wide
// enough for that depth, and a doorbell view over a scratch MMIO byte buffer.
// No completion queue is needed at this layer — the builders only reserve,
// stamp, and stage.
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
            stdx.addr.DMAAddr.fromInt(0x1000),
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

// Page-aligned DPTR/IoQueueBase substrate. The DMA address is fabricated —
// nothing here is dereferenced by the host tests — but page alignment is real
// so `DataPointers.fromContiguous` / `IoQueueBase.fromContiguous` accept it.
const PageFixture = struct {
    backing: [4096]u8 align(4096) = @splat(0),

    fn dataPointers(self: *PageFixture, dma_addr: u64) !DataPointers {
        const buf = try stdx.dma.Buffer(u8).init(
            self.backing[0..],
            stdx.addr.DMAAddr.fromInt(dma_addr),
        );
        const page_size = try prp.PageSize.fromBytes(4096);
        return try DataPointers.fromContiguous(.{
            .payload = buf,
            .page_size = page_size,
        });
    }

    fn ioQueueBase(self: *PageFixture, dma_addr: u64) !IoQueueBase {
        const buf = try stdx.dma.Buffer(u8).init(
            self.backing[0..],
            stdx.addr.DMAAddr.fromInt(dma_addr),
        );
        const page_size = try prp.PageSize.fromBytes(4096);
        return try IoQueueBase.fromContiguous(buf, page_size);
    }
};

// ---------------------------------------------------------------------------
// Identify
// ---------------------------------------------------------------------------

test "unit: identify controller stamps opcode 06h nsid zero and cdw10 CNS 01h" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const dptr = try page.dataPointers(0x0000_0000_1000_0000);

    const handle = try admin.Identify.controller(&sub.sq, .{ .dptr = dptr });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x06), slot.opcode());
    try testing.expectEqual(@as(u32, 0), slot.nsid().raw());
    const cdw10 = admin.Identify.Cdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(admin.Cns.controller, cdw10.cns);
    try testing.expectEqual(@as(u8, 0x01), @intFromEnum(cdw10.cns));
}

test "unit: identify namespace stamps opcode 06h nsid target and cdw10 CNS 00h" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const dptr = try page.dataPointers(0x0000_0000_1000_0000);

    const handle = try admin.Identify.namespace(&sub.sq, .{
        .namespace_id = .from(0x0000_0042),
        .dptr = dptr,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x06), slot.opcode());
    try testing.expectEqual(@as(u32, 0x0000_0042), slot.nsid().raw());
    const cdw10 = admin.Identify.Cdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(admin.Cns.namespace, cdw10.cns);
    try testing.expectEqual(@as(u8, 0x00), @intFromEnum(cdw10.cns));
}

test "unit: identify namespace rejects Nsid.none" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const dptr = try page.dataPointers(0x0000_0000_1000_0000);

    try testing.expectError(
        admin.Error.InvalidNamespaceIdentifier,
        admin.Identify.namespace(&sub.sq, .{ .namespace_id = .none, .dptr = dptr }),
    );
}

test "unit: identify namespace rejects Nsid.broadcast" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const dptr = try page.dataPointers(0x0000_0000_1000_0000);

    try testing.expectError(
        admin.Error.InvalidNamespaceIdentifier,
        admin.Identify.namespace(&sub.sq, .{ .namespace_id = .broadcast, .dptr = dptr }),
    );
}

test "unit: identify active namespace list stamps CNS 02h with starting NSID zero by default" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const dptr = try page.dataPointers(0x0000_0000_1000_0000);

    const handle = try admin.Identify.activeNamespaceList(&sub.sq, .{ .dptr = dptr });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const cdw10 = admin.Identify.Cdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(admin.Cns.active_namespace_id_list, cdw10.cns);
    try testing.expectEqual(@as(u8, 0x02), @intFromEnum(cdw10.cns));
    try testing.expectEqual(@as(u32, 0), slot.nsid().raw());
}

test "unit: identify Cdw10 encodes CNS in bits 7:0 with reserved and controller_id zero on default" {
    const value: admin.Identify.Cdw10 = .{ .cns = .controller };
    const raw = value.raw();
    try testing.expectEqual(@as(u32, 0x0000_0001), raw);
    try testing.expectEqual(@as(u8, 0), value.reserved_8);
    try testing.expectEqual(@as(u16, 0), value.controller_id);
}

test "roundtrip: identify controller encode then Sqe accessors decode opcode nsid cdw10 dptr" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const dptr = try page.dataPointers(0x0000_0000_1000_0000);

    const handle = try admin.Identify.controller(&sub.sq, .{ .dptr = dptr });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x06), slot.opcode());
    try testing.expectEqual(@as(u32, 0), slot.nsid().raw());
    const decoded_cdw10 = admin.Identify.Cdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(admin.Cns.controller, decoded_cdw10.cns);
    try testing.expectEqual(@as(u8, 0), decoded_cdw10.reserved_8);
    try testing.expectEqual(@as(u16, 0), decoded_cdw10.controller_id);
    try testing.expectEqual(dptr.prp1.raw(), slot.dptr().prp1.raw());
    try testing.expectEqual(dptr.prp2.raw(), slot.dptr().prp2.raw());
    try testing.expectEqual(@as(u64, 0x0000_0000_1000_0000), slot.dptr().prp1.raw());
}

test "unit: identify Cdw10 fromRaw round-trips through raw" {
    const original: admin.Identify.Cdw10 = .{
        .cns = .active_namespace_id_list,
        .controller_id = 0xBEEF,
    };
    const round = admin.Identify.Cdw10.fromRaw(original.raw());
    try testing.expectEqual(original.cns, round.cns);
    try testing.expectEqual(original.controller_id, round.controller_id);
    try testing.expectEqual(original.raw(), round.raw());
    try testing.expectEqual(@as(u8, 0), round.reserved_8);
}

// ---------------------------------------------------------------------------
// Create I/O Completion Queue
// ---------------------------------------------------------------------------

test "unit: create io cq encodes opcode 05h nsid zero and cdw10 qid qsize zero-based" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_2000_0000);

    const handle = try admin.CreateIoCompletionQueue.encode(&sub.sq, .{
        .qid = .from(3),
        .queue_size = 64,
        .base = base,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x05), slot.opcode());
    try testing.expectEqual(@as(u32, 0), slot.nsid().raw());
    const cdw10 = admin.CreateIoCompletionQueue.Cdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(@as(u16, 3), cdw10.qid);
    try testing.expectEqual(@as(u16, 63), cdw10.qsize_zero_based);
}

test "unit: create io cq encodes cdw11 pc 1 ien 0 iv default" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_2000_0000);

    const handle = try admin.CreateIoCompletionQueue.encode(&sub.sq, .{
        .qid = .from(1),
        .queue_size = 2,
        .base = base,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const cdw11 = admin.CreateIoCompletionQueue.Cdw11.fromRaw(slot.cdw11());
    try testing.expectEqual(@as(u1, 1), cdw11.physically_contiguous);
    try testing.expectEqual(@as(u1, 0), cdw11.interrupts_enabled);
    try testing.expectEqual(@as(u16, 0), cdw11.interrupt_vector);
}

test "unit: create io cq honors interrupts_enabled true and interrupt_vector value" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_2000_0000);

    const handle = try admin.CreateIoCompletionQueue.encode(&sub.sq, .{
        .qid = .from(1),
        .queue_size = 2,
        .base = base,
        .interrupts_enabled = true,
        .interrupt_vector = 0x1234,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const cdw11 = admin.CreateIoCompletionQueue.Cdw11.fromRaw(slot.cdw11());
    try testing.expectEqual(@as(u1, 1), cdw11.physically_contiguous);
    try testing.expectEqual(@as(u1, 1), cdw11.interrupts_enabled);
    try testing.expectEqual(@as(u16, 0x1234), cdw11.interrupt_vector);
}

test "unit: create io cq rejects Qid.admin on qid" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_2000_0000);

    try testing.expectError(
        admin.Error.InvalidQueueIdentifier,
        admin.CreateIoCompletionQueue.encode(&sub.sq, .{
            .qid = Qid.admin,
            .queue_size = 2,
            .base = base,
        }),
    );
}

test "unit: create io cq rejects Qid.reserved_max on qid" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_2000_0000);

    try testing.expectError(
        admin.Error.InvalidQueueIdentifier,
        admin.CreateIoCompletionQueue.encode(&sub.sq, .{
            .qid = Qid.reserved_max,
            .queue_size = 2,
            .base = base,
        }),
    );
}

test "unit: create io cq rejects queue_size below 2 with InvalidQueueSize" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_2000_0000);

    try testing.expectError(
        admin.Error.InvalidQueueSize,
        admin.CreateIoCompletionQueue.encode(&sub.sq, .{
            .qid = .from(1),
            .queue_size = 1,
            .base = base,
        }),
    );
}

test "unit: create io cq encodes prp1 from IoQueueBase and prp2 zero" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_2000_0000);

    const handle = try admin.CreateIoCompletionQueue.encode(&sub.sq, .{
        .qid = .from(1),
        .queue_size = 4,
        .base = base,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(base.prp1.raw(), slot.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0x0000_0000_2000_0000), slot.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0), slot.dptr().prp2.raw());
}

test "unit: create io cq Cdw10 fromRaw round-trips through raw" {
    const original: admin.CreateIoCompletionQueue.Cdw10 = .{
        .qid = 0xABCD,
        .qsize_zero_based = 0x1234,
    };
    const round = admin.CreateIoCompletionQueue.Cdw10.fromRaw(original.raw());
    try testing.expectEqual(original.qid, round.qid);
    try testing.expectEqual(original.qsize_zero_based, round.qsize_zero_based);
    try testing.expectEqual(original.raw(), round.raw());
}

test "unit: create io cq Cdw11 fromRaw round-trips through raw" {
    const original: admin.CreateIoCompletionQueue.Cdw11 = .{
        .physically_contiguous = 1,
        .interrupts_enabled = 1,
        .interrupt_vector = 0xC0DE,
    };
    const round = admin.CreateIoCompletionQueue.Cdw11.fromRaw(original.raw());
    try testing.expectEqual(original.physically_contiguous, round.physically_contiguous);
    try testing.expectEqual(original.interrupts_enabled, round.interrupts_enabled);
    try testing.expectEqual(original.interrupt_vector, round.interrupt_vector);
    try testing.expectEqual(original.raw(), round.raw());
    try testing.expectEqual(@as(u14, 0), round.reserved_2);
}

// ---------------------------------------------------------------------------
// Create I/O Submission Queue
// ---------------------------------------------------------------------------

test "unit: create io sq encodes opcode 01h nsid zero and cdw10 qid qsize zero-based" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_3000_0000);

    const handle = try admin.CreateIoSubmissionQueue.encode(&sub.sq, .{
        .qid = .from(5),
        .queue_size = 128,
        .base = base,
        .cqid = .from(3),
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x01), slot.opcode());
    try testing.expectEqual(@as(u32, 0), slot.nsid().raw());
    const cdw10 = admin.CreateIoSubmissionQueue.Cdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(@as(u16, 5), cdw10.qid);
    try testing.expectEqual(@as(u16, 127), cdw10.qsize_zero_based);
}

test "unit: create io sq encodes cdw11 pc 1 priority default medium cqid" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_3000_0000);

    const handle = try admin.CreateIoSubmissionQueue.encode(&sub.sq, .{
        .qid = .from(1),
        .queue_size = 2,
        .base = base,
        .cqid = .from(7),
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const cdw11 = admin.CreateIoSubmissionQueue.Cdw11.fromRaw(slot.cdw11());
    try testing.expectEqual(@as(u1, 1), cdw11.physically_contiguous);
    try testing.expectEqual(admin.CreateIoSubmissionQueue.Priority.medium, cdw11.priority);
    try testing.expectEqual(@as(u16, 7), cdw11.completion_queue_id);
}

test "unit: create io sq encodes cdw12 nvm_set_id" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_3000_0000);

    const handle = try admin.CreateIoSubmissionQueue.encode(&sub.sq, .{
        .qid = .from(1),
        .queue_size = 2,
        .base = base,
        .cqid = .from(1),
        .nvm_set_id = 0xABCD,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const cdw12 = admin.CreateIoSubmissionQueue.Cdw12.fromRaw(slot.cdw12());
    try testing.expectEqual(@as(u16, 0xABCD), cdw12.nvm_set_id);
    try testing.expectEqual(@as(u16, 0), cdw12.reserved_16);
}

test "unit: create io sq honors priority urgent high low" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_3000_0000);

    inline for ([_]admin.CreateIoSubmissionQueue.Priority{ .urgent, .high, .low }) |prio| {
        const handle = try admin.CreateIoSubmissionQueue.encode(&sub.sq, .{
            .qid = .from(1),
            .queue_size = 2,
            .base = base,
            .cqid = .from(1),
            .priority = prio,
        });
        const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
        const cdw11 = admin.CreateIoSubmissionQueue.Cdw11.fromRaw(slot.cdw11());
        try testing.expectEqual(prio, cdw11.priority);
    }
}

test "unit: create io sq rejects Qid.admin on qid" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_3000_0000);

    try testing.expectError(
        admin.Error.InvalidQueueIdentifier,
        admin.CreateIoSubmissionQueue.encode(&sub.sq, .{
            .qid = Qid.admin,
            .queue_size = 2,
            .base = base,
            .cqid = .from(1),
        }),
    );
}

test "unit: create io sq rejects Qid.admin on cqid" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_3000_0000);

    try testing.expectError(
        admin.Error.InvalidQueueIdentifier,
        admin.CreateIoSubmissionQueue.encode(&sub.sq, .{
            .qid = .from(1),
            .queue_size = 2,
            .base = base,
            .cqid = Qid.admin,
        }),
    );
}

test "unit: create io sq rejects Qid.reserved_max on cqid" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_3000_0000);

    try testing.expectError(
        admin.Error.InvalidQueueIdentifier,
        admin.CreateIoSubmissionQueue.encode(&sub.sq, .{
            .qid = .from(1),
            .queue_size = 2,
            .base = base,
            .cqid = Qid.reserved_max,
        }),
    );
}

test "unit: create io sq encodes prp1 from IoQueueBase and prp2 zero" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_3000_0000);

    const handle = try admin.CreateIoSubmissionQueue.encode(&sub.sq, .{
        .qid = .from(1),
        .queue_size = 4,
        .base = base,
        .cqid = .from(1),
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(base.prp1.raw(), slot.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0x0000_0000_3000_0000), slot.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0), slot.dptr().prp2.raw());
}

test "unit: create io sq rejects queue_size below 2 with InvalidQueueSize" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_3000_0000);

    try testing.expectError(
        admin.Error.InvalidQueueSize,
        admin.CreateIoSubmissionQueue.encode(&sub.sq, .{
            .qid = .from(1),
            .queue_size = 1,
            .base = base,
            .cqid = .from(1),
        }),
    );
}

test "unit: create io sq Cdw10 fromRaw round-trips through raw" {
    const original: admin.CreateIoSubmissionQueue.Cdw10 = .{
        .qid = 0xFEED,
        .qsize_zero_based = 0x0FF0,
    };
    const round = admin.CreateIoSubmissionQueue.Cdw10.fromRaw(original.raw());
    try testing.expectEqual(original.qid, round.qid);
    try testing.expectEqual(original.qsize_zero_based, round.qsize_zero_based);
    try testing.expectEqual(original.raw(), round.raw());
}

test "unit: create io sq Cdw11 fromRaw round-trips through raw" {
    const original: admin.CreateIoSubmissionQueue.Cdw11 = .{
        .physically_contiguous = 1,
        .priority = .high,
        .completion_queue_id = 0xC0DE,
    };
    const round = admin.CreateIoSubmissionQueue.Cdw11.fromRaw(original.raw());
    try testing.expectEqual(original.physically_contiguous, round.physically_contiguous);
    try testing.expectEqual(original.priority, round.priority);
    try testing.expectEqual(original.completion_queue_id, round.completion_queue_id);
    try testing.expectEqual(original.raw(), round.raw());
    try testing.expectEqual(@as(u13, 0), round.reserved_3);
}

test "unit: create io sq Cdw12 fromRaw round-trips through raw" {
    const original: admin.CreateIoSubmissionQueue.Cdw12 = .{ .nvm_set_id = 0xBEEF };
    const round = admin.CreateIoSubmissionQueue.Cdw12.fromRaw(original.raw());
    try testing.expectEqual(original.nvm_set_id, round.nvm_set_id);
    try testing.expectEqual(original.raw(), round.raw());
    try testing.expectEqual(@as(u16, 0), round.reserved_16);
}

// ---------------------------------------------------------------------------
// Delete I/O SQ / CQ
// ---------------------------------------------------------------------------

test "unit: delete io sq encodes opcode 00h and cdw10 qid" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try admin.DeleteIoSubmissionQueue.encode(&sub.sq, .{ .qid = .from(5) });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x00), slot.opcode());
    const cdw10 = admin.DeleteQueueCdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(@as(u16, 5), cdw10.qid);
    try testing.expectEqual(@as(u16, 0), cdw10.reserved_16);
}

test "unit: delete io cq encodes opcode 04h and cdw10 qid" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try admin.DeleteIoCompletionQueue.encode(&sub.sq, .{ .qid = .from(9) });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x04), slot.opcode());
    const cdw10 = admin.DeleteQueueCdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(@as(u16, 9), cdw10.qid);
    try testing.expectEqual(@as(u16, 0), cdw10.reserved_16);
}

test "unit: delete io sq rejects Qid.admin on qid" {
    var sub: Substrate = undefined;
    try sub.init();

    try testing.expectError(
        admin.Error.InvalidQueueIdentifier,
        admin.DeleteIoSubmissionQueue.encode(&sub.sq, .{ .qid = Qid.admin }),
    );
}

test "unit: delete io cq rejects Qid.reserved_max on qid" {
    var sub: Substrate = undefined;
    try sub.init();

    try testing.expectError(
        admin.Error.InvalidQueueIdentifier,
        admin.DeleteIoCompletionQueue.encode(&sub.sq, .{ .qid = Qid.reserved_max }),
    );
}

test "unit: delete queue Cdw10 fromRaw round-trips through raw" {
    const original: admin.DeleteQueueCdw10 = .{ .qid = 0xABCD };
    const round = admin.DeleteQueueCdw10.fromRaw(original.raw());
    try testing.expectEqual(original.qid, round.qid);
    try testing.expectEqual(original.raw(), round.raw());
    try testing.expectEqual(@as(u16, 0), round.reserved_16);
}

// ---------------------------------------------------------------------------
// Abort
// ---------------------------------------------------------------------------

test "unit: abort encodes opcode 08h nsid zero and cdw10 sqid cid" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try admin.Abort.encode(&sub.sq, .{
        .sqid = .from(3),
        .cid = .from(0x1234),
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x08), slot.opcode());
    try testing.expectEqual(@as(u32, 0), slot.nsid().raw());
    const cdw10 = admin.Abort.Cdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(@as(u16, 3), cdw10.sqid);
    try testing.expectEqual(@as(u16, 0x1234), cdw10.cid);
}

test "unit: abort accepts Qid.admin as sqid" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try admin.Abort.encode(&sub.sq, .{
        .sqid = Qid.admin,
        .cid = .from(7),
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const cdw10 = admin.Abort.Cdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(@as(u16, 0), cdw10.sqid);
    try testing.expectEqual(@as(u16, 7), cdw10.cid);
}

test "unit: abort rejects Qid.reserved_max as sqid" {
    var sub: Substrate = undefined;
    try sub.init();

    try testing.expectError(
        admin.Error.InvalidQueueIdentifier,
        admin.Abort.encode(&sub.sq, .{ .sqid = Qid.reserved_max, .cid = .from(0) }),
    );
}

test "unit: abort Cdw10 fromRaw round-trips through raw" {
    const original: admin.Abort.Cdw10 = .{ .sqid = 0xBEEF, .cid = 0xC0DE };
    const round = admin.Abort.Cdw10.fromRaw(original.raw());
    try testing.expectEqual(original.sqid, round.sqid);
    try testing.expectEqual(original.cid, round.cid);
    try testing.expectEqual(original.raw(), round.raw());
}

// ---------------------------------------------------------------------------
// Number of Queues
// ---------------------------------------------------------------------------

test "unit: number of queues set encodes opcode 09h fid 07h save 0" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try admin.NumberOfQueues.set(&sub.sq, .{
        .requested = .{ .submission_queues = 4, .completion_queues = 4 },
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x09), slot.opcode());
    const cdw10 = admin.NumberOfQueues.SetCdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(admin.Fid.number_of_queues, cdw10.fid);
    try testing.expectEqual(@as(u8, 0x07), @intFromEnum(cdw10.fid));
    try testing.expectEqual(@as(u1, 0), cdw10.save);
}

test "unit: number of queues set encodes cdw11 nsqr ncqr zero-based" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try admin.NumberOfQueues.set(&sub.sq, .{
        .requested = .{ .submission_queues = 8, .completion_queues = 4 },
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const cdw11 = admin.NumberOfQueues.RequestCdw11.fromRaw(slot.cdw11());
    try testing.expectEqual(@as(u16, 7), cdw11.nsqr_zero_based);
    try testing.expectEqual(@as(u16, 3), cdw11.ncqr_zero_based);
}

test "unit: number of queues get encodes opcode 0Ah fid 07h select current" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try admin.NumberOfQueues.get(&sub.sq);

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u8, 0x0A), slot.opcode());
    const cdw10 = admin.NumberOfQueues.GetCdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(admin.Fid.number_of_queues, cdw10.fid);
    try testing.expectEqual(@as(u8, 0x07), @intFromEnum(cdw10.fid));
    try testing.expectEqual(admin.FeatureSelect.current, cdw10.select);
}

test "unit: number of queues get encodes empty cdw11 zero" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try admin.NumberOfQueues.get(&sub.sq);

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    try testing.expectEqual(@as(u32, 0), slot.cdw11());
}

test "unit: number of queues ResponseDw0.fromRaw decodes nsqa ncqa zero-based" {
    // NSQA in bits 15:0, NCQA in bits 31:16 — little-endian packed struct.
    const raw: u32 = (@as(u32, 0x0003) << 16) | @as(u32, 0x0007);
    const decoded = admin.NumberOfQueues.ResponseDw0.fromRaw(raw);
    try testing.expectEqual(@as(u16, 7), decoded.nsqa_zero_based);
    try testing.expectEqual(@as(u16, 3), decoded.ncqa_zero_based);
    try testing.expectEqual(raw, decoded.raw());
}

test "unit: number of queues ResponseDw0.allocated maps zero-based to one-based" {
    const decoded: admin.NumberOfQueues.ResponseDw0 = .{
        .nsqa_zero_based = 7,
        .ncqa_zero_based = 3,
    };
    const allocated = decoded.allocated();
    try testing.expectEqual(@as(u16, 8), allocated.submission_queues);
    try testing.expectEqual(@as(u16, 4), allocated.completion_queues);
}

test "unit: number of queues set rejects requested submission_queues 0 with InvalidQueueCount" {
    var sub: Substrate = undefined;
    try sub.init();

    try testing.expectError(
        admin.Error.InvalidQueueCount,
        admin.NumberOfQueues.set(&sub.sq, .{
            .requested = .{ .submission_queues = 0, .completion_queues = 1 },
        }),
    );
}

test "unit: number of queues set rejects requested completion_queues 0 with InvalidQueueCount" {
    var sub: Substrate = undefined;
    try sub.init();

    try testing.expectError(
        admin.Error.InvalidQueueCount,
        admin.NumberOfQueues.set(&sub.sq, .{
            .requested = .{ .submission_queues = 1, .completion_queues = 0 },
        }),
    );
}

test "unit: number of queues SetCdw10 fromRaw round-trips through raw" {
    const original: admin.NumberOfQueues.SetCdw10 = .{
        .fid = .number_of_queues,
        .save = 1,
    };
    const round = admin.NumberOfQueues.SetCdw10.fromRaw(original.raw());
    try testing.expectEqual(original.fid, round.fid);
    try testing.expectEqual(original.save, round.save);
    try testing.expectEqual(original.raw(), round.raw());
    try testing.expectEqual(@as(u23, 0), round.reserved_8);
}

test "unit: number of queues GetCdw10 fromRaw round-trips through raw" {
    const original: admin.NumberOfQueues.GetCdw10 = .{
        .fid = .number_of_queues,
        .select = .saved,
    };
    const round = admin.NumberOfQueues.GetCdw10.fromRaw(original.raw());
    try testing.expectEqual(original.fid, round.fid);
    try testing.expectEqual(original.select, round.select);
    try testing.expectEqual(original.raw(), round.raw());
    try testing.expectEqual(@as(u21, 0), round.reserved_11);
}

test "unit: number of queues RequestCdw11 fromRaw round-trips through raw" {
    const original: admin.NumberOfQueues.RequestCdw11 = .{
        .nsqr_zero_based = 0x1234,
        .ncqr_zero_based = 0xABCD,
    };
    const round = admin.NumberOfQueues.RequestCdw11.fromRaw(original.raw());
    try testing.expectEqual(original.nsqr_zero_based, round.nsqr_zero_based);
    try testing.expectEqual(original.ncqr_zero_based, round.ncqr_zero_based);
    try testing.expectEqual(original.raw(), round.raw());
}

// ---------------------------------------------------------------------------
// Roundtrips
// ---------------------------------------------------------------------------

test "roundtrip: create io cq encoded slot decodes through Sqe accessors for cdw10 cdw11 dptr" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_2000_0000);

    const handle = try admin.CreateIoCompletionQueue.encode(&sub.sq, .{
        .qid = .from(2),
        .queue_size = 16,
        .base = base,
        .interrupts_enabled = true,
        .interrupt_vector = 0x0007,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const cdw10 = admin.CreateIoCompletionQueue.Cdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(@as(u16, 2), cdw10.qid);
    try testing.expectEqual(@as(u16, 15), cdw10.qsize_zero_based);
    const cdw11 = admin.CreateIoCompletionQueue.Cdw11.fromRaw(slot.cdw11());
    try testing.expectEqual(@as(u1, 1), cdw11.physically_contiguous);
    try testing.expectEqual(@as(u1, 1), cdw11.interrupts_enabled);
    try testing.expectEqual(@as(u16, 0x0007), cdw11.interrupt_vector);
    try testing.expectEqual(base.prp1.raw(), slot.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0), slot.dptr().prp2.raw());
}

test "roundtrip: create io sq encoded slot decodes through Sqe accessors for cdw10 cdw11 cdw12 dptr" {
    var sub: Substrate = undefined;
    try sub.init();
    var page: PageFixture = .{};
    const base = try page.ioQueueBase(0x0000_0000_3000_0000);

    const handle = try admin.CreateIoSubmissionQueue.encode(&sub.sq, .{
        .qid = .from(4),
        .queue_size = 32,
        .base = base,
        .cqid = .from(2),
        .priority = .urgent,
        .nvm_set_id = 0x00A5,
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const cdw10 = admin.CreateIoSubmissionQueue.Cdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(@as(u16, 4), cdw10.qid);
    try testing.expectEqual(@as(u16, 31), cdw10.qsize_zero_based);
    const cdw11 = admin.CreateIoSubmissionQueue.Cdw11.fromRaw(slot.cdw11());
    try testing.expectEqual(@as(u1, 1), cdw11.physically_contiguous);
    try testing.expectEqual(admin.CreateIoSubmissionQueue.Priority.urgent, cdw11.priority);
    try testing.expectEqual(@as(u16, 2), cdw11.completion_queue_id);
    const cdw12 = admin.CreateIoSubmissionQueue.Cdw12.fromRaw(slot.cdw12());
    try testing.expectEqual(@as(u16, 0x00A5), cdw12.nvm_set_id);
    try testing.expectEqual(base.prp1.raw(), slot.dptr().prp1.raw());
    try testing.expectEqual(@as(u64, 0), slot.dptr().prp2.raw());
}

test "roundtrip: number of queues set encoded slot decodes through Sqe accessors for cdw10 cdw11" {
    var sub: Substrate = undefined;
    try sub.init();

    const handle = try admin.NumberOfQueues.set(&sub.sq, .{
        .requested = .{ .submission_queues = 16, .completion_queues = 8 },
    });

    const slot: *const Sqe = &sub.ring_backing[handle.slot_index];
    const cdw10 = admin.NumberOfQueues.SetCdw10.fromRaw(slot.cdw10());
    try testing.expectEqual(admin.Fid.number_of_queues, cdw10.fid);
    try testing.expectEqual(@as(u1, 0), cdw10.save);
    const cdw11 = admin.NumberOfQueues.RequestCdw11.fromRaw(slot.cdw11());
    try testing.expectEqual(@as(u16, 15), cdw11.nsqr_zero_based);
    try testing.expectEqual(@as(u16, 7), cdw11.ncqr_zero_based);
}

test "roundtrip: number of queues fromRaw then allocated one-based round trip" {
    // Build a raw DW0 with known NSQA/NCQA, decode, allocate, assert one-based.
    const raw: u32 = (@as(u32, 4) << 16) | @as(u32, 8);
    const decoded = admin.NumberOfQueues.ResponseDw0.fromRaw(raw);
    try testing.expectEqual(@as(u16, 8), decoded.nsqa_zero_based);
    try testing.expectEqual(@as(u16, 4), decoded.ncqa_zero_based);
    const allocated = decoded.allocated();
    try testing.expectEqual(@as(u16, 9), allocated.submission_queues);
    try testing.expectEqual(@as(u16, 5), allocated.completion_queues);
    try testing.expectEqual(raw, decoded.raw());
}
