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

/// Reserve-side errors: SQ capacity and CID exhaustion.
pub const ReserveError = error{
    SubmissionQueueFull,
    CidExhausted,
} || CidAllocator.Error;

/// Flush errors bubble up straight from the SQ tail doorbell.
pub const FlushError = SubmissionQueueDoorbell.Error;

/// Completion-queue drain errors: timeout and CQ head doorbell.
pub const CqPollError = error{
    Timeout,
} || CompletionQueueDoorbell.Error;

/// Pair drain errors: `CqPollError` plus per-completion validation.
pub const PollError = error{
    SqidMismatch,
    InvalidSubmissionQueueHead,
    UnknownCommandId,
} || CqPollError;

/// Init-time errors for `SubmissionQueue.init`, `CompletionQueue.init`, and `Pair.init`.
pub const InitError = error{
    CapacityMismatch,
    PairMismatch,
} || CidAllocator.Error;

/// Retire token from `stage`; correlates a staged SQE with its CQE.
pub const Handle = struct {
    command_id: Cid,
    slot_index: u16,
};

/// Decoded CQE + retired CID. Phase is already matched by the `poll` that
/// produced this value; callers do not re-check.
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
    pub const Init = struct {
        qid: Qid,
        capacity: u16,
        ring: stdx.dma.Buffer(Sqe),
        cid_words: []CidAllocator.Word,
        doorbell: SubmissionQueueDoorbell,
    };

    pub const Reservation = struct {
        slot_index: u16,
        command_id: Cid,
        slot: *Sqe,
    };

    qid: Qid,
    capacity: u16,
    ring: stdx.dma.Buffer(Sqe),
    tail: u16 = 0,
    unflushed_tail: u16 = 0,
    head: u16 = 0,
    cids: CidAllocator,
    db: SubmissionQueueDoorbell,

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
    /// this per completion after `CompletionQueue.poll` returns.
    pub fn setHeadFromSqhd(self: *SubmissionQueue, sqhd: u16) PollError!void {
        if (sqhd >= self.capacity) return error.InvalidSubmissionQueueHead;
        self.head = sqhd;
    }

    /// Release a device-completed CID. Cross-boundary hook: callers composing
    /// `SubmissionQueue` and `CompletionQueue` without `Pair` invoke this per
    /// completion after `CompletionQueue.poll` returns. Returns
    /// `UnknownCommandId` when the CID was never allocated in this SQ.
    pub fn releaseCompletedCid(self: *SubmissionQueue, cid: Cid) PollError!void {
        self.cids.freeOne(cid.tag) catch |err| switch (err) {
            error.OutOfBounds, error.NotAllocated => return error.UnknownCommandId,
            error.OutOfTags, error.AlreadyAllocated => unreachable,
        };
    }
};

/// Host-side completion ring parameterized by a caller-supplied clock backend
/// (`fn now(*Backend) Instant`, `fn sleep(*Backend, Duration) void`). Caller
/// serializes all methods.
pub fn CompletionQueue(comptime Backend: type) type {
    return struct {
        const Self = @This();

        pub const Clock = stdx.time.Clock.Monotonic(Backend);

        pub const Init = struct {
            qid: Qid,
            capacity: u16,
            ring: stdx.dma.Buffer(Cqe),
            doorbell: CompletionQueueDoorbell,
            clock: Clock,
        };

        qid: Qid,
        capacity: u16,
        ring: stdx.dma.Buffer(Cqe),
        head: u16 = 0,
        expected_phase: u1 = 1,
        db: CompletionQueueDoorbell,
        clock: Clock,

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

        /// Drain contiguous matched CQEs into `out`. Waits on the FIRST completion
        /// via `stdx.io.poll.until`; subsequent slots are probed without engaging
        /// `Backoff`. Rings the CQ head doorbell exactly once at the end.
        ///
        /// Returns the number of completions written into `out[0..]`.
        /// On error, `head`/`expected_phase` are unchanged and `out` is untouched.
        pub fn poll(
            self: *Self,
            out: []Completion,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) CqPollError!usize {
            if (out.len == 0) return 0;

            // Wait on the first completion.
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

            // Drain contiguous matched CQEs without wrapping. `count += 1`
            // inline before the wrap check: Zig's `while (...) : (expr)`
            // continue-expression does not fire on `break`.
            var count: usize = 0;
            var probe = self.head;
            var wrapped = false;
            while (count < out.len) {
                const slot = &self.ring.constSlice()[probe];
                if (count > 0) {
                    // First slot's phase already matched inside poll.until.
                    if (slot.phase() != (self.expected_phase != 0)) break;
                }

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
                    break; // Stop at wrap; next call handles the flip.
                }
                probe = next;
            }
            const new_head: u16 = @intCast((self.head + count) % self.capacity);
            try self.db.setHead(new_head);

            // Flip phase from `wrapped`, not `new_head < self.head`: the
            // latter misses the head=0 full-wrap where both are zero.
            if (wrapped) self.expected_phase ^= 1;
            self.head = new_head;
            return count;
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
    };
}

/// One queue pair. Composes `SubmissionQueue` with `CompletionQueue(Backend)`,
/// enforces per-completion SQID/SQHD/CID validation, and releases every
/// drained CID. Caller serializes all methods per pair.
pub fn Pair(comptime Backend: type) type {
    return struct {
        const Self = @This();

        pub const Cq = CompletionQueue(Backend);

        _sq: SubmissionQueue,
        _cq: Cq,

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

        /// Drain contiguous matched CQEs, validating per-completion
        /// SQID/SQHD/CID and releasing every drained CID. Rings the CQ head
        /// doorbell exactly once per internal chunk.
        ///
        /// On per-completion validation error, `sq.head`, `sq.cids`, and `out`
        /// remain untouched. Note that `cq.head` and `cq.expected_phase` DO
        /// advance — the CQ doorbell has already rung inside `_cq.poll`.
        pub fn poll(
            self: *Self,
            out: []Completion,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) PollError!usize {
            const chunk_max: usize = 64;
            var written: usize = 0;
            while (written < out.len) {
                var chunk: [chunk_max]Completion = undefined;
                const room = @min(out.len - written, chunk_max);
                const n = self._cq.poll(chunk[0..room], deadline, backoff) catch |err| switch (err) {
                    error.Timeout => if (written == 0) return err else break,
                    else => |e| return e,
                };

                for (chunk[0..n]) |c| {
                    if (c.sqid.raw() != self._sq.qid.raw()) return error.SqidMismatch;
                    if (c.sqhd >= self._sq.capacity) return error.InvalidSubmissionQueueHead;
                    if (!self._sq.cids.isAllocated(c.cid.tag)) return error.UnknownCommandId;
                }

                // All validated. `freeOne catch unreachable` is safe:
                // `isAllocated(c.cid)` returned true above and per-pair
                // caller-serialization means no other path frees these CIDs.
                for (chunk[0..n]) |c| {
                    self._sq.head = c.sqhd; // Monotonic in NVMe wire order; last chunk entry wins.
                    self._sq.cids.freeOne(c.cid.tag) catch unreachable;
                    out[written] = c;
                    written += 1;
                }

                if (n < room) break; // CQ drained.
            }
            return written;
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
        const Self = @This();

        slots: []RequestState,
        capacity: u16,

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
