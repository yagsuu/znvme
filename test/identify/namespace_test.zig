//! Host-side tests for src/identify/namespace.zig. Spec: docs/specs/identify/namespace.md.

const std = @import("std");
const testing = std.testing;

const nvme = @import("nvme");
const namespace = nvme.identify.namespace;
const ids = nvme.core.ids;

const IdentifyNamespace = namespace.IdentifyNamespace;
const List = namespace.List;
const LbaFormat = namespace.LbaFormat;
const Geometry = namespace.Geometry;
const NsFeatBits = namespace.NsFeatBits;
const McBits = namespace.McBits;
const DpcBits = namespace.DpcBits;
const DpsBits = namespace.DpsBits;
const DlfeatBits = namespace.DlfeatBits;
const Pit = namespace.Pit;
const DeallocateReadBehavior = namespace.DeallocateReadBehavior;
const Nsid = ids.Nsid;

const regen_512e = @import("../fixtures/identify/namespace_512e_minimal_regen.zig");
const regen_4kn = @import("../fixtures/identify/namespace_4kn_minimal_regen.zig");
const regen_list_two = @import("../fixtures/identify/list_two_active_regen.zig");
const regen_list_dense = @import("../fixtures/identify/list_dense_1024_regen.zig");

test "unit: identify namespace size is 4096 bytes" {
    try testing.expectEqual(@as(usize, 4096), @sizeOf(IdentifyNamespace));
    try testing.expectEqual(namespace.size_bytes, @sizeOf(IdentifyNamespace));
}

test "unit: identify namespace offsets match NVM Command Set Specification Figure 97" {
    try testing.expectEqual(@as(usize, 0x00), @offsetOf(IdentifyNamespace, "_nsze"));
    try testing.expectEqual(@as(usize, 0x08), @offsetOf(IdentifyNamespace, "_ncap"));
    try testing.expectEqual(@as(usize, 0x10), @offsetOf(IdentifyNamespace, "_nuse"));
    try testing.expectEqual(@as(usize, 0x18), @offsetOf(IdentifyNamespace, "_nsfeat"));
    try testing.expectEqual(@as(usize, 0x19), @offsetOf(IdentifyNamespace, "_nlbaf"));
    try testing.expectEqual(@as(usize, 0x1a), @offsetOf(IdentifyNamespace, "_flbas"));
    try testing.expectEqual(@as(usize, 0x1b), @offsetOf(IdentifyNamespace, "_mc"));
    try testing.expectEqual(@as(usize, 0x1c), @offsetOf(IdentifyNamespace, "_dpc"));
    try testing.expectEqual(@as(usize, 0x1d), @offsetOf(IdentifyNamespace, "_dps"));
    try testing.expectEqual(@as(usize, 0x1e), @offsetOf(IdentifyNamespace, "_nmic"));
    try testing.expectEqual(@as(usize, 0x1f), @offsetOf(IdentifyNamespace, "_rescap"));
    try testing.expectEqual(@as(usize, 0x20), @offsetOf(IdentifyNamespace, "_fpi"));
    try testing.expectEqual(@as(usize, 0x21), @offsetOf(IdentifyNamespace, "_dlfeat"));
    try testing.expectEqual(@as(usize, 0x22), @offsetOf(IdentifyNamespace, "_nawun"));
    try testing.expectEqual(@as(usize, 0x24), @offsetOf(IdentifyNamespace, "_nawupf"));
    try testing.expectEqual(@as(usize, 0x26), @offsetOf(IdentifyNamespace, "_nacwu"));
    try testing.expectEqual(@as(usize, 0x28), @offsetOf(IdentifyNamespace, "_nabsn"));
    try testing.expectEqual(@as(usize, 0x2a), @offsetOf(IdentifyNamespace, "_nabo"));
    try testing.expectEqual(@as(usize, 0x2c), @offsetOf(IdentifyNamespace, "_nabspf"));
    try testing.expectEqual(@as(usize, 0x2e), @offsetOf(IdentifyNamespace, "_noiob"));
    try testing.expectEqual(@as(usize, 0x30), @offsetOf(IdentifyNamespace, "_nvmcap_low"));
    try testing.expectEqual(@as(usize, 0x38), @offsetOf(IdentifyNamespace, "_nvmcap_high"));
    try testing.expectEqual(@as(usize, 0x68), @offsetOf(IdentifyNamespace, "_nguid"));
    try testing.expectEqual(@as(usize, 0x78), @offsetOf(IdentifyNamespace, "_eui64"));
    try testing.expectEqual(@as(usize, 0x80), @offsetOf(IdentifyNamespace, "_lbaf"));
    try testing.expectEqual(@as(usize, 0x180), @offsetOf(IdentifyNamespace, "_reserved_180_vendor"));
}

test "unit: identify namespace validate rejects buffer shorter than 4096 with ShortBuffer" {
    var b: [4095]u8 align(8) = @splat(0);
    try testing.expectError(error.ShortBuffer, IdentifyNamespace.validate(&b));
}

test "unit: identify namespace validate rejects misaligned byte pointer with Misaligned" {
    // Force @alignOf(u64)-misaligned window: aligned 8 storage, slice starting at +1.
    var b: [4097]u8 align(8) = @splat(0);
    try testing.expectError(error.Misaligned, IdentifyNamespace.validate(b[1..4097]));
}

test "unit: identify namespace validate accepts exact 4096-byte buffer" {
    var b: [4096]u8 align(8) = @splat(0);
    const id = try IdentifyNamespace.validate(&b);
    try testing.expectEqual(@as(u64, 0), id.namespaceSize());
}

test "unit: identify namespace accessors work on a typed pointer without going through validate" {
    var t: IdentifyNamespace = .{};
    t._nsze = 0xDEAD_BEEF_CAFE_BABE;
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE_BABE), (&t).namespaceSize());
}

test "unit: identify namespace decodes NSZE NCAP NUSE as native little-endian u64" {
    // Method: stamp three distinct u64s at the wire offsets; validate; assert the accessor returns each verbatim.
    var b: [4096]u8 align(8) = @splat(0);
    std.mem.writeInt(u64, b[0x00..][0..8], 0x0011_2233_4455_6677, .little);
    std.mem.writeInt(u64, b[0x08..][0..8], 0x8899_AABB_CCDD_EEFF, .little);
    std.mem.writeInt(u64, b[0x10..][0..8], 0x1234_5678_9ABC_DEF0, .little);
    const id = try IdentifyNamespace.validate(&b);
    try testing.expectEqual(@as(u64, 0x0011_2233_4455_6677), id.namespaceSize());
    try testing.expectEqual(@as(u64, 0x8899_AABB_CCDD_EEFF), id.namespaceCapacity());
    try testing.expectEqual(@as(u64, 0x1234_5678_9ABC_DEF0), id.namespaceUtilization());
}

