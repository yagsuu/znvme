# Controller initialization

Status: Approved.

`Controller(Backend)` drives the NVMe controller register state machine — the `CC.EN` ↔ `CSTS.RDY` handshake, reset, and shutdown transitions — over a caller-supplied `stdx.time.Clock.Monotonic(Backend)`. It owns admin queue construction on successful enable: the caller passes admin queue storage in through `Config`, and after `enable` returns, `ctrl.admin.sq()` and `ctrl.admin.cq()` are ready to submit commands.

`Controller(Backend)` is a semantic type per `docs/specs/architecture.md` §"Two type worlds". It composes register accessors, doorbells, and queue types but carries no ABI layout of its own.

`Controller(Backend)` does not issue Identify, Set Features (Number of Queues), or Create I/O Queue commands. Those are caller-authored on top of `ctrl.admin` after `enable`; the concrete builders live in `docs/specs/commands/admin.md`.

## Owned scope

This spec owns:

- `Controller(Backend)`, the semantic type parameterized on the clock backend;
- `Controller.Config`, the construction parameter struct;
- `Controller.Admin` and `Controller.Admin.Storage`, the nested admin queue grouping;
- `Controller.State`, the observed state enum;
- the `reset` / `enable` / `shutdown` transitions;
- the `pollReady` / `pollShutdown` polling primitives;
- deadline-driven polling via `stdx.io.poll.until` composed with caller-owned `stdx.time.Backoff` state and `stdx.barrier.mmio.acquire()` after every `CSTS` load;
- `CAP.TO`-derived `ready_timeout` with a caller override;
- `CC.MPS` validation against `CAP.MPSMIN..CAP.MPSMAX`;
- `CC.CSS = 0` (NVM Command Set), `CC.IOSQES = 6`, `CC.IOCQES = 4`, `CC.CRIME = 0` — Controller Ready With Media mode;
- `AQA`, `ASQ`, `ACQ` register writes derived from `Config.admin`;
- `CSTS.CFS` handling: every poll returns `error.ControllerFatal` immediately when observed;
- construction of the admin `queue.Pair(Backend)` inside `enable`, exposed on `ctrl.admin`;
- `Controller.doorbells()`, exposing the `core.doorbell.Doorbells` derived from `CAP.DSTRD` at `init`;
- error taxonomy for the state machine.

## Deferred scope and non-goals

This spec does not own:

- Identify Controller, Identify Namespace, Set Features (Number of Queues), Create I/O SQ, Create I/O CQ — `docs/specs/commands/admin.md`;
- I/O queue-pair construction — the caller builds them from `ctrl.doorbells()` and calls `queue.SubmissionQueue.init` / `queue.CompletionQueue(Backend).init` / `queue.Pair(Backend).init` directly;
- namespace enumeration — `docs/specs/identify/namespace.md` (both CNS 00h `IdentifyNamespace` and CNS 02h `List`);
- interrupt configuration, `INTMS`, `INTMC` — deferred by `docs/specs/project/scope.md`;
- NVM Subsystem Reset (`NSSR.NSSRC`) — the offset is asserted in `docs/specs/core/registers.md`; behavior is out of first-slice scope;
- Controller Memory Buffer, Persistent Memory Region, Boot Partition, Doorbell Buffer Config, NSSD — offsets asserted upstream, behavior deferred;
- `CRTO` timeouts (`CRWMT`, `CRIMT`) and Controller Ready Independent of Media (`CRIME`) — `Controller.enable` selects Controller Ready With Media mode by clearing `CC.CRIME` (already the `Cc.nvmEnabled` default) and uses `CAP.TO` as the single timeout budget;
- retry policy on `error.Timeout` or `error.ControllerFatal` — the caller decides;
- wall-time or blocking waits — the polling loop is caller-driven via `stdx.io.poll.until` composed with caller-owned `stdx.time.Backoff` state; znvme selects no scheduler policy;
- message-based transport controller initialization (NVMe over Fabrics) — memory-mapped only;
- big-endian host or target compatibility.

## `stdx` composition

Directly consumed:

- `stdx.time.Clock.Monotonic(Backend)` — comptime parameter driving deadline reads;
- `stdx.time.Deadline` — deadline parameter on every waiting method;
- `stdx.time.Duration` — `Config.ready_timeout_override` and the `CAP.TO`-derived `ready_timeout`;
- `stdx.time.Backoff` — caller-owned backoff state threaded into every waiting method;
- `stdx.io.poll.until` — the polling primitive composing `Deadline`, `Backoff`, and a per-method predicate;
- `stdx.barrier.mmio.acquire()` — placed after every `CSTS` load, before the loaded value is decoded.

