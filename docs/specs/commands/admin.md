# Commands admin

Status: Approved.

`admin` owns the typed builder families for the admin opcodes the boot path issues: Identify (`06h`), Create/Delete I/O Submission Queue (`01h` / `00h`), Create/Delete I/O Completion Queue (`05h` / `04h`), Set Features (`09h`), Get Features (`0Ah`), and Abort (`08h`). Each builder reserves an SQ slot via `SubmissionQueue.reserveSlot`, stamps the SQE in place through `Sqe.init(reservation.slot, .{ ... })`, and stages — a one-call flow that returns a `queue.Handle` the caller pairs with later completions. The caller rings the SQ tail doorbell with `try sq.flush()` when a batch (or a single command) is ready to publish.

`admin` also owns the response decoders for Set Features and Get Features (Number of Queues), which extract the allocated queue counts from completion `CDW0`.

`admin` does not decode Identify response bytes — that lives in `docs/specs/identify/*.md`.

## Owned scope

This spec owns:

- `Opcode`, a non-exhaustive `enum(u8)` for admin opcodes;
- `Cns`, a non-exhaustive `enum(u8)` for Identify CNS values;
- `Fid`, a non-exhaustive `enum(u8)` for Feature Identifier values;
- `FeatureSelect`, a non-exhaustive `enum(u3)` for Get Features SEL values;
- `Identify.controller`, `Identify.namespace`, `Identify.activeNamespaceList` — the three CNS variants in the first-slice scope, each with its NSID admissibility;
- `CreateIoSubmissionQueue.encode`, `CreateIoCompletionQueue.encode`, `DeleteIoSubmissionQueue.encode`, `DeleteIoCompletionQueue.encode` — I/O queue management;
- `Abort.encode`;
- `NumberOfQueues.set`, `NumberOfQueues.get`, and `NumberOfQueues.ResponseDw0` — the only Feature Identifier owned by this spec;
- per-command `Cdw10` / `Cdw11` / `Cdw12` packed structs with `@bitSizeOf` and `@sizeOf` assertions;
- broadcast- and reserved-identifier validation at builder scope.

## Deferred scope and non-goals

This spec does not own:

- admin opcodes outside the boot path: Async Event Request (`0Ch`), Get Log Page (`02h`), Namespace Management (`0Dh`), Namespace Attachment (`15h`), Firmware Commit (`10h`), Firmware Image Download (`11h`), Device Self-test (`14h`), Directive Send/Receive (`19h`/`1Ah`), Virtualization Management (`1Ch`), NVMe-MI Send/Receive (`1Dh`/`1Eh`), Capacity Management (`20h`), Lockdown (`24h`), Doorbell Buffer Config (`7Ch`), Format NVM (`80h`), Security Send/Receive (`81h`/`82h`), Sanitize (`84h`), Get LBA Status (`86h`), Keep Alive (`18h`), Fabrics (`7Fh`), vendor-specific (`C0h`..`FFh`);
- Feature Identifiers other than Number of Queues — Arbitration, Power Management, Temperature Threshold, Volatile Write Cache, Interrupt Coalescing, Interrupt Vector Configuration, Write Atomicity Normal, Asynchronous Event Configuration, Autonomous Power State Transition, Host Memory Buffer, Timestamp, Keep Alive Timer, Host Controlled Thermal Management, Non-Operational Power State Config, Read Recovery Level Config, Predictable Latency Mode Config, Predictable Latency Mode Window, LBA Status Information Report Interval, Host Behavior Support, Sanitize Config, Endurance Group Event Configuration, I/O Command Set Profile, Spinup Control;
- Set Features `save` and Get Features `select != current` — first-slice builders write `SV = 0` and `SEL = 0` unconditionally;
- Identify CNS values outside `00h`/`01h`/`02h` — CSI-parameterized CNS variants (`05h`, `06h`, `07h`, `1Bh`, `1Ch`), NVM Set list (`04h`), namespace attachment list (`12h`), and every I/O Command Set specific CNS are deferred until an approved spec claims them;
- UUID Index encoding in CDW14 — reserved zero in the first slice;
- fused-operation composition;
- Metadata Pointer encoding — admin commands in the first slice use `MPTR = 0`;
- Identify response byte parsing — `docs/specs/identify/controller.md`, `docs/specs/identify/namespace.md` (both `IdentifyNamespace` for CNS 00h and `List` for CNS 02h);
- completion polling — `SubmissionQueue.stage` returns a `queue.Handle`; the caller flushes and polls through the owning `Pair(Backend)`;
- I/O queue creation policy (how many, which QIDs, negotiation logic) — the caller composes the sequence; `docs/specs/examples/controller-bringup.md` illustrates the full flow;
- outstanding-QID tracking — this spec does not know whether a Create I/O SQ/CQ command references an already-created queue;
- Abort admissibility — per NVMe, aborting a nonexistent CID is a silent no-op with success status; this spec does not pre-filter;
- SGL descriptors and the SGL PSDT selection;
- big-endian host or target compatibility.

## `stdx` composition

No direct `stdx` surface. Every stdx primitive reaches admin builders through znvme-owned types.

Composed through znvme types:

- `controller.queue.SubmissionQueue` — `reserveSlot`, `stage`, `flush`, `releaseReservation`;
- `controller.queue.Handle` — returned from `stage`, propagated by every builder;
- `controller.queue.ReserveError` — merged into `admin.Error`;
- `commands.sqe.Sqe` — SQE authorship in place via `Sqe.init(reservation.slot, params)`;
- `core.ids.Cid`, `core.ids.Nsid`, `core.ids.Qid` — identifier parameters and broadcast/reserved predicates;
- `core.prp.DataPointers` — DPTR values for Identify, Create I/O CQ/SQ.

## NVMe wire encodings

### Identify — opcode `06h`

`[nvme]` Per NVMe Base Specification 2.0 §5.17:

| CDW | Bits | Field | Meaning |
| --- | ---: | --- | --- |
| CDW10 | `07:00` | `CNS` | Controller/Namespace Structure |
| CDW10 | `15:08` | reserved |  |
| CDW10 | `31:16` | `CNTID` | Controller Identifier |
| CDW11 | `15:00` | CNS-specific |  |
| CDW11 | `23:16` | `CSI` | Command Set Identifier |
| CDW11 | `31:24` | reserved |  |
| CDW14 | `07:00` | UUID Index |  |

`[nvme]` CNS values used by the first slice:

| CNS | Meaning | NSID |
| ---: | --- | --- |
| `00h` | Identify Namespace | target namespace `1..0xFFFF_FFFE`; broadcast forbidden |
| `01h` | Identify Controller | cleared to `0` |
| `02h` | Active Namespace ID list | starting NSID; `0` returns list starting at the first allocated NSID |

`[nvme]` Identify transfers a 4 KiB response buffer through DPTR.

The builder encodes DPTR through `core.prp.DataPointers`.

### Create I/O Submission Queue — opcode `01h`

`[nvme]` Per NVMe Base Specification 2.0 §5.5:

| CDW | Bits | Field | Meaning |
| --- | ---: | --- | --- |
| CDW10 | `15:00` | `QID` | I/O SQ identifier |
| CDW10 | `31:16` | `QSIZE` | Queue size, zero-based |
| CDW11 | `00` | `PC` | Physically Contiguous |
| CDW11 | `02:01` | `QPRIO` | Queue Priority |
| CDW11 | `15:03` | reserved |  |
| CDW11 | `31:16` | `CQID` | Completion Queue Identifier |
| CDW12 | `15:00` | `NVMSETID` | NVM Set Identifier |
| CDW12 | `31:16` | reserved |  |

`[nvme]` PRP1: SQ base DMA address, memory-page-aligned per NVMe §3.5. NSID cleared to `0`.

First-slice `PC` is always `1` (physically contiguous). The caller supplies contiguous DMA memory through `core.prp.DataPointers`.

### Create I/O Completion Queue — opcode `05h`

`[nvme]` Per NVMe Base Specification 2.0 §5.4:

| CDW | Bits | Field | Meaning |
| --- | ---: | --- | --- |
| CDW10 | `15:00` | `QID` | I/O CQ identifier |
| CDW10 | `31:16` | `QSIZE` | Queue size, zero-based |
| CDW11 | `00` | `PC` | Physically Contiguous |
| CDW11 | `01` | `IEN` | Interrupts Enabled |
| CDW11 | `15:02` | reserved |  |
| CDW11 | `31:16` | `IV` | Interrupt Vector |

`[nvme]` PRP1: CQ base DMA address, memory-page-aligned. NSID cleared to `0`.

First-slice `IEN` defaults to `0` (polled completion path). `IV` is caller-supplied but is ignored by the controller when `IEN = 0`. The caller wraps contiguous, page-aligned CQ memory through `core.prp.IoQueueBase.fromContiguous(buffer, page_size)`, and the builder writes `PRP1 = base.prp1` with `PRP2 = 0`.

### Delete I/O Submission Queue / Delete I/O Completion Queue — opcodes `00h` / `04h`

`[nvme]` Per NVMe Base Specification 2.0 §5.6 and §5.7:

| CDW | Bits | Field |
| --- | ---: | --- |
| CDW10 | `15:00` | `QID` |
| CDW10 | `31:16` | reserved |

`[nvme]` NSID cleared to `0`. No data transfer.

`[nvme]` NVMe requires the associated CQ to remain alive while any SQ references it; deleting a CQ that still has an SQ attached returns a command-specific error status.

This is a device-side check; this spec does not pre-filter.

### Abort — opcode `08h`

`[nvme]` Per NVMe Base Specification 2.0 §5.1:

| CDW | Bits | Field |
| --- | ---: | --- |
| CDW10 | `15:00` | `SQID` |
| CDW10 | `31:16` | `CID` |

`[nvme]` NSID cleared to `0`. No data transfer.

`[nvme]` Aborting a command that has already completed or was never issued is a silent no-op with generic success status.

### Set Features / Get Features — Number of Queues (`FID 07h`)

`[nvme]` Per NVMe Base Specification 2.0 §5.27 and §5.15:

**Set Features CDW10:**

| Bits | Field |
| ---: | --- |
| `07:00` | `FID` |
| `30:08` | reserved |
| `31` | `SV` (Save) |

**Get Features CDW10:**

| Bits | Field |
| ---: | --- |
| `07:00` | `FID` |
| `10:08` | `SEL` (Select) |
| `31:11` | reserved |

`[nvme]` `SEL` values: `000b` current, `001b` default, `010b` saved, `011b` supported capabilities, `100b`..`111b` reserved.

**Set Features CDW11 (Number of Queues):**

