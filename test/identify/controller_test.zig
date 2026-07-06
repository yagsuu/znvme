//! Identify Controller host tests. Spec: docs/specs/identify/controller.md.

const std = @import("std");
const testing = std.testing;

const nvme = @import("nvme");
const controller = nvme.identify.controller;
const regen = @import("../fixtures/identify/controller_minimal_regen.zig");

const IdentifyController = controller.IdentifyController;
const ControllerType = controller.ControllerType;
const MaxDataTransferSize = controller.MaxDataTransferSize;
const EntrySize = controller.EntrySize;
const OacsBits = controller.OacsBits;
const OncsBits = controller.OncsBits;
const FusesBits = controller.FusesBits;

test "unit: identify controller size is 4096 bytes" {
    try testing.expectEqual(@as(usize, 4096), @sizeOf(IdentifyController));
    try testing.expectEqual(controller.size_bytes, @sizeOf(IdentifyController));
}

test "unit: identify controller offsets match NVMe Figure 275" {
    try testing.expectEqual(@as(usize, 0x000), @offsetOf(IdentifyController, "_vid"));
    try testing.expectEqual(@as(usize, 0x002), @offsetOf(IdentifyController, "_ssvid"));
    try testing.expectEqual(@as(usize, 0x004), @offsetOf(IdentifyController, "_sn"));
    try testing.expectEqual(@as(usize, 0x018), @offsetOf(IdentifyController, "_mn"));
    try testing.expectEqual(@as(usize, 0x040), @offsetOf(IdentifyController, "_fr"));
    try testing.expectEqual(@as(usize, 0x048), @offsetOf(IdentifyController, "_rab"));
    try testing.expectEqual(@as(usize, 0x049), @offsetOf(IdentifyController, "_ieee"));
    try testing.expectEqual(@as(usize, 0x04c), @offsetOf(IdentifyController, "_cmic"));
    try testing.expectEqual(@as(usize, 0x04d), @offsetOf(IdentifyController, "_mdts"));
    try testing.expectEqual(@as(usize, 0x04e), @offsetOf(IdentifyController, "_cntlid"));
    try testing.expectEqual(@as(usize, 0x050), @offsetOf(IdentifyController, "_ver"));
    try testing.expectEqual(@as(usize, 0x054), @offsetOf(IdentifyController, "_rtd3r"));
    try testing.expectEqual(@as(usize, 0x058), @offsetOf(IdentifyController, "_rtd3e"));
    try testing.expectEqual(@as(usize, 0x05c), @offsetOf(IdentifyController, "_oaes"));
    try testing.expectEqual(@as(usize, 0x060), @offsetOf(IdentifyController, "_ctratt"));
    try testing.expectEqual(@as(usize, 0x064), @offsetOf(IdentifyController, "_rrls"));
    try testing.expectEqual(@as(usize, 0x06f), @offsetOf(IdentifyController, "_cntrltype"));
    try testing.expectEqual(@as(usize, 0x070), @offsetOf(IdentifyController, "_fguid"));
    try testing.expectEqual(@as(usize, 0x080), @offsetOf(IdentifyController, "_crdt"));
    try testing.expectEqual(@as(usize, 0x100), @offsetOf(IdentifyController, "_oacs"));
    try testing.expectEqual(@as(usize, 0x102), @offsetOf(IdentifyController, "_acl"));
    try testing.expectEqual(@as(usize, 0x103), @offsetOf(IdentifyController, "_aerl"));
    try testing.expectEqual(@as(usize, 0x104), @offsetOf(IdentifyController, "_frmw"));
    try testing.expectEqual(@as(usize, 0x105), @offsetOf(IdentifyController, "_lpa"));
    try testing.expectEqual(@as(usize, 0x106), @offsetOf(IdentifyController, "_elpe"));
    try testing.expectEqual(@as(usize, 0x107), @offsetOf(IdentifyController, "_npss"));
    try testing.expectEqual(@as(usize, 0x108), @offsetOf(IdentifyController, "_avscc"));
    try testing.expectEqual(@as(usize, 0x109), @offsetOf(IdentifyController, "_apsta"));
    try testing.expectEqual(@as(usize, 0x10a), @offsetOf(IdentifyController, "_wctemp"));
    try testing.expectEqual(@as(usize, 0x10c), @offsetOf(IdentifyController, "_cctemp"));
    try testing.expectEqual(@as(usize, 0x200), @offsetOf(IdentifyController, "_sqes"));
    try testing.expectEqual(@as(usize, 0x201), @offsetOf(IdentifyController, "_cqes"));
    try testing.expectEqual(@as(usize, 0x202), @offsetOf(IdentifyController, "_maxcmd"));
    try testing.expectEqual(@as(usize, 0x204), @offsetOf(IdentifyController, "_nn"));
    try testing.expectEqual(@as(usize, 0x208), @offsetOf(IdentifyController, "_oncs"));
    try testing.expectEqual(@as(usize, 0x20a), @offsetOf(IdentifyController, "_fuses"));
    try testing.expectEqual(@as(usize, 0x20c), @offsetOf(IdentifyController, "_fna"));
    try testing.expectEqual(@as(usize, 0x20d), @offsetOf(IdentifyController, "_vwc"));
    try testing.expectEqual(@as(usize, 0x20e), @offsetOf(IdentifyController, "_awun"));
    try testing.expectEqual(@as(usize, 0x210), @offsetOf(IdentifyController, "_awupf"));
    try testing.expectEqual(@as(usize, 0x218), @offsetOf(IdentifyController, "_sgls"));
    try testing.expectEqual(@as(usize, 0x300), @offsetOf(IdentifyController, "_subnqn"));
}