Composed through znvme-owned types:

- `core.registers.ControllerRegisters` and its typed value wrappers (`Cap`, `Cc`, `Csts`, `Aqa`, `QueueBase`, `ShutdownNotification`, `ShutdownStatus`);
- `core.doorbell.Doorbells` — derived once at `init` from `CAP.DSTRD` and exposed on `Controller.doorbells()`;
- `core.prp.PageSize` — validated `CC.MPS` value on `Config.page_size`;
- `commands.sqe.Sqe` and `commands.cqe.Cqe` — admin queue element types;
- `controller.queue.SubmissionQueue`, `CompletionQueue(Backend)`, `Pair(Backend)`, `CidAllocator` — admin queue construction inside `enable`.

## NVMe behavior

`[nvme]` Memory-based Transport Controller Initialization, per NVMe Base Specification 2.0 §3.5:

1. `[nvme]` Wait for any previous reset to complete: `CSTS.RDY == 0`.
2. `[nvme]` Configure the admin queue: write `AQA` (depths, zero-based), `ASQ` (admin SQ base address), and `ACQ` (admin CQ base address).
3. `[nvme]` Configure the controller: set `CC.CSS` per `CAP.CSS`, `CC.AMS`, `CC.MPS` within `CAP.MPSMIN..CAP.MPSMAX`, `CC.IOSQES`, `CC.IOCQES`.
4. `[nvme]` Enable the controller: write `CC.EN = 1`.
5. `[nvme]` Wait for `CSTS.RDY == 1`. The worst-case wait is `CAP.TO * 500 ms`.

`[nvme]` `CSTS.CFS = 1` signals Controller Fatal Status. Any wait aborts.

`[nvme]` Shutdown, per §3.6:

1. `[nvme]` Stop submitting new commands and drain outstanding.
2. `[nvme]` Write `CC.SHN = 01b` (normal) or `CC.SHN = 10b` (abrupt).
3. `[nvme]` Wait for `CSTS.SHST == 10b` (complete).

`[nvme]` "It is not recommended to disable the controller via the `CC.EN` field" for shutdown — `CC.EN = 0` is a Controller Reset, not a shutdown.

`[nvme]` Controller Reset, per §3.7: transition `CC.EN` from `1` to `0`. All I/O queues are deleted controller-side; outstanding admin commands are aborted. To continue, the host re-enables the controller and re-creates queues.

`[nvme]` Admin submission and completion queue base addresses (`ASQ`, `ACQ`) shall be memory-page-aligned; bits `11:0` are reserved zero.

## znvme behavior

`Controller(Backend).init(config)` performs no register I/O beyond a single `CAP` load. It validates the command-set advertisement, the requested page size against `CAP.MPSMIN..CAP.MPSMAX`, the admin queue buffer lengths, the first-slice equal-depth admin pair requirement, admin queue depth encoding, ASQ/ACQ base alignment, and admin CID bitmap capacity. It derives `Doorbells` from `CAP.DSTRD` and the `CAP.TO`-based `ready_timeout`. The initial `state` is `.unknown` until the first transition method sets it.

`Controller.reset(deadline)` clears `CC.EN` when the current `CC` load reports it set, then polls `CSTS.RDY == 0` or `error.ControllerFatal` or `error.Timeout`. Idempotent: calling `reset` on an already-disabled controller returns immediately after the poll confirms `CSTS.RDY == 0`. On success, `state` transitions to `.disabled` and `admin.ready()` returns `false`.

`Controller.enable(deadline)` refuses to run unless `state == .disabled`, returning `error.NotDisabled` for `.unknown`, `.ready`, `.shutdown_occurring`, `.shutdown_complete`, or `.fatal`. A caller must drive `Controller.reset(deadline)` to success before the first `enable`; this proves the NVMe §3.5 precondition that `CSTS.RDY == 0` before `AQA`, `ASQ`, `ACQ`, and `CC.EN = 1` are written. On the accepted path, `enable` writes `AQA` (via `Aqa.fromDepths`), `ASQ` and `ACQ` (via `QueueBase.fromDmaAddr`), and `CC` (via `Cc.nvmEnabled(mps_shift)`), where `mps_shift = log2(page_size.bytes) - 12`. Then it polls `CSTS.RDY == 1` or `error.ControllerFatal` or `error.Timeout`. On success, `enable` composes the admin `queue.Pair(Backend)` from the stored `Config.admin` storage and the derived doorbells, publishes it through the private `admin._pair`, transitions `state` to `.ready`, and `admin.ready()` starts returning `true`.

