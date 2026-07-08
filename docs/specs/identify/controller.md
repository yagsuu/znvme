# Identify Controller

Status: Approved.

`identify.controller.IdentifyController` is znvme's borrowed read-only view over the 4 KiB Identify Controller response buffer produced by an admin `Identify` command with `CNS = 01h`. It owns the wire layout, field accessors for the boot-path–relevant subset, and validation against a caller-supplied byte slice.

The wire structure is 4096 bytes; NVMe defines dozens of fields, most of which the first-slice boot reader never consumes. This spec transcribes every field offset the boot path needs, plus scalar-length reserved regions that keep offsets aligned. It does not enumerate every optional or vendor-specific field.

## Owned scope

This spec owns:

- `IdentifyController`, a 4096-byte `extern struct` overlay with underscore-prefixed storage fields and `@sizeOf` / `@offsetOf` assertions for every named field;
- semantic accessors on `*const IdentifyController` covering the boot-path subset;
- `IdentifyController.validate(bytes) Error!*const IdentifyController`, the byte-window entry point;
- `ControllerType`, non-exhaustive `enum(u8)` covering `io`, `discovery`, `administrative`;
- `MaxDataTransferSize`, a tagged union distinguishing the `unlimited` sentinel from a `page_shift`;
- `EntrySize`, a `packed struct(u8)` decoding the required/max nibble pair;
- `OacsBits`, `OncsBits`, `FusesBits`, `SglSupportBits` — semantic wrappers over the corresponding wire words;
- `IdentifyController.Init` semantic construction params with zero-safe defaults;
- `IdentifyController.init(target: *IdentifyController, params: Init) void`, in-place value constructor for device-emulator fixtures;
- first-slice native little-endian storage on `x86_64-freestanding-none`.

## Deferred scope and non-goals

This spec does not own:

- field enumeration beyond the boot path — controller-attribute fields (`CTRATT`), ANA reporting (`ANATT`, `ANACAP`, `ANAGRPMAX`, `NANAGRPID`), Keep Alive support (`KAS`), Host Controlled Thermal Management (`HCTMA`, `MNTMT`, `MXTMT`), Sanitize Capabilities (`SANICAP`), Host Memory Buffer (`HMPRE`, `HMMIN`, `HMMINDS`, `HMMAXD`), power state descriptors, per–Command Set command-support fields, keyed SGL policy, endurance-group and NVM-set identifiers (`ENDGIDMAX`, `NSETIDMAX`), domain identifier, temperature thresholds beyond `WCTEMP`/`CCTEMP`, NVM subsystem capacity (`TNVMCAP`/`UNVMCAP`), NVM Vendor Specific Command Configuration (`ICSVSCC`), Namespace Write Protection Capabilities (`NWPC`), Atomic Compare & Write Unit (`ACWU`), Optional Copy Formats. Unrecognized field offsets fall through the `_reserved_*` padding fields;
- SGL bit-by-bit decoding — `sglSupport()` returns the raw `u32` wrapped in `SglSupportBits`, with only a `supported()` predicate defined; SGL support is deferred by `docs/specs/project/scope.md`;
- `OacsBits` / `OncsBits` bits outside the currently-named set — unknown bits pass through the packed struct as `reserved_*` fields;
- ASCII, UTF-8, or NUL-termination validation of `serialNumber`, `modelNumber`, `firmwareRevision`, or `subsystemNqn` — the wire fixes only the byte length; callers decode and trim;
- semantic interpretation of fields whose meaning depends on I/O Command Set specifications outside the NVM Command Set;
- retrieval mechanics — the admin `Identify` builder that requests the response lives in `docs/specs/commands/admin.md`;
- Identify Namespace or Active Namespace ID list decoding (`docs/specs/identify/namespace.md`);
- big-endian host or target compatibility.

## `stdx` composition

No direct `stdx` primitive is required. Composition is only the `[]const u8` byte slice and native `extern struct` field access.

## NVMe wire layout

`[nvme]` NVMe Base Specification 2.0 §5.17.2 defines the 4 KiB Identify Controller data structure. Boot-path–relevant offsets:

| Offset | Field | Width | Meaning |
| ---: | --- | ---: | --- |
| `0x000` | `VID` | 2 | PCI Vendor ID |
| `0x002` | `SSVID` | 2 | PCI Subsystem Vendor ID |
| `0x004` | `SN` | 20 | Serial Number (ASCII, space-padded) |
| `0x018` | `MN` | 40 | Model Number (ASCII, space-padded) |
| `0x040` | `FR` | 8 | Firmware Revision (ASCII, space-padded) |
| `0x048` | `RAB` | 1 | Recommended Arbitration Burst |
| `0x049` | `IEEE` | 3 | IEEE OUI |
| `0x04c` | `CMIC` | 1 | Controller Multi-Path I/O and Namespace Sharing |
| `0x04d` | `MDTS` | 1 | Maximum Data Transfer Size |
| `0x04e` | `CNTLID` | 2 | Controller ID |
| `0x050` | `VER` | 4 | Version |
| `0x054` | `RTD3R` | 4 | RTD3 Resume Latency |
| `0x058` | `RTD3E` | 4 | RTD3 Entry Latency |
| `0x05c` | `OAES` | 4 | Optional Asynchronous Events Supported |
| `0x060` | `CTRATT` | 4 | Controller Attributes |
| `0x064` | `RRLS` | 2 | Read Recovery Levels Supported |
| `0x066` | reserved | 9 |  |
| `0x06f` | `CNTRLTYPE` | 1 | Controller Type |
| `0x070` | `FGUID` | 16 | FRU Globally Unique Identifier |
| `0x080` | `CRDT` | 6 | Command Retry Delay Times 1..3 (three `u16`) |
| `0x086` | reserved | 122 |  |
| `0x100` | `OACS` | 2 | Optional Admin Command Support |
| `0x102` | `ACL` | 1 | Abort Command Limit |
| `0x103` | `AERL` | 1 | Asynchronous Event Request Limit |
| `0x104` | `FRMW` | 1 | Firmware Updates |
| `0x105` | `LPA` | 1 | Log Page Attributes |
| `0x106` | `ELPE` | 1 | Error Log Page Entries |
| `0x107` | `NPSS` | 1 | Number of Power States Supported |
| `0x108` | `AVSCC` | 1 | Admin Vendor Specific Command Configuration |
| `0x109` | `APSTA` | 1 | Autonomous Power State Transition Attributes |
| `0x10a` | `WCTEMP` | 2 | Warning Composite Temperature Threshold |
| `0x10c` | `CCTEMP` | 2 | Critical Composite Temperature Threshold |
| `0x10e` | reserved | 46 |  |
| `0x13c` | reserved | 68 |  |
| `0x180` | reserved | 128 |  |
| `0x200` | `SQES` | 1 | Submission Queue Entry Size (required/max, 4 bits each) |
| `0x201` | `CQES` | 1 | Completion Queue Entry Size (required/max, 4 bits each) |
| `0x202` | `MAXCMD` | 2 | Maximum Outstanding Commands |
| `0x204` | `NN` | 4 | Number of Namespaces |
| `0x208` | `ONCS` | 2 | Optional NVM Command Support |
| `0x20a` | `FUSES` | 2 | Fused Operation Support |
| `0x20c` | `FNA` | 1 | Format NVM Attributes |
| `0x20d` | `VWC` | 1 | Volatile Write Cache |
| `0x20e` | `AWUN` | 2 | Atomic Write Unit Normal |
| `0x210` | `AWUPF` | 2 | Atomic Write Unit Power Fail |
| `0x212` | reserved | 6 |  |
| `0x218` | `SGLS` | 4 | SGL Support |
| `0x21c` | reserved | 228 |  |
| `0x300` | `SUBNQN` | 256 | NVM Subsystem NVMe Qualified Name (UTF-8, NUL-terminated) |
| `0x400` | reserved | 1024 |  |
| `0x800` | power state descriptors | 1024 |  |
| `0xc00` | vendor specific | 1024 |  |

`[nvme]` Total size is 4096 bytes. `[nvme]` Multi-byte fields are little-endian.

## Bit layouts

### `CNTRLTYPE`

`[nvme]` Non-exhaustive `u8` per NVMe §5.17.2.1 Controller Type:

| Raw | Meaning |
| ---: | --- |
| `0x00` | Reserved (interpreted as "unknown / not reported") |
| `0x01` | I/O Controller |
| `0x02` | Discovery Controller |
| `0x03` | Administrative Controller |

### `MDTS`

`[nvme]` `0h` means unlimited data transfer size. Non-zero values encode the maximum transfer size as `CAP.MPSMIN * 2^MDTS` bytes (per NVMe §5.17.2.1).

`MaxDataTransferSize.maxBytes(min_page_size)` performs the shift and returns `error.MaxDataTransferSizeTooLarge` when the exponent or the shifted product does not fit `usize`.

### `SQES` / `CQES`

`[nvme]` One byte, low nibble is required entry size exponent, high nibble is maximum entry size exponent. Both express `2^n` bytes. For the NVM Command Set boot path, required SQE = 64 (`n = 6`) and required CQE = 16 (`n = 4`).

### `OACS`

`[nvme]` One `u16`, bits `0..10` name capabilities:

| Bit | Meaning |
| ---: | --- |
| `0` | Security Send/Receive |
| `1` | Format NVM |
| `2` | Firmware Commit and Firmware Image Download |
| `3` | Namespace Management (and Namespace Attachment) |
| `4` | Device Self-Test |
| `5` | Directives |
| `6` | NVMe-MI Send and Receive |
| `7` | Virtualization Management |
| `8` | Doorbell Buffer Config |
| `9` | Get LBA Status |
| `10` | Command and Feature Lockdown |
| `15:11` | Reserved |

### `ONCS`

`[nvme]` One `u16`, bits `0..8` name capabilities:

| Bit | Meaning |
| ---: | --- |
| `0` | Compare |
| `1` | Write Uncorrectable |
| `2` | Dataset Management |
| `3` | Write Zeroes |
| `4` | Save/Select fields on Set/Get Features |
| `5` | Reservations |
| `6` | Timestamp feature |
| `7` | Verify |
| `8` | Copy |
| `15:9` | Reserved |

### `FUSES`

`[nvme]` One `u16`, bit `0` names capability:

| Bit | Meaning |
| ---: | --- |
| `0` | Compare and Write |
| `15:1` | Reserved |

### `SGLS`

`[nvme]` One `u32` whose bit layout is defined in NVMe §5.17.2.1. The two-bit "SGL supported" field at bits `1:0` is `00b` not supported, `01b` supported, `10b` reserved, `11b` supported with keyed SGL data blocks.

This spec surfaces only that two-bit field. The remaining bits are not decoded in the first slice; they carry through in the raw `u32` and a future SGL-owning spec claims them.

## znvme behavior

`IdentifyController` is a `[4096]u8` overlay declared as an `extern struct` with named underscore-prefixed fields at their NVMe offsets and `_reserved_*` padding filling the gaps. Every named field is either a native little-endian scalar (`u8`, `u16`, `u32`) or a fixed-size `[N]u8` byte array. First-slice code targets `x86_64-freestanding-none` and assumes native little-endian per `docs/specs/project/scope.md`. The `_` prefix marks fields as wire-storage; the public read surface is the method set on `*const IdentifyController`.

`IdentifyController.validate(bytes)` accepts a `[]const u8` and returns `error.ShortBuffer` when `bytes.len < 4096` and `error.Misaligned` when `@intFromPtr(bytes.ptr) % @alignOf(u32) != 0`. NVMe DMA transfers land in caller-owned page-aligned storage (a `stdx.dma.Buffer(u8)` whose backing is at least 4-byte aligned by the underlying `[]align(4) u8` slice), so alignment is a caller invariant established at PRP construction — the typed error surfaces guest-authored or emulator-authored misalignment cleanly and never fires from a correctly-constructed host buffer. On success `validate` returns `*const IdentifyController` borrowing the caller's bytes.

Callers whose storage is already typed (for example, a caller-owned `[1]IdentifyController align(4)` buffer) call the accessors directly on the typed pointer without going through `validate`.

Scalar accessors return semantic values via native little-endian loads through the `extern struct` fields. The compiler folds the field load into a single instruction on `x86_64`.

`serialNumber()`, `modelNumber()`, `firmwareRevision()`, and `subsystemNqn()` return `[]const u8` slices into the caller's underlying storage. The slice lifetime is bounded by the caller's byte buffer; the accessor does not extend it. Callers who want the trimmed prefix use `std.mem.trimRight(u8, id.modelNumber(), " ")` for space-padded fields or `std.mem.sliceTo(id.subsystemNqn(), 0)` for the NUL-terminated SUBNQN.

`controllerType()` returns `ControllerType`. Values outside the four named cases pass through the non-exhaustive enum tail; callers detect unknown controller types by matching the exhaustive prefix.

`maxDataTransferSize()` returns a `MaxDataTransferSize` tagged union. `.unlimited` corresponds to `MDTS == 0`. `.page_shift = mdts` carries the raw exponent; the caller composes it with `CAP.MPSMIN` via `maxBytes(min_page_size_bytes)` to obtain a byte limit. `maxBytes` is fallible on device-authored oversize exponents: it returns `error.MaxDataTransferSizeTooLarge` when `page_shift >= @bitSizeOf(usize)` or when `min_page_size_bytes << page_shift` overflows `usize`. The `.unlimited` case still returns `null` unwrapped.

`submissionQueueEntrySize()` and `completionQueueEntrySize()` return `EntrySize`. `.requiredBytes()` and `.maxBytes()` compute `2^n`. For NVM Command Set support, the required nibble is `6` (SQE) and `4` (CQE); values differing from those are legal on the wire but not usable by the first-slice boot path — the caller decides.

`optionalAdminCommandSupport()`, `optionalNvmCommandSupport()`, and `fusedOperationSupport()` return the packed-struct decoded value; each bit is a `u1` field with a documented meaning. Reserved bits round-trip.

`sglSupport()` returns `SglSupportBits` wrapping the raw `u32`. `.supported()` returns true when bits `1:0` are non-zero. No other decoder is exposed in the first slice.

