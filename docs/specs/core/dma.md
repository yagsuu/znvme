# Core DMA (delegation)

Status: Approved.

`[znvme]` `znvme` does not own a DMA buffer or scatter-gather type. Every DMA-visible surface `znvme` touches — queue-pair storage, PRP payloads, Identify response buffers, controller-pointer registers — composes the upstream types from `stdx.dma`.

`[znvme]` This file is a delegation record. It fixes the boundary between `znvme` and `zstdx` for DMA memory and defines only the cross-spec delegation contract; concrete DMA type contracts remain in `zstdx`, and PRP-list shape remains in `docs/specs/core/prp.md`.

## Upstream ownership

`[znvme]` The following primitives are owned by `zstdx` and consumed by `znvme`:

- `[znvme]` `stdx.addr.DmaAddr` — device-visible address (`Address(DmaTag, u64)`); distinct from `PhysAddr` and `VirtAddr` at type level. Owning spec: `../zstdx/docs/specs/addr/address.md`.
- `[znvme]` `stdx.dma.Buffer(T)` — caller-owned `[]T` paired with a `DmaAddr`; the contiguous-buffer atom. Owning spec: `../zstdx/docs/specs/dma/buffer.md`.
- `[znvme]` `stdx.dma.ScatterGather` — `Segment` value, `List.Static(N)` / `List.Bounded` segment lists, and `Builder.Static(N, alignment)` / `Builder.Bounded(alignment)` builders that enforce uniform per-segment alignment. Owning spec: `../zstdx/docs/specs/dma/scatter-gather.md`.

`[znvme]` `znvme` uses the caller-provided variants only: `Buffer(T).init(...)` and `List.Static(N)` / `List.Bounded.wrap(...)`. Nothing under `znvme` allocates DMA memory.

## Delegation rationale

`[znvme]` `Buffer(T)` and the scatter-gather family are domain-neutral primitives because they encode host slice, device address, alignment, and byte-length bounds without NVMe policy. `znvme` composes them directly; a `znvme`-owned copy violates the sourcing rule in `docs/guidelines/conventions.md` §"Dependency on zstdx".

`[znvme]` The NVMe-specific rules that surround these types — queue-base page alignment against `CC.MPS`, PRP entry/list construction, PRP1/PRP2 selection, and command-specific transfer ownership — are protocol semantics and live in the consuming `znvme` specs (`controller/queue.md`, `core/prp.md`, `commands/nvm.md`). Those specs compose `stdx.dma.*` and add the NVMe policy on top.

## `znvme` composition sites

- `[znvme]` **`controller/queue.md`** — admin and I/O queues store their SQ and CQ as `stdx.dma.Buffer(Sqe)` and `stdx.dma.Buffer(Cqe)`. Callers additionally ensure the paired `DmaAddr` is page-aligned to `CC.MPS`; this is a caller invariant enforced at queue creation, not by the `Buffer` type.
- `[znvme]` **`core/prp.md`** — PRP entry representation, PRP-list storage shape, list capacity, and PRP-list fill rules are owned by `core/prp.md`. This spec only requires those rules to compose caller-owned `stdx.dma` storage instead of introducing a second DMA abstraction.
- `[znvme]` **`commands/sqe.md`** — SQE PRP fields carry raw PRP lane values produced by `core/prp.md`. The SQE spec owns the concrete wire-field endian representation.
- `[znvme]` **`commands/nvm.md`** — Read and Write builders take a data-buffer `stdx.dma.Buffer(u8)` and caller-owned PRP-list storage in the shape required by `core/prp.md`; they invoke `core/prp.md` to fill PRP1/PRP2/PRP-list before encoding into the SQE.
- `[znvme]` **`identify/*.md`** — Identify Controller / Namespace responses are 4 KiB buffers passed as `stdx.dma.Buffer(u8)`. The view types take a `[]const u8` slice (obtained via `buffer.constBytes()`); they never see the `DmaAddr` because the response is host-side.
- `[znvme]` **`controller/init.md`** — ASQ (Admin Submission Queue base) and ACQ (Admin Completion Queue base) fields in the controller register block are written from `dma.dmaAddr().raw()` at controller-enable time. Both must be page-aligned per NVMe 2.0; this is a caller invariant, checked at `Controller.init` and asserted at register write.

## Non-goals for `znvme`

`[znvme]` `znvme` does not:

- `[znvme]` allocate DMA-visible memory (caller responsibility);
- `[znvme]` perform IOMMU mapping, bounce buffering, or cache maintenance (caller responsibility);
- `[znvme]` re-implement `Buffer(T)`, `Segment`, `List`, or `Builder`;
- `[znvme]` introduce a `znvme`-owned wrapper around `stdx.dma.Buffer(T)` (composition through struct fields is used instead);
- `[znvme]` enforce page alignment inside the DMA types (that is a per-consumer runtime check because the page size is `CC.MPS`-negotiated).

## Boundary rule

`[znvme]` Everywhere `znvme` presents a DMA-visible surface to a caller, the caller passes a `stdx.dma.Buffer(T)` (or a `stdx.dma.ScatterGather.List.*` for multi-segment payloads) constructed against caller-owned host memory and a caller-computed `DmaAddr`. `znvme` never dereferences a `DmaAddr` and never touches the host memory except through the `buffer.slice()` / `buffer.bytes()` accessors the caller-facing API returns.

`[znvme]` Wire fields that carry a DMA address are encoded by the owning wire spec from `DmaAddr.raw()` or from PRP lane values returned by `core/prp.md`, according to that wire spec's endian-lane policy. They are never produced through raw pointer casts.

## Open questions

_(none)_
