//! Tests for src/controller/init.zig. Spec: docs/specs/controller/init.md.

const std = @import("std");

const stdx = @import("stdx");

const nvme = @import("nvme");

const Aqa = nvme.core.registers.Aqa;
const Cap = nvme.core.registers.Cap;
const Cc = nvme.core.registers.Cc;
const CidAllocator = nvme.controller.queue.CidAllocator;
const Cqe = nvme.commands.cqe.Cqe;
const Csts = nvme.core.registers.Csts;
const DmaAddr = stdx.addr.DmaAddr;
const QueueBase = nvme.core.registers.QueueBase;
const ShutdownNotification = nvme.core.registers.ShutdownNotification;
const ShutdownStatus = nvme.core.registers.ShutdownStatus;
const Sqe = nvme.commands.sqe.Sqe;

const init = nvme.controller.init;
const doorbell = nvme.core.doorbell;
const ids = nvme.core.ids;
const prp = nvme.core.prp;
const queue = nvme.controller.queue;
const registers = nvme.core.registers;
const testing = std.testing;

/// Register-block offsets (see src/core/registers.zig comptime asserts).
const OFF_CC: usize = 0x0014;
const OFF_CSTS: usize = 0x001c;
const OFF_AQA: usize = 0x0024;
const OFF_ASQ: usize = 0x0028;
const OFF_ACQ: usize = 0x0030;

const ADMIN_DEPTH: u16 = 8;
const ASQ_ADDR: u64 = 0x0000_0000_1000_0000;
const ACQ_ADDR: u64 = 0x0000_0000_2000_0000;
const PAGE_SIZE: u64 = 4096;

/// Deterministic host-only clock backend: `now` advances 1 ms per call so
/// `Deadline.now(&clock, ...)` reads a monotonically increasing anchor
/// without ever touching wall time. `sleep` is `unreachable`; the spin-only
/// backoff policy below never emits `.sleep`.
const CounterBackend = struct {
    ticks_ns: u64 = 0,

    pub fn now(self: *CounterBackend) stdx.time.Instant {
        const t = self.ticks_ns;
        self.ticks_ns += 1_000_000;
        return stdx.time.Instant.fromNanos(t);
    }

    pub fn sleep(self: *CounterBackend, _: stdx.time.Duration) void {
        _ = self;
        unreachable;
    }
};

const Controller = init.Controller(CounterBackend);

/// Spin-only backoff. Any non-payload iteration hits the sleep step which
/// then observes `remaining_ns <= 0` and returns `.timeout` — so tests that
/// never satisfy their predicate reach `error.Timeout` after one or two
/// iterations without emitting a `.sleep` step.
fn testBackoffPolicy() stdx.time.Backoff.Policy {
    return .{
        .spin_iterations = 0,
        .yield_iterations = 0,
        .yield = null,
        .initial_wait = stdx.time.Duration.zero,
        .max_wait = stdx.time.Duration.zero,
        .growth_shift = 0,
    };
}

fn makeBackoff() stdx.time.Backoff {
    return stdx.time.Backoff.init(testBackoffPolicy());
}

/// CAP scripted per spec §"Required tests": `CSS.bit0 = 1`, `TO = 20`
/// (10 s worst-case ready budget), `DSTRD = 0`, `MPSMIN = 0`, `MPSMAX = 0`.
fn scriptedCap() Cap {
    return .{
        .mqes = 0x00ff,
        .cqr = 0,
        .ams = 0,
        .to = 20,
        .dstrd = 0,
        .nssrs = 0,
        .css = 0x01,
        .bps = 0,
        .cps = 0,
        .mpsmin = 0,
        .mpsmax = 0,
        .pmrs = 0,
        .cmbs = 0,
        .nsss = 0,
        .crms = 0,
    };
}

