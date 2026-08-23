//! Host-side tests for src/controller/queue.zig. Spec: docs/specs/controller/queue.md.

const std = @import("std");
const testing = std.testing;

const stdx = @import("stdx");

const nvme = @import("nvme");
const queue = nvme.controller.queue;
const doorbell = nvme.core.doorbell;
const ids = nvme.core.ids;
const registers = nvme.core.registers;
const status = nvme.core.status;

const Sqe = nvme.commands.sqe.Sqe;
const Cqe = nvme.commands.cqe.Cqe;
const Cid = ids.Cid;
const Qid = ids.Qid;
const CompletionStatus = status.CompletionStatus;

/// Deterministic host-only clock backend. `now` advances by 1 ms per call so
/// `Deadline.now(&clock, ...)` produces monotonic anchors without touching
/// system time. `sleep` is `unreachable`: every test drives poll.until with
/// the spin-only backoff below, which never emits `.sleep`, so a firing
/// `sleep` proves a test misconfigured its policy.
const CounterBackend = struct {
    ticks_ns: u64 = 0,

    pub fn now(self: *CounterBackend) stdx.time.Instant {
        const t = self.ticks_ns;
        self.ticks_ns += 1_000_000;
        return stdx.time.Instant.fromNanos(t);
    }

    pub fn sleep(self: *CounterBackend, _: stdx.time.Duration) void {
        _ = self;
        unreachable;
    }
};

const CqType = queue.CompletionQueue(CounterBackend);
const PairType = queue.Pair(CounterBackend);
const CidAllocator = queue.CidAllocator;

/// Spin-only backoff. `spin_iterations = yield_iterations = 0` plus
/// `initial_wait = max_wait = zero` guarantees the first non-payload
/// iteration of `poll.until` routes into the sleep-step's timeout branch
/// (`remaining_ns <= 0 => .timeout`). No `.sleep` step is ever produced.
fn testBackoffPolicy() stdx.time.Backoff.Policy {
    return .{
        .spin_iterations = 0,
        .yield_iterations = 0,
        .yield = null,
        .initial_wait = stdx.time.Duration.zero,
        .max_wait = stdx.time.Duration.zero,
        .growth_shift = 0,
    };
}

fn makeSqBuffer(backing: []Sqe) !stdx.dma.Buffer(Sqe) {
    return try stdx.dma.Buffer(Sqe).init(backing, stdx.addr.DMAAddr.fromInt(0x1000));
}

fn makeCqBuffer(backing: []Cqe) !stdx.dma.Buffer(Cqe) {
    return try stdx.dma.Buffer(Cqe).init(backing, stdx.addr.DMAAddr.fromInt(0x2000));
}

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

fn makeDoorbells(bar_bytes: []align(@alignOf(u64)) u8) !doorbell.Doorbells {
    const regs = try registers.ControllerRegisters.at(bar_bytes);
    return doorbell.Doorbells.fromRegisters(regs, zeroedCap());
}

fn makeSubmissionQueue(
    qid: Qid,
    capacity: u16,
    ring: stdx.dma.Buffer(Sqe),
    cid_words: []CidAllocator.Word,
    sq_db: doorbell.SubmissionQueueDoorbell,
) !queue.SubmissionQueue {
    return try queue.SubmissionQueue.init(.{
        .qid = qid,
        .capacity = capacity,
        .ring = ring,
        .cid_words = cid_words,
        .doorbell = sq_db,
    });
}

fn makeCompletionQueue(
    qid: Qid,
    capacity: u16,
    ring: stdx.dma.Buffer(Cqe),
    cq_db: doorbell.CompletionQueueDoorbell,
    backend: CounterBackend,
) !CqType {
    return try CqType.init(.{
        .qid = qid,
        .capacity = capacity,
        .ring = ring,
        .doorbell = cq_db,
        .clock = CqType.Clock.init(backend),
    });
}

fn stampCompletion(
    cq_backing: []Cqe,
    index: usize,
    cid_value: u16,
    sqid_value: u16,
    sqhd_value: u16,
    status_raw: u16,
) void {
    Cqe.init(&cq_backing[index], .{
        .cid = cid_value,
        .sqid = sqid_value,
        .sqhd = sqhd_value,
        .status = status_raw,
        .dw0 = 0,
        .dw1 = 0,
    });
}

fn statusWithPhase(phase_bit: u1) u16 {
    return @as(u16, phase_bit);
}

fn readSqDoorbell(bar_bytes: []const u8, sq_db: doorbell.SubmissionQueueDoorbell) u32 {
    return std.mem.readInt(u32, bar_bytes[sq_db.offset()..][0..4], .little);
}

fn readCqDoorbell(bar_bytes: []const u8, cq_db: doorbell.CompletionQueueDoorbell) u32 {
    return std.mem.readInt(u32, bar_bytes[cq_db.offset()..][0..4], .little);
}

test "unit: submission queue init rejects zero capacity" {
    // Goal: init(.{ capacity = 0 }) yields CapacityMismatch before touching
    // CidAllocator.wrap. Ring length is also zero to prevent the two error
    // conditions from masking one another.
    var ring_backing: [0]Sqe = undefined;
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    try testing.expectError(error.CapacityMismatch, queue.SubmissionQueue.init(.{
        .qid = Qid.admin,
        .capacity = 0,
        .ring = ring,
        .cid_words = cid_words[0..],
        .doorbell = db.submissionQueue(Qid.admin),
    }));
}

test "unit: submission queue init rejects mismatched ring length" {
    // Goal: ring.len() != capacity yields CapacityMismatch. Ring length 4,
    // capacity 8: unambiguous mismatch.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    try testing.expectError(error.CapacityMismatch, queue.SubmissionQueue.init(.{
        .qid = Qid.admin,
        .capacity = 8,
        .ring = ring,
        .cid_words = cid_words[0..],
        .doorbell = db.submissionQueue(Qid.admin),
    }));
}

test "unit: submission queue init reports zero outstanding empty state and hasStaged false" {
    // Goal: freshly-initialized SQ has outstanding()==0, isFull()==false,
    // hasStaged()==false, tail==unflushed_tail==head==0.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], db.submissionQueue(Qid.admin));

    try testing.expectEqual(@as(usize, 0), sq.outstanding());
    try testing.expect(!sq.isFull());
    try testing.expect(!sq.hasStaged());
    try testing.expectEqual(@as(u16, 0), sq.tail);
    try testing.expectEqual(@as(u16, 0), sq.unflushed_tail);
    try testing.expectEqual(@as(u16, 0), sq.head);
}

test "unit: submission queue reserveSlot allocates lowest CID and returns builder bound to tail slot" {
    // Goal: reserveSlot on a fresh SQ returns CID 0 (lowest free), slot_index==tail==0,
    // and reservation.slot points at &ring.slice()[tail].
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], db.submissionQueue(Qid.admin));

    const reservation = try sq.reserveSlot();
    try testing.expectEqual(@as(u16, 0), reservation.command_id.raw());
    try testing.expectEqual(@as(u16, 0), reservation.slot_index);
    try testing.expectEqual(@as(*Sqe, &sq.ring.slice()[0]), reservation.slot);
    try testing.expectEqual(@as(usize, 1), sq.outstanding());
}

test "unit: submission queue reserveSlot does not advance tail" {
    // Goal: reserveSlot leaves tail/unflushed_tail unchanged; only `stage` moves them.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], db.submissionQueue(Qid.admin));

    _ = try sq.reserveSlot();
    try testing.expectEqual(@as(u16, 0), sq.tail);
    try testing.expectEqual(@as(u16, 0), sq.unflushed_tail);
}

test "unit: submission queue stage advances tail without ringing doorbell" {
    // Goal: stage bumps tail by one without writing to the MMIO doorbell lane;
    // the SQ tail doorbell byte reads back at its zero init value.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const sq_db = db.submissionQueue(Qid.admin);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], sq_db);

    const reservation = try sq.reserveSlot();
    _ = sq.stage(reservation);

    try testing.expectEqual(@as(u16, 1), sq.tail);
    try testing.expectEqual(@as(u16, 0), sq.unflushed_tail);
    try testing.expectEqual(@as(u32, 0), readSqDoorbell(&bar, sq_db));
}

test "unit: submission queue stage is infallible and returns Handle carrying reservation CID and slot_index" {
    // Goal: stage(reservation) returns Handle whose command_id and slot_index
    // equal the reservation's.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], db.submissionQueue(Qid.admin));

    const reservation = try sq.reserveSlot();
    const handle = sq.stage(reservation);
    try testing.expectEqual(reservation.command_id.raw(), handle.command_id.raw());
    try testing.expectEqual(reservation.slot_index, handle.slot_index);
}

