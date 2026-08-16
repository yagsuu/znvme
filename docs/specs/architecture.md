# Architecture

Status: Approved.

This specification defines the `znvme` code structure, dependency direction,
ownership boundaries, and validation model. It extends
[`docs/specs/project/scope.md`](project/scope.md). The scope specification
defines what `znvme` owns. This specification defines where that ownership
lives and how the parts interact.

## Purpose and boundaries

`znvme` is an allocation-free NVMe protocol library. It supplies the wire
layouts and controller mechanics required by the NVM Command Set boot path.
It serves two consumers:

- A host driver composes controller access, queue pairs, command builders, and
  completion polling.
- A device emulator composes the same wire layouts and validation views to
  interpret host requests and write device responses.

The caller owns the MMIO mapping, DMA-capable storage, DMA addresses, clock
backend, queue-selection policy, interrupt policy, and namespace-selection
policy. `znvme` does not discover PCI devices, allocate memory, install UEFI
protocols, schedule I/O, or implement a device-controller state machine.

## Public facade

`src/nvme.zig` is the public module root and the only public facade.

```zig
//! Public nvme surface. Spec: docs/specs/architecture.md.

pub const core = @import("core/root.zig");
pub const controller = @import("controller/root.zig");
pub const commands = @import("commands/root.zig");
pub const identify = @import("identify/root.zig");
```

The facade contains only re-exports. It contains no validation, allocation,
wire parsing, register access, or controller logic. Each domain `root.zig`
file aggregates the public surface of its directory. A root promotion is
allowed only after the owning specification approves the promoted name. The
domain namespace remains the canonical home of that name.

## Domains

Each source file owns one concept or one type family. A domain root aggregates
its domain's public modules.

| Domain | Responsibility |
| --- | --- |
| `core` | Strong identifiers, completion status, controller-register access, doorbell addressing, and PRP construction. |
| `controller` | Controller reset, enable, and shutdown; submission and completion queue-pair mechanics. |
| `commands` | SQE and CQE wire layouts; typed Admin and NVM command encoders. |
| `identify` | Identify Controller and Identify Namespace validation views, Active Namespace ID lists, and namespace geometry. |

`core/dma.zig` does not exist. DMA storage and addresses are `stdx.dma.Buffer(T)`
and `stdx.addr.DMAAddr` values. `znvme` does not wrap or replace them.

Source names describe the owned concept. Generic names such as `utils.zig`,
`helpers.zig`, `common.zig`, `misc.zig`, and `manager.zig` are not allowed.

## Dependency direction

```text
nvme.zig
  -> core, controller, commands, identify   (re-export only)

controller
  -> core, commands

commands
  -> core, controller/queue

identify
  -> core

core
  -> std, builtin, stdx
```

The dependency graph must remain acyclic.

- `core` imports only `std`, `builtin`, and `stdx`.
- `controller` must not import `identify`.
- `commands` may import `controller/queue.zig`. It must not import
  `controller/init.zig` or another `controller` implementation module.
- A cross-domain import requires an explicit owning-spec dependency.
- `nvme.zig` contains only re-exports and approved aliases.

The `commands -> controller/queue` edge is required because command encoders
reserve and stage slots through `SubmissionQueue`. `controller/queue.zig` does
not import Admin or NVM command builders, so the edge does not create a cycle.

## Wire and semantic types

`znvme` keeps wire types and semantic types separate.

### Wire types

Wire types represent NVMe-defined bytes and bit lanes.

- A wire declaration uses `extern struct` or `packed struct(uN)` when its Zig
  representation has an NVMe wire contract.
- Fixed offsets, bit meanings, and multi-byte byte order are transcribed from
  the NVMe specifications. `[nvme]`
- Multi-byte NVMe wire fields are little-endian. `[nvme]`
- A wire type has colocated compile-time assertions for its required size,
  alignment, offsets, and packed-field widths.
- A wire type has no allocator handle, function pointer, or semantic state.

The controller register overlay, SQE, CQE, Identify structures, and PRP
entries are wire types.

