# Controller queue types

Status: Approved.

`[znvme]` `SubmissionQueue`, `CompletionQueue(Backend)`, and `Pair(Backend)` own NVMe queue-pair mechanics: SQ tail advance, CQ head advance, phase-tag flip on wrap, doorbell coupling, and outstanding-CID allocation. The three types are role-agnostic — the admin pair and every I/O pair use the same types, distinguished by their `Qid`.

`[znvme]` The submission surface is split: `reserveSlot` + `stage` publish an SQE into the ring without touching MMIO, and `flush` rings the SQ tail doorbell exactly once for however many entries were staged since the last ring. The completion surface exposes a batch `poll(out, deadline, backoff)` primitive that drains contiguous matched CQEs into a caller-owned slice with a single CQ head doorbell ring; `pollOne` remains as ergonomic sugar. Throughput consumers batch submit and completion drain; boot readers write two extra lines (`try sq.flush()`, `try pair.pollOne(...)`).

`[znvme]` `SubmissionQueue`, `CompletionQueue(Backend)`, and `Pair(Backend)` are semantic types per `docs/specs/architecture.md` §"Two type worlds". They compose wire types (`Sqe`, `Cqe`) inside `stdx.dma.Buffer(T)` fields but carry no ABI layout of their own.

## Owned scope

`[znvme]` This spec owns:

- `[znvme]` `SubmissionQueue`, the non-generic submission-side type: caller-owned `stdx.dma.Buffer(Sqe)`, `tail`, `unflushed_tail`, `head`, its doorbell, and a `stdx.tags.TagAllocator.Bounded(CidDomain, u16)` outstanding-CID pool over caller-owned bitmap words;
- `[znvme]` `CompletionQueue(Backend)`, the generic completion-side type: caller-owned `stdx.dma.Buffer(Cqe)`, `head`, `expected_phase`, its doorbell, and a `stdx.time.Clock.Monotonic(Backend)`;
- `[znvme]` `Pair(Backend)`, the coordinator that composes one `SubmissionQueue` with one `CompletionQueue(Backend)`;
- `[znvme]` `SubmissionQueue.Reservation`, a reserved SQ slot plus allocated CID plus a `*Sqe` slot pointer;
- `[znvme]` `Completion`, the decoded CQE payload paired with the retired CID;
- `[znvme]` `Handle`, the (CID, slot index) pair returned by `stage`;
- `[znvme]` `RequestTable(RequestState)`, a caller-owned `Cid`-indexed slot table for per-CID request bookkeeping in multi-outstanding callers;
- `[znvme]` reserve/stage/flush submission flow (`reserveSlot`, `stage`, `flush`, `releaseReservation`) with an infallible stage step and a caller-invoked doorbell ring;
- `[znvme]` batched completion drain (`Pair(Backend).poll(out, deadline, backoff)`, `CompletionQueue(Backend).poll(out, deadline, backoff)`) and single-completion sugar (`pollOne`), composing `stdx.io.poll.until` with caller-owned `stdx.time.Backoff` state and ringing the CQ head doorbell once per drain;
- `[znvme]` phase-tag flip on CQ head wrap;
- `[znvme]` `stdx.barrier.dma.acquire()` placement between each phase-tag read and the CQE field decode that follows it;
- `[znvme]` SQ head sync from `Cqe.sqhd()` on every completion;
- `[znvme]` CID lifecycle: allocated on `reserveSlot`, released on `poll` / `pollOne` after successful CQ head doorbell store, or on `releaseReservation` before publication;
- `[znvme]` SQ-full and CQ-empty edge behavior;
- `[znvme]` multi-pair composition: the caller owns `[]Pair(Backend)` sized against `admin.NumberOfQueues.Allocated`; znvme owns no queue-set aggregate;
- `[znvme]` error taxonomy for queue mechanics, split per method group.

## Deferred scope and non-goals

`[znvme]` This spec does not own:

- `[znvme]` command construction, opcode selection, per-command CDW encoding, or NSID admissibility (`docs/specs/commands/admin.md`, `docs/specs/commands/nvm.md`);
- `[znvme]` a queue-set aggregate — callers with N pairs hold `[]Pair(Backend)` and route by their own core / stream policy; znvme owns no scheduler and no cross-pair sharing;
- `[znvme]` shared CQ backing multiple SQs — one `Pair(Backend)` binds one SQ to one CQ; per-CQE SQID routing to alternate SQs is deferred until an approved spec claims that shape;
- `[znvme]` unstage / mid-batch rewind — once `stage` returns, the SQE is in the ring and the tail has advanced; the caller either `flush`es and observes the completion or tears down the whole SQ. There is no "cancel staged but unflushed" API;
- `[znvme]` controller reset, enable, or shutdown sequencing (`docs/specs/controller/init.md`);
- `[znvme]` admin queue base register writes (`docs/specs/core/registers.md`, `docs/specs/controller/init.md`);
- `[znvme]` doorbell offset math or `stdx.barrier.mmio.release` placement — those live in `docs/specs/core/doorbell.md`;
- `[znvme]` retry policy on CRD, DNR, or More completion bits — `docs/specs/core/status.md` decodes; the caller decides;
- `[znvme]` interrupt-driven completion — deferred by `docs/specs/project/scope.md`;
- `[znvme]` cross-thread concurrent access — each `Pair(Backend)` is caller-serialized; a multi-threaded consumer holds one pair per thread and znvme owns no locking;
- `[znvme]` allocation of any storage — SQ ring, CQ ring, CID bitmap, MMIO window, and completion drain buffers are caller-owned;
- `[znvme]` timeout budgeting policy — the caller passes a `stdx.time.Deadline` and a `*stdx.time.Backoff` computed against its own budget;
- `[znvme]` big-endian host or target compatibility.

