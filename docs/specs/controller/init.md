# Controller initialization

Status: Approved.

`Controller(Backend)` validates caller-owned controller resources, drives NVMe reset, enable, ready, and shutdown transitions, and constructs the admin queue pair after a successful enable.

## What this spec is

This specification owns:

- `State`, `Error`, and `default_backoff_policy`;
- `Controller(Backend)`, `Controller.Config`, `Controller.Admin`, and `Controller.Admin.Storage`;
- controller construction from registers, page size, clock, and admin queue storage;
- `CC.EN` to `CSTS.RDY` reset and enable transitions;
- `CC.SHN` to `CSTS.SHST` shutdown transitions;
- fatal-controller handling during waits;
- admin queue register programming and admin `Pair` construction;
- admin queue access, non-waiting drain, and waiting single-completion delegation;
- controller-transition waiting, ordering, errors, state, lifetime, and concurrency contracts.

## What this spec is not

This specification does not own:

- PCI discovery, BAR mapping, DMA allocation, or page-table configuration;
- Identify, Set Features, Create I/O Queue, or NVM command encoding;
- I/O queue creation policy or a queue-set aggregate;
- MSI/MSI-X configuration, interrupt routing, handler registration, or event synchronization;
- retry policy after timeout, fatal status, or command completion failure;
- wall-clock or scheduler policy;
- message-based NVMe transport initialization;
- big-endian host or target compatibility.

## Terminology

- **Controller state** is the last transition that znvme completed or the fatal state that a wait observed. It is not a live copy of `CSTS`.
- **Admin readiness** means that `enable` completed and constructed the admin queue pair after the most recent successful `reset`.
- **Transition wait** means a `stdx.io.poll.until` loop over `CSTS` with a caller-owned deadline and `Backoff`.

## Public namespace

The public module is `nvme.controller.init`, implemented by `src/controller/init.zig` and exported through `src/controller/root.zig` and `src/nvme.zig`.

This specification approves:

- `State`;
- `Error`;
- `default_backoff_policy`;
- `Controller(Backend)` and its public nested types and methods.

This specification does not approve a separate `disable` method, an interrupt provider, an I/O queue aggregate, or an owned storage allocator.

## Cross-spec relationships

This specification depends on:

- `docs/specs/core/registers.md` for `CAP`, `CC`, `CSTS`, `AQA`, `ASQ`, and `ACQ` access;
- `docs/specs/core/doorbell.md` for the doorbell view derived from `CAP.DSTRD`;
- `docs/specs/core/prp.md` for `PageSize`;
- `docs/specs/controller/queue.md` for the admin `Pair`, completion drain, and polling contracts;
- `docs/specs/project/scope.md` for allocation, interrupt, and target boundaries.

This specification composes with, but does not own:

- `stdx.time.Clock.Monotonic(Backend)`, `Deadline`, and `Backoff`;
- `stdx.io.poll.until` for transition waits;
- `stdx.barrier.mmio.acquire()` after each `CSTS` load;
- caller-owned `stdx.dma.Buffer(Sqe)` and `stdx.dma.Buffer(Cqe)` storage.

## Data structures and representation

`Controller(Backend)` and its nested types are semantic types with no ABI guarantee.

`State` has these values:

- `.unknown`: `init` completed, but znvme has not completed a reset;
- `.disabled`: reset completed with `CSTS.RDY == 0`;
- `.ready`: enable completed with `CSTS.RDY == 1` and the admin pair exists;
- `.shutdown_occurring`: `CC.SHN` was written and shutdown has not completed;
- `.shutdown_complete`: `CSTS.SHST == .complete` was observed;
- `.fatal`: a transition wait observed `CSTS.CFS == 1`.

`Controller.Config` borrows controller registers, admin SQ storage, admin CQ storage, and a CID bitmap. `Controller` stores these borrows and one clock backend value.

`Controller.ready_timeout` is a caller-visible duration suggestion. If `ready_timeout_override` is null, `init` derives it from `CAP.TO * 500 ms`. A non-null override replaces the derived duration without clamping. Transition methods use only their explicit `deadline`; they do not read `ready_timeout` during a wait.

`Controller.admin` stores the admin queue storage for the controller lifetime. It stores an admin pair only after successful enable.