test "unit: identify controller validate rejects buffer shorter than 4096 with ShortBuffer" {
    var b: [4095]u8 align(4) = @splat(0);
    try testing.expectError(error.ShortBuffer, IdentifyController.validate(&b));
}

test "unit: identify controller validate rejects misaligned byte pointer with Misaligned" {
    var b: [4097]u8 align(4) = @splat(0);
    try testing.expectError(error.Misaligned, IdentifyController.validate(b[1..4097]));
}

test "unit: identify controller validate accepts exact 4096-byte buffer" {
    var b: [4096]u8 align(4) = @splat(0);
    const id = try IdentifyController.validate(&b);
    try testing.expectEqual(@as(u16, 0), id.vendorId());
}

test "unit: identify controller accessors work on a typed pointer without going through validate" {
    var t: IdentifyController = .{};
    t._vid = 0xBEEF;
    try testing.expectEqual(@as(u16, 0xBEEF), (&t).vendorId());
}

test "unit: identify controller decodes VID SSVID CNTLID VER as native little-endian" {
    var b: [4096]u8 align(4) = @splat(0);
    std.mem.writeInt(u16, b[0x000..][0..2], 0x1234, .little);
    std.mem.writeInt(u16, b[0x002..][0..2], 0x5678, .little);
    std.mem.writeInt(u16, b[0x04e..][0..2], 0xABCD, .little);
    std.mem.writeInt(u32, b[0x050..][0..4], 0x0001_0400, .little);
    const id = try IdentifyController.validate(&b);
    try testing.expectEqual(@as(u16, 0x1234), id.vendorId());
    try testing.expectEqual(@as(u16, 0x5678), id.subsystemVendorId());
    try testing.expectEqual(@as(u16, 0xABCD), id.controllerId());
    try testing.expectEqual(@as(u32, 0x0001_0400), id.version());
}

test "unit: identify controller decodes SN MN FR as byte slices with fixed lengths" {
    var b: [4096]u8 align(4) = @splat(0);
    const sn_pattern: [20]u8 = "SN0000000000000042  ".*;
    const mn_pattern: [40]u8 = "znvme-boot                              ".*;
    const fr_pattern: [8]u8 = "1.2.3.4 ".*;
    @memcpy(b[0x004..0x018], &sn_pattern);
    @memcpy(b[0x018..0x040], &mn_pattern);
    @memcpy(b[0x040..0x048], &fr_pattern);
    const id = try IdentifyController.validate(&b);
    try testing.expectEqual(@as(usize, 20), id.serialNumber().len);
    try testing.expectEqual(@as(usize, 40), id.modelNumber().len);
    try testing.expectEqual(@as(usize, 8), id.firmwareRevision().len);
    try testing.expectEqualSlices(u8, &sn_pattern, id.serialNumber());
    try testing.expectEqualSlices(u8, &mn_pattern, id.modelNumber());
    try testing.expectEqualSlices(u8, &fr_pattern, id.firmwareRevision());
}