The accessors do not check any field's admissibility. They decode what the device wrote. Consumers decide whether e.g. `numberOfNamespaces() == 0` is an operational error for their use case.

`IdentifyController.init(target, params)` stamps `target.*` in place with the params-provided lanes. Every `Init` field has a zero-safe default so `IdentifyController.init(target, .{})` is spec-legal blank storage. Emulator fixtures allocate a `[1]IdentifyController align(4)` buffer (or an equivalent `Buffer(u8)` cast), call `IdentifyController.init(&scratch[0], .{ ... })`, and expose the underlying bytes to the host through PRP. Host drivers never call `init`; they only decode through the accessors.

`IdentifyController.validate` and accessors borrow caller-owned bytes as-is; no accessor emits a memory barrier. Callers consuming a device-written Identify Controller payload (that is, after a successful `pollOne` returns a completion whose CID matches an outstanding Identify handle) must issue `stdx.barrier.dma.acquire()` between the matching CQE observation and the first accessor call. `pollOne`'s CQE-side acquire does not cover Identify payload bytes.

## Approved API

```zig
// src/identify/controller.zig
//! NVMe Identify Controller (CNS 01h) view. Spec: docs/specs/identify/controller.md.

const std = @import("std");

pub const size_bytes: usize = 4096;

pub const Error = error{
    ShortBuffer,
    Misaligned,
    MaxDataTransferSizeTooLarge,
};

pub const ControllerType = enum(u8) {
    reserved = 0x00,
    io = 0x01,
    discovery = 0x02,
    administrative = 0x03,
    _,
};

pub const MaxDataTransferSize = union(enum) {
    unlimited,
    page_shift: u8,

    pub fn fromRaw(mdts: u8) MaxDataTransferSize {
        if (mdts == 0) return .unlimited;
        return .{ .page_shift = mdts };
    }

    pub fn maxBytes(self: MaxDataTransferSize, min_page_size_bytes: usize) Error!?usize {
        return switch (self) {
            .unlimited => null,
            .page_shift => |shift| blk: {
                if (shift >= @bitSizeOf(usize)) break :blk error.MaxDataTransferSizeTooLarge;
                break :blk std.math.shlExact(usize, min_page_size_bytes, @intCast(shift)) catch
                    error.MaxDataTransferSizeTooLarge;
            },
        };
    }
};

pub const EntrySize = packed struct(u8) {
    required_shift: u4,
    max_shift: u4,

    pub fn requiredBytes(self: EntrySize) usize {
        return @as(usize, 1) << @intCast(self.required_shift);
    }

    pub fn maxBytes(self: EntrySize) usize {
        return @as(usize, 1) << @intCast(self.max_shift);
    }

    comptime {
        std.debug.assert(@bitSizeOf(EntrySize) == 8);
        std.debug.assert(@sizeOf(EntrySize) == 1);
    }
};

pub const OacsBits = packed struct(u16) {
    security_send_receive: u1,
    format_nvm: u1,
    firmware_download: u1,
    namespace_management: u1,
    device_self_test: u1,
    directives: u1,
    nvme_mi: u1,
    virtualization_management: u1,
    doorbell_buffer_config: u1,
    get_lba_status: u1,
    command_and_feature_lockdown: u1,
    reserved_11: u5 = 0,

    comptime {
        std.debug.assert(@bitSizeOf(OacsBits) == 16);
        std.debug.assert(@sizeOf(OacsBits) == 2);
    }
};

pub const OncsBits = packed struct(u16) {
    compare: u1,
    write_uncorrectable: u1,
    dataset_management: u1,
    write_zeroes: u1,
    save_features: u1,
    reservations: u1,
    timestamp: u1,
    verify: u1,
    copy: u1,
    reserved_9: u7 = 0,

    comptime {
        std.debug.assert(@bitSizeOf(OncsBits) == 16);
        std.debug.assert(@sizeOf(OncsBits) == 2);
    }
};

pub const FusesBits = packed struct(u16) {
    compare_and_write: u1,
    reserved_1: u15 = 0,

    comptime {
        std.debug.assert(@bitSizeOf(FusesBits) == 16);
        std.debug.assert(@sizeOf(FusesBits) == 2);
    }
};

pub const SglSupportBits = struct {
    raw: u32,

    pub fn fromRaw(value: u32) SglSupportBits {
        return .{ .raw = value };
    }

    pub fn supported(self: SglSupportBits) bool {
        return (self.raw & 0x3) != 0;
    }
};

pub const IdentifyController = extern struct {
    _vid: u16 = 0,
    _ssvid: u16 = 0,
    _sn: [20]u8 = @splat(' '),
    _mn: [40]u8 = @splat(' '),
    _fr: [8]u8 = @splat(' '),
    _rab: u8 = 0,
    _ieee: [3]u8 = .{ 0, 0, 0 },
    _cmic: u8 = 0,
    _mdts: u8 = 0,
    _cntlid: u16 = 0,
    _ver: u32 = 0,
    _rtd3r: u32 = 0,
    _rtd3e: u32 = 0,
    _oaes: u32 = 0,
    _ctratt: u32 = 0,
    _rrls: u16 = 0,
    _reserved_66: [9]u8 = @splat(0),
    _cntrltype: u8 = 0,
    _fguid: [16]u8 = @splat(0),
    _crdt: [3]u16 = .{ 0, 0, 0 },
    _reserved_86: [122]u8 = @splat(0),
    _oacs: u16 = 0,
    _acl: u8 = 0,
    _aerl: u8 = 0,
    _frmw: u8 = 0,
    _lpa: u8 = 0,
    _elpe: u8 = 0,
    _npss: u8 = 0,
    _avscc: u8 = 0,
    _apsta: u8 = 0,
    _wctemp: u16 = 0,
    _cctemp: u16 = 0,
    _reserved_10e: [46]u8 = @splat(0),
    _reserved_13c: [68]u8 = @splat(0),
    _reserved_180: [128]u8 = @splat(0),
    _sqes: u8 = 0,
    _cqes: u8 = 0,
    _maxcmd: u16 = 0,
    _nn: u32 = 0,
    _oncs: u16 = 0,
    _fuses: u16 = 0,
    _fna: u8 = 0,
    _vwc: u8 = 0,
    _awun: u16 = 0,
    _awupf: u16 = 0,
    _reserved_212: [6]u8 = @splat(0),
    _sgls: u32 = 0,
    _reserved_21c: [228]u8 = @splat(0),
    _subnqn: [256]u8 = @splat(0),
    _reserved_400: [1024]u8 = @splat(0),
    _reserved_800_power_states: [1024]u8 = @splat(0),
    _reserved_c00_vendor: [1024]u8 = @splat(0),

    pub const Init = struct {
        vid: u16 = 0,
        ssvid: u16 = 0,
        sn: [20]u8 = @splat(' '),
        mn: [40]u8 = @splat(' '),
        fr: [8]u8 = @splat(' '),
        rab: u8 = 0,
        ieee: [3]u8 = .{ 0, 0, 0 },
        cmic: u8 = 0,
        mdts: u8 = 0,
        cntlid: u16 = 0,
        ver: u32 = 0,
        oaes: u32 = 0,
        ctratt: u32 = 0,
        rrls: u16 = 0,
        cntrltype: ControllerType = .reserved,
        fguid: [16]u8 = @splat(0),
        crdt: [3]u16 = .{ 0, 0, 0 },
        oacs: OacsBits = @bitCast(@as(u16, 0)),
        acl: u8 = 0,
        aerl: u8 = 0,
        frmw: u8 = 0,
        lpa: u8 = 0,
        elpe: u8 = 0,
        npss: u8 = 0,
        avscc: u8 = 0,
        apsta: u8 = 0,
        wctemp: u16 = 0,
        cctemp: u16 = 0,
        sqes: EntrySize = @bitCast(@as(u8, 0)),
        cqes: EntrySize = @bitCast(@as(u8, 0)),
        maxcmd: u16 = 0,
        nn: u32 = 0,
        oncs: OncsBits = @bitCast(@as(u16, 0)),
        fuses: FusesBits = @bitCast(@as(u16, 0)),
        fna: u8 = 0,
        vwc: u8 = 0,
        awun: u16 = 0,
        awupf: u16 = 0,
        sgls: u32 = 0,
        subnqn: [256]u8 = @splat(0),
    };

    pub fn init(target: *IdentifyController, params: Init) void {
        target.* = .{
            ._vid = params.vid,
            ._ssvid = params.ssvid,
            ._sn = params.sn,
            ._mn = params.mn,
            ._fr = params.fr,
            ._rab = params.rab,
            ._ieee = params.ieee,
            ._cmic = params.cmic,
            ._mdts = params.mdts,
            ._cntlid = params.cntlid,
            ._ver = params.ver,
            ._oaes = params.oaes,
            ._ctratt = params.ctratt,
            ._rrls = params.rrls,
            ._cntrltype = @intFromEnum(params.cntrltype),
            ._fguid = params.fguid,
            ._crdt = params.crdt,
            ._oacs = @bitCast(params.oacs),
            ._acl = params.acl,
            ._aerl = params.aerl,
            ._frmw = params.frmw,
            ._lpa = params.lpa,
            ._elpe = params.elpe,
            ._npss = params.npss,
            ._avscc = params.avscc,
            ._apsta = params.apsta,
            ._wctemp = params.wctemp,
            ._cctemp = params.cctemp,
            ._sqes = @bitCast(params.sqes),
            ._cqes = @bitCast(params.cqes),
            ._maxcmd = params.maxcmd,
            ._nn = params.nn,
            ._oncs = @bitCast(params.oncs),
            ._fuses = @bitCast(params.fuses),
            ._fna = params.fna,
            ._vwc = params.vwc,
            ._awun = params.awun,
            ._awupf = params.awupf,
            ._sgls = params.sgls,
            ._subnqn = params.subnqn,
        };
    }

    pub fn validate(bytes: []const u8) Error!*const IdentifyController {
        if (bytes.len < size_bytes) return error.ShortBuffer;
        if (@intFromPtr(bytes.ptr) % @alignOf(u32) != 0) return error.Misaligned;
        return @ptrCast(@alignCast(bytes.ptr));
    }

    pub fn vendorId(self: *const IdentifyController) u16 {
        return self._vid;
    }

    pub fn subsystemVendorId(self: *const IdentifyController) u16 {
        return self._ssvid;
    }

    pub fn serialNumber(self: *const IdentifyController) []const u8 {
        return &self._sn;
    }

    pub fn modelNumber(self: *const IdentifyController) []const u8 {
        return &self._mn;
    }

    pub fn firmwareRevision(self: *const IdentifyController) []const u8 {
        return &self._fr;
    }

    pub fn recommendedArbitrationBurst(self: *const IdentifyController) u8 {
        return self._rab;
    }

    pub fn ieeeOui(self: *const IdentifyController) [3]u8 {
        return self._ieee;
    }

    pub fn controllerId(self: *const IdentifyController) u16 {
        return self._cntlid;
    }

    pub fn version(self: *const IdentifyController) u32 {
        return self._ver;
    }

    pub fn controllerType(self: *const IdentifyController) ControllerType {
        return @enumFromInt(self._cntrltype);
    }

    pub fn maxDataTransferSize(self: *const IdentifyController) MaxDataTransferSize {
        return MaxDataTransferSize.fromRaw(self._mdts);
    }

    pub fn optionalAdminCommandSupport(self: *const IdentifyController) OacsBits {
        return @bitCast(self._oacs);
    }

    pub fn submissionQueueEntrySize(self: *const IdentifyController) EntrySize {
        return @bitCast(self._sqes);
    }

    pub fn completionQueueEntrySize(self: *const IdentifyController) EntrySize {
        return @bitCast(self._cqes);
    }

    pub fn maxOutstandingCommands(self: *const IdentifyController) u16 {
        return self._maxcmd;
    }

    pub fn numberOfNamespaces(self: *const IdentifyController) u32 {
        return self._nn;
    }

    pub fn optionalNvmCommandSupport(self: *const IdentifyController) OncsBits {
        return @bitCast(self._oncs);
    }

    pub fn fusedOperationSupport(self: *const IdentifyController) FusesBits {
        return @bitCast(self._fuses);
    }

    pub fn atomicWriteUnitNormal(self: *const IdentifyController) u16 {
        return self._awun;
    }

    pub fn atomicWriteUnitPowerFail(self: *const IdentifyController) u16 {
        return self._awupf;
    }

    pub fn sglSupport(self: *const IdentifyController) SglSupportBits {
        return SglSupportBits.fromRaw(self._sgls);
    }

    pub fn subsystemNqn(self: *const IdentifyController) []const u8 {
        return &self._subnqn;
    }

    comptime {
        std.debug.assert(@offsetOf(IdentifyController, "_vid") == 0x000);
        std.debug.assert(@offsetOf(IdentifyController, "_ssvid") == 0x002);
        std.debug.assert(@offsetOf(IdentifyController, "_sn") == 0x004);
        std.debug.assert(@offsetOf(IdentifyController, "_mn") == 0x018);
        std.debug.assert(@offsetOf(IdentifyController, "_fr") == 0x040);
        std.debug.assert(@offsetOf(IdentifyController, "_rab") == 0x048);
        std.debug.assert(@offsetOf(IdentifyController, "_ieee") == 0x049);
        std.debug.assert(@offsetOf(IdentifyController, "_cmic") == 0x04c);
        std.debug.assert(@offsetOf(IdentifyController, "_mdts") == 0x04d);
        std.debug.assert(@offsetOf(IdentifyController, "_cntlid") == 0x04e);
        std.debug.assert(@offsetOf(IdentifyController, "_ver") == 0x050);
        std.debug.assert(@offsetOf(IdentifyController, "_rtd3r") == 0x054);
        std.debug.assert(@offsetOf(IdentifyController, "_rtd3e") == 0x058);
        std.debug.assert(@offsetOf(IdentifyController, "_oaes") == 0x05c);
        std.debug.assert(@offsetOf(IdentifyController, "_ctratt") == 0x060);
        std.debug.assert(@offsetOf(IdentifyController, "_rrls") == 0x064);
        std.debug.assert(@offsetOf(IdentifyController, "_cntrltype") == 0x06f);
        std.debug.assert(@offsetOf(IdentifyController, "_fguid") == 0x070);
        std.debug.assert(@offsetOf(IdentifyController, "_crdt") == 0x080);
        std.debug.assert(@offsetOf(IdentifyController, "_oacs") == 0x100);
        std.debug.assert(@offsetOf(IdentifyController, "_acl") == 0x102);
        std.debug.assert(@offsetOf(IdentifyController, "_aerl") == 0x103);
        std.debug.assert(@offsetOf(IdentifyController, "_frmw") == 0x104);
        std.debug.assert(@offsetOf(IdentifyController, "_lpa") == 0x105);
        std.debug.assert(@offsetOf(IdentifyController, "_elpe") == 0x106);
        std.debug.assert(@offsetOf(IdentifyController, "_npss") == 0x107);
        std.debug.assert(@offsetOf(IdentifyController, "_avscc") == 0x108);
        std.debug.assert(@offsetOf(IdentifyController, "_apsta") == 0x109);
        std.debug.assert(@offsetOf(IdentifyController, "_wctemp") == 0x10a);
        std.debug.assert(@offsetOf(IdentifyController, "_cctemp") == 0x10c);
        std.debug.assert(@offsetOf(IdentifyController, "_sqes") == 0x200);
        std.debug.assert(@offsetOf(IdentifyController, "_cqes") == 0x201);
        std.debug.assert(@offsetOf(IdentifyController, "_maxcmd") == 0x202);
        std.debug.assert(@offsetOf(IdentifyController, "_nn") == 0x204);
        std.debug.assert(@offsetOf(IdentifyController, "_oncs") == 0x208);
        std.debug.assert(@offsetOf(IdentifyController, "_fuses") == 0x20a);
        std.debug.assert(@offsetOf(IdentifyController, "_fna") == 0x20c);
        std.debug.assert(@offsetOf(IdentifyController, "_vwc") == 0x20d);
        std.debug.assert(@offsetOf(IdentifyController, "_awun") == 0x20e);
        std.debug.assert(@offsetOf(IdentifyController, "_awupf") == 0x210);
        std.debug.assert(@offsetOf(IdentifyController, "_sgls") == 0x218);
        std.debug.assert(@offsetOf(IdentifyController, "_subnqn") == 0x300);
        std.debug.assert(@sizeOf(IdentifyController) == size_bytes);
    }
};
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `IdentifyController.init` | never | never | O(1) | caller-serialized per target | none | infallible |
| `IdentifyController.validate` | never | never | O(1) length + alignment check | borrowed slice | none | `ShortBuffer`, `Misaligned` |
| scalar accessors | never | never | O(1) | borrowed load | none | infallible |
| `serialNumber` / `modelNumber` / `firmwareRevision` / `subsystemNqn` | never | never | O(1) | borrowed slice | none | infallible |
| `maxDataTransferSize.fromRaw` | never | never | O(1) | value type | none | infallible |
| `maxDataTransferSize.maxBytes` | never | never | O(1) | value type | none | `MaxDataTransferSizeTooLarge` |
| `EntrySize.requiredBytes` / `.maxBytes` | never | never | O(1) | value type | none | infallible |
| packed-struct decode (`OacsBits`, `OncsBits`, `FusesBits`) | never | never | O(1) | value type | none | infallible |
| `SglSupportBits.supported` | never | never | O(1) | value type | none | infallible |

The accessors perform no allocation, waiting, hidden global access, atomics, barriers, volatile access, target probing, syscalls, locks, or I/O.

## Validation phases

Per `docs/specs/architecture.md` §"Validation phases":

- **Compile time.** `@sizeOf`, `@offsetOf`, and `@bitSizeOf` assertions inside `IdentifyController`, `EntrySize`, `OacsBits`, `OncsBits`, and `FusesBits`. `zig build check` proves them on `x86_64-freestanding-none`.
- **Public validation.** `IdentifyController.validate(bytes)` returns `error.ShortBuffer` when `bytes.len < 4096` and `error.Misaligned` when the byte pointer is not `@alignOf(u32)`-aligned. `MaxDataTransferSize.maxBytes` returns `error.MaxDataTransferSizeTooLarge` when the device-authored `page_shift` is out of range or the shifted product would overflow `usize`. Every other raw byte pattern is representable; reserved fields decode as raw bytes or as `reserved_*` bits.
- **Assertions.** None. Alignment is a public typed error, not a programmer-error assertion.

## Example usage

Illustrative shape only; not part of the approved API.

```zig
const std = @import("std");

