//! NVMe controller register block. Spec: docs/specs/core/registers.md.

const std = @import("std");

const stdx = @import("stdx");

const DMAAddr = stdx.addr.DMAAddr;
const MMIO = stdx.io.MMIO;
const Window = MMIO.Window64;
const Reg32 = MMIO.Register(u32);
const Reg64 = MMIO.Register(u64);

/// Byte offset of the first doorbell (`SQ0TDBL`) within the register block.
pub const doorbell_base_offset: usize = 0x1000;

/// Typed accessor over a caller-owned MMIO window. Loads and stores go
/// through `stdx.io.MMIO.Register(T)` volatile lanes; construction only
/// validates that the window is large enough for the fixed register block.
pub const ControllerRegisters = struct {
    block: *volatile RegisterBlock,
    window: Window,

    pub const Error = error{OutOfBounds};

    pub fn at(bytes: []align(Window.min_align) volatile u8) Error!ControllerRegisters {
        if (bytes.len < doorbell_base_offset) return error.OutOfBounds;

        return .{
            .block = @ptrCast(bytes.ptr),
            .window = Window.wrap(bytes),
        };
    }

    pub fn mmioWindow(self: ControllerRegisters) Window {
        return self.window;
    }

    pub fn cap(self: ControllerRegisters) Cap {
        return Cap.fromRaw(self.block.cap.load());
    }

    pub fn storeCap(self: ControllerRegisters, value: Cap) void {
        self.block.cap.store(value.raw());
    }

    pub fn version(self: ControllerRegisters) Version {
        return Version.fromRaw(self.block.vs.load());
    }

    pub fn storeVersion(self: ControllerRegisters, value: Version) void {
        self.block.vs.store(value.raw());
    }

    pub fn cc(self: ControllerRegisters) Cc {
        return Cc.fromRaw(self.block.cc.load());
    }

    pub fn storeCc(self: ControllerRegisters, value: Cc) void {
        self.block.cc.store(value.raw());
    }

    pub fn csts(self: ControllerRegisters) Csts {
        return Csts.fromRaw(self.block.csts.load());
    }

    pub fn storeCsts(self: ControllerRegisters, value: Csts) void {
        self.block.csts.store(value.raw());
    }

    pub fn aqa(self: ControllerRegisters) Aqa {
        return Aqa.fromRaw(self.block.aqa.load());
    }

    pub fn storeAqa(self: ControllerRegisters, value: Aqa) void {
        self.block.aqa.store(value.raw());
    }

    pub fn asq(self: ControllerRegisters) QueueBase {
        return QueueBase.fromRaw(self.block.asq.load());
    }

    pub fn storeAsq(self: ControllerRegisters, value: QueueBase) void {
        self.block.asq.store(value.raw());
    }

    pub fn acq(self: ControllerRegisters) QueueBase {
        return QueueBase.fromRaw(self.block.acq.load());
    }

    pub fn storeAcq(self: ControllerRegisters, value: QueueBase) void {
        self.block.acq.store(value.raw());
    }
};

/// Wire-order overlay of the fixed 0x1000-byte NVMe controller register
/// block. Direct access is `volatile`; callers go through
/// `ControllerRegisters` methods.
pub const RegisterBlock = extern struct {
    cap: Reg64,
    vs: Reg32,
    intms: Reg32,
    intmc: Reg32,
    cc: Reg32,
    _reserved_18: [4]u8,
    csts: Reg32,
    nssr: Reg32,
    aqa: Reg32,
    asq: Reg64,
    acq: Reg64,
    _reserved_38_to_1000: [doorbell_base_offset - 0x38]u8,

    const Self = @This();

    comptime {
        std.debug.assert(@offsetOf(Self, "cap") == 0x0000);
        std.debug.assert(@offsetOf(Self, "vs") == 0x0008);
        std.debug.assert(@offsetOf(Self, "intms") == 0x000c);
        std.debug.assert(@offsetOf(Self, "intmc") == 0x0010);
        std.debug.assert(@offsetOf(Self, "cc") == 0x0014);
        std.debug.assert(@offsetOf(Self, "csts") == 0x001c);
        std.debug.assert(@offsetOf(Self, "nssr") == 0x0020);
        std.debug.assert(@offsetOf(Self, "aqa") == 0x0024);
        std.debug.assert(@offsetOf(Self, "asq") == 0x0028);
        std.debug.assert(@offsetOf(Self, "acq") == 0x0030);
        std.debug.assert(@sizeOf(Self) == doorbell_base_offset);
        std.debug.assert(@alignOf(Self) == Window.min_align);
    }
};