test "unit: identify controller decodes SUBNQN as 256-byte slice preserving trailing NUL padding" {
    var b: [4096]u8 align(4) = @splat(0);
    const head = "nqn.example";
    @memcpy(b[0x300 .. 0x300 + head.len], head);
    const id = try IdentifyController.validate(&b);
    try testing.expectEqual(@as(usize, 256), id.subsystemNqn().len);
    try testing.expectEqualSlices(u8, head, id.subsystemNqn()[0..head.len]);
    for (id.subsystemNqn()[head.len..]) |c| try testing.expectEqual(@as(u8, 0), c);
}

test "unit: identify controller controllerType returns io for 0x01 and preserves unknown values" {
    var b: [4096]u8 align(4) = @splat(0);
    b[0x06f] = 0x01;
    const id1 = try IdentifyController.validate(&b);
    try testing.expectEqual(ControllerType.io, id1.controllerType());

    b[0x06f] = 0x7F;
    const id2 = try IdentifyController.validate(&b);
    try testing.expectEqual(@as(u8, 0x7F), @intFromEnum(id2.controllerType()));
}

test "unit: identify controller maxDataTransferSize returns unlimited for MDTS zero" {
    var b: [4096]u8 align(4) = @splat(0);
    b[0x04d] = 0;
    const id = try IdentifyController.validate(&b);
    switch (id.maxDataTransferSize()) {
        .unlimited => {},
        .page_shift => return error.TestExpectedUnlimited,
    }
}

test "unit: identify controller maxDataTransferSize returns page_shift for non-zero MDTS" {
    var b: [4096]u8 align(4) = @splat(0);
    b[0x04d] = 5;
    const id = try IdentifyController.validate(&b);
    switch (id.maxDataTransferSize()) {
        .unlimited => return error.TestExpectedPageShift,
        .page_shift => |s| try testing.expectEqual(@as(u8, 5), s),
    }
}

test "unit: MaxDataTransferSize.maxBytes shifts min_page_size by MDTS for in-range page_shift" {
    const mdts: MaxDataTransferSize = .{ .page_shift = 3 };
    const got = try mdts.maxBytes(4096);
    try testing.expectEqual(@as(?usize, 4096 << 3), got);
}

test "unit: MaxDataTransferSize.maxBytes errors when page_shift >= @bitSizeOf(usize)" {
    const mdts: MaxDataTransferSize = .{ .page_shift = @bitSizeOf(usize) };
    try testing.expectError(error.MaxDataTransferSizeTooLarge, mdts.maxBytes(4096));
}

test "unit: MaxDataTransferSize.maxBytes errors on shift overflow of min_page_size" {
    const mdts: MaxDataTransferSize = .{ .page_shift = 1 };
    try testing.expectError(error.MaxDataTransferSizeTooLarge, mdts.maxBytes(std.math.maxInt(usize)));
}

test "unit: identify controller submissionQueueEntrySize decodes required and max nibbles" {
    var b: [4096]u8 align(4) = @splat(0);
    b[0x200] = 0x66;
    const id = try IdentifyController.validate(&b);
    const sqes = id.submissionQueueEntrySize();
    try testing.expectEqual(@as(u4, 6), sqes.required_shift);
    try testing.expectEqual(@as(u4, 6), sqes.max_shift);
}

test "unit: identify controller completionQueueEntrySize decodes required and max nibbles" {
    var b: [4096]u8 align(4) = @splat(0);
    b[0x201] = 0x44;
    const id = try IdentifyController.validate(&b);
    const cqes = id.completionQueueEntrySize();
    try testing.expectEqual(@as(u4, 4), cqes.required_shift);
    try testing.expectEqual(@as(u4, 4), cqes.max_shift);
}

test "unit: identify controller EntrySize.requiredBytes and maxBytes return 2^n bytes" {
    const es: EntrySize = .{ .required_shift = 6, .max_shift = 4 };
    try testing.expectEqual(@as(usize, 64), es.requiredBytes());
    try testing.expectEqual(@as(usize, 16), es.maxBytes());
}