## `stdx` composition

`[znvme]` Directly consumed:

- `[znvme]` `stdx.dma.Buffer(commands.sqe.Sqe)` — SQ storage inside `SubmissionQueue`;
- `[znvme]` `stdx.dma.Buffer(commands.cqe.Cqe)` — CQ storage inside `CompletionQueue(Backend)`;
- `[znvme]` `stdx.tags.TagAllocator.Bounded(CidDomain, u16)` — outstanding-CID pool inside `SubmissionQueue`, over caller-owned `[]u64` words;
- `[znvme]` `stdx.time.Clock.Monotonic(Backend)` — comptime parameter on `CompletionQueue(Backend)` driving `poll` / `pollOne` deadline reads;
- `[znvme]` `stdx.time.Deadline` — deadline parameter on `poll` and `pollOne`;
- `[znvme]` `stdx.time.Backoff` — caller-owned backoff state threaded through `poll` and `pollOne`;
- `[znvme]` `stdx.io.poll.until` — polling primitive composing `Deadline`, `Backoff`, and the phase-probe predicate for the first CQE in a drain;
- `[znvme]` `stdx.barrier.dma.acquire()` — placed after each phase-tag load and before the matching CQE field decode.

`[znvme]` Composed through znvme-owned types:

- `[znvme]` `core.doorbell.SubmissionQueueDoorbell` — the SQ tail doorbell, which internally uses `stdx.barrier.mmio.release()` before its MMIO store;
- `[znvme]` `core.doorbell.CompletionQueueDoorbell` — the CQ head doorbell;
- `[znvme]` `commands.sqe.Sqe` — SQE authorship in place via `Sqe.init(reservation.slot, params)`;
- `[znvme]` `commands.cqe.Cqe` — CQE decode through accessors on `*const Cqe`;
- `[znvme]` `core.ids.Cid` and `core.ids.Qid` — identifier types across the boundary;
- `[znvme]` `core.status.CompletionStatus` — the status field returned inside `Completion`.

## NVMe behavior

`[nvme]` The controller consumes SQEs at `SQyTDBL` and posts CQEs at the current CQ head. The host advances the CQ head only after consuming a completion.

`[nvme]` A single SQ tail doorbell write publishes every SQE between the previous tail value and the new tail value; the controller polls the tail register and consumes SQEs contiguously from head. A batched submit therefore rings the tail exactly once for N staged entries.

`[nvme]` A single CQ head doorbell write acknowledges every CQE consumed between the previous head value and the new head value. A batched drain rings the head exactly once for M consumed entries.

`[nvme]` The Phase Tag (`P`) bit indicates a fresh completion. The controller writes each CQE with the opposite phase from its previous write into that slot; the host expects the phase to flip on every full CQ wrap. Initial expected phase is `1`, matching the controller's first write after CQ initialization.

`[nvme]` `Cqe.SQHD` reports the SQ head pointer the controller has consumed through, letting the host reclaim SQ slots without a separate mechanism.

`[nvme]` Every command carries a Command Identifier in `Sqe.CDW0.CID` that is echoed in the corresponding `Cqe.CID`; uniqueness across outstanding commands on a given SQ is required for the controller to correlate submission and completion.

## znvme behavior

### Multi-pair composition

`[znvme]` One `Pair(Backend)` value represents one queue pair. `SubmissionQueue.qid` and `CompletionQueue(Backend).qid` are equal for a valid pair; `Pair.init` rejects mismatched `qid` or `capacity`.

`[znvme]` Callers with multiple I/O pairs hold `[]Pair(Backend)` (or however many named pair variables the caller prefers) and route work by their own policy — per-CPU core, per-stream, per-namespace. znvme owns no aggregate, no scheduler, and no cross-pair sharing; per-pair state stays fully caller-serialized. The negotiated ceiling comes from `admin.NumberOfQueues.set` / `.get` and its `Allocated` response; `Controller(Backend)` does not store it.

`[znvme]` `capacity` is the depth in entries and is identical for the paired SQ and CQ in the first slice. Asymmetric SQ/CQ depths do not land until an approved spec claims them.

### Submission — reserve → stage → flush

`[znvme]` `SubmissionQueue.tail` is the next-empty slot index that a fresh `reserveSlot` will target. `SubmissionQueue.unflushed_tail` records the last tail value the doorbell has seen; when `tail == unflushed_tail` there is nothing to flush and `flush` still writes `tail` to the doorbell (idempotent — the controller sees the same tail it already has and the write is a no-op on the controller side). `SubmissionQueue.head` is the last slot the controller confirmed consumed, updated from `Cqe.sqhd()` on every completion.

`[znvme]` `SubmissionQueue.isFull()` returns true when `(tail + 1) % capacity == head`. `reserveSlot` on a full SQ returns `error.SubmissionQueueFull` and does not allocate a CID.