/// Register substrate: a caller-owned 4 KiB BAR block with `CAP` pre-written.
const RegSubstrate = struct {
    bar: *align(@alignOf(u64)) [0x1000]u8,
    regs: registers.ControllerRegisters,

    fn init(bar: *align(@alignOf(u64)) [0x1000]u8, cap: Cap) !RegSubstrate {
        @memset(bar, 0);
        const regs = try registers.ControllerRegisters.at(bar);
        regs.storeCap(cap);
        return .{ .bar = bar, .regs = regs };
    }

    /// Rewrite the CSTS dword directly in the register bytes; the poll
    /// predicate re-reads CSTS on every iteration, so scripting between
    /// transition calls flips ready / fatal / SHST.
    fn setCsts(self: RegSubstrate, csts: Csts) void {
        std.mem.writeInt(u32, self.bar[OFF_CSTS..][0..4], csts.raw(), .little);
    }

    fn readCcRaw(self: RegSubstrate) u32 {
        return std.mem.readInt(u32, self.bar[OFF_CC..][0..4], .little);
    }

    fn readAqaRaw(self: RegSubstrate) u32 {
        return std.mem.readInt(u32, self.bar[OFF_AQA..][0..4], .little);
    }

    fn readAsqRaw(self: RegSubstrate) u64 {
        return std.mem.readInt(u64, self.bar[OFF_ASQ..][0..8], .little);
    }

    fn readAcqRaw(self: RegSubstrate) u64 {
        return std.mem.readInt(u64, self.bar[OFF_ACQ..][0..8], .little);
    }
};

/// Admin queue backing storage. Each test owns its buffers so we never
/// alias across tests.
const AdminStorage = struct {
    sq_backing: [ADMIN_DEPTH]Sqe align(@alignOf(Sqe)) = @splat(.{}),
    cq_backing: [ADMIN_DEPTH]Cqe align(@alignOf(Cqe)) = @splat(.{}),
    cid_words: [stdx.bits.word.count(CidAllocator.Word, ADMIN_DEPTH)]CidAllocator.Word = @splat(0),
};

fn makeAdmin(storage: *AdminStorage) !Controller.Admin.Storage {
    return .{
        .sq = try stdx.dma.Buffer(Sqe).init(storage.sq_backing[0..], DmaAddr.fromInt(ASQ_ADDR)),
        .cq = try stdx.dma.Buffer(Cqe).init(storage.cq_backing[0..], DmaAddr.fromInt(ACQ_ADDR)),
        .cid_words = storage.cid_words[0..],
    };
}

fn makeConfig(regs: registers.ControllerRegisters, admin: Controller.Admin.Storage) !Controller.Config {
    return .{
        .registers = regs,
        .admin = admin,
        .page_size = try prp.PageSize.fromBytes(PAGE_SIZE),
        .clock = Controller.Clock.init(.{}),
    };
}

// -----------------------------------------------------------------------------
// init: input validation
// -----------------------------------------------------------------------------

test "unit: controller init rejects UnsupportedCommandSet when CAP.CSS bit 0 is clear" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    var cap = scriptedCap();
    cap.css = 0x02; // NVM bit clear, only "all supported" bit
    const sub = try RegSubstrate.init(&bar, cap);

    var storage: AdminStorage = .{};
    const admin = try makeAdmin(&storage);

    try testing.expectError(error.UnsupportedCommandSet, Controller.init(try makeConfig(sub.regs, admin)));
}

test "unit: controller init rejects PageSizeUnsupported below CAP.MPSMIN" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    var cap = scriptedCap();
    cap.mpsmin = 1; // 8 KiB floor
    cap.mpsmax = 4;
    const sub = try RegSubstrate.init(&bar, cap);

    var storage: AdminStorage = .{};
    const admin = try makeAdmin(&storage);
    const config: Controller.Config = .{
        .registers = sub.regs,
        .admin = admin,
        .page_size = try prp.PageSize.fromBytes(4096), // below 8 KiB floor
        .clock = Controller.Clock.init(.{}),
    };

    try testing.expectError(error.PageSizeUnsupported, Controller.init(config));
}