test "unit: identify controller OacsBits decodes doorbell_buffer_config and get_lba_status flags" {
    var b: [4096]u8 align(4) = @splat(0);
    // bits 8 (doorbell_buffer_config) and 9 (get_lba_status).
    std.mem.writeInt(u16, b[0x100..][0..2], 0x0300, .little);
    const id = try IdentifyController.validate(&b);
    const oacs = id.optionalAdminCommandSupport();
    try testing.expectEqual(@as(u1, 1), oacs.doorbell_buffer_config);
    try testing.expectEqual(@as(u1, 1), oacs.get_lba_status);
    try testing.expectEqual(@as(u1, 0), oacs.security_send_receive);
    try testing.expectEqual(@as(u1, 0), oacs.format_nvm);
}

test "unit: identify controller OncsBits decodes dataset_management write_zeroes verify flags" {
    var b: [4096]u8 align(4) = @splat(0);
    // bits 2 (dataset_management), 3 (write_zeroes), 7 (verify) → 0x008C.
    std.mem.writeInt(u16, b[0x208..][0..2], 0x008C, .little);
    const id = try IdentifyController.validate(&b);
    const oncs = id.optionalNvmCommandSupport();
    try testing.expectEqual(@as(u1, 1), oncs.dataset_management);
    try testing.expectEqual(@as(u1, 1), oncs.write_zeroes);
    try testing.expectEqual(@as(u1, 1), oncs.verify);
    try testing.expectEqual(@as(u1, 0), oncs.compare);
    try testing.expectEqual(@as(u1, 0), oncs.write_uncorrectable);
}

test "unit: identify controller FusesBits decodes compare_and_write flag" {
    var b: [4096]u8 align(4) = @splat(0);
    std.mem.writeInt(u16, b[0x20a..][0..2], 0x0001, .little);
    const id = try IdentifyController.validate(&b);
    const fuses = id.fusedOperationSupport();
    try testing.expectEqual(@as(u1, 1), fuses.compare_and_write);
}

test "unit: identify controller sglSupport supported returns true for non-zero SGLS bits 1:0" {
    var b: [4096]u8 align(4) = @splat(0);
    std.mem.writeInt(u32, b[0x218..][0..4], 0x0000_0001, .little);
    const id1 = try IdentifyController.validate(&b);
    try testing.expect(id1.sglSupport().supported());

    std.mem.writeInt(u32, b[0x218..][0..4], 0x0000_0100, .little);
    const id2 = try IdentifyController.validate(&b);
    try testing.expect(!id2.sglSupport().supported());
}

test "unit: identify controller maxOutstandingCommands and numberOfNamespaces decode as native little-endian" {
    var b: [4096]u8 align(4) = @splat(0);
    std.mem.writeInt(u16, b[0x202..][0..2], 0x1234, .little);
    std.mem.writeInt(u32, b[0x204..][0..4], 0x0001_0203, .little);
    const id = try IdentifyController.validate(&b);
    try testing.expectEqual(@as(u16, 0x1234), id.maxOutstandingCommands());
    try testing.expectEqual(@as(u32, 0x0001_0203), id.numberOfNamespaces());
}