`[znvme]` `SubmissionQueue.reserveSlot` allocates the lowest free CID via `TagAllocator.Bounded.allocOne`, returns a `Reservation` bound to `sq.ring.slice()[tail]` via `Reservation.slot: *Sqe`, and does not advance `tail`. The caller stamps the slot through `Sqe.init(reservation.slot, .{ ... })` and either calls `stage` to publish (advances `tail`) or `releaseReservation` to unwind (frees the CID, `tail` stays put). Using an `errdefer` on `releaseReservation` between `reserveSlot` and `stage` is the idiomatic pattern; because `stage` is infallible, the `errdefer` only fires if the caller's own stamping code fails between `reserveSlot` and `stage`.

`[znvme]` `SubmissionQueue.stage` asserts `reservation.slot_index == self.tail`, advances `tail` by one with wrap, and returns `Handle{ command_id, slot_index }`. `stage` performs no MMIO, no allocation, no waiting, and cannot fail — the SQE is already in the ring at the reserved slot pointer, and advancing `tail` is a purely local index update. Once `stage` returns, the SQE is in the ring but is not yet visible to the controller.

`[znvme]` `SubmissionQueue.flush` writes the current `tail` to the SQ tail doorbell via `SubmissionQueueDoorbell.setTail`. It is legal to call `flush` when `tail == unflushed_tail` (no staged entries since the last flush); the doorbell store re-writes the same value the controller already has, which is idempotent. `flush` is the only fallible step in the submission path; on doorbell error it returns `error.FlushFailed`-family (see the error taxonomy below), `tail` and `unflushed_tail` are unchanged relative to their pre-`flush` values, and a retry writes the same tail value. On success, `unflushed_tail = tail`.

`[znvme]` Callers batch by staging many reservations and calling `flush` once. Boot readers stage one and flush one; the flow is:

```
try builder(...)         // reserveSlot + Sqe.init + stage
try sq.flush()
const c = try pair.pollOne(deadline, &backoff)
```

`[znvme]` The reservation-to-stage gap does not intersperse another `reserveSlot` on the same queue — each `stage` asserts `reservation.slot_index == tail`, so the caller either stages immediately after reserving or releases the reservation. This is a caller-serialization invariant, not a lock: a caller that owns one pair per thread and drives it sequentially can never violate it.

### Completion — batched drain

`[znvme]` `CompletionQueue(Backend).head` is the next slot to inspect. `expected_phase` starts at `1` and flips whenever `head` wraps from `capacity - 1` back to `0`.

`[znvme]` `CompletionQueue(Backend).poll(out, deadline, backoff)` drains contiguous matched CQEs into the caller-owned `out: []Completion` slice. It waits on the *first* CQE only:

1. `[znvme]` `poll.until` iterates the phase-probe predicate on `ring[head]` against `expected_phase`. On mismatch, `poll.until` invokes `Backoff.next`; on `Deadline.TimeoutError` from `Backoff.next` it propagates `error.Timeout`.
2. `[znvme]` On the first matched phase, the predicate returns success. `poll` then issues `stdx.barrier.dma.acquire()` and decodes `ring[head]` into `out[0]`.
3. `[znvme]` For subsequent slots, `poll` issues `Cqe.phase()` (an atomic monotonic load of the status lane) directly, without going back through `poll.until` — the caller-provided backoff is a "wait for first" tool, not a per-slot dwell. A phase mismatch on slot `i > 0` stops the drain with `i` completions collected. `poll` issues `stdx.barrier.dma.acquire()` after every matched phase in the loop, before reading the corresponding CQE fields.
4. `[znvme]` The drain stops at whichever comes first: `out` is full, a phase mismatch (no more posted completions), or a CQ wrap (the drain never spans a wrap in a single call — the next call starts with the new `expected_phase`).
5. `[znvme]` `poll` computes the target head as `(cq.head + count) % cq.capacity` and rings the CQ head doorbell **once** via `CompletionQueueDoorbell.setHead(new_head)`. On doorbell error, `poll` returns the error, `cq.head` and `cq.expected_phase` are unchanged, and every drained-into slot in `out[0..count]` is discarded (the caller MUST NOT consume `out` on an error return). Retrying `poll` re-observes the same completions from `cq.head`.
6. `[znvme]` On success, `poll` advances `cq.head = new_head`, flips `cq.expected_phase` if the new head is `0`, and returns `count`.

`[znvme]` `CompletionQueue(Backend).pollOne(deadline, backoff)` is sugar: it calls `poll` with a stack `[1]Completion` and returns slot `0`.

`[znvme]` `Pair(Backend).poll(out, deadline, backoff)` composes `CompletionQueue.poll` with submission-side validation and CID release. Both must be all-or-nothing: `poll` first drains contiguous CQEs into a scratch stack `[N]Completion` (with `N == out.len` capped at a small comptime constant like `64`; larger `out` slices drain in multiple internal chunks each doing one doorbell ring), and validates every completion in the chunk **before advancing state**. If any completion in the drained chunk has:

- `[znvme]` `completion.sqid.raw() != sq.qid.raw()` → `error.SqidMismatch`;
- `[znvme]` `completion.sqhd >= sq.capacity` → `error.InvalidSubmissionQueueHead`;
- `[znvme]` `completion.cid` was not allocated in `sq.cids` → `error.UnknownCommandId`;

