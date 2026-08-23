# Project scope

Status: Approved.

`znvme` is a Zig-native NVMe protocol library for firmware-class boot readers. It owns the NVMe 2.0 wire protocol and controller mechanics needed for the NVM Command Set boot path. Every domain-neutral primitive it composes comes from `stdx`.

`znvme` is not a kernel driver framework, an OS storage stack, a PCI enumerator, a UEFI protocol implementation, a filesystem, an allocator, or an interrupt provider.

## Package identity

| Field | Value |
| --- | --- |
| Package name | `znvme` |
| Public import name | `nvme` |
| Public facade | `src/nvme.zig` |
| Minimum Zig | `0.16.0` |
| Host target | `x86_64-linux` (test suite) |
| Freestanding target | `x86_64-freestanding-none` (`zig build check`) |
| Dependency | `.stdx = .{ .path = "../zstdx" }` |
| Normative specs | `docs/specs/` |

Public examples use `const nvme = @import("nvme");` and `const stdx = @import("stdx");`.

## Purpose

`znvme` implements only the NVMe protocol surface a firmware boot reader needs to bring an NVMe controller from BAR-mapped state to reading LBAs from a namespace.

- Controller register-block layout uses typed `stdx.io.MMIO.Window` accessors and compile-time size, alignment, offset, and bit-size assertions for NVMe-defined fields.
- CC/CSTS enable, ready, shutdown, and CFS state transitions follow the NVMe controller register semantics.
- The initialization state machine runs over an injected `stdx.time.Clock.Monotonic(Backend)`.
- The queue model is one admin queue pair plus N caller-owned I/O queue pairs, where N is negotiated via Set Features (Number of Queues). Queue pairs support non-waiting completion drain and deadline-driven completion polling.
- Identify Controller, Identify Namespace, and Active Namespace ID list structures use NVMe CNS values and field definitions.
- `znvme` exposes decoding views for Identify Controller, Identify Namespace, and Active Namespace ID list responses.
- Admin command builders cover Identify, Create/Delete I/O SQ/CQ, Set/Get Features, and Abort opcodes defined by NVMe.
- NVM command builders cover Read, Write, and Flush opcodes defined by the NVM Command Set.
- SQE encoding, CQE decoding, phase-tag tracking, and doorbell arithmetic follow NVMe queue semantics.
- `znvme` provides typed builders and views for SQE, CQE, phase-tag, and doorbell mechanics.
- PRP list construction is the only data-transfer descriptor path in the approved slice.

Everything else — device enumeration, DMA provisioning, UEFI protocol installation, interrupt policy, namespace selection, and block-device abstractions — is caller policy.

### Supported consumers

`znvme` is designed for two role-symmetric consumers of the same wire and mechanics primitives:

- **Host driver (primary consumer).** Firmware boot readers such as zfw compose the register accessors, doorbell arithmetic, admin/NVM command builders, and queue completion APIs to bring a controller up and read namespaces. A host can use deadline-driven polling or a caller-owned interrupt notification with non-waiting CQ drain.
- **Device emulator (equal-standing seam).** Software NVMe device implementations such as zvm compose the same wire structs (`Sqe`, `Cqe`, `IdentifyController`, `IdentifyNamespace`), register-block accessors, and byte-window validators to interpret host writes and author device responses. Normative API sections label device-authoring entry points explicitly (`ControllerRegisters.storeCap` / `storeVersion` / `storeCsts`, `Cqe.isPostedSuccess`, `Cqe.init`, `CompletionStatus.init` / `success` / `genericFailure`, `Sqe.validate`, admin `Cdw*.fromRaw`, `IdentifyController.init`, `IdentifyNamespace.init`).

The shared wire, layout assertions, and byte-window validators are the seam between both consumers. `znvme` does not implement a controller state machine or a guest-DMA translator; the emulator supplies those, using `znvme` as the wire authority.

## Ownership boundary

### znvme owns