### Semantic types

Semantic types express control flow and policy-free mechanics. They include
builders, enums, geometry values, controller state, and queue state. A
semantic type does not use `extern struct` layout discipline. It can compose
`stdx` primitives where its contract requires them.

A builder serializes semantic input into caller-owned wire storage. A view is
a borrowed, read-only overlay over caller-owned bytes. A view validates bytes
before it constructs a typed pointer. A method such as `geometry()` converts a
validated view into a separate semantic value.

## Controller and queue lifecycle

The caller supplies a `stdx.io.MMIO.Window`, an injected monotonic clock, and
matching caller-owned DMA buffers for the admin submission and completion
queues. `Controller.init` validates that configuration. `Controller.reset`
puts the controller in the disabled state. `Controller.enable` programs the
admin queue registers, waits for ready state, and makes the admin pair
available.

A caller submits one command through this sequence:

1. A command encoder reserves a submission slot and its command identifier.
2. The encoder writes the SQE and stages the reservation.
3. The caller calls `SubmissionQueue.flush` to publish every staged SQE with
   one tail-doorbell write.
4. The caller polls the matching `Pair` or completion queue with a deadline
   and backoff.
5. The queue advances the completion head and retires the command identifier.

A `SubmissionQueue`, `CompletionQueue(Backend)`, or `Pair(Backend)` has no
internal synchronization. The caller serializes calls on each queue pair. One
`Pair(Backend)` binds one submission queue to one completion queue. A shared
completion queue for multiple submission queues is deferred by
`docs/specs/project/scope.md`.

## Composition with `stdx`

`znvme` uses `stdx` for domain-neutral primitives. A missing primitive is an
upstream `stdx` gap, not a reason to implement a local replacement.

| `stdx` surface | `znvme` use |
| --- | --- |
| `io.MMIO.Window` and `io.MMIO.Register(T)` | Controller registers and doorbells. |
| `barrier.mmio.*` and `barrier.dma.*` | MMIO publication and completion visibility ordering. |
| `time.Clock.Monotonic(Backend)`, `Deadline`, and `Backoff` | Controller and completion polling. |
| `dma.Buffer(T)` and `addr.DMAAddr` | Caller-owned queue and transfer storage. |
| `tags.Tag` and `tags.TagAllocator.Bounded` | Strong NVMe identifiers and outstanding command identifiers. |
| `bytes.Cursor` and `bytes.load*` | Identify-byte validation. |
| `layout.Le(uN)` | Explicit little-endian wire lanes where required. |

Library code does not take an allocator, use `std.heap`, perform OS I/O, use
wall time, or probe the runtime target. Tests may allocate backing storage
only for test buffers and fixtures.

## Validation and testing

`znvme` uses three distinct checks:

- **Compile-time checks** prove wire layout with `@sizeOf`, `@alignOf`,
  `@offsetOf`, and `@bitSizeOf` assertions next to the type.
- **Public validation** rejects invalid external bytes, including short
  buffers, invalid reserved bits, invalid values, malformed lengths, and bad
  completion status. Validation returns a typed error instead of constructing
  a view over invalid bytes.
- **Assertions** protect internal invariants after public validation. They do
  not report external-input errors.

`zig build test` runs host-side tests through real byte buffers, typed MMIO
accessors, caller-owned DMA buffers, and deterministic clocks. `zig build
check` type-checks the public module for `x86_64-freestanding-none` and proves
the wire-layout assertions off-host. `test/all.zig` aggregates external tests;
test directories mirror the source domains. The required coverage and fixture
rules are defined by
[`docs/specs/verification/test-strategy.md`](verification/test-strategy.md).

## Source creation

A source module lands only when all of these conditions are true:

1. An approved owning specification exists under `docs/specs/`.
2. The module header cites that specification.
3. The module owns one concept or one type family.
4. The owning specification's required tests land with the module.
5. The module follows this specification's dependency direction.
6. Every domain-neutral primitive comes from `stdx`, or an upstream `stdx`
   specification draft names the required primitive.

## Open questions

_(none)_