then `Pair.poll` returns the error, `cq.head` / `cq.expected_phase` / `sq.head` / `sq.cids` are all unchanged, and the caller sees no partial drain. On success, `Pair.poll` rings the CQ head doorbell exactly once for the chunk, advances `cq.head` and `cq.expected_phase`, updates `sq.head = last.sqhd`, releases every drained CID via `sq.cids.freeOne`, copies the drained completions into `out[start..start+count]`, and repeats for the next chunk if `out` had more room and the CQ had more posted completions. `Pair.poll` returns the total number of completions written into `out`.

`[znvme]` If a chunk-internal validation error causes `Pair.poll` to abort, the CQE the failing entry read still lives at `ring[cq.head + i]` and its phase still matches `expected_phase`. A retry re-decodes and re-validates it. This gives callers the "controller fault → reset" pattern without a mid-drain torn state.

`[znvme]` `Pair(Backend).pollOne(deadline, backoff)` is sugar over `Pair.poll` with a stack `[1]Completion`.

`[znvme]` Ordering property: the caller-provided `out` slice is filled in the exact order the device posted the completions to the CQ, which is not necessarily the order the caller submitted the commands. Callers with multiple outstanding commands correlate via `completion.cid`.

### CID lifecycle

`[znvme]` `reserveSlot` allocates via `TagAllocator.Bounded.allocOne` (lowest free CID). `stage` does not touch CID state. `poll` / `pollOne` release each drained CID via `TagAllocator.Bounded.freeOne` after the CQ head doorbell store succeeds and after the chunk-wide validation passes. `releaseReservation` frees a still-unpublished reservation's CID without publishing. A device-returned CID that was never allocated is a validation error, not a programmer error — `Pair.poll` returns `error.UnknownCommandId` and does not touch queue state; the caller treats it as a controller/device fault.

### Cross-boundary hooks

`[znvme]` `SubmissionQueue.setHeadFromSqhd` and `SubmissionQueue.releaseCompletedCid` are public because `Pair(Backend).poll` calls them across the type boundary. Callers that use `SubmissionQueue` and `CompletionQueue(Backend)` without a `Pair` wrapper call these after `CompletionQueue.poll` returns, applying the same validation semantics per completion. `setHeadFromSqhd` returns `error.InvalidSubmissionQueueHead` when `sqhd >= capacity`; `releaseCompletedCid` returns `error.UnknownCommandId` when the completion's CID was not allocated. `releaseReservation` remains assertion-backed because it unwinds a caller-owned reservation, not device-authored data.

### Backoff and barriers

`[znvme]` `poll` and `pollOne` never block and never yield on their own. `poll.until` invokes the caller-supplied `Backoff` for every non-payload iteration; `Backoff.Policy.yield` (when non-null) or `clock.sleep` (on `.sleep(d)`) are the only ways non-spin dispatch happens. First-slice firmware callers pass a spin-only policy such as `nvme.controller.init.default_backoff_policy`. Throughput callers pass a policy tuned for their reactor.

`[znvme]` `poll` returns `error.Timeout` when `Backoff.next` reports `.timeout` on the *first* completion of a drain (i.e., the CQ was empty for the entire deadline window). Once the first completion is consumed, the drain runs to phase mismatch or `out` fullness without further deadline checks — draining is bounded by CQ capacity per call, and hitting the deadline mid-drain does not truncate the batch. This matches the "handle observed device state before failing" idiom.

`[znvme]` `poll`'s DMA acquire orders CQE-field reads only; it does not order host loads from the caller-owned Identify / Read / Write payload buffers against the device's DMA write of those buffers. Callers reading a device-written payload after a successful `poll` MUST issue `stdx.barrier.dma.acquire()` before the first payload load, or use a byte-window entry point whose contract already includes that acquire (currently none — Identify views borrow already-published bytes).

## Approved API