test "unit: submission queue stage sets hasStaged true and flush clears it" {
    // Goal: hasStaged flips true after stage and back to false after flush.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], db.submissionQueue(Qid.admin));

    const reservation = try sq.reserveSlot();
    _ = sq.stage(reservation);
    try testing.expect(sq.hasStaged());

    try sq.flush();
    try testing.expect(!sq.hasStaged());
}

test "unit: submission queue flush rings SQ tail doorbell with current tail" {
    // Goal: after stage+flush, the SQ tail doorbell lane in the caller-owned
    // BAR holds the current tail value (1).
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const sq_db = db.submissionQueue(Qid.admin);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], sq_db);

    const reservation = try sq.reserveSlot();
    _ = sq.stage(reservation);
    try sq.flush();

    try testing.expectEqual(@as(u32, 1), readSqDoorbell(&bar, sq_db));
    try testing.expectEqual(sq.tail, sq.unflushed_tail);
}

test "unit: submission queue flush is idempotent — two flushes ring the same tail twice with no intervening stage" {
    // Goal: back-to-back flush() writes the same tail value both times; no error.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const sq_db = db.submissionQueue(Qid.admin);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], sq_db);

    const reservation = try sq.reserveSlot();
    _ = sq.stage(reservation);
    try sq.flush();
    try testing.expectEqual(@as(u32, 1), readSqDoorbell(&bar, sq_db));

    try sq.flush();
    try testing.expectEqual(@as(u32, 1), readSqDoorbell(&bar, sq_db));
    try testing.expectEqual(@as(u16, 1), sq.tail);
    try testing.expectEqual(@as(u16, 1), sq.unflushed_tail);
}

test "unit: submission queue flush with no staged commits still rings current tail" {
    // Goal: flush() on a fresh SQ writes tail=0. Sentinel 0xDEAD in the BAR
    // lane proves the flush overwrote it.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const sq_db = db.submissionQueue(Qid.admin);

    std.mem.writeInt(u32, bar[sq_db.offset()..][0..4], 0x0000_DEAD, .little);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], sq_db);

    try sq.flush();
    try testing.expectEqual(@as(u32, 0), readSqDoorbell(&bar, sq_db));
}

test "unit: submission queue stage N then flush once rings the batched tail" {
    // Goal: stage 5 in a cap-8 ring → tail=5, doorbell untouched; then flush
    // → doorbell reads 5.
    var ring_backing: [8]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const sq_db = db.submissionQueue(Qid.admin);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 8, ring, cid_words[0..], sq_db);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const r = try sq.reserveSlot();
        _ = sq.stage(r);
    }
    try testing.expectEqual(@as(u16, 5), sq.tail);
    try testing.expectEqual(@as(u32, 0), readSqDoorbell(&bar, sq_db));

    try sq.flush();
    try testing.expectEqual(@as(u32, 5), readSqDoorbell(&bar, sq_db));
}

test "unit: submission queue flush retry after doorbell failure re-rings the same tail" {
    // Goal: build the SQ over a 0x1000-byte BAR (no room for the doorbell
    // page). First flush surfaces OutOfBounds; tail/unflushed_tail unchanged.
    // Swap `sq.db` to a properly sized BAR and verify the second flush syncs
    // unflushed_tail and the doorbell lane reads the batched tail.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);

    var short_bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const short_regs = try registers.ControllerRegisters.at(&short_bar);
    const short_db = doorbell.Doorbells.fromRegisters(short_regs, zeroedCap());

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], short_db.submissionQueue(Qid.admin));

    const reservation = try sq.reserveSlot();
    _ = sq.stage(reservation);
    try testing.expectEqual(@as(u16, 1), sq.tail);

    try testing.expectError(error.OutOfBounds, sq.flush());
    try testing.expectEqual(@as(u16, 1), sq.tail);
    try testing.expectEqual(@as(u16, 0), sq.unflushed_tail);

    var full_bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const full_db = try makeDoorbells(&full_bar);
    const full_sq_db = full_db.submissionQueue(Qid.admin);
    sq.db = full_sq_db;

    try sq.flush();
    try testing.expectEqual(@as(u16, 1), sq.unflushed_tail);
    try testing.expectEqual(@as(u32, 1), readSqDoorbell(&full_bar, full_sq_db));
}

test "unit: submission queue reserveSlot rejects SubmissionQueueFull" {
    // Goal: fill capacity-1 slots (isFull true); the next reserveSlot returns
    // SubmissionQueueFull. Outstanding stays at capacity-1.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], db.submissionQueue(Qid.admin));

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const r = try sq.reserveSlot();
        _ = sq.stage(r);
    }
    try testing.expect(sq.isFull());
    try testing.expectError(error.SubmissionQueueFull, sq.reserveSlot());
    try testing.expectEqual(@as(usize, 3), sq.outstanding());
}

test "unit: submission queue reserveSlot rejects CidExhausted" {
    // Goal: reserveSlot without staging leaves tail at zero (isFull false), so
    // each call consumes a CID. After `capacity` reservations the CID pool is
    // empty and the next reserveSlot returns CidExhausted. Tail unchanged.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], db.submissionQueue(Qid.admin));

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        _ = try sq.reserveSlot();
    }
    try testing.expectEqual(@as(usize, 4), sq.outstanding());
    try testing.expectError(error.CidExhausted, sq.reserveSlot());
    try testing.expectEqual(@as(u16, 0), sq.tail);
}

test "unit: submission queue releaseReservation frees the CID and leaves tail unchanged" {
    // Goal: reserveSlot then releaseReservation returns outstanding to 0 with
    // tail unchanged; the next reserveSlot returns the same CID.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], db.submissionQueue(Qid.admin));

    const r1 = try sq.reserveSlot();
    sq.releaseReservation(r1);
    try testing.expectEqual(@as(usize, 0), sq.outstanding());
    try testing.expectEqual(@as(u16, 0), sq.tail);

    const r2 = try sq.reserveSlot();
    try testing.expectEqual(r1.command_id.raw(), r2.command_id.raw());
}

test "unit: submission queue setHeadFromSqhd accepts in-range head and rejects capacity overflow" {
    // Goal: setHeadFromSqhd(sqhd) accepts sqhd < capacity (head advances) and
    // rejects sqhd == capacity (head unchanged, InvalidSubmissionQueueHead).
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], db.submissionQueue(Qid.admin));

    try sq.setHeadFromSqhd(2);
    try testing.expectEqual(@as(u16, 2), sq.head);

    try testing.expectError(error.InvalidSubmissionQueueHead, sq.setHeadFromSqhd(4));
    try testing.expectEqual(@as(u16, 2), sq.head);
}

test "unit: submission queue releaseCompletedCid frees an allocated CID" {
    // Goal: reserve+stage one command, then releaseCompletedCid returns the
    // CID to the pool; outstanding drops to zero and the next reserveSlot
    // reuses the same CID (lowest-free order).
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], db.submissionQueue(Qid.admin));

    const reservation = try sq.reserveSlot();
    _ = sq.stage(reservation);
    try testing.expectEqual(@as(usize, 1), sq.outstanding());

    try sq.releaseCompletedCid(reservation.command_id);
    try testing.expectEqual(@as(usize, 0), sq.outstanding());

    // Same slot's CID becomes free again.
    const reused = try sq.reserveSlot();
    try testing.expectEqual(reservation.command_id.raw(), reused.command_id.raw());
}

test "unit: submission queue releaseCompletedCid rejects unallocated CID with UnknownCommandId" {
    // Goal: on an empty allocator, releaseCompletedCid(Cid.from(3)) translates
    // the underlying CidAllocator.NotAllocated into UnknownCommandId. Every
    // observable state stays put.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], db.submissionQueue(Qid.admin));

    try testing.expectError(error.UnknownCommandId, sq.releaseCompletedCid(Cid.from(3)));
    try testing.expectEqual(@as(usize, 0), sq.outstanding());
    try testing.expectEqual(@as(u16, 0), sq.tail);
    try testing.expectEqual(@as(u16, 0), sq.head);
}

