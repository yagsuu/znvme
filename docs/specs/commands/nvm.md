# Commands NVM

Status: Approved.

`[znvme]` `nvm` owns the typed builder families for the NVM Command Set opcodes the boot path issues: Read (`02h`), Write (`01h`), and Flush (`00h`). Each builder reserves an SQ slot on a caller-owned `queue.SubmissionQueue`, stamps the SQE in place through `Sqe.init(reservation.slot, .{ ... })`, and stages — a one-call flow that returns a `queue.Handle` the caller pairs with later completions. The caller rings the SQ tail doorbell with `try sq.flush()` when a batch (or a single command) is ready to publish.

`[znvme]` The first slice targets namespaces formatted without end-to-end protection information (`DPS.pit = disabled`) and without Directives, so `PRINFO`, `STC`, `DTYPE`, `DSPEC`, `DSM`, and the CDW2/CDW3/CDW14/CDW15 protection lanes stay reserved zero on the wire. Namespaces that require those lanes are not part of the first-slice scope.

## Owned scope

`[znvme]` This spec owns:

- `[znvme]` `Opcode`, a non-exhaustive `enum(u8)` for NVM Command Set opcodes;
- `[znvme]` `Read.encode`, `Write.encode`, `Flush.encode` — one static factory per command family;
- `[znvme]` `Read.Cdw12` and `Write.Cdw12` — per-command `packed struct(u32)` types with `raw()` / `fromRaw()` and colocated `@bitSizeOf` / `@sizeOf` assertions;
- `[znvme]` per-command `Params` structs;
- `[znvme]` one-based `logical_block_count` encoding: the builder writes `nlb_zero_based = logical_block_count - 1` to the wire and rejects `logical_block_count == 0`;
- `[znvme]` NSID admissibility at builder scope: Read and Write reject `Nsid.none` and `Nsid.broadcast`; Flush rejects only `Nsid.none`;
- `[znvme]` the error taxonomy for NVM builders (`InvalidNamespaceIdentifier`, `InvalidLogicalBlockCount`).

## Deferred scope and non-goals

`[znvme]` This spec does not own:

- `[znvme]` NVM Command Set opcodes outside the boot path: Write Uncorrectable (`04h`), Compare (`05h`), Write Zeroes (`08h`), Dataset Management (`09h`), Verify (`0Ch`), Reservation Register / Report / Acquire / Release (`0Dh`, `0Eh`, `11h`, `15h`), Copy (`19h`), Get LBA Status (`86h`), vendor-specific (`80h..FFh`);
- `[znvme]` end-to-end Protection Information — `PRINFO` and `STC` bits in CDW12 stay reserved zero; `CDW2`, `CDW3`, `CDW14`, and `CDW15` stay reserved zero via the `Sqe.Init` defaults; the ELBST / LBST / EILBRT / ILBRT / ELBAT / LBAT / ELBATM / LBATM lanes are not surfaced. A future PI spec claims those lanes;
- `[znvme]` Directives — Write CDW12 `DTYPE` and CDW13 `DSPEC` stay reserved zero;
- `[znvme]` Dataset Management hints — Read/Write CDW13 low byte stays reserved zero; performance hints (Incompressible, Sequential Request, Access Latency, Access Frequency) are non-boot policy;
- `[znvme]` fused-operation composition — the first slice never issues Compare+Write pairs;
- `[znvme]` Metadata Pointer construction — the `metadata_pointer` `Params` field is passed through to `Sqe.metadata_pointer`; the builder does not validate MPTR against namespace geometry. Callers targeting a namespace with `MC.separate_buffer = 1` compose the metadata buffer's DMA address at the call site; namespaces that are extended-LBA or metadata-free pass `metadata_pointer = 0`;
- `[znvme]` MDTS enforcement — `IdentifyController.maxDataTransferSize()` is caller policy; the NVM builder trusts caller sizing;
- `[znvme]` `DataPointers` construction, payload PRP-list emission, and page-alignment validation — `docs/specs/core/prp.md`;
- `[znvme]` completion `DW0` / `DW1` interpretation — Read, Write, and Flush return no meaningful command-specific completion dwords;
- `[znvme]` completion polling and timeouts — `SubmissionQueue.stage` returns a `queue.Handle`; the caller flushes and polls through the owning `Pair(Backend)`;
- `[znvme]` outstanding-NSID tracking, namespace-active checks, or MDTS-vs-payload cross-checks;
- `[znvme]` SGL descriptors and the SGL `Psdt` selection;
- `[znvme]` big-endian host or target compatibility.

