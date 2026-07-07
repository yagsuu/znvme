//! Tests for src/core/status.zig. Spec: docs/specs/core/status.md.

const std = @import("std");
const testing = std.testing;
const nvme = @import("nvme");
const status = nvme.core.status;
const CompletionStatus = status.CompletionStatus;

test "unit: status decodes success with phase one" {
    const cs = CompletionStatus.from(0x0001);
    try testing.expectEqual(true, cs.phase());
    try testing.expectEqual(true, cs.isSuccess());
    try testing.expectEqual(@as(?CompletionStatus.Failure, null), cs.failure());
    try testing.expectEqual(std.meta.Tag(CompletionStatus.Kind).success, std.meta.activeTag(cs.kind()));
}

test "unit: status decodes generic invalid field" {
    const cs = CompletionStatus.from(0x0005);
    try testing.expectEqual(true, cs.phase());
    try testing.expectEqual(false, cs.isSuccess());
    try testing.expect(cs.failure() != null);
    switch (cs.kind()) {
        .generic => |gc| try testing.expectEqual(CompletionStatus.GenericCode.invalid_field, gc),
        else => return error.WrongKind,
    }
}

test "unit: status decodes command specific raw code" {
    const cs = CompletionStatus.init(.{
        .phase = true,
        .code_type = .command_specific,
        .code = 0x02,
    });
    switch (cs.kind()) {
        .command_specific => |c| try testing.expectEqual(@as(u8, 0x02), c),
        else => return error.WrongKind,
    }
    const round = CompletionStatus.from(cs.raw());
    switch (round.kind()) {
        .command_specific => |c| try testing.expectEqual(@as(u8, 0x02), c),
        else => return error.WrongKind,
    }
}

test "unit: status decodes media and path raw codes" {
    const media = CompletionStatus.init(.{
        .phase = true,
        .code_type = .media_data_integrity,
        .code = 0x81,
    });
    switch (media.kind()) {
        .media_data_integrity => |c| try testing.expectEqual(@as(u8, 0x81), c),
        else => return error.WrongKind,
    }

    const path = CompletionStatus.init(.{
        .phase = false,
        .code_type = .path_related,
        .code = 0x60,
    });
    switch (path.kind()) {
        .path_related => |c| try testing.expectEqual(@as(u8, 0x60), c),
        else => return error.WrongKind,
    }
}

test "unit: status decodes vendor specific raw code" {
    const cs = CompletionStatus.init(.{
        .phase = true,
        .code_type = .vendor_specific,
        .code = 0xC3,
    });
    switch (cs.kind()) {
        .vendor_specific => |c| try testing.expectEqual(@as(u8, 0xC3), c),
        else => return error.WrongKind,
    }
}

test "unit: status preserves reserved code type" {
    inline for (.{ @as(u3, 4), @as(u3, 5), @as(u3, 6) }) |raw_sct| {
        const cs = CompletionStatus.init(.{
            .phase = false,
            .code_type = @enumFromInt(raw_sct),
            .code = 0x10,
        });
        switch (cs.kind()) {
            .reserved_code_type => |v| try testing.expectEqual(raw_sct, v),
            else => return error.WrongKind,
        }
        const fail = cs.failure() orelse return error.ExpectedFailure;
        try testing.expectEqual(
            std.meta.Tag(CompletionStatus.Kind).reserved_code_type,
            std.meta.activeTag(fail.kind),
        );
    }
}

test "unit: status decodes retry delay more and do-not-retry" {
    const cs = CompletionStatus.init(.{
        .phase = true,
        .code_type = .command_specific,
        .code = 0x01,
        .retry_delay = .crdt2,
        .more = true,
        .do_not_retry = true,
    });
    try testing.expectEqual(CompletionStatus.RetryDelay.crdt2, cs.retryDelay());
    try testing.expectEqual(true, cs.hasMore());
    try testing.expectEqual(true, cs.doNotRetry());

    const fail = cs.failure() orelse return error.ExpectedFailure;
    try testing.expectEqual(CompletionStatus.RetryDelay.crdt2, fail.retry_delay);
    try testing.expectEqual(true, fail.more);
    try testing.expectEqual(true, fail.do_not_retry);
}