test "unit: identify namespace NsFeatBits decodes THINP NSABP DAE UIDREUSE OPTPERF flags" {
    // Method: set bits 0..4 in NSFEAT; verify each packed field decodes to 1.
    var b: [4096]u8 align(8) = @splat(0);
    b[0x18] = 0b0001_1111;
    const id = try IdentifyNamespace.validate(&b);
    const f = id.features();
    try testing.expectEqual(@as(u1, 1), f.thin_provisioning);
    try testing.expectEqual(@as(u1, 1), f.namespace_atomic_boundaries);
    try testing.expectEqual(@as(u1, 1), f.deallocated_or_unwritten_error);
    try testing.expectEqual(@as(u1, 1), f.uid_reuse_defined);
    try testing.expectEqual(@as(u1, 1), f.optimal_performance_hints);
}

test "unit: identify namespace numberOfLbaFormats returns NLBAF+1" {
    // Method: cover the boundary values NLBAF = {0, 15, 63}.
    var b: [4096]u8 align(8) = @splat(0);

    b[0x19] = 0;
    try testing.expectEqual(@as(u7, 1), (try IdentifyNamespace.validate(&b)).numberOfLbaFormats());

    b[0x19] = 15;
    try testing.expectEqual(@as(u7, 16), (try IdentifyNamespace.validate(&b)).numberOfLbaFormats());

    b[0x19] = 63;
    try testing.expectEqual(@as(u7, 64), (try IdentifyNamespace.validate(&b)).numberOfLbaFormats());
}

test "unit: identify namespace formatIndex assembles FLBAS bits 6:5 with 3:0" {
    // Method: exercise both the 4-bit legacy case (high bits zero) and the 6-bit assembled case.
    var b: [4096]u8 align(8) = @splat(0);

    // Low nibble only: (0<<4) | 0x5 = 5.
    b[0x1a] = 0x05;
    try testing.expectEqual(@as(u6, 0x05), (try IdentifyNamespace.validate(&b)).formatIndex());

    // High bits set: FLBAS = 0b0110_1010 -> low = 0xa, high = 0b11 -> (3<<4)|0xa = 0x3a = 58.
    b[0x1a] = 0b0110_1010;
    try testing.expectEqual(@as(u6, 0x3a), (try IdentifyNamespace.validate(&b)).formatIndex());
}

test "unit: identify namespace metadataAsExtendedLba decodes FLBAS bit 4" {
    var b: [4096]u8 align(8) = @splat(0);
    b[0x1a] = 0x00;
    try testing.expect(!(try IdentifyNamespace.validate(&b)).metadataAsExtendedLba());
    b[0x1a] = 0x10;
    try testing.expect((try IdentifyNamespace.validate(&b)).metadataAsExtendedLba());
}

test "unit: identify namespace McBits decodes extended_lba and separate_buffer flags" {
    var b: [4096]u8 align(8) = @splat(0);
    b[0x1b] = 0b0000_0011;
    const mc = (try IdentifyNamespace.validate(&b)).metadataCapabilities();
    try testing.expectEqual(@as(u1, 1), mc.extended_lba);
    try testing.expectEqual(@as(u1, 1), mc.separate_buffer);
}

test "unit: identify namespace DpcBits decodes all three PI-type support bits and PII first/last" {
    var b: [4096]u8 align(8) = @splat(0);
    // bits 0..4 all set -> 0x1F.
    b[0x1c] = 0x1F;
    const dpc = (try IdentifyNamespace.validate(&b)).dataProtectionCapabilities();
    try testing.expectEqual(@as(u1, 1), dpc.pi_type_1);
    try testing.expectEqual(@as(u1, 1), dpc.pi_type_2);
    try testing.expectEqual(@as(u1, 1), dpc.pi_type_3);
    try testing.expectEqual(@as(u1, 1), dpc.pi_in_first_bytes);
    try testing.expectEqual(@as(u1, 1), dpc.pi_in_last_bytes);
}

test "unit: identify namespace DpsBits decodes PIT enum and PIP bit" {
    // Method: cover disabled/type_1/type_2/type_3 plus a reserved value preserved via the non-exhaustive tail;
    // also verify PIP bit 3 flips independently.
    var b: [4096]u8 align(8) = @splat(0);

    b[0x1d] = 0b0000; // disabled, PIP=0
    var dps = (try IdentifyNamespace.validate(&b)).dataProtectionSettings();
    try testing.expectEqual(Pit.disabled, dps.pit);
    try testing.expectEqual(@as(u1, 0), dps.pi_position_first_bytes);

    b[0x1d] = 0b0001;
    dps = (try IdentifyNamespace.validate(&b)).dataProtectionSettings();
    try testing.expectEqual(Pit.type_1, dps.pit);

    b[0x1d] = 0b0010;
    dps = (try IdentifyNamespace.validate(&b)).dataProtectionSettings();
    try testing.expectEqual(Pit.type_2, dps.pit);

    b[0x1d] = 0b0011;
    dps = (try IdentifyNamespace.validate(&b)).dataProtectionSettings();
    try testing.expectEqual(Pit.type_3, dps.pit);

    // Reserved value 0b101 in PIT — must round-trip through the non-exhaustive tail.
    b[0x1d] = 0b0000_1101; // PIT=101, PIP=1.
    dps = (try IdentifyNamespace.validate(&b)).dataProtectionSettings();
    try testing.expectEqual(@as(u3, 0b101), @intFromEnum(dps.pit));
    try testing.expectEqual(@as(u1, 1), dps.pi_position_first_bytes);
}

test "unit: identify namespace DlfeatBits decodes read_behavior write_zeroes_deallocate guard_crc flags" {
    var b: [4096]u8 align(8) = @splat(0);
    // read_behavior=read_ones(0b010), write_zeroes_deallocate=1, guard_crc=1 -> 0b0001_1010.
    b[0x21] = 0b0001_1010;
    const dl = (try IdentifyNamespace.validate(&b)).deallocateFeatures();
    try testing.expectEqual(DeallocateReadBehavior.read_ones, dl.read_behavior);
    try testing.expectEqual(@as(u1, 1), dl.write_zeroes_deallocate);
    try testing.expectEqual(@as(u1, 1), dl.guard_crc_for_deallocated);
}

test "unit: identify namespace nvmCapacityBytes assembles high u64 shifted 64 bits over low u64" {
    // Method: stamp two adjacent u64 halves; reassembled u128 must place high above low.
    var b: [4096]u8 align(8) = @splat(0);
    std.mem.writeInt(u64, b[0x30..][0..8], 0x0000_0000_DEAD_BEEF, .little);
    std.mem.writeInt(u64, b[0x38..][0..8], 0x0000_0000_CAFE_BABE, .little);
    const id = try IdentifyNamespace.validate(&b);
    const expected: u128 = (@as(u128, 0x0000_0000_CAFE_BABE) << 64) | @as(u128, 0x0000_0000_DEAD_BEEF);
    try testing.expectEqual(expected, id.nvmCapacityBytes());
}

