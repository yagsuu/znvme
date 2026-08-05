//! NVMe SQ/CQ doorbells. Spec: docs/specs/core/doorbell.md.

const std = @import("std");

const stdx = @import("stdx");

const ids = @import("ids.zig");
const registers = @import("registers.zig");

const MMIO = stdx.io.MMIO;
const Qid = ids.Qid;
const Window = MMIO.Window64;
const Reg32 = MMIO.Register(u32);

pub const base_offset: usize = registers.doorbell_base_offset;

const Kind = enum(u1) {
    submission_tail = 0,
    completion_head = 1,
};

/// Doorbell stride in bytes, derived from `CAP.DSTRD`.
pub const Stride = struct {
    bytes: usize,

    pub fn fromDstrd(value: u4) Stride {
        return .{ .bytes = @as(usize, 4) << @intCast(value) };
    }

    pub fn fromCap(cap: registers.Cap) Stride {
        return fromDstrd(cap.dstrd);
    }
};

/// Wire-encoded doorbell store: 16-bit index in the low half, upper half
/// reserved and always zero.
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

/// Root doorbell accessor: composes an MMIO window with the CAP-derived
/// stride and mints per-queue doorbell handles.
pub const Doorbells = struct {
    window: Window,
    stride: Stride,

    pub fn init(window: Window, stride: Stride) Doorbells {
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

/// Per-SQ tail doorbell. `setTail` emits `stdx.barrier.mmio.release` before
/// the store so prior SQE writes are ordered ahead of the doorbell ring.
pub const SubmissionQueueDoorbell = struct {
    window: Window,
    stride: Stride,
    qid: Qid,

    pub const Error = Window.Error;

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

/// Per-CQ head doorbell. `setHead` emits no barrier — the paired
/// `stdx.barrier.dma.acquire` in the completion drain already orders CQE
/// reads, and the head store only acknowledges consumption.
pub const CompletionQueueDoorbell = struct {
    window: Window,
    stride: Stride,
    qid: Qid,

    pub const Error = Window.Error;

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