- The controller register block as an `extern struct` accessed through typed `stdx.io.MMIO.Window`/`stdx.io.MMIO.Register(T)` views.
- Register layout assertions for `@sizeOf`, `@alignOf`, `@offsetOf` per NVMe-defined byte offset, and `@bitSizeOf` per packed field.
- The CC.EN → CSTS.RDY handshake, CC.SHN → CSTS.SHST shutdown, and CSTS.CFS handling required by NVMe controller semantics.
- The controller initialization state machine over an injected `stdx.time.Clock.Monotonic(Backend)`.
- Admin and I/O queue-pair mechanics: submission ring, completion ring, doorbell writes, and phase-tag flip.
- NVMe queue semantics for submission entries, completion entries, doorbell writes, and phase tags.
- Command construction as typed builders over the wire SQE layout.
- Admin builders for Identify, Create/Delete I/O SQ/CQ, Set/Get Features (Number of Queues), and Abort.
- NVM builders for Read, Write, and Flush.
- Completion parsing through a typed CQE view over status field, command id, and SQ head pointer.
- Identify Controller, Identify Namespace, and Active Namespace ID list structure views.
- Namespace geometry derivation from validated Identify Namespace data.
- PRP1, PRP2, and PRP-list construction for data transfers.

### The caller owns

- PCI/ECAM enumeration and BAR discovery.
- The MMIO mapping; the caller supplies a `stdx.io.MMIO.Window` covering the controller register aperture.
- DMA-capable memory provisioning; `znvme` owns no memory.
- Queue and transfer storage supplied through `stdx.dma.Buffer(T)` (`../zstdx/docs/specs/dma/buffer.md`).
- UEFI protocol ABI types and protocol installation (`EFI_BLOCK_IO_PROTOCOL`, `EFI_DISK_IO_PROTOCOL`, ...).
- Device-path node construction.
- Interrupt provisioning and policy, including MSI/MSI-X configuration, vector routing, handler registration, masking, acknowledgement, deferred-work scheduling, and event-latch synchronization. `znvme` supplies only the NVMe `IEN` / `IV` command fields and non-waiting CQ drain.
- The monotonic time backend consumed by `stdx.time.Clock.Monotonic(Backend)`.
- The firmware's namespace-selection policy.

### The device emulator owns

