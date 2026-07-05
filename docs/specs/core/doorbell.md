# Core doorbells

Status: Approved.

`[znvme]` `Doorbells` owns NVMe SQ/CQ doorbell offset computation and host writes to doorbell MMIO registers. It composes `ControllerRegisters.mmioWindow()`, `CAP.DSTRD`, and `Qid`.

`[znvme]` A doorbell is notification, not queue state. Queue head/tail ownership, wrap, full/empty checks, phase-tag state, and queue-depth validation are owned by `docs/specs/controller/queue.md`.

## Owned scope

`[znvme]` This spec owns:

- `[znvme]` doorbell base offset `0x1000`;
- `[znvme]` doorbell stride computation from `CAP.DSTRD`;
- `[znvme]` SQ tail doorbell offset formula;
- `[znvme]` CQ head doorbell offset formula;
- `[znvme]` 32-bit doorbell value encoding (`index` in bits `15:0`, upper bits zero);
- `[znvme]` typed per-queue doorbell views for submission and completion queues;
- `[znvme]` host writes for SQ tail and CQ head doorbells;
- `[znvme]` the `mmio.release()` placement before SQ tail doorbell writes.

## Deferred scope and non-goals

`[znvme]` This spec does not own:

- `[znvme]` queue ring state, capacity, wrap, or phase tags (`docs/specs/controller/queue.md`);
- `[znvme]` command submission policy or synchronous polling loops;
- `[znvme]` CQE DMA acquire barriers;
- `[znvme]` interrupt behavior;
- `[znvme]` doorbell-buffer configuration or shadow doorbells;
- `[znvme]` reading doorbell registers;
- `[znvme]` validating whether a queue id has been created;
- `[znvme]` big-endian MMIO compatibility.

## NVMe behavior

`[nvme]` Doorbell registers start at offset `0x1000` in the NVMe controller MMIO register space.

`[nvme]` Each doorbell register is 32 bits. Doorbell spacing is:

```text
stride_bytes = 4 << CAP.DSTRD
```

Equivalent form:

```text
stride_bytes = 2^(2 + CAP.DSTRD)
```

`[nvme]` For queue identifier `y`:

```text
SQyTDBL = 0x1000 + (2*y)     * stride_bytes
CQyHDBL = 0x1000 + (2*y + 1) * stride_bytes
```

Where:

- `[nvme]` `SQyTDBL` = Submission Queue `y` Tail Doorbell;
- `[nvme]` `CQyHDBL` = Completion Queue `y` Head Doorbell;
- `[nvme]` `y` is the `Qid` raw value;
- `[nvme]` `Qid.admin` (`0`) addresses admin queue doorbells.

`[nvme]` Doorbell fields:

| Register | Low bits | Meaning |
| --- | --- | --- |
| `SQyTDBL` | `SQT[15:0]` | new Submission Queue Tail pointer |
| `CQyHDBL` | `CQH[15:0]` | new Completion Queue Head pointer |

`[nvme]` Bits `31:16` are reserved zero on writes.

`[nvme]` Values returned by doorbell-register reads are vendor-specific.

`[nvme]` Writing a doorbell for a queue that does not exist has undefined behavior.

## Approved API

```zig
// src/core/doorbell.zig
//! NVMe SQ/CQ doorbells. Spec: docs/specs/core/doorbell.md.

const std = @import("std");

const stdx = @import("stdx");

const ids = @import("ids.zig");
const registers = @import("registers.zig");

const Mmio = stdx.io.Mmio;
const Qid = ids.Qid;
const Reg32 = Mmio.Register(u32);

pub const base_offset: usize = registers.doorbell_base_offset;

const Kind = enum(u1) {
    submission_tail = 0,
    completion_head = 1,
};

pub const Stride = struct {
    bytes: usize,

    pub fn fromDstrd(value: u4) Stride {
        return .{ .bytes = @as(usize, 4) << @intCast(value) };
    }

    pub fn fromCap(cap: registers.Cap) Stride {
        return fromDstrd(cap.dstrd);
    }
};

pub const Value = packed struct(u32) {
    index: u16,
    reserved_16: u16 = 0,

    pub fn fromIndex(index: u16) Value {
        return .{ .index = index };
    }

    pub fn raw(self: Value) u32 {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert(@bitSizeOf(Value) == 32);
        std.debug.assert(@sizeOf(Value) == @sizeOf(u32));
        std.debug.assert(@alignOf(Value) == @alignOf(u32));
    }
};

pub const Doorbells = struct {
    window: Mmio.Window,
    stride: Stride,

    pub fn init(window: Mmio.Window, stride: Stride) Doorbells {
        return .{ .window = window, .stride = stride };
    }

    pub fn fromRegisters(regs: registers.ControllerRegisters, cap: registers.Cap) Doorbells {
        return init(regs.mmioWindow(), Stride.fromCap(cap));
    }

    pub fn submissionQueue(self: Doorbells, qid: Qid) SubmissionQueueDoorbell {
        assertValidQid(qid);
        return .{ .window = self.window, .stride = self.stride, .qid = qid };
    }

    pub fn completionQueue(self: Doorbells, qid: Qid) CompletionQueueDoorbell {
        assertValidQid(qid);
        return .{ .window = self.window, .stride = self.stride, .qid = qid };
    }
};

pub const SubmissionQueueDoorbell = struct {
    window: Mmio.Window,
    stride: Stride,
    qid: Qid,

    pub const Error = Mmio.Window.Error;

    pub fn offset(self: SubmissionQueueDoorbell) usize {
        return doorbellOffset(self.qid, .submission_tail, self.stride);
    }

    pub fn setTail(self: SubmissionQueueDoorbell, tail: u16) Error!void {
        const doorbell = try self.register();
        stdx.barrier.mmio.release();
        doorbell.store(Value.fromIndex(tail).raw());
    }

    fn register(self: SubmissionQueueDoorbell) Error!*volatile Reg32 {
        return self.window.register(u32, self.offset());
    }
};

pub const CompletionQueueDoorbell = struct {
    window: Mmio.Window,
    stride: Stride,
    qid: Qid,

    pub const Error = Mmio.Window.Error;

    pub fn offset(self: CompletionQueueDoorbell) usize {
        return doorbellOffset(self.qid, .completion_head, self.stride);
    }

    pub fn setHead(self: CompletionQueueDoorbell, head: u16) Error!void {
        const doorbell = try self.register();
        doorbell.store(Value.fromIndex(head).raw());
    }

    fn register(self: CompletionQueueDoorbell) Error!*volatile Reg32 {
        return self.window.register(u32, self.offset());
    }
};

fn doorbellOffset(qid: Qid, kind: Kind, stride: Stride) usize {
    assertValidQid(qid);

    const slot = (@as(usize, qid.raw()) * 2) + @intFromEnum(kind);
    return base_offset + slot * stride.bytes;
}

fn assertValidQid(qid: Qid) void {
    std.debug.assert(!qid.isReserved());
}

comptime {
    std.debug.assert(@bitSizeOf(Kind) == 1);
    std.debug.assert(@alignOf(Reg32) == @alignOf(u32));
}
```