test "unit: status raw roundtrip preserves all bits" {
    const cases = [_]u16{ 0x0000, 0x0001, 0xFFFF, 0xA5A5, 0x5A5A, 0x1234, 0xBEEF };
    for (cases) |v| {
        try testing.expectEqual(v, CompletionStatus.from(v).raw());
    }
}

test "unit: completion status isSuccess returns true for all-zero status field regardless of phase bit" {
    const p0 = CompletionStatus.from(0x0000);
    try testing.expectEqual(false, p0.phase());
    try testing.expectEqual(true, p0.isSuccess());
    try testing.expectEqual(@as(?CompletionStatus.Failure, null), p0.failure());

    const p1 = CompletionStatus.from(0x0001);
    try testing.expectEqual(true, p1.phase());
    try testing.expectEqual(true, p1.isSuccess());
    try testing.expectEqual(@as(?CompletionStatus.Failure, null), p1.failure());
}

test "unit: CompletionStatus.init round-trips through raw and from" {
    const built_success = CompletionStatus.init(.{ .phase = true });
    const built_failure = CompletionStatus.init(.{
        .phase = false,
        .code_type = .path_related,
        .code = 0x42,
        .retry_delay = .crdt3,
        .more = true,
        .do_not_retry = true,
    });

    inline for (.{ built_success, built_failure }) |built| {
        const round = CompletionStatus.from(built.raw());
        try testing.expectEqual(built.phase(), round.phase());
        try testing.expectEqual(built.code(), round.code());
        try testing.expectEqual(built.codeType(), round.codeType());
        try testing.expectEqual(built.retryDelay(), round.retryDelay());
        try testing.expectEqual(built.hasMore(), round.hasMore());
        try testing.expectEqual(built.doNotRetry(), round.doNotRetry());
        try testing.expectEqual(built.isSuccess(), round.isSuccess());
        try testing.expectEqual(built.raw(), round.raw());
    }
}

test "unit: CompletionStatus.success(phase) returns a generic-success value with the given phase bit" {
    inline for (.{ false, true }) |p| {
        const cs = CompletionStatus.success(p);
        try testing.expectEqual(p, cs.phase());
        try testing.expectEqual(true, cs.isSuccess());
        try testing.expectEqual(CompletionStatus.CodeType.generic, cs.codeType());
        try testing.expectEqual(@as(u8, 0), cs.code());
        try testing.expectEqual(@as(?CompletionStatus.Failure, null), cs.failure());
        try testing.expectEqual(CompletionStatus.RetryDelay.none, cs.retryDelay());
        try testing.expectEqual(false, cs.hasMore());
        try testing.expectEqual(false, cs.doNotRetry());
    }
}

test "unit: CompletionStatus.genericFailure(phase, code) sets code_type generic and preserves phase and code" {
    const codes = .{
        CompletionStatus.GenericCode.invalid_command_opcode,
        CompletionStatus.GenericCode.invalid_field,
        CompletionStatus.GenericCode.internal_error,
        CompletionStatus.GenericCode.prp_offset_invalid,
    };
    inline for (.{ false, true }) |p| {
        inline for (codes) |gc| {
            const cs = CompletionStatus.genericFailure(p, gc);
            try testing.expectEqual(p, cs.phase());
            try testing.expectEqual(CompletionStatus.CodeType.generic, cs.codeType());
            try testing.expectEqual(@intFromEnum(gc), cs.code());
            try testing.expectEqual(false, cs.isSuccess());
            switch (cs.kind()) {
                .generic => |inner| try testing.expectEqual(gc, inner),
                else => return error.WrongKind,
            }
        }
    }
}