```zig
// src/controller/queue.zig
//! NVMe queue-pair mechanics. Spec: docs/specs/controller/queue.md.

const std = @import("std");

const stdx = @import("stdx");

const doorbell = @import("../core/doorbell.zig");
const ids = @import("../core/ids.zig");

const Cid = ids.Cid;
const CompletionStatus = @import("../core/status.zig").CompletionStatus;
const Cqe = @import("../commands/cqe.zig").Cqe;
const Qid = ids.Qid;
const Sqe = @import("../commands/sqe.zig").Sqe;

pub const CidAllocator = stdx.tags.TagAllocator.Bounded(ids.CidDomain, u16);

/// Reserve-side errors: SQ capacity and CID exhaustion.
pub const ReserveError = error{
    SubmissionQueueFull,
    CidExhausted,
} || CidAllocator.Error;

/// Flush errors bubble up straight from the SQ tail doorbell.
pub const FlushError = doorbell.SubmissionQueueDoorbell.Error;

/// Completion-queue drain errors: timeout and CQ head doorbell.
pub const CqPollError = error{
    Timeout,
} || doorbell.CompletionQueueDoorbell.Error;

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

pub const Handle = struct {
    command_id: Cid,
    slot_index: u16,
};

pub const Completion = struct {
    cid: Cid,
    sqid: Qid,
    sqhd: u16,
    status: CompletionStatus,
    dw0: u32,
    dw1: u32,

    /// True iff the CQE status field decoded to a generic-success completion.
    /// This is phase-agnostic: `Pair.poll` / `pollOne` and `CompletionQueue.poll` /
    /// `pollOne` only return a `Completion` after the CQE phase has been matched and
    /// the CQ head advanced, so callers do not re-check phase here.
    pub fn statusIsSuccess(self: Completion) bool {
        return self.status.isSuccess();
    }
};

pub const SubmissionQueue = struct {
    pub const Init = struct {
        qid: Qid,
        capacity: u16,
        ring: stdx.dma.Buffer(Sqe),
        cid_words: []CidAllocator.Word,
        doorbell: doorbell.SubmissionQueueDoorbell,
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
    db: doorbell.SubmissionQueueDoorbell,

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

    pub fn doorbell(self: SubmissionQueue) doorbell.SubmissionQueueDoorbell {
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

        const cid = self.cids.allocOne() catch return error.CidExhausted;
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

    /// Ring the SQ tail doorbell with the current tail. Idempotent: legal with no
    /// staged entries (writes the same tail the controller already has).
    /// On error, `tail` and `unflushed_tail` are unchanged; the caller may retry.
    pub fn flush(self: *SubmissionQueue) FlushError!void {
        try self.db.setTail(self.tail);
        self.unflushed_tail = self.tail;
    }

    pub fn releaseReservation(self: *SubmissionQueue, reservation: Reservation) void {
        self.cids.freeOne(reservation.command_id) catch unreachable;
    }

    pub fn setHeadFromSqhd(self: *SubmissionQueue, sqhd: u16) PollError!void {
        if (sqhd >= self.capacity) return error.InvalidSubmissionQueueHead;
        self.head = sqhd;
    }

    pub fn releaseCompletedCid(self: *SubmissionQueue, cid: Cid) PollError!void {
        self.cids.freeOne(cid) catch |err| switch (err) {
            error.NotAllocated => return error.UnknownCommandId,
            else => return err,
        };
    }
};

pub fn CompletionQueue(comptime Backend: type) type {
    return struct {
        const Self = @This();

        pub const Clock = stdx.time.Clock.Monotonic(Backend);

        pub const Init = struct {
            qid: Qid,
            capacity: u16,
            ring: stdx.dma.Buffer(Cqe),
            doorbell: doorbell.CompletionQueueDoorbell,
            clock: Clock,
        };

        qid: Qid,
        capacity: u16,
        ring: stdx.dma.Buffer(Cqe),
        head: u16 = 0,
        expected_phase: u1 = 1,
        db: doorbell.CompletionQueueDoorbell,
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

        pub fn doorbell(self: Self) doorbell.CompletionQueueDoorbell {
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

            // Drain contiguous matched CQEs without wrapping.
            var count: usize = 0;
            var probe = self.head;
            while (count < out.len) : (count += 1) {
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
                const next = probe +% 1;
                if (next == self.capacity) break; // Stop at wrap; next call handles the flip.
                probe = next;
            }
            // count is at least 1 (the first predicate matched).
            const new_head: u16 = @intCast((self.head + count) % self.capacity);
            try self.db.setHead(new_head);

            if (new_head < self.head) self.expected_phase ^= 1;
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

        /// Drain contiguous matched CQEs, validating per-completion SQID/SQHD/CID
        /// and releasing every drained CID. Rings the CQ head doorbell exactly
        /// once per internal chunk. On any per-completion validation error, no
        /// state advances and no completions are written to `out`.
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
                    if (!self._sq.cids.isAllocated(c.command_id_field())) return error.UnknownCommandId;
                }

                // All validated. Apply submission-side state and hand out.
                for (chunk[0..n]) |c| {
                    self._sq.head = c.sqhd; // last write wins; monotonic in NVMe wire order.
                    self._sq.cids.freeOne(c.cid) catch unreachable;
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
```

