# Architecture

Status: Approved.

This spec defines the normative `znvme` source-tree structure: repository layout, public facade, domain boundaries, layering, the two type worlds, host-testability, validation phases, build shape, test aggregation, and `stdx` composition.

This spec extends `docs/specs/project/scope.md`. Where scope names what `znvme` owns, this spec names where the ownership sits in code.

## Repository shape

Approved top-level layout:

```text
znvme/
  build.zig
  build.zig.zon
  .gitignore

  docs/
    decisions.md
    specs/
      project/
      core/
      controller/
      commands/
      identify/
      verification/
      examples/
    planning/
    guidelines/

  src/
    nvme.zig

    core/
    controller/
    commands/
    identify/

  test/
    all.zig
    core/
    controller/
    commands/
    identify/
```

This tree is an ownership map, not permission to create empty scaffolding. A source file lands only when the source-creation gate below is satisfied.

## Public package facade

`src/nvme.zig` is the sole public facade and the build-module root.

Approved API:

```zig
//! Public nvme surface. Spec: docs/specs/project/scope.md.

pub const core = @import("core/root.zig");
pub const controller = @import("controller/root.zig");
pub const commands = @import("commands/root.zig");
pub const identify = @import("identify/root.zig");
```

The facade is thin: re-exports and aliases only. It contains no logic, no validation, no allocation, no wire parsing, and no register access. `znvme` does not expose per-domain facade modules under `src/*.zig`. Domain root files (`src/core/root.zig`, ...) exist only to aggregate their directory's public surface for the facade.

Root promotion (`pub const Controller = controller.Controller;`) is allowed only after the owning spec approves the promoted name. Promotion is additive; the canonical home stays the domain namespace.

## Domain boundaries

`znvme` owns four domains under `src/`. Each domain is a directory of one-concept-per-file modules plus a `root.zig` that aggregates the domain's public surface.

### `src/core/`

`src/core/` contains shared primitives with no command-level semantics.

- `core/ids.zig` owns `Nsid`, `Cid`, and `Qid` newtypes and bounds.
- `core/dma.zig` is a delegation record only; `stdx.dma.Buffer(T)` is the DMA primitive.
- `core/status.zig` owns CQE status decode and error taxonomy.
- `core/registers.zig` owns the controller register block `extern struct`, typed `stdx.io.MMIO.Window` accessor, and layout assertions.
- `core/doorbell.zig` owns doorbell stride and SQ/CQ doorbell addressing.
- `core/prp.zig` owns PRP1, PRP2, and PRP-list construction.

### `src/controller/`

`src/controller/` contains controller state machine and queue-pair mechanics.

- `controller/init.zig` owns the CC/CSTS enable → ready handshake and shutdown state machine.
- `controller/queue.zig` owns `SubmissionQueue`, `CompletionQueue(Backend)`, and `Pair(Backend)` — the queue types are role-agnostic (same types back the admin pair and any I/O pair), and this module owns the SQ tail advance, CQ head advance, phase-tag flip, and doorbell coupling.

### `src/commands/`

`src/commands/` contains wire SQE/CQE layouts and typed command builders.

- `commands/sqe.zig` owns the Submission Queue Entry wire layout and view.
- `commands/cqe.zig` owns the Completion Queue Entry wire layout and view.
- `commands/admin.zig` owns Identify, Create/Delete I/O SQ/CQ, Set/Get Features (Number of Queues), and Abort builders.
- `commands/nvm.zig` owns NVM Read, Write, and Flush builders.

### `src/identify/`

`src/identify/` contains Identify structures and namespace geometry.

- `identify/controller.zig` owns the Identify Controller (CNS 01h) view.
- `identify/namespace.zig` owns the Identify Namespace (CNS 00h) view and geometry derivation, and the Active Namespace ID list (CNS 02h) `List` type.

## File responsibility

Each `.zig` file owns one concept or one type family. A file splits by sub-concern only when the owning spec requires it.

Disallowed file names:

```text
utils.zig
helpers.zig
common.zig
misc.zig
manager.zig
```

`manager.zig` is disallowed unconditionally in `znvme`. There is no public concept named `Manager` in the surface.

Approved split shapes:

- `commands/admin.zig` plus `commands/nvm.zig` when the command families have independent mechanics.
- `core/prp.zig` alongside `core/dma.zig` when the transfer builder and the address newtype have separate contracts.

Premature splits by capacity variant (`commands/admin_static.zig`, `commands/admin_bounded.zig`) are not approved. `stdx` owns the capacity vocabulary, and `znvme` composes at the type-parameter layer rather than the file layer.

## Layering

Approved dependency direction:

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

Hard rules:

- `core` imports only `std`, `builtin`, and `stdx`.
- Sibling domains import only through `core`, except where the layering diagram above names a direct edge and the importing spec names the dependency (currently: `commands` -> `controller/queue`).
- `controller` must not import from `identify`.
- `commands` may import `controller/queue.zig` but must not import `controller/init.zig` or any other `controller/*` module.
- `nvme.zig` contains no logic beyond re-exporting and aliasing.
- Implementation modules within a domain import each other directly only when the owning spec allows the dependency.
- A cross-domain import requires the importing spec to name the dependency and the graph to remain acyclic.

## Two type worlds

`znvme` maintains a strict split between wire types and semantic types.

### Wire types

- Wire declarations use `extern struct` or `packed struct(uN)` when the Zig representation carries an NVMe wire contract.
- Fixed byte offsets and bit meanings are transcribed from the NVMe specification. `[nvme]`
- Multi-byte NVMe wire fields are little-endian. `[nvme]`
- A wire declaration uses `stdx.layout.Le(uN)` where the declaration must make little-endian order explicit.
- First-slice wire readers and writers assume native little-endian targets.
- Every wire type has a colocated `comptime` block asserting `@sizeOf`, `@alignOf`, `@offsetOf` for every mandated offset, and `@bitSizeOf` for every packed subfield.
- Wire types produce or consume bytes at the boundary.
- Wire types carry no allocator handles, function pointers, or semantic state.
- Covered wire types include the controller register block overlay, SQE, CQE, Identify Controller, Identify Namespace, and PRP entries.

### Semantic types

- Semantic declarations are Zig-idiomatic builders, enums, geometry aggregates, and queue-pair state.
- Semantic declarations do not use `extern struct` layout discipline.
- Semantic declarations encode into or decode from wire types at the domain boundary.
- Semantic declarations compose `stdx` primitives such as `TagAllocator.Bounded`, `Clock.Monotonic`, `dma.Buffer(T)`, and `Cursor` as fields when the semantics call for them.
- Covered semantic types include `Controller(Clock)`, `SubmissionQueue`, `CompletionQueue(Backend)`, `Pair(Backend)`, `admin.Identify.Builder`, and `identify.namespace.Geometry`.

### Boundary rule

A wire type and a semantic type never mix in a single type. A builder holds a semantic representation and serializes into a caller-owned wire buffer at the encode boundary. A view is a borrowed read-only overlay over caller-owned wire bytes. Deriving semantic state from the view happens through a `geometry()` or `decode()` method that returns a separate semantic value.

## Composition with `stdx`

`znvme` composes `stdx` at the domain layer named below. File-level composition is decided by each per-type spec, not this one.

### `core/`

- `stdx.io.MMIO.Register(T)` and `stdx.io.MMIO.Window` back the controller register block, doorbell array, and typed MMIO accessors.
- `stdx.layout.Le(uN)` documents little-endian wire-field declarations.
- `stdx.addr.DMAAddr` supplies device-visible addresses paired inside `stdx.dma.Buffer(T)`.
- `stdx.tags.Tag(Domain, u16)` supplies strong `Nsid`, `Cid`, and `Qid` identifiers.
- `stdx.bytes` supplies byte cursors and checked offset access inside validators.

### `controller/`

- `stdx.tags.TagAllocator.Bounded(CidDomain, u16)` supplies outstanding-CID allocation state inside the submission queue, backed by a caller-owned bitmap. The submission queue authors SQEs in place via `Sqe.init(reservation.slot, params)` over `stdx.dma.Buffer(Sqe)`; the completion queue advances its head from device-authored `Cqe.sqhd()`. Neither ring is a `stdx.collections.Ring.Bounded` value — that primitive's `pushBack(item)` and host-side `popFront` do not model in-place SQE authorship and device-reported SQ head.
- `stdx.time.Clock.Monotonic(Backend)` is the comptime parameter on `Controller` and drives handshake and completion timeouts.
- `stdx.barrier.mmio.*` supplies SQ tail doorbell release and CSTS acquire ordering.
- `stdx.barrier.dma.*` supplies CQE phase-tag acquire ordering.
- `stdx.io.poll.until` supplies the caller-driven poll loop consumed by `Controller` and `CompletionQueue(Backend)`.

### `commands/`

- `stdx.layout.Le(uN)` documents SQE/CQE little-endian dword declarations.
- `stdx.tags.Tag(Domain, u16)` carries identifiers across command boundaries such as the `Cid` SQE/CQE round-trip.
- `stdx.addr.DMAAddr` supplies PRP1 and PRP2 field values.
- Encoders write `buffer.dmaAddr().raw()` through the wire field's dword lane.

### `identify/`

- `stdx.bytes.Cursor` and `stdx.bytes.load*` validate variable-length fields and reserved-bit fields.
- `stdx.layout.Le(uN)` documents Identify little-endian field declarations.

A primitive `znvme` needs that `stdx` does not yet provide is a gap. Gaps are proposed upstream against `../zstdx` before the consuming `znvme` spec lands. Local reimplementation is a defect.

## Host-testability

Every module builds and tests on the host. There is no freestanding-only code in the test path.