test "unit: controller init rejects PageSizeUnsupported above CAP.MPSMAX" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    var cap = scriptedCap();
    cap.mpsmin = 0;
    cap.mpsmax = 0; // 4 KiB ceiling
    const sub = try RegSubstrate.init(&bar, cap);

    var storage: AdminStorage = .{};
    const admin = try makeAdmin(&storage);
    const config: Controller.Config = .{
        .registers = sub.regs,
        .admin = admin,
        .page_size = try prp.PageSize.fromBytes(8192), // above 4 KiB ceiling
        .clock = Controller.Clock.init(.{}),
    };

    try testing.expectError(error.PageSizeUnsupported, Controller.init(config));
}

test "unit: controller init rejects AdminPairMismatch when admin SQ and CQ depths differ" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());

    var sq_backing: [8]Sqe align(@alignOf(Sqe)) = @splat(.{});
    var cq_backing: [4]Cqe align(@alignOf(Cqe)) = @splat(.{});
    var cid_words: [stdx.bits.word.count(CidAllocator.Word, 8)]CidAllocator.Word = @splat(0);
    const admin: Controller.Admin.Storage = .{
        .sq = try stdx.dma.Buffer(Sqe).init(sq_backing[0..], DmaAddr.fromInt(ASQ_ADDR)),
        .cq = try stdx.dma.Buffer(Cqe).init(cq_backing[0..], DmaAddr.fromInt(ACQ_ADDR)),
        .cid_words = cid_words[0..],
    };
    try testing.expectError(error.AdminPairMismatch, Controller.init(try makeConfig(sub.regs, admin)));
}

test "unit: controller init propagates QueueDepthOutOfRange from Aqa.fromDepths before enable writes registers" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());

    // Zero-length backing storage still passes the pair-length equality
    // check because sq.len() == cq.len() == 0; `Aqa.fromDepths(0)` is the
    // guardrail.
    var sq_backing: [0]Sqe = undefined;
    var cq_backing: [0]Cqe = undefined;
    var cid_words: [1]CidAllocator.Word = @splat(0);
    const admin: Controller.Admin.Storage = .{
        .sq = try stdx.dma.Buffer(Sqe).init(sq_backing[0..], DmaAddr.fromInt(ASQ_ADDR)),
        .cq = try stdx.dma.Buffer(Cqe).init(cq_backing[0..], DmaAddr.fromInt(ACQ_ADDR)),
        .cid_words = cid_words[0..],
    };
    try testing.expectError(error.QueueDepthOutOfRange, Controller.init(try makeConfig(sub.regs, admin)));

    // And no register bytes past CAP were touched by init.
    try testing.expectEqual(@as(u32, 0), sub.readCcRaw());
    try testing.expectEqual(@as(u32, 0), sub.readAqaRaw());
    try testing.expectEqual(@as(u64, 0), sub.readAsqRaw());
    try testing.expectEqual(@as(u64, 0), sub.readAcqRaw());
}

test "unit: controller init propagates Misaligned from QueueBase.fromDmaAddr for unaligned admin SQ base" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());

    var sq_backing: [ADMIN_DEPTH]Sqe align(@alignOf(Sqe)) = @splat(.{});
    var cq_backing: [ADMIN_DEPTH]Cqe align(@alignOf(Cqe)) = @splat(.{});
    var cid_words: [stdx.bits.word.count(CidAllocator.Word, ADMIN_DEPTH)]CidAllocator.Word = @splat(0);
    const admin: Controller.Admin.Storage = .{
        .sq = try stdx.dma.Buffer(Sqe).init(sq_backing[0..], DmaAddr.fromInt(0x1_0000_0080)), // 128-B aligned, not 4 KiB
        .cq = try stdx.dma.Buffer(Cqe).init(cq_backing[0..], DmaAddr.fromInt(ACQ_ADDR)),
        .cid_words = cid_words[0..],
    };
    try testing.expectError(error.Misaligned, Controller.init(try makeConfig(sub.regs, admin)));
}