test "unit: submission queue doorbell returns the underlying SubmissionQueueDoorbell value" {
    // Goal: SubmissionQueue.doorbell() forwards the composed doorbell — same
    // offset, same qid.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const sq_db = db.submissionQueue(Qid.admin);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], sq_db);

    const returned = sq.doorbell();
    try testing.expectEqual(sq_db.offset(), returned.offset());
    try testing.expectEqual(sq_db.qid.raw(), returned.qid.raw());
}

test "roundtrip: submission queue reserveSlot stage flush stamps slot and rings once" {
    // Goal: reserve → Sqe.init(reservation.slot, ...) → stage → flush; verify
    // ring[0] decodes through Sqe accessors to the stamped values, the SQ
    // doorbell lane reads tail==1, outstanding==1.
    var ring_backing: [4]Sqe = @splat(Sqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const sq_db = db.submissionQueue(Qid.admin);

    const ring = try makeSqBuffer(ring_backing[0..]);
    var sq = try makeSubmissionQueue(Qid.admin, 4, ring, cid_words[0..], sq_db);

    const reservation = try sq.reserveSlot();
    Sqe.init(reservation.slot, .{
        .opcode = 0x06,
        .command_id = reservation.command_id,
        .namespace_id = ids.Nsid.from(0xAB),
        .cdw10 = 0x1122_3344,
    });
    const handle = sq.stage(reservation);
    try sq.flush();

    const view = &sq.ring.constSlice()[0];
    try testing.expectEqual(@as(u8, 0x06), view.opcode());
    try testing.expectEqual(handle.command_id.raw(), view.cid().raw());
    try testing.expectEqual(@as(u32, 0xAB), view.nsid().raw());
    try testing.expectEqual(@as(u32, 0x1122_3344), view.cdw10());
    try testing.expectEqual(@as(u32, 1), readSqDoorbell(&bar, sq_db));
    try testing.expectEqual(@as(usize, 1), sq.outstanding());
}

test "unit: completion queue init rejects zero capacity" {
    // Goal: init(.{ capacity = 0 }) yields CapacityMismatch.
    var cq_backing: [0]Cqe = undefined;
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeCqBuffer(cq_backing[0..]);
    try testing.expectError(error.CapacityMismatch, CqType.init(.{
        .qid = Qid.admin,
        .capacity = 0,
        .ring = ring,
        .doorbell = db.completionQueue(Qid.admin),
        .clock = CqType.Clock.init(.{}),
    }));
}

test "unit: completion queue init rejects mismatched ring length" {
    // Goal: ring.len() != capacity yields CapacityMismatch.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeCqBuffer(cq_backing[0..]);
    try testing.expectError(error.CapacityMismatch, CqType.init(.{
        .qid = Qid.admin,
        .capacity = 8,
        .ring = ring,
        .doorbell = db.completionQueue(Qid.admin),
        .clock = CqType.Clock.init(.{}),
    }));
}

test "unit: completion queue drain with empty out changes no state or doorbell" {
    // Preserve clock and doorbell sentinels to prove an empty output slice exits before queue access.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const cq_db = db.completionQueue(Qid.admin);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, cq_db, .{ .ticks_ns = 17 });
    cq.head = 1;
    std.mem.writeInt(u32, bar[cq_db.offset()..][0..4], 0xCAFE_BABE, .little);

    var out: [0]queue.Completion = undefined;
    const n = try cq.drain(out[0..]);

    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(@as(u16, 1), cq.head);
    try testing.expectEqual(@as(u1, 1), cq.expected_phase);
    try testing.expectEqual(@as(u64, 17), cq.clock.backend.ticks_ns);
    try testing.expectEqual(@as(u32, 0xCAFE_BABE), readCqDoorbell(&bar, cq_db));
}

test "unit: completion queue drain returns zero on phase mismatch without side effects" {
    // Leave the CQE phase stale and preserve sentinels to prove a mismatch has no observable side effects.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const cq_db = db.completionQueue(Qid.admin);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, cq_db, .{ .ticks_ns = 23 });
    std.mem.writeInt(u32, bar[cq_db.offset()..][0..4], 0xABCD_EF01, .little);

    var out = [_]queue.Completion{.{
        .cid = Cid.from(0x1234),
        .sqid = Qid.from(7),
        .sqhd = 3,
        .status = CompletionStatus.success(false),
        .dw0 = 0x1122_3344,
        .dw1 = 0x5566_7788,
    }};
    const n = try cq.drain(out[0..]);

    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(@as(u16, 0), cq.head);
    try testing.expectEqual(@as(u1, 1), cq.expected_phase);
    try testing.expectEqual(@as(u64, 23), cq.clock.backend.ticks_ns);
    try testing.expectEqual(@as(u16, 0x1234), out[0].cid.raw());
    try testing.expectEqual(@as(u32, 0x1122_3344), out[0].dw0);
    try testing.expectEqual(@as(u32, 0xABCD_EF01), readCqDoorbell(&bar, cq_db));
}

test "unit: completion queue pollOne returns Timeout when phase never matches and Deadline expires" {
    // Goal: ring[0] carries phase=0 while expected_phase=1; the spin-only
    // policy routes the first backoff step to `.timeout`; pollOne surfaces
    // error.Timeout without advancing head or expected_phase.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, db.completionQueue(Qid.admin), .{});

    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl = try stdx.time.Deadline.now(&cq.clock, stdx.time.Duration.zero);
    try testing.expectError(error.Timeout, cq.pollOne(dl, &backoff));

    try testing.expectEqual(@as(u16, 0), cq.head);
    try testing.expectEqual(@as(u1, 1), cq.expected_phase);
}

test "unit: completion queue pollOne consumes matching phase and rings CQ head doorbell once" {
    // Goal: fabricate ring[0] with phase=1; pollOne returns, head advances
    // 0→1, the CQ head doorbell lane reads 1.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const cq_db = db.completionQueue(Qid.admin);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, cq_db, .{});

    stampCompletion(cq_backing[0..], 0, 0x42, 0, 3, statusWithPhase(1));

    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl = try stdx.time.Deadline.now(&cq.clock, stdx.time.Duration.zero);
    const c = try cq.pollOne(dl, &backoff);

    try testing.expectEqual(@as(u16, 0x42), c.cid.raw());
    try testing.expectEqual(@as(u16, 1), cq.head);
    try testing.expectEqual(@as(u32, 1), readCqDoorbell(&bar, cq_db));
}

test "unit: completion queue pollOne consumes a slot whose phase matches even after deadline passes" {
    // Goal: with a payload already sitting in ring[0], poll.until returns on
    // the first predicate call and never engages Backoff — even a past
    // deadline yields the completion, not error.Timeout.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, db.completionQueue(Qid.admin), .{});

    stampCompletion(cq_backing[0..], 0, 0x11, 0, 0, statusWithPhase(1));

    const anchor = cq.clock.now();
    _ = cq.clock.now();
    _ = cq.clock.now();
    const dl = stdx.time.Deadline.at(anchor);
    var backoff = stdx.time.Backoff.init(testBackoffPolicy());

    const c = try cq.pollOne(dl, &backoff);
    try testing.expectEqual(@as(u16, 0x11), c.cid.raw());
}

test "unit: completion queue drain flips expected phase on a full wrap" {
    // Fill one complete phase and use excess output capacity to verify that drain stops and flips at wrap.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const cq_db = db.completionQueue(Qid.admin);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, cq_db, .{});

    var i: u16 = 0;
    while (i < 4) : (i += 1) {
        stampCompletion(cq_backing[0..], i, i, 0, i, statusWithPhase(1));
    }

    var out_buf: [8]queue.Completion = undefined;
    const n = try cq.drain(out_buf[0..]);

    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(u16, 0), cq.head);
    try testing.expectEqual(@as(u1, 0), cq.expected_phase);
    try testing.expectEqual(@as(u32, 0), readCqDoorbell(&bar, cq_db));
}

test "unit: completion queue pollOne composes stdx.io.poll.until with the caller Backoff" {
    // Goal: verify pollOne wires Backoff into the poll loop by observing the
    // spin-only policy's timeout path — Backoff.next hits `.timeout` because
    // remaining==0, error.Timeout surfaces, and backoff.attempts stays at 0
    // (the `.timeout` branch does not increment `attempt`, per zstdx spec).
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, db.completionQueue(Qid.admin), .{});

    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const initial_attempts = backoff.attempts();
    const dl = try stdx.time.Deadline.now(&cq.clock, stdx.time.Duration.zero);
    try testing.expectError(error.Timeout, cq.pollOne(dl, &backoff));
    try testing.expectEqual(initial_attempts, backoff.attempts());
}

