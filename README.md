# znvme

`znvme` is an allocation-free Zig library for NVMe 2.0 wire protocol and controller mechanics.

## Overview

`znvme` owns the following NVMe components:

- Controller register layouts and typed MMIO accessors.
- Controller reset, enable, and shutdown state transitions.
- Admin and caller-owned I/O submission/completion queue mechanics.
- SQE and CQE layouts, command identifiers, doorbells, and phase tags.
- Admin builders for Identify, I/O queue creation and deletion, Number of
  Queues, and Abort.
- NVM builders for Read, Write, and Flush.
- Identify Controller, Identify Namespace, and Active Namespace ID list views.
- PRP1, PRP2, and PRP-list construction.


## Requirements and platform support

| Item | Support |
| --- | --- |
| Zig | `0.16.0` or later |
| Package | `znvme` |
| Public module | `nvme` |
| Dependency | `zstdx`, declared in `build.zig.zon` |
| Host target | `x86_64-linux` for the default test suite |
| Freestanding check | `x86_64-freestanding-none` through `zig build check` |
| Host endianness | Little-endian x86_64 in the current slice |
| Completion mode | Caller-driven polling; interrupt-driven completion is deferred |

## Quick start

Add `znvme` and its `zstdx` dependency to the consuming project's build
configuration. Import the package module as `nvme`:

```zig
const znvme = b.dependency("znvme", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("nvme", znvme.module("nvme"));
```

```zig
const nvme = @import("nvme");
const stdx = @import("stdx");
```

Construct a controller from caller-owned register, queue, and clock resources:

```zig
const Controller = nvme.controller.init.Controller(MyMonotonicBackend);
const Sqe = nvme.commands.sqe.Sqe;
const Cqe = nvme.commands.cqe.Cqe;
const CidWord = nvme.controller.queue.CidAllocator.Word;

const depth: u16 = 32;
var admin_sq_backing: [depth]Sqe align(@alignOf(Sqe)) = .{.{}} ** depth;
var admin_cq_backing: [depth]Cqe align(@alignOf(Cqe)) = .{.{}} ** depth;
var admin_cid_words: [stdx.bits.word.count(CidWord, depth)]CidWord = @splat(0);

var controller = try Controller.init(.{
    .registers = registers, // stdx.io.MMIO.Window over the controller BAR
    .admin = .{
        .sq = try stdx.dma.Buffer(Sqe).init(&admin_sq_backing, asq_addr),
        .cq = try stdx.dma.Buffer(Cqe).init(&admin_cq_backing, acq_addr),
        .cid_words = &admin_cid_words,
    },
    .page_size = try nvme.core.prp.PageSize.fromBytes(4096),
    .clock = .{ .backend = monotonic_backend },
});
```

`MyMonotonicBackend` is a comptime type with
`pub fn now(self: *MyMonotonicBackend) stdx.time.Instant`. The caller keeps the
MMIO window and all queue storage valid while the controller uses them.

## Common workflows

### Reset and enable a controller

The caller supplies deadlines and drives the polling loop. Reset disables the
controller when necessary. Enable programs the admin queue and waits for
`CSTS.RDY`.

```zig
var backoff = stdx.time.Backoff.init(nvme.controller.init.default_backoff_policy);

try controller.reset(
    try stdx.time.Deadline.now(&controller.clock, reset_budget),
    &backoff,
);
backoff.reset();
try controller.enable(
    try stdx.time.Deadline.now(&controller.clock, controller.ready_timeout),
    &backoff,
);
```

### Submit and complete an Admin command

Command builders reserve a slot and stage its SQE. `flush` publishes all staged
SQEs with one submission-tail doorbell write. `pollOne` waits for one matching
completion and retires its command identifier.

```zig
_ = try nvme.commands.admin.Identify.controller(controller.admin.sq(), .{
    .dptr = identify_dptr,
});
try controller.admin.sq().flush();

const completion = try controller.admin.pollOne(
    try stdx.time.Deadline.now(&controller.clock, poll_budget),
    &backoff,
);
if (!completion.statusIsSuccess()) return error.IdentifyFailed;
```

### Create caller-owned I/O queue pairs

