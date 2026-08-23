//! NVMe queue-pair mechanics. Spec: docs/specs/controller/queue.md.

const std = @import("std");

const stdx = @import("stdx");

const ids = @import("../core/ids.zig");

const Cid = ids.Cid;
const CompletionQueueDoorbell = @import("../core/doorbell.zig").CompletionQueueDoorbell;
const CompletionStatus = @import("../core/status.zig").CompletionStatus;
const Cqe = @import("../commands/cqe.zig").Cqe;
const Qid = ids.Qid;
const Sqe = @import("../commands/sqe.zig").Sqe;
const SubmissionQueueDoorbell = @import("../core/doorbell.zig").SubmissionQueueDoorbell;

pub const CidAllocator = stdx.tags.TagAllocator.Bounded(ids.CidDomain, u16);

pub const CqDrainError = CompletionQueueDoorbell.Error;

pub const CqPollError = error{
    Timeout,
} || CqDrainError;

pub const DrainError = error{
    SqidMismatch,
    InvalidSubmissionQueueHead,
    UnknownCommandId,
} || CqDrainError;

pub const PollError = error{
    Timeout,
} || DrainError;

pub const InitError = error{
    CapacityMismatch,
    PairMismatch,
} || CidAllocator.Error;

pub const Handle = struct {
    command_id: Cid,
    slot_index: u16,
};

/// Decoded CQE returned after phase matching. `Pair` also retires the CID;
/// direct `CompletionQueue` users must apply the submission-queue hooks.
pub const Completion = struct {
    cid: Cid,
    sqid: Qid,
    sqhd: u16,
    status: CompletionStatus,
    dw0: u32,
    dw1: u32,

    pub fn statusIsSuccess(self: Completion) bool {
        return self.status.isSuccess();
    }
};

/// Host-side submission ring: reserve → stage → flush → release. Caller
/// serializes all methods; concurrent access is unsupported.
pub const SubmissionQueue = struct {
    qid: Qid,
    capacity: u16,
    ring: stdx.dma.Buffer(Sqe),
    tail: u16 = 0,
    unflushed_tail: u16 = 0,
    head: u16 = 0,
    cids: CidAllocator,
    db: SubmissionQueueDoorbell,

    pub const ReserveError = error{
        SubmissionQueueFull,
        CidExhausted,
    } || CidAllocator.Error;

    pub const FlushError = SubmissionQueueDoorbell.Error;

    pub const Reservation = struct {
        slot_index: u16,
        command_id: Cid,
        slot: *Sqe,
    };

    pub const Init = struct {
        qid: Qid,
        capacity: u16,
        ring: stdx.dma.Buffer(Sqe),
        cid_words: []CidAllocator.Word,
        doorbell: SubmissionQueueDoorbell,
    };

    pub fn init(params: Init) InitError!SubmissionQueue {
        if (params.capacity == 0) return error.CapacityMismatch;
        if (params.ring.len() != params.capacity) return error.CapacityMismatch;

        return .{
            .qid = params.qid,
            .capacity = params.capacity,
            .ring = params.ring,
            .cids = try CidAllocator.wrap(params.cid_words, params.capacity),
            .db = params.doorbell,
        };
    }

    pub fn doorbell(self: SubmissionQueue) SubmissionQueueDoorbell {
        return self.db;
    }

    pub fn isFull(self: SubmissionQueue) bool {
        const next: u16 = (self.tail + 1) % self.capacity;
        return next == self.head;
    }

    pub fn hasStaged(self: SubmissionQueue) bool {
        return self.tail != self.unflushed_tail;
    }

    pub fn outstanding(self: SubmissionQueue) usize {
        return self.cids.allocated();
    }

    pub fn reserveSlot(self: *SubmissionQueue) ReserveError!Reservation {
        if (self.isFull()) return error.SubmissionQueueFull;

        const tag = self.cids.allocOne() catch return error.CidExhausted;
        const cid: Cid = .{ .tag = tag };
        const slot = &self.ring.slice()[self.tail];

        return .{
            .slot_index = self.tail,
            .command_id = cid,
            .slot = slot,
        };
    }

    /// Publish the SQE at `reservation.slot` into the ring. Infallible: advances
    /// `tail` and returns the Handle. The SQE is not yet visible to the controller;
    /// `flush` is required.
    pub fn stage(self: *SubmissionQueue, reservation: Reservation) Handle {
        std.debug.assert(reservation.slot_index == self.tail);

        self.tail = (self.tail + 1) % self.capacity;

        return .{
            .command_id = reservation.command_id,
            .slot_index = reservation.slot_index,
        };
    }

    /// Ring the SQ tail doorbell with the current tail. Idempotent when nothing
    /// is staged. On error, `tail` and `unflushed_tail` are unchanged.
    pub fn flush(self: *SubmissionQueue) FlushError!void {
        try self.db.setTail(self.tail);
        self.unflushed_tail = self.tail;
    }

    /// Unwind a still-unpublished reservation, returning its CID to the pool.
    /// Infallible: `reserveSlot` is the only reservation source and no other
    /// caller-visible path frees this CID.
    pub fn releaseReservation(self: *SubmissionQueue, reservation: Reservation) void {
        self.cids.freeOne(reservation.command_id.tag) catch unreachable;
    }

    /// Update `head` from a completion's `sqhd`. Cross-boundary hook: callers
    /// composing `SubmissionQueue` and `CompletionQueue` without `Pair` invoke
    /// this per completion after `CompletionQueue.drain` or `poll` returns.
    pub fn setHeadFromSqhd(self: *SubmissionQueue, sqhd: u16) DrainError!void {
        if (sqhd >= self.capacity) return error.InvalidSubmissionQueueHead;
        self.head = sqhd;
    }

    /// Release a device-completed CID. Cross-boundary hook: callers composing
    /// `SubmissionQueue` and `CompletionQueue` without `Pair` invoke this per
    /// completion after `CompletionQueue.drain` or `poll` returns. Returns
    /// `UnknownCommandId` when the CID was never allocated in this SQ.
    pub fn releaseCompletedCid(self: *SubmissionQueue, cid: Cid) DrainError!void {
        self.cids.freeOne(cid.tag) catch |err| switch (err) {
            error.OutOfBounds, error.NotAllocated => return error.UnknownCommandId,
        };
    }
};