test "unit: completion queue doorbell returns the underlying CompletionQueueDoorbell value" {
    // Goal: CompletionQueue.doorbell() forwards the composed doorbell.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const cq_db = db.completionQueue(Qid.admin);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, cq_db, .{});

    const returned = cq.doorbell();
    try testing.expectEqual(cq_db.offset(), returned.offset());
    try testing.expectEqual(cq_db.qid.raw(), returned.qid.raw());
}

test "unit: completion queue pollOne observes device-flipped phase after an initial miss" {
    // Goal: first poll sees phase=0 while expected=1 → Timeout without state
    // change; then the "device" flips the CQE to phase=1 in-place; the second
    // poll observes the fresh phase and returns.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, db.completionQueue(Qid.admin), .{});

    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl1 = try stdx.time.Deadline.now(&cq.clock, stdx.time.Duration.zero);
    try testing.expectError(error.Timeout, cq.pollOne(dl1, &backoff));

    stampCompletion(cq_backing[0..], 0, 0x77, 0, 0, statusWithPhase(1));
    backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl2 = try stdx.time.Deadline.now(&cq.clock, stdx.time.Duration.zero);
    const c = try cq.pollOne(dl2, &backoff);

    try testing.expectEqual(@as(u16, 0x77), c.cid.raw());
    try testing.expectEqual(@as(u16, 1), cq.head);
}

test "unit: completion queue pollOne issues DMA acquire after phase match before CQE field decode" {
    // Goal: behavioral proxy for the acquire barrier — after phase matches at
    // ring[0], the decoded fields equal the stamped bytes. On host the
    // acquire is a compiler fence (test-strategy.md §"Barrier substrate"), so
    // the positive observable is that decode-after-phase-match works end-to-end.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, db.completionQueue(Qid.admin), .{});

    Cqe.init(&cq_backing[0], .{
        .cid = 0x1234,
        .sqid = 0,
        .sqhd = 2,
        .status = statusWithPhase(1),
        .dw0 = 0xDEAD_BEEF,
        .dw1 = 0xCAFE_F00D,
    });

    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl = try stdx.time.Deadline.now(&cq.clock, stdx.time.Duration.zero);
    const c = try cq.pollOne(dl, &backoff);

    try testing.expectEqual(@as(u16, 0x1234), c.cid.raw());
    try testing.expectEqual(@as(u16, 0), c.sqid.raw());
    try testing.expectEqual(@as(u16, 2), c.sqhd);
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), c.dw0);
    try testing.expectEqual(@as(u32, 0xCAFE_F00D), c.dw1);
}

test "unit: completion queue pollOne DMA acquire covers CQE fields only" {
    // Goal: the acquire barrier orders CQE-field reads only (queue.md §"Backoff
    // and barriers"). Fabricate a CQE with distinct DW0/DW1 sentinels and verify
    // decode recovers them — the barrier's positive observable is a clean decode
    // of the CQE's own fields; payload buffers are out of scope for this queue.
    var cq_backing: [2]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 2, ring, db.completionQueue(Qid.admin), .{});

    Cqe.init(&cq_backing[0], .{
        .cid = 0xABCD,
        .sqid = 0,
        .sqhd = 1,
        .status = statusWithPhase(1),
        .dw0 = 0x1111_2222,
        .dw1 = 0x3333_4444,
    });

    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl = try stdx.time.Deadline.now(&cq.clock, stdx.time.Duration.zero);
    const c = try cq.pollOne(dl, &backoff);
    try testing.expectEqual(@as(u16, 0xABCD), c.cid.raw());
    try testing.expectEqual(@as(u32, 0x1111_2222), c.dw0);
    try testing.expectEqual(@as(u32, 0x3333_4444), c.dw1);
    try testing.expectEqual(@as(u16, 1), c.sqhd);
}

test "unit: completion queue drain consumes contiguous matched CQEs with one doorbell" {
    // Stamp five distinct CQEs and verify one drain decodes them in order with one head update.
    var cq_backing: [8]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const cq_db = db.completionQueue(Qid.admin);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 8, ring, cq_db, .{});

    var i: u16 = 0;
    while (i < 5) : (i += 1) {
        stampCompletion(cq_backing[0..], i, i + 0x10, 0, i, statusWithPhase(1));
    }

    var out_buf: [8]queue.Completion = undefined;
    const n = try cq.drain(out_buf[0..]);

    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(@as(u16, 5), cq.head);
    try testing.expectEqual(@as(u32, 5), readCqDoorbell(&bar, cq_db));
    var k: u16 = 0;
    while (k < 5) : (k += 1) {
        try testing.expectEqual(k + 0x10, out_buf[k].cid.raw());
        try testing.expectEqual(@as(u16, 0), out_buf[k].sqid.raw());
        try testing.expectEqual(k, out_buf[k].sqhd);
    }
}

test "unit: completion queue drain stops at first phase mismatch" {
    // Stamp a matching prefix only and verify the first stale phase terminates the drain.
    var cq_backing: [8]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const cq_db = db.completionQueue(Qid.admin);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 8, ring, cq_db, .{});

    var i: u16 = 0;
    while (i < 3) : (i += 1) {
        stampCompletion(cq_backing[0..], i, i + 1, 0, i, statusWithPhase(1));
    }

    var out_buf: [8]queue.Completion = undefined;
    const n = try cq.drain(out_buf[0..]);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u16, 3), cq.head);
    try testing.expectEqual(@as(u32, 3), readCqDoorbell(&bar, cq_db));
}

test "unit: completion queue drain stops when out fills and resumes on the next call" {
    // Stamp eight CQEs, drain through a short slice, then verify the next call resumes at the fourth CQE.
    var cq_backing: [16]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const cq_db = db.completionQueue(Qid.admin);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 16, ring, cq_db, .{});

    var i: u16 = 0;
    while (i < 8) : (i += 1) {
        stampCompletion(cq_backing[0..], i, i + 1, 0, i, statusWithPhase(1));
    }

    var out_buf: [8]queue.Completion = undefined;
    const n1 = try cq.drain(out_buf[0..3]);
    try testing.expectEqual(@as(usize, 3), n1);
    try testing.expectEqual(@as(u16, 3), cq.head);
    try testing.expectEqual(@as(u32, 3), readCqDoorbell(&bar, cq_db));

    const n2 = try cq.drain(out_buf[0..8]);
    try testing.expectEqual(@as(usize, 5), n2);
    try testing.expectEqual(@as(u16, 8), cq.head);
    try testing.expectEqual(@as(u32, 8), readCqDoorbell(&bar, cq_db));
    try testing.expectEqual(@as(u16, 4), out_buf[0].cid.raw());
}

test "unit: completion queue drain issues DMA acquire before each CQE field decode" {
    // Stamp distinct CQE fields so each decoded entry proves acquire ordering follows its phase match.
    var cq_backing: [8]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 8, ring, db.completionQueue(Qid.admin), .{});

    var i: u16 = 0;
    while (i < 5) : (i += 1) {
        Cqe.init(&cq_backing[i], .{
            .cid = i + 0x20,
            .sqid = 0,
            .sqhd = i,
            .status = statusWithPhase(1),
            .dw0 = 0xAA00 | @as(u32, i),
            .dw1 = 0xBB00 | @as(u32, i),
        });
    }

    var out_buf: [8]queue.Completion = undefined;
    const n = try cq.drain(out_buf[0..]);
    try testing.expectEqual(@as(usize, 5), n);

    var k: u16 = 0;
    while (k < 5) : (k += 1) {
        try testing.expectEqual(k + 0x20, out_buf[k].cid.raw());
        try testing.expectEqual(@as(u32, 0xAA00 | @as(u32, k)), out_buf[k].dw0);
        try testing.expectEqual(@as(u32, 0xBB00 | @as(u32, k)), out_buf[k].dw1);
    }
}

