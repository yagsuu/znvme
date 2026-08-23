# Controller queue types

Status: Approved.

`SubmissionQueue`, `CompletionQueue(Backend)`, and `Pair(Backend)` implement caller-owned NVMe submission and completion queue mechanics, including batching, doorbells, phase tags, command identifiers, non-waiting completion drain, and deadline-driven completion polling.

## What this spec is

This specification owns:

- `SubmissionQueue` and its reserve, stage, flush, and reservation-release operations;
- `CompletionQueue(Backend)` and its non-waiting `drain`, deadline-driven `poll`, and `pollOne` operations;
- `Pair(Backend)` and its completion validation and CID-retirement operations;
- `Completion`, `Handle`, and `RequestTable(RequestState)`;
- queue capacity, head, tail, phase-tag, and CID invariants;
- queue-local waiting, memory-ordering, error, lifetime, and concurrency contracts.

## What this spec is not

This specification does not own:

- command encoding or command-specific validation (`docs/specs/commands/admin.md`, `docs/specs/commands/nvm.md`);
- controller reset, enable, or shutdown (`docs/specs/controller/init.md`);
- doorbell offset arithmetic (`docs/specs/core/doorbell.md`);
- queue storage allocation or DMA mapping;
- a queue-set aggregate, scheduler, reactor, or cross-pair routing policy;
- a shared completion queue for multiple submission queues;
- interrupt provisioning, MSI/MSI-X configuration, vector routing, handler registration, masking, acknowledgement, deferred-work scheduling, or event-latch synchronization;
- internal locking or concurrent access to one queue pair;
- retry policy for completion status fields;
- big-endian host or target compatibility.

## Terminology

- A **posted CQE** is a CQE at the current CQ head whose phase equals `expected_phase`.
- A **drain** consumes CQEs that are posted when the operation inspects the CQ. A drain does not wait for a CQE.
- A **poll** waits for the first posted CQE until a caller-supplied deadline, then performs a drain without another wait.
- An **internal chunk** is at most 64 completions that `Pair.drain` validates before it changes submission-side state.

## Public namespace

The public module is `nvme.controller.queue`, implemented by `src/controller/queue.zig` and exported through `src/controller/root.zig` and `src/nvme.zig`.

This specification approves these public declarations:

- `CidAllocator`;
- `SubmissionQueue.ReserveError`, `SubmissionQueue.FlushError`, `CqDrainError`, `CqPollError`, `DrainError`, `PollError`, and `InitError`;
- `Handle` and `Completion`;
- `SubmissionQueue`;
- `CompletionQueue(Backend)`;
- `Pair(Backend)`;
- `RequestTable(RequestState)`.

This specification does not approve an interrupt object, callback, handler, event, lock, queue-set type, or non-generic completion queue alias.

## Cross-spec relationships

This specification depends on:

- `docs/specs/core/ids.md` for `Cid` and `Qid`;
- `docs/specs/core/status.md` for `CompletionStatus`;
- `docs/specs/core/doorbell.md` for submission-tail and completion-head doorbells;
- `docs/specs/commands/sqe.md` for `Sqe`;
- `docs/specs/commands/cqe.md` for `Cqe`;
- `docs/specs/project/scope.md` for allocation, interrupt, target, and ownership boundaries.

This specification composes with, but does not own:

- `stdx.dma.Buffer(T)` for caller-owned queue storage;
- `stdx.tags.TagAllocator.Bounded` for outstanding CIDs;
- `stdx.time.Clock.Monotonic(Backend)`, `Deadline`, and `Backoff` for polling;
- `stdx.io.poll.until` for the first-completion wait;
- `stdx.barrier.mmio.release()` inside the SQ tail doorbell;
- `stdx.barrier.dma.acquire()` between a matched CQE phase load and CQE field loads.

## Data structures and representation

`SubmissionQueue`, `CompletionQueue(Backend)`, and `Pair(Backend)` are semantic types. They have no ABI or wire-layout guarantee.

One `Pair(Backend)` binds one SQ and one CQ. The SQ and CQ MUST have the same `Qid` and capacity. The caller composes multiple independent pairs when it needs multiple I/O queues.

`SubmissionQueue.tail` identifies the next empty SQ slot. `unflushed_tail` records the tail value last written to the SQ tail doorbell. `head` records the last controller-consumed position reported through CQE `SQHD`.