## Boundary rules

`[znvme]` `Doorbells` borrows a `stdx.io.Mmio.Window`; it owns no MMIO mapping and no queue memory.

`[znvme]` `Doorbells.submissionQueue(qid)` and `Doorbells.completionQueue(qid)` return small borrowed views and allocate nothing.

`[znvme]` The per-queue views assert that `Qid.reserved_max` is not used. Whether a non-reserved QID names a created queue is owned by `controller/queue.md`.

`[znvme]` `SubmissionQueueDoorbell.setTail` performs `stdx.barrier.mmio.release()` immediately before the MMIO store. This orders prior SQE writes in caller-owned DMA memory before the controller observes the new SQ tail.

`[znvme]` `CompletionQueueDoorbell.setHead` performs only the MMIO store. CQE visibility is handled by the queue/CQE consumption path before entries are consumed; the CQ head doorbell only returns slots to the controller.

`[znvme]` No API reads doorbell registers.

## Error and validation behavior

- `[znvme]` `Stride.fromDstrd` accepts every `u4` value. The maximum NVMe value still fits `usize` on the required `x86_64` target.
- `[znvme]` `Value.fromIndex` accepts every `u16` value. Queue capacity validation belongs to `controller/queue.md`.
- `[znvme]` `SubmissionQueueDoorbell.setTail` and `CompletionQueueDoorbell.setHead` return `stdx.io.Mmio.Window.Error` if the backing MMIO window is too short or unexpectedly misaligned.
- `[znvme]` The per-queue view constructors and offset helper use a debug assertion for `Qid.reserved_max`; this is a programmer error after queue-id validation.

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `[znvme]` `Stride.fromDstrd` / `fromCap` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `Value.fromIndex` / `raw` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `Doorbells.init` / `fromRegisters` | never | never | O(1) | borrowed value | none | infallible |
| `[znvme]` `submissionQueue` / `completionQueue` | never | never | O(1) | borrowed value | none | debug assert on reserved QID |
| `[znvme]` `SubmissionQueueDoorbell.offset` / `CompletionQueueDoorbell.offset` | never | never | O(1) | value type | none | debug assert on reserved QID |
| `[znvme]` `SubmissionQueueDoorbell.setTail` | never | never | O(1) via `Mmio.Window` | caller-serialized per SQ | `mmio.release` then volatile store | `Mmio.Window.Error` |
| `[znvme]` `CompletionQueueDoorbell.setHead` | never | never | O(1) via `Mmio.Window` | caller-serialized per CQ | volatile store only | `Mmio.Window.Error` |

## Required tests `[znvme]`

`[znvme]` Test file `test/core/doorbell_test.zig`. Naming per `docs/guidelines/testing.md`.

- `[znvme]` `unit: doorbell stride expands CAP DSTRD` — `0 -> 4`, `2 -> 16`, `15 -> 131072`.
- `[znvme]` `unit: submission doorbell offset for admin queue with packed stride` — SQ0 `0x1000`.
- `[znvme]` `unit: completion doorbell offset for admin queue with packed stride` — CQ0 `0x1004`.
- `[znvme]` `unit: submission doorbell offset for io queue with packed stride` — QID 1 gives SQ1 `0x1008` when `DSTRD = 0`.
- `[znvme]` `unit: completion doorbell offset for io queue with packed stride` — QID 1 gives CQ1 `0x100c` when `DSTRD = 0`.
- `[znvme]` `unit: doorbell offsets honor expanded stride` — QID 1 gives SQ1 `0x1020`, CQ1 `0x1030` when `DSTRD = 2`.
- `[znvme]` `unit: doorbell value stores index and clears reserved bits`.
- `[znvme]` `unit: submission queue setTail writes expected MMIO lane` using a caller-owned aligned byte buffer.
- `[znvme]` `unit: completion queue setHead writes expected MMIO lane` using a caller-owned aligned byte buffer.
- `[znvme]` `unit: doorbell write rejects short window`.

## Open questions

_(none)_