test "unit: completion queue drain stops at wrap without spanning it" {
    // Seed both sides of a wrap with opposite phases and verify each drain stays on one side.
    var cq_backing: [5]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);
    const cq_db = db.completionQueue(Qid.admin);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 5, ring, cq_db, .{});
    cq.head = 2;
    cq.expected_phase = 1;

    stampCompletion(cq_backing[0..], 2, 0xA0, 0, 2, statusWithPhase(1));
    stampCompletion(cq_backing[0..], 3, 0xA1, 0, 3, statusWithPhase(1));
    stampCompletion(cq_backing[0..], 4, 0xA2, 0, 4, statusWithPhase(1));
    stampCompletion(cq_backing[0..], 0, 0xB0, 0, 0, statusWithPhase(0));
    stampCompletion(cq_backing[0..], 1, 0xB1, 0, 1, statusWithPhase(0));

    var out_buf: [8]queue.Completion = undefined;
    const n1 = try cq.drain(out_buf[0..]);
    try testing.expectEqual(@as(usize, 3), n1);
    try testing.expectEqual(@as(u16, 0), cq.head);
    try testing.expectEqual(@as(u1, 0), cq.expected_phase);
    try testing.expectEqual(@as(u32, 0), readCqDoorbell(&bar, cq_db));

    const n2 = try cq.drain(out_buf[0..]);
    try testing.expectEqual(@as(usize, 2), n2);
    try testing.expectEqual(@as(u16, 2), cq.head);
    try testing.expectEqual(@as(u1, 0), cq.expected_phase);
    try testing.expectEqual(@as(u32, 2), readCqDoorbell(&bar, cq_db));
}

test "unit: completion queue drain retry after CQ head doorbell failure re-observes completions" {
    // Fail the first head-doorbell write, replace the doorbell, and verify retry observes the same CQE.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var short_bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const short_regs = try registers.ControllerRegisters.at(&short_bar);
    const short_db = doorbell.Doorbells.fromRegisters(short_regs, zeroedCap());

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, short_db.completionQueue(Qid.admin), .{});

    stampCompletion(cq_backing[0..], 0, 0x55, 0, 0, statusWithPhase(1));

    var out_buf: [4]queue.Completion = undefined;
    try testing.expectError(error.OutOfBounds, cq.drain(out_buf[0..]));
    try testing.expectEqual(@as(u16, 0), cq.head);
    try testing.expectEqual(@as(u1, 1), cq.expected_phase);

    var full_bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const full_db = try makeDoorbells(&full_bar);
    cq.db = full_db.completionQueue(Qid.admin);

    const n = try cq.drain(out_buf[0..]);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u16, 0x55), out_buf[0].cid.raw());
    try testing.expectEqual(@as(u16, 1), cq.head);
}

test "unit: completion queue poll with empty out returns 0 without engaging Backoff" {
    // Goal: poll(out[0..0]) returns 0 without touching Backoff. Deadline is
    // anchored in the past to prove the early-return bypasses the poll.until
    // dispatch (otherwise the past deadline would surface error.Timeout).
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, db.completionQueue(Qid.admin), .{});

    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const initial_attempts = backoff.attempts();
    const dl = try stdx.time.Deadline.now(&cq.clock, stdx.time.Duration.zero);
    var out_buf: [0]queue.Completion = undefined;
    const n = try cq.poll(out_buf[0..], dl, &backoff);
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(initial_attempts, backoff.attempts());
    try testing.expectEqual(@as(u16, 0), cq.head);
    try testing.expectEqual(@as(u1, 1), cq.expected_phase);
}

test "roundtrip: completion queue pollOne decodes cid sqid sqhd status dw0 and dw1 from a fabricated CQE" {
    // Goal: fabricate a full CQE (cid/sqid/sqhd/status/dw0/dw1) and verify
    // pollOne returns a Completion whose fields match one-for-one and whose
    // status decodes as generic-success.
    var cq_backing: [4]Cqe = @splat(Cqe{});
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const ring = try makeCqBuffer(cq_backing[0..]);
    var cq = try makeCompletionQueue(Qid.admin, 4, ring, db.completionQueue(Qid.admin), .{});

    const success_status = CompletionStatus.success(true).raw();
    Cqe.init(&cq_backing[0], .{
        .cid = 0x0123,
        .sqid = 0,
        .sqhd = 2,
        .status = success_status,
        .dw0 = 0xAAAA_5555,
        .dw1 = 0x5555_AAAA,
    });

    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl = try stdx.time.Deadline.now(&cq.clock, stdx.time.Duration.zero);
    const c = try cq.pollOne(dl, &backoff);
    try testing.expectEqual(@as(u16, 0x0123), c.cid.raw());
    try testing.expectEqual(@as(u16, 0), c.sqid.raw());
    try testing.expectEqual(@as(u16, 2), c.sqhd);
    try testing.expectEqual(success_status, c.status.raw());
    try testing.expectEqual(@as(u32, 0xAAAA_5555), c.dw0);
    try testing.expectEqual(@as(u32, 0x5555_AAAA), c.dw1);
    try testing.expect(c.statusIsSuccess());
}

/// Bundle of caller-owned storage that composes into one `Pair`. Keeps each
/// test's setup to a couple of lines and every backing slice stack-local.
/// The backing arrays are sized at the maximum any Pair test uses; buildPair
/// slices `sq_ring`/`cq_ring` to the requested capacity.
const PairKit = struct {
    sq_ring: [8]Sqe = @splat(Sqe{}),
    cq_ring: [8]Cqe = @splat(Cqe{}),
    cid_words: [1]CidAllocator.Word = @splat(0),
    bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0),

    fn buildPair(self: *PairKit, qid: Qid, capacity: u16) !PairType {
        const doorbells = try makeDoorbells(&self.bar);
        const sq_ring = try makeSqBuffer(self.sq_ring[0..capacity]);
        const cq_ring = try makeCqBuffer(self.cq_ring[0..capacity]);
        const sq = try makeSubmissionQueue(
            qid,
            capacity,
            sq_ring,
            self.cid_words[0..],
            doorbells.submissionQueue(qid),
        );
        const cq = try makeCompletionQueue(
            qid,
            capacity,
            cq_ring,
            doorbells.completionQueue(qid),
            .{},
        );
        return try PairType.init(sq, cq);
    }
};

