# Core controller registers

Status: Approved.

`[znvme]` `ControllerRegisters` is znvme's borrowed view over the NVMe controller MMIO register window. It owns the fixed controller-register block layout, typed register-value wrappers, and accessors for first-slice initialization fields.

`[znvme]` The caller owns PCI enumeration, BAR discovery, and MMIO mapping. The caller passes znvme a `[]align(8) volatile u8` window over BAR0/1.

## Owned scope

`[znvme]` This spec owns:

- `[znvme]` `ControllerRegisters`, a borrowed controller-register view over caller-owned MMIO bytes;
- `[znvme]` `RegisterBlock`, an `extern struct` overlay from offset `0x0000` through the start of the doorbell region at `0x1000`;
- `[znvme]` offset, size, and alignment assertions for the fixed register block;
- `[znvme]` type-owned size, alignment, and bit-size assertions for `CAP`, `VS`, `CC`, `CSTS`, `AQA`, `ASQ`, and `ACQ` value wrappers;
- `[znvme]` read methods for `CAP`, `VS`, `CC`, `CSTS`, `AQA`, `ASQ`, and `ACQ`;
- `[znvme]` write methods for `CAP`, `VS`, `CC`, `CSTS`, `AQA`, `ASQ`, and `ACQ`;
- `[znvme]` exposure of the underlying `stdx.io.Mmio.Window` for the doorbell spec.

## Deferred scope and non-goals

`[znvme]` This spec does not own:

- `[znvme]` SQ/CQ doorbell offset math (`docs/specs/core/doorbell.md`);
- `[znvme]` controller reset/enable/shutdown sequencing (`docs/specs/controller/init.md`);
- `[znvme]` interrupt behavior or use of `INTMS` / `INTMC`;
- `[znvme]` NVM Subsystem Reset behavior through `NSSR`;
- `[znvme]` Controller Memory Buffer, Persistent Memory Region, boot-partition, NSSD, CRTO, or vendor-specific registers;
- `[znvme]` generic read-modify-write helpers;
- `[znvme]` hardware ordering barriers;
- `[znvme]` PCI/ECAM/BAR discovery or MMIO mapping;
- `[znvme]` big-endian MMIO compatibility.

`[znvme]` Optional standard registers between `0x0038` and `0x0068` remain reserved padding until a consuming spec promotes them.

## Register map

`[nvme]` First-slice fixed offsets:

| Offset | Register | Width | znvme behavior |
| ---: | --- | ---: | --- |
| `0x0000` | `CAP` | 64 | read through `cap()`, write through `storeCap()` |
| `0x0008` | `VS` | 32 | read through `version()`, write through `storeVersion()` |
| `0x000c` | `INTMS` | 32 | offset asserted only |
| `0x0010` | `INTMC` | 32 | offset asserted only |
| `0x0014` | `CC` | 32 | read through `cc()`, write through `storeCc()` |
| `0x0018` | reserved | 32 | not surfaced |
| `0x001c` | `CSTS` | 32 | read through `csts()`, write through `storeCsts()` |
| `0x0020` | `NSSR` | 32 | offset asserted only |
| `0x0024` | `AQA` | 32 | read through `aqa()`, write through `storeAqa()` |
| `0x0028` | `ASQ` | 64 | read through `asq()`, write through `storeAsq()` |
| `0x0030` | `ACQ` | 64 | read through `acq()`, write through `storeAcq()` |
| `0x0038..0x0fff` | reserved / optional registers | byte padding | not surfaced |
| `0x1000` | doorbell region start | dynamic | exposed to `doorbell.md` via `mmioWindow()` |

`[znvme]` The fixed overlay ends exactly at `0x1000`. Doorbell registers are not embedded in `RegisterBlock`; their offsets depend on `CAP.DSTRD` and queue identity.

## stdx composition

