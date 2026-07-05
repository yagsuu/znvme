# Architecture

Status: Approved. `[znvme]`

This spec defines the normative `znvme` source-tree structure: repository layout, public facade, domain boundaries, layering, the two type worlds, host-testability, validation phases, build shape, test aggregation, and `stdx` composition. `[znvme]`

This spec extends `docs/specs/project/scope.md`. `[znvme]` Where scope names what `znvme` owns, this spec names where the ownership sits in code. `[znvme]`

## Repository shape

Approved top-level layout: `[znvme]`

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

This tree is an ownership map, not permission to create empty scaffolding. `[znvme]` A source file lands only when the source-creation gate below is satisfied. `[znvme]`

## Public package facade

`src/nvme.zig` is the sole public facade and the build-module root. `[znvme]`

Approved API: `[znvme]`

```zig
//! Public nvme surface. Spec: docs/specs/project/scope.md.

pub const core = @import("core/root.zig");
pub const controller = @import("controller/root.zig");
pub const commands = @import("commands/root.zig");
pub const identify = @import("identify/root.zig");
```

The facade is thin: re-exports and aliases only. `[znvme]` It contains no logic, no validation, no allocation, no wire parsing, and no register access. `[znvme]` `znvme` does not expose per-domain facade modules under `src/*.zig`. `[znvme]` Domain root files (`src/core/root.zig`, ...) exist only to aggregate their directory's public surface for the facade. `[znvme]`

Root promotion (`pub const Controller = controller.Controller;`) is allowed only after the owning spec approves the promoted name. `[znvme]` Promotion is additive; the canonical home stays the domain namespace. `[znvme]`

## Domain boundaries

`znvme` owns four domains under `src/`. `[znvme]` Each domain is a directory of one-concept-per-file modules plus a `root.zig` that aggregates the domain's public surface. `[znvme]`

### `src/core/`

`src/core/` contains shared primitives with no command-level semantics. `[znvme]`

- `core/ids.zig` owns `Nsid`, `Cid`, and `Qid` newtypes and bounds. `[znvme]`
- `core/dma.zig` is a delegation record only; `stdx.dma.Buffer(T)` is the DMA primitive. `[znvme]`
- `core/status.zig` owns CQE status decode and error taxonomy. `[znvme]`
- `core/registers.zig` owns the controller register block `extern struct`, typed `stdx.io.Mmio.Window` accessor, and layout assertions. `[znvme]`
- `core/doorbell.zig` owns doorbell stride and SQ/CQ doorbell addressing. `[znvme]`
- `core/prp.zig` owns PRP1, PRP2, and PRP-list construction. `[znvme]`

### `src/controller/`

`src/controller/` contains controller state machine and queue-pair mechanics. `[znvme]`

- `controller/init.zig` owns the CC/CSTS enable → ready handshake and shutdown state machine. `[znvme]`
- `controller/queue.zig` owns `SubmissionQueue`, `CompletionQueue(Backend)`, and `Pair(Backend)` — the queue types are role-agnostic (same types back the admin pair and any I/O pair), and this module owns the SQ tail advance, CQ head advance, phase-tag flip, and doorbell coupling. `[znvme]`

### `src/commands/`

`src/commands/` contains wire SQE/CQE layouts and typed command builders. `[znvme]`

- `commands/sqe.zig` owns the Submission Queue Entry wire layout and view. `[znvme]`
- `commands/cqe.zig` owns the Completion Queue Entry wire layout and view. `[znvme]`
- `commands/admin.zig` owns Identify, Create/Delete I/O SQ/CQ, Set/Get Features (Number of Queues), and Abort builders. `[znvme]`
- `commands/nvm.zig` owns NVM Read, Write, and Flush builders. `[znvme]`

### `src/identify/`

`src/identify/` contains Identify structures and namespace geometry. `[znvme]`

- `identify/controller.zig` owns the Identify Controller (CNS 01h) view. `[znvme]`
- `identify/namespace.zig` owns the Identify Namespace (CNS 00h) view and geometry derivation, and the Active Namespace ID list (CNS 02h) `List` type. `[znvme]`

## File responsibility

Each `.zig` file owns one concept or one type family. `[znvme]` A file splits by sub-concern only when the owning spec requires it. `[znvme]`

Disallowed file names: `[znvme]`