`[znvme]` `Cqe.command_id_field()` above is shorthand for the raw `u16` view that `CidAllocator.isAllocated` needs; concrete implementation converts `c.cid.raw()` back into the allocator's index. The public spec surface is `c.cid: Cid`; implementation is free to phrase the isAllocated check however works with the `TagAllocator.Bounded` API. `TagAllocator.Bounded` exposes `isAllocated(Tag)` in stdx.

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `[znvme]` `SubmissionQueue.init` | never | never | O(1) checks + `CidAllocator.wrap` | value type | none | `InitError` |
| `[znvme]` `SubmissionQueue.doorbell` / `isFull` / `hasStaged` / `outstanding` | never | never | O(1) | borrowed value | none | infallible |
| `[znvme]` `SubmissionQueue.reserveSlot` | never | never | O(1) | caller-serialized per queue | none | `ReserveError` |
| `[znvme]` `SubmissionQueue.stage` | never | never | O(1) | caller-serialized per queue | none (no MMIO) | infallible (asserts `slot_index == tail`) |
| `[znvme]` `SubmissionQueue.flush` | never | never | O(1) | caller-serialized per queue | `stdx.barrier.mmio.release` inside SQ tail doorbell | `FlushError` |
| `[znvme]` `SubmissionQueue.releaseReservation` | never | never | O(1) | caller-serialized per queue | none | infallible (asserts reservation allocation state) |
| `[znvme]` `SubmissionQueue.setHeadFromSqhd` | never | never | O(1) | caller-serialized per queue | none | `InvalidSubmissionQueueHead` |
| `[znvme]` `SubmissionQueue.releaseCompletedCid` | never | never | O(1) | caller-serialized per queue | none | `UnknownCommandId`, `CidAllocator.Error` |
| `[znvme]` `CompletionQueue(Backend).init` | never | never | O(1) | value type | none | `InitError` |
| `[znvme]` `CompletionQueue(Backend).doorbell` | never | never | O(1) | borrowed value | none | infallible |
| `[znvme]` `CompletionQueue(Backend).poll(out)` | never | first completion via `stdx.io.poll.until`; drain is bounded by `out.len` and CQ capacity | O(min(out.len, cq.capacity)) | single-owner over `*Backoff`, caller-serialized per queue | phase probe via `Cqe.phase()` monotonic atomic load per drained slot; `stdx.barrier.dma.acquire` after each matched phase; `stdx.barrier.mmio.release` inside CQ head doorbell (once per call) | `CqPollError` |
| `[znvme]` `CompletionQueue(Backend).pollOne` | never | as `poll` with `out.len == 1` | O(1) | as `poll` | as `poll` | `CqPollError` |
| `[znvme]` `Pair(Backend).init` | never | never | O(1) | value type | none | `PairMismatch` |
| `[znvme]` `Pair(Backend).sq` / `cq` | never | never | O(1) | borrowed pointer | none | infallible |
| `[znvme]` `Pair(Backend).poll(out)` | never | as `CompletionQueue.poll` | O(min(out.len, cq.capacity)) | single-owner over `*Backoff`, caller-serialized per pair | as `CompletionQueue.poll`; SQ-side state advanced only after chunk-wide validation passes | `PollError` |
| `[znvme]` `Pair(Backend).pollOne` | never | as `poll` | O(1) | as `poll` | as `poll` | `PollError` |
| `[znvme]` `RequestTable(RequestState).wrap` | never | never | O(1) | value type | none | `CapacityMismatch` |
| `[znvme]` `RequestTable(RequestState).at` / `atConst` | never | never | O(1) | borrowed pointer to slot | none | infallible (asserts `cid < capacity`) |

## Validation phases

`[znvme]` Per `docs/specs/architecture.md` §"Validation phases":

- `[znvme]` **Compile time.** `stdx.time.Clock.Monotonic(Backend)` signature-checks the `Backend` type at instantiation. No layout assertions; these are semantic types.
- `[znvme]` **Public validation.** `SubmissionQueue.init` and `CompletionQueue(Backend).init` reject zero capacity and mismatched ring lengths with `error.CapacityMismatch`. `SubmissionQueue.init` delegates to `CidAllocator.wrap`, which rejects capacities that overflow `u16` or exceed the caller's bitmap. `Pair(Backend).init` rejects mismatched `qid` or `capacity` with `error.PairMismatch`. `Pair(Backend).poll` rejects device-authored completions whose SQID does not match the pair QID (`SqidMismatch`), whose SQHD is outside the SQ capacity (`InvalidSubmissionQueueHead`), or whose CID is not allocated (`UnknownCommandId`) — chunk-wide, before any state advances.
- `[znvme]` **Assertions.** `SubmissionQueue.stage` asserts `reservation.slot_index == tail`. `SubmissionQueue.releaseReservation` treats `NotAllocated` as `unreachable` because releasing a reservation that was never allocated is a caller programmer error. `RequestTable(RequestState).at` and `atConst` assert `cid.raw() < capacity`; a CID out of range is a caller-side programmer error since `poll` never yields a CID outside the SQ's allocator bitmap. Device-authored completion fields never use assertions for validation.

## Example usage

`[znvme]` Illustrative shape only; not part of the approved API. `docs/specs/controller/init.md` owns admin queue bring-up and `docs/specs/commands/admin.md` owns Identify Controller encoding.

### Boot reader — one command

```zig
const std = @import("std");

const nvme = @import("nvme");
const stdx = @import("stdx");

const Pair = nvme.controller.queue.Pair(MyHpetBackend);
const Sqe = nvme.commands.sqe.Sqe;

// Submit an Identify Controller.
{
    const sq = admin.sq();
    const reservation = try sq.reserveSlot();
    errdefer sq.releaseReservation(reservation);

    Sqe.init(reservation.slot, .{
        .opcode = 0x06,
        .command_id = reservation.command_id,
        .namespace_id = .none,
        .data_pointers = identify_dptr,
        .cdw10 = 0x0000_0001, // CNS = 01h Identify Controller.
    });

    _ = sq.stage(reservation);
    try sq.flush();
}

var backoff = stdx.time.Backoff.init(nvme.controller.init.default_backoff_policy);
const deadline = try stdx.time.Deadline.now(&admin.cq().clock, try stdx.time.Duration.fromMillis(500));
const completion = try admin.pollOne(deadline, &backoff);
std.debug.assert(completion.statusIsSuccess());
```

### Throughput driver — batched submit + batched drain

```zig
// Submit a batch of reads. Every encode stages internally; the caller
// controls when the doorbell rings.
for (0..batch_size) |i| {
    _ = try nvme.commands.nvm.Read.encode(io.sq(), reqs[i]);
}
try io.sq().flush();

// Drain up to 64 completions in one call, one CQ head doorbell ring.
var completions: [64]nvme.controller.queue.Completion = undefined;
const n = try io.poll(&completions, deadline, &backoff);
for (completions[0..n]) |c| handle(c);
```