- `[znvme]` `RegisterBlock` uses `stdx.io.Mmio.Register(u32)` and `stdx.io.Mmio.Register(u64)` lanes.
- `[znvme]` `ControllerRegisters` stores a `stdx.io.Mmio.Window` so `core/doorbell.zig` can request runtime-computed `u32` doorbell lanes.
- `[znvme]` `QueueBase.fromDmaAddr` consumes `stdx.addr.DmaAddr`; no physical-address type appears in znvme's register API.
- `[znvme]` `stdx.barrier.mmio.*` is not called here. Ordering belongs to the controller-init and doorbell specs that know the protocol transition.

`[znvme]` `stdx.io.Mmio.Register` access provides volatile compiler ordering only. It does not emit ISA fences and does not order DMA payloads by itself.

## Approved API

```zig
// src/core/registers.zig
//! NVMe controller register block. Spec: docs/specs/core/registers.md.

const std = @import("std");

const stdx = @import("stdx");

const DmaAddr = stdx.addr.DmaAddr;
const Mmio = stdx.io.Mmio;
const Reg32 = Mmio.Register(u32);
const Reg64 = Mmio.Register(u64);

pub const doorbell_base_offset: usize = 0x1000;

pub const ControllerRegisters = struct {
    block: *volatile RegisterBlock,
    window: Mmio.Window,

    pub const Error = error{OutOfBounds};

    pub fn at(bytes: []align(Mmio.Window.min_align) volatile u8) Error!ControllerRegisters {
        if (bytes.len < doorbell_base_offset) return error.OutOfBounds;

        return .{
            .block = @ptrCast(bytes.ptr),
            .window = Mmio.Window.wrap(bytes),
        };
    }

    pub fn mmioWindow(self: ControllerRegisters) Mmio.Window {
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
        std.debug.assert(@alignOf(Self) == Mmio.Window.min_align);
    }
};

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

    pub fn maxQueueEntries(self: Cap) u32 {
        return @as(u32, self.mqes) + 1;
    }

    pub fn readyTimeoutUnits500ms(self: Cap) u8 {
        return self.to;
    }

    pub fn doorbellStrideBytes(self: Cap) usize {
        const shift: u6 = 2 + @as(u6, self.dstrd);
        return @as(usize, 1) << shift;
    }

    pub fn minPageSizeBytes(self: Cap) usize {
        const shift: u6 = 12 + @as(u6, self.mpsmin);
        return @as(usize, 1) << shift;
    }

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

pub const CommandSetSelection = enum(u3) {
    nvm = 0,
    all_supported = 6,
    admin_only = 7,
    _,
};

pub const Arbitration = enum(u3) {
    round_robin = 0,
    weighted_round_robin_urgent = 1,
    vendor_specific = 7,
    _,
};

pub const ShutdownNotification = enum(u2) {
    none = 0,
    normal = 1,
    abrupt = 2,
    _,
};

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

pub const ShutdownStatus = enum(u2) {
    normal = 0,
    occurring = 1,
    complete = 2,
    _,
};

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

    pub fn fromDmaAddr(addr: DmaAddr) Error!QueueBase {
        if (!addr.isAligned(alignment)) return error.Misaligned;
        return @bitCast(addr.raw());
    }

    pub fn dmaAddr(self: QueueBase) DmaAddr {
        return DmaAddr.fromInt(self.raw());
    }

    comptime {
        std.debug.assert(@bitSizeOf(QueueBase) == 64);
        std.debug.assert(@sizeOf(QueueBase) == @sizeOf(u64));
        std.debug.assert(@alignOf(QueueBase) == @alignOf(u64));
    }
};
```

## Field semantics

### `CAP` — Controller Capabilities

`[nvme]` `CAP` fields:

| Field | Bits | Meaning |
| --- | --- | --- |
| `MQES` | `15:0` | Maximum queue entries supported, zero-based (`MQES + 1`) |
| `CQR` | `16` | I/O queues require physically contiguous memory when set |
| `AMS` | `18:17` | Optional arbitration mechanisms supported |
| `TO` | `31:24` | Ready timeout in 500 ms units |
| `DSTRD` | `35:32` | Doorbell stride exponent; bytes = `2^(2 + DSTRD)` |
| `NSSRS` | `36` | NVM Subsystem Reset supported |
| `CSS` | `44:37` | Command sets supported; bit 0 is NVM Command Set |
| `BPS` | `45` | Boot partition support |
| `CPS` | `47:46` | Controller power scope |
| `MPSMIN` | `51:48` | Minimum memory page size exponent; bytes = `2^(12 + MPSMIN)` |
| `MPSMAX` | `55:52` | Maximum memory page size exponent; bytes = `2^(12 + MPSMAX)` |
| `PMRS` | `56` | Persistent Memory Region supported |
| `CMBS` | `57` | Controller Memory Buffer supported |
| `NSSS` | `58` | NVM Subsystem Shutdown supported |
| `CRMS` | `60:59` | Controller Ready Modes supported |

`[znvme]` First-slice behavior consumes `MQES`, `CQR`, `TO`, `DSTRD`, `CSS`, `MPSMIN`, and `MPSMAX`. Other fields are decoded and preserved but do not enable behavior by themselves.

### `VS` — Version

`[nvme]` `VS` packs tertiary version in bits `7:0`, minor in bits `15:8`, and major in bits `31:16`.

### `CC` — Controller Configuration

`[nvme]` `CC` fields:

| Field | Bits | znvme first-slice value |
| --- | --- | --- |
| `EN` | `0` | `0` while disabled, `1` for enabled |
| `CSS` | `6:4` | `0` (`.nvm`) |
| `MPS` | `10:7` | chosen by init after checking `CAP.MPSMIN..CAP.MPSMAX` |
| `AMS` | `13:11` | `0` (`.round_robin`) |
| `SHN` | `15:14` | `.none`, `.normal`, or `.abrupt` |
| `IOSQES` | `19:16` | `6` (`2^6 = 64` byte SQE) |
| `IOCQES` | `23:20` | `4` (`2^4 = 16` byte CQE) |
| `CRIME` | `24` | `0` in the first slice |

`[znvme]` `Cc.nvmEnabled(mps)` constructs the complete enabled NVM value. Controller init validates `mps` against `CAP`, then writes through `storeCc`.

### `CSTS` — Controller Status

`[nvme]` `CSTS` fields:

| Field | Bits | Meaning |
| --- | --- | --- |
| `RDY` | `0` | Controller ready |
| `CFS` | `1` | Controller fatal status |
| `SHST` | `3:2` | Shutdown status: normal, occurring, complete |
| `NSSRO` | `4` | NVM Subsystem Reset occurred |
| `PP` | `5` | Processing paused |
| `ST` | `6` | Shutdown type |

`[znvme]` Controller init owns polling and timeout behavior around `RDY`, `CFS`, and `SHST`.

### `AQA` — Admin Queue Attributes

`[nvme]` `ASQS` bits `11:0` and `ACQS` bits `27:16` encode admin submission/completion queue depths as zero-based values.

`[znvme]` `Aqa.fromDepths(.{ .submission_entries = 1, .completion_entries = 1 })` encodes both fields as `0`. `Aqa.fromDepths(.{ .submission_entries = 4096, .completion_entries = 4096 })` encodes both fields as `0xfff`.

### `ASQ` / `ACQ` — Admin Queue Base Address

`[nvme]` Bits `11:0` are reserved zero. Bits `63:12` hold the admin queue base address.

`[znvme]` `QueueBase.fromDmaAddr` enforces 4 KiB alignment. Any stronger page-size policy derived from `CC.MPS` is owned by controller init.

## Access and ordering rules

`[znvme]` `ControllerRegisters.at` borrows the caller's BAR mapping and performs no device access.

`[znvme]` All write methods write complete register values; no method performs a read-modify-write operation.

`[znvme]` `storeCap`, `storeVersion`, `storeCc`, `storeCsts`, `storeAqa`, `storeAsq`, and `storeAcq` do not emit barriers. The caller spec must place barriers around register access when required by the NVMe transition being implemented.

