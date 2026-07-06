//! NVMe Identify Controller (CNS 01h) view. Spec: docs/specs/identify/controller.md.

const std = @import("std");

/// Size of the Identify Controller payload (CNS 01h) on the wire.
pub const size_bytes: usize = 4096;

pub const Error = error{
    ShortBuffer,
    Misaligned,
    MaxDataTransferSizeTooLarge,
};

/// Controller Type (`CNTRLTYPE`). Non-exhaustive per NVMe 2.0.
pub const ControllerType = enum(u8) {
    reserved = 0x00,
    io = 0x01,
    discovery = 0x02,
    administrative = 0x03,
    _,
};

/// Decoded `MDTS` (Maximum Data Transfer Size). `unlimited` when the wire
/// field is zero; otherwise `page_shift` is the exponent applied to the
/// controller's `MPSMIN` page size.
pub const MaxDataTransferSize = union(enum) {
    unlimited,
    page_shift: u8,

    pub fn fromRaw(mdts: u8) MaxDataTransferSize {
        if (mdts == 0) return .unlimited;
        return .{ .page_shift = mdts };
    }

    /// Absolute byte ceiling on one transfer, or `null` for unlimited.
    /// Multiplies `min_page_size_bytes` (from `CAP.MPSMIN`) by `1 << page_shift`.
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

/// SQE/CQE size register (`SQES` / `CQES`): required and max entry size,
/// each as a power-of-two byte-count shift.
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

/// Optional Admin Command Support (`OACS`). One flag per optional admin
/// feature; the controller sets a bit iff the command is supported.
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

/// Optional NVM Command Support (`ONCS`). One flag per optional NVM command.
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

/// Fused-Operation Support (`FUSES`). Currently only compare-and-write.
pub const FusesBits = packed struct(u16) {
    compare_and_write: u1,
    reserved_1: u15 = 0,

    comptime {
        std.debug.assert(@bitSizeOf(FusesBits) == 16);
        std.debug.assert(@sizeOf(FusesBits) == 2);
    }
};

/// SGL support summary (`SGLS`). The full bit layout is deferred; the first
/// slice only needs "does the controller advertise SGLs at all?".
pub const SglSupportBits = struct {
    raw: u32,

    pub fn fromRaw(value: u32) SglSupportBits {
        return .{ .raw = value };
    }

    pub fn supported(self: SglSupportBits) bool {
        return (self.raw & 0x3) != 0;
    }
};

/// 4096-byte Identify Controller (CNS 01h) response. Underscore-prefixed
/// storage fields carry wire bytes; typed accessors decode. Fabricate for
/// tests via `IdentifyController.init(target, params)`; production readers
/// borrow through `IdentifyController.validate(bytes)`.
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
