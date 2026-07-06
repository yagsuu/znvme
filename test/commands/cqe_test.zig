//! Host-side tests for src/commands/cqe.zig. Spec: docs/specs/commands/cqe.md.

const std = @import("std");
const testing = std.testing;

const nvme = @import("nvme");
const cqe_mod = nvme.commands.cqe;
const regen = @import("../fixtures/commands/cqe_success_regen.zig");

const Cqe = cqe_mod.Cqe;
const Cid = nvme.core.ids.Cid;
const Qid = nvme.core.ids.Qid;
const CompletionStatus = nvme.core.status.CompletionStatus;

test "unit: cqe extern layout matches NVMe completion format offsets" {
    // Mirror the colocated comptime @offsetOf assertions behaviorally so the
    // NVMe Common Completion Format byte offsets are checked from a host-side
    // test as well as at compile time.
    try testing.expectEqual(@as(usize, 0x00), @offsetOf(Cqe, "_dw0"));
    try testing.expectEqual(@as(usize, 0x04), @offsetOf(Cqe, "_dw1"));
    try testing.expectEqual(@as(usize, 0x08), @offsetOf(Cqe, "_sqhd"));
    try testing.expectEqual(@as(usize, 0x0a), @offsetOf(Cqe, "_sqid"));
    try testing.expectEqual(@as(usize, 0x0c), @offsetOf(Cqe, "_cid"));
    try testing.expectEqual(@as(usize, 0x0e), @offsetOf(Cqe, "_status"));
}

test "unit: cqe size is 16 bytes and alignment is 4" {
    // The NVMe CQE is exactly 16 bytes with 4-byte alignment to match the
    // wire format required by controller DMA.
    try testing.expectEqual(@as(usize, 16), @sizeOf(Cqe));
    try testing.expectEqual(@as(usize, 16), cqe_mod.size_bytes);
    try testing.expectEqual(@as(usize, 4), @alignOf(Cqe));
}

test "unit: cqe default value is all-zero" {
    // A default-constructed `Cqe{}` reads zero on every underscored storage
    // lane — establishes the "blank slot" invariant callers rely on.
    const c: Cqe = .{};
    try testing.expectEqual(@as(u32, 0), c._dw0);
    try testing.expectEqual(@as(u32, 0), c._dw1);
    try testing.expectEqual(@as(u16, 0), c._sqhd);
    try testing.expectEqual(@as(u16, 0), c._sqid);
    try testing.expectEqual(@as(u16, 0), c._cid);
    try testing.expectEqual(@as(u16, 0), c._status);
}

test "unit: cqe accessors decode dw0 and dw1" {
    // Arbitrary arithmetic u32 values must round-trip through `dw0()` and
    // `dw1()`; the accessors are pure typed loads of the underscored lanes.
    const dw0_values = [_]u32{ 0x0000_0000, 0xDEAD_BEEF, 0xFFFF_FFFF, 0x1234_5678 };
    const dw1_values = [_]u32{ 0xFFFF_FFFF, 0x0000_0000, 0xCAFE_F00D, 0x8765_4321 };
    for (dw0_values, dw1_values) |v0, v1| {
        const c: Cqe = .{ ._dw0 = v0, ._dw1 = v1 };
        try testing.expectEqual(v0, c.dw0());
        try testing.expectEqual(v1, c.dw1());
    }
}

test "unit: cqe sqhd returns raw u16" {
    // SQHD is an intra-SQ offset, not an identifier — the accessor returns
    // the raw u16 unchanged for representative low, mid-range, and high values.
    for ([_]u16{ 0, 0x8000, 0xFFFF }) |v| {
        const c: Cqe = .{ ._sqhd = v };
        try testing.expectEqual(v, c.sqhd());
    }
}