test "roundtrip: identify controller accessors return exactly what a byte fixture encodes" {
    var b: [4096]u8 align(4) = @splat(0);

    std.mem.writeInt(u16, b[0x000..][0..2], 0xAAAA, .little); // VID
    std.mem.writeInt(u16, b[0x002..][0..2], 0xBBBB, .little); // SSVID
    const sn: [20]u8 = "SNROUNDTRIP000000001".*;
    @memcpy(b[0x004..0x018], &sn);
    const mn: [40]u8 = "znvme-roundtrip-model-abcdefghijklmnopqr".*;
    @memcpy(b[0x018..0x040], &mn);
    const fr: [8]u8 = "abcdefgh".*;
    @memcpy(b[0x040..0x048], &fr);
    b[0x048] = 0x07; // RAB
    b[0x049] = 0x11;
    b[0x04a] = 0x22;
    b[0x04b] = 0x33; // IEEE
    b[0x04c] = 0x0F; // CMIC
    b[0x04d] = 0x05; // MDTS
    std.mem.writeInt(u16, b[0x04e..][0..2], 0xCAFE, .little); // CNTLID
    std.mem.writeInt(u32, b[0x050..][0..4], 0x0001_0400, .little); // VER
    b[0x06f] = @intFromEnum(ControllerType.io); // CNTRLTYPE

    // OACS + admin body block
    std.mem.writeInt(u16, b[0x100..][0..2], 0x0300, .little); // OACS
    b[0x102] = 1; // ACL
    b[0x103] = 2; // AERL
    b[0x104] = 3; // FRMW
    b[0x105] = 4; // LPA
    b[0x106] = 5; // ELPE
    b[0x107] = 6; // NPSS
    b[0x108] = 7; // AVSCC
    b[0x109] = 8; // APSTA
    std.mem.writeInt(u16, b[0x10a..][0..2], 350, .little); // WCTEMP
    std.mem.writeInt(u16, b[0x10c..][0..2], 360, .little); // CCTEMP

    // NVM command set body
    b[0x200] = 0x66; // SQES
    b[0x201] = 0x44; // CQES
    std.mem.writeInt(u16, b[0x202..][0..2], 256, .little); // MAXCMD
    std.mem.writeInt(u32, b[0x204..][0..4], 0x0000_0008, .little); // NN
    std.mem.writeInt(u16, b[0x208..][0..2], 0x008C, .little); // ONCS
    std.mem.writeInt(u16, b[0x20a..][0..2], 0x0001, .little); // FUSES
    std.mem.writeInt(u16, b[0x20e..][0..2], 0xABCD, .little); // AWUN
    std.mem.writeInt(u16, b[0x210..][0..2], 0xDCBA, .little); // AWUPF
    std.mem.writeInt(u32, b[0x218..][0..4], 0x0000_0001, .little); // SGLS

    const subnqn_head = "nqn.2026-07.dev.znvme:roundtrip";
    @memcpy(b[0x300 .. 0x300 + subnqn_head.len], subnqn_head);

    const id = try IdentifyController.validate(&b);

    try testing.expectEqual(@as(u16, 0xAAAA), id.vendorId());
    try testing.expectEqual(@as(u16, 0xBBBB), id.subsystemVendorId());
    try testing.expectEqualSlices(u8, &sn, id.serialNumber());
    try testing.expectEqualSlices(u8, &mn, id.modelNumber());
    try testing.expectEqualSlices(u8, &fr, id.firmwareRevision());
    try testing.expectEqual(@as(u8, 0x07), id.recommendedArbitrationBurst());
    try testing.expectEqual([3]u8{ 0x11, 0x22, 0x33 }, id.ieeeOui());
    try testing.expectEqual(@as(u16, 0xCAFE), id.controllerId());
    try testing.expectEqual(@as(u32, 0x0001_0400), id.version());
    try testing.expectEqual(ControllerType.io, id.controllerType());
    switch (id.maxDataTransferSize()) {
        .unlimited => return error.TestExpectedPageShift,
        .page_shift => |s| try testing.expectEqual(@as(u8, 5), s),
    }
    const oacs = id.optionalAdminCommandSupport();
    try testing.expectEqual(@as(u16, 0x0300), @as(u16, @bitCast(oacs)));
    const sqes = id.submissionQueueEntrySize();
    try testing.expectEqual(@as(u4, 6), sqes.required_shift);
    try testing.expectEqual(@as(u4, 6), sqes.max_shift);
    const cqes = id.completionQueueEntrySize();
    try testing.expectEqual(@as(u4, 4), cqes.required_shift);
    try testing.expectEqual(@as(u4, 4), cqes.max_shift);
    try testing.expectEqual(@as(u16, 256), id.maxOutstandingCommands());
    try testing.expectEqual(@as(u32, 8), id.numberOfNamespaces());
    const oncs = id.optionalNvmCommandSupport();
    try testing.expectEqual(@as(u16, 0x008C), @as(u16, @bitCast(oncs)));
    const fuses = id.fusedOperationSupport();
    try testing.expectEqual(@as(u16, 0x0001), @as(u16, @bitCast(fuses)));
    try testing.expectEqual(@as(u16, 0xABCD), id.atomicWriteUnitNormal());
    try testing.expectEqual(@as(u16, 0xDCBA), id.atomicWriteUnitPowerFail());
    try testing.expect(id.sglSupport().supported());
    try testing.expectEqualSlices(u8, subnqn_head, id.subsystemNqn()[0..subnqn_head.len]);
}