/// Controller Capabilities (`CAP`, 64-bit). Read-only wire lane.
pub const Cap = packed struct(u64) {
    mqes: u16,
    cqr: u1,
    ams: u2,
    reserved_19: u5 = 0,
    to: u8,
    dstrd: u4,
    nssrs: u1,
    css: u8,
    bps: u1,
    cps: u2,
    mpsmin: u4,
    mpsmax: u4,
    pmrs: u1,
    cmbs: u1,
    nsss: u1,
    crms: u2,
    reserved_61: u3 = 0,

    pub fn fromRaw(value: u64) Cap {
        return @bitCast(value);
    }

    pub fn raw(self: Cap) u64 {
        return @bitCast(self);
    }

    /// MQES is 0-based on the wire; return the 1-based entry count.
    pub fn maxQueueEntries(self: Cap) u32 {
        return @as(u32, self.mqes) + 1;
    }

    pub fn readyTimeoutUnits500ms(self: Cap) u8 {
        return self.to;
    }

    /// Doorbell stride in bytes: `4 << DSTRD`. Powers of two from 4 to 512.
    pub fn doorbellStrideBytes(self: Cap) usize {
        const shift: u6 = 2 + @as(u6, self.dstrd);
        return @as(usize, 1) << shift;
    }

    /// Memory page size floor in bytes: `1 << (12 + MPSMIN)`.
    pub fn minPageSizeBytes(self: Cap) usize {
        const shift: u6 = 12 + @as(u6, self.mpsmin);
        return @as(usize, 1) << shift;
    }

    /// Memory page size ceiling in bytes: `1 << (12 + MPSMAX)`.
    pub fn maxPageSizeBytes(self: Cap) usize {
        const shift: u6 = 12 + @as(u6, self.mpsmax);
        return @as(usize, 1) << shift;
    }

    pub fn supportsNvmCommandSet(self: Cap) bool {
        return (self.css & 0x01) != 0;
    }

    comptime {
        std.debug.assert(@bitSizeOf(Cap) == 64);
        std.debug.assert(@sizeOf(Cap) == @sizeOf(u64));
        std.debug.assert(@alignOf(Cap) == @alignOf(u64));
    }
};

/// Version (`VS`, 32-bit). Read-only wire lane.
pub const Version = packed struct(u32) {
    tertiary: u8,
    minor: u8,
    major: u16,

    pub fn fromRaw(value: u32) Version {
        return @bitCast(value);
    }

    pub fn raw(self: Version) u32 {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert(@bitSizeOf(Version) == 32);
        std.debug.assert(@sizeOf(Version) == @sizeOf(u32));
        std.debug.assert(@alignOf(Version) == @alignOf(u32));
    }
};

/// Command Set Selection (`CC.CSS`). Non-exhaustive: reserved encodings pass
/// through the wire lane unchanged.
pub const CommandSetSelection = enum(u3) {
    nvm = 0,
    all_supported = 6,
    admin_only = 7,
    _,
};

/// Arbitration Mechanism Selected (`CC.AMS`). Non-exhaustive.
pub const Arbitration = enum(u3) {
    round_robin = 0,
    weighted_round_robin_urgent = 1,
    vendor_specific = 7,
    _,
};

/// Shutdown Notification (`CC.SHN`). Non-exhaustive.
pub const ShutdownNotification = enum(u2) {
    none = 0,
    normal = 1,
    abrupt = 2,
    _,
};

