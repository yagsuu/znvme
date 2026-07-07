# znvme

A Zig-native NVMe 2.0 protocol library.

`znvme` owns the wire types, register layout, queue mechanics, and command
builders defined by the NVMe Base Specification 2.0 and the NVM Command Set
Specification 1.0. It composes domain-neutral primitives from `stdx` (MMIO
windows, DMA buffers, monotonic clocks, tagged identifiers, poll loops) and
never allocates.

The surface is role-symmetric: the same wire types and validators serve host
drivers composing register accessors, doorbell arithmetic, admin/NVM command
builders, and completion loops, and software NVMe device emulators
interpreting host writes and authoring device responses.

## Requirements

| Field | Value |
| --- | --- |
| Minimum Zig | `0.16.0` |
| Host target | `x86_64-linux` (test suite) |
| Freestanding target | `x86_64-freestanding-none` (`zig build check`) |
| Dependency | `zstdx` (private sibling repo) via `.path = "../zstdx"` |
| Transcription sources | NVMe Base Specification 2.0, NVM Command Set Specification 1.0 |

## Install

`znvme` is consumed as a Zig module named `nvme`. Add it to your `build.zig.zon`
alongside its `stdx` dependency, then wire the module in `build.zig`:

```zig
const znvme = b.dependency("znvme", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("nvme", znvme.module("nvme"));
```

Public imports:

```zig
const nvme = @import("nvme");
const stdx = @import("stdx");
```

## Usage

Controller bring-up. Illustrative shape; every step is a real API call.

```zig
const std = @import("std");
const stdx = @import("stdx");
const nvme = @import("nvme");

const Controller = nvme.controller.init.Controller(MyMonotonicBackend);
const Sqe = nvme.commands.sqe.Sqe;
const Cqe = nvme.commands.cqe.Cqe;
const CidWord = nvme.controller.queue.CidAllocator.Word;

const depth: u16 = 32;
var admin_sq_backing: [depth]Sqe align(@alignOf(Sqe)) = .{.{}} ** depth;
var admin_cq_backing: [depth]Cqe align(@alignOf(Cqe)) = .{.{}} ** depth;
var admin_cid_words: [stdx.bits.word.count(CidWord, depth)]CidWord = @splat(0);

var ctrl = try Controller.init(.{
    .registers = regs, // stdx.io.Mmio.Window over the BAR
    .admin = .{
        .sq = try stdx.dma.Buffer(Sqe).init(&admin_sq_backing, asq_addr),
        .cq = try stdx.dma.Buffer(Cqe).init(&admin_cq_backing, acq_addr),
        .sq_depth = depth,
        .cq_depth = depth,
        .cid_words = &admin_cid_words,
    },
    .page_size = try nvme.core.prp.PageSize.fromBytes(4096),
    .clock = .{ .backend = monotonic_backend },
});

var backoff = stdx.time.Backoff.init(nvme.controller.init.default_backoff_policy);

// Reset then enable. `CC.EN = 0` is the sole tear-down (NVMe 2.0 §3.7).
try ctrl.reset(try stdx.time.Deadline.now(&ctrl.clock, reset_budget), &backoff);
backoff.reset();
try ctrl.enable(try stdx.time.Deadline.now(&ctrl.clock, ctrl.ready_timeout), &backoff);
backoff.reset();

// Submit Identify Controller through the admin builder.
_ = try nvme.commands.admin.Identify.controller(ctrl.admin.sq(), .{ .dptr = identify_dptr });
try ctrl.admin.sq().flush();

const completion = try ctrl.admin.pollOne(
    try stdx.time.Deadline.now(&ctrl.clock, poll_budget),
    &backoff,
);
std.debug.assert(completion.statusIsSuccess());

// Later: orderly shutdown.
try ctrl.shutdown(.normal, shutdown_deadline, &backoff);
```

`Backend` is any comptime type exposing `pub fn now(self: *Backend) stdx.time.Instant`.
Callers supply whatever monotonic source their environment provides; tests
supply a counter.

Once `enable` returns, callers create I/O queue pairs through
`nvme.commands.admin.CreateIoCompletionQueue.encode` and
`CreateIoSubmissionQueue.encode`, then compose their own
`nvme.controller.queue.Pair(Backend)` values. Read / Write / Flush live under
`nvme.commands.nvm`.

## Public API

The facade is `src/nvme.zig`. It re-exports four domains covering thirteen modules.

