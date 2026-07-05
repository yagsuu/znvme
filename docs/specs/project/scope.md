# Project scope

Status: Approved. `[znvme]`

`znvme` is a Zig-native NVMe protocol library for firmware-class polled boot readers. `[znvme]` It owns the NVMe 2.0 wire protocol and controller mechanics needed for the NVM Command Set boot path. `[znvme]` Every domain-neutral primitive it composes comes from `stdx`. `[znvme]`

`znvme` is not a kernel driver framework, an OS storage stack, a PCI enumerator, a UEFI protocol implementation, a filesystem, an allocator, or an interrupt-driven driver. `[znvme]`

## Package identity

| Field | Value |
| --- | --- |
| Package name | `znvme` `[znvme]` |
| Public import name | `nvme` `[znvme]` |
| Public facade | `src/nvme.zig` `[znvme]` |
| Minimum Zig | `0.16.0` `[znvme]` |
| Host target | `x86_64-linux` (test suite) `[znvme]` |
| Freestanding target | `x86_64-freestanding-none` (`zig build check`) `[znvme]` |
| Dependency | `.stdx = .{ .path = "../zstdx" }` `[znvme]` |
| Normative specs | `docs/specs/` `[znvme]` |

Public examples use `const nvme = @import("nvme");` and `const stdx = @import("stdx");`. `[znvme]`

## Purpose

`znvme` implements only the NVMe protocol surface a firmware boot reader needs to bring an NVMe controller from BAR-mapped state to reading LBAs from a namespace. `[znvme]`

- Controller register-block layout uses typed `stdx.io.Mmio.Window` accessors and compile-time size, alignment, offset, and bit-size assertions for NVMe-defined fields. `[znvme]`
- CC/CSTS enable, ready, shutdown, and CFS state transitions follow the NVMe controller register semantics. `[nvme]`
- The initialization state machine runs over an injected `stdx.time.Clock.Monotonic(Backend)`. `[znvme]`
- The queue model is one admin queue pair plus N caller-owned polled I/O queue pairs, where N is negotiated via Set Features (Number of Queues). `[znvme]`
- Identify Controller, Identify Namespace, and Active Namespace ID list structures use NVMe CNS values and field definitions. `[nvme]`
- `znvme` exposes decoding views for Identify Controller, Identify Namespace, and Active Namespace ID list responses. `[znvme]`
- Admin command builders cover Identify, Create/Delete I/O SQ/CQ, Set/Get Features, and Abort opcodes defined by NVMe. `[nvme]`
- NVM command builders cover Read, Write, and Flush opcodes defined by the NVM Command Set. `[nvme]`
- SQE encoding, CQE decoding, phase-tag tracking, and doorbell arithmetic follow NVMe queue semantics. `[nvme]`
- `znvme` provides typed builders and views for SQE, CQE, phase-tag, and doorbell mechanics. `[znvme]`
- PRP list construction is the only data-transfer descriptor path in the approved slice. `[znvme]`

Everything else — device enumeration, DMA provisioning, UEFI protocol installation, interrupt policy, namespace selection, and block-device abstractions — is caller policy. `[znvme]`

### Supported consumers

`znvme` is designed for two role-symmetric consumers of the same wire and mechanics primitives: `[znvme]`

- **Host driver (primary consumer).** Firmware boot readers such as zfw compose the register accessors, doorbell arithmetic, admin/NVM command builders, and completion-polling loop to bring a controller up and read namespaces. Every approved API section names this the "host" path. `[znvme]`
- **Device emulator (equal-standing seam).** Software NVMe device implementations such as zvm compose the same wire structs (`Sqe`, `Cqe`, `IdentifyController`, `IdentifyNamespace`), register-block accessors, and byte-window validators to interpret host writes and author device responses. Approved API sections label device-authoring entry points explicitly (`ControllerRegisters.storeCap` / `storeVersion` / `storeCsts`, `Cqe.isPostedSuccess`, `Cqe.init`, `CompletionStatus.init` / `success` / `genericFailure`, `Sqe.validate`, admin `Cdw*.fromRaw`, `IdentifyController.init`, `IdentifyNamespace.init`). `[znvme]`

The shared wire, layout assertions, and byte-window validators are the seam between both consumers. `znvme` does not implement a controller state machine or a guest-DMA translator; the emulator supplies those, using `znvme` as the wire authority. `[znvme]`

## Ownership boundary

### znvme owns `[znvme]`