const nvme = @import("nvme");

const IdentifyController = nvme.identify.controller.IdentifyController;

const id = try IdentifyController.validate(identify_buffer.constBytes());

if (id.controllerType() != .io) return error.NotIoController;
if (id.numberOfNamespaces() == 0) return error.NoNamespaces;

const sqes = id.submissionQueueEntrySize();
std.debug.assert(sqes.requiredBytes() == 64);

const model = std.mem.trimRight(u8, id.modelNumber(), " ");
log.info("model: {s}", .{model});

const mdts_max_bytes = try id.maxDataTransferSize().maxBytes(cap.minPageSizeBytes());
if (mdts_max_bytes) |limit| {
    log.debug("MDTS limit = {} bytes", .{limit});
} else {
    // .unlimited: no per-command byte cap.
}
```

Emulator authoring a fixture in place:

```zig
const nvme = @import("nvme");

const IdentifyController = nvme.identify.controller.IdentifyController;

var scratch: [1]IdentifyController align(4) = undefined;
IdentifyController.init(&scratch[0], .{
    .vid = 0x1234,
    .cntrltype = .io,
    .sqes = .{ .required_shift = 6, .max_shift = 6 },
    .cqes = .{ .required_shift = 4, .max_shift = 4 },
    .nn = 1,
});
```

## Required tests

Test file `test/identify/controller_test.zig`. Naming per `docs/guidelines/testing.md`.

Test substrate: a `[4096]u8 align(4)` scratch buffer initialized to zero, then written with known bytes at each field offset the tests exercise.

- `unit: identify controller size is 4096 bytes`.
- `unit: identify controller offsets match NVMe Figure 275` — every named `@offsetOf` echoed as a host-side check.
- `unit: identify controller validate rejects buffer shorter than 4096 with ShortBuffer`.
- `unit: identify controller validate rejects misaligned byte pointer with Misaligned`.
- `unit: identify controller validate accepts exact 4096-byte buffer`.
- `unit: identify controller accessors work on a typed pointer without going through validate`.
- `unit: identify controller decodes VID SSVID CNTLID VER as native little-endian`.
- `unit: identify controller decodes SN MN FR as byte slices with fixed lengths` — verify slice lengths 20 / 40 / 8; permit arbitrary bytes including trailing spaces.
- `unit: identify controller decodes SUBNQN as 256-byte slice preserving trailing NUL padding`.
- `unit: identify controller controllerType returns io for 0x01 and preserves unknown values`.
- `unit: identify controller maxDataTransferSize returns unlimited for MDTS zero`.
- `unit: identify controller maxDataTransferSize returns page_shift for non-zero MDTS`.
- `unit: identify controller MaxDataTransferSize.maxBytes returns min_page_size shifted by MDTS for in-range page_shift`.
- `unit: identify controller MaxDataTransferSize.maxBytes returns MaxDataTransferSizeTooLarge when page_shift >= @bitSizeOf(usize)`.
- `unit: identify controller MaxDataTransferSize.maxBytes returns MaxDataTransferSizeTooLarge when min_page_size shifted by page_shift overflows usize`.
- `unit: identify controller submissionQueueEntrySize decodes required and max nibbles` — `SQES = 0x66` returns `.required_shift = 6, .max_shift = 6`.
- `unit: identify controller completionQueueEntrySize decodes required and max nibbles` — `CQES = 0x44` returns `.required_shift = 4, .max_shift = 4`.
- `unit: identify controller EntrySize.requiredBytes and maxBytes return 2^n bytes`.
- `unit: identify controller OacsBits decodes doorbell_buffer_config and get_lba_status flags`.
- `unit: identify controller OncsBits decodes dataset_management write_zeroes verify flags`.
- `unit: identify controller FusesBits decodes compare_and_write flag`.
- `unit: identify controller sglSupport supported returns true for non-zero SGLS bits 1:0`.
- `unit: identify controller maxOutstandingCommands and numberOfNamespaces decode as native little-endian`.
- `roundtrip: identify controller accessors return exactly what a byte fixture encodes` — write a 4 KiB buffer with known bytes at every named offset, verify every accessor returns the expected value.
- `golden: identify controller minimal bytes decode` — bytes-exact 4 KiB fixture (documented regeneration command) with plausible boot-device values; every boot-path accessor asserted.
- `unit: IdentifyController.init(target, .{}) is spec-legal all-zero storage with default reserved padding` — every reserved region reads zero; `_subnqn`, `_fguid`, `_crdt` default to zero; `_sn`, `_mn`, `_fr` default to space padding.
- `roundtrip: IdentifyController.init round-trips every field through accessors` — populate every non-reserved `Init` field; construct via `init`; assert every accessor returns the input.
- `unit: identify controller accessors emit no barrier` — audit that `validate` and every accessor issue no `stdx.barrier.*` calls; ordering is the caller's responsibility.

## Open questions

_(none)_