`Controller.reset` is the sole tear-down path per NVMe §3.7 controller-reset semantics: writing `CC.EN = 0` deletes controller-side I/O queues and aborts outstanding admin commands. Callers must not rely on any completion posted before the transition. There is no separate `disable` method; NVMe does not distinguish "reset" from "disable via CC.EN" — both are the same Controller Reset transition, and znvme exposes the idempotent path only.

`Controller.shutdown(kind, deadline)` refuses to run when `state != .ready` with `error.NotReady`. `kind` must be `.normal` or `.abrupt`; `.none` and reserved values are programmer errors. `shutdown` reads the current `CC`, writes `cc.withShutdown(kind)`, transitions `state` to `.shutdown_occurring`, then polls `CSTS.SHST == .complete` or `error.ControllerFatal` or `error.Timeout`. On success, `state` transitions to `.shutdown_complete`; the admin pair is preserved (`admin.ready()` stays `true`) so callers can drain final completions before deconstructing.

Every polling method composes `stdx.io.poll.until` with a per-method predicate:

- the predicate reads `self.registers.csts()` (a volatile MMIO load), calls `stdx.barrier.mmio.acquire()` immediately after, then dispatches on the observed value;
- `csts.fatal()` — the predicate returns `error.ControllerFatal` and transitions `state` to `.fatal`; the error propagates through `poll.until` untranslated;
- target predicate matched (`csts.ready() == target` or `csts.shst == .complete`) — the predicate returns the payload (`{}` for `void`-returning waits);
- otherwise the predicate returns `null` and `poll.until` invokes `Backoff.next` for the caller-selected spin / yield / sleep dispatch;
- `poll.until` returns `error.Timeout` (from `stdx.time.Deadline.TimeoutError`) when the `Backoff` reports `.timeout`.

`Controller.ready_timeout` is derived at `init`. When `Config.ready_timeout_override` is `null`, `init` sets it to `stdx.time.Duration.fromMillis(cap.readyTimeoutUnits500ms() * 500)`. When `Config.ready_timeout_override` is non-null, `init` stores the caller value verbatim — the override is a replacement, not a bound. znvme performs no clamp; callers may shorten (typical: `CAP.TO` advertises up to 127.5 seconds while real controllers finish in milliseconds) or lengthen (e.g., a slow lab / debug bring-up).

`Controller.ready_timeout` is a public suggestion callers use to compose deadlines: `try stdx.time.Deadline.now(&ctrl.clock, ctrl.ready_timeout)`. Inside `reset(deadline, backoff)` and `enable(deadline, backoff)` the poll loop only inspects the caller-passed `deadline` — `Controller.ready_timeout` is not consulted at runtime once `init` finishes.

`reset(deadline, backoff)` and `enable(deadline, backoff)` share the same `ready_timeout` suggestion. NVMe does not fix a numeric timeout for the `CC.EN` 1→0 transition, but the hardware handshake is symmetric; using one budget for both matches the Linux kernel and the majority of firmware NVMe implementations.

`Controller.shutdown(kind, deadline, backoff)` takes an explicit `deadline` and `backoff` from the caller. NVMe references `RTD3 Entry Latency` from Identify Controller as the recommended wait, but znvme does not read Identify Controller inside this spec — the caller decides.

znvme exposes a conservative `default_backoff_policy` that callers may copy or override. It has spin-only progression suitable for firmware boot (`spin_iterations = 128`, `yield_iterations = 0`, `yield = null`, `initial_wait = Duration.fromMicros(1)`, `max_wait = Duration.fromMillis(1)`, `growth_shift = 1`). Callers build a `Backoff` via `stdx.time.Backoff.init(default_backoff_policy)` and pass `&backoff` into every waiting method; they call `backoff.reset()` between phases when they reuse the same value.

`Controller.state` is the last transition znvme drove, not the current hardware truth. Callers who need the register directly read `ctrl.registers.csts()`. The cached `state` exists for the `NotDisabled` / `NotReady` precondition checks on `enable` and `shutdown`.