test "unit: cqe sqid wraps through Qid.from" {
    // sqid() wraps the raw u16 through Qid.from — every u16 is representable
    // (admin 0, an IO qid, and reserved_max 0xFFFF).
    const cases = [_]u16{ 0x0000, 0x0007, 0xFFFF };
    for (cases) |v| {
        const c: Cqe = .{ ._sqid = v };
        const q = c.sqid();
        try testing.expectEqual(v, q.raw());
        try testing.expectEqual(Qid.from(v).raw(), q.raw());
    }
    // Spot-check identity predicates on the boundary values.
    const admin: Cqe = .{ ._sqid = 0x0000 };
    try testing.expectEqual(true, admin.sqid().isAdmin());
    const io: Cqe = .{ ._sqid = 0x0007 };
    try testing.expectEqual(true, io.sqid().isIoQueue());
    const rmax: Cqe = .{ ._sqid = 0xFFFF };
    try testing.expectEqual(true, rmax.sqid().isReserved());
}

test "unit: cqe cid wraps through Cid.from" {
    // cid() wraps the raw u16 through Cid.from — every u16 is representable.
    for ([_]u16{ 0x0000, 0x7FFF, 0xFFFF }) |v| {
        const c: Cqe = .{ ._cid = v };
        try testing.expectEqual(v, c.cid().raw());
        try testing.expectEqual(Cid.from(v).raw(), c.cid().raw());
    }
}

test "unit: cqe status wraps through CompletionStatus.from" {
    // status() must produce identical decodes to CompletionStatus.from(raw)
    // across success-with-phase, a generic failure, and a reserved-SCT value.
    const success_raw = CompletionStatus.success(true).raw();
    const success_c: Cqe = .{ ._status = success_raw };
    try testing.expectEqual(success_raw, success_c.status().raw());
    try testing.expectEqual(true, success_c.status().phase());
    try testing.expectEqual(true, success_c.status().isSuccess());

    const fail_raw = CompletionStatus.genericFailure(true, .invalid_field).raw();
    const fail_c: Cqe = .{ ._status = fail_raw };
    try testing.expectEqual(fail_raw, fail_c.status().raw());
    try testing.expectEqual(false, fail_c.status().isSuccess());
    switch (fail_c.status().kind()) {
        .generic => |gc| try testing.expectEqual(CompletionStatus.GenericCode.invalid_field, gc),
        else => return error.WrongKind,
    }

    // Reserved SCT (raw code_type = 4) — accessors preserve the raw bits and
    // classify the failure under `.reserved_code_type`.
    const reserved = CompletionStatus.init(.{
        .phase = false,
        .code_type = @enumFromInt(@as(u3, 4)),
        .code = 0x10,
    });
    const reserved_c: Cqe = .{ ._status = reserved.raw() };
    try testing.expectEqual(reserved.raw(), reserved_c.status().raw());
    switch (reserved_c.status().kind()) {
        .reserved_code_type => |v| try testing.expectEqual(@as(u3, 4), v),
        else => return error.WrongKind,
    }
}

test "unit: cqe phase issues a monotonic atomic load of the status lane and returns bit 0" {
    // Behavioral probe: write various raw u16 values directly into `_status`
    // and confirm phase() returns bit 0 of the observed status lane. This
    // exercises the runtime load path — not an audit — proving phase() masks
    // exactly one bit off the atomic load.
    const cases = [_]struct { raw: u16, expected: bool }{
        .{ .raw = 0x0000, .expected = false },
        .{ .raw = 0x0001, .expected = true },
        .{ .raw = 0xFFFE, .expected = false },
        .{ .raw = 0xFFFF, .expected = true },
        .{ .raw = 0xA5A4, .expected = false },
        .{ .raw = 0xA5A5, .expected = true },
    };
    var c: Cqe = .{};
    for (cases) |case| {
        c._status = case.raw;
        try testing.expectEqual(case.expected, c.phase());
    }
}