test "unit: controller init propagates Misaligned from QueueBase.fromDmaAddr for unaligned admin CQ base" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());

    var sq_backing: [ADMIN_DEPTH]Sqe align(@alignOf(Sqe)) = @splat(.{});
    var cq_backing: [ADMIN_DEPTH]Cqe align(@alignOf(Cqe)) = @splat(.{});
    var cid_words: [stdx.bits.word.count(CidAllocator.Word, ADMIN_DEPTH)]CidAllocator.Word = @splat(0);
    const admin: Controller.Admin.Storage = .{
        .sq = try stdx.dma.Buffer(Sqe).init(sq_backing[0..], DmaAddr.fromInt(ASQ_ADDR)),
        .cq = try stdx.dma.Buffer(Cqe).init(cq_backing[0..], DmaAddr.fromInt(0x2_0000_0080)), // 128-B aligned
        .cid_words = cid_words[0..],
    };
    try testing.expectError(error.Misaligned, Controller.init(try makeConfig(sub.regs, admin)));
}

test "unit: controller init rejects undersized admin CID bitmap before enable writes registers" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());

    var sq_backing: [ADMIN_DEPTH]Sqe align(@alignOf(Sqe)) = @splat(.{});
    var cq_backing: [ADMIN_DEPTH]Cqe align(@alignOf(Cqe)) = @splat(.{});
    var cid_words: [0]CidAllocator.Word = .{}; // deliberately too small for depth 8
    const admin: Controller.Admin.Storage = .{
        .sq = try stdx.dma.Buffer(Sqe).init(sq_backing[0..], DmaAddr.fromInt(ASQ_ADDR)),
        .cq = try stdx.dma.Buffer(Cqe).init(cq_backing[0..], DmaAddr.fromInt(ACQ_ADDR)),
        .cid_words = cid_words[0..],
    };
    try testing.expectError(error.OutOfBounds, Controller.init(try makeConfig(sub.regs, admin)));
    try testing.expectEqual(@as(u32, 0), sub.readCcRaw());
    try testing.expectEqual(@as(u32, 0), sub.readAqaRaw());
    try testing.expectEqual(@as(u64, 0), sub.readAsqRaw());
    try testing.expectEqual(@as(u64, 0), sub.readAcqRaw());
}

test "unit: controller init derives ready_timeout from CAP.TO 500ms units" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    var cap = scriptedCap();
    cap.to = 20; // 20 * 500 ms = 10 s
    const sub = try RegSubstrate.init(&bar, cap);

    var storage: AdminStorage = .{};
    const ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));
    const expected = try stdx.time.Duration.fromMillis(20 * 500);
    try testing.expectEqual(expected.nanos(), ctrl.ready_timeout.nanos());
}

test "unit: controller init derives doorbells from CAP.DSTRD" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    var cap = scriptedCap();
    cap.dstrd = 0; // 4-byte stride: SQ0TDBL at 0x1000
    const sub = try RegSubstrate.init(&bar, cap);

    var storage: AdminStorage = .{};
    const ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));
    try testing.expectEqual(@as(usize, 0x1000), ctrl.doorbells().submissionQueue(.admin).offset());
}

test "unit: controller init honors ready_timeout_override as a verbatim replacement (shortens and lengthens)" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap()); // CAP.TO = 20 -> derived 10 s

    // Shorten: 5 ms override replaces the 10 s derivation verbatim.
    {
        var storage: AdminStorage = .{};
        const short = try stdx.time.Duration.fromMillis(5);
        var config = try makeConfig(sub.regs, try makeAdmin(&storage));
        config.ready_timeout_override = short;
        const ctrl = try Controller.init(config);
        try testing.expectEqual(short.nanos(), ctrl.ready_timeout.nanos());
    }
    // Lengthen: 60 s override replaces the 10 s derivation verbatim.
    {
        var storage: AdminStorage = .{};
        const long = try stdx.time.Duration.fromSeconds(60);
        var config = try makeConfig(sub.regs, try makeAdmin(&storage));
        config.ready_timeout_override = long;
        const ctrl = try Controller.init(config);
        try testing.expectEqual(long.nanos(), ctrl.ready_timeout.nanos());
    }
}

// -----------------------------------------------------------------------------
// reset: idempotence, CC.EN clear, CSTS.RDY polling, timeout
// -----------------------------------------------------------------------------