| Bits | Field |
| ---: | --- |
| `15:00` | `NSQR` — Number of I/O SQ requested, zero-based |
| `31:16` | `NCQR` — Number of I/O CQ requested, zero-based |

**Response CDW0 (Number of Queues):**

| Bits | Field |
| ---: | --- |
| `15:00` | `NSQA` — Number of I/O SQ allocated, zero-based |
| `31:16` | `NCQA` — Number of I/O CQ allocated, zero-based |

`[nvme]` NSID cleared to `0`. No data transfer.

First-slice Set Features writes `SV = 0` (no persistence). First-slice Get Features writes `SEL = 0` (current). The one-based public API on `NumberOfQueues.Requested` / `Allocated` maps to the wire's zero-based encoding at the builder boundary — a caller who asks for one submission queue writes `NSQR = 0` on the wire and reads `NSQA = 0` back as one allocated queue.

## znvme behavior

Every builder is a struct with static factory methods. No stateful builder value persists across calls; the naming pattern is `Identify.controller(sq, params)`, `CreateIoSubmissionQueue.encode(sq, params)`, `NumberOfQueues.set(sq, params)`. The `SubmissionQueue` allocates every CID from its bounded pool; no `Params` struct carries a `command_id` field — callers read `handle.command_id` off the returned `queue.Handle`.

Every factory:

1. calls `sq.reserveSlot()`;
2. sets up an `errdefer sq.releaseReservation(reservation)` so any failure between reservation and `stage` releases the CID and leaves the SQ tail untouched;
3. composes a single `Sqe.Init` value carrying opcode, `reservation.command_id`, `namespace_id`, any `data_pointers`, and the per-command `cdw10`..`cdw15` lanes;
4. calls `Sqe.init(reservation.slot, sqe_init)` to stamp the reserved slot in place — every unspecified `Init` field is zero, so no lane inherits stale bytes;
5. returns `sq.stage(reservation)` — the returned `queue.Handle` carries the reservation-assigned CID, which callers pair with later completions. `stage` is infallible; the SQE is in the ring but not yet visible to the controller. The caller rings the SQ tail doorbell with `try sq.flush()` when a batch (or a single command) is ready to publish.

Identifier admissibility:

- `Identify.controller` writes `NSID = 0`; the caller does not supply an NSID.
- `Identify.namespace` rejects `Nsid.none` and `Nsid.broadcast` with `error.InvalidNamespaceIdentifier`. Broadcast NSID is legal on some Identify CNS values, but none of the first-slice CNS variants (`00h`) accept it.
- `Identify.activeNamespaceList` accepts any `Nsid` value — `Nsid.none` (`0`) is the conventional starting NSID.
- `CreateIoSubmissionQueue`, `CreateIoCompletionQueue`, `DeleteIoSubmissionQueue`, and `DeleteIoCompletionQueue` reject `Qid.admin` and `Qid.reserved_max` on `qid` with `error.InvalidQueueIdentifier`. `CreateIoSubmissionQueue` additionally rejects `Qid.admin` and `Qid.reserved_max` on `cqid`: the admin CQ is bound to the admin SQ and never associates with an I/O SQ.
- `Abort` rejects `Qid.reserved_max` on `sqid`; `Qid.admin` is accepted because callers can legally abort admin commands.
- `CreateIoCompletionQueue.Params.base` and `CreateIoSubmissionQueue.Params.base` are `core.prp.IoQueueBase`. The builder writes `PRP1 = base.prp1` and `PRP2 = 0`. Empty or non-page-aligned queue-base buffers are rejected by `IoQueueBase.fromContiguous` before submission and never reach the wire.

Queue-size encoding: `CreateIoSubmissionQueue.Params.queue_size` and `CreateIoCompletionQueue.Params.queue_size` are one-based `u16` values (the actual number of entries). The builder writes `qsize_zero_based = queue_size - 1` to the wire. `queue_size == 0` and `queue_size == 1` are rejected with `error.InvalidQueueSize`; NVMe requires at least two entries for an I/O queue.

Queue-count encoding: `NumberOfQueues.Requested.submission_queues` and `Requested.completion_queues` are one-based `u16` values. The builder writes `nsqr_zero_based = submission_queues - 1` and `ncqr_zero_based = completion_queues - 1` to the wire. `submission_queues == 0` or `completion_queues == 0` are rejected with `error.InvalidQueueCount`; NVMe requires at least one queue per direction.

Response decoding: `NumberOfQueues.ResponseDw0.fromRaw(u32)` converts the completion's `dw0` into a typed value; `.allocated()` returns a one-based `Allocated` struct. Callers write `NumberOfQueues.ResponseDw0.fromRaw(completion.dw0).allocated()`. This mirrors every other decoder in the repo (`CompletionStatus.from(u16)`, `Sqe.Cdw0.fromRaw(u32)`).

Reserved lanes: `Sqe.init` overwrites every field of the SQE; `Sqe.Init` fields default to zero so the per-command builder names only the lanes it needs. Reserved bits inside each `Cdw10` / `Cdw11` / `Cdw12` packed struct carry `= 0` defaults so their `.raw()` output zeroes them explicitly.

Symmetric CDW decoding: every admin `Cdw*` / `Dw*` packed struct exposes a `fromRaw(u32) Self` decoder alongside its `raw() u32` encoder. Host builders compose values through the field constructors and call `raw()` at the SQE boundary; device emulators decode host CDW writes through `fromRaw(sqe_cdwN)` and then read fields as typed values. Both directions bit-cast; the packed-struct layout is the single source of truth. `NumberOfQueues.ResponseDw0.fromRaw` follows the same pattern for the device-authored response lane.