`[znvme]` `ControllerRegisters` exposes symmetric read and write accessors on every named register in the fixed block. The type does not police NVMe's per-register R/W attribute — that lives with the consumer role:

- `[znvme]` **Host driver.** Uses `cap`, `version`, `csts`, `aqa`, `asq`, `acq` as reads and `cc`, `aqa`, `asq`, `acq` as writes during controller enable. Never calls `storeCap`, `storeVersion`, or `storeCsts`.
- `[znvme]` **Device emulator.** Publishes controller-authored register state through `storeCap`, `storeVersion`, `storeCsts`, and (as replay) `storeCc`; observes host writes to `CC`, `AQA`, `ASQ`, `ACQ` through the reader accessors.

`[znvme]` The same MMIO window backs both roles; ordering and cache attributes belong to the caller's mapping.

`[znvme]` Direct use of `RegisterBlock` fields outside `core/registers.zig` is a defect. Callers use only `ControllerRegisters` methods approved by this spec or by the spec that owns a new accessor before that accessor lands.

## Validation behavior

- `[znvme]` `ControllerRegisters.at` rejects windows shorter than `0x1000`.
- `[znvme]` `Aqa.fromDepths` rejects zero queue depths and depths above 4096 entries.
- `[znvme]` `QueueBase.fromDmaAddr` rejects addresses with any low 12 bits set.
- `[znvme]` `Cap`, `Version`, `Cc`, and `Csts` decode every raw bit pattern; reserved bits are preserved.
- `[znvme]` `Cc.nvmEnabled` does not validate `mps`; controller init validates `mps` against `Cap` before constructing the enabled value.

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `[znvme]` `ControllerRegisters.at` | never | never | O(1) length check | borrowed value | none | `OutOfBounds` |
| `[znvme]` `mmioWindow` | never | never | O(1) | value copy | none | infallible |
| `[znvme]` register read methods | never | never | O(1) | caller-serialized per register | volatile load only | infallible |
| `[znvme]` register write methods | never | never | O(1) | caller-serialized per register | volatile store only | infallible |
| `[znvme]` value `fromRaw` / `raw` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `Aqa.fromDepths` | never | never | O(1) | value type | none | `QueueDepthOutOfRange` |
| `[znvme]` `QueueBase.fromDmaAddr` | never | never | O(1) | value type | none | `Misaligned` |

## Required tests `[znvme]`

`[znvme]` Test file `test/core/registers_test.zig`. Naming per `docs/guidelines/testing.md`.

- `[znvme]` `unit: registers block offsets match NVMe controller properties`.
- `[znvme]` `unit: registers block size ends at doorbell base`.
- `[znvme]` `unit: registers at rejects short BAR window`.
- `[znvme]` `unit: cap decodes queue entries timeout doorbell stride and page sizes`.
- `[znvme]` `unit: cap detects NVM command set support`.
- `[znvme]` `unit: version decodes major minor tertiary`.
- `[znvme]` `unit: cc nvm enabled encodes NVM CSS and queue entry sizes`.
- `[znvme]` `unit: cc shutdown notification updates only SHN`.
- `[znvme]` `unit: csts decodes ready fatal and shutdown status`.
- `[znvme]` `unit: aqa encodes named one-based depths as zero-based fields`.
- `[znvme]` `unit: aqa rejects zero and too-large depths`.
- `[znvme]` `unit: queue base rejects unaligned DMA address`.
- `[znvme]` `unit: queue base roundtrips aligned DMA address`.
- `[znvme]` `unit: controller registers storeCap writes CAP through the mmio window and cap reads it back`.
- `[znvme]` `unit: controller registers storeVersion writes VS and version reads it back`.
- `[znvme]` `unit: controller registers storeCsts writes CSTS and csts reads it back`.
- `[znvme]` `unit: controller registers aqa reads back what storeAqa wrote`.
- `[znvme]` `unit: controller registers asq reads back what storeAsq wrote`.
- `[znvme]` `unit: controller registers acq reads back what storeAcq wrote`.

## Open questions

_(none)_