```text
utils.zig
helpers.zig
common.zig
misc.zig
manager.zig
```

`manager.zig` is disallowed unconditionally in `znvme`. `[znvme]` There is no public concept named `Manager` in the surface. `[znvme]`

Approved split shapes: `[znvme]`

- `commands/admin.zig` plus `commands/nvm.zig` when the command families have independent mechanics. `[znvme]`
- `core/prp.zig` alongside `core/dma.zig` when the transfer builder and the address newtype have separate contracts. `[znvme]`

Premature splits by capacity variant (`commands/admin_static.zig`, `commands/admin_bounded.zig`) are not approved. `[znvme]` `stdx` owns the capacity vocabulary, and `znvme` composes at the type-parameter layer rather than the file layer. `[znvme]`

## Layering

Approved dependency direction: `[znvme]`

```text
nvme.zig
  -> core, controller, commands, identify   (re-export only)

controller
  -> core, commands

commands
  -> core

identify
  -> core

core
  -> std, builtin, stdx
```

Hard rules: `[znvme]`

- `core` imports only `std`, `builtin`, and `stdx`. `[znvme]`
- Sibling domains import only through `core`. `[znvme]`
- `controller` must not import from `identify`. `[znvme]`
- `commands` must not import from `controller`. `[znvme]`
- `nvme.zig` contains no logic beyond re-exporting and aliasing. `[znvme]`
- Implementation modules within a domain import each other directly only when the owning spec allows the dependency. `[znvme]`
- A cross-domain import requires the importing spec to name the dependency and the graph to remain acyclic. `[znvme]`

## Two type worlds

`znvme` maintains a strict split between wire types and semantic types. `[znvme]`

### Wire types

- Wire declarations use `extern struct` or `packed struct(uN)` when the Zig representation carries an NVMe wire contract. `[znvme]`
- Fixed byte offsets and bit meanings are transcribed from the NVMe specification. `[nvme]`
- Multi-byte NVMe wire fields are little-endian. `[nvme]`
- A wire declaration uses `stdx.layout.Le(uN)` where the declaration must make little-endian order explicit. `[znvme]`
- First-slice wire readers and writers assume native little-endian targets. `[znvme]`
- Every wire type has a colocated `comptime` block asserting `@sizeOf`, `@alignOf`, `@offsetOf` for every mandated offset, and `@bitSizeOf` for every packed subfield. `[znvme]`
- Wire types produce or consume bytes at the boundary. `[znvme]`
- Wire types carry no allocator handles, function pointers, or semantic state. `[znvme]`
- Covered wire types include the controller register block overlay, SQE, CQE, Identify Controller, Identify Namespace, and PRP entries. `[znvme]`

### Semantic types

- Semantic declarations are Zig-idiomatic builders, enums, geometry aggregates, and queue-pair state. `[znvme]`
- Semantic declarations do not use `extern struct` layout discipline. `[znvme]`
- Semantic declarations encode into or decode from wire types at the domain boundary. `[znvme]`
- Semantic declarations compose `stdx` primitives such as `TagAllocator.Bounded`, `Clock.Monotonic`, `dma.Buffer(T)`, and `Cursor` as fields when the semantics call for them. `[znvme]`
- Covered semantic types include `Controller(Clock)`, `SubmissionQueue`, `CompletionQueue(Backend)`, `Pair(Backend)`, `admin.Identify.Builder`, and `identify.namespace.Geometry`. `[znvme]`

### Boundary rule

A wire type and a semantic type never mix in a single type. `[znvme]` A builder holds a semantic representation and serializes into a caller-owned wire buffer at the encode boundary. `[znvme]` A view is a borrowed read-only overlay over caller-owned wire bytes. `[znvme]` Deriving semantic state from the view happens through a `geometry()` or `decode()` method that returns a separate semantic value. `[znvme]`

## Composition with `stdx`

`znvme` composes `stdx` at the domain layer named below. `[znvme]` File-level composition is decided by each per-type spec, not this one. `[znvme]`

### `core/`