test "unit: pair init rejects mismatched qid — PairMismatch" {
    // Goal: SQ with Qid.admin composed with CQ with Qid.from(1) yields PairMismatch.
    var sq_ring: [4]Sqe = @splat(Sqe{});
    var cq_ring: [4]Cqe = @splat(Cqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const sq = try makeSubmissionQueue(
        Qid.admin,
        4,
        try makeSqBuffer(sq_ring[0..]),
        cid_words[0..],
        db.submissionQueue(Qid.admin),
    );
    const cq = try makeCompletionQueue(
        Qid.from(1),
        4,
        try makeCqBuffer(cq_ring[0..]),
        db.completionQueue(Qid.from(1)),
        .{},
    );
    try testing.expectError(error.PairMismatch, PairType.init(sq, cq));
}

test "unit: pair init rejects mismatched capacity — PairMismatch" {
    // Goal: SQ capacity 4 with CQ capacity 8 yields PairMismatch.
    var sq_ring: [4]Sqe = @splat(Sqe{});
    var cq_ring: [8]Cqe = @splat(Cqe{});
    var cid_words: [1]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const sq = try makeSubmissionQueue(
        Qid.admin,
        4,
        try makeSqBuffer(sq_ring[0..]),
        cid_words[0..],
        db.submissionQueue(Qid.admin),
    );
    const cq = try makeCompletionQueue(
        Qid.admin,
        8,
        try makeCqBuffer(cq_ring[0..]),
        db.completionQueue(Qid.admin),
        .{},
    );
    try testing.expectError(error.PairMismatch, PairType.init(sq, cq));
}

test "unit: pair sq and cq return the composed pointers" {
    // Goal: pair.sq() and pair.cq() expose the composed queues' qid and capacity.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 4);

    try testing.expectEqual(Qid.admin.raw(), pair.sq().qid.raw());
    try testing.expectEqual(Qid.admin.raw(), pair.cq().qid.raw());
    try testing.expectEqual(@as(u16, 4), pair.sq().capacity);
    try testing.expectEqual(@as(u16, 4), pair.cq().capacity);
}

test "unit: pair drain returns zero on an empty CQ without changing state" {
    // Leave the CQ stale and compare queue and clock state before and after the non-waiting drain.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 4);
    const ticks_before = pair.cq().clock.backend.ticks_ns;

    var out: [4]queue.Completion = undefined;
    const n = try pair.drain(out[0..]);

    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(@as(u16, 0), pair.sq().head);
    try testing.expectEqual(@as(u16, 0), pair.cq().head);
    try testing.expectEqual(@as(usize, 0), pair.sq().outstanding());
    try testing.expectEqual(ticks_before, pair.cq().clock.backend.ticks_ns);
}

test "unit: pair drain returns SqidMismatch after CQ advance without changing SQ state" {
    // Post a wrong-SQID CQE and verify CQ advancement occurs before chunk validation rejects it.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 4);

    const reservation = try pair.sq().reserveSlot();
    _ = pair.sq().stage(reservation);
    try pair.sq().flush();
    stampCompletion(kit.cq_ring[0..], 0, reservation.command_id.raw(), 1, 0, statusWithPhase(1));

    var out: [1]queue.Completion = undefined;
    try testing.expectError(error.SqidMismatch, pair.drain(out[0..]));

    try testing.expectEqual(@as(u16, 0), pair.sq().head);
    try testing.expectEqual(@as(usize, 1), pair.sq().outstanding());
    try testing.expectEqual(@as(u16, 1), pair.cq().head);
}

test "unit: pair drain returns InvalidSubmissionQueueHead after CQ advance without changing SQ state" {
    // Post an out-of-range SQHD and verify rejection preserves submission-side state after CQ advancement.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 4);

    const reservation = try pair.sq().reserveSlot();
    _ = pair.sq().stage(reservation);
    try pair.sq().flush();
    stampCompletion(kit.cq_ring[0..], 0, reservation.command_id.raw(), 0, 4, statusWithPhase(1));

    var out: [1]queue.Completion = undefined;
    try testing.expectError(error.InvalidSubmissionQueueHead, pair.drain(out[0..]));

    try testing.expectEqual(@as(u16, 0), pair.sq().head);
    try testing.expectEqual(@as(usize, 1), pair.sq().outstanding());
    try testing.expectEqual(@as(u16, 1), pair.cq().head);
}

test "unit: pair drain returns UnknownCommandId after CQ advance without changing SQ state" {
    // Post an unallocated CID and verify rejection preserves the empty submission-side allocator.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 4);
    stampCompletion(kit.cq_ring[0..], 0, 0x3, 0, 0, statusWithPhase(1));

    var out: [1]queue.Completion = undefined;
    try testing.expectError(error.UnknownCommandId, pair.drain(out[0..]));

    try testing.expectEqual(@as(u16, 0), pair.sq().head);
    try testing.expectEqual(@as(usize, 0), pair.sq().outstanding());
    try testing.expectEqual(@as(u16, 1), pair.cq().head);
}

test "unit: pair drain returns SqidMismatch mid-chunk without changing SQ state or output" {
    // Place a wrong SQID after valid entries to verify complete-chunk validation prevents partial SQ mutation.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 8);

    var reservations: [4]queue.SubmissionQueue.Reservation = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        reservations[i] = try pair.sq().reserveSlot();
        _ = pair.sq().stage(reservations[i]);
    }
    const extra = try pair.sq().reserveSlot();
    _ = pair.sq().stage(extra);
    try pair.sq().flush();

    var k: u16 = 0;
    while (k < 4) : (k += 1) {
        stampCompletion(kit.cq_ring[0..], k, reservations[k].command_id.raw(), 0, k, statusWithPhase(1));
    }
    stampCompletion(kit.cq_ring[0..], 4, extra.command_id.raw(), 1, 4, statusWithPhase(1));

    var out_buf: [8]queue.Completion = undefined;
    @memset(std.mem.asBytes(&out_buf), 0xFF);
    try testing.expectError(error.SqidMismatch, pair.drain(out_buf[0..]));

    try testing.expectEqual(@as(u16, 0), pair.sq().head);
    try testing.expectEqual(@as(usize, 5), pair.sq().outstanding());
    for (std.mem.asBytes(&out_buf)) |b| try testing.expectEqual(@as(u8, 0xFF), b);
}

test "unit: pair drain returns InvalidSubmissionQueueHead mid-chunk without changing SQ state or output" {
    // Place an invalid SQHD after valid entries to verify complete-chunk validation preserves output.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 8);

    var reservations: [3]queue.SubmissionQueue.Reservation = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        reservations[i] = try pair.sq().reserveSlot();
        _ = pair.sq().stage(reservations[i]);
    }
    const extra = try pair.sq().reserveSlot();
    _ = pair.sq().stage(extra);
    try pair.sq().flush();

    var k: u16 = 0;
    while (k < 3) : (k += 1) {
        stampCompletion(kit.cq_ring[0..], k, reservations[k].command_id.raw(), 0, k, statusWithPhase(1));
    }
    stampCompletion(kit.cq_ring[0..], 3, extra.command_id.raw(), 0, 8, statusWithPhase(1));

    var out_buf: [8]queue.Completion = undefined;
    @memset(std.mem.asBytes(&out_buf), 0xFF);
    try testing.expectError(error.InvalidSubmissionQueueHead, pair.drain(out_buf[0..]));

    try testing.expectEqual(@as(u16, 0), pair.sq().head);
    try testing.expectEqual(@as(usize, 4), pair.sq().outstanding());
    for (std.mem.asBytes(&out_buf)) |b| try testing.expectEqual(@as(u8, 0xFF), b);
}

test "unit: pair drain returns UnknownCommandId mid-chunk without changing SQ state or output" {
    // Place an unknown CID after valid entries to verify complete-chunk validation preserves allocated CIDs.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 8);

    var reservations: [2]queue.SubmissionQueue.Reservation = undefined;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        reservations[i] = try pair.sq().reserveSlot();
        _ = pair.sq().stage(reservations[i]);
    }
    try pair.sq().flush();

    stampCompletion(kit.cq_ring[0..], 0, reservations[0].command_id.raw(), 0, 0, statusWithPhase(1));
    stampCompletion(kit.cq_ring[0..], 1, reservations[1].command_id.raw(), 0, 1, statusWithPhase(1));
    stampCompletion(kit.cq_ring[0..], 2, 0x7, 0, 2, statusWithPhase(1));

    var out_buf: [8]queue.Completion = undefined;
    @memset(std.mem.asBytes(&out_buf), 0xFF);
    try testing.expectError(error.UnknownCommandId, pair.drain(out_buf[0..]));

    try testing.expectEqual(@as(u16, 0), pair.sq().head);
    try testing.expectEqual(@as(usize, 2), pair.sq().outstanding());
    for (std.mem.asBytes(&out_buf)) |b| try testing.expectEqual(@as(u8, 0xFF), b);
}

test "unit: pair drain validates completions and releases every CID" {
    // Post five valid CQEs and verify one drain updates SQHD and retires every CID in wire order.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 8);

    var reservations: [5]queue.SubmissionQueue.Reservation = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        reservations[i] = try pair.sq().reserveSlot();
        _ = pair.sq().stage(reservations[i]);
    }
    try pair.sq().flush();

    var k: u16 = 0;
    while (k < 5) : (k += 1) {
        stampCompletion(kit.cq_ring[0..], k, reservations[k].command_id.raw(), 0, k, statusWithPhase(1));
    }

    var out_buf: [8]queue.Completion = undefined;
    const n = try pair.drain(out_buf[0..]);

    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(@as(usize, 0), pair.sq().outstanding());
    try testing.expectEqual(@as(u16, 4), pair.sq().head);
    try testing.expectEqual(@as(u32, 5), readCqDoorbell(&kit.bar, pair.cq().doorbell()));
}

test "unit: pair drain retry after CQ head doorbell failure re-observes completions" {
    // Fail the CQ head write, replace the doorbell, and verify pair retry retires the original CID.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 4);

    const reservation = try pair.sq().reserveSlot();
    _ = pair.sq().stage(reservation);
    try pair.sq().flush();
    stampCompletion(kit.cq_ring[0..], 0, reservation.command_id.raw(), 0, 0, statusWithPhase(1));

    var short_bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const short_regs = try registers.ControllerRegisters.at(&short_bar);
    const short_db = doorbell.Doorbells.fromRegisters(short_regs, zeroedCap());
    pair.cq().db = short_db.completionQueue(Qid.admin);

    var out_buf: [4]queue.Completion = undefined;
    try testing.expectError(error.OutOfBounds, pair.drain(out_buf[0..]));
    try testing.expectEqual(@as(u16, 0), pair.cq().head);
    try testing.expectEqual(@as(u16, 0), pair.sq().head);
    try testing.expectEqual(@as(usize, 1), pair.sq().outstanding());

    var full_bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const full_db = try makeDoorbells(&full_bar);
    pair.cq().db = full_db.completionQueue(Qid.admin);

    const n = try pair.drain(out_buf[0..]);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(reservation.command_id.raw(), out_buf[0].cid.raw());
    try testing.expectEqual(@as(usize, 0), pair.sq().outstanding());
}