After `enable`, create I/O completion and submission queues through the Admin
builders. The caller owns every I/O ring and builds its own
`nvme.controller.queue.Pair(Backend)` value. `znvme` does not create a
multi-queue scheduler or queue-set aggregate.

```zig
_ = try nvme.commands.admin.CreateIoCompletionQueue.encode(controller.admin.sq(), .{
    .qid = io_qid,
    .queue_size = depth,
    .base = io_cq_base,
});
_ = try nvme.commands.admin.CreateIoSubmissionQueue.encode(controller.admin.sq(), .{
    .qid = io_qid,
    .queue_size = depth,
    .base = io_sq_base,
    .cqid = io_qid,
});
try controller.admin.sq().flush();
```

### Encode NVM commands

Read, Write, and Flush use a caller-selected queue and caller-owned PRP
pointers. Each encoder stages one SQE; the caller chooses when to flush.

```zig
_ = try nvme.commands.nvm.Read.encode(io_pair.sq(), .{
    .namespace_id = namespace_id,
    .starting_lba = lba,
    .logical_block_count = 1,
    .data_pointers = read_prps,
});
try io_pair.sq().flush();
```

### Validate Identify responses

Identify views validate caller-owned response bytes before exposing fields.

```zig
const identify = try nvme.identify.controller.IdentifyController.validate(&identify_bytes);
const namespace = try nvme.identify.namespace.IdentifyNamespace.validate(&namespace_bytes);
const geometry = try namespace.geometry();
```

## Public API

`src/nvme.zig` re-exports four namespaces:

| Namespace | Purpose |
| --- | --- |
| `nvme.core` | Identifiers, completion status, controller registers, doorbells, and PRP helpers. |
| `nvme.controller` | Controller lifecycle plus submission, completion, and pair mechanics. |
| `nvme.commands` | SQE/CQE layouts and Admin/NVM command encoders. |
| `nvme.identify` | Validated Identify Controller/Namespace views, active namespace lists, and geometry. |

## Design

- **No hidden allocation.** Queue rings, command-ID bitmaps, PRP storage, and
  register windows are caller-owned.
- **Explicit privileged access.** Controller registers use `stdx.io.MMIO.Window`.
  DMA-visible storage uses `stdx.dma.Buffer(T)` and `stdx.addr.DMAAddr`.
- **Caller-serialized queues.** A queue or pair contains no internal
  synchronization. One `Pair(Backend)` binds one SQ to one CQ.
- **Plan publication explicitly.** Command encoders stage SQEs. `flush` makes
  staged work visible to the controller.
- **Wire types are checked.** Wire layouts carry compile-time size, alignment,
  offset, and bit-width assertions.
- **Validated byte views.** External Identify and command bytes are validated
  before typed views are constructed.
- **NVM Command Set and PRP transfers.** The current slice uses `CC.CSS = 0`
  and does not support SGL transfers or non-NVM command sets.

## Build and test

Run the default host-side suite:

```sh
zig build test
```

Type-check the public module for the freestanding target:

```sh
zig build check
```

Check Zig source formatting:

```sh
zig fmt --check build.zig src test
```

The host suite uses real MMIO byte buffers, caller-owned DMA slices, and a
deterministic clock backend. It requires no NVMe hardware, VM, or external
tool. Golden fixtures under `test/fixtures/` are generated byte-for-byte by
colocated `_regen.zig` programs.

## Documentation

Normative contracts are under [`docs/specs/`](docs/specs/). `[nvme]` marks
claims transcribed from NVMe Base Specification 2.0 or NVM Command Set
Specification 1.0. Unmarked normative specification text is a `znvme` design
decision.

- [`docs/specs/project/scope.md`](docs/specs/project/scope.md) — package scope,
  ownership boundaries, non-goals, and deferred seams.
- [`docs/specs/architecture.md`](docs/specs/architecture.md) — source domains,
  type boundary, dependency direction, and lifecycle.
- [`docs/specs/verification/test-strategy.md`](docs/specs/verification/test-strategy.md)
  — host-test and fixture contracts.
- [`docs/planning/spec-queue.md`](docs/planning/spec-queue.md) — process and
  queue for future specification work.