- `stdx.io.Mmio.Register(T)` and `stdx.io.Mmio.Window` back the controller register block, doorbell array, and typed MMIO accessors. `[znvme]`
- `stdx.layout.Le(uN)` documents little-endian wire-field declarations. `[znvme]`
- `stdx.addr.DmaAddr` supplies device-visible addresses paired inside `stdx.dma.Buffer(T)`. `[znvme]`
- `stdx.tags.Tag(Domain, u16)` supplies strong `Nsid`, `Cid`, and `Qid` identifiers. `[znvme]`
- `stdx.bytes` supplies byte cursors and checked offset access inside validators. `[znvme]`

### `controller/`

- `stdx.tags.TagAllocator.Bounded(CidDomain, u16)` supplies outstanding-CID allocation state inside the submission queue, backed by a caller-owned bitmap. `[znvme]` The submission queue authors SQEs in place via `Sqe.init(reservation.slot, params)` over `stdx.dma.Buffer(Sqe)`; the completion queue advances its head from device-authored `Cqe.sqhd()`. Neither ring is a `stdx.collections.Ring.Bounded` value — that primitive's `pushBack(item)` and host-side `popFront` do not model in-place SQE authorship and device-reported SQ head. `[znvme]`
- `stdx.time.Clock.Monotonic(Backend)` is the comptime parameter on `Controller` and drives handshake and completion timeouts. `[znvme]`
- `stdx.barrier.mmio.*` supplies SQ tail doorbell release and CSTS acquire ordering. `[znvme]`
- `stdx.barrier.dma.*` supplies CQE phase-tag acquire ordering. `[znvme]`
- `stdx.io.poll.until` supplies the caller-driven poll loop consumed by `Controller` and `CompletionQueue(Backend)`. `[znvme]`

### `commands/`

- `stdx.layout.Le(uN)` documents SQE/CQE little-endian dword declarations. `[znvme]`
- `stdx.tags.Tag(Domain, u16)` carries identifiers across command boundaries such as the `Cid` SQE/CQE round-trip. `[znvme]`
- `stdx.addr.DmaAddr` supplies PRP1 and PRP2 field values. `[znvme]`
- Encoders write `buffer.dmaAddr().raw()` through the wire field's dword lane. `[znvme]`

### `identify/`

- `stdx.bytes.Cursor` and `stdx.bytes.load*` validate variable-length fields and reserved-bit fields. `[znvme]`
- `stdx.layout.Le(uN)` documents Identify little-endian field declarations. `[znvme]`

A primitive `znvme` needs that `stdx` does not yet provide is a gap. `[znvme]` Gaps are proposed upstream against `../zstdx` before the consuming `znvme` spec lands. `[znvme]` Local reimplementation is a defect. `[znvme]`

## Host-testability

Every module builds and tests on the host. `[znvme]` There is no freestanding-only code in the test path. `[znvme]`

### Register substrate

Tests construct a `stdx.io.Mmio.Window` over a plain `[N]u8 align(@alignOf(u64))` scratch buffer. `[znvme]` The buffer is real backing memory, not a mock. `[znvme]` On target, the same typed accessors alias MMIO through `stdx.io.Mmio.Window`. `[znvme]` Tests read and write through the typed accessor and inspect the underlying bytes. `[znvme]`

### DMA substrate

`stdx.dma.Buffer(T)` pairs a caller-owned host slice with a fabricated `stdx.addr.DmaAddr` in tests (`stdx.addr.DmaAddr.fromInt(...)`). `[znvme]` Tests treat the DMA address as opaque. `[znvme]` `znvme` never dereferences a DMA address. `[znvme]`

### Time substrate

Timeout loops accept a `stdx.time.Clock.Monotonic(Backend)`. `[znvme]` Tests supply a counter-backed `Backend` whose `now()` increments deterministically per call. `[znvme]` `znvme` never busy-waits on wall time. `[znvme]`

### Barrier substrate

`stdx.barrier.mmio.*` and `stdx.barrier.dma.*` execute their real x86_64 instructions on the host test target. `[znvme]` Tests assert API shape and referential mapping through the `stdx` spec, not hardware ordering. `[znvme]`

### Fixture policy

Golden fixture bytes are real NVMe structure bytes or bytes generated by `znvme` builders. `[znvme]` Fixtures live under a test fixture directory with a documented regeneration command. `[znvme]` Default `zig build test` requires no external tools. `[znvme]`

## Validation phases

`znvme` performs three kinds of checks, and they do not overlap. `[znvme]`

### Compile time