test "unit: pair drain rejects a duplicate CID before changing SQ state" {
    // Post the same allocated CID twice and verify prefix validation rejects it before SQ mutation.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 4);

    const reservation = try pair.sq().reserveSlot();
    _ = pair.sq().stage(reservation);
    try pair.sq().flush();
    stampCompletion(kit.cq_ring[0..], 0, reservation.command_id.raw(), 0, 1, statusWithPhase(1));
    stampCompletion(kit.cq_ring[0..], 1, reservation.command_id.raw(), 0, 1, statusWithPhase(1));

    var out_buf: [2]queue.Completion = undefined;
    @memset(std.mem.asBytes(&out_buf), 0xFF);
    try testing.expectError(error.UnknownCommandId, pair.drain(out_buf[0..]));

    try testing.expectEqual(@as(u16, 2), pair.cq().head);
    try testing.expectEqual(@as(u16, 0), pair.sq().head);
    try testing.expectEqual(@as(usize, 1), pair.sq().outstanding());
    for (std.mem.asBytes(&out_buf)) |b| try testing.expectEqual(@as(u8, 0xFF), b);
}

test "unit: pair pollOne returns completions in the order the device posts them not the order the caller submitted" {
    // Goal: submit 3 commands, CID assignment 0/1/2. Fabricate CQEs in reverse
    // order (ring[0].cid=2, ring[1].cid=1, ring[2].cid=0). Three pollOne calls
    // yield CIDs 2, 1, 0 — device order, not submission order.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 4);

    var reservations: [3]queue.SubmissionQueue.Reservation = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        reservations[i] = try pair.sq().reserveSlot();
        _ = pair.sq().stage(reservations[i]);
    }
    try pair.sq().flush();

    stampCompletion(kit.cq_ring[0..], 0, reservations[2].command_id.raw(), 0, 2, statusWithPhase(1));
    stampCompletion(kit.cq_ring[0..], 1, reservations[1].command_id.raw(), 0, 1, statusWithPhase(1));
    stampCompletion(kit.cq_ring[0..], 2, reservations[0].command_id.raw(), 0, 0, statusWithPhase(1));

    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl = try stdx.time.Deadline.now(&pair.cq().clock, stdx.time.Duration.zero);
    const c0 = try pair.pollOne(dl, &backoff);
    backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl1 = try stdx.time.Deadline.now(&pair.cq().clock, stdx.time.Duration.zero);
    const c1 = try pair.pollOne(dl1, &backoff);
    backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl2 = try stdx.time.Deadline.now(&pair.cq().clock, stdx.time.Duration.zero);
    const c2 = try pair.pollOne(dl2, &backoff);

    try testing.expectEqual(reservations[2].command_id.raw(), c0.cid.raw());
    try testing.expectEqual(reservations[1].command_id.raw(), c1.cid.raw());
    try testing.expectEqual(reservations[0].command_id.raw(), c2.cid.raw());
    try testing.expectEqual(@as(usize, 0), pair.sq().outstanding());
}

test "unit: releaseReservation still treats unallocated reservation CID as programmer error" {
    // Goal: releaseReservation on a fresh reservation frees its CID, leaving
    // sq.cids.allocated() == 0. Double-release is a programmer error per spec
    // (assertion-backed via `catch unreachable`); this test observes only the
    // single-release path — double-release would panic in Debug builds, which
    // is the contract and not something a positive test asserts against.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 4);

    const reservation = try pair.sq().reserveSlot();
    try testing.expectEqual(@as(usize, 1), pair.sq().outstanding());
    pair.sq().releaseReservation(reservation);
    try testing.expectEqual(@as(usize, 0), pair.sq().outstanding());
}

test "roundtrip: pair reserveSlot stage flush and pollOne returns matching handle and syncs SQ head" {
    // Goal: full path — reserve → Sqe.init → stage → flush → fabricate CQE →
    // pollOne. Handle CID matches Completion CID; sq.head equals the CQE's
    // sqhd; outstanding drops to zero.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 4);

    const reservation = try pair.sq().reserveSlot();
    Sqe.init(reservation.slot, .{
        .opcode = 0x02,
        .command_id = reservation.command_id,
    });
    const handle = pair.sq().stage(reservation);
    try pair.sq().flush();

    stampCompletion(kit.cq_ring[0..], 0, handle.command_id.raw(), 0, 1, statusWithPhase(1));

    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl = try stdx.time.Deadline.now(&pair.cq().clock, stdx.time.Duration.zero);
    const c = try pair.pollOne(dl, &backoff);

    try testing.expectEqual(handle.command_id.raw(), c.cid.raw());
    try testing.expectEqual(@as(u16, 1), pair.sq().head);
    try testing.expectEqual(@as(usize, 0), pair.sq().outstanding());
}

test "roundtrip: pair poll across CQ wrap tracks SQ head from the last SQHD in the chunk" {
    // Goal: pre-wrap chunk has 3 phase-1 CQEs with increasing sqhd values.
    // Pair.poll consumes them in one internal chunk; sq.head equals the LAST
    // sqhd (spec: "last write wins; monotonic in NVMe wire order").
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 5);

    // Reserve+stage 3 SQEs so their CIDs exist in the allocator.
    var reservations: [3]queue.SubmissionQueue.Reservation = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        reservations[i] = try pair.sq().reserveSlot();
        _ = pair.sq().stage(reservations[i]);
    }
    try pair.sq().flush();

    // Seed the CQ near the wrap so the drain hits the wrap-break.
    pair.cq().head = 2;
    pair.cq().expected_phase = 1;
    // Slots before the synthetic head are stale entries from the current
    // phase. After wrap, they must mismatch the new expected phase.
    stampCompletion(kit.cq_ring[0..], 0, 0, 0, 0, statusWithPhase(1));
    stampCompletion(kit.cq_ring[0..], 1, 0, 0, 0, statusWithPhase(1));

    stampCompletion(kit.cq_ring[0..], 2, reservations[0].command_id.raw(), 0, 0, statusWithPhase(1));
    stampCompletion(kit.cq_ring[0..], 3, reservations[1].command_id.raw(), 0, 1, statusWithPhase(1));
    stampCompletion(kit.cq_ring[0..], 4, reservations[2].command_id.raw(), 0, 2, statusWithPhase(1));

    var out_buf: [8]queue.Completion = undefined;
    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl = try stdx.time.Deadline.now(&pair.cq().clock, stdx.time.Duration.zero);
    const n = try pair.poll(out_buf[0..], dl, &backoff);

    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u16, 2), pair.sq().head);
    try testing.expectEqual(@as(u16, 0), pair.cq().head);
    try testing.expectEqual(@as(u1, 0), pair.cq().expected_phase);
    try testing.expectEqual(@as(usize, 0), pair.sq().outstanding());
}

test "roundtrip: pair batched submit and drain rings one SQ doorbell and one CQ doorbell" {
    // Goal: stage 4 commands, flush once → SQ doorbell reads 4; fabricate 4
    // CQEs, poll(out[0..4]) → CQ doorbell reads 4. One MMIO ring per side
    // over the entire submit/drain cycle.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 8);

    var reservations: [4]queue.SubmissionQueue.Reservation = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        reservations[i] = try pair.sq().reserveSlot();
        _ = pair.sq().stage(reservations[i]);
    }
    try pair.sq().flush();
    try testing.expectEqual(@as(u32, 4), readSqDoorbell(&kit.bar, pair.sq().doorbell()));

    var k: u16 = 0;
    while (k < 4) : (k += 1) {
        stampCompletion(kit.cq_ring[0..], k, reservations[k].command_id.raw(), 0, k, statusWithPhase(1));
    }

    var out_buf: [4]queue.Completion = undefined;
    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl = try stdx.time.Deadline.now(&pair.cq().clock, stdx.time.Duration.zero);
    const n = try pair.poll(out_buf[0..], dl, &backoff);

    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(u32, 4), readCqDoorbell(&kit.bar, pair.cq().doorbell()));
    try testing.expectEqual(@as(usize, 0), pair.sq().outstanding());
}