test "unit: identify namespace nguid and eui64 return preserved big-endian bytes" {
    // Method: NGUID/EUI64 are byte arrays on the wire; accessor must return the byte pattern verbatim.
    var b: [4096]u8 align(8) = @splat(0);
    var nguid_pattern: [16]u8 = undefined;
    for (&nguid_pattern, 0..) |*c, i| c.* = @intCast(0xB0 + i);
    var eui_pattern: [8]u8 = undefined;
    for (&eui_pattern, 0..) |*c, i| c.* = @intCast(0xE0 + i);
    @memcpy(b[0x68..0x78], &nguid_pattern);
    @memcpy(b[0x78..0x80], &eui_pattern);
    const id = try IdentifyNamespace.validate(&b);
    try testing.expectEqual(nguid_pattern, id.nguid());
    try testing.expectEqual(eui_pattern, id.eui64());
}

test "unit: identify namespace optimalIoBoundary returns NOIOB as u16" {
    var b: [4096]u8 align(8) = @splat(0);
    std.mem.writeInt(u16, b[0x2e..][0..2], 0x1234, .little);
    try testing.expectEqual(@as(u16, 0x1234), (try IdentifyNamespace.validate(&b)).optimalIoBoundary());
}

test "unit: LbaFormat decodes MS LBADS RP fields at documented bit positions" {
    // Method: bitcast a raw u32 with distinct nibbles in each named region and verify each field.
    // MS=0xBEEF (bits 15:0), LBADS=0x12 (bits 23:16), RP=0b10 (bits 25:24).
    const raw: u32 = (@as(u32, 0b10) << 24) | (@as(u32, 0x12) << 16) | 0xBEEF;
    const f: LbaFormat = @bitCast(raw);
    try testing.expectEqual(@as(u16, 0xBEEF), f.metadata_size);
    try testing.expectEqual(@as(u8, 0x12), f.lba_data_size_shift);
    try testing.expectEqual(@as(u2, 0b10), f.relative_performance);
}

test "unit: LbaFormat isAvailable returns false when LBADS is zero" {
    const zero: LbaFormat = @bitCast(@as(u32, 0));
    try testing.expect(!zero.isAvailable());
    const nonzero: LbaFormat = .{ .metadata_size = 0, .lba_data_size_shift = 9, .relative_performance = 0 };
    try testing.expect(nonzero.isAvailable());
}

test "unit: LbaFormat dataSizeBytes returns LbaFormatUnavailable for shift 0" {
    const f: LbaFormat = .{ .metadata_size = 0, .lba_data_size_shift = 0, .relative_performance = 0 };
    try testing.expectError(error.LbaFormatUnavailable, f.dataSizeBytes());
}

test "unit: LbaFormat dataSizeBytes returns ReservedLbaFormat for shift 1..8" {
    // Method: iterate the reserved range and assert each value returns ReservedLbaFormat.
    var s: u8 = 1;
    while (s <= 8) : (s += 1) {
        const f: LbaFormat = .{ .metadata_size = 0, .lba_data_size_shift = s, .relative_performance = 0 };
        try testing.expectError(error.ReservedLbaFormat, f.dataSizeBytes());
    }
}

test "unit: LbaFormat dataSizeBytes returns LbaFormatTooLarge for shift >= @bitSizeOf(usize)" {
    const at_bound: LbaFormat = .{
        .metadata_size = 0,
        .lba_data_size_shift = @bitSizeOf(usize),
        .relative_performance = 0,
    };
    try testing.expectError(error.LbaFormatTooLarge, at_bound.dataSizeBytes());
    const above: LbaFormat = .{ .metadata_size = 0, .lba_data_size_shift = 0xFF, .relative_performance = 0 };
    try testing.expectError(error.LbaFormatTooLarge, above.dataSizeBytes());
}

test "unit: LbaFormat dataSizeBytes returns 512 for shift 9 and 4096 for shift 12" {
    // Method: cover the two spec-named LBA sizes plus shift 24 (16 MiB) as an in-range large value.
    const f512: LbaFormat = .{ .metadata_size = 0, .lba_data_size_shift = 9, .relative_performance = 0 };
    try testing.expectEqual(@as(usize, 512), try f512.dataSizeBytes());

    const f4k: LbaFormat = .{ .metadata_size = 0, .lba_data_size_shift = 12, .relative_performance = 0 };
    try testing.expectEqual(@as(usize, 4096), try f4k.dataSizeBytes());

    const f16m: LbaFormat = .{ .metadata_size = 0, .lba_data_size_shift = 24, .relative_performance = 0 };
    try testing.expectEqual(@as(usize, 1 << 24), try f16m.dataSizeBytes());
}

test "unit: LbaFormat totalLbaSizeBytes sums data and metadata for representable values" {
    // Method: shift 12 + 8 bytes metadata -> stride 4104.
    const f: LbaFormat = .{ .metadata_size = 8, .lba_data_size_shift = 12, .relative_performance = 0 };
    try testing.expectEqual(@as(usize, 4104), try f.totalLbaSizeBytes());

    // No metadata -> stride equals data size.
    const bare: LbaFormat = .{ .metadata_size = 0, .lba_data_size_shift = 9, .relative_performance = 0 };
    try testing.expectEqual(@as(usize, 512), try bare.totalLbaSizeBytes());
}

test "unit: LbaFormat totalLbaSizeBytes returns LbaFormatTooLarge when data + metadata overflows usize" {
    // Method: dataSizeBytes filters shift >= @bitSizeOf(usize) with LbaFormatTooLarge, so
    // totalLbaSizeBytes propagates that error via `try`; the observable outcome is the same.
    // Metadata is at most u16 and data at shift 63 is 2^63, so on any host with usize >= u32 the
    // addition itself does not overflow — the guarded shift domain is what protects the sum.
    const oversize: LbaFormat = .{
        .metadata_size = 0xFFFF,
        .lba_data_size_shift = @bitSizeOf(usize),
        .relative_performance = 0,
    };
    try testing.expectError(error.LbaFormatTooLarge, oversize.totalLbaSizeBytes());
}

test "unit: identify namespace lbaFormat rejects index >= numberOfLbaFormats with LbaFormatOutOfRange" {
    // NLBAF=0 -> numberOfLbaFormats()==1; only index 0 is legal.
    var t: IdentifyNamespace = .{};
    t._nlbaf = 0;
    try testing.expectError(error.LbaFormatOutOfRange, (&t).lbaFormat(1));

    // NLBAF=15 -> valid indices 0..=15.
    t._nlbaf = 15;
    try testing.expectError(error.LbaFormatOutOfRange, (&t).lbaFormat(16));
    _ = try (&t).lbaFormat(15);
}

test "unit: identify namespace selectedLbaFormat honors 6-bit formatIndex when NLBAF > 16" {
    // Method: place a distinct LbaFormat at index 0x21 (33) so the high-bits path must contribute.
    var t: IdentifyNamespace = .{};
    t._nlbaf = 63;
    // FLBAS = high 0b01 (<<5), low 0x1 -> assembled 0x11 = 17.
    t._flbas = (0b01 << 5) | 0x01;
    t._lbaf[17] = .{ .metadata_size = 42, .lba_data_size_shift = 12, .relative_performance = 1 };
    const f = try (&t).selectedLbaFormat();
    try testing.expectEqual(@as(u16, 42), f.metadata_size);
    try testing.expectEqual(@as(u8, 12), f.lba_data_size_shift);
    try testing.expectEqual(@as(u2, 1), f.relative_performance);
}