- The controller register block as an `extern struct` accessed through typed `stdx.io.Mmio.Window`/`stdx.io.Mmio.Register(T)` views. `[znvme]`
- Register layout assertions for `@sizeOf`, `@alignOf`, `@offsetOf` per NVMe-defined byte offset, and `@bitSizeOf` per packed field. `[znvme]`
- The CC.EN → CSTS.RDY handshake, CC.SHN → CSTS.SHST shutdown, and CSTS.CFS handling required by NVMe controller semantics. `[nvme]`
- The controller initialization state machine over an injected `stdx.time.Clock.Monotonic(Backend)`. `[znvme]`
- Admin and I/O queue-pair mechanics: submission ring, completion ring, doorbell writes, and phase-tag flip. `[znvme]`
- NVMe queue semantics for submission entries, completion entries, doorbell writes, and phase tags. `[nvme]`
- Command construction as typed builders over the wire SQE layout. `[znvme]`
- Admin builders for Identify, Create/Delete I/O SQ/CQ, Set/Get Features (Number of Queues), and Abort. `[znvme]`
- NVM builders for Read, Write, and Flush. `[znvme]`
- Completion parsing through a typed CQE view over status field, command id, and SQ head pointer. `[znvme]`
- Identify Controller, Identify Namespace, and Active Namespace ID list structure views. `[znvme]`
- Namespace geometry derivation from validated Identify Namespace data. `[znvme]`
- PRP1, PRP2, and PRP-list construction for data transfers. `[znvme]`

### The caller owns `[znvme]`

- PCI/ECAM enumeration and BAR discovery. `[znvme]`
- The MMIO mapping; the caller supplies a `stdx.io.Mmio.Window` covering the controller register aperture. `[znvme]`
- DMA-capable memory provisioning; `znvme` owns no memory. `[znvme]`
- Queue and transfer storage supplied through `stdx.dma.Buffer(T)` (`../zstdx/docs/specs/dma/buffer.md`). `[znvme]`
- UEFI protocol ABI types and protocol installation (`EFI_BLOCK_IO_PROTOCOL`, `EFI_DISK_IO_PROTOCOL`, ...). `[znvme]`
- Device-path node construction. `[znvme]`
- Interrupt policy; `znvme` is polled and the caller drives every completion loop. `[znvme]`
- The monotonic time backend consumed by `stdx.time.Clock.Monotonic(Backend)`. `[znvme]`
- The firmware's namespace-selection policy. `[znvme]`

### The device emulator owns `[znvme]`