`[nvme]` Memory-based controller initialization requires the host to observe `CSTS.RDY == 0`, program `AQA`, `ASQ`, `ACQ`, and `CC`, set `CC.EN = 1`, and wait for `CSTS.RDY == 1`.

`[nvme]` The maximum ready transition time is `CAP.TO * 500 ms`.

`[nvme]` `CSTS.CFS == 1` reports Controller Fatal Status.

`[nvme]` Controller Reset changes `CC.EN` from `1` to `0`. It deletes controller-side I/O queues and aborts outstanding admin commands.

`[nvme]` Normal or abrupt shutdown writes `CC.SHN` and waits for `CSTS.SHST == 10b`.

`[nvme]` `ASQ` and `ACQ` base addresses are memory-page-aligned.

## Global invariants

- Controller operations MUST NOT allocate memory.
- Controller operations MUST NOT use hidden global state.
- The caller MUST serialize all mutable operations on one `Controller` and its admin pair.
- The caller MUST provide exclusive ownership of each `Backoff` during a transition or completion poll.
- The caller MUST keep the MMIO mapping, admin queue storage, CID bitmap, and clock dependencies valid for the controller lifetime.
- `admin.ready()` MUST equal whether the controller stores an admin pair.
- A successful `reset` MUST clear the admin pair and set state to `.disabled`.
- A successful `enable` MUST construct the admin pair before it sets state to `.ready`.
- A successful `shutdown` MUST preserve the admin pair and set state to `.shutdown_complete`.
- A transition wait that observes `CSTS.CFS` MUST set state to `.fatal` before it returns `error.ControllerFatal`.
- Each `CSTS` load in a transition wait MUST be followed immediately by `stdx.barrier.mmio.acquire()` before the observed fields are evaluated.
- Copying a controller and mutating both copies is prohibited. Moving the controller before use is permitted.

## API

```zig
pub const State = enum {
    unknown,
    disabled,
    ready,
    shutdown_occurring,
    shutdown_complete,
    fatal,
};

pub const Error = error{
    ControllerFatal,
    Timeout,
    NotDisabled,
    NotReady,
    PageSizeUnsupported,
    UnsupportedCommandSet,
    AdminPairMismatch,
} || QueueBase.Error
    || Aqa.Error
    || stdx.time.Duration.Error
    || queue.InitError
    || queue.SubmissionQueue.ReserveError
    || queue.SubmissionQueue.FlushError
    || queue.PollError;

pub const default_backoff_policy: stdx.time.Backoff.Policy;

pub fn Controller(comptime Backend: type) type {
    return struct {
        pub const Clock = stdx.time.Clock.Monotonic(Backend);
        pub const Pair = queue.Pair(Backend);

        pub const Admin = struct {
            pub const Storage = struct {
                sq: stdx.dma.Buffer(Sqe),
                cq: stdx.dma.Buffer(Cqe),
                cid_words: []queue.CidAllocator.Word,
            };

            pub fn ready(self: *const Admin) bool;
            pub fn sq(self: *Admin) *queue.SubmissionQueue;
            pub fn cq(self: *Admin) *Pair.Cq;
            pub fn drain(
                self: *Admin,
                out: []queue.Completion,
            ) queue.DrainError!usize;
            pub fn pollOne(
                self: *Admin,
                deadline: stdx.time.Deadline,
                backoff: *stdx.time.Backoff,
            ) queue.PollError!queue.Completion;
        };

        pub const Config = struct {
            registers: ControllerRegisters,
            admin: Admin.Storage,
            page_size: PageSize,
            clock: Clock,
            ready_timeout_override: ?stdx.time.Duration = null,
        };

        registers: ControllerRegisters,
        admin: Admin,
        page_size: PageSize,
        clock: Clock,
        db: doorbell.Doorbells,
        ready_timeout: stdx.time.Duration,
        state: State,

        pub fn init(config: Config) Error!@This();
        pub fn doorbells(self: @This()) doorbell.Doorbells;
        pub fn reset(
            self: *@This(),
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void;
        pub fn enable(
            self: *@This(),
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void;
        pub fn shutdown(
            self: *@This(),
            kind: ShutdownNotification,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void;
        pub fn pollReady(
            self: *@This(),
            target: bool,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void;
        pub fn pollShutdown(
            self: *@This(),
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void;
    };
}
```

The signatures in this section are normative. Function bodies and private declarations are implementation details and MUST NOT be inferred from the signature-only snippets.

### `Controller.init`

