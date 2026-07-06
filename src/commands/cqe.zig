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