test "unit: pair poll returns after exactly 64 completions without a second wait" {
    // Post one full 64-entry chunk with an expired deadline to prove poll does not wait for entry 65.
    const capacity: u16 = 65;
    var sq_ring: [capacity]Sqe = @splat(Sqe{});
    var cq_ring: [capacity]Cqe = @splat(Cqe{});
    var cid_words: [2]CidAllocator.Word = @splat(0);
    var bar: [0x2000]u8 align(@alignOf(u64)) = @splat(0);
    const db = try makeDoorbells(&bar);

    const sq = try makeSubmissionQueue(
        Qid.admin,
        capacity,
        try makeSqBuffer(sq_ring[0..]),
        cid_words[0..],
        db.submissionQueue(Qid.admin),
    );
    const cq = try makeCompletionQueue(
        Qid.admin,
        capacity,
        try makeCqBuffer(cq_ring[0..]),
        db.completionQueue(Qid.admin),
        .{},
    );
    var pair = try PairType.init(sq, cq);

    var i: u16 = 0;
    while (i < 64) : (i += 1) {
        const reservation = try pair.sq().reserveSlot();
        _ = pair.sq().stage(reservation);
        stampCompletion(cq_ring[0..], i, reservation.command_id.raw(), 0, i + 1, statusWithPhase(1));
    }
    try pair.sq().flush();

    var out_buf: [capacity]queue.Completion = undefined;
    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const deadline = try stdx.time.Deadline.now(&pair.cq().clock, stdx.time.Duration.zero);
    const n = try pair.poll(out_buf[0..], deadline, &backoff);

    try testing.expectEqual(@as(usize, 64), n);
    try testing.expectEqual(@as(u16, 64), pair.cq().head);
    try testing.expectEqual(@as(u16, 64), pair.sq().head);
    try testing.expectEqual(@as(usize, 0), pair.sq().outstanding());
}

test "roundtrip: two independent pairs drain their own CQs without cross-interference" {
    // Goal: build two Pair values with distinct qids and distinct backing
    // storage. Submit+drain on each independently; each pair's state advances
    // (outstanding, head, expected_phase) with no read/write of the other.
    var kit_a = PairKit{};
    var kit_b = PairKit{};
    var pair_a = try kit_a.buildPair(Qid.from(1), 4);
    var pair_b = try kit_b.buildPair(Qid.from(2), 4);

    const ra = try pair_a.sq().reserveSlot();
    _ = pair_a.sq().stage(ra);
    try pair_a.sq().flush();

    const rb1 = try pair_b.sq().reserveSlot();
    _ = pair_b.sq().stage(rb1);
    const rb2 = try pair_b.sq().reserveSlot();
    _ = pair_b.sq().stage(rb2);
    try pair_b.sq().flush();

    stampCompletion(kit_a.cq_ring[0..], 0, ra.command_id.raw(), 1, 0, statusWithPhase(1));
    stampCompletion(kit_b.cq_ring[0..], 0, rb1.command_id.raw(), 2, 0, statusWithPhase(1));
    stampCompletion(kit_b.cq_ring[0..], 1, rb2.command_id.raw(), 2, 1, statusWithPhase(1));

    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl_a = try stdx.time.Deadline.now(&pair_a.cq().clock, stdx.time.Duration.zero);
    const ca = try pair_a.pollOne(dl_a, &backoff);

    backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl_b1 = try stdx.time.Deadline.now(&pair_b.cq().clock, stdx.time.Duration.zero);
    const cb1 = try pair_b.pollOne(dl_b1, &backoff);
    backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl_b2 = try stdx.time.Deadline.now(&pair_b.cq().clock, stdx.time.Duration.zero);
    const cb2 = try pair_b.pollOne(dl_b2, &backoff);

    try testing.expectEqual(ra.command_id.raw(), ca.cid.raw());
    try testing.expectEqual(rb1.command_id.raw(), cb1.cid.raw());
    try testing.expectEqual(rb2.command_id.raw(), cb2.cid.raw());
    try testing.expectEqual(@as(usize, 0), pair_a.sq().outstanding());
    try testing.expectEqual(@as(usize, 0), pair_b.sq().outstanding());
    try testing.expectEqual(@as(u16, 1), pair_a.cq().head);
    try testing.expectEqual(@as(u16, 2), pair_b.cq().head);
}

test "unit: request table wrap rejects mismatched slice length with CapacityMismatch" {
    // Goal: RequestTable(u32).wrap(slots[..4], capacity=8) yields CapacityMismatch.
    var slots: [4]u32 = .{ 0, 0, 0, 0 };
    try testing.expectError(error.CapacityMismatch, queue.RequestTable(u32).wrap(slots[0..], 8));
}

test "unit: request table at returns storage aliased with slots[cid.raw()]" {
    // Goal: table.at(cid) returns &slots[cid.raw()]; mutating through the
    // returned pointer mutates the backing slot in place.
    var slots: [4]u32 = .{ 0, 0, 0, 0 };
    var table = try queue.RequestTable(u32).wrap(slots[0..], 4);

    table.at(Cid.from(2)).* = 0xDEAD_BEEF;
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), slots[2]);
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), table.at(Cid.from(2)).*);

    // A different CID reads its own slot.
    slots[1] = 0x1234_5678;
    try testing.expectEqual(@as(u32, 0x1234_5678), table.at(Cid.from(1)).*);
}

test "unit: request table atConst returns const pointer aliased with slots[cid.raw()]" {
    // Goal: on a `const` binding, `atConst(cid)` returns *const RequestState
    // pointing at slots[cid.raw()]. Mutating the backing slice through the
    // original `slots` name still shows through the returned const pointer.
    var slots: [4]u32 = .{ 0, 0, 0, 0 };
    var mut_table = try queue.RequestTable(u32).wrap(slots[0..], 4);
    const table: *const queue.RequestTable(u32) = &mut_table;

    slots[3] = 0xFEED_BEEF;
    const ptr = table.atConst(Cid.from(3));
    try testing.expectEqual(@as(u32, 0xFEED_BEEF), ptr.*);
    try testing.expectEqual(@as(*const u32, &slots[3]), ptr);
}

test "unit: request table with RequestState = void has zero-size backing" {
    // Goal: RequestTable(void) accepts a zero-size slice matching capacity;
    // @sizeOf([N]void) == 0 and the wrap contract holds.
    try testing.expectEqual(@as(usize, 0), @sizeOf([4]void));
    var slots: [4]void = .{ {}, {}, {}, {} };
    var table = try queue.RequestTable(void).wrap(slots[0..], 4);
    // Access through `at` returns *void; nothing to assert beyond the compile
    // and the wrap contract itself.
    _ = table.at(Cid.from(0));
}

test "roundtrip: pair pollOne plus request table correlates completion with prior state write" {
    // Goal: submit 3 commands with distinct namespace ids, populate
    // RequestTable(u32) at each handle.command_id with the same namespace
    // value; fabricate 3 CQEs in reverse submission order; poll all 3; verify
    // each returned completion.cid looks up the correct namespace value.
    var kit = PairKit{};
    var pair = try kit.buildPair(Qid.admin, 4);
    var table_slots: [4]u32 = .{ 0, 0, 0, 0 };
    var table = try queue.RequestTable(u32).wrap(table_slots[0..], 4);

    const ns_values = [_]u32{ 0xAA, 0xBB, 0xCC };
    var handles: [3]queue.Handle = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const reservation = try pair.sq().reserveSlot();
        Sqe.init(reservation.slot, .{
            .opcode = 0x02,
            .command_id = reservation.command_id,
            .namespace_id = ids.Nsid.from(ns_values[i]),
        });
        handles[i] = pair.sq().stage(reservation);
        table.at(handles[i].command_id).* = ns_values[i];
    }
    try pair.sq().flush();

    // Reverse-order posting.
    stampCompletion(kit.cq_ring[0..], 0, handles[2].command_id.raw(), 0, 2, statusWithPhase(1));
    stampCompletion(kit.cq_ring[0..], 1, handles[1].command_id.raw(), 0, 1, statusWithPhase(1));
    stampCompletion(kit.cq_ring[0..], 2, handles[0].command_id.raw(), 0, 0, statusWithPhase(1));

    var out_buf: [3]queue.Completion = undefined;
    var backoff = stdx.time.Backoff.init(testBackoffPolicy());
    const dl = try stdx.time.Deadline.now(&pair.cq().clock, stdx.time.Duration.zero);
    const n = try pair.poll(out_buf[0..], dl, &backoff);
    try testing.expectEqual(@as(usize, 3), n);

    // Each completion's CID keys back to its submit-time namespace value.
    try testing.expectEqual(ns_values[2], table.at(out_buf[0].cid).*);
    try testing.expectEqual(ns_values[1], table.at(out_buf[1].cid).*);
    try testing.expectEqual(ns_values[0], table.at(out_buf[2].cid).*);
}