## `stdx` composition

`[znvme]` No direct `stdx` surface. Every stdx primitive reaches NVM builders through znvme-owned types.

`[znvme]` Composed through znvme types:

- `[znvme]` `controller.queue.SubmissionQueue` — `reserveSlot`, `stage`, `flush`, `releaseReservation`;
- `[znvme]` `controller.queue.Handle` — returned from `stage`, propagated by every builder;
- `[znvme]` `controller.queue.ReserveError` — merged into `nvm.Error`;
- `[znvme]` `commands.sqe.Sqe` — SQE authorship in place via `Sqe.init(reservation.slot, params)`;
- `[znvme]` `core.ids.Nsid` — namespace-identifier parameters and admissibility predicates;
- `[znvme]` `core.prp.DataPointers` — DPTR values for Read and Write.

## NVMe wire encodings

### Read — opcode `02h`

`[nvme]` Per NVM Command Set Specification 1.0 §3.2.4 (Figures 44–52):

| Marker | CDW | Bits | Field | Meaning |
| --- | --- | ---: | --- | --- |
| `[nvme]` | CDW10 | `31:00` | `SLBA[31:00]` | Starting LBA low dword |
| `[nvme]` | CDW11 | `31:00` | `SLBA[63:32]` | Starting LBA high dword |
| `[nvme]` | CDW12 | `15:00` | `NLB` | Number of Logical Blocks, zero-based |
| `[nvme]` | CDW12 | `23:16` | reserved |  |
| `[nvme]` | CDW12 | `24` | `STC` | Storage Tag Check |
| `[nvme]` | CDW12 | `25` | reserved |  |
| `[nvme]` | CDW12 | `29:26` | `PRINFO` | Protection Information Field |
| `[nvme]` | CDW12 | `30` | `FUA` | Force Unit Access |
| `[nvme]` | CDW12 | `31` | `LR` | Limited Retry |
| `[nvme]` | CDW13 | `31:00` | `DSM` + reserved | Dataset Management |
| `[nvme]` | CDW2/3 | `47:00` | ELBST/EILBRT | Reserved when PI is disabled |
| `[nvme]` | CDW14 | `31:00` | ELBST/EILBRT | Reserved when PI is disabled |
| `[nvme]` | CDW15 | `31:16` | `ELBATM` | Reserved when PI is disabled |
| `[nvme]` | CDW15 | `15:00` | `ELBAT` | Reserved when PI is disabled |

`[nvme]` MPTR: a caller-owned metadata buffer or zero. DPTR: encoded through `core.prp.DataPointers`. NSID: target namespace (`1 .. 0xFFFF_FFFE`).

### Write — opcode `01h`

`[nvme]` Per NVM Command Set Specification 1.0 §3.2.6 (Figures 59–67). The wire layout matches Read except for CDW12 bits `23:20`:

| Marker | CDW | Bits | Field | Meaning |
| --- | --- | ---: | --- | --- |
| `[nvme]` | CDW12 | `15:00` | `NLB` | Number of Logical Blocks, zero-based |
| `[nvme]` | CDW12 | `19:16` | reserved |  |
| `[nvme]` | CDW12 | `23:20` | `DTYPE` | Directive Type |
| `[nvme]` | CDW12 | `24` | `STC` | Storage Tag Check |
| `[nvme]` | CDW12 | `25` | reserved |  |
| `[nvme]` | CDW12 | `29:26` | `PRINFO` | Protection Information Field |
| `[nvme]` | CDW12 | `30` | `FUA` | Force Unit Access |
| `[nvme]` | CDW12 | `31` | `LR` | Limited Retry |
| `[nvme]` | CDW13 | `31:16` | `DSPEC` | Directive Specific |
| `[nvme]` | CDW13 | `15:00` | `DSM` + reserved | Dataset Management |

`[nvme]` CDW10, CDW11, MPTR, DPTR, CDW2/3, CDW14, CDW15 semantics match Read. NSID: target namespace (`1 .. 0xFFFF_FFFE`).

### Flush — opcode `00h`