test "unit: identify namespace geometry returns LbaFormatUnavailable when selected LBADS is zero" {
    var t: IdentifyNamespace = .{};
    t._nlbaf = 0;
    t._flbas = 0;
    t._lbaf[0] = .{ .metadata_size = 0, .lba_data_size_shift = 0, .relative_performance = 0 };
    try testing.expectError(error.LbaFormatUnavailable, (&t).geometry());
}

test "unit: identify namespace geometry returns ReservedLbaFormat when selected LBADS is less than 9" {
    var t: IdentifyNamespace = .{};
    t._nlbaf = 0;
    t._flbas = 0;
    t._lbaf[0] = .{ .metadata_size = 0, .lba_data_size_shift = 5, .relative_performance = 0 };
    try testing.expectError(error.ReservedLbaFormat, (&t).geometry());
}

test "unit: identify namespace geometry returns LbaFormatTooLarge when LBADS >= @bitSizeOf(usize)" {
    var t: IdentifyNamespace = .{};
    t._nlbaf = 0;
    t._flbas = 0;
    t._lbaf[0] = .{
        .metadata_size = 0,
        .lba_data_size_shift = @bitSizeOf(usize),
        .relative_performance = 0,
    };
    try testing.expectError(error.LbaFormatTooLarge, (&t).geometry());
}

test "unit: identify namespace geometry with 512-byte LBAs and no metadata sets data=512 metadata=0 stride=512" {
    var t: IdentifyNamespace = .{};
    t._nsze = 1024;
    t._nlbaf = 0;
    t._flbas = 0;
    t._lbaf[0] = .{ .metadata_size = 0, .lba_data_size_shift = 9, .relative_performance = 0 };
    const g = try (&t).geometry();
    try testing.expectEqual(@as(usize, 512), g.data_size_bytes);
    try testing.expectEqual(@as(usize, 0), g.metadata_size_bytes);
    try testing.expectEqual(@as(usize, 512), g.transfer_stride_bytes);
    try testing.expectEqual(@as(u64, 1024), g.logical_block_count);
}

test "unit: identify namespace geometry with 4KiB LBAs plus extended metadata sets stride 4104" {
    var t: IdentifyNamespace = .{};
    t._nsze = 512;
    t._nlbaf = 0;
    t._flbas = 0x10; // metadata_as_extended_lba
    t._lbaf[0] = .{ .metadata_size = 8, .lba_data_size_shift = 12, .relative_performance = 0 };
    const g = try (&t).geometry();
    try testing.expectEqual(@as(usize, 4096), g.data_size_bytes);
    try testing.expectEqual(@as(usize, 8), g.metadata_size_bytes);
    try testing.expectEqual(@as(usize, 4104), g.transfer_stride_bytes);
}

test "unit: identify namespace geometry with 4KiB LBAs plus separate metadata sets stride 4096" {
    var t: IdentifyNamespace = .{};
    t._nsze = 512;
    t._nlbaf = 0;
    t._flbas = 0x00; // metadata rides a separate buffer -> stride == data_size
    t._lbaf[0] = .{ .metadata_size = 8, .lba_data_size_shift = 12, .relative_performance = 0 };
    const g = try (&t).geometry();
    try testing.expectEqual(@as(usize, 4096), g.data_size_bytes);
    try testing.expectEqual(@as(usize, 8), g.metadata_size_bytes);
    try testing.expectEqual(@as(usize, 4096), g.transfer_stride_bytes);
}

test "unit: Geometry.containsLba returns false for lba equal to logical_block_count" {
    const g: Geometry = .{
        .format = .{ .metadata_size = 0, .lba_data_size_shift = 9, .relative_performance = 0 },
        .data_size_bytes = 512,
        .metadata_size_bytes = 0,
        .transfer_stride_bytes = 512,
        .logical_block_count = 10,
    };
    try testing.expect(g.containsLba(0));
    try testing.expect(g.containsLba(9));
    try testing.expect(!g.containsLba(10));
    try testing.expect(!g.containsLba(std.math.maxInt(u64)));
}

test "unit: Geometry.totalDataBytes multiplies count by data_size_bytes" {
    const g: Geometry = .{
        .format = .{ .metadata_size = 0, .lba_data_size_shift = 12, .relative_performance = 0 },
        .data_size_bytes = 4096,
        .metadata_size_bytes = 0,
        .transfer_stride_bytes = 4096,
        .logical_block_count = 1024,
    };
    try testing.expectEqual(@as(u64, 4_194_304), try g.totalDataBytes());
}

test "unit: Geometry.totalDataBytes returns Overflow when product exceeds u64.max" {
    const g: Geometry = .{
        .format = .{ .metadata_size = 0, .lba_data_size_shift = 9, .relative_performance = 0 },
        .data_size_bytes = 2,
        .metadata_size_bytes = 0,
        .transfer_stride_bytes = 2,
        .logical_block_count = std.math.maxInt(u64),
    };
    try testing.expectError(error.Overflow, g.totalDataBytes());
}

test "unit: Geometry.totalTransferBytes multiplies count by transfer_stride_bytes" {
    // Method: extended-LBA fixture with data=4096 metadata=8 stride=4104 to prove stride path.
    const g: Geometry = .{
        .format = .{ .metadata_size = 8, .lba_data_size_shift = 12, .relative_performance = 0 },
        .data_size_bytes = 4096,
        .metadata_size_bytes = 8,
        .transfer_stride_bytes = 4104,
        .logical_block_count = 100,
    };
    try testing.expectEqual(@as(u64, 410_400), try g.totalTransferBytes());
}

test "unit: Geometry.totalTransferBytes returns Overflow when product exceeds u64.max" {
    const g: Geometry = .{
        .format = .{ .metadata_size = 0, .lba_data_size_shift = 9, .relative_performance = 0 },
        .data_size_bytes = 2,
        .metadata_size_bytes = 0,
        .transfer_stride_bytes = 2,
        .logical_block_count = std.math.maxInt(u64),
    };
    try testing.expectError(error.Overflow, g.totalTransferBytes());
}

test "unit: Geometry.dataByteOffsetOf returns lba times data_size_bytes" {
    const g: Geometry = .{
        .format = .{ .metadata_size = 0, .lba_data_size_shift = 12, .relative_performance = 0 },
        .data_size_bytes = 4096,
        .metadata_size_bytes = 0,
        .transfer_stride_bytes = 4096,
        .logical_block_count = 1_000_000,
    };
    try testing.expectEqual(@as(u64, 0), try g.dataByteOffsetOf(0));
    try testing.expectEqual(@as(u64, 4096), try g.dataByteOffsetOf(1));
    try testing.expectEqual(@as(u64, 3 * 4096), try g.dataByteOffsetOf(3));
}