## Approved API

```zig
// src/commands/admin.zig
//! NVMe admin command builders. Spec: docs/specs/commands/admin.md.

const std = @import("std");

const ids = @import("../core/ids.zig");
const queue = @import("../controller/queue.zig");

const Cid = ids.Cid;
const DataPointers = @import("../core/prp.zig").DataPointers;
const IoQueueBase = @import("../core/prp.zig").IoQueueBase;
const Nsid = ids.Nsid;
const Qid = ids.Qid;
const Sqe = @import("sqe.zig").Sqe;

pub const Opcode = enum(u8) {
    delete_io_sq = 0x00,
    create_io_sq = 0x01,
    delete_io_cq = 0x04,
    create_io_cq = 0x05,
    identify = 0x06,
    abort = 0x08,
    set_features = 0x09,
    get_features = 0x0a,
    _,
};

pub const Cns = enum(u8) {
    namespace = 0x00,
    controller = 0x01,
    active_namespace_id_list = 0x02,
    _,
};

pub const Fid = enum(u8) {
    number_of_queues = 0x07,
    _,
};

pub const FeatureSelect = enum(u3) {
    current = 0b000,
    default = 0b001,
    saved = 0b010,
    supported_capabilities = 0b011,
    _,
};

pub const Error = error{
    InvalidNamespaceIdentifier,
    InvalidQueueIdentifier,
    InvalidQueueSize,
    InvalidQueueCount,
} || queue.ReserveError;

pub const DeleteQueueCdw10 = packed struct(u32) {
    qid: u16,
    reserved_16: u16 = 0,

    pub fn fromRaw(value: u32) DeleteQueueCdw10 {
        return @bitCast(value);
    }

    pub fn raw(self: DeleteQueueCdw10) u32 {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert(@bitSizeOf(DeleteQueueCdw10) == 32);
        std.debug.assert(@sizeOf(DeleteQueueCdw10) == @sizeOf(u32));
    }
};

pub const Identify = struct {
    pub const Cdw10 = packed struct(u32) {
        cns: Cns,
        reserved_8: u8 = 0,
        controller_id: u16 = 0,

        pub fn fromRaw(value: u32) Cdw10 {
            return @bitCast(value);
        }

        pub fn raw(self: Cdw10) u32 {
            return @bitCast(self);
        }

        comptime {
            std.debug.assert(@bitSizeOf(Cdw10) == 32);
            std.debug.assert(@sizeOf(Cdw10) == @sizeOf(u32));
        }
    };

    pub const ControllerParams = struct {
        dptr: DataPointers,
    };

    pub const NamespaceParams = struct {
        namespace_id: Nsid,
        dptr: DataPointers,
    };

    pub const ActiveListParams = struct {
        starting_namespace_id: Nsid = .none,
        dptr: DataPointers,
    };

    pub fn controller(sq: *queue.SubmissionQueue, params: ControllerParams) Error!queue.Handle {
        return encode(sq, .{
            .cns = .controller,
            .namespace_id = .none,
            .dptr = params.dptr,
        });
    }

    pub fn namespace(sq: *queue.SubmissionQueue, params: NamespaceParams) Error!queue.Handle {
        if (params.namespace_id.isNone() or params.namespace_id.isBroadcast()) {
            return error.InvalidNamespaceIdentifier;
        }
        return encode(sq, .{
            .cns = .namespace,
            .namespace_id = params.namespace_id,
            .dptr = params.dptr,
        });
    }

    pub fn activeNamespaceList(sq: *queue.SubmissionQueue, params: ActiveListParams) Error!queue.Handle {
        return encode(sq, .{
            .cns = .active_namespace_id_list,
            .namespace_id = params.starting_namespace_id,
            .dptr = params.dptr,
        });
    }

    const Encoded = struct {
        cns: Cns,
        namespace_id: Nsid,
        dptr: DataPointers,
    };

    fn encode(sq: *queue.SubmissionQueue, params: Encoded) Error!queue.Handle {
        const reservation = try sq.reserveSlot();
        errdefer sq.releaseReservation(reservation);

        Sqe.init(reservation.slot, .{
            .opcode = @intFromEnum(Opcode.identify),
            .command_id = reservation.command_id,
            .namespace_id = params.namespace_id,
            .data_pointers = params.dptr,
            .cdw10 = (Cdw10{ .cns = params.cns }).raw(),
        });

        return sq.stage(reservation);
    }
};

pub const CreateIoCompletionQueue = struct {
    pub const Cdw10 = packed struct(u32) {
        qid: u16,
        qsize_zero_based: u16,

        pub fn fromRaw(value: u32) Cdw10 {
            return @bitCast(value);
        }

        pub fn raw(self: Cdw10) u32 {
            return @bitCast(self);
        }

        comptime {
            std.debug.assert(@bitSizeOf(Cdw10) == 32);
            std.debug.assert(@sizeOf(Cdw10) == @sizeOf(u32));
        }
    };

    pub const Cdw11 = packed struct(u32) {
        physically_contiguous: u1,
        interrupts_enabled: u1,
        reserved_2: u14 = 0,
        interrupt_vector: u16,

        pub fn fromRaw(value: u32) Cdw11 {
            return @bitCast(value);
        }

        pub fn raw(self: Cdw11) u32 {
            return @bitCast(self);
        }

        comptime {
            std.debug.assert(@bitSizeOf(Cdw11) == 32);
            std.debug.assert(@sizeOf(Cdw11) == @sizeOf(u32));
        }
    };

    pub const Params = struct {
        qid: Qid,
        queue_size: u16,
        base: IoQueueBase,
        interrupts_enabled: bool = false,
        interrupt_vector: u16 = 0,
    };

    pub fn encode(sq: *queue.SubmissionQueue, params: Params) Error!queue.Handle {
        if (params.qid.isAdmin() or params.qid.isReserved()) {
            return error.InvalidQueueIdentifier;
        }
        if (params.queue_size < 2) return error.InvalidQueueSize;

        const reservation = try sq.reserveSlot();
        errdefer sq.releaseReservation(reservation);

        Sqe.init(reservation.slot, .{
            .opcode = @intFromEnum(Opcode.create_io_cq),
            .command_id = reservation.command_id,
            .namespace_id = .none,
            .data_pointers = .{ .prp1 = params.base.prp1, .prp2 = .zero },
            .cdw10 = (Cdw10{
                .qid = params.qid.raw(),
                .qsize_zero_based = params.queue_size - 1,
            }).raw(),
            .cdw11 = (Cdw11{
                .physically_contiguous = 1,
                .interrupts_enabled = @intFromBool(params.interrupts_enabled),
                .interrupt_vector = params.interrupt_vector,
            }).raw(),
        });

        return sq.stage(reservation);
    }
};

pub const CreateIoSubmissionQueue = struct {
    pub const Priority = enum(u2) {
        urgent = 0b00,
        high = 0b01,
        medium = 0b10,
        low = 0b11,
    };

    pub const Cdw10 = packed struct(u32) {
        qid: u16,
        qsize_zero_based: u16,

        pub fn fromRaw(value: u32) Cdw10 {
            return @bitCast(value);
        }

        pub fn raw(self: Cdw10) u32 {
            return @bitCast(self);
        }

        comptime {
            std.debug.assert(@bitSizeOf(Cdw10) == 32);
            std.debug.assert(@sizeOf(Cdw10) == @sizeOf(u32));
        }
    };

    pub const Cdw11 = packed struct(u32) {
        physically_contiguous: u1,
        priority: Priority,
        reserved_3: u13 = 0,
        completion_queue_id: u16,

        pub fn fromRaw(value: u32) Cdw11 {
            return @bitCast(value);
        }

        pub fn raw(self: Cdw11) u32 {
            return @bitCast(self);
        }

        comptime {
            std.debug.assert(@bitSizeOf(Cdw11) == 32);
            std.debug.assert(@sizeOf(Cdw11) == @sizeOf(u32));
        }
    };

    pub const Cdw12 = packed struct(u32) {
        nvm_set_id: u16,
        reserved_16: u16 = 0,

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
        qid: Qid,
        queue_size: u16,
        base: IoQueueBase,
        cqid: Qid,
        priority: Priority = .medium,
        nvm_set_id: u16 = 0,
    };

    pub fn encode(sq: *queue.SubmissionQueue, params: Params) Error!queue.Handle {
        if (params.qid.isAdmin() or params.qid.isReserved()) {
            return error.InvalidQueueIdentifier;
        }
        if (params.cqid.isAdmin() or params.cqid.isReserved()) {
            return error.InvalidQueueIdentifier;
        }
        if (params.queue_size < 2) return error.InvalidQueueSize;

        const reservation = try sq.reserveSlot();
        errdefer sq.releaseReservation(reservation);

        Sqe.init(reservation.slot, .{
            .opcode = @intFromEnum(Opcode.create_io_sq),
            .command_id = reservation.command_id,
            .namespace_id = .none,
            .data_pointers = .{ .prp1 = params.base.prp1, .prp2 = .zero },
            .cdw10 = (Cdw10{
                .qid = params.qid.raw(),
                .qsize_zero_based = params.queue_size - 1,
            }).raw(),
            .cdw11 = (Cdw11{
                .physically_contiguous = 1,
                .priority = params.priority,
                .completion_queue_id = params.cqid.raw(),
            }).raw(),
            .cdw12 = (Cdw12{ .nvm_set_id = params.nvm_set_id }).raw(),
        });

        return sq.stage(reservation);
    }
};

pub const DeleteIoSubmissionQueue = struct {
    pub const Params = struct {
        qid: Qid,
    };

    pub fn encode(sq: *queue.SubmissionQueue, params: Params) Error!queue.Handle {
        return encodeDelete(sq, .delete_io_sq, params.qid);
    }
};

pub const DeleteIoCompletionQueue = struct {
    pub const Params = struct {
        qid: Qid,
    };

    pub fn encode(sq: *queue.SubmissionQueue, params: Params) Error!queue.Handle {
        return encodeDelete(sq, .delete_io_cq, params.qid);
    }
};

fn encodeDelete(
    sq: *queue.SubmissionQueue,
    opcode: Opcode,
    qid: Qid,
) Error!queue.Handle {
    if (qid.isAdmin() or qid.isReserved()) return error.InvalidQueueIdentifier;

    const reservation = try sq.reserveSlot();
    errdefer sq.releaseReservation(reservation);

    Sqe.init(reservation.slot, .{
        .opcode = @intFromEnum(opcode),
        .command_id = reservation.command_id,
        .namespace_id = .none,
        .cdw10 = (DeleteQueueCdw10{ .qid = qid.raw() }).raw(),
    });

    return sq.stage(reservation);
}

pub const Abort = struct {
    pub const Cdw10 = packed struct(u32) {
        sqid: u16,
        cid: u16,

        pub fn fromRaw(value: u32) Cdw10 {
            return @bitCast(value);
        }

        pub fn raw(self: Cdw10) u32 {
            return @bitCast(self);
        }

        comptime {
            std.debug.assert(@bitSizeOf(Cdw10) == 32);
            std.debug.assert(@sizeOf(Cdw10) == @sizeOf(u32));
        }
    };

    pub const Params = struct {
        sqid: Qid,
        cid: Cid,
    };

    pub fn encode(sq: *queue.SubmissionQueue, params: Params) Error!queue.Handle {
        if (params.sqid.isReserved()) return error.InvalidQueueIdentifier;

        const reservation = try sq.reserveSlot();
        errdefer sq.releaseReservation(reservation);

        Sqe.init(reservation.slot, .{
            .opcode = @intFromEnum(Opcode.abort),
            .command_id = reservation.command_id,
            .namespace_id = .none,
            .cdw10 = (Cdw10{
                .sqid = params.sqid.raw(),
                .cid = params.cid.raw(),
            }).raw(),
        });

        return sq.stage(reservation);
    }
};

pub const NumberOfQueues = struct {
    pub const Requested = struct {
        submission_queues: u16,
        completion_queues: u16,
    };

    pub const Allocated = struct {
        submission_queues: u16,
        completion_queues: u16,
    };

    pub const SetCdw10 = packed struct(u32) {
        fid: Fid,
        reserved_8: u23 = 0,
        save: u1 = 0,

        pub fn fromRaw(value: u32) SetCdw10 {
            return @bitCast(value);
        }

        pub fn raw(self: SetCdw10) u32 {
            return @bitCast(self);
        }

        comptime {
            std.debug.assert(@bitSizeOf(SetCdw10) == 32);
            std.debug.assert(@sizeOf(SetCdw10) == @sizeOf(u32));
        }
    };

    pub const GetCdw10 = packed struct(u32) {
        fid: Fid,
        select: FeatureSelect = .current,
        reserved_11: u21 = 0,

        pub fn fromRaw(value: u32) GetCdw10 {
            return @bitCast(value);
        }

        pub fn raw(self: GetCdw10) u32 {
            return @bitCast(self);
        }

        comptime {
            std.debug.assert(@bitSizeOf(GetCdw10) == 32);
            std.debug.assert(@sizeOf(GetCdw10) == @sizeOf(u32));
        }
    };

    pub const RequestCdw11 = packed struct(u32) {
        nsqr_zero_based: u16,
        ncqr_zero_based: u16,

        pub fn fromRaw(value: u32) RequestCdw11 {
            return @bitCast(value);
        }

        pub fn raw(self: RequestCdw11) u32 {
            return @bitCast(self);
        }

        comptime {
            std.debug.assert(@bitSizeOf(RequestCdw11) == 32);
            std.debug.assert(@sizeOf(RequestCdw11) == @sizeOf(u32));
        }
    };

    pub const ResponseDw0 = packed struct(u32) {
        nsqa_zero_based: u16,
        ncqa_zero_based: u16,

        pub fn fromRaw(value: u32) ResponseDw0 {
            return @bitCast(value);
        }

        pub fn raw(self: ResponseDw0) u32 {
            return @bitCast(self);
        }

        pub fn allocated(self: ResponseDw0) Allocated {
            return .{
                .submission_queues = @as(u16, self.nsqa_zero_based) + 1,
                .completion_queues = @as(u16, self.ncqa_zero_based) + 1,
            };
        }

        comptime {
            std.debug.assert(@bitSizeOf(ResponseDw0) == 32);
            std.debug.assert(@sizeOf(ResponseDw0) == @sizeOf(u32));
        }
    };

    pub const SetParams = struct {
        requested: Requested,
    };

    pub fn set(sq: *queue.SubmissionQueue, params: SetParams) Error!queue.Handle {
        if (params.requested.submission_queues == 0) return error.InvalidQueueCount;
        if (params.requested.completion_queues == 0) return error.InvalidQueueCount;

        const reservation = try sq.reserveSlot();
        errdefer sq.releaseReservation(reservation);

        Sqe.init(reservation.slot, .{
            .opcode = @intFromEnum(Opcode.set_features),
            .command_id = reservation.command_id,
            .namespace_id = .none,
            .cdw10 = (SetCdw10{ .fid = .number_of_queues }).raw(),
            .cdw11 = (RequestCdw11{
                .nsqr_zero_based = params.requested.submission_queues - 1,
                .ncqr_zero_based = params.requested.completion_queues - 1,
            }).raw(),
        });

        return sq.stage(reservation);
    }

    pub fn get(sq: *queue.SubmissionQueue) Error!queue.Handle {
        const reservation = try sq.reserveSlot();
        errdefer sq.releaseReservation(reservation);

        Sqe.init(reservation.slot, .{
            .opcode = @intFromEnum(Opcode.get_features),
            .command_id = reservation.command_id,
            .namespace_id = .none,
            .cdw10 = (GetCdw10{ .fid = .number_of_queues }).raw(),
        });

        return sq.stage(reservation);
    }
};
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `Identify.controller` | never | never | O(1) | caller-serialized per SQ | ordered by caller `sq.flush()` (SQ tail doorbell) | `queue.ReserveError` |
| `Identify.namespace` | never | never | O(1) | caller-serialized per SQ | ordered by caller `sq.flush()` | `queue.ReserveError`, `InvalidNamespaceIdentifier` |
| `Identify.activeNamespaceList` | never | never | O(1) | caller-serialized per SQ | ordered by caller `sq.flush()` | `queue.ReserveError` |
| `CreateIoCompletionQueue.encode` | never | never | O(1) | caller-serialized per SQ | ordered by caller `sq.flush()` | `queue.ReserveError`, `InvalidQueueIdentifier`, `InvalidQueueSize` |
| `CreateIoSubmissionQueue.encode` | never | never | O(1) | caller-serialized per SQ | ordered by caller `sq.flush()` | `queue.ReserveError`, `InvalidQueueIdentifier`, `InvalidQueueSize` |
| `DeleteIoSubmissionQueue.encode` / `DeleteIoCompletionQueue.encode` | never | never | O(1) | caller-serialized per SQ | ordered by caller `sq.flush()` | `queue.ReserveError`, `InvalidQueueIdentifier` |
| `Abort.encode` | never | never | O(1) | caller-serialized per SQ | ordered by caller `sq.flush()` | `queue.ReserveError`, `InvalidQueueIdentifier` |
| `NumberOfQueues.set` / `NumberOfQueues.get` | never | never | O(1) | caller-serialized per SQ | ordered by caller `sq.flush()` | `queue.ReserveError`, `InvalidQueueCount` |
| `NumberOfQueues.ResponseDw0.fromRaw` / `.allocated` / `.raw` | never | never | O(1) | value type | none | infallible |
| per-command `Cdw*` / `Dw*` `fromRaw` / `raw` | never | never | O(1) | value type | none | infallible |

## Validation phases

Per `docs/specs/architecture.md` §"Validation phases":

- **Compile time.** `@bitSizeOf` and `@sizeOf` assertions on every `Cdw10` / `Cdw11` / `Cdw12` / `ResponseDw0` / `DeleteQueueCdw10` packed struct.
- **Public validation.**
  - `Identify.namespace` rejects `Nsid.none` and `Nsid.broadcast`.
  - `CreateIoSubmissionQueue`, `CreateIoCompletionQueue`, `DeleteIoSubmissionQueue`, `DeleteIoCompletionQueue` reject `Qid.admin` and `Qid.reserved_max` on `qid`.
  - `CreateIoSubmissionQueue` additionally rejects `Qid.admin` and `Qid.reserved_max` on `cqid`.
  - `Abort` rejects `Qid.reserved_max` on `sqid`.
  - `CreateIoSubmissionQueue.encode` and `CreateIoCompletionQueue.encode` reject `queue_size < 2` with `error.InvalidQueueSize`.
  - `NumberOfQueues.set` rejects `submission_queues == 0` or `completion_queues == 0` with `error.InvalidQueueCount`.
- **Assertions.**
  - None — every runtime-input queue-size / queue-count value is validated through typed errors above. Reservation-slot invariants are asserted inside `controller/queue.md`.

## Example usage

Illustrative shape only; not part of the approved API. `docs/specs/examples/controller-bringup.md` owns the full sequence.

```zig
const std = @import("std");