`Controller.admin` provides `ready()`, `sq()`, `cq()`, and `pollOne(deadline, backoff)`. `ready()` returns `true` iff `enable` has completed successfully since the last `reset`; callers branch on it before calling any of the other three. `sq()`, `cq()`, and `pollOne` assert `admin.ready()` — calling them without a ready pair is a programmer error, not a runtime failure. The backing pair is a private field (`_pair`); callers read state only through `ready()`.

## Approved API

```zig
// src/controller/init.zig
//! NVMe controller reset/enable/shutdown state machine.
//! Spec: docs/specs/controller/init.md.

const std = @import("std");

const stdx = @import("stdx");

const doorbell = @import("../core/doorbell.zig");
const prp = @import("../core/prp.zig");
const queue = @import("queue.zig");
const registers = @import("../core/registers.zig");

const Aqa = registers.Aqa;
const Cc = registers.Cc;
const ControllerRegisters = registers.ControllerRegisters;
const Cqe = @import("../commands/cqe.zig").Cqe;
const PageSize = prp.PageSize;
const QueueBase = registers.QueueBase;
const ShutdownNotification = registers.ShutdownNotification;
const Sqe = @import("../commands/sqe.zig").Sqe;

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
}
    || QueueBase.Error
    || Aqa.Error
    || stdx.time.Duration.Error
    || queue.InitError
    || queue.ReserveError
    || queue.FlushError
    || queue.PollError;

pub const default_backoff_policy: stdx.time.Backoff.Policy = .{
    .spin_iterations = 128,
    .yield_iterations = 0,
    .yield = null,
    .initial_wait = stdx.time.Duration.fromMicros(1) catch unreachable,
    .max_wait = stdx.time.Duration.fromMillis(1) catch unreachable,
    .growth_shift = 1,
};

pub fn Controller(comptime Backend: type) type {
    return struct {
        const Self = @This();

        pub const Clock = stdx.time.Clock.Monotonic(Backend);
        pub const Pair = queue.Pair(Backend);

        pub const Admin = struct {
            pub const Storage = struct {
                sq: stdx.dma.Buffer(Sqe),
                cq: stdx.dma.Buffer(Cqe),
                cid_words: []queue.CidAllocator.Word,
            };

            _storage: Storage,
            _pair: ?Pair = null,

            pub fn ready(self: *const Admin) bool {
                return self._pair != null;
            }

            pub fn sq(self: *Admin) *queue.SubmissionQueue {
                std.debug.assert(self.ready());
                return self._pair.?.sq();
            }

            pub fn cq(self: *Admin) *Pair.Cq {
                std.debug.assert(self.ready());
                return self._pair.?.cq();
            }

            pub fn pollOne(
                self: *Admin,
                deadline: stdx.time.Deadline,
                backoff: *stdx.time.Backoff,
            ) queue.PollError!queue.Completion {
                std.debug.assert(self.ready());
                return self._pair.?.pollOne(deadline, backoff);
            }
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
        state: State = .unknown,

        pub fn init(config: Config) Error!Self {
            const cap = config.registers.cap();
            if (!cap.supportsNvmCommandSet()) return error.UnsupportedCommandSet;

            const mps_bytes = config.page_size.bytes;
            if (mps_bytes < cap.minPageSizeBytes()) return error.PageSizeUnsupported;
            if (mps_bytes > cap.maxPageSizeBytes()) return error.PageSizeUnsupported;

            if (config.admin.sq.len() != config.admin.cq.len()) return error.AdminPairMismatch;

            const depth = std.math.cast(u16, config.admin.sq.len()) orelse return error.QueueDepthOutOfRange;

            _ = try Aqa.fromDepths(.{
                .submission_entries = depth,
                .completion_entries = depth,
            });
            _ = try QueueBase.fromDmaAddr(config.admin.sq.dmaAddr());
            _ = try QueueBase.fromDmaAddr(config.admin.cq.dmaAddr());
            _ = try queue.CidAllocator.wrap(config.admin.cid_words, depth);

            const ready_timeout = if (config.ready_timeout_override) |override|
                override
            else
                try stdx.time.Duration.fromMillis(@as(i64, cap.readyTimeoutUnits500ms()) * 500);

            return .{
                .registers = config.registers,
                .admin = .{ ._storage = config.admin },
                .page_size = config.page_size,
                .clock = config.clock,
                .db = doorbell.Doorbells.fromRegisters(config.registers, cap),
                .ready_timeout = ready_timeout,
            };
        }

        pub fn doorbells(self: Self) doorbell.Doorbells {
            return self.db;
        }

        pub fn reset(
            self: *Self,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void {
            const current = self.registers.cc();
            if (current.en != 0) self.registers.storeCc(Cc.disabled());

            try self.pollReady(false, deadline, backoff);
            self.admin._pair = null;
            self.state = .disabled;
        }

        pub fn enable(
            self: *Self,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void {
            if (self.state != .disabled) return error.NotDisabled;

            const storage = self.admin._storage;
            const depth: u16 = @intCast(storage.sq.len());
            const aqa = Aqa.fromDepths(.{
                .submission_entries = depth,
                .completion_entries = depth,
            }) catch unreachable;
            const asq = QueueBase.fromDmaAddr(storage.sq.dmaAddr()) catch unreachable;
            const acq = QueueBase.fromDmaAddr(storage.cq.dmaAddr()) catch unreachable;

            self.registers.storeAqa(aqa);
            self.registers.storeAsq(asq);
            self.registers.storeAcq(acq);

            const shift_bits: u6 = @intCast(std.math.log2(self.page_size.bytes) - 12);
            const mps: u4 = @intCast(shift_bits);
            self.registers.storeCc(Cc.nvmEnabled(mps));

            try self.pollReady(true, deadline, backoff);

            const admin_sq = queue.SubmissionQueue.init(.{
                .qid = .admin,
                .capacity = depth,
                .ring = storage.sq,
                .cid_words = storage.cid_words,
                .doorbell = self.db.submissionQueue(.admin),
            }) catch unreachable;
            const admin_cq = Pair.Cq.init(.{
                .qid = .admin,
                .capacity = depth,
                .ring = storage.cq,
                .doorbell = self.db.completionQueue(.admin),
                .clock = self.clock,
            }) catch unreachable;
            self.admin._pair = Pair.init(admin_sq, admin_cq) catch unreachable;
            self.state = .ready;
        }

        pub fn shutdown(
            self: *Self,
            kind: ShutdownNotification,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void {
            if (self.state != .ready) return error.NotReady;
            std.debug.assert(kind == .normal or kind == .abrupt);

            const current = self.registers.cc();
            self.registers.storeCc(current.withShutdown(kind));
            self.state = .shutdown_occurring;

            try self.pollShutdown(deadline, backoff);
            self.state = .shutdown_complete;
        }

        pub fn pollReady(
            self: *Self,
            target: bool,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void {
            const Predicate = struct {
                ctrl: *Self,
                target: bool,

                pub fn call(p: @This()) Error!?void {
                    const csts = p.ctrl.registers.csts();
                    stdx.barrier.mmio.acquire();

                    if (csts.fatal()) {
                        p.ctrl.state = .fatal;
                        return error.ControllerFatal;
                    }

                    if (csts.ready() == p.target) return {};
                    return null;
                }
            };
            return stdx.io.poll.until(
                &self.clock,
                deadline,
                backoff,
                Predicate{ .ctrl = self, .target = target },
            );
        }

        pub fn pollShutdown(
            self: *Self,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void {
            const Predicate = struct {
                ctrl: *Self,

                pub fn call(p: @This()) Error!?void {
                    const csts = p.ctrl.registers.csts();
                    stdx.barrier.mmio.acquire();

                    if (csts.fatal()) {
                        p.ctrl.state = .fatal;
                        return error.ControllerFatal;
                    }

                    if (csts.shst == .complete) return {};
                    return null;
                }
            };
            return stdx.io.poll.until(
                &self.clock,
                deadline,
                backoff,
                Predicate{ .ctrl = self },
            );
        }
    };
}
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `Controller(Backend).init` | never | never | O(1) | value type | none | `UnsupportedCommandSet`, `PageSizeUnsupported`, `AdminPairMismatch`, `Aqa.Error`, `QueueBase.Error`, `queue.CidAllocator.Error`, `stdx.time.Duration.Error` |
| `Controller.doorbells` | never | never | O(1) | borrowed value | none | infallible |
| `Controller.reset` | never | via `stdx.io.poll.until` composing caller `*Backoff` and `Deadline` | O(attempts) × (predicate + `Backoff.next`) | caller-serialized, single-owner over `*Backoff` | `mmio.acquire` after CSTS load | `Timeout`, `ControllerFatal` |
| `Controller.enable` | never | via `stdx.io.poll.until` composing caller `*Backoff` and `Deadline` | O(attempts) × (predicate + `Backoff.next`) | caller-serialized, single-owner over `*Backoff` | `mmio.acquire` after CSTS load | `NotDisabled`, `Timeout`, `ControllerFatal` |
| `Controller.shutdown` | never | via `stdx.io.poll.until` composing caller `*Backoff` and `Deadline` | O(attempts) × (predicate + `Backoff.next`) | caller-serialized, single-owner over `*Backoff` | `mmio.acquire` after CSTS load | `NotReady`, `Timeout`, `ControllerFatal` |
| `Controller.pollReady` / `pollShutdown` | never | via `stdx.io.poll.until` composing caller `*Backoff` and `Deadline` | O(attempts) × (predicate + `Backoff.next`) | caller-serialized, single-owner over `*Backoff` | `mmio.acquire` after CSTS load | `Timeout`, `ControllerFatal` |
| `Admin.ready` | never | never | O(1) | value type | none | infallible |
| `Admin.sq` / `cq` / `pollOne` | never | as `Pair.pollOne` for `pollOne`; otherwise never | O(1) | borrowed pointer | as `Pair.pollOne` | asserts `admin.ready()`; `pollOne` returns `queue.PollError` |

## Validation phases

Per `docs/specs/architecture.md` §"Validation phases":

- **Compile time.** `stdx.time.Clock.Monotonic(Backend)` signature-checks `Backend`. No layout assertions — semantic type.
- **Public validation.**
  - `init` rejects `!supportsNvmCommandSet()`, out-of-range `page_size`, admin buffer lengths that differ from the configured depths, mismatched admin SQ/CQ depths, invalid admin queue depth encoding, misaligned ASQ/ACQ DMA bases, CID bitmaps too small for the admin SQ depth, and `CAP.TO * 500` values that overflow `Duration.fromMillis`.
  - `enable` consumes only init-validated admin queue depths, ASQ/ACQ bases, and CID bitmap storage; validation failures in those paths are unreachable after successful `init`.
  - `enable` refuses `state != .disabled` with `error.NotDisabled`; callers reach `.disabled` through a successful `reset`, including the first bring-up from `.unknown`.
  - `shutdown` refuses `state != .ready` with `error.NotReady`.
- **Assertions.** `shutdown` asserts `kind == .normal or kind == .abrupt`. `Admin.sq`, `Admin.cq`, and `Admin.pollOne` assert `admin.ready()`.

## Example usage

Illustrative shape only; not part of the approved API.

```zig
const std = @import("std");

