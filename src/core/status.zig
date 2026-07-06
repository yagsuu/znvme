//! CQE status decode. Spec: docs/specs/core/status.md.

const std = @import("std");

pub const CompletionStatus = struct {
    bits: Bits,

    pub const Raw = u16;

    pub const Bits = packed struct(u16) {
        phase: u1,
        code: u8,
        code_type: u3,
        retry_delay: u2,
        more: u1,
        do_not_retry: u1,
    };

    pub const CodeType = enum(u3) {
        generic = 0x0,
        command_specific = 0x1,
        media_data_integrity = 0x2,
        path_related = 0x3,
        vendor_specific = 0x7,
        _,
    };

    pub const RetryDelay = enum(u2) {
        none = 0,
        crdt1 = 1,
        crdt2 = 2,
        crdt3 = 3,
    };

    pub const GenericCode = enum(u8) {
        success = 0x00,
        invalid_command_opcode = 0x01,
        invalid_field = 0x02,
        command_id_conflict = 0x03,
        data_transfer_error = 0x04,
        commands_aborted_power_loss = 0x05,
        internal_error = 0x06,
        command_abort_requested = 0x07,
        command_aborted_sq_deletion = 0x08,
        fused_command_failed = 0x09,
        fused_command_missing = 0x0A,
        invalid_namespace_or_format = 0x0B,
        command_sequence_error = 0x0C,
        invalid_sgl_segment_descriptor = 0x0D,
        invalid_number_sgl_descriptors = 0x0E,
        data_sgl_length_invalid = 0x0F,
        metadata_sgl_length_invalid = 0x10,
        sgl_descriptor_type_invalid = 0x11,
        invalid_use_controller_memory_buffer = 0x12,
        prp_offset_invalid = 0x13,
        _,
    };

    pub const Kind = union(enum) {
        success,
        generic: GenericCode,
        command_specific: u8,
        media_data_integrity: u8,
        path_related: u8,
        vendor_specific: u8,
        reserved_code_type: u3,
    };

    pub const Failure = struct {
        kind: Kind,
        retry_delay: RetryDelay,
        more: bool,
        do_not_retry: bool,
    };

    pub const Init = struct {
        phase: bool,
        code_type: CodeType = .generic,
        code: u8 = @intFromEnum(GenericCode.success),
        retry_delay: RetryDelay = .none,
        more: bool = false,
        do_not_retry: bool = false,
    };

    /// Compose a `CompletionStatus` from semantic fields. `phase` is required; every other
    /// `Init` field defaults to the "success" side, so `init(.{ .phase = true })` yields a
    /// phase-1 generic-success value.
    pub fn init(params: Init) CompletionStatus {
        return .{ .bits = .{
            .phase = @intFromBool(params.phase),
            .code = params.code,
            .code_type = @intFromEnum(params.code_type),
            .retry_delay = @intFromEnum(params.retry_delay),
            .more = @intFromBool(params.more),
            .do_not_retry = @intFromBool(params.do_not_retry),
        } };
    }

    /// Shortcut for the common "posted successful admin completion" fixture:
    /// `CompletionStatus.init(.{ .phase = phase_bit })`.
    pub fn success(phase_bit: bool) CompletionStatus {
        return init(.{ .phase = phase_bit });
    }

    /// Shortcut for a generic-status failure with a chosen `GenericCode`.
    pub fn genericFailure(phase_bit: bool, generic_code: GenericCode) CompletionStatus {
        return init(.{
            .phase = phase_bit,
            .code_type = .generic,
            .code = @intFromEnum(generic_code),
        });
    }

    pub fn from(value: Raw) CompletionStatus {
        return .{ .bits = @bitCast(value) };
    }

    pub fn raw(self: CompletionStatus) Raw {
        return @bitCast(self.bits);
    }

    pub fn phase(self: CompletionStatus) bool {
        return self.bits.phase != 0;
    }

    pub fn code(self: CompletionStatus) u8 {
        return self.bits.code;
    }

    pub fn codeType(self: CompletionStatus) CodeType {
        return @enumFromInt(self.bits.code_type);
    }

    pub fn retryDelay(self: CompletionStatus) RetryDelay {
        return @enumFromInt(self.bits.retry_delay);
    }

    pub fn hasMore(self: CompletionStatus) bool {
        return self.bits.more != 0;
    }

    pub fn doNotRetry(self: CompletionStatus) bool {
        return self.bits.do_not_retry != 0;
    }

    /// True iff the status field decodes to a generic-success completion:
    /// `codeType == .generic` and `code == GenericCode.success`. This is a
    /// pure status-field decoder and never consults the phase bit. Callers
    /// reading a CQ slot directly must verify phase separately through
    /// `Cqe.phase()` or `Cqe.isPostedSuccess(expected_phase)`;
    /// callers using a `queue.Completion` returned from `pollOne` have
    /// already had phase verified and use `Completion.statusIsSuccess()`.
    pub fn isSuccess(self: CompletionStatus) bool {
        return self.codeType() == .generic and self.code() == @intFromEnum(GenericCode.success);
    }

    pub fn kind(self: CompletionStatus) Kind {
        if (self.isSuccess()) return .success;

        return switch (self.codeType()) {
            .generic => .{ .generic = @enumFromInt(self.code()) },
            .command_specific => .{ .command_specific = self.code() },
            .media_data_integrity => .{ .media_data_integrity = self.code() },
            .path_related => .{ .path_related = self.code() },
            .vendor_specific => .{ .vendor_specific = self.code() },
            else => .{ .reserved_code_type = self.bits.code_type },
        };
    }

    pub fn failure(self: CompletionStatus) ?Failure {
        if (self.isSuccess()) return null;

        return .{
            .kind = self.kind(),
            .retry_delay = self.retryDelay(),
            .more = self.hasMore(),
            .do_not_retry = self.doNotRetry(),
        };
    }

    comptime {
        std.debug.assert(@bitSizeOf(Bits) == 16);
        std.debug.assert(@bitSizeOf(CodeType) == 3);
        std.debug.assert(@bitSizeOf(RetryDelay) == 2);
        std.debug.assert(@bitSizeOf(GenericCode) == 8);
        std.debug.assert(@sizeOf(CompletionStatus) == 2);
        std.debug.assert(@alignOf(CompletionStatus) == @alignOf(u16));
    }
};