test "golden: identify controller minimal bytes decode" {
    // Compose bytes from the same golden Init the regen program uses.
    var scratch: IdentifyController = undefined;
    IdentifyController.init(&scratch, regen.golden_init);
    const composed = std.mem.asBytes(&scratch);

    const embedded = @embedFile("../fixtures/identify/controller_minimal.bin");
    try testing.expectEqual(@as(usize, controller.size_bytes), embedded.len);
    try testing.expectEqualSlices(u8, embedded, composed);

    // Validate the on-disk golden bytes as a real host would; copy into an
    // aligned buffer since `@embedFile` yields byte-aligned storage.
    var golden: [controller.size_bytes]u8 align(4) = undefined;
    @memcpy(&golden, embedded);
    const id = try IdentifyController.validate(&golden);
    try testing.expectEqual(@as(u16, 0x1234), id.vendorId());
    try testing.expectEqual(ControllerType.io, id.controllerType());
    const sqes = id.submissionQueueEntrySize();
    try testing.expectEqual(@as(u4, 6), sqes.required_shift);
    try testing.expectEqual(@as(u4, 6), sqes.max_shift);
    const cqes = id.completionQueueEntrySize();
    try testing.expectEqual(@as(u4, 4), cqes.required_shift);
    try testing.expectEqual(@as(u4, 4), cqes.max_shift);
    try testing.expectEqual(@as(u32, 1), id.numberOfNamespaces());
    try testing.expectEqualSlices(u8, "SN0000000000000001  ", id.serialNumber());
    try testing.expectEqualSlices(u8, "znvme-mock                              ", id.modelNumber());
    try testing.expectEqualSlices(u8, "1.0.0.0 ", id.firmwareRevision());
    const nqn_head = "nqn.2026-07.dev.znvme:znvme-mock";
    try testing.expectEqualSlices(u8, nqn_head, id.subsystemNqn()[0..nqn_head.len]);
    switch (id.maxDataTransferSize()) {
        .unlimited => {},
        .page_shift => return error.TestExpectedUnlimited,
    }
}

test "unit: IdentifyController.init(target, .{}) is spec-legal all-zero storage with default reserved padding" {
    var scratch: IdentifyController = undefined;
    IdentifyController.init(&scratch, .{});
    const bytes = std.mem.asBytes(&scratch);

    // SN/MN/FR default to ASCII space padding.
    for (bytes[0x004..0x018]) |c| try testing.expectEqual(@as(u8, 0x20), c);
    for (bytes[0x018..0x040]) |c| try testing.expectEqual(@as(u8, 0x20), c);
    for (bytes[0x040..0x048]) |c| try testing.expectEqual(@as(u8, 0x20), c);

    // Reserved regions must all be zero.
    for (bytes[0x066..0x06f]) |c| try testing.expectEqual(@as(u8, 0), c); // _reserved_66
    for (bytes[0x086..0x100]) |c| try testing.expectEqual(@as(u8, 0), c); // _reserved_86
    for (bytes[0x10e..0x200]) |c| try testing.expectEqual(@as(u8, 0), c); // _reserved_10e/13c/180
    for (bytes[0x212..0x218]) |c| try testing.expectEqual(@as(u8, 0), c); // _reserved_212
    for (bytes[0x21c..0x300]) |c| try testing.expectEqual(@as(u8, 0), c); // _reserved_21c
    for (bytes[0x400..0x1000]) |c| try testing.expectEqual(@as(u8, 0), c); // _reserved_400+800+c00

    // fguid, crdt, subnqn default to zero.
    for (bytes[0x070..0x080]) |c| try testing.expectEqual(@as(u8, 0), c); // _fguid
    for (bytes[0x080..0x086]) |c| try testing.expectEqual(@as(u8, 0), c); // _crdt
    for (bytes[0x300..0x400]) |c| try testing.expectEqual(@as(u8, 0), c); // _subnqn

    // Numeric scalars default to zero.
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bytes[0x000..][0..2], .little)); // VID
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bytes[0x002..][0..2], .little)); // SSVID
    try testing.expectEqual(@as(u8, 0), bytes[0x06f]); // CNTRLTYPE
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[0x054..][0..4], .little)); // RTD3R
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[0x058..][0..4], .little)); // RTD3E
}