test "unit: controller reset clears CC.EN when set and polls CSTS.RDY to zero" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());

    // Pre-set CC.EN = 1 so `reset` observes it and writes Cc.disabled().
    sub.regs.storeCc(Cc.nvmEnabled(0));
    // Script CSTS.RDY = 0 so the poll predicate returns payload on iter 0.
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(deadline, &backoff);

    try testing.expectEqual(init.State.disabled, ctrl.state);
    try testing.expectEqual(@as(u32, Cc.disabled().raw()), sub.readCcRaw());
    try testing.expect(!ctrl.admin.ready());
}

test "unit: controller reset is idempotent on double-call when CC.EN already clear" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    // CC starts zero; CSTS.RDY = 0.
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(deadline, &backoff);
    try ctrl.reset(deadline, &backoff); // second call must not fail.

    try testing.expectEqual(init.State.disabled, ctrl.state);
}

test "unit: controller reset is idempotent with no CC write when CC.EN is already clear" {
    // Precondition variant: assert no CC write is observed when CC.EN is
    // already clear on entry, and state transitions to `.disabled`.
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    // Poison CC with a non-zero-but-EN=0 sentinel; reset must NOT overwrite.
    const sentinel: u32 = 0xDEAD_BEE0; // low nibble even -> bit0 (EN) is 0
    std.mem.writeInt(u32, sub.bar[OFF_CC..][0..4], sentinel, .little);
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(deadline, &backoff);

    try testing.expectEqual(sentinel, sub.readCcRaw());
    try testing.expectEqual(init.State.disabled, ctrl.state);
}

test "unit: controller reset clears CC.EN and polls CSTS.RDY to zero and transitions admin.ready() false" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));

    // Drive to ready first so admin.ready() flips true, then observe reset flips it back.
    try ctrl.reset(deadline, &backoff);
    backoff = makeBackoff();
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });
    const enable_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.enable(enable_deadline, &backoff);
    try testing.expect(ctrl.admin.ready());

    // Now the actual reset assertion.
    backoff = makeBackoff();
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });
    const reset_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(reset_deadline, &backoff);

    try testing.expectEqual(@as(u32, Cc.disabled().raw()), sub.readCcRaw());
    try testing.expectEqual(init.State.disabled, ctrl.state);
    try testing.expect(!ctrl.admin.ready());
}

test "unit: controller reset returns Timeout when CSTS.RDY never clears" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.regs.storeCc(Cc.nvmEnabled(0));
    // CSTS.RDY stays 1 forever.
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(1));
    try testing.expectError(error.Timeout, ctrl.reset(deadline, &backoff));
}

// -----------------------------------------------------------------------------
// enable: register bytes, precondition, timeout, CFS
// -----------------------------------------------------------------------------

test "unit: controller enable writes AQA ASQ ACQ and CC with mps css iosqes iocqes" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const reset_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(reset_deadline, &backoff);

    backoff = makeBackoff();
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });
    const enable_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.enable(enable_deadline, &backoff);

    // Exact bytes match the spec-required derivations.
    const expected_aqa = try Aqa.fromDepths(.{ .submission_entries = ADMIN_DEPTH, .completion_entries = ADMIN_DEPTH });
    const expected_asq = try QueueBase.fromDmaAddr(DmaAddr.fromInt(ASQ_ADDR));
    const expected_acq = try QueueBase.fromDmaAddr(DmaAddr.fromInt(ACQ_ADDR));
    try testing.expectEqual(expected_aqa.raw(), sub.readAqaRaw());
    try testing.expectEqual(expected_asq.raw(), sub.readAsqRaw());
    try testing.expectEqual(expected_acq.raw(), sub.readAcqRaw());
    try testing.expectEqual(@as(u32, Cc.nvmEnabled(0).raw()), sub.readCcRaw());

    // And decode CC so failure messages carry field-level detail.
    const observed_cc = Cc.fromRaw(sub.readCcRaw());
    try testing.expectEqual(@as(u1, 1), observed_cc.en);
    try testing.expectEqual(registers.CommandSetSelection.nvm, observed_cc.css);
    try testing.expectEqual(@as(u4, 0), observed_cc.mps); // MPSMIN=0 -> 4 KiB -> shift 0
    try testing.expectEqual(@as(u4, 6), observed_cc.iosqes);
    try testing.expectEqual(@as(u4, 4), observed_cc.iocqes);
}