const nvme = @import("nvme");
const stdx = @import("stdx");

const IoQueueBase = nvme.core.prp.IoQueueBase;

const admin = nvme.commands.admin;

var backoff = stdx.time.Backoff.init(nvme.controller.init.default_backoff_policy);
const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(500));

// Identify Controller.
const identify_buffer = try stdx.dma.Buffer(u8).init(&identify_backing, identify_dma_addr);
const identify_dptr = try nvme.core.prp.DataPointers.fromContiguous(.{
    .payload = identify_buffer,
    .page_size = page_size,
});
const identify_handle = try admin.Identify.controller(ctrl.admin.sq(), .{
    .dptr = identify_dptr,
});
try ctrl.admin.sq().flush();
const identify_completion = try ctrl.admin.pollOne(deadline, &backoff);
std.debug.assert(identify_completion.cid.raw() == identify_handle.command_id.raw());
if (!identify_completion.statusIsSuccess()) return error.IdentifyControllerFailed;

// Set Number of Queues (request 1 SQ, 1 CQ).
_ = try admin.NumberOfQueues.set(ctrl.admin.sq(), .{
    .requested = .{ .submission_queues = 1, .completion_queues = 1 },
});
try ctrl.admin.sq().flush();
const set_completion = try ctrl.admin.pollOne(deadline, &backoff);
if (!set_completion.statusIsSuccess()) return error.SetNumberOfQueuesFailed;
const allocated = admin.NumberOfQueues.ResponseDw0
    .fromRaw(set_completion.dw0)
    .allocated();