#### Contract

`init` MUST load `CAP` once and validate:

- the controller advertises the NVM Command Set;
- `page_size` is within `CAP.MPSMIN..CAP.MPSMAX`;
- admin SQ and CQ lengths are equal;
- the admin depth converts to `u16` and is valid for `AQA`;
- ASQ and ACQ DMA addresses are page-aligned;
- the CID bitmap can represent the admin depth;
- the derived `CAP.TO * 500 ms` duration is representable when no override is supplied.

On success, `init` MUST set state to `.unknown`, leave `admin.ready()` false, derive doorbells from `CAP.DSTRD`, and store either the verbatim timeout override or the `CAP.TO`-derived duration.

#### Errors and fault behavior

`init` MUST return `error.UnsupportedCommandSet`, `error.PageSizeUnsupported`, or `error.AdminPairMismatch` for the corresponding validation failure. It MUST propagate applicable `Aqa.Error`, `QueueBase.Error`, `CidAllocator.Error`, and `Duration.Error` values. It MUST NOT write controller registers.

#### Locking and waiting

Never.

#### Allocation behavior

Never. `init` borrows all supplied mappings and buffers.

#### NMI/interrupt safety

`init` is not an interrupt or NMI entry point. The caller MUST provide exclusive initialization ownership.

#### Memory ordering

The `CAP` read uses the ordering contract owned by `ControllerRegisters.cap`.

#### Concurrency effects

The caller MUST NOT concurrently access the controller during initialization.

#### Invalidation and lifetime

All borrowed resources MUST outlive the returned controller.

#### Complexity/progress

O(1) validation and one `CAP` load.

### `Controller.reset`

#### Contract

`reset` MUST load `CC`. If `CC.EN != 0`, it MUST write disabled `CC`. It MUST then wait for `CSTS.RDY == 0`.

On success, `reset` MUST clear the admin pair and set state to `.disabled`. Calling `reset` when `CC.EN == 0` is permitted and still requires confirmation that `CSTS.RDY == 0`.

#### State transitions

- success: any state to `.disabled`;
- fatal observation: any state to `.fatal`;
- timeout: cached state and admin readiness remain unchanged, although `CC.EN` may already have been cleared.

#### Errors and fault behavior

`reset` MUST return `error.ControllerFatal` when the wait observes `CSTS.CFS`. It MUST return `error.Timeout` when the deadline expires. On either error, it MUST NOT clear the stored admin pair. A failed reset is not retry-transparent because the operation may already have written `CC.EN = 0`.

#### Locking and waiting

`reset` uses a transition wait and can spin, yield, or sleep according to the caller's `Backoff`.

#### Allocation behavior

Never.

#### NMI/interrupt safety

`reset` MUST NOT run in an interrupt or NMI context unless the caller's clock, `Backoff`, and platform permit every possible wait action. Normal callers MUST run it in serialized process or firmware control context.

#### Memory ordering

Every `CSTS` load is followed by `stdx.barrier.mmio.acquire()` before field evaluation.

#### Concurrency effects

The caller MUST stop queue submission and serialize controller and admin-pair access before reset.

#### Invalidation and lifetime

A successful reset invalidates every pointer previously returned by `Admin.sq()` or `Admin.cq()`, every outstanding admin handle, and all controller-side I/O queues. Caller-owned storage remains allocated and can be reused after re-enable.

#### Complexity/progress

O(wait attempts). Progress depends on controller state, deadline, clock, and backoff policy.

### `Controller.enable`

#### Contract

`enable` MUST accept only state `.disabled`. It MUST program `AQA`, `ASQ`, `ACQ`, and an NVM-enabled `CC` with:

- `CC.CSS = 0`;
- `CC.AMS = 0`;
- `CC.MPS = log2(page_size.bytes) - 12`;
- `CC.IOSQES = 6`;
- `CC.IOCQES = 4`;
- `CC.CRIME = 0`;
- `CC.EN = 1`.

It MUST then wait for `CSTS.RDY == 1`. On success, it MUST construct the admin SQ and CQ over the stored buffers, compose the admin pair, and set state to `.ready`.

#### State transitions

- `.disabled` to `.ready` on success;
- `.disabled` to `.fatal` on fatal observation;
- `.disabled` remains cached on timeout, although controller registers have been programmed and `CC.EN` may remain set;
- every other initial state returns `error.NotDisabled` without a transition.