/// Controller Configuration (`CC`, 32-bit). Read-write; every field defaults
/// to a disabled controller ready for `nvmEnabled` bring-up.
pub const Cc = packed struct(u32) {
    en: u1 = 0,
    reserved_1: u3 = 0,
    css: CommandSetSelection = .nvm,
    mps: u4 = 0,
    ams: Arbitration = .round_robin,
    shn: ShutdownNotification = .none,
    iosqes: u4 = 6,
    iocqes: u4 = 4,
    crime: u1 = 0,
    reserved_25: u7 = 0,

    pub fn fromRaw(value: u32) Cc {
        return @bitCast(value);
    }

    pub fn raw(self: Cc) u32 {
        return @bitCast(self);
    }

    pub fn disabled() Cc {
        return .{ .en = 0 };
    }

    pub fn nvmEnabled(mps: u4) Cc {
        return .{
            .en = 1,
            .css = .nvm,
            .mps = mps,
            .ams = .round_robin,
            .shn = .none,
            .iosqes = 6,
            .iocqes = 4,
            .crime = 0,
        };
    }

    pub fn withShutdown(self: Cc, shn: ShutdownNotification) Cc {
        var next = self;
        next.shn = shn;
        return next;
    }

    comptime {
        std.debug.assert(@bitSizeOf(Cc) == 32);
        std.debug.assert(@sizeOf(Cc) == @sizeOf(u32));
        std.debug.assert(@alignOf(Cc) == @alignOf(u32));
    }
};

/// Shutdown Status (`CSTS.SHST`). Non-exhaustive.
pub const ShutdownStatus = enum(u2) {
    normal = 0,
    occurring = 1,
    complete = 2,
    _,
};

/// Controller Status (`CSTS`, 32-bit). Read-only wire lane.
pub const Csts = packed struct(u32) {
    rdy: u1,
    cfs: u1,
    shst: ShutdownStatus,
    nssro: u1,
    pp: u1,
    st: u1,
    reserved_7: u25 = 0,

    pub fn fromRaw(value: u32) Csts {
        return @bitCast(value);
    }

    pub fn raw(self: Csts) u32 {
        return @bitCast(self);
    }

    pub fn ready(self: Csts) bool {
        return self.rdy != 0;
    }

    pub fn fatal(self: Csts) bool {
        return self.cfs != 0;
    }

    comptime {
        std.debug.assert(@bitSizeOf(Csts) == 32);
        std.debug.assert(@sizeOf(Csts) == @sizeOf(u32));
        std.debug.assert(@alignOf(Csts) == @alignOf(u32));
    }
};

/// Admin Queue Attributes (`AQA`, 32-bit). Both queue depths are 0-based on
/// the wire; `fromDepths` accepts the 1-based entry count callers work in.
pub const Aqa = packed struct(u32) {
    asqs: u12,
    reserved_12: u4 = 0,
    acqs: u12,
    reserved_28: u4 = 0,

    pub const Error = error{QueueDepthOutOfRange};

    pub const Depths = struct {
        submission_entries: u16,
        completion_entries: u16,
    };

    pub fn fromRaw(value: u32) Aqa {
        return @bitCast(value);
    }

    pub fn raw(self: Aqa) u32 {
        return @bitCast(self);
    }

    pub fn fromDepths(depths: Depths) Error!Aqa {
        return .{
            .asqs = try encodeDepth(depths.submission_entries),
            .acqs = try encodeDepth(depths.completion_entries),
        };
    }

    fn encodeDepth(entries: u16) Error!u12 {
        if (entries == 0 or entries > 4096) return error.QueueDepthOutOfRange;
        return @intCast(entries - 1);
    }

    comptime {
        std.debug.assert(@bitSizeOf(Aqa) == 32);
        std.debug.assert(@sizeOf(Aqa) == @sizeOf(u32));
        std.debug.assert(@alignOf(Aqa) == @alignOf(u32));
    }
};

/// 64-bit queue base register (`ASQ` / `ACQ`). The controller requires
/// 4 KiB alignment; the low 12 bits are always zero on the wire.
pub const QueueBase = packed struct(u64) {
    reserved_0: u12 = 0,
    base: u52,

    pub const alignment: u64 = 4096;
    pub const Error = error{Misaligned};

    pub fn fromRaw(value: u64) QueueBase {
        return @bitCast(value);
    }

    pub fn raw(self: QueueBase) u64 {
        return @bitCast(self);
    }

    pub fn fromDmaAddr(addr: DMAAddr) Error!QueueBase {
        if (!addr.isAligned(alignment)) return error.Misaligned;
        return @bitCast(addr.raw());
    }

    pub fn dmaAddr(self: QueueBase) DMAAddr {
        return DMAAddr.fromInt(self.raw());
    }

    comptime {
        std.debug.assert(@bitSizeOf(QueueBase) == 64);
        std.debug.assert(@sizeOf(QueueBase) == @sizeOf(u64));
        std.debug.assert(@alignOf(QueueBase) == @alignOf(u64));
    }
};
