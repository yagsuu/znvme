//! NVM Command Set builders: Read, Write, Flush. Spec: docs/specs/commands/nvm.md.

const std = @import("std");

const ids = @import("../core/ids.zig");
const prp = @import("../core/prp.zig");
const queue = @import("../controller/queue.zig");

const DataPointers = prp.DataPointers;
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
