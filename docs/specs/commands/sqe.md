# Commands Submission Queue Entry

Status: Approved.

`Sqe` is znvme's transcription of the NVMe Common Command Format: the 64-byte submission queue entry with typed CDW0 header, NSID, reserved dwords, metadata pointer, data pointer, and six command-specific dwords. This spec owns the wire layout, in-place construction through `Sqe.init(target, params)`, and read accessors on `*const Sqe`. Per-command dword semantics land in `docs/specs/commands/admin.md` and `docs/specs/commands/nvm.md`, each composing a `Sqe.Init` value and stamping the reserved slot with one `Sqe.init` call.

The SQ is caller-owned typed DMA memory (`stdx.dma.Buffer(Sqe)`). Host builders stamp reserved slots through `Sqe.init(reservation.slot, params)`; the device-emulator seam validates raw guest bytes through `Sqe.validate(bytes)`, which returns `error.ShortBuffer` on a byte window shorter than 64 and `error.Misaligned` on any pointer that is not `@alignOf(u32)`-aligned.

## Owned scope

This spec owns:

- `Sqe`, the 64-byte `extern struct` wire layout with underscore-prefixed storage fields;
- colocated `@sizeOf`, `@alignOf`, and `@offsetOf` assertions for every NVMe-defined byte offset;
- `Cdw0`, the `packed struct(u32)` splitting `opcode`, `fuse`, reserved bits, `psdt`, and `cid`;
- `Fuse` and `Psdt` non-exhaustive enums;
- `Sqe.Init`, the parameter struct that carries opcode, CID, NSID, fuse, PSDT, MPTR, DPTR, and every command-specific `cdw10`..`cdw15` lane;
- `Sqe.init(target: *Sqe, params: Init) void`, in-place value constructor for host builders and emulator fixtures;
- `Sqe.validate(bytes) Error!*const Sqe`, a fallible byte-window entry point returning `error.ShortBuffer` or `error.Misaligned`;
- read accessors on `*const Sqe`: `cdw0()`, `opcode()`, `fuse()`, `psdt()`, `cid()`, `nsid()`, `mptr()`, `dptr()`, `cdw10()`..`cdw15()`;
- `size_bytes`, the 64-byte SQE constant;
- `Error`, the SQE view error taxonomy (`ShortBuffer`, `Misaligned`);
- first-slice little-endian native storage on `x86_64-freestanding-none`.

## Deferred scope and non-goals

This spec does not own:

- named opcode enums for admin or NVM commands (`docs/specs/commands/admin.md`, `docs/specs/commands/nvm.md`);
- per-command CDW10..CDW15 field semantics (`docs/specs/commands/admin.md`, `docs/specs/commands/nvm.md`);
- PRP construction, validation, or list emission (`docs/specs/core/prp.md`);
- queue-ring state, phase tags, capacity, or doorbell coupling (`docs/specs/controller/queue.md`, `docs/specs/core/doorbell.md`);
- command submission, completion drain, polling, or timeouts (`docs/specs/controller/queue.md`, `docs/specs/controller/init.md`);
- SGL descriptor construction — SGL support is deferred by `docs/specs/project/scope.md`;
- fused-operation policy — first slice never issues fused pairs;
- CDW2 and CDW3 semantics — declared as reserved underscored lanes defaulting to zero and not surfaced through accessors;
- big-endian host or target compatibility.

## NVMe wire layout

`[nvme]` NVMe Base Specification 2.0 Common Command Format:

| Offset | Field | Width | Meaning |
| ---: | --- | ---: | --- |
| `0x00` | `CDW0` | 4 | opcode, fuse, reserved, PSDT, CID |
| `0x04` | `NSID` | 4 | Namespace Identifier |
| `0x08` | `CDW2` | 4 | Command specific; reserved in first slice |
| `0x0c` | `CDW3` | 4 | Command specific; reserved in first slice |
| `0x10` | `MPTR` | 8 | Metadata Pointer |
| `0x18` | `PRP1` | 8 | Data Pointer entry 1 |
| `0x20` | `PRP2` | 8 | Data Pointer entry 2 |
| `0x28` | `CDW10` | 4 | Command specific |
| `0x2c` | `CDW11` | 4 | Command specific |
| `0x30` | `CDW12` | 4 | Command specific |
| `0x34` | `CDW13` | 4 | Command specific |
| `0x38` | `CDW14` | 4 | Command specific |
| `0x3c` | `CDW15` | 4 | Command specific |