`[nvme]` Per NVM Command Set Specification 1.0 §3.2.1. Flush uses no command-specific dwords; every field outside opcode, CID, and NSID is reserved zero. No data transfer.

`[nvme]` NSID field: NVMe Base Specification 2.0 Figure 18 note 4 permits `NSID = FFFF_FFFFh` (broadcast) for Flush, in which case the controller flushes every attached namespace. NSID = `0` is not defined for any NVM command.

## znvme behavior

`[znvme]` Every builder is a struct with a static `encode` method (Read/Write) or a named factory (`Flush.encode`). No stateful builder value persists across calls. The `SubmissionQueue` allocates every CID from its bounded pool; no `Params` struct carries a `command_id` field — callers read `handle.command_id` off the returned `queue.Handle`, mirroring `docs/specs/commands/admin.md`.

`[znvme]` Every factory:

1. `[znvme]` validates the caller-provided parameters (NSID admissibility, `logical_block_count > 0`);
2. `[znvme]` calls `sq.reserveSlot()`;
3. `[znvme]` sets up an `errdefer sq.releaseReservation(reservation)` so any failure between reservation and `stage` releases the CID and leaves the SQ tail untouched;
4. `[znvme]` composes a single `Sqe.Init` value carrying opcode, `reservation.command_id`, `namespace_id`, `metadata_pointer`, `data_pointers`, and the per-command `cdw10`..`cdw15` lanes it needs;
5. `[znvme]` calls `Sqe.init(reservation.slot, sqe_init)` to stamp the reserved slot in place — every unspecified `Init` field is zero, so `CDW2`, `CDW3`, `CDW14`, `CDW15`, and any omitted `cdw*` lane inherit zero without leaking a previous slot's bytes;
6. `[znvme]` returns `sq.stage(reservation)` — the returned `queue.Handle` carries the reservation-assigned CID. `stage` is infallible; the SQE is in the ring but not yet visible to the controller. The caller batches multiple `encode` calls and then invokes `try sq.flush()` to ring the SQ tail doorbell once for the whole batch.

`[znvme]` NSID admissibility:

- `[znvme]` `Read.encode` and `Write.encode` reject `Nsid.none` and `Nsid.broadcast` with `error.InvalidNamespaceIdentifier`. NVMe defines `NSID = 0` as no-namespace, and Read/Write are not on the list of commands accepting broadcast (NVMe Base Specification 2.0 Figure 18 note 4).
- `[znvme]` `Flush.encode` rejects only `Nsid.none`. Broadcast is legal on the wire; whether the target controller implements the broadcast semantic is a device capability the caller decides via `IdentifyController`, not a builder-scope check.

`[znvme]` `Read.Params.logical_block_count` and `Write.Params.logical_block_count` are one-based `u16` values. The builder writes `nlb_zero_based = logical_block_count - 1` to the wire and rejects `logical_block_count == 0` with `error.InvalidLogicalBlockCount`. The API range is therefore `1 .. 65535` blocks per command; the wire NLB field can theoretically encode `65536` (raw `0xFFFF`), but the first-slice API caps at `65535` for symmetry with the admin builders' one-based / zero-based mapping. Callers issuing larger transfers split them into multiple commands, which is also the natural response to `IdentifyController.maxDataTransferSize()`.

`[znvme]` `Read.Params.starting_lba` and `Write.Params.starting_lba` are `u64` values written directly to `CDW10` (`@truncate(starting_lba)`) and `CDW11` (`@truncate(starting_lba >> 32)`). The builder does not consult namespace geometry; a caller reading past `NSZE - 1` receives a device-authored `Invalid Field in Command` completion.

`[znvme]` `Read.Params.data_pointers` and `Write.Params.data_pointers` are `core.prp.DataPointers` values composed by the caller through `DataPointers.fromContiguous`. Empty or misaligned payloads are rejected at `DataPointers.fromContiguous` and never reach the NVM builder. The builder does not cross-check `logical_block_count × Geometry.transfer_stride_bytes` against the payload's byte length — namespace geometry is caller state, and a mismatch surfaces on the wire as a device-authored status.

`[znvme]` `Read.Params.metadata_pointer` and `Write.Params.metadata_pointer` default to `0`, which is the correct value for extended-LBA namespaces (metadata rides inline in the data buffer) and for namespaces with zero-byte metadata. Callers targeting a namespace with `MC.separate_buffer = 1` supply the metadata buffer's DMA address raw `u64`.