`CompletionQueue.head` identifies the next CQE to inspect. `expected_phase` starts at `1`. The completion queue flips `expected_phase` when `head` wraps to zero.

`[nvme]` The controller consumes SQEs through `SQyTDBL`, posts CQEs at the CQ tail, and reuses a CQ slot only after the host advances the CQ head doorbell.

`[nvme]` A CQE is new when its Phase Tag equals the host's expected phase for that slot.

`[nvme]` `Cqe.SQHD` reports the SQ head that the controller has consumed.

`[nvme]` A CID MUST be unique among outstanding commands on one SQ. The controller echoes the SQE CID in the corresponding CQE.

`Handle` contains the CID and SQ slot index assigned during submission. `Completion` contains the decoded CQE fields after phase matching. `RequestTable(RequestState)` maps each CID to caller-owned request state.

The caller owns every SQ ring, CQ ring, CID bitmap, request-state slice, output slice, and DMA mapping. The caller MUST keep the backing storage valid for the complete lifetime of every queue value that borrows it.

## Global invariants

- Queue operations MUST NOT allocate memory.
- Queue operations MUST NOT use hidden global state.
- The caller MUST serialize all mutable operations on one `SubmissionQueue`, `CompletionQueue`, or `Pair`.
- The caller MUST NOT mutate two copied values that represent the same initialized queue state. Moving a queue value before use is permitted.
- `SubmissionQueue.capacity` and `CompletionQueue.capacity` MUST equal the corresponding ring length and MUST be nonzero.
- A valid `Pair` MUST retain equal SQ/CQ QIDs and capacities.
- `SubmissionQueue.tail`, `unflushed_tail`, and `head` MUST remain less than `capacity`.
- `CompletionQueue.head` MUST remain less than `capacity`.
- A CID MUST remain allocated from `reserveSlot` until successful completion retirement or `releaseReservation`.
- A completion operation MUST issue `stdx.barrier.dma.acquire()` after each matched phase load and before it reads the remaining fields of that CQE.
- A completion operation MUST advance CQ state only after the CQ head doorbell write succeeds.
- An interrupt notification MUST NOT replace CQ phase inspection as the completion-readiness condition.
- No queue operation provides internal thread, interrupt, or NMI synchronization.

## API

```zig
pub const CidAllocator = stdx.tags.TagAllocator.Bounded(ids.CidDomain, u16);

pub const CqDrainError = doorbell.CompletionQueueDoorbell.Error;

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

pub const Completion = struct {
    cid: Cid,
    sqid: Qid,
    sqhd: u16,
    status: CompletionStatus,
    dw0: u32,
    dw1: u32,

    pub fn statusIsSuccess(self: Completion) bool;
};

pub const SubmissionQueue = struct {
    pub const ReserveError = error{
        SubmissionQueueFull,
        CidExhausted,
    } || CidAllocator.Error;

    pub const FlushError = doorbell.SubmissionQueueDoorbell.Error;

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
    tail: u16,
    unflushed_tail: u16,
    head: u16,
    cids: CidAllocator,
    db: doorbell.SubmissionQueueDoorbell,

    pub fn init(params: Init) InitError!SubmissionQueue;
    pub fn doorbell(self: SubmissionQueue) doorbell.SubmissionQueueDoorbell;
    pub fn isFull(self: SubmissionQueue) bool;
    pub fn hasStaged(self: SubmissionQueue) bool;
    pub fn outstanding(self: SubmissionQueue) usize;
    pub fn reserveSlot(self: *SubmissionQueue) ReserveError!Reservation;
    pub fn releaseReservation(self: *SubmissionQueue, reservation: Reservation) void;
    pub fn stage(self: *SubmissionQueue, reservation: Reservation) Handle;
    pub fn flush(self: *SubmissionQueue) FlushError!void;
    pub fn setHeadFromSqhd(self: *SubmissionQueue, sqhd: u16) DrainError!void;
    pub fn releaseCompletedCid(self: *SubmissionQueue, cid: Cid) DrainError!void;
};

pub fn CompletionQueue(comptime Backend: type) type {
    return struct {
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
        head: u16,
        expected_phase: u1,
        db: doorbell.CompletionQueueDoorbell,
        clock: Clock,

        pub fn init(params: Init) InitError!@This();
        pub fn doorbell(self: @This()) doorbell.CompletionQueueDoorbell;
        pub fn drain(self: *@This(), out: []Completion) CqDrainError!usize;
        pub fn poll(
            self: *@This(),
            out: []Completion,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) CqPollError!usize;
        pub fn pollOne(
            self: *@This(),
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) CqPollError!Completion;
    };
}

pub fn Pair(comptime Backend: type) type {
    return struct {
        pub const Cq = CompletionQueue(Backend);

        pub fn init(submission: SubmissionQueue, completion: Cq) InitError!@This();
        pub fn sq(self: *@This()) *SubmissionQueue;
        pub fn cq(self: *@This()) *Cq;
        pub fn drain(self: *@This(), out: []Completion) DrainError!usize;
        pub fn poll(
            self: *@This(),
            out: []Completion,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) PollError!usize;
        pub fn pollOne(
            self: *@This(),
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) PollError!Completion;
    };
}

pub fn RequestTable(comptime RequestState: type) type {
    return struct {
        slots: []RequestState,
        capacity: u16,

        pub fn wrap(slots: []RequestState, capacity: u16) InitError!@This();
        pub fn at(self: *@This(), cid: Cid) *RequestState;
        pub fn atConst(self: *const @This(), cid: Cid) *const RequestState;
    };
}
```