const nvme = @import("nvme");
const stdx = @import("stdx");

const CidWord = nvme.controller.queue.CidAllocator.Word;
const Controller = nvme.controller.init.Controller(MyHpetBackend);
const Cqe = nvme.commands.cqe.Cqe;
const Sqe = nvme.commands.sqe.Sqe;

const depth: u16 = 32;
var admin_sq_backing: [depth]Sqe align(@alignOf(Sqe)) = .{.{}} ** depth;
var admin_cq_backing: [depth]Cqe align(@alignOf(Cqe)) = .{.{}} ** depth;
var admin_cid_words: [stdx.bits.word.count(CidWord, depth)]CidWord = @splat(0);

var ctrl = try Controller.init(.{
    .registers = regs,
    .admin = .{
        .sq = try stdx.dma.Buffer(Sqe).init(&admin_sq_backing, asq_addr),
        .cq = try stdx.dma.Buffer(Cqe).init(&admin_cq_backing, acq_addr),
        .cid_words = &admin_cid_words,
    },
    .page_size = try nvme.core.prp.PageSize.fromBytes(4096),
    .clock = .{ .backend = hpet_backend },
});

// Bring controller up.
var backoff = stdx.time.Backoff.init(nvme.controller.init.default_backoff_policy);

const reset_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(2000));
try ctrl.reset(reset_deadline, &backoff);
backoff.reset();