test "unit: cqe statusIsSuccess returns true for status-field all-zero slot as phase-agnostic status decode" {
    // An all-zero status field decodes to generic success regardless of phase;
    // statusIsSuccess() must delegate to CompletionStatus.isSuccess() and
    // therefore return true for a default-constructed slot (phase == 0 too).
    const c: Cqe = .{};
    try testing.expectEqual(false, c.phase());
    try testing.expectEqual(true, c.statusIsSuccess());
}

test "unit: cqe isPostedSuccess returns false when phase does not match expected even when status is generic success" {
    // Slot carries a generic-success status with phase 0, but the caller
    // expects phase 1. isPostedSuccess must reject on phase mismatch.
    const c: Cqe = .{ ._status = CompletionStatus.success(false).raw() };
    try testing.expectEqual(true, c.statusIsSuccess());
    try testing.expectEqual(false, c.isPostedSuccess(true));
}

test "unit: cqe isPostedSuccess returns true when phase matches expected and status is generic success" {
    // Happy path: phase matches expected and status decodes as generic
    // success — isPostedSuccess is the single go/no-go predicate for callers.
    const c: Cqe = .{ ._status = CompletionStatus.success(true).raw() };
    try testing.expectEqual(true, c.phase());
    try testing.expectEqual(true, c.statusIsSuccess());
    try testing.expectEqual(true, c.isPostedSuccess(true));
}

test "unit: cqe isPostedSuccess returns false when phase matches expected but status is a generic failure" {
    // Phase matches but the status field carries a generic failure —
    // isPostedSuccess must return false because statusIsSuccess is false.
    const c: Cqe = .{
        ._status = CompletionStatus.genericFailure(true, .invalid_field).raw(),
    };
    try testing.expectEqual(true, c.phase());
    try testing.expectEqual(false, c.statusIsSuccess());
    try testing.expectEqual(false, c.isPostedSuccess(true));
}

test "unit: Cqe.init(target, .{}) stamps target with every lane zero" {
    // Init defaults must produce a fully zero slot suitable as a fixture reset.
    var c: Cqe = undefined;
    Cqe.init(&c, .{});
    try testing.expectEqual(@as(u32, 0), c._dw0);
    try testing.expectEqual(@as(u32, 0), c._dw1);
    try testing.expectEqual(@as(u16, 0), c._sqhd);
    try testing.expectEqual(@as(u16, 0), c._sqid);
    try testing.expectEqual(@as(u16, 0), c._cid);
    try testing.expectEqual(@as(u16, 0), c._status);
}

test "roundtrip: Cqe.init round-trips every Init field through accessors" {
    // Populate every Init field with a non-default value; construct via init;
    // verify each accessor returns the corresponding input verbatim.
    const status_val = CompletionStatus.init(.{
        .phase = true,
        .code_type = .command_specific,
        .code = 0x42,
        .retry_delay = .crdt2,
        .more = true,
        .do_not_retry = true,
    }).raw();
    const params: Cqe.Init = .{
        .cid = 0xBEEF,
        .sqid = 0x1234,
        .sqhd = 0xABCD,
        .dw0 = 0xDEAD_BEEF,
        .dw1 = 0xF00D_CAFE,
        .status = status_val,
    };

    var c: Cqe = undefined;
    Cqe.init(&c, params);

    try testing.expectEqual(params.dw0, c.dw0());
    try testing.expectEqual(params.dw1, c.dw1());
    try testing.expectEqual(params.sqhd, c.sqhd());
    try testing.expectEqual(params.sqid, c.sqid().raw());
    try testing.expectEqual(params.cid, c.cid().raw());
    try testing.expectEqual(params.status, c.status().raw());
}