The signatures in this section are normative. Function bodies and private declarations are implementation details and MUST NOT be inferred from the signature-only snippets.

### `SubmissionQueue.init`

#### Contract

`init` MUST reject zero capacity or a ring length that differs from `capacity` with `error.CapacityMismatch`. `init` MUST wrap the caller-owned CID bitmap for the same capacity. On success, all indices and the outstanding CID count MUST start at zero.

#### Errors and fault behavior

On error, `init` MUST NOT return a queue value. It MUST propagate applicable `CidAllocator.Error` values.

#### Locking and waiting

Never.

#### Allocation behavior

Never. `init` borrows the ring and CID bitmap.

#### Concurrency effects

The returned value requires caller serialization after initialization.

#### Invalidation and lifetime

The ring and CID bitmap MUST outlive the returned queue.

#### Complexity/progress

O(1), excluding the bounded allocator-wrap validation required by `CidAllocator`.

### Submission reserve, stage, release, and flush

#### Contract

`isFull` MUST return true when `(tail + 1) % capacity == head`. `reserveSlot` MUST return `error.SubmissionQueueFull` without allocating a CID when the SQ is full. Otherwise, `reserveSlot` MUST allocate the lowest free CID, return the SQ slot at `tail`, and leave `tail` unchanged.

The caller MUST either pass a reservation to `stage` immediately or release it through `releaseReservation`. The caller MUST NOT interleave another reservation on the same SQ.

`stage` MUST assert that `reservation.slot_index == tail`, advance `tail` with wrap, and return the reservation CID and slot index. `stage` MUST NOT write MMIO.

`releaseReservation` MUST free the reservation CID and leave `tail` unchanged. Releasing an unallocated reservation is a caller-contract violation and MUST trap when runtime safety checks are enabled.

`flush` MUST write the current `tail` to the SQ tail doorbell, including when no new entries are staged. On success, `flush` MUST set `unflushed_tail = tail`.

#### State transitions

- `reserveSlot`: allocates one CID; indices do not change.
- `stage`: advances `tail`; CID remains allocated.
- `releaseReservation`: releases one CID; indices do not change.
- successful `flush`: sets `unflushed_tail` to `tail`.

#### Errors and fault behavior

`reserveSlot` MUST return `error.CidExhausted` when no CID is available. `flush` MUST propagate its doorbell error. On a `flush` error, `tail` and `unflushed_tail` MUST remain unchanged from their pre-call values. A retry MUST write the same tail.

#### Locking and waiting

Never.

#### Allocation behavior

No memory allocation. `reserveSlot` allocates one tag from caller-owned bitmap storage.

#### NMI/interrupt safety

These operations provide no interrupt or NMI synchronization. A caller MAY use an operation in an interrupt context only when that context has exclusive ownership of the SQ and the platform permits the required memory or MMIO access.

#### Memory ordering

`flush` MUST publish staged SQE writes through the `stdx.barrier.mmio.release()` performed by `SubmissionQueueDoorbell.setTail` before its MMIO store.

