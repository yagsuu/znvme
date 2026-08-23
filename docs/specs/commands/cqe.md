# Commands Completion Queue Entry

Status: Approved.

`Cqe` is znvme's transcription of the NVMe Common Completion Format: the 16-byte completion queue entry with two command-specific dwords, submission queue head pointer, submission queue identifier, command identifier, and a status lane whose bit layout is owned by `docs/specs/core/status.md`. This spec owns wire layout, in-place construction, and read accessors on `*const Cqe`.

The CQ is caller-owned typed DMA memory (`stdx.dma.Buffer(Cqe)` per `docs/specs/controller/queue.md`). Host drivers decode through methods on `*const Cqe`; emulator fixtures stamp slots with `Cqe.init(target, params)`.

## Owned scope

This spec owns:

- `Cqe`, the 16-byte `extern struct` wire layout with underscore-prefixed storage fields;
- colocated `@sizeOf`, `@alignOf`, and `@offsetOf` assertions for every NVMe-defined byte offset;
- `Cqe.Init`, semantic construction params with zero-safe defaults;
- `Cqe.init(target: *Cqe, params: Init) void`, in-place value constructor for device-emulator fixtures;
- semantic accessors on `*const Cqe`: `cid()` returns `Cid`, `sqid()` returns `Qid`, `sqhd()` returns `u16`, `dw0()` / `dw1()` return `u32`, `status()` returns `CompletionStatus`;
- convenience predicates on `*const Cqe`: `phase()`, `isPostedSuccess(expected_phase)`, `statusIsSuccess()`, delegating to `CompletionStatus`;
- first-slice native little-endian storage on `x86_64-freestanding-none`.

## Deferred scope and non-goals

This spec does not own:

- status-lane bit layout, `CompletionStatus` taxonomy, retry-delay, do-not-retry, more, and CRD semantics (`docs/specs/core/status.md`);
- phase-tag flip, queue head/tail state, capacity, wrap, and empty-slot detection (`docs/specs/controller/queue.md`);
- per-command interpretation of DW0 and DW1 (Set/Get Features result, Get Log Page continuation, Create I/O SQ head sync, and other command-specific meanings) — each command spec claims its own DW0/DW1 view;
- CQ head doorbell writes (`docs/specs/core/doorbell.md`);
- raw-byte validation of external CQE bytes;
- big-endian host or target compatibility.

## NVMe wire layout

`[nvme]` NVMe Base Specification 2.0 Common Completion Format:

| Offset | Field | Width | Meaning |
| ---: | --- | ---: | --- |
| `0x00` | `DW0` | 4 | Command specific |
| `0x04` | `DW1` | 4 | Command specific |
| `0x08` | `SQHD` | 2 | Submission Queue Head Pointer |
| `0x0a` | `SQID` | 2 | Submission Queue Identifier |
| `0x0c` | `CID` | 2 | Command Identifier |
| `0x0e` | `SF` | 2 | Status Field (includes Phase Tag) |

`[nvme]` Total size is 16 bytes. `[nvme]` Multi-byte fields are little-endian.

`SQHD` is the producer-side offset inside the submission queue that the controller has consumed through. It is not a queue identifier and does not wrap through `Qid`; `docs/specs/controller/queue.md` uses it to advance its SQ head pointer.

## Status Field bit layout

Status Field bit layout is normative in [`docs/specs/core/status.md`](../core/status.md) §"Bit layout". `Cqe.status()` returns `CompletionStatus.from(self._status)`; every bit of the wire lane crosses through that decode. This spec does not restate `SC`, `SCT`, `CRD`, `M`, `DNR`, or `P` widths.

## znvme behavior

`Cqe` is an `extern struct` with underscore-prefixed native little-endian `u32` and `u16` lanes on the first-slice `x86_64-freestanding-none` target. The `_` prefix marks fields as wire-storage; the public read surface is the method set on `*const Cqe`. Big-endian portability is deferred by `docs/specs/project/scope.md`.