test "roundtrip: cqe accessors decode every scalar field from a struct-literal slot" {
    // Build a Cqe via a struct literal (as an emulator-authored slot would
    // appear when written directly) and check every accessor decodes the
    // wire lane back into its semantic type. Success case, phase = 1.
    const c: Cqe = .{
        ._dw0 = 0x1122_3344,
        ._dw1 = 0x5566_7788,
        ._sqhd = 0x00AB,
        ._sqid = 0x0005,
        ._cid = 0x1234,
        ._status = CompletionStatus.success(true).raw(),
    };

    try testing.expectEqual(@as(u32, 0x1122_3344), c.dw0());
    try testing.expectEqual(@as(u32, 0x5566_7788), c.dw1());
    try testing.expectEqual(@as(u16, 0x00AB), c.sqhd());
    try testing.expectEqual(@as(u16, 0x0005), c.sqid().raw());
    try testing.expectEqual(true, c.sqid().isIoQueue());
    try testing.expectEqual(@as(u16, 0x1234), c.cid().raw());
    try testing.expectEqual(true, c.phase());
    try testing.expectEqual(true, c.statusIsSuccess());
    try testing.expectEqual(true, c.isPostedSuccess(true));
}

test "roundtrip: cqe decodes generic invalid_field failure with CRD and DNR set" {
    // A generic-failure status composed with retry-delay and do-not-retry
    // set must decode identically through Cqe.status() and via
    // CompletionStatus.failure() — every failure bit reaches the consumer.
    const built = CompletionStatus.init(.{
        .phase = true,
        .code_type = .generic,
        .code = @intFromEnum(CompletionStatus.GenericCode.invalid_field),
        .retry_delay = .crdt2,
        .do_not_retry = true,
    });
    const c: Cqe = .{
        ._cid = 0x0007,
        ._sqid = 0x0000,
        ._sqhd = 0x0010,
        ._status = built.raw(),
    };

    const decoded = c.status();
    try testing.expectEqual(built.raw(), decoded.raw());
    try testing.expectEqual(true, decoded.phase());
    try testing.expectEqual(false, decoded.isSuccess());
    try testing.expectEqual(false, c.statusIsSuccess());
    try testing.expectEqual(false, c.isPostedSuccess(true));

    const fail = decoded.failure() orelse return error.ExpectedFailure;
    switch (fail.kind) {
        .generic => |gc| try testing.expectEqual(CompletionStatus.GenericCode.invalid_field, gc),
        else => return error.WrongKind,
    }
    try testing.expectEqual(CompletionStatus.RetryDelay.crdt2, fail.retry_delay);
    try testing.expectEqual(true, fail.do_not_retry);
    try testing.expectEqual(false, fail.more);
}

test "golden: cqe success completion minimal bytes" {
    // Compose the fixture bytes via the regen program's golden Init and
    // compare byte-for-byte against the on-disk `.bin`. Then re-validate
    // one accessor round-trip by re-reading the embedded bytes through the
    // Cqe type — proves the wire encoding and the host decode agree.
    var scratch: Cqe = undefined;
    Cqe.init(&scratch, regen.golden_init);
    const composed = std.mem.asBytes(&scratch);

    const embedded = @embedFile("../fixtures/commands/cqe_success.bin");
    try testing.expectEqual(@as(usize, cqe_mod.size_bytes), embedded.len);
    try testing.expectEqualSlices(u8, embedded, composed);

    // Re-view the composed bytes through the Cqe type and confirm one
    // accessor round-trip: successful admin completion with CID 0x0001,
    // SQHD 0x0002, SQID admin (0), phase 1, generic success.
    try testing.expectEqual(@as(u16, 0x0001), scratch.cid().raw());
    try testing.expectEqual(@as(u16, 0x0002), scratch.sqhd());
    try testing.expectEqual(@as(u16, 0x0000), scratch.sqid().raw());
    try testing.expectEqual(true, scratch.sqid().isAdmin());
    try testing.expectEqual(@as(u32, 0), scratch.dw0());
    try testing.expectEqual(@as(u32, 0), scratch.dw1());
    try testing.expectEqual(true, scratch.phase());
    try testing.expectEqual(true, scratch.statusIsSuccess());
    try testing.expectEqual(true, scratch.isPostedSuccess(true));
}