`[nvme]` Total size is 64 bytes. `[nvme]` Multi-byte fields are little-endian.

`PRP1` and `PRP2` are transported through the `DataPointers` block from `docs/specs/core/prp.md`, which owns bits `1:0` reserved-zero and page-alignment rules.

## CDW0 bit layout

`[nvme]` CDW0 packs the following, least-significant bit first:

| Bits | Field | Width | Meaning |
| ---: | --- | ---: | --- |
| `7:0` | `opcode` (OPC) | 8 | Command opcode |
| `9:8` | `fuse` (FUSE) | 2 | Fused operation |
| `13:10` | reserved | 4 | Reserved zero on host writes |
| `15:14` | `psdt` (PSDT) | 2 | PRP or SGL for Data Transfer |
| `31:16` | `cid` (CID) | 16 | Command Identifier |

`[nvme]` Fuse values: `00b` normal, `01b` first-of-pair, `10b` second-of-pair, `11b` reserved.

`[nvme]` PSDT values: `00b` PRPs, `01b` SGLs with metadata address, `10b` SGLs with metadata SGL, `11b` reserved.

The 4-bit hole between FUSE and PSDT is a `reserved_10: u4 = 0` field so builder-produced bytes zero it.

## znvme behavior

`Sqe` is an `extern struct` with underscore-prefixed native little-endian `u32` and `u64` lanes on the first-slice `x86_64-freestanding-none` target. The `_` prefix marks fields as wire-storage; the public read surface is the method set on `*const Sqe`. Big-endian portability is deferred by `docs/specs/project/scope.md`.

`Sqe{}` field defaults are zero on every lane; the default value produces a spec-legal blank slot with `Fuse.normal`, `Psdt.prps`, and `Cdw0.opcode = 0`. A caller never uses the blank slot; `Sqe.init` always stamps `opcode`, `command_id`, and `namespace_id` before submission.

`Cdw0` decode and encode go through `Cdw0.fromRaw(u32)` and `Cdw0.raw()`. The `_cdw0` field itself holds the raw `u32`; the packed struct is a semantic value at the accessor/init boundary. This mirrors the register-block idiom in `docs/specs/core/registers.md`.

`Sqe.init(target, params)` stamps `target.*` in place: it writes CDW0 (`opcode`, `fuse`, `psdt`, `cid` composed via `Cdw0`), NSID, MPTR, DPTR, and every `cdw10`..`cdw15` lane the caller supplied; CDW2, CDW3, and every omitted `cdw*` default to zero. No SQE authoring call ever inherits stale bytes from a previous command in the same slot. Per-command builders in `docs/specs/commands/admin.md` and `docs/specs/commands/nvm.md` compose one `Sqe.Init` value per command — a caller allocates a reservation, computes CDW10..CDW15 through the per-command packed structs, then calls `Sqe.init(reservation.slot, .{ ... })` in one statement.

`Init.namespace_id` defaults to `Nsid.none` (`0x0000_0000`), which matches the NVMe rule that admin commands not targeting a namespace clear NSID; per-command builders override the default when NSID is required.

`Init.fuse` defaults to `Fuse.normal` and `Init.psdt` defaults to `Psdt.prps`. First-slice commands never use fused pairs or SGLs; overriding these defaults is a caller-authored deviation that a future spec must approve.

`cid()` and `nsid()` return `Cid` and `Nsid` from `docs/specs/core/ids.md` through `.from(...)`; `Init.command_id` and `Init.namespace_id` accept those types and encode `.raw()` into the wire lanes. CID uniqueness within an outstanding-command set is a caller invariant owned by `docs/specs/controller/queue.md`.

`Sqe.init` and every accessor allocate nothing, wait on nothing, and touch no state outside the borrowed slot.

`Sqe.validate(bytes)` accepts a `[]const u8` and returns `error.ShortBuffer` when `bytes.len < 64` and `error.Misaligned` when `@intFromPtr(bytes.ptr) % @alignOf(u32) != 0`. On success it returns `*const Sqe` borrowing the caller's bytes. This mirrors `IdentifyController.validate` and `IdentifyNamespace.validate` — every byte-window entry point at a device-authored boundary is publicly fallible on both length and alignment. Emulator fixtures use `Sqe.validate` at the guest DMA boundary; host builders never validate their own writes.