`Cqe{}` field defaults are zero on every lane; the default value's status decode returns `phase() == false` because the status field is all-zero, and `statusIsSuccess() == true` because `CodeType == .generic` and `Code == success` at all-zero — `CompletionStatus.isSuccess()` is phase-agnostic per `docs/specs/core/status.md`. `isPostedSuccess(true) == false` for the default because phase does not match. Submission paths never rely on the default; CQ storage is device-written, and `docs/specs/controller/queue.md` owns whether a slot has been posted.

`Cqe.init(target, params)` stamps `target.*` in place with the params-provided lanes. `params` names use the NVMe short-form spellings (`cid`, `sqid`, `sqhd`, `dw0`, `dw1`, `status`) and default to zero, so `Cqe.init(target, .{})` produces a blank posted slot suitable for a fixture reset. Emulator fixtures assemble a `Cqe.Init` value with `status = CompletionStatus.success(phase).raw()` (or `CompletionStatus.genericFailure(phase, code).raw()`) and stamp the ring slot in one call. Host drivers never call `init` — CQEs are device-authored on the wire.

`cid()` and `sqid()` wrap the raw `u16` lanes through `Cid.from` and `Qid.from`. Per `docs/specs/core/ids.md`, every `u16` is a representable `Cid`, and every `u16` is a representable `Qid` (including `Qid.admin` at `0x0000` and `Qid.reserved_max` at `0xFFFF`). The accessors never reject a raw lane.

`status()` returns `CompletionStatus.from(self._status)`. Reserved `SCT` values are preserved as `.reserved_code_type` per `docs/specs/core/status.md` §"Validation behavior".

`phase()` is the poll-safe phase probe: it issues `@atomicLoad(u16, &self._status, .monotonic)` and returns bit 0. The monotonic atomic load forces a fresh reload of the device-written status lane on every call; it emits no memory barrier and does not order device DMA writes against subsequent CQE field reads — `docs/specs/controller/queue.md` owns that barrier. `statusIsSuccess()` returns `self.status().isSuccess()` and is phase-agnostic; the completion consumer reads it after `stdx.barrier.dma.acquire()` and before touching DW0 or DW1. `isPostedSuccess(expected_phase)` returns `self.phase() == expected_phase and self.statusIsSuccess()`; it is the single predicate for "posted successfully" on a caller-inspected CQ slot.

`sqhd()` returns the raw `u16`. Wrapping it in a strong type would misrepresent its meaning; it is an intra-SQ offset, not an identifier.

## `stdx` composition

This spec adds no direct `stdx` dependency. Transitive `stdx` surfaces reach `Cqe` through znvme-owned types:

- `stdx.tags.Tag(CidDomain, u16)` — inside `core.ids.Cid`, crossed at `cid()`;
- `stdx.tags.Tag(QidDomain, u16)` — inside `core.ids.Qid`, crossed at `sqid()`;
- `core.status.CompletionStatus` — semantic wrapper crossed at `status()`.

## Approved API