- The guest-visible controller state machine.
- Guest-DMA memory translation between guest and host address spaces.
- The device-authored side of every register the host does not write (CAP, VS, CSTS from the host's read perspective).
- Timing of CQE posting (phase flip, CDW visibility) relative to guest observation.
- Any per-command emulation policy beyond wire-format validity.

## Dependency posture

`znvme` depends on `zstdx` for every domain-neutral primitive.

Consumed `stdx` surfaces:

- `stdx.io.MMIO.Register(T)` / `stdx.io.MMIO.Window` — controller register block, doorbell array, and typed MMIO access.
- `stdx.barrier.mmio.*` — SQ doorbell release and CSTS acquire ordering.
- `stdx.barrier.dma.*` — CQE phase-read acquire ordering.
- `stdx.time.Deadline` / `stdx.time.Duration` / `stdx.time.Clock.Monotonic(Backend)` / `stdx.time.Backoff` — RDY handshake and completion timeouts.
- `stdx.layout.Le(u32)` / `stdx.layout.Le(u64)` — declaration-time documentation for little-endian wire fields.
- NVMe multi-byte wire fields are little-endian. `[nvme]`
- First-slice code targets little-endian machines and assumes native little-endian loads for wire decoding.
- `stdx.bytes.Cursor` / `stdx.bytes.load*` — Identify structure validation over caller byte buffers.
- `stdx.dma.Buffer(T)` — caller-owned DMA-visible storage for queue pairs, PRP payloads, PRP list pages, and Identify response buffers.
- `stdx.addr.DMAAddr` — device-visible address paired inside `stdx.dma.Buffer(T)`.
- PRP1, PRP2, ASQ, and ACQ encoders write `dmaAddr().raw()` into the corresponding NVMe wire dword/qword lane.
- `stdx.tags.Tag(Domain, u16)` — the strong-typed identifier used inside `Nsid`, `Cid`, and `Qid`.
- `stdx.tags.TagAllocator.Bounded(CidDomain, u16)` — outstanding-CID pool backing the submission queue, over a caller-owned bitmap.
- `stdx.io.poll.until` — caller-driven deadline wait composing `Deadline`, `Backoff`, and a phase predicate before the queue drain.

A primitive `znvme` needs that `stdx` does not yet provide is a gap, not a local implementation opportunity. Gaps are proposed upstream against `../zstdx` before the consuming `znvme` spec lands. `znvme` does not shadow, wrap, or reimplement a `stdx` primitive. A temporary experiment during scoping lives behind a clearly named internal type and names the upstream primitive it will be replaced by.

## Marker vocabulary

NVMe-authoritative claims carry `[nvme]`: statements, bullets, tables, or sections derived from the NVMe Base Specification 2.0 or the NVM Command Set Specification 1.0.

Unmarked normative claims are znvme design decisions. An unmarked NVMe-authoritative claim is a defect.

The project-design marker is retired and should not appear in current specs. Non-normative prose such as motivation, examples, and background stays unmarked.

## Inline decision labels

Specification document status lines use `Status: Draft.`, `Status: Approved.`, or `Status: Superseded by <path>.` as required by `docs/guidelines/spec-writing.md`.

Planning ledgers and specification content MAY use these inline decision labels:

- **`[Approved]`** — accepted project fact or decision; the contract is stable.
- **`[Draft proposal]`** — candidate design under review; implementation does not depend on it.
- **`[Open question]`** — unresolved; implementation stops at the boundary and either updates the specification with an approved decision or isolates a clearly named unstable interface.
- **`[Deferred]`** — intentionally out of the current target; implementation does not land until an approved specification opens the gate.

An inline label MUST appear at the head of the item that it qualifies. An inline label MUST NOT replace the specification document status line.

## Transcription sources

- NVMe Base Specification 2.0. `[nvme]`
- NVM Command Set Specification 1.0. `[nvme]`

Specs transcribe field names, offsets, opcodes, and bit meanings from those documents. Any deviation from published text is called out in the consuming spec with the original name in prose.

`[nvme]` The conventional block-SSD boot path uses `CC.CSS = 0` for the NVM Command Set.

`[nvme]` Read, Write, and Flush opcodes and CQE status semantics are defined by the NVM Command Set.

`znvme` supports only that command-set path in the approved slice and owns that NVM Command Set surface.

## Spec index

Specs land in the order they appear in `docs/planning/spec-queue.md`. Each entry below states the spec's ownership in one clause.

Any planning entry moved from `Queue` to `Approved` in `docs/planning/spec-queue.md` moves at the same time from `Planned` to `Approved` here; a queued entry is not part of the approved surface.

### Approved

- `docs/specs/project/scope.md` — project purpose, ownership boundary, dependencies, document statuses, inline decision labels, deferred gates, and source index.
- `docs/specs/architecture.md` — layering, the two type worlds, host-testability, validation phases, source-creation gate, build shape, and test aggregation.
- `docs/specs/core/ids.md` — `Nsid`, `Cid`, and `Qid` newtypes and bounds.
- `docs/specs/core/dma.md` — delegation record; DMA primitives remain owned by `stdx.dma.*`.
- `docs/specs/core/status.md` — CQE status decode and error taxonomy.
- `docs/specs/core/registers.md` — controller register-block extern layout, typed `stdx.io.MMIO.Window` accessor, and ABI assertions.
- `docs/specs/core/doorbell.md` — doorbell stride and SQ/CQ doorbell addressing.
- `docs/specs/core/prp.md` — PRP1, PRP2, and PRP-list construction.
- `docs/specs/commands/sqe.md` — Submission Queue Entry wire layout.
- `docs/specs/commands/cqe.md` — Completion Queue Entry wire layout.
- `docs/specs/controller/queue.md` — `SubmissionQueue`, `CompletionQueue(Backend)`, and `Pair(Backend)` — role-agnostic types owning SQ/CQ mechanics, phase tag, and doorbell coupling for one pair.
- `docs/specs/controller/init.md` — CC/CSTS enable → ready handshake and shutdown state machine over `stdx.time.Clock.Monotonic(Backend)`.
- `docs/specs/commands/admin.md` — Identify, Create/Delete I/O SQ/CQ, Set/Get Features (Number of Queues), and Abort builders.
- `docs/specs/identify/controller.md` — Identify Controller (CNS 01h) structure view.
- `docs/specs/identify/namespace.md` — Identify Namespace (CNS 00h) structure view and geometry, and the Active Namespace ID list (CNS 02h) `List` type.
- `docs/specs/commands/nvm.md` — NVM Read, Write, and Flush command builders.
- `docs/specs/verification/test-strategy.md` — host-test contract, fixture policy, no-mocks rule, per-module required-test set, and the test-file manifest.

### Planned

- `[Queued]` `docs/specs/examples/controller-bringup.md` — end-to-end controller enable → Identify → first read.
- `[Queued]` `docs/specs/examples/read-namespace.md` — caller-owned one-LBA-range read through the public surface.
- `[Queued]` `docs/specs/examples/malformed-inputs.md` — negative inputs each validating view rejects.

## Non-goals

`znvme` must not implement or own any of the following; callers or sibling packages own them.

- PCI/ECAM/PCIe enumeration and BAR discovery.
- MSI/MSI-X configuration or interrupt routing.
- DMA memory provisioning, IOMMU mapping, or cache-maintenance policy.
- UEFI protocol installation, protocol ABI types, or firmware boot policy.
- Device-path construction.
- Block-device abstractions or partition-table parsers.
- Filesystems.
- Namespace selection policy for the boot device.
- Allocators and event loops. Interrupt provisioning, delivery, handlers, and synchronization remain caller-owned; queue pairs expose only non-waiting completion drain.
- A ready-made multi-queue reactor, scheduler, or per-core dispatcher — `znvme` owns queue-pair mechanics but no aggregate over multiple pairs.
- Scatter/Gather List (SGL) transfers.
- Namespaces outside the NVM Command Set.
- Big-endian host/target compatibility.
- A ready-made NVMe device emulator: `znvme` supplies the wire, layout, and validators; it does not supply a controller state machine or guest-DMA translator.

## Deferred seams

Deferred items are gates: implementation does not land until the named approved spec exists.

- `[Deferred]` **Shared CQ backing multiple SQs.** Per-CQE `SQID` routing to alternate SQs does not land until an approved specification claims that shape. One `Pair(Backend)` currently binds one SQ to one CQ.
- `[Deferred]` **SGL transfers.** SGL transfer support does not land until an approved `commands/sgl.md` specification defines descriptor encoding, ownership, and tests.
- `[Deferred]` **Non-NVM command sets.** Command sets other than `CC.CSS = 0` do not land until approved command-set specifications define their register, command, and identify views.
- `[Deferred]` **Non-x86_64 targets.** Non-x86_64 target support does not land until an approved architecture specification defines `stdx.barrier.mmio.*`, `stdx.barrier.dma.*`, and `stdx.arch` mappings for that target.
- `[Deferred]` **Big-endian compatibility.** `[nvme]` NVMe wire data is little-endian. Non-little-endian target support does not land until approved wire specifications add explicit byte-order coverage and tests.

## Rule for API snippets

Code blocks in a `## API` section are normative public signatures. Code blocks in legacy `## Approved API` sections remain normative until a substantial revision moves the specification to the current section model. Other code blocks are illustrative unless the specification explicitly marks them normative.

## Rule for unresolved details

If a detail is needed for implementation but appears only as an `[Open question]`, implementation stops at that boundary and either updates the spec with an approved decision or isolates a temporary experiment behind a clearly named unstable interface. Temporary experimental interfaces must not be presented as final ABI.

## Open questions

_(none)_