const enable_deadline = try stdx.time.Deadline.now(&ctrl.clock, ctrl.ready_timeout);
try ctrl.enable(enable_deadline, &backoff);
backoff.reset();

// Admin queue pair is now ready; submit an Identify Controller.
{
    const sq = ctrl.admin.sq();
    const reservation = try sq.reserveSlot();
    errdefer sq.releaseReservation(reservation);

    Sqe.init(reservation.slot, .{
        .opcode = 0x06,
        .command_id = reservation.command_id,
        .namespace_id = .none,
        .data_pointers = identify_dptr,
        .cdw10 = 0x0000_0001,
    });

    _ = sq.stage(reservation);
}

try ctrl.admin.sq().flush();

const poll_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(500));
const completion = try ctrl.admin.pollOne(poll_deadline, &backoff);
std.debug.assert(completion.statusIsSuccess());
backoff.reset();

// Later, orderly shutdown.
const shutdown_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromSeconds(2));
try ctrl.shutdown(.normal, shutdown_deadline, &backoff);
```

## Required tests

Test file `test/controller/init_test.zig`. Naming per `docs/guidelines/testing.md`.

Test substrate: a caller-owned `[0x1000]u8 align(8)` register window with a scripted `CAP` value (`CSS.bit0 = 1`, `TO = 20` for a 10-second budget, `DSTRD = 0`, `MPSMIN = 0`, `MPSMAX = 0`), a counter-backed `stdx.time.Clock.Monotonic` backend that advances deterministically per `now()`, and scripted `CSTS` byte patterns the test rewrites between poll iterations.

- `unit: controller init rejects UnsupportedCommandSet when CAP.CSS bit 0 is clear`.
- `unit: controller init rejects PageSizeUnsupported below CAP.MPSMIN`.
- `unit: controller init rejects PageSizeUnsupported above CAP.MPSMAX`.
- `unit: controller init rejects AdminPairMismatch when admin SQ and CQ depths differ`.
- `unit: controller init propagates QueueDepthOutOfRange from Aqa.fromDepths before enable writes registers`.
- `unit: controller init propagates Misaligned from QueueBase.fromDmaAddr for unaligned admin SQ base`.
- `unit: controller init propagates Misaligned from QueueBase.fromDmaAddr for unaligned admin CQ base`.
- `unit: controller init rejects undersized admin CID bitmap before enable writes registers`.
- `unit: controller init derives ready_timeout from CAP.TO 500ms units`.
- `unit: controller init derives doorbells from CAP.DSTRD` — `ctrl.doorbells().submissionQueue(.admin).offset() == 0x1000`.
- `unit: controller init honors ready_timeout_override as a verbatim replacement (shortens and lengthens)`.
- `unit: controller reset clears CC.EN when set and polls CSTS.RDY to zero`.
- `unit: controller reset is idempotent on double-call when CC.EN already clear`.
- `unit: controller enable writes AQA ASQ ACQ and CC with mps css iosqes iocqes` — inspects exact bytes in the register buffer.
- `unit: controller enable rejects NotDisabled when state is not disabled`.
- `unit: controller enable returns Timeout when CSTS.RDY never sets`.
- `unit: controller enable returns ControllerFatal when CSTS.CFS sets during poll` — state transitions to `.fatal`.
- `unit: controller admin ready returns false before enable and true after enable success`.
- `unit: controller enable transitions admin.ready() true when CSTS.RDY sets` — verifies `ctrl.admin.ready() == true` and `ctrl.admin.sq().qid == .admin` and `ctrl.admin.cq().qid == .admin`.
- `unit: controller reset clears CC.EN and polls CSTS.RDY to zero and transitions admin.ready() false`.
- `unit: controller reset returns Timeout when CSTS.RDY never clears`.
- `unit: controller reset is idempotent with no CC write when CC.EN is already clear` — sentinel-poisoned CC lane confirms no CC write observed, `state` transitions to `.disabled`.
- `unit: controller shutdown normal sets CC.SHN to 01b and polls SHST to complete`.
- `unit: controller shutdown abrupt sets CC.SHN to 10b and polls SHST to complete`.
- `unit: controller shutdown returns NotReady when state is not ready`.
- `unit: controller shutdown returns Timeout when SHST never reports complete`.
- `unit: controller shutdown preserves admin.ready() true for final completion drain`.
- `unit: controller pollReady honors mmio.acquire ordering after each CSTS load` — behavioral check that the barrier lowers to `lfence` on x86_64.
- `roundtrip: controller reset then enable then reset transitions through disabled ready disabled and admin.ready() follows`.
- `roundtrip: controller reset then enable then shutdown normal transitions through disabled ready shutdown_complete`.

## Open questions

_(none)_