// Create the I/O Completion Queue first, then the I/O Submission Queue.
const io_cq_base = try IoQueueBase.fromContiguous(io_cq_bytes, page_size);
_ = try admin.CreateIoCompletionQueue.encode(ctrl.admin.sq(), .{
    .qid = .from(1),
    .queue_size = io_depth,
    .base = io_cq_base,
});
try ctrl.admin.sq().flush();
_ = try ctrl.admin.pollOne(deadline, &backoff);

const io_sq_base = try IoQueueBase.fromContiguous(io_sq_bytes, page_size);
_ = try admin.CreateIoSubmissionQueue.encode(ctrl.admin.sq(), .{
    .qid = .from(1),
    .queue_size = io_depth,
    .base = io_sq_base,
    .cqid = .from(1),
});
try ctrl.admin.sq().flush();
_ = try ctrl.admin.pollOne(deadline, &backoff);
```

## Required tests

Test file `test/commands/admin_test.zig`. Naming per `docs/guidelines/testing.md`.

Test substrate: a caller-owned `SubmissionQueue` with a scratch SQ ring, a scratch MMIO byte buffer for the doorbell, and `Sqe` accessors on `*const Sqe` verifying encoded slots. No CQE completion is needed at this level; response decoding is tested against fabricated DW0 values.

### Identify

- `unit: identify controller stamps opcode 06h nsid zero and cdw10 CNS 01h`.
- `unit: identify namespace stamps opcode 06h nsid target and cdw10 CNS 00h`.
- `unit: identify namespace rejects Nsid.none`.
- `unit: identify namespace rejects Nsid.broadcast`.
- `unit: identify active namespace list stamps CNS 02h with starting NSID zero by default`.
- `unit: identify Cdw10 encodes CNS in bits 7:0 with reserved and controller_id zero on default`.
- `roundtrip: identify controller encode then Sqe accessors decode opcode nsid cdw10 dptr`.
- `unit: identify Cdw10 fromRaw round-trips through raw`.

### Create I/O Completion Queue

- `unit: create io cq encodes opcode 05h nsid zero and cdw10 qid qsize zero-based`.
- `unit: create io cq encodes cdw11 pc 1 ien 0 iv default`.
- `unit: create io cq honors interrupts_enabled true and interrupt_vector value`.
- `unit: create io cq rejects Qid.admin on qid`.
- `unit: create io cq rejects Qid.reserved_max on qid`.
- `unit: create io cq rejects queue_size below 2 with InvalidQueueSize`.
- `unit: create io cq encodes prp1 from IoQueueBase and prp2 zero`.
- `unit: create io cq Cdw10 fromRaw round-trips through raw`.
- `unit: create io cq Cdw11 fromRaw round-trips through raw`.
### Create I/O Submission Queue

- `unit: create io sq encodes opcode 01h nsid zero and cdw10 qid qsize zero-based`.
- `unit: create io sq encodes cdw11 pc 1 priority default medium cqid`.
- `unit: create io sq encodes cdw12 nvm_set_id`.
- `unit: create io sq honors priority urgent high low`.
- `unit: create io sq rejects Qid.admin on qid`.
- `unit: create io sq rejects Qid.admin on cqid`.
- `unit: create io sq rejects Qid.reserved_max on cqid`.
- `unit: create io sq encodes prp1 from IoQueueBase and prp2 zero`.
- `unit: create io sq rejects queue_size below 2 with InvalidQueueSize`.
- `unit: create io sq Cdw10 fromRaw round-trips through raw`.
- `unit: create io sq Cdw11 fromRaw round-trips through raw`.
- `unit: create io sq Cdw12 fromRaw round-trips through raw`.

### Delete I/O SQ / CQ

- `unit: delete io sq encodes opcode 00h and cdw10 qid`.
- `unit: delete io cq encodes opcode 04h and cdw10 qid`.
- `unit: delete io sq rejects Qid.admin on qid`.
- `unit: delete io cq rejects Qid.reserved_max on qid`.
- `unit: delete queue Cdw10 fromRaw round-trips through raw`.

### Abort

- `unit: abort encodes opcode 08h nsid zero and cdw10 sqid cid`.
- `unit: abort accepts Qid.admin as sqid`.
- `unit: abort rejects Qid.reserved_max as sqid`.
- `unit: abort Cdw10 fromRaw round-trips through raw`.

### Number of Queues

- `unit: number of queues set encodes opcode 09h fid 07h save 0`.
- `unit: number of queues set encodes cdw11 nsqr ncqr zero-based`.
- `unit: number of queues get encodes opcode 0Ah fid 07h select current`.
- `unit: number of queues get encodes empty cdw11 zero`.
- `unit: number of queues ResponseDw0.fromRaw decodes nsqa ncqa zero-based`.
- `unit: number of queues ResponseDw0.allocated maps zero-based to one-based`.
- `unit: number of queues set rejects requested submission_queues 0 with InvalidQueueCount`.
- `unit: number of queues set rejects requested completion_queues 0 with InvalidQueueCount`.
- `unit: number of queues SetCdw10 fromRaw round-trips through raw`.
- `unit: number of queues GetCdw10 fromRaw round-trips through raw`.
- `unit: number of queues RequestCdw11 fromRaw round-trips through raw`.

### Roundtrips

- `roundtrip: create io cq encoded slot decodes through Sqe accessors for cdw10 cdw11 dptr`.
- `roundtrip: create io sq encoded slot decodes through Sqe accessors for cdw10 cdw11 cdw12 dptr`.
- `roundtrip: number of queues set encoded slot decodes through Sqe accessors for cdw10 cdw11`.
- `roundtrip: number of queues fromRaw then allocated one-based round trip` — build a raw `u32`, decode, allocate, assert one-based math.

## Open questions

_(none)_