test "unit: controller enable rejects NotDisabled when state is not disabled" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    // state == .unknown from init; enable must refuse.
    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try testing.expectError(error.NotDisabled, ctrl.enable(deadline, &backoff));
}

test "unit: controller enable returns Timeout when CSTS.RDY never sets" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const reset_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(reset_deadline, &backoff);

    // Do NOT flip CSTS.RDY -> 1: enable must poll to timeout.
    backoff = makeBackoff();
    const enable_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(1));
    try testing.expectError(error.Timeout, ctrl.enable(enable_deadline, &backoff));
}

test "unit: controller enable returns ControllerFatal when CSTS.CFS sets during poll" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const reset_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(reset_deadline, &backoff);

    // Now script CFS = 1 so the enable-side poll observes it on first iteration.
    sub.setCsts(.{ .rdy = 0, .cfs = 1, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    backoff = makeBackoff();
    const enable_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try testing.expectError(error.ControllerFatal, ctrl.enable(enable_deadline, &backoff));
    try testing.expectEqual(init.State.fatal, ctrl.state);
}

test "unit: controller admin ready returns false before enable and true after enable success" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));
    try testing.expect(!ctrl.admin.ready()); // .unknown

    var backoff = makeBackoff();
    const reset_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(reset_deadline, &backoff);
    try testing.expect(!ctrl.admin.ready()); // .disabled

    backoff = makeBackoff();
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });
    const enable_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.enable(enable_deadline, &backoff);
    try testing.expect(ctrl.admin.ready());
}

test "unit: controller enable transitions admin.ready() true when CSTS.RDY sets" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const reset_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(reset_deadline, &backoff);

    backoff = makeBackoff();
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });
    const enable_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.enable(enable_deadline, &backoff);

    try testing.expect(ctrl.admin.ready());
    try testing.expectEqual(ids.Qid.admin, ctrl.admin.sq().qid);
    try testing.expectEqual(ids.Qid.admin, ctrl.admin.cq().qid);
}

// -----------------------------------------------------------------------------
// shutdown
// -----------------------------------------------------------------------------

fn driveToReady(sub: RegSubstrate, ctrl: *Controller) !void {
    var backoff = makeBackoff();
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });
    const reset_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(reset_deadline, &backoff);

    backoff = makeBackoff();
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });
    const enable_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.enable(enable_deadline, &backoff);
}

test "unit: controller shutdown normal sets CC.SHN to 01b and polls SHST to complete" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));
    try driveToReady(sub, &ctrl);

    // Flip SHST -> complete so pollShutdown returns payload on first iter.
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .complete, .nssro = 0, .pp = 0, .st = 0 });

    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.shutdown(.normal, deadline, &backoff);

    const observed_cc = Cc.fromRaw(sub.readCcRaw());
    try testing.expectEqual(ShutdownNotification.normal, observed_cc.shn);
    try testing.expectEqual(init.State.shutdown_complete, ctrl.state);
}

test "unit: controller shutdown abrupt sets CC.SHN to 10b and polls SHST to complete" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));
    try driveToReady(sub, &ctrl);

    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .complete, .nssro = 0, .pp = 0, .st = 0 });

    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.shutdown(.abrupt, deadline, &backoff);

    const observed_cc = Cc.fromRaw(sub.readCcRaw());
    try testing.expectEqual(ShutdownNotification.abrupt, observed_cc.shn);
    try testing.expectEqual(init.State.shutdown_complete, ctrl.state);
}

