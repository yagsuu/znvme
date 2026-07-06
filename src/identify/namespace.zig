//! NVMe Identify Namespace (CNS 00h) and Active Namespace ID list (CNS 02h).
//! Spec: docs/specs/identify/namespace.md.

const std = @import("std");

const ids = @import("../core/ids.zig");

const Nsid = ids.Nsid;

pub const size_bytes: usize = 4096;
pub const max_lba_formats: usize = 64;

pub const Error = error{
    ShortBuffer,
    Misaligned,
    LbaFormatOutOfRange,
    LbaFormatUnavailable,
    LbaFormatTooLarge,
    ReservedLbaFormat,
    Overflow,
    EntryIndexOutOfRange,
};

pub const Pit = enum(u3) {
    disabled = 0b000,
    type_1 = 0b001,
    type_2 = 0b010,
    type_3 = 0b011,
    _,
};

pub const DeallocateReadBehavior = enum(u3) {
    not_reported = 0b000,
    read_zeros = 0b001,
    read_ones = 0b010,
    _,
};

pub const NsFeatBits = packed struct(u8) {
    thin_provisioning: u1,
    namespace_atomic_boundaries: u1,
    deallocated_or_unwritten_error: u1,
    uid_reuse_defined: u1,
    optimal_performance_hints: u1,
    reserved_5: u3 = 0,

    comptime {
        std.debug.assert(@bitSizeOf(NsFeatBits) == 8);
        std.debug.assert(@sizeOf(NsFeatBits) == 1);
    }
};

pub const McBits = packed struct(u8) {
    extended_lba: u1,
    separate_buffer: u1,
    reserved_2: u6 = 0,

    comptime {
        std.debug.assert(@bitSizeOf(McBits) == 8);
        std.debug.assert(@sizeOf(McBits) == 1);
    }
};

pub const DpcBits = packed struct(u8) {
    pi_type_1: u1,
    pi_type_2: u1,
    pi_type_3: u1,
    pi_in_first_bytes: u1,
    pi_in_last_bytes: u1,
    reserved_5: u3 = 0,

    comptime {
        std.debug.assert(@bitSizeOf(DpcBits) == 8);
        std.debug.assert(@sizeOf(DpcBits) == 1);
    }
};

pub const DpsBits = packed struct(u8) {
    pit: Pit,
    pi_position_first_bytes: u1,
    reserved_4: u4 = 0,

    comptime {
        std.debug.assert(@bitSizeOf(DpsBits) == 8);
        std.debug.assert(@sizeOf(DpsBits) == 1);
    }
};

pub const DlfeatBits = packed struct(u8) {
    read_behavior: DeallocateReadBehavior,
    write_zeroes_deallocate: u1,
    guard_crc_for_deallocated: u1,
    reserved_5: u3 = 0,

    comptime {
        std.debug.assert(@bitSizeOf(DlfeatBits) == 8);
        std.debug.assert(@sizeOf(DlfeatBits) == 1);
    }
};

pub const LbaFormat = packed struct(u32) {
    metadata_size: u16,
    lba_data_size_shift: u8,
    relative_performance: u2,
    reserved_26: u6 = 0,

    pub fn isAvailable(self: LbaFormat) bool {
        return self.lba_data_size_shift != 0;
    }

    pub fn dataSizeBytes(self: LbaFormat) Error!usize {
        if (self.lba_data_size_shift == 0) return error.LbaFormatUnavailable;
        if (self.lba_data_size_shift < 9) return error.ReservedLbaFormat;
        if (self.lba_data_size_shift >= @bitSizeOf(usize)) return error.LbaFormatTooLarge;
        return @as(usize, 1) << @intCast(self.lba_data_size_shift);
    }

    pub fn metadataSizeBytes(self: LbaFormat) usize {
        return @as(usize, self.metadata_size);
    }

    pub fn totalLbaSizeBytes(self: LbaFormat) Error!usize {
        const data = try self.dataSizeBytes();
        return std.math.add(usize, data, self.metadataSizeBytes()) catch
            error.LbaFormatTooLarge;
    }

    comptime {
        std.debug.assert(@bitSizeOf(LbaFormat) == 32);
        std.debug.assert(@sizeOf(LbaFormat) == 4);
    }
};