#### Errors and fault behavior

For state other than `.disabled`, `enable` MUST return `error.NotDisabled` before it writes queue or controller configuration registers. During the wait, it MUST return `error.ControllerFatal` or `error.Timeout` as applicable. On wait failure, `admin.ready()` MUST remain false. A failed enable is not retry-transparent because controller registers have already been written.

#### Locking and waiting

`enable` uses a transition wait and can spin, yield, or sleep according to `Backoff`.

#### Allocation behavior

Never. Admin queue construction wraps stored caller-owned buffers and CID storage.

#### NMI/interrupt safety

The `reset` interrupt-context restriction applies.

#### Memory ordering

Register writes use the ordering contracts of `ControllerRegisters`. Every `CSTS` wait load is followed by `stdx.barrier.mmio.acquire()` before field evaluation.

#### Concurrency effects

The caller MUST provide exclusive controller ownership and MUST NOT use admin accessors until `enable` succeeds.

#### Invalidation and lifetime

A successful enable creates new admin queue state over the stored buffers. Handles or queue pointers from an earlier enable remain invalid.

#### Complexity/progress

O(wait attempts).

### `Controller.shutdown`

#### Contract

`shutdown` MUST accept only state `.ready`. `kind` MUST be `.normal` or `.abrupt`. The operation MUST write `CC.SHN`, set state to `.shutdown_occurring`, and wait for `CSTS.SHST == .complete`.

On success, it MUST set state to `.shutdown_complete` and preserve the admin pair for final completion drain.

#### State transitions

- `.ready` to `.shutdown_occurring` after the `CC.SHN` write;
- `.shutdown_occurring` to `.shutdown_complete` on success;
- `.shutdown_occurring` to `.fatal` on fatal observation;
- `.shutdown_occurring` remains on timeout;
- other states return `error.NotReady` without a transition.

#### Errors and fault behavior

`shutdown` MUST return `error.NotReady` before a register write when state is not `.ready`. An invalid `kind` is a programmer error and MUST trap when runtime safety checks are enabled. The wait MUST return `error.ControllerFatal` or `error.Timeout` as applicable. On timeout, the admin pair remains ready.

#### Locking and waiting

`shutdown` uses a transition wait and can spin, yield, or sleep according to `Backoff`.

#### Allocation behavior

Never.

#### NMI/interrupt safety

The `reset` interrupt-context restriction applies.

#### Memory ordering

Every `CSTS` wait load is followed by `stdx.barrier.mmio.acquire()` before field evaluation.

#### Concurrency effects

Before shutdown, the caller MUST stop new submissions and apply its queue-drain policy. The caller MUST serialize shutdown with every other controller transition.

#### Invalidation and lifetime

Successful shutdown preserves current admin queue pointers until reset or controller destruction.

#### Complexity/progress

O(wait attempts).

### `pollReady` and `pollShutdown`

#### Contract

`pollReady` MUST wait until `CSTS.RDY == target`. `pollShutdown` MUST wait until `CSTS.SHST == .complete`. Each predicate MUST test `CSTS.CFS` before it tests the target condition.

A successful direct poll operation MUST NOT change cached state. The transition methods own non-fatal state changes around these wait primitives.

#### Errors and fault behavior

Each operation MUST set state to `.fatal` and return `error.ControllerFatal` when it observes `CSTS.CFS`. Each operation MUST return `error.Timeout` when `Backoff.next` reports timeout. A timeout MUST NOT change cached state.

#### Locking and waiting

Each operation uses `stdx.io.poll.until` and can spin, yield, or sleep according to `Backoff`.

#### Allocation behavior

Never.

#### NMI/interrupt safety

These operations have the same interrupt-context restriction as `reset`.

#### Memory ordering

Each predicate MUST perform a volatile `CSTS` load, then `stdx.barrier.mmio.acquire()`, then field evaluation.

#### Concurrency effects

The caller MUST provide exclusive controller and `Backoff` ownership.

#### Complexity/progress

O(wait attempts).

### Admin access and completion operations

#### Contract

`Admin.ready()` MUST return true exactly when the admin pair exists. `Admin.sq()` and `Admin.cq()` MUST return pointers to the initialized pair. `Admin.drain(out)` MUST delegate to `Pair.drain(out)`. `Admin.pollOne(deadline, backoff)` MUST delegate to `Pair.pollOne`.