test "unit: Geometry.dataByteOffsetOf returns Overflow when lba times data_size_bytes exceeds u64.max" {
    const g: Geometry = .{
        .format = .{ .metadata_size = 0, .lba_data_size_shift = 9, .relative_performance = 0 },
        .data_size_bytes = 2,
        .metadata_size_bytes = 0,
        .transfer_stride_bytes = 2,
        .logical_block_count = 1,
    };
    try testing.expectError(error.Overflow, g.dataByteOffsetOf(std.math.maxInt(u64)));
}

test "unit: Geometry.transferByteOffsetOf returns lba times transfer_stride_bytes" {
    // Method: extended-LBA fixture with stride 4104; lba=3 -> 12312.
    const g: Geometry = .{
        .format = .{ .metadata_size = 8, .lba_data_size_shift = 12, .relative_performance = 0 },
        .data_size_bytes = 4096,
        .metadata_size_bytes = 8,
        .transfer_stride_bytes = 4104,
        .logical_block_count = 100,
    };
    try testing.expectEqual(@as(u64, 12_312), try g.transferByteOffsetOf(3));
}

test "unit: Geometry.transferByteOffsetOf returns Overflow when lba times transfer_stride_bytes exceeds u64.max" {
    const g: Geometry = .{
        .format = .{ .metadata_size = 0, .lba_data_size_shift = 9, .relative_performance = 0 },
        .data_size_bytes = 2,
        .metadata_size_bytes = 0,
        .transfer_stride_bytes = 2,
        .logical_block_count = 1,
    };
    try testing.expectError(error.Overflow, g.transferByteOffsetOf(std.math.maxInt(u64)));
}

test "roundtrip: identify namespace accessors return exactly what a byte fixture encodes" {
    // Method: stamp every accessible scalar/bit/array field into a 4096-byte buffer, validate it,
    // and read back through every accessor. This is the byte-fixture mirror of the init round-trip below.
    var b: [4096]u8 align(8) = @splat(0);

    std.mem.writeInt(u64, b[0x00..][0..8], 4096, .little); // NSZE
    std.mem.writeInt(u64, b[0x08..][0..8], 4096, .little); // NCAP
    std.mem.writeInt(u64, b[0x10..][0..8], 2048, .little); // NUSE
    b[0x18] = 0b0001_0011; // NSFEAT: THINP+NSABP+OPTPERF
    b[0x19] = 3; // NLBAF -> 4 formats
    b[0x1a] = 0x10 | 0x01; // FLBAS: extended_lba=1, low=1
    b[0x1b] = 0b0000_0001; // MC: extended_lba
    b[0x1c] = 0b0000_0111; // DPC: PIT1S/PIT2S/PIT3S
    b[0x1d] = 0b0000_0001; // DPS: PIT=type_1
    b[0x1e] = 0x0F; // NMIC
    b[0x21] = 0b0000_0010; // DLFEAT: read_ones
    std.mem.writeInt(u16, b[0x2e..][0..2], 0xABCD, .little); // NOIOB
    std.mem.writeInt(u64, b[0x30..][0..8], 0xDEADBEEF, .little); // NVMCAP low
    std.mem.writeInt(u64, b[0x38..][0..8], 0x1122_3344, .little); // NVMCAP high

    var nguid_pat: [16]u8 = undefined;
    for (&nguid_pat, 0..) |*c, i| c.* = @intCast(0xC0 + i);
    var eui_pat: [8]u8 = undefined;
    for (&eui_pat, 0..) |*c, i| c.* = @intCast(0xF0 + i);
    @memcpy(b[0x68..0x78], &nguid_pat);
    @memcpy(b[0x78..0x80], &eui_pat);

    // Four LBA formats: 512n / 4Kn / 4K+8 / 8K+16.
    const fmt0: LbaFormat = .{ .metadata_size = 0, .lba_data_size_shift = 9, .relative_performance = 0 };
    const fmt1: LbaFormat = .{ .metadata_size = 0, .lba_data_size_shift = 12, .relative_performance = 1 };
    const fmt2: LbaFormat = .{ .metadata_size = 8, .lba_data_size_shift = 12, .relative_performance = 2 };
    const fmt3: LbaFormat = .{ .metadata_size = 16, .lba_data_size_shift = 13, .relative_performance = 3 };
    std.mem.writeInt(u32, b[0x80..][0..4], @bitCast(fmt0), .little);
    std.mem.writeInt(u32, b[0x84..][0..4], @bitCast(fmt1), .little);
    std.mem.writeInt(u32, b[0x88..][0..4], @bitCast(fmt2), .little);
    std.mem.writeInt(u32, b[0x8c..][0..4], @bitCast(fmt3), .little);

    const id = try IdentifyNamespace.validate(&b);

    try testing.expectEqual(@as(u64, 4096), id.namespaceSize());
    try testing.expectEqual(@as(u64, 4096), id.namespaceCapacity());
    try testing.expectEqual(@as(u64, 2048), id.namespaceUtilization());
    const f = id.features();
    try testing.expectEqual(@as(u1, 1), f.thin_provisioning);
    try testing.expectEqual(@as(u1, 1), f.namespace_atomic_boundaries);
    try testing.expectEqual(@as(u1, 1), f.optimal_performance_hints);
    try testing.expectEqual(@as(u7, 4), id.numberOfLbaFormats());
    try testing.expectEqual(@as(u6, 1), id.formatIndex());
    try testing.expect(id.metadataAsExtendedLba());
    try testing.expectEqual(@as(u1, 1), id.metadataCapabilities().extended_lba);
    const dpc = id.dataProtectionCapabilities();
    try testing.expectEqual(@as(u1, 1), dpc.pi_type_1);
    try testing.expectEqual(@as(u1, 1), dpc.pi_type_2);
    try testing.expectEqual(@as(u1, 1), dpc.pi_type_3);
    try testing.expectEqual(Pit.type_1, id.dataProtectionSettings().pit);
    try testing.expectEqual(@as(u8, 0x0F), id.namespaceMultipathCapabilities());
    try testing.expectEqual(DeallocateReadBehavior.read_ones, id.deallocateFeatures().read_behavior);
    try testing.expectEqual(@as(u16, 0xABCD), id.optimalIoBoundary());
    const expected_cap: u128 = (@as(u128, 0x1122_3344) << 64) | @as(u128, 0xDEADBEEF);
    try testing.expectEqual(expected_cap, id.nvmCapacityBytes());
    try testing.expectEqual(nguid_pat, id.nguid());
    try testing.expectEqual(eui_pat, id.eui64());
    try testing.expectEqual(fmt0, try id.lbaFormat(0));
    try testing.expectEqual(fmt1, try id.lbaFormat(1));
    try testing.expectEqual(fmt2, try id.lbaFormat(2));
    try testing.expectEqual(fmt3, try id.lbaFormat(3));
    try testing.expectEqual(fmt1, try id.selectedLbaFormat()); // FLBAS index = 1
}