pub const Geometry = struct {
    format: LbaFormat,

    /// User-visible data bytes per LBA. `1 << format.lba_data_size_shift`.
    /// This is what a caller uses to translate `lba` into a user-buffer offset.
    data_size_bytes: usize,

    /// Metadata bytes per LBA. `format.metadataSizeBytes()` from the wire; may be zero.
    metadata_size_bytes: usize,

    /// On-wire byte stride consumed by one LBA transfer:
    /// - extended-LBA (`FLBAS.metadata_as_extended_lba == 1`): `data_size_bytes + metadata_size_bytes`;
    /// - separate-metadata:                                    `data_size_bytes`.
    /// Sizing PRP lists for Read/Write uses this multiplied by `logical_block_count`.
    transfer_stride_bytes: usize,

    /// LBA count (`NSZE`).
    logical_block_count: u64,

    pub fn totalDataBytes(self: Geometry) Error!u64 {
        return std.math.mul(u64, self.logical_block_count, self.data_size_bytes) catch
            error.Overflow;
    }

    pub fn totalTransferBytes(self: Geometry) Error!u64 {
        return std.math.mul(u64, self.logical_block_count, self.transfer_stride_bytes) catch
            error.Overflow;
    }

    pub fn containsLba(self: Geometry, lba: u64) bool {
        return lba < self.logical_block_count;
    }

    pub fn dataByteOffsetOf(self: Geometry, lba: u64) Error!u64 {
        return std.math.mul(u64, lba, self.data_size_bytes) catch error.Overflow;
    }

    pub fn transferByteOffsetOf(self: Geometry, lba: u64) Error!u64 {
        return std.math.mul(u64, lba, self.transfer_stride_bytes) catch error.Overflow;
    }
};