`[znvme]` `Read.Params.limited_retry` and `Read.Params.force_unit_access` (and the Write equivalents) default to `false`. `Flush.Params` has no such toggles — Flush has no LR or FUA on the wire.

`[znvme]` `Sqe.Init.fuse` and `Sqe.Init.psdt` retain the `Fuse.normal` / `Psdt.prps` defaults from `docs/specs/commands/sqe.md`. The first slice never issues fused pairs and never uses SGLs.

`[znvme]` Symmetric CDW decoding: `Read.Cdw12` and `Write.Cdw12` each expose `fromRaw(u32) Self` alongside `raw() u32`. Host builders compose values through field constructors and call `raw()` at the SQE boundary; device emulators decode host CDW writes through `fromRaw(sqe.cdw12())` and read fields as typed values. Both directions bit-cast; the packed-struct layout is the single source of truth.

## Approved API

```zig
// src/commands/nvm.zig
//! NVM Command Set builders: Read, Write, Flush. Spec: docs/specs/commands/nvm.md.

const std = @import("std");

const ids = @import("../core/ids.zig");
const queue = @import("../controller/queue.zig");

const DataPointers = @import("../core/prp.zig").DataPointers;
const Nsid = ids.Nsid;
const Sqe = @import("sqe.zig").Sqe;

pub const Opcode = enum(u8) {
    flush = 0x00,
    write = 0x01,
    read = 0x02,
    _,
};

pub const Error = error{
    InvalidNamespaceIdentifier,
    InvalidLogicalBlockCount,
} || queue.ReserveError;

pub const Read = struct {
    pub const Cdw12 = packed struct(u32) {
        nlb_zero_based: u16,
        reserved_16: u8 = 0,
        storage_tag_check: u1 = 0,
        reserved_25: u1 = 0,
        prinfo: u4 = 0,
        force_unit_access: u1,
        limited_retry: u1,

        pub fn fromRaw(value: u32) Cdw12 {
            return @bitCast(value);
        }

        pub fn raw(self: Cdw12) u32 {
            return @bitCast(self);
        }

        comptime {
            std.debug.assert(@bitSizeOf(Cdw12) == 32);
            std.debug.assert(@sizeOf(Cdw12) == @sizeOf(u32));
        }
    };

    pub const Params = struct {
        namespace_id: Nsid,
        starting_lba: u64,
        logical_block_count: u16,
        data_pointers: DataPointers,
        limited_retry: bool = false,
        force_unit_access: bool = false,
        metadata_pointer: u64 = 0,
    };

    pub fn encode(sq: *queue.SubmissionQueue, params: Params) Error!queue.Handle {
        if (params.namespace_id.isNone() or params.namespace_id.isBroadcast()) {
            return error.InvalidNamespaceIdentifier;
        }
        if (params.logical_block_count == 0) return error.InvalidLogicalBlockCount;

        const reservation = try sq.reserveSlot();
        errdefer sq.releaseReservation(reservation);

        Sqe.init(reservation.slot, .{
            .opcode = @intFromEnum(Opcode.read),
            .command_id = reservation.command_id,
            .namespace_id = params.namespace_id,
            .metadata_pointer = params.metadata_pointer,
            .data_pointers = params.data_pointers,
            .cdw10 = @truncate(params.starting_lba),
            .cdw11 = @truncate(params.starting_lba >> 32),
            .cdw12 = (Cdw12{
                .nlb_zero_based = params.logical_block_count - 1,
                .force_unit_access = @intFromBool(params.force_unit_access),
                .limited_retry = @intFromBool(params.limited_retry),
            }).raw(),
        });

        return sq.stage(reservation);
    }
};

pub const Write = struct {
    pub const Cdw12 = packed struct(u32) {
        nlb_zero_based: u16,
        reserved_16: u4 = 0,
        directive_type: u4 = 0,
        storage_tag_check: u1 = 0,
        reserved_25: u1 = 0,
        prinfo: u4 = 0,
        force_unit_access: u1,
        limited_retry: u1,

        pub fn fromRaw(value: u32) Cdw12 {
            return @bitCast(value);
        }

        pub fn raw(self: Cdw12) u32 {
            return @bitCast(self);
        }

        comptime {
            std.debug.assert(@bitSizeOf(Cdw12) == 32);
            std.debug.assert(@sizeOf(Cdw12) == @sizeOf(u32));
        }
    };

    pub const Params = struct {
        namespace_id: Nsid,
        starting_lba: u64,
        logical_block_count: u16,
        data_pointers: DataPointers,
        limited_retry: bool = false,
        force_unit_access: bool = false,
        metadata_pointer: u64 = 0,
    };

    pub fn encode(sq: *queue.SubmissionQueue, params: Params) Error!queue.Handle {
        if (params.namespace_id.isNone() or params.namespace_id.isBroadcast()) {
            return error.InvalidNamespaceIdentifier;
        }
        if (params.logical_block_count == 0) return error.InvalidLogicalBlockCount;

        const reservation = try sq.reserveSlot();
        errdefer sq.releaseReservation(reservation);

        Sqe.init(reservation.slot, .{
            .opcode = @intFromEnum(Opcode.write),
            .command_id = reservation.command_id,
            .namespace_id = params.namespace_id,
            .metadata_pointer = params.metadata_pointer,
            .data_pointers = params.data_pointers,
            .cdw10 = @truncate(params.starting_lba),
            .cdw11 = @truncate(params.starting_lba >> 32),
            .cdw12 = (Cdw12{
                .nlb_zero_based = params.logical_block_count - 1,
                .force_unit_access = @intFromBool(params.force_unit_access),
                .limited_retry = @intFromBool(params.limited_retry),
            }).raw(),
        });

        return sq.stage(reservation);
    }
};

pub const Flush = struct {
    pub const Params = struct {
        namespace_id: Nsid,
    };

    pub fn encode(sq: *queue.SubmissionQueue, params: Params) Error!queue.Handle {
        if (params.namespace_id.isNone()) return error.InvalidNamespaceIdentifier;

        const reservation = try sq.reserveSlot();
        errdefer sq.releaseReservation(reservation);

        Sqe.init(reservation.slot, .{
            .opcode = @intFromEnum(Opcode.flush),
            .command_id = reservation.command_id,
            .namespace_id = params.namespace_id,
        });

        return sq.stage(reservation);
    }
};
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `[znvme]` `Read.encode` | never | never | O(1) | caller-serialized per SQ | ordered by caller `sq.flush()` (SQ tail doorbell) | `queue.ReserveError`, `InvalidNamespaceIdentifier`, `InvalidLogicalBlockCount` |
| `[znvme]` `Write.encode` | never | never | O(1) | caller-serialized per SQ | ordered by caller `sq.flush()` | `queue.ReserveError`, `InvalidNamespaceIdentifier`, `InvalidLogicalBlockCount` |
| `[znvme]` `Flush.encode` | never | never | O(1) | caller-serialized per SQ | ordered by caller `sq.flush()` | `queue.ReserveError`, `InvalidNamespaceIdentifier` |
| `[znvme]` `Read.Cdw12.fromRaw` / `.raw` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `Write.Cdw12.fromRaw` / `.raw` | never | never | O(1) | value type | none | infallible |

## Validation phases

`[znvme]` Per `docs/specs/architecture.md` §"Validation phases":

- `[znvme]` **Compile time.** `@bitSizeOf` and `@sizeOf` assertions on `Read.Cdw12` and `Write.Cdw12`.
- `[znvme]` **Public validation.**
  - `[znvme]` `Read.encode` and `Write.encode` reject `Nsid.none` and `Nsid.broadcast` with `error.InvalidNamespaceIdentifier`.
  - `[znvme]` `Read.encode` and `Write.encode` reject `logical_block_count == 0` with `error.InvalidLogicalBlockCount`.
  - `[znvme]` `Flush.encode` rejects `Nsid.none` with `error.InvalidNamespaceIdentifier`.
- `[znvme]` **Assertions.** None inside the NVM builders — every runtime-input value is validated through typed errors above. Reservation-slot invariants are asserted inside `controller/queue.md`.

## Example usage

`[znvme]` Illustrative shape only; not part of the approved API. `docs/specs/examples/read-namespace.md` owns the full sequence.

```zig
const std = @import("std");