## `stdx` composition

This spec adds no direct `stdx` dependency. Transitive `stdx` surfaces reach `Sqe` through znvme-owned types:

- `stdx.addr.DMAAddr` — inside `core.prp.DataPointers.prp1`/`prp2`, embedded as `_dptr`;
- `stdx.tags.Tag(Domain, u16)` — inside `core.ids.Cid` and `core.ids.Nsid`, crossed at the accessors and `Init`.

## Approved API

```zig
// src/commands/sqe.zig
//! NVMe Submission Queue Entry. Spec: docs/specs/commands/sqe.md.

const std = @import("std");

const ids = @import("../core/ids.zig");

const Cid = ids.Cid;
const DataPointers = @import("../core/prp.zig").DataPointers;
const Nsid = ids.Nsid;

pub const size_bytes: usize = 64;

pub const Error = error{ ShortBuffer, Misaligned };

pub const Fuse = enum(u2) {
    normal = 0b00,
    first = 0b01,
    second = 0b10,
    _,
};

pub const Psdt = enum(u2) {
    prps = 0b00,
    sgl_mptr_addr = 0b01,
    sgl_mptr_sgl = 0b10,
    _,
};

pub const Cdw0 = packed struct(u32) {
    opcode: u8,
    fuse: Fuse = .normal,
    reserved_10: u4 = 0,
    psdt: Psdt = .prps,
    cid: u16,

    pub fn fromRaw(value: u32) Cdw0 {
        return @bitCast(value);
    }

    pub fn raw(self: Cdw0) u32 {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert(@bitSizeOf(Cdw0) == 32);
        std.debug.assert(@sizeOf(Cdw0) == @sizeOf(u32));
        std.debug.assert(@alignOf(Cdw0) == @alignOf(u32));
    }
};

pub const Sqe = extern struct {
    _cdw0: u32 = 0,
    _nsid: u32 = 0,
    _reserved_8: u32 = 0,
    _reserved_12: u32 = 0,
    _mptr: u64 = 0,
    _dptr: DataPointers = .zero,
    _cdw10: u32 = 0,
    _cdw11: u32 = 0,
    _cdw12: u32 = 0,
    _cdw13: u32 = 0,
    _cdw14: u32 = 0,
    _cdw15: u32 = 0,

    pub const Init = struct {
        opcode: u8,
        command_id: Cid,
        namespace_id: Nsid = .none,
        fuse: Fuse = .normal,
        psdt: Psdt = .prps,
        metadata_pointer: u64 = 0,
        data_pointers: DataPointers = .zero,
        cdw10: u32 = 0,
        cdw11: u32 = 0,
        cdw12: u32 = 0,
        cdw13: u32 = 0,
        cdw14: u32 = 0,
        cdw15: u32 = 0,
    };

    pub fn init(target: *Sqe, params: Init) void {
        const header: Cdw0 = .{
            .opcode = params.opcode,
            .fuse = params.fuse,
            .psdt = params.psdt,
            .cid = params.command_id.raw(),
        };

        target.* = .{
            ._cdw0 = header.raw(),
            ._nsid = params.namespace_id.raw(),
            ._mptr = params.metadata_pointer,
            ._dptr = params.data_pointers,
            ._cdw10 = params.cdw10,
            ._cdw11 = params.cdw11,
            ._cdw12 = params.cdw12,
            ._cdw13 = params.cdw13,
            ._cdw14 = params.cdw14,
            ._cdw15 = params.cdw15,
        };
    }

    pub fn validate(bytes: []const u8) Error!*const Sqe {
        if (bytes.len < size_bytes) return error.ShortBuffer;
        if (@intFromPtr(bytes.ptr) % @alignOf(u32) != 0) return error.Misaligned;
        return @ptrCast(@alignCast(bytes.ptr));
    }

    pub fn cdw0(self: *const Sqe) Cdw0 {
        return .fromRaw(self._cdw0);
    }

    pub fn opcode(self: *const Sqe) u8 {
        return self.cdw0().opcode;
    }

    pub fn fuse(self: *const Sqe) Fuse {
        return self.cdw0().fuse;
    }

    pub fn psdt(self: *const Sqe) Psdt {
        return self.cdw0().psdt;
    }

    pub fn cid(self: *const Sqe) Cid {
        return .from(self.cdw0().cid);
    }

    pub fn nsid(self: *const Sqe) Nsid {
        return .from(self._nsid);
    }

    pub fn mptr(self: *const Sqe) u64 {
        return self._mptr;
    }

    pub fn dptr(self: *const Sqe) DataPointers {
        return self._dptr;
    }

    pub fn cdw10(self: *const Sqe) u32 {
        return self._cdw10;
    }

    pub fn cdw11(self: *const Sqe) u32 {
        return self._cdw11;
    }

    pub fn cdw12(self: *const Sqe) u32 {
        return self._cdw12;
    }

    pub fn cdw13(self: *const Sqe) u32 {
        return self._cdw13;
    }

    pub fn cdw14(self: *const Sqe) u32 {
        return self._cdw14;
    }

    pub fn cdw15(self: *const Sqe) u32 {
        return self._cdw15;
    }

    comptime {
        std.debug.assert(@offsetOf(Sqe, "_cdw0") == 0x00);
        std.debug.assert(@offsetOf(Sqe, "_nsid") == 0x04);
        std.debug.assert(@offsetOf(Sqe, "_reserved_8") == 0x08);
        std.debug.assert(@offsetOf(Sqe, "_reserved_12") == 0x0c);
        std.debug.assert(@offsetOf(Sqe, "_mptr") == 0x10);
        std.debug.assert(@offsetOf(Sqe, "_dptr") == 0x18);
        std.debug.assert(@offsetOf(Sqe, "_cdw10") == 0x28);
        std.debug.assert(@offsetOf(Sqe, "_cdw11") == 0x2c);
        std.debug.assert(@offsetOf(Sqe, "_cdw12") == 0x30);
        std.debug.assert(@offsetOf(Sqe, "_cdw13") == 0x34);
        std.debug.assert(@offsetOf(Sqe, "_cdw14") == 0x38);
        std.debug.assert(@offsetOf(Sqe, "_cdw15") == 0x3c);
        std.debug.assert(@sizeOf(Sqe) == size_bytes);
        std.debug.assert(@alignOf(Sqe) == @alignOf(u64));
    }
};
```

