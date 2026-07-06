//! Tests for src/core/registers.zig. Spec: docs/specs/core/registers.md.

const std = @import("std");

const nvme = @import("nvme");

const regs_mod = nvme.core.registers;
const DmaAddr = @TypeOf(regs_mod.QueueBase.fromRaw(0).dmaAddr());

test "unit: registers block offsets match NVMe controller properties" {
    try std.testing.expectEqual(@as(usize, 0x0000), @offsetOf(regs_mod.RegisterBlock, "cap"));
    try std.testing.expectEqual(@as(usize, 0x0008), @offsetOf(regs_mod.RegisterBlock, "vs"));
    try std.testing.expectEqual(@as(usize, 0x000c), @offsetOf(regs_mod.RegisterBlock, "intms"));
    try std.testing.expectEqual(@as(usize, 0x0010), @offsetOf(regs_mod.RegisterBlock, "intmc"));
    try std.testing.expectEqual(@as(usize, 0x0014), @offsetOf(regs_mod.RegisterBlock, "cc"));
    try std.testing.expectEqual(@as(usize, 0x001c), @offsetOf(regs_mod.RegisterBlock, "csts"));
    try std.testing.expectEqual(@as(usize, 0x0020), @offsetOf(regs_mod.RegisterBlock, "nssr"));
    try std.testing.expectEqual(@as(usize, 0x0024), @offsetOf(regs_mod.RegisterBlock, "aqa"));
    try std.testing.expectEqual(@as(usize, 0x0028), @offsetOf(regs_mod.RegisterBlock, "asq"));
    try std.testing.expectEqual(@as(usize, 0x0030), @offsetOf(regs_mod.RegisterBlock, "acq"));
}

test "unit: registers block size ends at doorbell base" {
    try std.testing.expectEqual(@as(usize, 0x1000), @sizeOf(regs_mod.RegisterBlock));
    try std.testing.expectEqual(regs_mod.doorbell_base_offset, @sizeOf(regs_mod.RegisterBlock));
}

test "unit: registers at rejects short BAR window" {
    var short: [0x0fff]u8 align(@alignOf(u64)) = @splat(0);
    try std.testing.expectError(error.OutOfBounds, regs_mod.ControllerRegisters.at(&short));
}

test "unit: cap decodes queue entries timeout doorbell stride and page sizes" {
    const sample: regs_mod.Cap = .{
        .mqes = 0x00ff,
        .cqr = 0,
        .ams = 0,
        .to = 20,
        .dstrd = 2,
        .nssrs = 0,
        .css = 0x01,
        .bps = 0,
        .cps = 0,
        .mpsmin = 0,
        .mpsmax = 4,
        .pmrs = 0,
        .cmbs = 0,
        .nsss = 0,
        .crms = 0,
    };
    const round = regs_mod.Cap.fromRaw(sample.raw());
    try std.testing.expectEqual(@as(u32, 256), round.maxQueueEntries());
    try std.testing.expectEqual(@as(u8, 20), round.readyTimeoutUnits500ms());
    try std.testing.expectEqual(@as(usize, 16), round.doorbellStrideBytes());
    try std.testing.expectEqual(@as(usize, 4096), round.minPageSizeBytes());
    try std.testing.expectEqual(@as(usize, 65536), round.maxPageSizeBytes());
}