### Register substrate

Tests construct a `stdx.io.MMIO.Window` over a plain `[N]u8 align(@alignOf(u64))` scratch buffer. The buffer is real backing memory, not a mock. On target, the same typed accessors alias MMIO through `stdx.io.MMIO.Window`. Tests read and write through the typed accessor and inspect the underlying bytes.

### DMA substrate

`stdx.dma.Buffer(T)` pairs a caller-owned host slice with a fabricated `stdx.addr.DMAAddr` in tests (`stdx.addr.DMAAddr.fromInt(...)`). Tests treat the DMA address as opaque. `znvme` never dereferences a DMA address.

### Time substrate

Timeout loops accept a `stdx.time.Clock.Monotonic(Backend)`. Tests supply a counter-backed `Backend` whose `now()` increments deterministically per call. `znvme` never busy-waits on wall time.

### Barrier substrate

`stdx.barrier.mmio.*` and `stdx.barrier.dma.*` execute their real x86_64 instructions on the host test target. Tests assert API shape and referential mapping through the `stdx` spec, not hardware ordering.

### Fixture policy

Golden fixture bytes are real NVMe structure bytes or bytes generated by `znvme` builders. Fixtures live under a test fixture directory with a documented regeneration command. Default `zig build test` requires no external tools.

## Validation phases

`znvme` performs three kinds of checks, and they do not overlap.

### Compile time

Compile-time checks prove wire-layout invariants: `@sizeOf`, `@alignOf`, `@offsetOf`, and `@bitSizeOf`. Layout checks are colocated with the type body in a `comptime` block. `zig build check` proves those checks on `x86_64-freestanding-none`.

### Public validation

Public validation covers external-byte checks: short buffers, reserved-bit violations, out-of-range field values, malformed length prefixes, and bad completion status. Public validation surfaces as `T.validate(bytes)` methods returning `Error!*const T` with a typed error set. Typed pointers over invalid bytes are never constructed.

### Assertions

Assertions cover post-validation programmer-error checks. `std.debug.assert` guards internal invariants that public validation has already established: doorbell on initialized queue, SQE slot within capacity, and completion decoded before consumption. Assertions never fire on external input.

## Build shape

`build.zig` produces two consumers of the `nvme` module.

- **`zig build test`** is the host-target test step. It is aggregated by `test/all.zig` and imports `nvme` as a module dependency.
- **`zig build check`** is the `x86_64-freestanding-none` type-check step. It type-checks the `nvme` module off-host to prove wire-layout ABI assertions.

Both steps link `stdx` at the matching target through `b.dependency("stdx", .{ .target = ..., .optimize = ... })`. The `nvme` module carries one import: `.{ .name = "stdx", .module = stdx.module("stdx") }`.

No other build steps land until an approved spec requires one.

## Test aggregation

`test/all.zig` aggregates tests with comptime imports mirroring `src/`.

```zig
comptime {
    _ = @import("core/ids_test.zig");
    _ = @import("core/registers_test.zig");
    _ = @import("controller/init_test.zig");
    // ...
}
```

Test directories mirror source domains. In-source `test` blocks cover local pure logic. Multi-module tests, golden-byte tests, malformed-input tests, and round-trip tests live under `test/`.

Test naming uses the category prefixes named in `docs/guidelines/testing.md`: `unit:`, `golden:`, `malformed:`, `roundtrip:`.

## `std` and `stdx` usage

Approved in library code:

- `std.debug.assert` — programmer-error assertions after public validation.
- `std.mem` compile-time helpers (`std.mem.eql` on comptime-known slices, `std.mem.sliceAsBytes`).
- `std.math` overflow-checked arithmetic (`std.math.add`, `std.math.sub`).
- `stdx.*` per the composition table above.

Not approved in library code:

- `std.mem.Allocator`; `znvme` owns no memory and takes no allocator.
- `std.heap.*`; `znvme` owns no memory and takes no allocator.
- OS syscalls, `std.os.*`, and `std.fs.*`; `znvme` performs no host I/O.
- Wall time and `std.time.*`; `znvme` uses only the injected `stdx.time.Clock.Monotonic(Backend)`.
- Runtime target probing; targets are gated at compile time through `stdx.arch` or `@compileError`.
- Reimplementations of `stdx` primitives; open a gap entry instead.

Approved in tests:

- `std.testing` and its helpers.
- Heap-allocated buffers used only to back `stdx.dma.Buffer(T)`, register windows, and fixtures.

## Source-creation gate

A `.zig` file lands only when all conditions are true.

1. An approved owning spec exists under `docs/specs/`.
2. The file's module header cites that spec.
3. The file owns one concept or one type family.
4. Tests required by the owning spec land with the implementation slice.
5. The dependency direction follows this architecture spec.
6. Every domain-neutral primitive the file consumes comes from `stdx`, or a spec draft has landed upstream against `../zstdx`.

## Open questions

_(none)_