| Namespace | Owns |
| --- | --- |
| `nvme.core.ids` | `Nsid`, `Cid`, `Qid` strong newtypes with reserved-value predicates |
| `nvme.core.status` | `CompletionStatus` decode + error taxonomy |
| `nvme.core.registers` | Controller register block, typed MMIO accessors, `Cap` / `Cc` / `Csts` / `Aqa` / `QueueBase` |
| `nvme.core.doorbell` | Doorbell stride math and SQ / CQ addressing |
| `nvme.core.prp` | `DataPointers.fromContiguous`, `IoQueueBase`, `PrpList`, `PageSize` |
| `nvme.controller.queue` | `SubmissionQueue`, `CompletionQueue(Backend)`, `Pair(Backend)`, `CidAllocator` |
| `nvme.controller.init` | `Controller(Backend)` state machine (reset / enable / shutdown) |
| `nvme.commands.sqe` | Submission Queue Entry wire layout + validator |
| `nvme.commands.cqe` | Completion Queue Entry wire layout + validator |
| `nvme.commands.admin` | Identify, Create / Delete I/O SQ+CQ, Set / Get Features, Abort |
| `nvme.commands.nvm` | Read, Write, Flush |
| `nvme.identify.controller` | Identify Controller (CNS 01h) view + geometry |
| `nvme.identify.namespace` | Identify Namespace (CNS 00h) view + `List` (CNS 02h) |

Every wire type carries `comptime` `@sizeOf` / `@alignOf` / `@offsetOf` / `@bitSizeOf`
assertions colocated with the type body. Every packed lane exposes `raw()` and
`fromRaw()`; every byte-window view exposes `T.validate(bytes) Error!*const T`.

## Design constraints

- **No allocation.** Every ring, bitmap, PRP list, and register window is caller-owned.
- **Polled completions.** The caller drives `stdx.io.poll.until` with its own
  `stdx.time.Deadline` and `stdx.time.Backoff`. `znvme` never touches wall time
  and does not configure interrupts.
- **One admin + N caller-owned I/O queue pairs.** No queue-set aggregate,
  no cross-pair scheduler.
- **Two type worlds.** Wire types are `extern struct` / `packed struct(uN)` with
  compile-time layout assertions; semantic types compose `stdx` primitives.
- **Injected clock backend.** `Controller(Backend)` and `CompletionQueue(Backend)`
  are generic over `stdx.time.Clock.Monotonic(Backend)`.
- **Little-endian x86_64.** Wire decoding assumes native little-endian loads.

The current surface covers the NVM Command Set only (`CC.CSS = 0`) and uses
PRP transfers (no SGL). Scope, deferred surfaces, and the ownership boundary
between `znvme` and its callers are enumerated in
[`docs/specs/project/scope.md`](docs/specs/project/scope.md).

## Repository layout

```
src/
  nvme.zig            # public facade
  core/               # ids, status, registers, doorbell, prp
  controller/         # queue, init
  commands/           # sqe, cqe, admin, nvm
  identify/           # controller, namespace

test/
  all.zig             # host-side test aggregator (13 files)
  fixtures/           # golden .bin files + colocated _regen.zig programs

docs/
  specs/              # normative per-module specs
  guidelines/         # zig, conventions, testing overlays
  decisions.md        # decisions ledger
  planning/           # implementation plan and spec queue
```

## Verification

```sh
zig build test    # host-side unit + golden + roundtrip suite
zig build check   # x86_64-freestanding-none type-check of the nvme module
zig fmt --check src test build.zig
```

The host suite composes real MMIO byte buffers, caller-owned DMA slices, and an
injected counter-backed clock. No mocks: tests exercise the same accessors
production code uses. Golden fixtures under `test/fixtures/` are reproducible
byte-for-byte via colocated `_regen.zig` programs.

Per-module required-test manifests are enumerated in
[`docs/specs/verification/test-strategy.md`](docs/specs/verification/test-strategy.md).

## Documentation

Normative surface lives under `docs/specs/`. Every claim marked `[nvme]` cites
NVMe Base 2.0 or NVM Command Set 1.0; every `[znvme]` claim is a `znvme` design
choice. Design decisions and their resolution are recorded in
[`docs/decisions.md`](docs/decisions.md).

Start with:

- [`docs/specs/project/scope.md`](docs/specs/project/scope.md) — purpose, ownership boundary, deferred seams
- [`docs/specs/architecture.md`](docs/specs/architecture.md) — layering, type worlds, validation phases
- [`docs/specs/verification/test-strategy.md`](docs/specs/verification/test-strategy.md) — host-test contract

## Status

Version `0.0.0`. Every module in the initial spec set is approved and landed;
the public facade is stable within that surface.