test "unit: cap detects NVM command set support" {
    const with_nvm: regs_mod.Cap = .{
        .mqes = 0,
        .cqr = 0,
        .ams = 0,
        .to = 0,
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
    const without_nvm: regs_mod.Cap = .{
        .mqes = 0,
        .cqr = 0,
        .ams = 0,
        .to = 0,
        .dstrd = 0,
        .nssrs = 0,
        .css = 0x02,
        .bps = 0,
        .cps = 0,
        .mpsmin = 0,
        .mpsmax = 0,
        .pmrs = 0,
        .cmbs = 0,
        .nsss = 0,
        .crms = 0,
    };
    try std.testing.expectEqual(true, with_nvm.supportsNvmCommandSet());
    try std.testing.expectEqual(false, without_nvm.supportsNvmCommandSet());
}

test "unit: version decodes major minor tertiary" {
    const v: regs_mod.Version = .{ .tertiary = 0, .minor = 4, .major = 1 };
    try std.testing.expectEqual(@as(u32, 0x00010400), v.raw());
    const decoded = regs_mod.Version.fromRaw(0x00020100);
    try std.testing.expectEqual(@as(u16, 2), decoded.major);
    try std.testing.expectEqual(@as(u8, 1), decoded.minor);
    try std.testing.expectEqual(@as(u8, 0), decoded.tertiary);
}

test "unit: cc nvm enabled encodes NVM CSS and queue entry sizes" {
    const c0 = regs_mod.Cc.nvmEnabled(0);
    try std.testing.expectEqual(@as(u1, 1), c0.en);
    try std.testing.expectEqual(regs_mod.CommandSetSelection.nvm, c0.css);
    try std.testing.expectEqual(@as(u4, 0), c0.mps);
    try std.testing.expectEqual(regs_mod.Arbitration.round_robin, c0.ams);
    try std.testing.expectEqual(regs_mod.ShutdownNotification.none, c0.shn);
    try std.testing.expectEqual(@as(u4, 6), c0.iosqes);
    try std.testing.expectEqual(@as(u4, 4), c0.iocqes);
    try std.testing.expectEqual(@as(u1, 0), c0.crime);

    const c4 = regs_mod.Cc.nvmEnabled(4);
    try std.testing.expectEqual(@as(u4, 4), c4.mps);
    try std.testing.expectEqual(@as(u1, 1), c4.en);
    try std.testing.expectEqual(regs_mod.CommandSetSelection.nvm, c4.css);
    try std.testing.expectEqual(regs_mod.Arbitration.round_robin, c4.ams);
    try std.testing.expectEqual(regs_mod.ShutdownNotification.none, c4.shn);
    try std.testing.expectEqual(@as(u4, 6), c4.iosqes);
    try std.testing.expectEqual(@as(u4, 4), c4.iocqes);
    try std.testing.expectEqual(@as(u1, 0), c4.crime);
}

test "unit: cc shutdown notification updates only SHN" {
    const start = regs_mod.Cc.nvmEnabled(0);
    const next = start.withShutdown(.abrupt);
    try std.testing.expectEqual(regs_mod.ShutdownNotification.abrupt, next.shn);
    try std.testing.expectEqual(start.en, next.en);
    try std.testing.expectEqual(start.css, next.css);
    try std.testing.expectEqual(start.mps, next.mps);
    try std.testing.expectEqual(start.ams, next.ams);
    try std.testing.expectEqual(start.iosqes, next.iosqes);
    try std.testing.expectEqual(start.iocqes, next.iocqes);
    try std.testing.expectEqual(start.crime, next.crime);
}

test "unit: csts decodes ready fatal and shutdown status" {
    const a: regs_mod.Csts = .{
        .rdy = 1,
        .cfs = 0,
        .shst = .occurring,
        .nssro = 0,
        .pp = 0,
        .st = 0,
    };
    try std.testing.expectEqual(true, a.ready());
    try std.testing.expectEqual(false, a.fatal());
    try std.testing.expectEqual(regs_mod.ShutdownStatus.occurring, a.shst);

    const b: regs_mod.Csts = .{
        .rdy = 0,
        .cfs = 1,
        .shst = .complete,
        .nssro = 0,
        .pp = 0,
        .st = 0,
    };
    try std.testing.expectEqual(false, b.ready());
    try std.testing.expectEqual(true, b.fatal());
    try std.testing.expectEqual(regs_mod.ShutdownStatus.complete, b.shst);
}

test "unit: aqa encodes named one-based depths as zero-based fields" {
    const one = try regs_mod.Aqa.fromDepths(.{ .submission_entries = 1, .completion_entries = 1 });
    try std.testing.expectEqual(@as(u12, 0), one.asqs);
    try std.testing.expectEqual(@as(u12, 0), one.acqs);

    const max = try regs_mod.Aqa.fromDepths(.{ .submission_entries = 4096, .completion_entries = 4096 });
    try std.testing.expectEqual(@as(u12, 0xfff), max.asqs);
    try std.testing.expectEqual(@as(u12, 0xfff), max.acqs);

    const asymmetric = try regs_mod.Aqa.fromDepths(.{ .submission_entries = 64, .completion_entries = 128 });
    try std.testing.expectEqual(@as(u12, 63), asymmetric.asqs);
    try std.testing.expectEqual(@as(u12, 127), asymmetric.acqs);
}

test "unit: aqa rejects zero and too-large depths" {
    try std.testing.expectError(
        error.QueueDepthOutOfRange,
        regs_mod.Aqa.fromDepths(.{ .submission_entries = 0, .completion_entries = 64 }),
    );
    try std.testing.expectError(
        error.QueueDepthOutOfRange,
        regs_mod.Aqa.fromDepths(.{ .submission_entries = 64, .completion_entries = 0 }),
    );
    try std.testing.expectError(
        error.QueueDepthOutOfRange,
        regs_mod.Aqa.fromDepths(.{ .submission_entries = 4097, .completion_entries = 64 }),
    );
    try std.testing.expectError(
        error.QueueDepthOutOfRange,
        regs_mod.Aqa.fromDepths(.{ .submission_entries = 64, .completion_entries = 4097 }),
    );
}

test "unit: queue base rejects unaligned DMA address" {
    try std.testing.expectError(
        error.Misaligned,
        regs_mod.QueueBase.fromDmaAddr(DmaAddr.fromInt(0x1000 | 0x1)),
    );
    try std.testing.expectError(
        error.Misaligned,
        regs_mod.QueueBase.fromDmaAddr(DmaAddr.fromInt(0x800)),
    );
}

test "unit: queue base roundtrips aligned DMA address" {
    const addr = DmaAddr.fromInt(0x0000_0000_1000_2000);
    const qb = try regs_mod.QueueBase.fromDmaAddr(addr);
    try std.testing.expectEqual(addr.raw(), qb.raw());
    try std.testing.expectEqual(addr.raw(), qb.dmaAddr().raw());
}

test "unit: controller registers storeCap writes CAP through the mmio window and cap reads it back" {
    var bar_bytes: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try regs_mod.ControllerRegisters.at(&bar_bytes);
    const v: regs_mod.Cap = .{
        .mqes = 0x00ff,
        .cqr = 0,
        .ams = 0,
        .to = 20,
        .dstrd = 2,
        .nssrs = 0,
        .css = 0x01,
        .bps = 0,
        .cps = 0,
        .mpsmin = 0,
        .mpsmax = 4,
        .pmrs = 0,
        .cmbs = 0,
        .nsss = 0,
        .crms = 0,
    };
    regs.storeCap(v);
    try std.testing.expectEqual(v.raw(), regs.cap().raw());
    try std.testing.expectEqual(v.raw(), std.mem.readInt(u64, bar_bytes[0..8], .little));
}

test "unit: controller registers storeVersion writes VS and version reads it back" {
    var bar_bytes: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try regs_mod.ControllerRegisters.at(&bar_bytes);
    const v: regs_mod.Version = .{ .tertiary = 0, .minor = 4, .major = 1 };
    regs.storeVersion(v);
    try std.testing.expectEqual(v.raw(), regs.version().raw());
    try std.testing.expectEqual(v.raw(), std.mem.readInt(u32, bar_bytes[0x08..0x0c], .little));
}

test "unit: controller registers storeCsts writes CSTS and csts reads it back" {
    var bar_bytes: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try regs_mod.ControllerRegisters.at(&bar_bytes);
    const v: regs_mod.Csts = .{
        .rdy = 1,
        .cfs = 0,
        .shst = .occurring,
        .nssro = 0,
        .pp = 0,
        .st = 0,
    };
    regs.storeCsts(v);
    try std.testing.expectEqual(v.raw(), regs.csts().raw());
    try std.testing.expectEqual(v.raw(), std.mem.readInt(u32, bar_bytes[0x1c..0x20], .little));
}

test "unit: controller registers aqa reads back what storeAqa wrote" {
    var bar_bytes: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try regs_mod.ControllerRegisters.at(&bar_bytes);
    const v = try regs_mod.Aqa.fromDepths(.{ .submission_entries = 64, .completion_entries = 128 });
    regs.storeAqa(v);
    try std.testing.expectEqual(v.raw(), regs.aqa().raw());
}

test "unit: controller registers asq reads back what storeAsq wrote" {
    var bar_bytes: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try regs_mod.ControllerRegisters.at(&bar_bytes);
    const v = try regs_mod.QueueBase.fromDmaAddr(DmaAddr.fromInt(0x0000_0000_2000_0000));
    regs.storeAsq(v);
    try std.testing.expectEqual(v.raw(), regs.asq().raw());
    try std.testing.expectEqual(@as(u64, 0x0000_0000_2000_0000), regs.asq().dmaAddr().raw());
}

test "unit: controller registers acq reads back what storeAcq wrote" {
    var bar_bytes: [0x1000]u8 align(@alignOf(u64)) = @splat(0);
    const regs = try regs_mod.ControllerRegisters.at(&bar_bytes);
    const v = try regs_mod.QueueBase.fromDmaAddr(DmaAddr.fromInt(0x0000_0000_3000_0000));
    regs.storeAcq(v);
    try std.testing.expectEqual(v.raw(), regs.acq().raw());
    try std.testing.expectEqual(@as(u64, 0x0000_0000_3000_0000), regs.acq().dmaAddr().raw());
}