const nvme = @import("nvme");
const stdx = @import("stdx");

const nvm = nvme.commands.nvm;

const page_size = try nvme.core.prp.PageSize.fromBytes(4096);

var backoff = stdx.time.Backoff.init(nvme.controller.init.default_backoff_policy);
const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(500));

// Read one LBA range through the caller-owned I/O queue pair.
const payload = try stdx.dma.Buffer(u8).init(&read_backing, read_dma_addr);
const dptr = try nvme.core.prp.DataPointers.fromContiguous(.{
    .payload = payload,
    .page_size = page_size,
});

const read_handle = try nvm.Read.encode(io.sq(), .{
    .namespace_id = target_nsid,
    .starting_lba = 0,
    .logical_block_count = @intCast(block_count),
    .data_pointers = dptr,
});
try io.sq().flush();
const read_completion = try io.pollOne(deadline, &backoff);
std.debug.assert(read_completion.cid.raw() == read_handle.command_id.raw());
if (!read_completion.statusIsSuccess()) return error.ReadFailed;

// Force durability before returning to the boot loader.
_ = try nvm.Flush.encode(io.sq(), .{ .namespace_id = target_nsid });
try io.sq().flush();
const flush_completion = try io.pollOne(deadline, &backoff);
if (!flush_completion.statusIsSuccess()) return error.FlushFailed;
```

## Required tests `[znvme]`

`[znvme]` Test file `test/commands/nvm_test.zig`. Naming per `docs/guidelines/testing.md`.

`[znvme]` Test substrate: a caller-owned `SubmissionQueue` with a scratch SQ ring, a scratch MMIO byte buffer for the doorbell, and `Sqe` accessors on `*const Sqe` verifying encoded slots. No CQE completion is needed at this level.

### Read

- `[znvme]` `unit: nvm read encodes opcode 02h target NSID and SLBA in CDW10 CDW11`.
- `[znvme]` `unit: nvm read encodes CDW12 NLB zero-based and LR FUA cleared on default`.
- `[znvme]` `unit: nvm read honors limited_retry true and force_unit_access true`.
- `[znvme]` `unit: nvm read encodes DPTR from Params.data_pointers`.
- `[znvme]` `unit: nvm read passes through metadata_pointer to Sqe.mptr`.
- `[znvme]` `unit: nvm read rejects Nsid.none`.
- `[znvme]` `unit: nvm read rejects Nsid.broadcast`.
- `[znvme]` `unit: nvm read rejects logical_block_count 0 with InvalidLogicalBlockCount`.
- `[znvme]` `unit: nvm read encodes SLBA high half of a 64-bit LBA above 2^32`.
- `[znvme]` `unit: nvm Read.Cdw12 fromRaw round-trips through raw`.

### Write

- `[znvme]` `unit: nvm write encodes opcode 01h target NSID and SLBA in CDW10 CDW11`.
- `[znvme]` `unit: nvm write encodes CDW12 NLB zero-based and LR FUA cleared on default with DTYPE zero`.
- `[znvme]` `unit: nvm write honors limited_retry true and force_unit_access true`.
- `[znvme]` `unit: nvm write encodes DPTR from Params.data_pointers`.
- `[znvme]` `unit: nvm write passes through metadata_pointer to Sqe.mptr`.
- `[znvme]` `unit: nvm write rejects Nsid.none`.
- `[znvme]` `unit: nvm write rejects Nsid.broadcast`.
- `[znvme]` `unit: nvm write rejects logical_block_count 0 with InvalidLogicalBlockCount`.
- `[znvme]` `unit: nvm Write.Cdw12 fromRaw round-trips through raw with DTYPE preserved`.

### Flush

- `[znvme]` `unit: nvm flush encodes opcode 00h target NSID and every other lane zero`.
- `[znvme]` `unit: nvm flush accepts Nsid.broadcast`.
- `[znvme]` `unit: nvm flush rejects Nsid.none`.

### Roundtrips

- `[znvme]` `roundtrip: nvm read encoded slot decodes through Sqe accessors for opcode nsid cdw10 cdw11 cdw12 dptr`.
- `[znvme]` `roundtrip: nvm write encoded slot decodes through Sqe accessors for opcode nsid cdw10 cdw11 cdw12 dptr`.
- `[znvme]` `roundtrip: nvm flush encoded slot decodes through Sqe accessors for opcode and NSID with cdw10..cdw15 zero`.

## Open questions

_(none)_