### Multi-queue — one pair per core

```zig
// After Set Features (Number of Queues) has returned an Allocated count,
// the caller creates and initializes one Pair(Backend) per CPU core (or per
// whatever routing policy the caller uses). znvme owns no aggregate.
const io_pairs: []Pair = caller_composed_pairs;

// Each thread drives its own pair; per-pair state stays caller-serialized.
threads[core].run(io_pairs[core], workload);
```

### Full bring-up context (for reference)

```zig
const nvme = @import("nvme");
const stdx = @import("stdx");

const CidWord = nvme.controller.queue.CidAllocator.Word;
const Cqe = nvme.commands.cqe.Cqe;
const Pair = nvme.controller.queue.Pair(MyHpetBackend);
const Sqe = nvme.commands.sqe.Sqe;

const capacity: u16 = 64;
var sq_backing: [capacity]Sqe align(@alignOf(Sqe)) = .{.{}} ** capacity;
var cq_backing: [capacity]Cqe align(@alignOf(Cqe)) = .{.{}} ** capacity;
var cid_words: [stdx.bits.word.count(CidWord, capacity)]CidWord = @splat(0);

var admin_sq = try nvme.controller.queue.SubmissionQueue.init(.{
    .qid = .admin,
    .capacity = capacity,
    .ring = try stdx.dma.Buffer(Sqe).init(&sq_backing, asq_addr),
    .cid_words = &cid_words,
    .doorbell = doorbells.submissionQueue(.admin),
});
var admin_cq = try Pair.Cq.init(.{
    .qid = .admin,
    .capacity = capacity,
    .ring = try stdx.dma.Buffer(Cqe).init(&cq_backing, acq_addr),
    .doorbell = doorbells.completionQueue(.admin),
    .clock = .{ .backend = hpet_backend },
});
var admin = try Pair.init(admin_sq, admin_cq);

// Optional direct doorbell access reads as sq.doorbell().setTail(...); the
// queue types encapsulate every write for correctness, so callers only need
// this when composing their own diagnostics or panic paths.
_ = admin.sq().doorbell();
```

## Required tests `[znvme]`

`[znvme]` Test file `test/controller/queue_test.zig`. Naming per `docs/guidelines/testing.md`.

### `SubmissionQueue`

- `[znvme]` `unit: submission queue init rejects zero capacity`.
- `[znvme]` `unit: submission queue init rejects mismatched ring length`.
- `[znvme]` `unit: submission queue init reports zero outstanding empty state and hasStaged false`.
- `[znvme]` `unit: submission queue reserveSlot allocates lowest CID and returns builder bound to tail slot`.
- `[znvme]` `unit: submission queue reserveSlot does not advance tail`.
- `[znvme]` `unit: submission queue stage advances tail without ringing doorbell` — verifies the caller-owned MMIO byte buffer is unchanged after `stage` (contents equal the init-time value).
- `[znvme]` `unit: submission queue stage is infallible and returns Handle carrying reservation CID and slot_index`.
- `[znvme]` `unit: submission queue stage sets hasStaged true and flush clears it`.
- `[znvme]` `unit: submission queue flush rings SQ tail doorbell with current tail` — verifies the caller-owned MMIO byte buffer holds the expected tail value.
- `[znvme]` `unit: submission queue flush is idempotent — two flushes ring the same tail twice with no intervening stage`.
- `[znvme]` `unit: submission queue flush with no staged commits still rings current tail` — legal no-op from the wire's perspective; useful for retry paths.
- `[znvme]` `unit: submission queue stage N then flush once rings the batched tail` — stage 5, verify tail advanced 5, verify doorbell buffer unchanged; then flush, verify doorbell value equals `starting_tail + 5`.
- `[znvme]` `unit: submission queue flush retry after doorbell failure re-rings the same tail` — inject a doorbell error on first flush; verify tail and unflushed_tail unchanged; second flush succeeds and updates unflushed_tail.
- `[znvme]` `unit: submission queue reserveSlot rejects SubmissionQueueFull` — fills capacity, verifies the CID pool did not grow past capacity.
- `[znvme]` `unit: submission queue reserveSlot rejects CidExhausted` — pre-reserves every CID, verifies tail unchanged.
- `[znvme]` `unit: submission queue releaseReservation frees the CID and leaves tail unchanged`.
- `[znvme]` `unit: submission queue setHeadFromSqhd accepts controller-reported head and rejects capacity overflow with InvalidSubmissionQueueHead`.
- `[znvme]` `unit: submission queue doorbell returns the underlying SubmissionQueueDoorbell value`.
- `[znvme]` `roundtrip: submission queue reserveSlot then stage then flush stamps the reserved slot decoded through Sqe accessors and rings once`.

### `CompletionQueue(Backend)`