```zig
// src/commands/cqe.zig
//! NVMe Completion Queue Entry. Spec: docs/specs/commands/cqe.md.

const std = @import("std");

const ids = @import("../core/ids.zig");

const Cid = ids.Cid;
const CompletionStatus = @import("../core/status.zig").CompletionStatus;
const Qid = ids.Qid;

pub const size_bytes: usize = 16;

pub const Cqe = extern struct {
    _dw0: u32 = 0,
    _dw1: u32 = 0,
    _sqhd: u16 = 0,
    _sqid: u16 = 0,
    _cid: u16 = 0,
    _status: u16 = 0,

    pub const Init = struct {
        cid: u16 = 0,
        sqid: u16 = 0,
        sqhd: u16 = 0,
        dw0: u32 = 0,
        dw1: u32 = 0,
        status: u16 = 0,
    };

    pub fn init(target: *Cqe, params: Init) void {
        target.* = .{
            ._dw0 = params.dw0,
            ._dw1 = params.dw1,
            ._sqhd = params.sqhd,
            ._sqid = params.sqid,
            ._cid = params.cid,
            ._status = params.status,
        };
    }

    pub fn dw0(self: *const Cqe) u32 {
        return self._dw0;
    }

    pub fn dw1(self: *const Cqe) u32 {
        return self._dw1;
    }

    pub fn sqhd(self: *const Cqe) u16 {
        return self._sqhd;
    }

    pub fn sqid(self: *const Cqe) Qid {
        return .from(self._sqid);
    }

    pub fn cid(self: *const Cqe) Cid {
        return .from(self._cid);
    }

    pub fn status(self: *const Cqe) CompletionStatus {
        return .from(self._status);
    }

    pub fn phase(self: *const Cqe) bool {
        const raw_status = @atomicLoad(u16, &self._status, .monotonic);
        return (raw_status & 0x1) != 0;
    }

    pub fn statusIsSuccess(self: *const Cqe) bool {
        return self.status().isSuccess();
    }

    pub fn isPostedSuccess(self: *const Cqe, expected_phase: bool) bool {
        return self.phase() == expected_phase and self.statusIsSuccess();
    }

    comptime {
        std.debug.assert(@offsetOf(Cqe, "_dw0") == 0x00);
        std.debug.assert(@offsetOf(Cqe, "_dw1") == 0x04);
        std.debug.assert(@offsetOf(Cqe, "_sqhd") == 0x08);
        std.debug.assert(@offsetOf(Cqe, "_sqid") == 0x0a);
        std.debug.assert(@offsetOf(Cqe, "_cid") == 0x0c);
        std.debug.assert(@offsetOf(Cqe, "_status") == 0x0e);
        std.debug.assert(@sizeOf(Cqe) == size_bytes);
        std.debug.assert(@alignOf(Cqe) == @alignOf(u32));
    }
};
```

## Accessor behavior

Every scalar accessor is a pure load through the underscored typed field.

`cid()`, `sqid()`, and `status()` wrap through `Cid.from`, `Qid.from`, and `CompletionStatus.from`. The wrappers cost nothing beyond the raw load; they document the type-level identity of each lane.

`sqhd()` returns the raw `u16` because SQHD is an intra-SQ offset. `docs/specs/controller/queue.md` uses it to advance the SQ head pointer.

`phase()` is the poll-safe phase probe: it issues a monotonic atomic load of the CQE status lane and returns bit 0. The atomic load pins the compiler against caching or hoisting the phase read across loop iterations; it emits no memory barrier and does not order device DMA writes against subsequent CQE field reads. `docs/specs/controller/queue.md` owns the acquire barrier between a matched phase and the rest of the CQE. `statusIsSuccess()` delegates to `CompletionStatus.isSuccess()` and is phase-agnostic; the completion consumer reads it after `stdx.barrier.dma.acquire()` and before touching DW0/DW1. `isPostedSuccess(expected_phase)` composes `phase()` with `statusIsSuccess()` so a caller inspecting CQ storage directly gets one predicate that is both fresh and success-checked.

## Validation behavior

Per `docs/specs/architecture.md` §"Validation phases":

- **Compile time.** Colocated `@sizeOf`, `@alignOf`, and `@offsetOf` assertions inside `Cqe`. `zig build check` proves them on `x86_64-freestanding-none`.
- **Public validation.** None. CQ storage is caller-owned typed DMA memory; accessors on `*const Cqe` require a typed pointer, and there is no raw-byte parsing entry point in the first slice.
- **Assertions.** None inside `Cqe`. Phase-mismatch semantics — "this CQ slot has not been posted" — live in `docs/specs/controller/queue.md`. Every representable status value is legal per `docs/specs/core/status.md`.

## Example usage

Illustrative shape only; not part of the approved API. `docs/specs/controller/queue.md` owns non-waiting completion drain and deadline-driven completion polling.

```zig
const nvme = @import("nvme");
const stdx = @import("stdx");

const Cqe = nvme.commands.cqe.Cqe;

const depth: usize = 32;
var ring_backing: [depth]Cqe align(@alignOf(Cqe)) = .{.{}} ** depth;
const ring = try stdx.dma.Buffer(Cqe).init(&ring_backing, cq_dma_addr);

const slot = &ring.constSlice()[head_index];

if (slot.phase() != expected_phase) return .not_posted;

if (slot.isPostedSuccess(expected_phase)) {
    consume(slot.cid(), slot.dw0(), slot.dw1());
} else {
    fail(slot.cid(), slot.status());
}

// controller/queue.md advances the SQ head from slot.sqhd().
```