pub const IdentifyNamespace = extern struct {
    _nsze: u64 = 0,
    _ncap: u64 = 0,
    _nuse: u64 = 0,
    _nsfeat: u8 = 0,
    _nlbaf: u8 = 0,
    _flbas: u8 = 0,
    _mc: u8 = 0,
    _dpc: u8 = 0,
    _dps: u8 = 0,
    _nmic: u8 = 0,
    _rescap: u8 = 0,
    _fpi: u8 = 0,
    _dlfeat: u8 = 0,
    _nawun: u16 = 0,
    _nawupf: u16 = 0,
    _nacwu: u16 = 0,
    _nabsn: u16 = 0,
    _nabo: u16 = 0,
    _nabspf: u16 = 0,
    _noiob: u16 = 0,
    _nvmcap_low: u64 = 0,
    _nvmcap_high: u64 = 0,
    _reserved_40: [24]u8 = @splat(0),
    _reserved_58: [16]u8 = @splat(0),
    _nguid: [16]u8 = @splat(0),
    _eui64: [8]u8 = @splat(0),
    _lbaf: [max_lba_formats]LbaFormat = @splat(@bitCast(@as(u32, 0))),
    _reserved_180_vendor: [3712]u8 = @splat(0),

    pub const Init = struct {
        nsze: u64 = 0,
        ncap: u64 = 0,
        nuse: u64 = 0,
        nsfeat: NsFeatBits = @bitCast(@as(u8, 0)),
        nlbaf: u8 = 0,
        flbas: u8 = 0,
        mc: McBits = @bitCast(@as(u8, 0)),
        dpc: DpcBits = @bitCast(@as(u8, 0)),
        dps: DpsBits = @bitCast(@as(u8, 0)),
        nmic: u8 = 0,
        rescap: u8 = 0,
        fpi: u8 = 0,
        dlfeat: DlfeatBits = @bitCast(@as(u8, 0)),
        nawun: u16 = 0,
        nawupf: u16 = 0,
        nacwu: u16 = 0,
        nabsn: u16 = 0,
        nabo: u16 = 0,
        nabspf: u16 = 0,
        noiob: u16 = 0,
        nvmcap_low: u64 = 0,
        nvmcap_high: u64 = 0,
        nguid: [16]u8 = @splat(0),
        eui64: [8]u8 = @splat(0),
        lbaf: [max_lba_formats]LbaFormat = @splat(@bitCast(@as(u32, 0))),
    };

    pub fn init(target: *IdentifyNamespace, params: Init) void {
        target.* = .{
            ._nsze = params.nsze,
            ._ncap = params.ncap,
            ._nuse = params.nuse,
            ._nsfeat = @bitCast(params.nsfeat),
            ._nlbaf = params.nlbaf,
            ._flbas = params.flbas,
            ._mc = @bitCast(params.mc),
            ._dpc = @bitCast(params.dpc),
            ._dps = @bitCast(params.dps),
            ._nmic = params.nmic,
            ._rescap = params.rescap,
            ._fpi = params.fpi,
            ._dlfeat = @bitCast(params.dlfeat),
            ._nawun = params.nawun,
            ._nawupf = params.nawupf,
            ._nacwu = params.nacwu,
            ._nabsn = params.nabsn,
            ._nabo = params.nabo,
            ._nabspf = params.nabspf,
            ._noiob = params.noiob,
            ._nvmcap_low = params.nvmcap_low,
            ._nvmcap_high = params.nvmcap_high,
            ._nguid = params.nguid,
            ._eui64 = params.eui64,
            ._lbaf = params.lbaf,
        };
    }

    pub fn validate(bytes: []const u8) Error!*const IdentifyNamespace {
        if (bytes.len < size_bytes) return error.ShortBuffer;
        if (@intFromPtr(bytes.ptr) % @alignOf(u64) != 0) return error.Misaligned;
        return @ptrCast(@alignCast(bytes.ptr));
    }

    pub fn namespaceSize(self: *const IdentifyNamespace) u64 {
        return self._nsze;
    }

    pub fn namespaceCapacity(self: *const IdentifyNamespace) u64 {
        return self._ncap;
    }

    pub fn namespaceUtilization(self: *const IdentifyNamespace) u64 {
        return self._nuse;
    }

    pub fn features(self: *const IdentifyNamespace) NsFeatBits {
        return @bitCast(self._nsfeat);
    }

    pub fn numberOfLbaFormats(self: *const IdentifyNamespace) u7 {
        return @as(u7, @intCast(self._nlbaf & 0x3F)) + 1;
    }

    pub fn formatIndex(self: *const IdentifyNamespace) u6 {
        const low: u6 = @intCast(self._flbas & 0xf);
        const high: u6 = @intCast((self._flbas >> 5) & 0x3);
        return (high << 4) | low;
    }

    pub fn metadataAsExtendedLba(self: *const IdentifyNamespace) bool {
        return (self._flbas & 0x10) != 0;
    }

    pub fn metadataCapabilities(self: *const IdentifyNamespace) McBits {
        return @bitCast(self._mc);
    }

    pub fn dataProtectionCapabilities(self: *const IdentifyNamespace) DpcBits {
        return @bitCast(self._dpc);
    }

    pub fn dataProtectionSettings(self: *const IdentifyNamespace) DpsBits {
        return @bitCast(self._dps);
    }

    pub fn namespaceMultipathCapabilities(self: *const IdentifyNamespace) u8 {
        return self._nmic;
    }

    pub fn deallocateFeatures(self: *const IdentifyNamespace) DlfeatBits {
        return @bitCast(self._dlfeat);
    }

    pub fn optimalIoBoundary(self: *const IdentifyNamespace) u16 {
        return self._noiob;
    }

    pub fn nvmCapacityBytes(self: *const IdentifyNamespace) u128 {
        return (@as(u128, self._nvmcap_high) << 64) | self._nvmcap_low;
    }

    pub fn nguid(self: *const IdentifyNamespace) [16]u8 {
        return self._nguid;
    }

    pub fn eui64(self: *const IdentifyNamespace) [8]u8 {
        return self._eui64;
    }

    pub fn lbaFormat(self: *const IdentifyNamespace, index: u7) Error!LbaFormat {
        if (index >= self.numberOfLbaFormats()) return error.LbaFormatOutOfRange;
        return self._lbaf[index];
    }

    pub fn selectedLbaFormat(self: *const IdentifyNamespace) Error!LbaFormat {
        return self.lbaFormat(self.formatIndex());
    }

    pub fn geometry(self: *const IdentifyNamespace) Error!Geometry {
        const format = try self.selectedLbaFormat();
        const data_size = try format.dataSizeBytes();
        const metadata_size = format.metadataSizeBytes();
        const stride: usize = if (self.metadataAsExtendedLba())
            try format.totalLbaSizeBytes()
        else
            data_size;

        return .{
            .format = format,
            .data_size_bytes = data_size,
            .metadata_size_bytes = metadata_size,
            .transfer_stride_bytes = stride,
            .logical_block_count = self.namespaceSize(),
        };
    }

    comptime {
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nsze") == 0x00);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_ncap") == 0x08);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nuse") == 0x10);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nsfeat") == 0x18);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nlbaf") == 0x19);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_flbas") == 0x1a);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_mc") == 0x1b);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_dpc") == 0x1c);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_dps") == 0x1d);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nmic") == 0x1e);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_rescap") == 0x1f);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_fpi") == 0x20);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_dlfeat") == 0x21);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nawun") == 0x22);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nawupf") == 0x24);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nacwu") == 0x26);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nabsn") == 0x28);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nabo") == 0x2a);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nabspf") == 0x2c);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_noiob") == 0x2e);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nvmcap_low") == 0x30);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nvmcap_high") == 0x38);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_nguid") == 0x68);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_eui64") == 0x78);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_lbaf") == 0x80);
        std.debug.assert(@offsetOf(IdentifyNamespace, "_reserved_180_vendor") == 0x180);
        std.debug.assert(@sizeOf(IdentifyNamespace) == size_bytes);
        std.debug.assert(@alignOf(IdentifyNamespace) >= @alignOf(u64));
    }
};