- `[znvme]` `unit: completion queue init rejects zero capacity`.
- `[znvme]` `unit: completion queue init rejects mismatched ring length`.
- `[znvme]` `unit: completion queue pollOne returns Timeout when phase never matches and Deadline expires`.
- `[znvme]` `unit: completion queue pollOne consumes matching phase and rings CQ head doorbell once` — fabricated CQE at head slot; verify head advanced by one and doorbell store observed at `1`.
- `[znvme]` `unit: completion queue pollOne consumes a slot whose phase matches even after deadline passes`.
- `[znvme]` `unit: completion queue pollOne flips expected phase on wrap` — fill full capacity of completions; verify `expected_phase` toggles once when head wraps to zero.
- `[znvme]` `unit: completion queue pollOne composes stdx.io.poll.until with the caller Backoff`.
- `[znvme]` `unit: completion queue doorbell returns the underlying CompletionQueueDoorbell value`.
- `[znvme]` `unit: completion queue pollOne observes device-flipped phase after an initial miss`.
- `[znvme]` `unit: completion queue pollOne issues DMA acquire after phase match before CQE field decode`.
- `[znvme]` `unit: completion queue pollOne DMA acquire covers CQE fields only`.
- `[znvme]` `unit: completion queue poll drains N contiguous matched CQEs with one CQ head doorbell ring` — fabricate 5 CQEs starting at head; call `poll(buf[0..8])`; verify n == 5, head advanced 5, doorbell rung once with `head + 5`, and every buf slot decodes CID/SQID/SQHD.
- `[znvme]` `unit: completion queue poll stops at first phase mismatch even when out has room` — fabricate 3, leave rest with wrong phase; `poll(buf[0..8])` returns 3.
- `[znvme]` `unit: completion queue poll stops when out fills; remaining CQEs stay for next call` — fabricate 8, `poll(buf[0..3])` returns 3, second `poll(buf[0..8])` returns 5 without re-observing the first 3.
- `[znvme]` `unit: completion queue poll issues DMA acquire before each drained CQE field decode` — instrumented acquire counter equals count.
- `[znvme]` `unit: completion queue poll stops at wrap without spanning it` — head near capacity, 3 fabricated pre-wrap, 2 post-wrap; first `poll` returns 3, second `poll` returns 2 with expected_phase flipped.
- `[znvme]` `unit: completion queue poll retry after CQ head doorbell failure leaves head and phase unchanged and re-observes same completions`.
- `[znvme]` `unit: completion queue poll with empty out returns 0 without engaging Backoff` — deadline in the past; call returns 0 immediately.
- `[znvme]` `roundtrip: completion queue pollOne decodes cid sqid sqhd status dw0 and dw1 from a fabricated CQE`.

### `Pair(Backend)`

- `[znvme]` `unit: pair init rejects mismatched qid` — `PairMismatch`.
- `[znvme]` `unit: pair init rejects mismatched capacity` — `PairMismatch`.
- `[znvme]` `unit: pair sq and cq return the composed pointers`.
- `[znvme]` `unit: pair pollOne returns SqidMismatch for CQE SQID mismatch without advancing state`.
- `[znvme]` `unit: pair pollOne returns InvalidSubmissionQueueHead for CQE SQHD outside capacity without advancing state`.
- `[znvme]` `unit: pair pollOne returns UnknownCommandId for unallocated CQE CID without advancing state`.
- `[znvme]` `unit: pair poll returns SqidMismatch mid-chunk without advancing state` — fabricate 4 good CQEs then one with wrong SQID; verify head/phase/sq.head/cids unchanged, out untouched.
- `[znvme]` `unit: pair poll returns InvalidSubmissionQueueHead mid-chunk without advancing state`.
- `[znvme]` `unit: pair poll returns UnknownCommandId mid-chunk without advancing state`.
- `[znvme]` `unit: pair poll drains N completions with one CQ head doorbell ring and releases every CID` — reserveSlot+stage N, flush, fabricate N CQEs, poll, verify n == N, sq.outstanding() == 0, cq head doorbell rung once.
- `[znvme]` `unit: pair poll retry after CQ head doorbell failure re-observes same completions`.
- `[znvme]` `unit: pair pollOne returns completions in the order the device posts them not the order the caller submitted` — fabricate CQEs out of submit order; verify `pollOne` returns them out of order.
- `[znvme]` `unit: releaseReservation still treats unallocated reservation CID as programmer error`.
- `[znvme]` `roundtrip: pair reserveSlot stage flush and pollOne returns matching handle and syncs SQ head`.
- `[znvme]` `roundtrip: pair poll across CQ wrap tracks SQ head from the last SQHD in the chunk`.
- `[znvme]` `roundtrip: pair batched submit and batched drain — stage N, flush once, poll into an N-slot buffer, verify one SQ doorbell and one CQ doorbell over the whole cycle`.
- `[znvme]` `roundtrip: two independent pairs drain their own CQs without cross-interference` — construct two `Pair(Backend)` values sharing no state; submit and drain on each; verify each pair's outstanding/head/expected_phase advances independently.

### `RequestTable(RequestState)`

- `[znvme]` `unit: request table wrap rejects mismatched slice length with CapacityMismatch`.
- `[znvme]` `unit: request table at returns storage aliased with slots[cid.raw()]`.
- `[znvme]` `unit: request table with RequestState = void has zero-size backing`.
- `[znvme]` `roundtrip: pair pollOne plus request table correlates completion with prior state write` — submit N, populate the table under each `handle.command_id`, poll all N in device-chosen order, verify each result's `at(completion.cid)` state matches the submit-time write.

## Open questions

_(none)_