Compile-time checks prove wire-layout invariants: `@sizeOf`, `@alignOf`, `@offsetOf`, and `@bitSizeOf`. `[znvme]` Layout checks are colocated with the type body in a `comptime` block. `[znvme]` `zig build check` proves those checks on `x86_64-freestanding-none`. `[znvme]`

### Public validation

Public validation covers external-byte checks: short buffers, reserved-bit violations, out-of-range field values, malformed length prefixes, and bad completion status. `[znvme]` Public validation surfaces as `T.validate(bytes)` methods returning `Error!*const T` with a typed error set. `[znvme]` Typed pointers over invalid bytes are never constructed. `[znvme]`

### Assertions

Assertions cover post-validation programmer-error checks. `[znvme]` `std.debug.assert` guards internal invariants that public validation has already established: doorbell on initialized queue, SQE slot within capacity, and completion decoded before consumption. `[znvme]` Assertions never fire on external input. `[znvme]`

## Build shape

`build.zig` produces two consumers of the `nvme` module. `[znvme]`

- **`zig build test`** is the host-target test step. `[znvme]` It is aggregated by `test/all.zig` and imports `nvme` as a module dependency. `[znvme]`
- **`zig build check`** is the `x86_64-freestanding-none` type-check step. `[znvme]` It type-checks the `nvme` module off-host to prove wire-layout ABI assertions. `[znvme]`

Both steps link `stdx` at the matching target through `b.dependency("stdx", .{ .target = ..., .optimize = ... })`. `[znvme]` The `nvme` module carries one import: `.{ .name = "stdx", .module = stdx.module("stdx") }`. `[znvme]`

No other build steps land until an approved spec requires one. `[znvme]`

## Test aggregation

`test/all.zig` aggregates tests with comptime imports mirroring `src/`. `[znvme]`

```zig
comptime {
    _ = @import("core/ids_test.zig");
    _ = @import("core/registers_test.zig");
    _ = @import("controller/init_test.zig");
    // ...
}
```

Test directories mirror source domains. `[znvme]` In-source `test` blocks cover local pure logic. `[znvme]` Multi-module tests, golden-byte tests, malformed-input tests, and round-trip tests live under `test/`. `[znvme]`

Test naming uses the category prefixes named in `docs/guidelines/testing.md`: `unit:`, `golden:`, `malformed:`, `roundtrip:`. `[znvme]`

## `std` and `stdx` usage

Approved in library code: `[znvme]`

- `std.debug.assert` — programmer-error assertions after public validation. `[znvme]`
- `std.mem` compile-time helpers (`std.mem.eql` on comptime-known slices, `std.mem.sliceAsBytes`). `[znvme]`
- `std.math` overflow-checked arithmetic (`std.math.add`, `std.math.sub`). `[znvme]`
- `stdx.*` per the composition table above. `[znvme]`

Not approved in library code: `[znvme]`

- `std.mem.Allocator`; `znvme` owns no memory and takes no allocator. `[znvme]`
- `std.heap.*`; `znvme` owns no memory and takes no allocator. `[znvme]`
- OS syscalls, `std.os.*`, and `std.fs.*`; `znvme` performs no host I/O. `[znvme]`
- Wall time and `std.time.*`; `znvme` uses only the injected `stdx.time.Clock.Monotonic(Backend)`. `[znvme]`
- Runtime target probing; targets are gated at compile time through `stdx.arch` or `@compileError`. `[znvme]`
- Reimplementations of `stdx` primitives; open a gap entry instead. `[znvme]`

Approved in tests: `[znvme]`

- `std.testing` and its helpers. `[znvme]`
- Heap-allocated buffers used only to back `stdx.dma.Buffer(T)`, register windows, and fixtures. `[znvme]`

## Source-creation gate

A `.zig` file lands only when all conditions are true. `[znvme]`

1. An approved owning spec exists under `docs/specs/`. `[znvme]`
2. The file's module header cites that spec. `[znvme]`
3. The file owns one concept or one type family. `[znvme]`
4. Tests required by the owning spec land with the implementation slice. `[znvme]`
5. The dependency direction follows this architecture spec. `[znvme]`
6. Every domain-neutral primitive the file consumes comes from `stdx`, or a spec draft has landed upstream against `../zstdx`. `[znvme]`

## Open questions

_(none)_