## Init and accessor behavior

`Sqe.init(target, params)` overwrites every lane. After `init`, every field except CDW0, NSID, MPTR, DPTR, and any non-default `cdw*` reads zero: `_reserved_8 == 0`, `_reserved_12 == 0`, and every omitted `cdw*` field defaults to zero. The `Fuse.normal` and `Psdt.prps` defaults on `Init` produce a first-slice-legal header when the caller omits them.

`cdw0()` returns the decoded `Cdw0` semantic value. Scalar accessors (`opcode`, `fuse`, `psdt`, `cid`) resolve through the same decode; the compiler is expected to fold repeated `Cdw0.fromRaw` calls at a call site.

`cid()` and `nsid()` return `Cid` and `Nsid` values; every representable `u16` is a legal `Cid` and every `u32` is a representable `Nsid` per `docs/specs/core/ids.md`.

## Validation behavior

Per `docs/specs/architecture.md` §"Validation phases":

- **Compile time.** Colocated `@sizeOf`, `@alignOf`, `@offsetOf`, and `@bitSizeOf` assertions inside `Sqe` and `Cdw0`. `zig build check` proves them on `x86_64-freestanding-none`.
- **Public validation.** `Sqe.validate(bytes)` returns `error.ShortBuffer` on short input and `error.Misaligned` when the byte pointer is not `@alignOf(u32)`-aligned. Host-driver paths never call `validate`; they stamp typed storage directly through `Sqe.init`. Emulator fixtures use `validate` at the guest DMA boundary.
- **Assertions.** None inside `Sqe`. Programmer-error assertions live in the consuming queue and per-command builder specs (`docs/specs/controller/queue.md`, `docs/specs/commands/admin.md`, `docs/specs/commands/nvm.md`), which enforce CID allocation state, queue capacity, and command legality.

## Example usage

Illustrative shape only; not part of the approved API. `docs/specs/commands/admin.md` owns the concrete Identify Controller builder.

