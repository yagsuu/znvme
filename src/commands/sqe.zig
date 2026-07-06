//! NVMe Submission Queue Entry. Spec: docs/specs/commands/sqe.md.

const std = @import("std");

const ids = @import("../core/ids.zig");

const Cid = ids.Cid;
const DataPointers = @import("../core/prp.zig").DataPointers;
const Nsid = ids.Nsid;

/// Size of one SQE on the wire.
pub const size_bytes: usize = 64;

pub const Error = error{ ShortBuffer, Misaligned };

/// Fused-operation phase for two-command atomic sequences (compare-and-write).
pub const Fuse = enum(u2) {
    normal = 0b00,
    first = 0b01,
    second = 0b10,
    _,
};

/// PRP-or-SGL Data Transfer selection. NVM Command Set on the first slice
/// uses `.prps` exclusively.
pub const Psdt = enum(u2) {
    prps = 0b00,
    sgl_mptr_addr = 0b01,
    sgl_mptr_sgl = 0b10,
    _,
};

/// Command Dword 0: opcode, fuse phase, transfer type, and command id.
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

/// 64-byte NVMe Submission Queue Entry. Underscore-prefixed storage fields
/// carry wire bytes; typed accessors decode. Callers author in place via
/// `Sqe.init(target, params)`; readers borrow through `Sqe.validate(bytes)`.
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