/// Host-side completion ring parameterized by a caller-supplied clock backend
/// (`fn now(*Backend) Instant`, `fn sleep(*Backend, Duration) void`). Caller
/// serializes all methods.
pub fn CompletionQueue(comptime Backend: type) type {
    return struct {
        qid: Qid,
        capacity: u16,
        ring: stdx.dma.Buffer(Cqe),
        head: u16 = 0,
        expected_phase: u1 = 1,
        db: CompletionQueueDoorbell,
        clock: Clock,

        const Self = @This();

        pub const Clock = stdx.time.Clock.Monotonic(Backend);

        pub const Init = struct {
            qid: Qid,
            capacity: u16,
            ring: stdx.dma.Buffer(Cqe),
            doorbell: CompletionQueueDoorbell,
            clock: Clock,
        };

        pub fn init(params: Init) InitError!Self {
            if (params.capacity == 0) return error.CapacityMismatch;
            if (params.ring.len() != params.capacity) return error.CapacityMismatch;

            return .{
                .qid = params.qid,
                .capacity = params.capacity,
                .ring = params.ring,
                .db = params.doorbell,
                .clock = params.clock,
            };
        }

        pub fn doorbell(self: Self) CompletionQueueDoorbell {
            return self.db;
        }

        /// Consumes already-posted CQEs without allocating, reading the clock,
        /// or waiting. Returns zero when the phase at `head` does not match. On
        /// doorbell error, queue state is unchanged and the caller must not
        /// consume `out`.
        pub fn drain(self: *Self, out: []Completion) CqDrainError!usize {
            if (out.len == 0) return 0;

            var count: usize = 0;
            var probe = self.head;
            var wrapped = false;
            while (count < out.len) {
                const slot = &self.ring.constSlice()[probe];
                if (slot.phase() != (self.expected_phase != 0)) break;

                stdx.barrier.dma.acquire();
                out[count] = .{
                    .cid = slot.cid(),
                    .sqid = slot.sqid(),
                    .sqhd = slot.sqhd(),
                    .status = slot.status(),
                    .dw0 = slot.dw0(),
                    .dw1 = slot.dw1(),
                };
                count += 1;

                const next = probe +% 1;
                if (next == self.capacity) {
                    wrapped = true;
                    break;
                }
                probe = next;
            }
            if (count == 0) return 0;

            const new_head: u16 = @intCast((self.head + count) % self.capacity);
            try self.db.setHead(new_head);

            if (wrapped) self.expected_phase ^= 1;
            self.head = new_head;
            return count;
        }

        /// Waits for the first posted CQE, then drains without another wait.
        pub fn poll(
            self: *Self,
            out: []Completion,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) CqPollError!usize {
            if (out.len == 0) return 0;
            try self.waitForFirst(deadline, backoff);
            return self.drain(out);
        }

        pub fn pollOne(
            self: *Self,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) CqPollError!Completion {
            var buf: [1]Completion = undefined;
            const n = try self.poll(buf[0..], deadline, backoff);
            std.debug.assert(n == 1);
            return buf[0];
        }

        fn waitForFirst(
            self: *Self,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) CqPollError!void {
            const FirstPredicate = struct {
                cq: *Self,

                pub fn call(p: @This()) CqPollError!?void {
                    const slot = &p.cq.ring.constSlice()[p.cq.head];
                    if (slot.phase() != (p.cq.expected_phase != 0)) return null;
                    return {};
                }
            };
            _ = try stdx.io.poll.until(
                &self.clock,
                deadline,
                backoff,
                FirstPredicate{ .cq = self },
            );
        }
    };
}