`Admin.sq`, `Admin.cq`, `Admin.drain`, and `Admin.pollOne` MUST assert `Admin.ready()`. Calling one before successful enable or after successful reset is a programmer error.

#### Errors and fault behavior

`Admin.drain` MUST propagate `queue.DrainError`. `Admin.pollOne` MUST propagate `queue.PollError`. Pair error and output-validity contracts apply unchanged.

#### Locking and waiting

Accessors and `drain` never wait. `pollOne` waits according to the pair contract.

#### Allocation behavior

Never.

#### NMI/interrupt safety

`Admin.drain` has the same interrupt-context contract as `Pair.drain`. Accessors provide no synchronization. `Admin.pollOne` has the same interrupt-context restriction as `Pair.pollOne`.

#### Memory ordering

Completion operations use the ordering contracts of the delegated pair operation.

#### Concurrency effects

The caller MUST serialize admin access and completion consumption with controller reset and enable.

#### Invalidation and lifetime

Pointers returned by `sq` and `cq` remain valid until successful reset or controller destruction. Successful reset invalidates them.

#### Complexity/progress

Accessors are O(1). Completion operation complexity matches the delegated pair operation.

### `doorbells` and `ready_timeout`

`doorbells()` MUST return the `Doorbells` value derived from the init-time `CAP.DSTRD`. It does not allocate, wait, synchronize, or access MMIO.

`ready_timeout` MUST remain the init-time derived or overridden value. It is a suggestion for caller deadline construction and does not mutate automatically.

`default_backoff_policy` MUST have:

- `spin_iterations = 128`;
- `yield_iterations = 0`;
- `yield = null`;
- `initial_wait = Duration.fromMicros(1)`;
- `max_wait = Duration.fromMillis(1)`;
- `growth_shift = 1`.

The caller MAY copy or replace this policy. A caller that reuses one `Backoff` across transitions MUST reset it between transitions.

## Implementation constraints

- The implementation MUST NOT allocate, install callbacks, register interrupts, create locks, call syscalls directly, or use hidden globals.
- Transition predicates MUST load `CSTS` on every attempt and MUST NOT cache it across attempts.
- `enable` MUST use only init-validated queue depths, DMA addresses, page size, and CID storage; repeated validation in `enable` is not required.
- Admin queue construction MUST occur only after the ready wait succeeds.
- Admin pair removal MUST occur only after the reset wait succeeds.
- `Admin.drain` and `Admin.pollOne` MUST delegate to the stored pair; they MUST NOT duplicate queue mechanics.

## Testing

Test file: `test/controller/init_test.zig`.

Required tests MUST cover:

- unsupported command-set rejection;
- page size below `CAP.MPSMIN` and above `CAP.MPSMAX`;
- unequal admin SQ/CQ lengths;
- invalid queue depth and undersized CID bitmap;
- misaligned ASQ and ACQ addresses;
- `CAP.TO` timeout derivation and verbatim shorter or longer override;
- doorbell derivation from `CAP.DSTRD`;
- reset with `CC.EN` set and reset idempotence with `CC.EN` clear;
- reset timeout and fatal status;
- enable register bytes, state precondition, timeout, and fatal status;
- admin readiness before enable, after enable, and after reset;
- normal and abrupt shutdown encodings;
- shutdown state precondition, timeout, fatal status, and admin-pair preservation;
- `pollReady` MMIO acquire ordering;
- reset-enable-reset state round trip;
- reset-enable-shutdown state round trip;
- initialized `Admin.drain` delegation with an empty CQ.

A process-aborting assertion failure is not a runtime unit-test requirement because Zig provides no repository-supported `expectPanic` equivalent. Positive tests and source-level assertions enforce invalid `ShutdownNotification` and unready-admin contracts.

## Usage examples

The caller uses `ready_timeout` to construct a deadline and resets the caller-owned `Backoff` between transitions:

```zig
var backoff = stdx.time.Backoff.init(nvme.controller.init.default_backoff_policy);

const reset_deadline = try stdx.time.Deadline.now(&ctrl.clock, ctrl.ready_timeout);
try ctrl.reset(reset_deadline, &backoff);
backoff.reset();

const enable_deadline = try stdx.time.Deadline.now(&ctrl.clock, ctrl.ready_timeout);
try ctrl.enable(enable_deadline, &backoff);
```