```zig
const std = @import("std");

const nvme = @import("nvme");
const stdx = @import("stdx");

const Cdw0 = nvme.commands.sqe.Cdw0;
const Sqe = nvme.commands.sqe.Sqe;

const depth: usize = 32;
var ring_backing: [depth]Sqe align(@alignOf(Sqe)) = .{.{}} ** depth;
const ring = try stdx.dma.Buffer(Sqe).init(&ring_backing, sq_dma_addr);
const slot = &ring.slice()[tail_index];

Sqe.init(slot, .{
    .opcode = 0x06,
    .command_id = cid,
    .data_pointers = dptr,
    .cdw10 = identify_cdw10.raw(),
});

std.debug.assert(slot.opcode() == 0x06);
std.debug.assert(slot.cid().raw() == cid.raw());
std.debug.assert(slot.psdt() == .prps);
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `Cdw0.fromRaw` / `raw` | never | never | O(1) | value type | none | infallible |
| `Sqe.init` | never | never | O(1) | caller-serialized per slot | none | infallible |
| `Sqe.validate` | never | never | O(1) length + alignment check | borrowed slice | none | `ShortBuffer`, `Misaligned` |
| `cdw0` / `opcode` / `fuse` / `psdt` / `cid` | never | never | O(1) | borrowed load | none | infallible |
| `nsid` / `mptr` / `dptr` / `cdw10`..`cdw15` | never | never | O(1) | borrowed load | none | infallible |

`Sqe` performs no allocation, waiting, hidden global access, atomics, barriers, volatile access, target probing, syscalls, locks, or I/O. Ordering between SQE writes and controller observation is owned by the SQ tail doorbell path in `docs/specs/core/doorbell.md`.

## Required tests

Test file `test/commands/sqe_test.zig`. Naming per `docs/guidelines/testing.md`.

- `unit: sqe extern layout matches NVMe common command format offsets` — behavioral mirror of the comptime offset assertions.
- `unit: sqe size is 64 bytes and alignment is 8`.
- `unit: Sqe.validate rejects buffer shorter than 64 with ShortBuffer`.
- `unit: Sqe.validate rejects misaligned byte pointer with Misaligned` — construct a 64-byte window starting at an odd address, assert typed error.
- `unit: Sqe.validate accepts exact 64-byte aligned buffer and returns a pointer whose accessors decode the underlying bytes` — write a golden SQE via `Sqe.init`, cast to bytes, validate, read every accessor.
- `unit: cdw0 packs opcode fuse reserved psdt cid at documented bit positions` — `Cdw0.fromRaw(0)` and `Cdw0{...}.raw()` exercise each bit range.
- `unit: cdw0 fuse round-trips through non-exhaustive enum` — normal, first, second, and a reserved `0b11` bit pattern.
- `unit: cdw0 psdt round-trips through non-exhaustive enum` — prps, sgl_mptr_addr, sgl_mptr_sgl, and a reserved `0b11` bit pattern.
- `unit: cdw0 reserved 4-bit hole is zeroed on encode` — construct through the packed struct and confirm bits `13:10` are zero.
- `unit: sqe default value is all-zero and has psdt prps and fuse normal on decode`.
- `unit: Sqe.init stamps cdw0 and nsid and zeroes every other lane when Init omits them` — verifies `_reserved_8`, `_reserved_12`, `_mptr`, `_dptr.prp1`, `_dptr.prp2`, and `_cdw10`..`_cdw15` all read zero after init.
- `unit: Sqe.init defaults fuse to normal psdt to prps and namespace_id to none` — omitting those `Init` fields writes the expected wire bits.
- `unit: Sqe.init writes metadata_pointer into the mptr lane and leaves others unchanged` — same slot, before-and-after comparison of the other lanes.
- `unit: Sqe.init writes data_pointers prp1 at offset 0x18 and prp2 at offset 0x20`.
- `unit: Sqe.init writes cdw10 through cdw15 into their addressed lanes` — one assertion per lane, verifying the other five stay zero.
- `roundtrip: Sqe.init then accessors decode every scalar field the caller wrote` — Identify-shaped input covering opcode, fuse, psdt, cid, nsid, mptr, dptr, and every cdw10..cdw15.
- `roundtrip: Sqe.init composes prp list dptr from prp construction` — payload spanning more than one page via `core.prp.DataPointers.fromContiguous` with a caller-supplied `PrpList`.
- `golden: sqe identify controller minimal bytes` — bytes-exact fixture generated by `Sqe.init` for Identify Controller with fixed CID, blank DPTR, and CDW10 = `0x0000_0001`. Regeneration command documented alongside the fixture.

## Open questions

_(none)_