test "unit: IdentifyNamespace.init(target, .{}) is spec-legal all-zero storage with default reserved padding" {
    // Method: default-init a scratch struct; every wire byte must be zero — reserved regions,
    // NGUID/EUI64, and the LBAF table all zero-defaulted.
    var scratch: IdentifyNamespace = undefined;
    IdentifyNamespace.init(&scratch, .{});
    const bytes = std.mem.asBytes(&scratch);

    for (bytes) |c| try testing.expectEqual(@as(u8, 0), c);

    const p: *const IdentifyNamespace = &scratch;
    try testing.expectEqual(@as(u64, 0), p.namespaceSize());
    try testing.expectEqual(@as(u64, 0), p.namespaceCapacity());
    try testing.expectEqual(@as(u128, 0), p.nvmCapacityBytes());
    try testing.expectEqual([_]u8{0} ** 16, p.nguid());
    try testing.expectEqual([_]u8{0} ** 8, p.eui64());
}

test "roundtrip: IdentifyNamespace.init round-trips every field through accessors including LBAF table" {
    // Method: populate every non-reserved Init lane including a distinct LbaFormat in every one
    // of the 64 slots; construct via init; assert every accessor returns the input.
    var nguid_pat: [16]u8 = undefined;
    for (&nguid_pat, 0..) |*c, i| c.* = @intCast(0x10 + i);
    var eui_pat: [8]u8 = undefined;
    for (&eui_pat, 0..) |*c, i| c.* = @intCast(0x80 + i);

    var lbaf_pat: [namespace.max_lba_formats]LbaFormat = @splat(@bitCast(@as(u32, 0)));
    for (&lbaf_pat, 0..) |*e, i| {
        // Distinct value in every entry: metadata_size varies, shift varies within legal range.
        e.* = .{
            .metadata_size = @intCast(i),
            .lba_data_size_shift = 9 + @as(u8, @intCast(i % 4)),
            .relative_performance = @intCast(i % 4),
        };
    }

    const params: IdentifyNamespace.Init = .{
        .nsze = 1_000_000,
        .ncap = 1_000_000,
        .nuse = 500_000,
        .nsfeat = @bitCast(@as(u8, 0b0001_1111)),
        .nlbaf = 63,
        .flbas = (0b01 << 5) | 0x02, // assembled = 0x12 = 18
        .mc = @bitCast(@as(u8, 0x03)),
        .dpc = @bitCast(@as(u8, 0x1F)),
        .dps = @bitCast(@as(u8, 0b0000_1010)),
        .nmic = 0xA5,
        .rescap = 0x5A,
        .fpi = 0x77,
        .dlfeat = @bitCast(@as(u8, 0b0001_1010)),
        .nawun = 0x1111,
        .nawupf = 0x2222,
        .nacwu = 0x3333,
        .nabsn = 0x4444,
        .nabo = 0x5555,
        .nabspf = 0x6666,
        .noiob = 0x7777,
        .nvmcap_low = 0xDEAD_BEEF_CAFE_BABE,
        .nvmcap_high = 0x0BAD_F00D_1234_5678,
        .nguid = nguid_pat,
        .eui64 = eui_pat,
        .lbaf = lbaf_pat,
    };

    var target: IdentifyNamespace = undefined;
    IdentifyNamespace.init(&target, params);
    const id: *const IdentifyNamespace = &target;

    try testing.expectEqual(@as(u64, 1_000_000), id.namespaceSize());
    try testing.expectEqual(@as(u64, 1_000_000), id.namespaceCapacity());
    try testing.expectEqual(@as(u64, 500_000), id.namespaceUtilization());
    try testing.expectEqual(@as(u8, 0b0001_1111), @as(u8, @bitCast(id.features())));
    try testing.expectEqual(@as(u7, 64), id.numberOfLbaFormats());
    try testing.expectEqual(@as(u6, 0x12), id.formatIndex());
    try testing.expect(!id.metadataAsExtendedLba()); // bit 4 not set in FLBAS
    try testing.expectEqual(@as(u8, 0x03), @as(u8, @bitCast(id.metadataCapabilities())));
    try testing.expectEqual(@as(u8, 0x1F), @as(u8, @bitCast(id.dataProtectionCapabilities())));
    try testing.expectEqual(@as(u8, 0b0000_1010), @as(u8, @bitCast(id.dataProtectionSettings())));
    try testing.expectEqual(@as(u8, 0xA5), id.namespaceMultipathCapabilities());
    try testing.expectEqual(@as(u8, 0b0001_1010), @as(u8, @bitCast(id.deallocateFeatures())));
    try testing.expectEqual(@as(u16, 0x7777), id.optimalIoBoundary());
    const expected_cap: u128 =
        (@as(u128, 0x0BAD_F00D_1234_5678) << 64) | @as(u128, 0xDEAD_BEEF_CAFE_BABE);
    try testing.expectEqual(expected_cap, id.nvmCapacityBytes());
    try testing.expectEqual(nguid_pat, id.nguid());
    try testing.expectEqual(eui_pat, id.eui64());

    // Every LBAF slot preserved.
    for (lbaf_pat, 0..) |expected, i| {
        const got = try id.lbaFormat(@intCast(i));
        try testing.expectEqual(expected, got);
    }
    // selectedLbaFormat -> formatIndex=0x12 -> lbaf_pat[18].
    try testing.expectEqual(lbaf_pat[18], try id.selectedLbaFormat());
}

test "unit: identify namespace accessors emit no barrier" {
    // Method: behavioral proxy — because the accessor set is a pure function of the storage
    // slice, validate + accessor calls on caller-owned memory must return exactly the stamped
    // bytes without any implicit synchronization. If an accessor issued a memory barrier
    // (release or acquire) the returned value would still equal input, but the design contract
    // is that ordering is the caller's responsibility. This test documents that contract by
    // exercising validate + one accessor from every accessor family in sequence and asserting
    // no observable side effect beyond the returned value.
    var b: [4096]u8 align(8) = @splat(0);
    std.mem.writeInt(u64, b[0x00..][0..8], 0xAAAA_BBBB_CCCC_DDDD, .little);
    b[0x18] = 0b0000_0001;
    b[0x19] = 0;
    b[0x1a] = 0x00;
    b[0x1b] = 0x01;
    b[0x1c] = 0x01;
    b[0x1d] = 0x00;
    b[0x21] = 0x00;
    std.mem.writeInt(u32, b[0x80..][0..4], @bitCast(LbaFormat{
        .metadata_size = 0,
        .lba_data_size_shift = 9,
        .relative_performance = 0,
    }), .little);

    const id = try IdentifyNamespace.validate(&b);
    try testing.expectEqual(@as(u64, 0xAAAA_BBBB_CCCC_DDDD), id.namespaceSize());
    try testing.expectEqual(@as(u1, 1), id.features().thin_provisioning);
    try testing.expectEqual(@as(u7, 1), id.numberOfLbaFormats());
    try testing.expectEqual(@as(u6, 0), id.formatIndex());
    try testing.expect(!id.metadataAsExtendedLba());
    try testing.expectEqual(@as(u1, 1), id.metadataCapabilities().extended_lba);
    try testing.expectEqual(@as(u1, 1), id.dataProtectionCapabilities().pi_type_1);
    _ = id.dataProtectionSettings();
    _ = id.deallocateFeatures();
    _ = id.namespaceMultipathCapabilities();
    _ = id.optimalIoBoundary();
    _ = id.nvmCapacityBytes();
    _ = id.nguid();
    _ = id.eui64();
    _ = try id.lbaFormat(0);
    _ = try id.selectedLbaFormat();
    _ = try id.geometry();
}

