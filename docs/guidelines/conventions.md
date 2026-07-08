# Conventions

Implementation conventions for znvme source and specs. Terse rules; deviations need a reason in review.

These conventions extend `docs/guidelines/zig.md`.

## Authority order

When rules conflict, follow this order:

1. approved specs under `docs/specs/`;
2. this conventions document;
3. baseline `docs/guidelines/zig.md`;
4. planning notes under `docs/planning/`, which are never authoritative for landed code.

## Dependency on zstdx

znvme depends on `zstdx` for every domain-neutral primitive. The import name is `stdx` (zstdx's exported module name); the sibling path `../zstdx` is the workspace convention.

**Sourcing rule.** If a primitive is domain-neutral — addresses, byte cursors, endian lanes, alignment helpers, bit sets, fixed-capacity containers, strong tags, bump/pool allocators, target-gated fences — it comes from `stdx`. znvme does not shadow, wrap, or reimplement it.

**Ownership boundary.** znvme owns only NVMe-specific mechanics: wire types (SQE/CQE, register block, Identify structures), builders, views, the controller state machine, doorbell math, PRP construction, and completion status decoding. These types compose stdx primitives (`stdx.dma.Buffer(Sqe)` and `stdx.dma.Buffer(Cqe)` inside the submission and completion queues, `stdx.addr.DmaAddr` inside wire fields as native `u64` on the first-slice little-endian target or via `stdx.layout.Le(u64)` when a declaration needs explicit byte-order storage, `stdx.tags.TagAllocator.Bounded(CidDomain, u16)` inside the submission queue's outstanding-CID pool, `stdx.time.Clock.Monotonic(Backend)` inside `Controller` and the completion queue) but the composed type is znvme's.

**Missing primitives.** A primitive `znvme` needs and `stdx` does not provide is a gap, not a local implementation opportunity. Propose the primitive upstream against `../zstdx` — filing a spec draft in `../zstdx/docs/specs/` or an issue against the upstream repo — before landing the `znvme` spec that consumes it. `znvme` does not shadow, wrap, or reimplement a `stdx` primitive.

**No local replacements.** Landing a znvme-owned copy of a stdx primitive to work around a missing feature is forbidden. If a temporary workaround is unavoidable, it is a labelled experiment behind an internal name that names the upstream primitive it will be replaced by.

## Spec markers

NVMe-authoritative claims carry `[nvme]`: statements, bullets, tables, or sections derived from the NVMe Base Specification 2.0 or the NVM Command Set Specification 1.0.

Unmarked normative claims are znvme design decisions. An unmarked NVMe-authoritative claim is a defect.

The project-design marker is retired and should not appear in current specs.

## Spec ownership

Every public module is owned by one spec under `docs/specs/`.

- Source module headers cite the owning spec path.
- A module without an approved owning spec does not land.
- Planning documents do not define public API contracts.
- Specs define contracts; source implements them.

## Structure and layering

Repository shape, directory ownership, file responsibility, the public facade, the two type worlds, and dependency layering are normative in [`docs/specs/architecture.md`](../specs/architecture.md). Do not restate them here.

This overlay contributes only style and engineering deltas over `docs/guidelines/zig.md`. Conflicts between this file and `docs/specs/architecture.md` are defects — architecture wins.

## ABI layout

Extends the baseline "ABI-boundary types must use the layout required by their ABI and carry scoped compile-time layout assertions inside the type body" rule.

Every wire-boundary type carries a top-level `comptime` block asserting:

- `@sizeOf`;
- `@alignOf`;
- mandated field offsets;
- packed-flag bit widths (`@bitSizeOf`).

Named bit ranges inside a wire flag word use Zig `packed struct(uN)` with backing-integer width matching the wire field. Reserved subfields carry `= 0` defaults so writes zero them. Enum-typed subfields use `enum(uK)` with a non-exhaustive `_` tail when the specification reserves values. Raw shift/mask arithmetic on flag words is forbidden.

`zig build check` type-checks the `nvme` module for `x86_64-freestanding`, proving these assertions on a non-host target on every build. Host tests assert behavior, never layout.

### Bit-packed lane types

A wire lane packed into a `uN` picks one of two shapes based on the semantics of its decoded value:

- **Direct.** `pub const T = packed struct(uN) { ... };`. Callers read and write fields directly and use `.raw()` / `T.fromRaw(v)` at the wire boundary. This is the default and covers every bit-lane type whose decoded value is field-for-field: no cross-field predicate, no reserved-value hiding, no derived taxonomy. Landed examples: `Cap`, `Cc`, `Csts`, `Aqa`, `QueueBase`, `Version`, `EntrySize`, `OacsBits`, `OncsBits`, `FusesBits`.
- **Semantic wrapper.** `pub const T = struct { bits: Bits, ... }; pub const Bits = packed struct(uN) { ... };`. Callers construct through `T.init(Init)` / `T.from(Raw)` and read only through methods; the `Bits` field is not touched at call sites. Reserved for lanes whose decoded value requires cross-field logic — non-exhaustive enum tags hidden behind an accessor, predicates that combine multiple fields, or a taxonomy (`Kind`, `Failure`) built on top of the raw bits. Landed example: `CompletionStatus`, whose reserved `CodeType` values, phase-agnostic `isSuccess`, and `Kind`/`Failure` composition would leak to every read site under the direct shape.

Both shapes obey the wire-boundary `comptime` assertions above; the wrapper additionally asserts `@sizeOf(T) == @sizeOf(uN)` and `@alignOf(T) == @alignOf(uN)`. A new lane type defaults to direct; the wrapper shape requires the owning spec to name at least one cross-field or reserved-value semantic that justifies the extra layer.

## Endianness

NVMe is little-endian on the wire, and the first slice targets little-endian `x86_64-freestanding-none` only. Wire readers and writers may assume native little-endian; big-endian compatibility is deferred in `docs/specs/project/scope.md`. Multi-byte wire fields still use `align(1)` typed fields, `stdx.layout.Le(uN)`, or explicit little-endian read/write when that makes byte order visible at the declaration boundary. Raw host layout is never treated as a wire contract unless the type carries the layout assertions above.

## Register and doorbell access

- Controller properties are MMIO; every access goes through the typed register accessor. Raw `volatile` pointer math scattered through logic is forbidden.
- 64-bit properties (CAP, ASQ, ACQ) honor the specification's access rules.
- Doorbells are write-only; the doorbell stride derives from `CAP.DSTRD`. Doorbell index math lives in one place (`core/doorbell.zig`), not duplicated per queue.
- Magic offsets appear only in layout assertions or named constants.

## Allocation discipline

`docs/specs/architecture.md` §"`std` and `stdx` usage" fixes the rule: no `Allocator` on any `znvme` API, no allocation on error or diagnostic paths, no `std.heap` in library code.

Style deltas over that rule:

- A `Builder` writes into a caller-owned buffer and never owns the queue storage it encodes into.
- `stdx` primitives whose construction requires an `Allocator` (`stdx.diag.Diagnostics`) are out of scope for the znvme surface; `znvme` uses only inline-storage or caller-owned variants (`Static`, `Bounded`, `wrap`) of the containers, arenas, and pools it does touch.

## Validation discipline

`docs/specs/architecture.md` §"Validation phases" fixes the three-phase rule: compile-time layout, public validation over external bytes, and post-validation assertions for programmer error.

Style delta: reserved assertion sites include ringing a doorbell on an uninitialized queue, issuing a command before the controller reports ready, and indexing through an accessor with a documented precondition.

## Naming discipline

Extends the baseline with a closed vocabulary that encodes ownership and direction:

- `View` — borrowed read-only access over caller bytes.
- `Builder` — constructs or encodes a command / queue entry into caller storage.
- `from` — pure reinterpretation or conversion from one input.
- `validate` — checks external bytes and returns a borrowed read view.
- `at` — constructs a typed accessor over a base pointer (registers).
- `asX` — non-owning view/conversion.

Wire-visible identity fields (command id, queue id, namespace id) take no implicit default. The builder call site names them.

Spec-exact NVMe names are vocabulary and keep their spelling even where the baseline would treat the acronym as a word.

## Constructors

Extends the baseline constructor rules with a closed znvme vocabulary:

- `Type.from(input)` — pure reinterpretation or conversion from one input.
- `View.validate(bytes)` — typed validation, returns a borrowed read view.
- `Registers.at(base)` — typed register accessor over a base pointer.
- `Builder.encode(...)` into a caller-owned buffer — carries no allocator and no ownership of queue storage.

Construction-related `Error`, parameter structs, iterators, and owned helper types nest under the type they serve (`SubmissionQueue.Reservation`, `Controller.Init`, `admin.Identify.Cns`). Members keep their domain qualifier; only the owner's prefix drops.

Module-scope `build*` / `make*` / `from*` free functions are forbidden; they orphan construction from the result type.

## No object system

znvme defines no generic command registry, builder registry, or vtable over command or table types. Dispatch is explicit: the caller selects `admin.identify` vs `nvm.read`. Shared mechanics live in `core/`.

## Imports and aliases

Use the baseline import and alias rules. Group 2 (external packages) contains exactly one entry — `const stdx = @import("stdx");` — unless the file uses no stdx surface. The same grouping applies to re-exports in `src/nvme.zig`.

Prefer a top-level alias for the stdx surface actually used (`const DmaAddr = @import("stdx").addr.DmaAddr;`) over pulling the whole `stdx` namespace when only one type is needed. Multiple uses through the same subnamespace keep the subnamespace (`const bytes = @import("stdx").bytes;`).

## Comments

Use the baseline comment and module-header rules. znvme source comments may cite `docs/specs/...` paths only; `docs/planning/...` is never cited from source or tests.

## No generated source

Source under `src/` is handwritten. NVMe wire structs are transcribed into explicit Zig types with colocated layout assertions. Generated artifacts are limited to test fixtures or manifests outside `src/`, each with a documented regeneration command.

## Implementation order per module

Each module lands in this order:

1. owning spec exists and is approved;
2. public type skeletons and colocated layout assertions;
3. unit tests for layout and malformed inputs;
4. implementation;
5. round-trip tests where a builder exists (encode → decode through the matching view).