Emulator authoring a completion in place:

```zig
Cqe.init(&cq_ring[head], .{
    .cid = handle.command_id.raw(),
    .sqid = 0,
    .sqhd = new_sqhd,
    .status = nvme.core.status.CompletionStatus.success(current_phase).raw(),
});
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `Cqe.init` | never | never | O(1) | caller-serialized per slot | none | infallible |
| `dw0` / `dw1` | never | never | O(1) | borrowed load | none | infallible |
| `sqhd` | never | never | O(1) | borrowed load | none | infallible |
| `sqid` / `cid` / `status` | never | never | O(1) | borrowed load | none | infallible |
| `phase` | never | never | O(1) | borrowed load | monotonic atomic load on `_status` | infallible |
| `statusIsSuccess` | never | never | O(1) | borrowed load | none | infallible |
| `isPostedSuccess` | never | never | O(1) | borrowed load | monotonic atomic load on `_status` via `phase()` | infallible |

`Cqe` performs no allocation, waiting, hidden global access, barriers, volatile access, target probing, syscalls, locks, or I/O. `phase()` performs a single monotonic atomic load; every other accessor is a pure typed load. Ordering between CQE DMA visibility and host loads is owned by `docs/specs/controller/queue.md`, which places `stdx.barrier.dma.acquire()` after a matched phase and before reading the remaining CQE fields.

## Required tests

Test file `test/commands/cqe_test.zig`. Naming per `docs/guidelines/testing.md`.

- `unit: cqe extern layout matches NVMe completion format offsets` — behavioral mirror of the comptime offset assertions.
- `unit: cqe size is 16 bytes and alignment is 4`.
- `unit: cqe default value is all-zero` — every underscored field reads zero after `Cqe{}`.
- `unit: cqe accessors decode dw0 and dw1` — arbitrary `u32` inputs round-trip through `dw0` and `dw1`.
- `unit: cqe sqhd returns raw u16` — covers `0`, `0x8000`, `0xFFFF`.
- `unit: cqe sqid wraps through Qid.from` — covers admin (`0`), a mid-range IO qid, and `0xFFFF`.
- `unit: cqe cid wraps through Cid.from` — covers `0`, `0x7FFF`, `0xFFFF`.
- `unit: cqe status wraps through CompletionStatus.from` — success with phase set, one generic failure, one reserved-SCT value.
- `unit: cqe phase issues a monotonic atomic load of the status lane and returns bit 0`.
- `unit: cqe statusIsSuccess returns true for status-field all-zero slot as phase-agnostic status decode`.
- `unit: cqe isPostedSuccess returns false when phase does not match expected even when status is generic success`.
- `unit: cqe isPostedSuccess returns true when phase matches expected and status is generic success`.
- `unit: cqe isPostedSuccess returns false when phase matches expected but status is a generic failure`.
- `unit: Cqe.init(target, .{}) stamps target with every lane zero` — every underscored field reads zero after the call.
- `roundtrip: Cqe.init round-trips every Init field through accessors` — populate every non-default `Init` field; construct via `init`; assert every accessor returns the input.
- `roundtrip: cqe accessors decode every scalar field from a struct-literal slot` — success case with phase `1`, non-trivial DW0, DW1, SQHD, SQID, and CID.
- `roundtrip: cqe decodes generic invalid_field failure with CRD and DNR set` — verifies the failure path composes correctly across `status()` and `CompletionStatus.failure()`.
- `golden: cqe success completion minimal bytes` — bytes-exact 16-byte fixture representing a successful admin completion with CID `0x0001`, SQHD `0x0002`, SQID `0x0000`, phase `1`, and generic success. Regeneration command documented alongside the fixture.

## Open questions

_(none)_