pub const List = extern struct {
    _entries: [max_entries]u32 = @splat(0),

    pub const list_size_bytes: usize = 4096;
    pub const max_entries: usize = 1024;

    pub const Iterator = struct {
        list: *const List,
        index: u16 = 0,

        pub fn next(self: *Iterator) ?Nsid {
            if (self.index >= max_entries) return null;

            const raw = self.list._entries[self.index];
            if (raw == 0) return null;

            self.index += 1;
            return Nsid.from(raw);
        }
    };

    pub const Init = struct {
        nsids: []const Nsid = &.{},
    };

    pub fn init(target: *List, params: Init) void {
        std.debug.assert(params.nsids.len <= max_entries);

        var entries: [max_entries]u32 = @splat(0);
        for (params.nsids, 0..) |nsid, i| entries[i] = nsid.raw();
        target.* = .{ ._entries = entries };
    }

    pub fn validate(bytes: []const u8) Error!*const List {
        if (bytes.len < list_size_bytes) return error.ShortBuffer;
        if (@intFromPtr(bytes.ptr) % @alignOf(u32) != 0) return error.Misaligned;
        return @ptrCast(@alignCast(bytes.ptr));
    }

    pub fn entry(self: *const List, index: u16) Error!Nsid {
        if (index >= max_entries) return error.EntryIndexOutOfRange;
        return Nsid.from(self._entries[index]);
    }

    pub fn entryCount(self: *const List) u16 {
        var i: u16 = 0;
        while (i < max_entries) : (i += 1) {
            if (self._entries[i] == 0) return i;
        }
        return @intCast(max_entries);
    }

    pub fn iterator(self: *const List) Iterator {
        return .{ .list = self };
    }

    pub fn rawEntries(self: *const List) []const u32 {
        return &self._entries;
    }

    comptime {
        std.debug.assert(@offsetOf(List, "_entries") == 0);
        std.debug.assert(@sizeOf(List) == list_size_bytes);
        std.debug.assert(@alignOf(List) >= @alignOf(u32));
    }
};