/// One queue pair. Composes `SubmissionQueue` with `CompletionQueue(Backend)`,
/// enforces per-completion SQID/SQHD/CID validation, and releases every
/// drained CID. Caller serializes all methods per pair.
pub fn Pair(comptime Backend: type) type {
    return struct {
        _sq: SubmissionQueue,
        _cq: Cq,

        const Self = @This();

        pub const Cq = CompletionQueue(Backend);

        pub fn init(submission: SubmissionQueue, completion: Cq) InitError!Self {
            if (submission.qid.raw() != completion.qid.raw()) return error.PairMismatch;
            if (submission.capacity != completion.capacity) return error.PairMismatch;

            return .{ ._sq = submission, ._cq = completion };
        }

        pub fn sq(self: *Self) *SubmissionQueue {
            return &self._sq;
        }

        pub fn cq(self: *Self) *Cq {
            return &self._cq;
        }

        /// Consumes already-posted CQEs without allocating or waiting, validates
        /// each complete chunk, and retires its CIDs. On validation error, CQ
        /// state has advanced, submission-side state for the failing chunk is
        /// unchanged, and the caller must not consume `out`.
        pub fn drain(self: *Self, out: []Completion) DrainError!usize {
            const chunk_max: usize = 64;
            var written: usize = 0;
            while (written < out.len) {
                var chunk: [chunk_max]Completion = undefined;
                const room = @min(out.len - written, chunk_max);
                const n = try self._cq.drain(chunk[0..room]);
                if (n == 0) break;

                for (chunk[0..n], 0..) |c, i| {
                    if (c.sqid.raw() != self._sq.qid.raw()) return error.SqidMismatch;
                    if (c.sqhd >= self._sq.capacity) return error.InvalidSubmissionQueueHead;
                    if (!self._sq.cids.isAllocated(c.cid.tag)) return error.UnknownCommandId;

                    // The 64-entry bound makes a prefix scan cheaper than a second CID bitmap.
                    for (chunk[0..i]) |prior| {
                        if (prior.cid.raw() == c.cid.raw()) return error.UnknownCommandId;
                    }
                }

                for (chunk[0..n]) |c| {
                    self._sq.head = c.sqhd;
                    self._sq.cids.freeOne(c.cid.tag) catch unreachable;
                    out[written] = c;
                    written += 1;
                }
            }
            return written;
        }

        /// Waits for the first posted CQE, then drains without another wait.
        pub fn poll(
            self: *Self,
            out: []Completion,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) PollError!usize {
            if (out.len == 0) return 0;
            try self._cq.waitForFirst(deadline, backoff);
            return self.drain(out);
        }

        pub fn pollOne(
            self: *Self,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) PollError!Completion {
            var buf: [1]Completion = undefined;
            const n = try self.poll(buf[0..], deadline, backoff);
            std.debug.assert(n == 1);
            return buf[0];
        }
    };
}

/// Caller-owned `Cid`-indexed slot table. Backing storage is caller-owned;
/// slot count must equal `capacity`.
pub fn RequestTable(comptime RequestState: type) type {
    return struct {
        slots: []RequestState,
        capacity: u16,

        const Self = @This();

        pub fn wrap(slots: []RequestState, capacity: u16) InitError!Self {
            if (slots.len != capacity) return error.CapacityMismatch;
            return .{ .slots = slots, .capacity = capacity };
        }

        pub fn at(self: *Self, cid: Cid) *RequestState {
            std.debug.assert(cid.raw() < self.capacity);
            return &self.slots[cid.raw()];
        }

        pub fn atConst(self: *const Self, cid: Cid) *const RequestState {
            std.debug.assert(cid.raw() < self.capacity);
            return &self.slots[cid.raw()];
        }
    };
}