test "golden: identify namespace 512e minimal bytes decode" {
    // Method: compose bytes from the same golden Init the regen program uses; assert byte-equal
    // to the on-disk fixture; then validate the golden bytes and read accessors.
    const composed = regen_512e.compose();
    const embedded = @embedFile("../fixtures/identify/namespace_512e_minimal.bin");
    try testing.expectEqual(@as(usize, namespace.size_bytes), embedded.len);
    try testing.expectEqualSlices(u8, embedded, &composed);

    var golden: [namespace.size_bytes]u8 align(8) = undefined;
    @memcpy(&golden, embedded);
    const id = try IdentifyNamespace.validate(&golden);
    try testing.expectEqual(@as(u64, 2048), id.namespaceSize());
    try testing.expectEqual(@as(u64, 2048), id.namespaceCapacity());
    try testing.expectEqual(@as(u7, 1), id.numberOfLbaFormats());
    const g = try id.geometry();
    try testing.expectEqual(@as(usize, 512), g.data_size_bytes);
    try testing.expectEqual(@as(usize, 0), g.metadata_size_bytes);
    try testing.expectEqual(@as(usize, 512), g.transfer_stride_bytes);
    try testing.expectEqual(@as(u64, 2048), g.logical_block_count);
}

test "golden: identify namespace 4kn minimal bytes decode" {
    // Method: same compose/embed/validate loop against the 4 KiB LBA fixture.
    const composed = regen_4kn.compose();
    const embedded = @embedFile("../fixtures/identify/namespace_4kn_minimal.bin");
    try testing.expectEqual(@as(usize, namespace.size_bytes), embedded.len);
    try testing.expectEqualSlices(u8, embedded, &composed);

    var golden: [namespace.size_bytes]u8 align(8) = undefined;
    @memcpy(&golden, embedded);
    const id = try IdentifyNamespace.validate(&golden);
    try testing.expectEqual(@as(u64, 256), id.namespaceSize());
    const g = try id.geometry();
    try testing.expectEqual(@as(usize, 4096), g.data_size_bytes);
    try testing.expectEqual(@as(usize, 0), g.metadata_size_bytes);
    try testing.expectEqual(@as(usize, 4096), g.transfer_stride_bytes);
    try testing.expectEqual(@as(u64, 256), g.logical_block_count);
    try testing.expect(!id.metadataAsExtendedLba());
}

test "unit: list size is 4096 bytes" {
    try testing.expectEqual(@as(usize, 4096), @sizeOf(List));
    try testing.expectEqual(List.list_size_bytes, @sizeOf(List));
}

test "unit: list _entries starts at offset 0 and spans 4096 bytes" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(List, "_entries"));
    try testing.expectEqual(@as(usize, 4096), @sizeOf([List.max_entries]u32));
}

test "unit: List.validate rejects buffer shorter than 4096 with ShortBuffer" {
    var b: [4095]u8 align(4) = @splat(0);
    try testing.expectError(error.ShortBuffer, List.validate(&b));
}

test "unit: List.validate rejects misaligned byte pointer with Misaligned" {
    var b: [4097]u8 align(4) = @splat(0);
    try testing.expectError(error.Misaligned, List.validate(b[1..4097]));
}

test "unit: List.validate accepts exact 4096-byte buffer" {
    var b: [4096]u8 align(4) = @splat(0);
    const list = try List.validate(&b);
    try testing.expectEqual(@as(u16, 0), list.entryCount());
}

test "unit: list accessors work on a typed pointer without going through validate" {
    var t: List = .{};
    t._entries[0] = 7;
    const p: *const List = &t;
    try testing.expectEqual(@as(u32, 7), (try p.entry(0)).raw());
}

test "unit: List.entry rejects index >= 1024 with EntryIndexOutOfRange" {
    var t: List = .{};
    const p: *const List = &t;
    try testing.expectError(error.EntryIndexOutOfRange, p.entry(1024));
    try testing.expectError(error.EntryIndexOutOfRange, p.entry(0xFFFF));
}

test "unit: List.entry returns Nsid.from(raw) for every in-range index" {
    // Method: stamp a distinct raw u32 at a handful of representative in-range slots
    // (0, mid, penultimate, last) and assert entry(i).raw() matches the stamp.
    var t: List = .{};
    t._entries[0] = 1;
    t._entries[1] = 5;
    t._entries[500] = 0xABCD_1234;
    t._entries[1022] = 0xFFFF_FFFE;
    t._entries[1023] = 0xFFFF_FFFF;
    const p: *const List = &t;
    try testing.expectEqual(@as(u32, 1), (try p.entry(0)).raw());
    try testing.expectEqual(@as(u32, 5), (try p.entry(1)).raw());
    try testing.expectEqual(@as(u32, 0xABCD_1234), (try p.entry(500)).raw());
    try testing.expectEqual(@as(u32, 0xFFFF_FFFE), (try p.entry(1022)).raw());
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), (try p.entry(1023)).raw());
}

test "unit: List.entryCount returns 0 for all-zero buffer" {
    var t: List = .{};
    const p: *const List = &t;
    try testing.expectEqual(@as(u16, 0), p.entryCount());
}

test "unit: List.entryCount returns 1024 when no zero terminator is present" {
    var t: List = .{};
    var i: usize = 0;
    while (i < List.max_entries) : (i += 1) t._entries[i] = @intCast(i + 1);
    const p: *const List = &t;
    try testing.expectEqual(@as(u16, 1024), p.entryCount());
}

test "unit: List.entryCount returns index of first zero slot" {
    // Method: prefix of 7 non-zero entries then a zero terminator; scan must stop at index 7.
    var t: List = .{};
    t._entries[0] = 1;
    t._entries[1] = 2;
    t._entries[2] = 3;
    t._entries[3] = 4;
    t._entries[4] = 5;
    t._entries[5] = 6;
    t._entries[6] = 7;
    // t._entries[7] is 0 by default.
    // Even a later non-zero slot must not affect the count.
    t._entries[500] = 999;
    const p: *const List = &t;
    try testing.expectEqual(@as(u16, 7), p.entryCount());
}

test "unit: List.iterator yields the live prefix and stops at zero terminator" {
    // Method: iterator must yield [1, 2, 3] and then null even though later slots are non-zero.
    var t: List = .{};
    t._entries[0] = 1;
    t._entries[1] = 2;
    t._entries[2] = 3;
    t._entries[3] = 0;
    t._entries[10] = 999;
    var iter = (&t).iterator();
    try testing.expectEqual(@as(u32, 1), iter.next().?.raw());
    try testing.expectEqual(@as(u32, 2), iter.next().?.raw());
    try testing.expectEqual(@as(u32, 3), iter.next().?.raw());
    try testing.expectEqual(@as(?Nsid, null), iter.next());
    try testing.expectEqual(@as(?Nsid, null), iter.next()); // stays null on further calls
}