test "roundtrip: IdentifyController.init round-trips every field through accessors" {
    var subnqn_pattern: [256]u8 = @splat(0);
    for (&subnqn_pattern, 0..) |*c, i| c.* = @intCast(i & 0xFF);
    var fguid: [16]u8 = undefined;
    for (&fguid, 0..) |*c, i| c.* = @intCast(0xA0 + i);

    const oacs_val: OacsBits = @bitCast(@as(u16, 0x0755));
    const oncs_val: OncsBits = @bitCast(@as(u16, 0x018D));
    const fuses_val: FusesBits = @bitCast(@as(u16, 0x0001));

    const params: IdentifyController.Init = .{
        .vid = 0x1111,
        .ssvid = 0x2222,
        .sn = "SN__ROUNDTRIP_______".*,
        .mn = "MN__ROUNDTRIP_MODEL_ABCDEFGHIJKLMNOPQRST".*,
        .fr = "FRROUND1".*,
        .rab = 7,
        .ieee = .{ 1, 2, 3 },
        .cmic = 0x0F,
        .mdts = 3,
        .cntlid = 0xCAFE,
        .ver = 0x0001_0400,
        .oaes = 0xA5A5_A5A5,
        .ctratt = 0x5A5A_5A5A,
        .rrls = 0x1234,
        .cntrltype = .discovery,
        .fguid = fguid,
        .crdt = .{ 1, 2, 3 },
        .oacs = oacs_val,
        .acl = 1,
        .aerl = 2,
        .frmw = 3,
        .lpa = 4,
        .elpe = 5,
        .npss = 6,
        .avscc = 7,
        .apsta = 8,
        .wctemp = 350,
        .cctemp = 360,
        .sqes = .{ .required_shift = 6, .max_shift = 6 },
        .cqes = .{ .required_shift = 4, .max_shift = 4 },
        .maxcmd = 256,
        .nn = 8,
        .oncs = oncs_val,
        .fuses = fuses_val,
        .fna = 1,
        .vwc = 1,
        .awun = 0xABCD,
        .awupf = 0xDCBA,
        .sgls = 0x0000_0001,
        .subnqn = subnqn_pattern,
    };

    var target: IdentifyController = undefined;
    IdentifyController.init(&target, params);
    const id: *const IdentifyController = &target;

    try testing.expectEqual(@as(u16, 0x1111), id.vendorId());
    try testing.expectEqual(@as(u16, 0x2222), id.subsystemVendorId());
    try testing.expectEqualSlices(u8, &params.sn, id.serialNumber());
    try testing.expectEqualSlices(u8, &params.mn, id.modelNumber());
    try testing.expectEqualSlices(u8, &params.fr, id.firmwareRevision());
    try testing.expectEqual(@as(u8, 7), id.recommendedArbitrationBurst());
    try testing.expectEqual([3]u8{ 1, 2, 3 }, id.ieeeOui());
    try testing.expectEqual(@as(u16, 0xCAFE), id.controllerId());
    try testing.expectEqual(@as(u32, 0x0001_0400), id.version());
    try testing.expectEqual(ControllerType.discovery, id.controllerType());

    switch (id.maxDataTransferSize()) {
        .unlimited => return error.TestExpectedPageShift,
        .page_shift => |s| try testing.expectEqual(@as(u8, 3), s),
    }

    try testing.expectEqual(@as(u16, 0x0755), @as(u16, @bitCast(id.optionalAdminCommandSupport())));
    const sqes_out = id.submissionQueueEntrySize();
    try testing.expectEqual(@as(u8, 0x66), @as(u8, @bitCast(sqes_out)));
    const cqes_out = id.completionQueueEntrySize();
    try testing.expectEqual(@as(u8, 0x44), @as(u8, @bitCast(cqes_out)));
    try testing.expectEqual(@as(u16, 256), id.maxOutstandingCommands());
    try testing.expectEqual(@as(u32, 8), id.numberOfNamespaces());
    try testing.expectEqual(@as(u16, 0x018D), @as(u16, @bitCast(id.optionalNvmCommandSupport())));
    try testing.expectEqual(@as(u16, 0x0001), @as(u16, @bitCast(id.fusedOperationSupport())));
    try testing.expectEqual(@as(u16, 0xABCD), id.atomicWriteUnitNormal());
    try testing.expectEqual(@as(u16, 0xDCBA), id.atomicWriteUnitPowerFail());
    try testing.expect(id.sglSupport().supported());
    try testing.expectEqual(@as(u32, 0x0000_0001), id.sglSupport().raw);
    try testing.expectEqualSlices(u8, &subnqn_pattern, id.subsystemNqn());
}

test "unit: identify controller accessors emit no barrier" {
    const audit = @import("audit_sources");
    try testing.expect(std.mem.indexOf(u8, audit.controller_source, "stdx.barrier") == null);
}