#### Concurrency effects

The caller MUST serialize all operations on one SQ.

#### Invalidation and lifetime

A reservation slot pointer remains valid until the caller stages or releases that reservation, provided the caller retains the ring storage. `stage` consumes the reservation. `releaseReservation` consumes the reservation. A `Handle` remains a value-only CID/slot correlation token; queue reset or destruction ends its useful lifetime.

#### Complexity/progress

Each operation is O(1) and wait-free with respect to software state. An MMIO store can still have platform-defined completion latency.

### `CompletionQueue.drain`

#### Contract

If `out.len == 0`, `drain` MUST return `0` without loading a CQE or writing the CQ head doorbell.

`drain` MUST load `Cqe.phase()` at `ring[head]`. If the phase does not equal `expected_phase`, `drain` MUST return `0` without a DMA acquire, state change, output write, or doorbell write.

After the first phase match, `drain` MUST consume contiguous posted CQEs until `out` is full, a phase mismatches, or the CQ reaches its wrap boundary. One call MUST NOT consume CQEs on both sides of a wrap.

For a non-empty drain, `drain` MUST write the new CQ head exactly once. It MUST update `head` only after the doorbell write succeeds. It MUST flip `expected_phase` only when the drain reaches the wrap boundary.

#### State transitions

An empty drain changes no state. A successful non-empty drain advances `head` by the returned count and flips `expected_phase` exactly when `head` wraps to zero.

#### Errors and fault behavior

`drain` MUST propagate `CqDrainError`. On a doorbell error, `head` and `expected_phase` MUST remain unchanged. The contents of `out` are unspecified on an error return, and the caller MUST NOT consume them. A retry MUST re-observe the same CQEs from the unchanged head.

#### Locking and waiting

Never. `drain` MUST NOT read the clock, invoke `Backoff`, sleep, yield, park, or call a scheduler.

#### Allocation behavior

Never.

#### NMI/interrupt safety

`drain` has no callback, allocator, clock, sleep, or lock dependency. znvme does not guarantee that the caller's MMIO mapping or platform is NMI-safe. A caller MAY invoke `drain` in an interrupt context only when that context has exclusive ownership of the CQ or pair and the platform permits the CQ head MMIO write. Concurrent process-context and interrupt-context drains are prohibited.

#### Memory ordering

`Cqe.phase()` MUST use an atomic monotonic load of the CQE status lane. `drain` MUST issue `stdx.barrier.dma.acquire()` after each matched phase load and before it reads the other fields of that CQE. This acquire orders CQE fields only. The caller MUST issue the applicable DMA acquire before it reads a separate device-written payload unless the payload API provides that ordering.

#### Concurrency effects

The caller MUST serialize all consumers of one CQ. An interrupt is a wake-up notification and is not proof that a CQE is posted.

#### Invalidation and lifetime

`out[0..n]` is initialized on success. The remaining output slots are unchanged. The CQ ring, output slice, and doorbell mapping MUST remain valid for the call.

#### Complexity/progress

O(min(`out.len`, entries before wrap)). The operation is bounded and does not retry.

### `CompletionQueue.poll` and `pollOne`

#### Contract

If `out.len == 0`, `poll` MUST return `0` without waiting. Otherwise, `poll` MUST use `stdx.io.poll.until` to wait until `ring[head]` is posted. After the first phase match, `poll` MUST perform one `drain(out)` and MUST NOT wait again during that call.

`pollOne` MUST call `poll` with a one-entry buffer and return that completion.

#### Errors and fault behavior

`poll` MUST return `error.Timeout` when `Backoff.next` reports timeout before the first phase match. After a phase match, the deadline MUST NOT truncate the drain. Doorbell errors follow `CompletionQueue.drain`.

#### Locking and waiting

`poll` and `pollOne` can spin, invoke the caller's `Backoff.Policy.yield`, or call the clock backend's `sleep`, according to `Backoff`. They do not select scheduler policy.

#### Allocation behavior

Never. `pollOne` uses one stack `Completion`.

#### NMI/interrupt safety

`poll` and `pollOne` MUST NOT be called from an interrupt or NMI context unless the caller's `Backoff`, clock backend, and platform explicitly permit every possible wait action. Interrupt consumers SHOULD use `drain`.

#### Memory ordering

After the first phase match, memory ordering is identical to `drain`.