test "unit: List.iterator yields all 1024 entries when no zero terminator is present" {
    var t: List = .{};
    var i: usize = 0;
    while (i < List.max_entries) : (i += 1) t._entries[i] = @intCast(i + 1);
    var iter = (&t).iterator();
    var seen: usize = 0;
    while (iter.next()) |nsid| : (seen += 1) {
        try testing.expectEqual(@as(u32, @intCast(seen + 1)), nsid.raw());
    }
    try testing.expectEqual(@as(usize, List.max_entries), seen);
}

test "unit: List.rawEntries returns 1024-element u32 slice at offset 0" {
    var t: List = .{};
    t._entries[0] = 0x1111_1111;
    t._entries[1023] = 0x2222_2222;
    const p: *const List = &t;
    const raw = p.rawEntries();
    try testing.expectEqual(@as(usize, List.max_entries), raw.len);
    try testing.expectEqual(@as(u32, 0x1111_1111), raw[0]);
    try testing.expectEqual(@as(u32, 0x2222_2222), raw[1023]);
    // Pointer aliases the underlying storage.
    try testing.expectEqual(@intFromPtr(&t._entries[0]), @intFromPtr(raw.ptr));
}

test "unit: List.init(target, .{}) is spec-legal all-zero storage" {
    var target: List = undefined;
    List.init(&target, .{});
    const bytes = std.mem.asBytes(&target);
    for (bytes) |c| try testing.expectEqual(@as(u8, 0), c);
    try testing.expectEqual(@as(u16, 0), (&target).entryCount());
}

test "unit: List.init with N nsids fills slots 0..N-1 and zeroes slots N..1023" {
    const nsids = [_]Nsid{ Nsid.from(1), Nsid.from(2), Nsid.from(3) };
    var target: List = undefined;
    List.init(&target, .{ .nsids = &nsids });
    try testing.expectEqual(@as(u32, 1), target._entries[0]);
    try testing.expectEqual(@as(u32, 2), target._entries[1]);
    try testing.expectEqual(@as(u32, 3), target._entries[2]);
    var i: usize = 3;
    while (i < List.max_entries) : (i += 1) {
        try testing.expectEqual(@as(u32, 0), target._entries[i]);
    }
}

test "roundtrip: List.init round-trips slice of Nsid through List.entry" {
    // Method: construct with three distinct NSIDs including a large non-broadcast one; verify
    // entry(i) and iterator() prefix, and confirm the trailing terminator via entryCount.
    const nsids = [_]Nsid{ Nsid.from(1), Nsid.from(2), Nsid.from(0xFFFF_FFFE) };
    var target: List = undefined;
    List.init(&target, .{ .nsids = &nsids });
    const p: *const List = &target;

    try testing.expectEqual(@as(u32, 1), (try p.entry(0)).raw());
    try testing.expectEqual(@as(u32, 2), (try p.entry(1)).raw());
    try testing.expectEqual(@as(u32, 0xFFFF_FFFE), (try p.entry(2)).raw());
    try testing.expectEqual(@as(u16, 3), p.entryCount());

    var iter = p.iterator();
    try testing.expectEqual(@as(u32, 1), iter.next().?.raw());
    try testing.expectEqual(@as(u32, 2), iter.next().?.raw());
    try testing.expectEqual(@as(u32, 0xFFFF_FFFE), iter.next().?.raw());
    try testing.expectEqual(@as(?Nsid, null), iter.next());
}

test "unit: list accessors emit no barrier" {
    // Method: behavioral proxy — validate + every accessor called on caller-owned memory
    // returns exactly the stamped bytes. Ordering across DMA/CQE boundaries is caller-owned
    // per the spec; this test exercises the full accessor set to document that no accessor
    // performs any observable synchronization side effect beyond returning a value.
    var b: [4096]u8 align(4) = @splat(0);
    std.mem.writeInt(u32, b[0..4], 1, .little);
    std.mem.writeInt(u32, b[4..8], 2, .little);
    std.mem.writeInt(u32, b[8..12], 3, .little);
    const list = try List.validate(&b);
    try testing.expectEqual(@as(u16, 3), list.entryCount());
    try testing.expectEqual(@as(u32, 1), (try list.entry(0)).raw());
    var iter = list.iterator();
    _ = iter.next();
    _ = iter.next();
    _ = iter.next();
    try testing.expectEqual(@as(?Nsid, null), iter.next());
    const raw = list.rawEntries();
    try testing.expectEqual(@as(usize, List.max_entries), raw.len);
}

test "golden: list two active nsids decode" {
    // Method: compose from the regen's Init; assert byte-equal to the on-disk fixture;
    // validate + iterate yields {1, 5}; slots >= 2 read zero via rawEntries.
    const composed = regen_list_two.compose();
    const embedded = @embedFile("../fixtures/identify/list_two_active.bin");
    try testing.expectEqual(@as(usize, namespace.size_bytes), embedded.len);
    try testing.expectEqualSlices(u8, embedded, &composed);

    var golden: [namespace.size_bytes]u8 align(4) = undefined;
    @memcpy(&golden, embedded);
    const list = try List.validate(&golden);
    try testing.expectEqual(@as(u16, 2), list.entryCount());
    try testing.expectEqual(@as(u32, 1), (try list.entry(0)).raw());
    try testing.expectEqual(@as(u32, 5), (try list.entry(1)).raw());
    try testing.expectEqual(@as(u32, 0), (try list.entry(2)).raw());

    var iter = list.iterator();
    try testing.expectEqual(@as(u32, 1), iter.next().?.raw());
    try testing.expectEqual(@as(u32, 5), iter.next().?.raw());
    try testing.expectEqual(@as(?Nsid, null), iter.next());
}

test "golden: list dense 1024 active nsids decode" {
    // Method: dense fixture has NSIDs 1..1024 with no zero terminator; iterator yields all 1024.
    const composed = regen_list_dense.compose();
    const embedded = @embedFile("../fixtures/identify/list_dense_1024.bin");
    try testing.expectEqual(@as(usize, namespace.size_bytes), embedded.len);
    try testing.expectEqualSlices(u8, embedded, &composed);

    var golden: [namespace.size_bytes]u8 align(4) = undefined;
    @memcpy(&golden, embedded);
    const list = try List.validate(&golden);
    try testing.expectEqual(@as(u16, 1024), list.entryCount());
    try testing.expectEqual(@as(u32, 1), (try list.entry(0)).raw());
    try testing.expectEqual(@as(u32, 1024), (try list.entry(1023)).raw());

    var iter = list.iterator();
    var seen: u32 = 0;
    while (iter.next()) |nsid| : (seen += 1) {
        try testing.expectEqual(seen + 1, nsid.raw());
    }
    try testing.expectEqual(@as(u32, 1024), seen);
}
