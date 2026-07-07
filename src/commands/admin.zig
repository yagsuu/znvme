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