#### Concurrency effects

The caller MUST provide exclusive ownership of the CQ and `Backoff` for the call.

#### Complexity/progress

O(wait attempts + min(`out.len`, entries before wrap)). Progress before the first CQE depends on the controller, deadline, clock backend, and backoff policy.

### `Pair.drain`

#### Contract

`Pair.drain` MUST call `CompletionQueue.drain` in internal chunks of at most 64 completions. It MUST validate a complete chunk before it changes submission-side state or copies that chunk to caller output.

For each completion, `Pair.drain` MUST return:

- `error.SqidMismatch` when `completion.sqid != sq.qid`;
- `error.InvalidSubmissionQueueHead` when `completion.sqhd >= sq.capacity`;
- `error.UnknownCommandId` when the completion CID is not allocated or repeats an earlier CID in the same internal chunk.

After chunk validation succeeds, `Pair.drain` MUST update `sq.head` in CQ order, release every CID, and copy the chunk to `out` in CQ order.

#### State transitions

An empty drain changes no state. A successful chunk advances CQ state, updates SQ head, and retires each chunk CID. The last CQE in CQ order determines the final SQ head for that chunk.

#### Errors and fault behavior

CQ doorbell errors follow `CompletionQueue.drain`. On a validation error, CQ state has already advanced and the CQ head doorbell has already been written. Submission-side state MUST remain unchanged for the failing chunk. The caller MUST treat the error as a controller fault and reset the pair. The caller MUST NOT consume `out` after any error return, including output produced by an earlier successful internal chunk.

#### Locking and waiting

Never.

#### Allocation behavior

Never. Each internal chunk uses at most 64 stack `Completion` values.

#### NMI/interrupt safety

The `CompletionQueue.drain` interrupt-context requirements apply. The interrupt context MUST also have exclusive ownership of submission-side CID and head state.

#### Memory ordering

CQE ordering is identical to `CompletionQueue.drain`. Pair validation and CID retirement occur after the CQ head doorbell succeeds.

#### Concurrency effects

The caller MUST serialize all SQ and CQ operations that use the pair. The caller MUST use a platform-owned event latch or an equivalent check-arm-recheck protocol to prevent a lost wake-up between an empty drain and a wait. znvme does not synchronize with the platform event source.

#### Invalidation and lifetime

Successful CID retirement invalidates outstanding-request ownership associated with each returned CID. Caller-owned request-table entries remain allocated; the caller decides when to reuse their contents.

#### Complexity/progress

O(min(`out.len`, posted CQEs)) CQ work plus O($n^2$) duplicate-CID comparisons per internal chunk, where $n \le 64$. One chunk performs at most 2,016 CID comparisons. The operation is bounded and does not retry.

### `Pair.poll` and `pollOne`

#### Contract

If `out.len == 0`, `Pair.poll` MUST return `0` without waiting. Otherwise, it MUST wait only for the first posted CQE of the complete call and then use the same chunked completion path as `Pair.drain`. An empty CQ after an exactly full 64-entry internal chunk MUST end the drain without another wait.

`Pair.pollOne` MUST call `Pair.poll` with a one-entry buffer and return that completion.

#### Errors and fault behavior

Timeout behavior follows `CompletionQueue.poll`. Drain and validation errors follow `Pair.drain`.

#### Locking and waiting

Only the first CQE can cause waiting. The caller MUST provide exclusive ownership of the pair and `Backoff`.

#### Allocation behavior

Never. Stack use is bounded by the 64-entry internal chunk and the one-entry `pollOne` buffer.

#### NMI/interrupt safety

The `CompletionQueue.poll` interrupt-context restrictions apply. Interrupt consumers SHOULD use `Pair.drain`.

#### Memory ordering

Identical to `Pair.drain` after the first phase match.

#### Concurrency effects

The caller MUST serialize every operation on the pair.

#### Complexity/progress

O(wait attempts + min(`out.len`, posted CQEs)). The call performs at most one wait phase.

### Cross-boundary hooks

`SubmissionQueue.setHeadFromSqhd` MUST reject `sqhd >= capacity` with `error.InvalidSubmissionQueueHead`. On success, it MUST set `head = sqhd`.

`SubmissionQueue.releaseCompletedCid` MUST reject an unallocated or out-of-range CID with `error.UnknownCommandId`. On success, it MUST release that CID.