test "unit: controller shutdown returns NotReady when state is not ready" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    // State is .unknown: shutdown must refuse.
    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try testing.expectError(error.NotReady, ctrl.shutdown(.normal, deadline, &backoff));

    // Even after reset to .disabled: still not ready.
    backoff = makeBackoff();
    const reset_deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(reset_deadline, &backoff);
    backoff = makeBackoff();
    try testing.expectError(error.NotReady, ctrl.shutdown(.normal, deadline, &backoff));
}

test "unit: controller shutdown returns Timeout when SHST never reports complete" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));
    try driveToReady(sub, &ctrl);

    // SHST stays .normal: pollShutdown never sees .complete.
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(1));
    try testing.expectError(error.Timeout, ctrl.shutdown(.normal, deadline, &backoff));
}

test "unit: controller shutdown preserves admin.ready() true for final completion drain" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));
    try driveToReady(sub, &ctrl);
    try testing.expect(ctrl.admin.ready());

    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .complete, .nssro = 0, .pp = 0, .st = 0 });
    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.shutdown(.normal, deadline, &backoff);

    try testing.expectEqual(init.State.shutdown_complete, ctrl.state);
    try testing.expect(ctrl.admin.ready());
    // And the pair is still usable through the accessors post-shutdown.
    try testing.expectEqual(ids.Qid.admin, ctrl.admin.sq().qid);
    try testing.expectEqual(ids.Qid.admin, ctrl.admin.cq().qid);
}

// -----------------------------------------------------------------------------
// pollReady barrier check
// -----------------------------------------------------------------------------

test "unit: controller pollReady honors mmio.acquire ordering after each CSTS load" {
    // Behavioral check: the CSTS load path composes `stdx.barrier.mmio.acquire()`
    // which lowers to `lfence` on x86_64 and to `dmb ishld` on aarch64. We
    // exercise the code path once against an immediately-ready CSTS and
    // assert the observable transition. Codegen inspection is out of scope
    // for host unit tests.
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const deadline = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.pollReady(true, deadline, &backoff); // target = ready; predicate matches on iter 0
    // pollReady is a wait primitive; it does not itself set `state`. The
    // observable behavior is a successful (`void`) return.
}

// -----------------------------------------------------------------------------
// Roundtrips: state and admin.ready() through the full lifecycle
// -----------------------------------------------------------------------------

test "roundtrip: controller reset then enable then reset transitions through disabled ready disabled and admin.ready() follows" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const d1 = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(d1, &backoff);
    try testing.expectEqual(init.State.disabled, ctrl.state);
    try testing.expect(!ctrl.admin.ready());

    backoff = makeBackoff();
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });
    const d2 = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.enable(d2, &backoff);
    try testing.expectEqual(init.State.ready, ctrl.state);
    try testing.expect(ctrl.admin.ready());

    backoff = makeBackoff();
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });
    const d3 = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(d3, &backoff);
    try testing.expectEqual(init.State.disabled, ctrl.state);
    try testing.expect(!ctrl.admin.ready());
}

test "roundtrip: controller reset then enable then shutdown normal transitions through disabled ready shutdown_complete" {
    var bar: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const sub = try RegSubstrate.init(&bar, scriptedCap());
    sub.setCsts(.{ .rdy = 0, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });

    var storage: AdminStorage = .{};
    var ctrl = try Controller.init(try makeConfig(sub.regs, try makeAdmin(&storage)));

    var backoff = makeBackoff();
    const d1 = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.reset(d1, &backoff);
    try testing.expectEqual(init.State.disabled, ctrl.state);

    backoff = makeBackoff();
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .normal, .nssro = 0, .pp = 0, .st = 0 });
    const d2 = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.enable(d2, &backoff);
    try testing.expectEqual(init.State.ready, ctrl.state);

    backoff = makeBackoff();
    sub.setCsts(.{ .rdy = 1, .cfs = 0, .shst = .complete, .nssro = 0, .pp = 0, .st = 0 });
    const d3 = try stdx.time.Deadline.now(&ctrl.clock, try stdx.time.Duration.fromMillis(100));
    try ctrl.shutdown(.normal, d3, &backoff);
    try testing.expectEqual(init.State.shutdown_complete, ctrl.state);
    try testing.expect(ctrl.admin.ready());
}