- The guest-visible controller state machine. `[znvme]`
- Guest-DMA memory translation between guest and host address spaces. `[znvme]`
- The device-authored side of every register the host does not write (CAP, VS, CSTS from the host's read perspective). `[znvme]`
- Timing of CQE posting (phase flip, CDW visibility) relative to guest observation. `[znvme]`
- Any per-command emulation policy beyond wire-format validity. `[znvme]`

## Dependency posture

`znvme` depends on `zstdx` for every domain-neutral primitive. `[znvme]`

Consumed `stdx` surfaces: `[znvme]`

- `stdx.io.Mmio.Register(T)` / `stdx.io.Mmio.Window` — controller register block, doorbell array, and typed MMIO access. `[znvme]`
- `stdx.barrier.mmio.*` — SQ doorbell release and CSTS acquire ordering. `[znvme]`
- `stdx.barrier.dma.*` — CQE phase-read acquire ordering. `[znvme]`
- `stdx.time.Deadline` / `stdx.time.Duration` / `stdx.time.Clock.Monotonic(Backend)` / `stdx.time.Backoff` — RDY handshake and completion timeouts. `[znvme]`
- `stdx.layout.Le(u32)` / `stdx.layout.Le(u64)` — declaration-time documentation for little-endian wire fields. `[znvme]`
- NVMe multi-byte wire fields are little-endian. `[nvme]`
- First-slice code targets little-endian machines and assumes native little-endian loads for wire decoding. `[znvme]`
- `stdx.bytes.Cursor` / `stdx.bytes.load*` — Identify structure validation over caller byte buffers. `[znvme]`
- `stdx.dma.Buffer(T)` — caller-owned DMA-visible storage for queue pairs, PRP payloads, PRP list pages, and Identify response buffers. `[znvme]`
- `stdx.addr.DmaAddr` — device-visible address paired inside `stdx.dma.Buffer(T)`. `[znvme]`
- PRP1, PRP2, ASQ, and ACQ encoders write `dmaAddr().raw()` into the corresponding NVMe wire dword/qword lane. `[znvme]`
- `stdx.tags.Tag(Domain, u16)` — the strong-typed identifier used inside `Nsid`, `Cid`, and `Qid`. `[znvme]`
- `stdx.tags.TagAllocator.Bounded(CidDomain, u16)` — outstanding-CID pool backing the submission queue, over a caller-owned bitmap. `[znvme]`
- `stdx.io.poll.until` — caller-driven poll loop composing `Deadline`, `Backoff`, and a per-method predicate. `[znvme]`

A primitive `znvme` needs that `stdx` does not yet provide is a gap, not a local implementation opportunity. `[znvme]` Gaps are proposed upstream against `../zstdx` before the consuming `znvme` spec lands. `[znvme]` `znvme` does not shadow, wrap, or reimplement a `stdx` primitive. `[znvme]` A temporary experiment during scoping lives behind a clearly named internal type and names the upstream primitive it will be replaced by. `[znvme]`

## Marker vocabulary

Every normative claim in every `znvme` spec carries exactly one marker. `[znvme]`

- `[nvme]` marks a mandate from the NVMe Base Specification 2.0 or the NVM Command Set Specification 1.0. `[znvme]`
- `[znvme]` marks a `znvme` design choice; no external specification forces it. `[znvme]`

An unmarked normative claim is a defect. `[znvme]` Non-normative prose such as motivation, examples, and background stays unmarked. `[znvme]`

## Status labels

Specs and ledger entries use exactly these four labels. `[znvme]`

- **`[Approved]`** — accepted project fact or decision; the contract is stable. `[znvme]`
- **`[Draft proposal]`** — candidate design under review; implementation does not depend on it. `[znvme]`
- **`[Open question]`** — unresolved; implementation stops at the boundary and either updates the spec with an approved decision or isolates a clearly named unstable interface. `[znvme]`
- **`[Deferred]`** — intentionally out of the current target; implementation does not land until an approved spec opens the gate. `[znvme]`

The label sits at the head of the item it qualifies. `[znvme]`

## Transcription sources

- NVMe Base Specification 2.0. `[nvme]`
- NVM Command Set Specification 1.0. `[nvme]`

Specs transcribe field names, offsets, opcodes, and bit meanings from those documents. `[nvme]` Any deviation from published text is called out in the consuming spec with a `[znvme]` marker and the original name in prose. `[znvme]`

The conventional block-SSD boot path uses `CC.CSS = 0` for the NVM Command Set. `[nvme]` `znvme` supports only that command-set path in the approved slice. `[znvme]` Read, Write, and Flush opcodes and CQE status semantics are the NVM Command Set surface `znvme` owns. `[nvme]`

## Spec index

Specs land in the order they appear in `docs/planning/spec-queue.md`. `[znvme]` Each entry below states the spec's ownership in one clause. `[znvme]`

Any planning entry moved from `Queue` to `Approved` in `docs/planning/spec-queue.md` moves at the same time from `Planned` to `Approved` here; a queued entry is not part of the approved surface. `[znvme]`

### Approved

- `docs/specs/project/scope.md` — project purpose, ownership boundary, dependencies, status labels, deferred gates, and source index. `[znvme]`
- `docs/specs/architecture.md` — layering, the two type worlds, host-testability, validation phases, source-creation gate, build shape, and test aggregation. `[znvme]`
- `docs/specs/core/ids.md` — `Nsid`, `Cid`, and `Qid` newtypes and bounds. `[znvme]`
- `docs/specs/core/dma.md` — delegation record; DMA primitives remain owned by `stdx.dma.*`. `[znvme]`
- `docs/specs/core/status.md` — CQE status decode and error taxonomy. `[znvme]`
- `docs/specs/core/registers.md` — controller register-block extern layout, typed `stdx.io.Mmio.Window` accessor, and ABI assertions. `[znvme]`
- `docs/specs/core/doorbell.md` — doorbell stride and SQ/CQ doorbell addressing. `[znvme]`
- `docs/specs/core/prp.md` — PRP1, PRP2, and PRP-list construction. `[znvme]`
- `docs/specs/commands/sqe.md` — Submission Queue Entry wire layout. `[znvme]`
- `docs/specs/commands/cqe.md` — Completion Queue Entry wire layout. `[znvme]`
- `docs/specs/controller/queue.md` — `SubmissionQueue`, `CompletionQueue(Backend)`, and `Pair(Backend)` — role-agnostic types owning SQ/CQ mechanics, phase tag, and doorbell coupling for one pair. `[znvme]`
- `docs/specs/controller/init.md` — CC/CSTS enable → ready handshake and shutdown state machine over `stdx.time.Clock.Monotonic(Backend)`. `[znvme]`
- `docs/specs/commands/admin.md` — Identify, Create/Delete I/O SQ/CQ, Set/Get Features (Number of Queues), and Abort builders. `[znvme]`
- `docs/specs/identify/controller.md` — Identify Controller (CNS 01h) structure view. `[znvme]`
- `docs/specs/identify/namespace.md` — Identify Namespace (CNS 00h) structure view and geometry, and the Active Namespace ID list (CNS 02h) `List` type. `[znvme]`
- `docs/specs/commands/nvm.md` — NVM Read, Write, and Flush command builders. `[znvme]`
- `docs/specs/verification/test-strategy.md` — host-test contract, fixture policy, no-mocks rule, per-module required-test set, and the test-file manifest. `[znvme]`

### Planned

- `[Queued]` `docs/specs/examples/controller-bringup.md` — end-to-end controller enable → Identify → first read. `[znvme]`
- `[Queued]` `docs/specs/examples/read-namespace.md` — caller-owned one-LBA-range read through the public surface. `[znvme]`
- `[Queued]` `docs/specs/examples/malformed-inputs.md` — negative inputs each validating view rejects. `[znvme]`

## Non-goals

`znvme` must not implement or own any of the following; callers or sibling packages own them. `[znvme]`

- PCI/ECAM/PCIe enumeration and BAR discovery. `[znvme]`
- MSI/MSI-X configuration or interrupt routing. `[znvme]`
- DMA memory provisioning, IOMMU mapping, or cache-maintenance policy. `[znvme]`
- UEFI protocol installation, protocol ABI types, or firmware boot policy. `[znvme]`
- Device-path construction. `[znvme]`
- Block-device abstractions or partition-table parsers. `[znvme]`
- Filesystems. `[znvme]`
- Namespace selection policy for the boot device. `[znvme]`
- Allocators, event loops, and interrupt-driven completion paths. `[znvme]`
- A ready-made multi-queue reactor, scheduler, or per-core dispatcher — `znvme` owns queue-pair mechanics but no aggregate over multiple pairs. `[znvme]`
- Scatter/Gather List (SGL) transfers. `[znvme]`
- Namespaces outside the NVM Command Set. `[znvme]`
- Big-endian host/target compatibility. `[znvme]`
- A ready-made NVMe device emulator: `znvme` supplies the wire, layout, and validators; it does not supply a controller state machine or guest-DMA translator. `[znvme]`

## Deferred seams

Deferred items are gates: implementation does not land until the named approved spec exists. `[znvme]`

- **Shared CQ backing multiple SQs.** `[Deferred]` Per-CQE `SQID` routing to alternate SQs does not land until an approved spec claims that shape; one `Pair(Backend)` currently binds one SQ to one CQ. `[znvme]`
- **SGL transfers.** `[Deferred]` SGL transfer support does not land until an approved `commands/sgl.md` spec defines descriptor encoding, ownership, and tests. `[znvme]`
- **Non-NVM command sets.** `[Deferred]` Command sets other than `CC.CSS = 0` do not land until approved command-set specs define their register, command, and identify views. `[znvme]`
- **Interrupt-driven completion.** `[Deferred]` Interrupt-driven completion does not land until an approved controller-mode spec defines ownership, API shape, ordering, and tests. `[znvme]`
- **Non-x86_64 targets.** `[Deferred]` Non-x86_64 target support does not land until an approved architecture spec defines `stdx.barrier.mmio.*`, `stdx.barrier.dma.*`, and `stdx.arch` mappings for that target. `[znvme]`
- **Big-endian compatibility.** `[Deferred]` NVMe wire data is little-endian. `[nvme]` Non-little-endian target support does not land until approved wire specs add explicit byte-order coverage and tests. `[znvme]`

## Rule for API sketches

Code blocks in spec documents are illustrative unless the section is explicitly labeled **Approved API**. `[znvme]` Illustrative code discusses shape and usage; implementation must not treat it as a stable ABI or source contract. `[znvme]`

## Rule for unresolved details

If a detail is needed for implementation but appears only as an `[Open question]`, implementation stops at that boundary and either updates the spec with an approved decision or isolates a temporary experiment behind a clearly named unstable interface. `[znvme]` Temporary experimental interfaces must not be presented as final ABI. `[znvme]`

## Open questions

_(none)_
