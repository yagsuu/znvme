# znvme

`znvme` is an allocation-free Zig library for NVMe 2.0 wire protocol and controller mechanics.

## Overview

`znvme` owns the following NVMe components:

- Controller register layouts and typed MMIO accessors.
- Controller reset, enable, and shutdown state transitions.
- Admin and caller-owned I/O submission/completion queue mechanics.
- SQE and CQE layouts, command identifiers, doorbells, phase tags, non-waiting
  completion drain, and deadline-driven polling.
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
| Host endianness | Little-endian |
| Completion mode | Non-waiting drain and deadline-driven poll |

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

## Common workflows

### Construct a controller

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

### Reset and enable a controller

The caller supplies each transition deadline. `reset` disables the controller;
`enable` programs the admin queue and waits for `CSTS.RDY`.

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

Command builders stage SQEs. `flush` publishes the batch with one SQ tail
doorbell write. `pollOne` waits for one completion and retires its CID.

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

After `enable`, create the I/O queues through the admin builders. The caller
owns their rings and constructs each `nvme.controller.queue.Pair(Backend)`.

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

Read, Write, and Flush stage SQEs on a caller-selected queue. The caller
provides the PRPs and chooses when to flush.

```zig
_ = try nvme.commands.nvm.Read.encode(io_pair.sq(), .{
    .namespace_id = namespace_id,
    .starting_lba = lba,
    .logical_block_count = 1,
    .data_pointers = read_prps,
});
try io_pair.sq().flush();
```

### Drain posted completions

Use `Pair.drain` to consume posted CQEs without waiting. It returns `0` when no
CQE is ready and does not require a clock or `Backoff`.

```zig
var completions: [64]nvme.controller.queue.Completion = undefined;
const count = try io_pair.drain(completions[0..]);

for (completions[0..count]) |*completion| {
    if (!completion.statusIsSuccess()) return error.CommandFailed;
    completeRequest(completion.cid, completion);
}
```

`controller.admin.drain` provides the same operation for the admin queue.
Interrupts and platform events only wake the serialized consumer; the CQ phase
tag determines readiness. Interrupt configuration and synchronization remain
caller-owned.

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
- **Caller-owned queue policy.** Queue access is serialized by the caller.
  `drain` consumes posted CQEs; `poll` waits for the first CQE. Interrupt
  configuration and synchronization are also caller-owned.
- **Publish submissions explicitly.** Command encoders stage SQEs. `flush`
  makes staged work visible to the controller.
- **Wire types are checked.** Wire layouts carry compile-time size, alignment,
  offset, and bit-width assertions.
- **Validated byte views.** External Identify and command bytes are validated
  before typed views are constructed.
- **Command Set and PRP transfers.** Uses the NVM Command Set (`CC.CSS = 0`).
  SGL transfers and non-NVM command sets are not currently supported.

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
Specification 1.0.

- [`docs/specs/project/scope.md`](docs/specs/project/scope.md) — package scope,
  ownership boundaries, non-goals, and deferred seams.
- [`docs/specs/architecture.md`](docs/specs/architecture.md) — source domains,
  type boundary, dependency direction, and lifecycle.
- [`docs/specs/verification/test-strategy.md`](docs/specs/verification/test-strategy.md)
  — host-test and fixture contracts.