These hooks never allocate or wait. Callers that compose an SQ and CQ without `Pair` MUST invoke both hooks for each successfully drained completion and MUST preserve the same validation ordering as `Pair.drain`.

### `RequestTable(RequestState)`

`wrap` MUST reject `slots.len != capacity` with `error.CapacityMismatch`. `at` and `atConst` MUST return the slot at `cid.raw()`. They MUST assert `cid.raw() < capacity` because an out-of-range caller-authored CID is a programmer error.

The table borrows `slots`; the slice MUST outlive the table and every returned pointer. `at` and `atConst` do not allocate, wait, synchronize, or invalidate another pointer. Each operation is O(1).

## Implementation constraints

- The implementation MUST use caller-owned storage and MUST NOT allocate.
- The implementation MUST NOT install callbacks, handlers, locks, scheduler hooks, or hidden globals.
- `CompletionQueue.poll` and `Pair.poll` MAY use private helpers, but private declarations MUST NOT become public API.
- `CompletionQueue.drain` MUST be the single implementation of CQ phase probing, CQE decode, CQ head advancement, and phase flip used by both waiting and non-waiting paths.
- `Pair.drain` MUST be the single implementation of chunk validation, SQ-head synchronization, CID retirement, and caller-output copy used by both waiting and non-waiting paths.
- Internal chunk capacity MUST be 64 completions.
- The implementation MUST preserve direct output writes before the fallible CQ doorbell store; it MUST NOT add an avoidable output copy only to preserve `out` on error.

## Testing

Test file: `test/controller/queue_test.zig`.

### Submission queue

Required tests MUST cover:

- zero and mismatched capacity rejection;
- initial empty state and outstanding count;
- lowest-CID reservation without tail advance;
- stage without MMIO, stage handle fields, and staged-state tracking;
- one flush for one entry and for a batch;
- idempotent flush and flush with no staged entries;
- flush retry with unchanged state after doorbell failure;
- SQ-full and CID-exhausted errors;
- reservation release;
- SQHD validation;
- doorbell access;
- reserve, initialize, stage, and flush round-trip behavior.

### Completion queue

Required tests MUST cover:

- zero and mismatched capacity rejection;
- empty-output drain without CQE load or doorbell write;
- phase-mismatch drain with no state, output, clock, barrier, or doorbell effect;
- matching-phase drain without clock or `Backoff` use;
- contiguous drain stopping at mismatch;
- output-capacity stop and continuation;
- wrap stop, phase flip, and next-call consumption at index zero;
- DMA acquire before every decoded CQE;
- doorbell failure with unchanged CQ state and successful retry;
- timeout before the first phase match;
- an already-posted CQE despite an expired deadline;
- first-CQE wait followed by drain without another backoff step;
- empty-output poll without backoff;
- complete CQE field decode and status round trip;
- doorbell access.

### Pair

Required tests MUST cover:

- QID and capacity mismatch rejection;
- SQ and CQ accessors;
- empty drain with no SQ/CQ state or CID change;
- successful drain with SQHD update, CID retirement, and CQ-order output;
- SQID, SQHD, unallocated-CID, and duplicate-CID validation failures after CQ advance with unchanged submission-side state for the failing chunk;
- doorbell failure and retry;
- device completion order independent of submission order;
- reserve, stage, flush, and complete round trip;
- CQ wrap and last-SQHD behavior;
- batched SQ and CQ doorbell behavior;
- two independent pairs without cross-interference;
- exactly 64 completions followed by an empty CQ without a second wait.

### Request table

Required tests MUST cover:

- mismatched slice length;
- CID-indexed aliasing;
- `RequestState = void`;
- completion correlation with prior caller state.

A process-aborting assertion failure is not a runtime unit-test requirement because Zig provides no repository-supported `expectPanic` equivalent. Positive tests and source-level assertions enforce programmer-error contracts.

## Usage examples

An interrupt is a notification only. A serialized consumer uses the phase tag as the readiness condition:

```zig
var completions: [64]nvme.controller.queue.Completion = undefined;

while (true) {
    const n = try pair.drain(&completions);
    if (n != 0) {
        for (completions[0..n]) |completion| handle(completion);
        continue;
    }

    try platform_event.waitChecked(); // Platform-owned check-arm-recheck.
}
```
