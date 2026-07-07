# Identify Namespace

Status: Approved.

`[znvme]` `identify.namespace` owns two related NVMe wire structures:

- `[znvme]` `IdentifyNamespace` — the 4 KiB Identify Namespace response for the NVM Command Set (CNS = 00h), with field accessors, the 64-entry `LbaFormat` table, and namespace **geometry** derivation.
- `[znvme]` `List` — the 4 KiB Active Namespace ID list response (CNS = 02h), a zero-terminated `u32` NSID array with a bounds-checked iterator.

`[znvme]` Geometry is the operational payload the boot reader consumes: given a namespace, what is the user-visible data size per LBA, what is the on-wire transfer stride, and how many LBAs are there? This spec derives geometry from validated bytes; the Read/Write builder in `docs/specs/commands/nvm.md` is the primary consumer.

## Owned scope

`[znvme]` This spec owns:

- `[znvme]` `IdentifyNamespace`, a 4096-byte `extern struct` overlay with underscore-prefixed storage fields and colocated `@sizeOf` / `@offsetOf` assertions;
- `[znvme]` semantic accessors on `*const IdentifyNamespace` for `NSZE`, `NCAP`, `NUSE`, `NSFEAT`, `NLBAF`, `FLBAS` (assembled 6-bit format index + extended-LBA bit), `MC`, `DPC`, `DPS`, `NMIC` (raw), `DLFEAT`, `NOIOB`, `NVMCAP`, `NGUID`, `EUI64`, and the 64-entry `LBAF` table;
- `[znvme]` `IdentifyNamespace.validate(bytes) Error!*const IdentifyNamespace`, the byte-window entry point;
- `[znvme]` `IdentifyNamespace.Init` semantic construction params with zero-safe defaults;
- `[znvme]` `IdentifyNamespace.init(target: *IdentifyNamespace, params: Init) void`, in-place value constructor for device-emulator fixtures;
- `[znvme]` `LbaFormat`, a `packed struct(u32)` with `metadata_size`, `lba_data_size_shift`, `relative_performance`, and reserved bits, plus predicates `isAvailable()`, `dataSizeBytes()`, `metadataSizeBytes()`, `totalLbaSizeBytes()`;
- `[znvme]` `Geometry`, a semantic aggregate pairing the selected `LbaFormat` with `NSZE` and exposing `data_size_bytes` / `metadata_size_bytes` / `transfer_stride_bytes` / `logical_block_count`, plus `containsLba(lba)`, `totalDataBytes()`, `totalTransferBytes()`, `dataByteOffsetOf(lba)`, and `transferByteOffsetOf(lba)`;
- `[znvme]` `Pit`, `DeallocateReadBehavior` non-exhaustive enums;
- `[znvme]` `NsFeatBits`, `McBits`, `DpcBits`, `DpsBits`, `DlfeatBits` packed structs for the corresponding wire bytes;
- `[znvme]` `List`, a 4096-byte `extern struct` for the Active Namespace ID list (CNS 02h), with `List.validate`, `List.init`, `List.entry`, `List.entryCount`, `List.iterator`, `List.rawEntries`, and `List.Iterator`;
- `[znvme]` error taxonomy for view validation, geometry derivation, and list indexing;
- `[znvme]` first-slice native little-endian storage on `x86_64-freestanding-none`.

## Deferred scope and non-goals

`[znvme]` This spec does not own:

- `[znvme]` I/O Command Set Independent Identify Namespace (CNS 08h) — the shared cross-Command-Set fields spec is not queued;
- `[znvme]` I/O Command Set specific Identify Namespace for CSI ≠ 0 (Zoned Namespace, KV, Subsystem Local Memory Command Set) — deferred by `docs/specs/project/scope.md`;
- `[znvme]` semantic interpretation of `EUI64` or `NGUID` beyond returning the preserved big-endian bytes;
- `[znvme]` performance-hint fields NPWG, NPWA, NPDG, NPDA, NOWS — reserved padding in the extern overlay; not surfaced through accessors in the first slice;
- `[znvme]` Copy command fields MSSRL, MCL, MSRC — deferred until an approved Copy spec claims them;
- `[znvme]` ANA group identifier, reservation capabilities, NVM Set identifier, endurance group identifier;
- `[znvme]` vendor-specific 3712-byte tail;
- `[znvme]` end-to-end data protection processing beyond decoding the `DPC` / `DPS` bit fields;
- `[znvme]` Format NVM command handling — `docs/specs/project/scope.md` non-goals;
- `[znvme]` retrieval mechanics — `docs/specs/commands/admin.md` owns the builder;
- `[znvme]` `List` monotonicity validation — NVMe requires the list monotonically increasing across active NSIDs; this is a device-authored contract, not a byte-layout requirement. Callers who need it iterate and compare adjacent pairs. A future opt-in seam remains available;
- `[znvme]` `List` live-entry admissibility beyond the zero terminator — `Nsid.broadcast` (`0xFFFF_FFFF`) inside the live prefix is not rejected. Callers filter with `Nsid.isValidNamespace()`;
- `[znvme]` Allocated Namespace ID list (CNS 10h) and I/O Command Set-specific Active Namespace ID list (CNS 07h) — deferred by `docs/specs/commands/admin.md` non-goals;
- `[znvme]` big-endian host or target compatibility.

## `stdx` composition

`[znvme]` `IdentifyNamespace` composes only the `[]const u8` byte slice, `extern struct` field access, and `std.math.mul` for overflow-checked geometry arithmetic.

`[znvme]` `List` composes `stdx.tags.Tag(NsidDomain, u32)` through `ids.Nsid.from(raw)` at the accessor boundary.

## NVMe wire layout

`[nvme]` NVM Command Set Specification 1.0 §4.1.5.1 Figure 97 (Identify Namespace):

| Marker | Offset | Field | Width | Meaning |
| --- | ---: | --- | ---: | --- |
| `[nvme]` | `0x00` | `NSZE` | 8 | Namespace Size (LBAs) |
| `[nvme]` | `0x08` | `NCAP` | 8 | Namespace Capacity |
| `[nvme]` | `0x10` | `NUSE` | 8 | Namespace Utilization |
| `[nvme]` | `0x18` | `NSFEAT` | 1 | Namespace Features |
| `[nvme]` | `0x19` | `NLBAF` | 1 | Number of LBA Formats, zero-based (up to 63) |
| `[nvme]` | `0x1a` | `FLBAS` | 1 | Formatted LBA Size |
| `[nvme]` | `0x1b` | `MC` | 1 | Metadata Capabilities |
| `[nvme]` | `0x1c` | `DPC` | 1 | Data Protection Capabilities |
| `[nvme]` | `0x1d` | `DPS` | 1 | Data Protection Settings |
| `[nvme]` | `0x1e` | `NMIC` | 1 | Multi-path I/O Namespace Capabilities |
| `[nvme]` | `0x1f` | `RESCAP` | 1 | Reservation Capabilities |
| `[nvme]` | `0x20` | `FPI` | 1 | Format Progress Indicator |
| `[nvme]` | `0x21` | `DLFEAT` | 1 | Deallocate Features |
| `[nvme]` | `0x22` | `NAWUN` | 2 | Namespace Atomic Write Unit Normal |
| `[nvme]` | `0x24` | `NAWUPF` | 2 | Namespace Atomic Write Unit Power Fail |
| `[nvme]` | `0x26` | `NACWU` | 2 | Namespace Atomic Compare & Write Unit |
| `[nvme]` | `0x28` | `NABSN` | 2 | Namespace Atomic Boundary Size Normal |
| `[nvme]` | `0x2a` | `NABO` | 2 | Namespace Atomic Boundary Offset |
| `[nvme]` | `0x2c` | `NABSPF` | 2 | Namespace Atomic Boundary Size Power Fail |
| `[nvme]` | `0x2e` | `NOIOB` | 2 | Namespace Optimal I/O Boundary |
| `[nvme]` | `0x30` | `NVMCAP` | 16 | NVM Capacity (bytes, `u128`) |
| `[nvme]` | `0x40` | reserved (NPWG..MSRC and beyond) | 24 |  |
| `[nvme]` | `0x58` | reserved | 16 |  |
| `[nvme]` | `0x68` | `NGUID` | 16 | Namespace Globally Unique Identifier (big-endian) |
| `[nvme]` | `0x78` | `EUI64` | 8 | IEEE Extended Unique Identifier (big-endian) |
| `[nvme]` | `0x80` | `LBAF0`..`LBAF63` | 64 × 4 | LBA Format entries |
| `[nvme]` | `0x180` | vendor specific | 3712 |  |

`[nvme]` Total size is 4096 bytes. `[nvme]` Multi-byte scalar fields are little-endian. `[nvme]` `NGUID` and `EUI64` are big-endian per NVMe.

`[nvme]` NVMe Base Specification 2.0 §5.17 (Identify) Active Namespace ID list (CNS 02h): 1024 × `u32` NSID slots at offset `0x000..0xFFF`. The first slot whose value is `0` marks end-of-list; slots after the terminator are reserved / device-authored zero. The list is monotonically increasing across active NSIDs.

## Bit layouts

### `NSFEAT`

`[nvme]` One `u8`:

| Marker | Bit | Meaning |
| --- | ---: | --- |
| `[nvme]` | `0` | THINP — thin provisioning supported |
| `[nvme]` | `1` | NSABP — namespace atomic write fields valid |
| `[nvme]` | `2` | DAE — deallocated or unwritten logical block error supported |
| `[nvme]` | `3` | UIDREUSE — mirrored from I/O Command Set Independent Identify Namespace |
| `[nvme]` | `4` | OPTPERF — NPWG, NPWA, NPDG, NPDA, NOWS fields defined |
| `[nvme]` | `7:5` | reserved |

### `FLBAS`

`[nvme]` One `u8`:

| Marker | Bits | Meaning |
| --- | ---: | --- |
| `[nvme]` | `3:0` | Format Index low nibble |
| `[nvme]` | `4` | Metadata as extended LBA |
| `[nvme]` | `6:5` | Format Index high 2 bits |
| `[nvme]` | `7` | reserved |

`[nvme]` Format Index assembly: `((FLBAS >> 5) & 0x3) << 4) | (FLBAS & 0xf)` yields a `u6` in `0..63`. `[nvme]` If `NLBAF + 1 <= 16`, host software should ignore FLBAS bits `6:5`.

`[znvme]` `formatIndex()` returns the full assembled `u6` unconditionally. Callers who need to enforce the pre-2.0 truncation compare `numberOfLbaFormats()` against `16` before interpreting.

### `MC`

`[nvme]` One `u8`:

| Marker | Bit | Meaning |
| --- | ---: | --- |
| `[nvme]` | `0` | Extended LBA supported |
| `[nvme]` | `1` | Separate metadata buffer supported |
| `[nvme]` | `7:2` | reserved |

### `DPC`

`[nvme]` One `u8`:

| Marker | Bit | Meaning |
| --- | ---: | --- |
| `[nvme]` | `0` | PIT1S — Protection Information Type 1 supported |
| `[nvme]` | `1` | PIT2S — Type 2 supported |
| `[nvme]` | `2` | PIT3S — Type 3 supported |
| `[nvme]` | `3` | PIIFB — Protection Information in first bytes of metadata supported |
| `[nvme]` | `4` | PIILB — Protection Information in last bytes of metadata supported |
| `[nvme]` | `7:5` | reserved |

### `DPS`

`[nvme]` One `u8`:

| Marker | Bits | Meaning |
| --- | ---: | --- |
| `[nvme]` | `2:0` | PIT — Protection Information Type enable |
| `[nvme]` | `3` | PIP — PI position (0 = last bytes, 1 = first bytes) |
| `[nvme]` | `7:4` | reserved |

`[nvme]` PIT values: `000b` disabled, `001b` Type 1, `010b` Type 2, `011b` Type 3, `100b..111b` reserved.

### `DLFEAT`

`[nvme]` One `u8`:

| Marker | Bits | Meaning |
| --- | ---: | --- |
| `[nvme]` | `2:0` | Deallocate read behavior |
| `[nvme]` | `3` | Write Zeroes Deallocate bit supported |
| `[nvme]` | `4` | CRC computed for deallocated LBs |
| `[nvme]` | `7:5` | reserved |

`[nvme]` Deallocate read behavior values: `000b` not reported, `001b` all bytes cleared to `0x00`, `010b` all bytes set to `0xff`, `011b..111b` reserved.

### `LbaFormat`

`[nvme]` NVM Command Set Specification 1.0 Figure 98. Each 32-bit entry:

| Marker | Bits | Field | Width | Meaning |
| --- | ---: | --- | ---: | --- |
| `[nvme]` | `15:0` | `MS` | 16 | Metadata size (bytes per LBA) |
| `[nvme]` | `23:16` | `LBADS` | 8 | LBA Data Size exponent (`2^n` bytes); `n == 0` = format not available; `n < 9` reserved |
| `[nvme]` | `25:24` | `RP` | 2 | Relative Performance |
| `[nvme]` | `31:26` | reserved | 6 |  |

## znvme behavior — `IdentifyNamespace`

`[znvme]` `IdentifyNamespace` is a `[4096]u8` overlay declared as an `extern struct` with named underscore-prefixed fields at their NVMe offsets and `_reserved_*` padding filling the gaps. Multi-byte scalar fields (`_nsze`, `_ncap`, `_nuse`, `_nawun`, ..., `_noiob`) are native little-endian on the first-slice `x86_64-freestanding-none` target. `_nguid` and `_eui64` are `[N]u8` byte arrays preserving NVMe's big-endian designator semantics. The `_` prefix marks fields as wire-storage; the public read surface is the method set on `*const IdentifyNamespace`.

`[znvme]` `NVMCAP` is a 128-bit unsigned value transcribed as two adjacent `u64` fields (`_nvmcap_low`, `_nvmcap_high`). `nvmCapacityBytes()` reassembles them into a `u128`.

`[znvme]` `IdentifyNamespace.validate(bytes)` returns `error.ShortBuffer` when `bytes.len < 4096` and `error.Misaligned` when `@intFromPtr(bytes.ptr) % @alignOf(u64) != 0`. Mirrors `IdentifyController.validate` and `Sqe.validate` — every byte-window entry point at a device-authored boundary is publicly fallible on both length and alignment. On success `validate` returns `*const IdentifyNamespace` borrowing the caller's bytes.

`[znvme]` Callers whose storage is already typed call the accessors directly on the typed pointer.

`[znvme]` `numberOfLbaFormats()` returns `(NLBAF & 0x3F) + 1` as a `u7` (max 64). NVMe 2.0 caps `NLBAF` at 63 (`u6`); the low-6-bit mask makes the accessor total and infallible for any device-authored `_nlbaf: u8` byte pattern, without panicking on out-of-domain values a nonconforming device might emit.

`[znvme]` `formatIndex()` returns a `u6` assembled from FLBAS bits `6:5` + `3:0`.

`[znvme]` `metadataAsExtendedLba()` returns `(_flbas & 0x10) != 0`.

`[znvme]` `lbaFormat(index)` returns `error.LbaFormatOutOfRange` when `index >= numberOfLbaFormats()`. `selectedLbaFormat()` composes `lbaFormat(formatIndex())` and returns the same error when the device-reported `FLBAS` names an index beyond `NLBAF`.

`[znvme]` `LbaFormat.isAvailable()` returns `lba_data_size_shift != 0`. `LbaFormat.dataSizeBytes()` is fallible: `error.LbaFormatUnavailable` when `lba_data_size_shift == 0`, `error.ReservedLbaFormat` when `0 < lba_data_size_shift < 9`, `error.LbaFormatTooLarge` when `lba_data_size_shift >= @bitSizeOf(usize)`, and `1 << lba_data_size_shift` otherwise. `LbaFormat.metadataSizeBytes()` is infallible because `metadata_size` is a `u16` on the wire. `LbaFormat.totalLbaSizeBytes()` composes `dataSizeBytes()` with `std.math.add(usize, ...)` and returns `error.LbaFormatTooLarge` on data+metadata overflow in `usize`.

`[znvme]` `geometry()` composes the selected LBA format with `NSZE` and `FLBAS.metadata_as_extended_lba`:

- `[znvme]` returns `error.LbaFormatOutOfRange` when `selectedLbaFormat` returns it;
- `[znvme]` returns whatever `LbaFormat.dataSizeBytes()` returns for a device-authored `LBADS` outside the accepted range (`LbaFormatUnavailable`, `ReservedLbaFormat`, `LbaFormatTooLarge`);
- `[znvme]` returns `error.LbaFormatTooLarge` when `FLBAS.metadata_as_extended_lba == 1` and `LbaFormat.totalLbaSizeBytes()` overflows `usize`;
- `[znvme]` otherwise populates three sizes from the selected format and FLBAS:
  - `[znvme]` `data_size_bytes = try format.dataSizeBytes()` — user-visible data per LBA, i.e. `1 << LBADS`;
  - `[znvme]` `metadata_size_bytes = format.metadataSizeBytes()` — metadata per LBA, may be zero;
  - `[znvme]` `transfer_stride_bytes = try format.totalLbaSizeBytes()` when FLBAS.metadata_as_extended_lba is set (metadata rides inline with data on the wire); `= data_size_bytes` otherwise (metadata rides a separate MPTR buffer or does not exist).

`[znvme]` `Geometry.totalDataBytes()` returns `std.math.mul(u64, logical_block_count, data_size_bytes)`; `Geometry.totalTransferBytes()` returns the same overflow-checked product against `transfer_stride_bytes`. Both surface `error.Overflow` when the product exceeds `u64.max`. `Geometry.dataByteOffsetOf(lba)` and `Geometry.transferByteOffsetOf(lba)` are the corresponding overflow-checked LBA→byte-offset multiplications. Callers translating LBA into a user data-buffer offset use `dataByteOffsetOf`; callers sizing a wire-transfer buffer use `transferByteOffsetOf` and `totalTransferBytes`. Read/Write builders in `docs/specs/commands/nvm.md` consume `transfer_stride_bytes` for PRP-list sizing; that spec is queued.

`[znvme]` `Geometry.containsLba(lba)` is `lba < logical_block_count`. It is not a precondition of `dataByteOffsetOf` or `transferByteOffsetOf`; callers check it separately when the semantic they want is "in-range LBA."

`[znvme]` `IdentifyNamespace.init(target, params)` stamps `target.*` in place with the params-provided lanes. Every `Init` field has a zero-safe default so `IdentifyNamespace.init(target, .{})` is spec-legal blank storage. Emulator fixtures allocate `[1]IdentifyNamespace align(8)` (or `Buffer(u8)` cast), call `IdentifyNamespace.init(&scratch[0], .{ ... })`, and expose the underlying bytes to the host through PRP. Host drivers never call `init`; they only decode through accessors.

`[znvme]` `IdentifyNamespace.validate` and every accessor borrow caller-owned bytes as-is; no accessor emits a memory barrier. Callers consuming a device-written Identify Namespace payload (that is, after a successful `pollOne` returns a completion whose CID matches an outstanding Identify handle) must issue `stdx.barrier.dma.acquire()` between the matching CQE observation and the first accessor call. `pollOne`'s CQE-side acquire does not cover Identify payload bytes.

## znvme behavior — `List`

`[znvme]` `List` is a `[1024]u32` overlay declared as an `extern struct` with the underscore-prefixed `_entries` field covering the full 4 KiB. Every slot is a native little-endian `u32` on the first-slice target. The public read surface is the method set on `*const List`.

`[znvme]` `List.validate(bytes)` returns `error.ShortBuffer` when `bytes.len < 4096`, `error.Misaligned` when `@intFromPtr(bytes.ptr) % @alignOf(u32) != 0`. Mirrors every other byte-window validator in the repo.

`[znvme]` `List.entry(index)` returns `Nsid.from(_entries[index])` for `index < max_entries` and `error.EntryIndexOutOfRange` otherwise.

`[znvme]` `List.entryCount()` scans forward from index 0 and returns the count of slots preceding the first zero terminator; bounded by `max_entries` (1024). O(entryCount) worst case.

`[znvme]` `List.iterator()` returns a stateful `Iterator { list: *const List, index: u16 = 0 }` whose `next()` returns `null` on first zero slot or at index `max_entries`. Idiomatic loop: `while (iter.next()) |nsid| { ... }`.

`[znvme]` `List.rawEntries()` returns `&self._entries` as a `[]const u32` for callers who want the untyped wire without the `Nsid` wrap.

`[znvme]` `List.init(target, params)` writes `params.nsids[i].raw()` into `_entries[i]` for `i < params.nsids.len` and zeroes `_entries[params.nsids.len..1024]`. `init` asserts `params.nsids.len <= max_entries` — the caller is composing a fixed-size fixture and overrun is a programmer error.

`[znvme]` `List.validate` and every accessor emit no memory barrier; the same acquire contract as `IdentifyNamespace` and `IdentifyController` applies at the caller.

## Approved API

```zig
// src/identify/namespace.zig
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
    }
};
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `[znvme]` `IdentifyNamespace.init` | never | never | O(1) | caller-serialized per target | none | infallible |
| `[znvme]` `IdentifyNamespace.validate` | never | never | O(1) length + alignment check | borrowed slice | none | `ShortBuffer`, `Misaligned` |
| `[znvme]` scalar accessors | never | never | O(1) | borrowed load | none | infallible |
| `[znvme]` `nguid` / `eui64` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `nvmCapacityBytes` | never | never | O(1) | value type | none | infallible |
| `[znvme]` packed-struct decode (`features`, `metadataCapabilities`, `dataProtectionCapabilities`, `dataProtectionSettings`, `deallocateFeatures`) | never | never | O(1) | value type | none | infallible |
| `[znvme]` `numberOfLbaFormats` / `formatIndex` / `metadataAsExtendedLba` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `lbaFormat` / `selectedLbaFormat` | never | never | O(1) | value type | none | `LbaFormatOutOfRange` |
| `[znvme]` `geometry` | never | never | O(1) | value type | none | `LbaFormatOutOfRange`, `LbaFormatUnavailable`, `ReservedLbaFormat`, `LbaFormatTooLarge` |
| `[znvme]` `LbaFormat.isAvailable` / `.metadataSizeBytes` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `LbaFormat.dataSizeBytes` / `.totalLbaSizeBytes` | never | never | O(1) | value type | none | `LbaFormatUnavailable`, `ReservedLbaFormat`, `LbaFormatTooLarge` |
| `[znvme]` `Geometry.totalDataBytes` / `.totalTransferBytes` / `.dataByteOffsetOf` / `.transferByteOffsetOf` | never | never | O(1) | value type | none | `Overflow` |
| `[znvme]` `Geometry.containsLba` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `List.init` | never | never | O(max_entries) | caller-serialized per target | none | infallible (asserts `nsids.len <= max_entries`) |
| `[znvme]` `List.validate` | never | never | O(1) length + alignment check | borrowed slice | none | `ShortBuffer`, `Misaligned` |
| `[znvme]` `List.entry` | never | never | O(1) | value type | none | `EntryIndexOutOfRange` |
| `[znvme]` `List.entryCount` | never | never | O(entryCount) ≤ 1024 | borrowed slice | none | infallible |
| `[znvme]` `List.iterator` / `Iterator.next` | never | never | O(1) per step, ≤ 1024 total | value type | none | infallible |
| `[znvme]` `List.rawEntries` | never | never | O(1) | borrowed slice | none | infallible |

`[znvme]` No accessor performs allocation, waiting, hidden global access, atomics, barriers, volatile access, target probing, syscalls, locks, or I/O.

## Validation phases

`[znvme]` Per `docs/specs/architecture.md` §"Validation phases":

- `[znvme]` **Compile time.** `@sizeOf`, `@offsetOf`, and `@bitSizeOf` assertions inside `IdentifyNamespace`, `List`, `LbaFormat`, `NsFeatBits`, `McBits`, `DpcBits`, `DpsBits`, and `DlfeatBits`. `zig build check` proves them on `x86_64-freestanding-none`.
- `[znvme]` **Public validation.** `IdentifyNamespace.validate` returns `error.ShortBuffer` on short input and `error.Misaligned` when the byte pointer is not `@alignOf(u64)`-aligned. `List.validate` returns the same errors against `@alignOf(u32)`. `lbaFormat`, `selectedLbaFormat`, `LbaFormat.dataSizeBytes`, `LbaFormat.totalLbaSizeBytes`, and `geometry` return errors for device-authored inconsistencies (out-of-range format index, unavailable format, reserved data-size exponent, oversize data-size exponent). `Geometry.totalDataBytes`, `Geometry.totalTransferBytes`, `Geometry.dataByteOffsetOf`, and `Geometry.transferByteOffsetOf` return `error.Overflow` when the product exceeds `u64.max`. `List.entry` returns `error.EntryIndexOutOfRange` when `index >= max_entries`.
- `[znvme]` **Assertions.** `List.init` asserts `params.nsids.len <= max_entries`. Alignment is a public typed error, not a programmer-error assertion.

## Example usage — `IdentifyNamespace`

`[znvme]` Illustrative shape only; not part of the approved API.

```zig
const nvme = @import("nvme");

const IdentifyNamespace = nvme.identify.namespace.IdentifyNamespace;

const ns = try IdentifyNamespace.validate(namespace_buffer.constBytes());
const geometry = try ns.geometry();

if (geometry.data_size_bytes != 512 and geometry.data_size_bytes != 4096) {
    return error.UnsupportedLbaSize;
}

if (!geometry.containsLba(target_lba)) return error.LbaOutOfRange;

const data_offset = try geometry.dataByteOffsetOf(target_lba);
const wire_offset = try geometry.transferByteOffsetOf(target_lba);
```

## Example usage — `List`

`[znvme]` Illustrative shape only.

```zig
const nvme = @import("nvme");

const List = nvme.identify.namespace.List;

const list = try List.validate(list_buffer.constBytes());
var iter = list.iterator();
while (iter.next()) |nsid| {
    if (!nsid.isValidNamespace()) continue;
    try issueIdentifyNamespace(nsid);
}
```

## Required tests `[znvme]`

`[znvme]` Test file `test/identify/namespace_test.zig`. Naming per `docs/guidelines/testing.md`.

`[znvme]` Test substrate: a `[4096]u8 align(8)` scratch buffer initialized to zero, then written with known bytes at each field offset the tests exercise.

### `IdentifyNamespace` layout

- `[znvme]` `unit: identify namespace size is 4096 bytes`.
- `[znvme]` `unit: identify namespace offsets match NVM Command Set Specification Figure 97`.
- `[znvme]` `unit: identify namespace validate rejects buffer shorter than 4096 with ShortBuffer`.
- `[znvme]` `unit: identify namespace validate rejects misaligned byte pointer with Misaligned`.
- `[znvme]` `unit: identify namespace validate accepts exact 4096-byte buffer`.
- `[znvme]` `unit: identify namespace accessors work on a typed pointer without going through validate`.

### `IdentifyNamespace` scalar and bit fields

- `[znvme]` `unit: identify namespace decodes NSZE NCAP NUSE as native little-endian u64`.
- `[znvme]` `unit: identify namespace NsFeatBits decodes THINP NSABP DAE UIDREUSE OPTPERF flags`.
- `[znvme]` `unit: identify namespace numberOfLbaFormats returns NLBAF+1` — covers `0`, `15`, `63`.
- `[znvme]` `unit: identify namespace formatIndex assembles FLBAS bits 6:5 with 3:0` — verify 4-bit case (high bits zero) and 6-bit case (high bits non-zero).
- `[znvme]` `unit: identify namespace metadataAsExtendedLba decodes FLBAS bit 4`.
- `[znvme]` `unit: identify namespace McBits decodes extended_lba and separate_buffer flags`.
- `[znvme]` `unit: identify namespace DpcBits decodes all three PI-type support bits and PII first/last`.
- `[znvme]` `unit: identify namespace DpsBits decodes PIT enum and PIP bit` — covers disabled, type_1, type_2, type_3, and a reserved value preserved via the non-exhaustive tail.
- `[znvme]` `unit: identify namespace DlfeatBits decodes read_behavior write_zeroes_deallocate guard_crc flags`.
- `[znvme]` `unit: identify namespace nvmCapacityBytes assembles high u64 shifted 64 bits over low u64`.
- `[znvme]` `unit: identify namespace nguid and eui64 return preserved big-endian bytes`.
- `[znvme]` `unit: identify namespace optimalIoBoundary returns NOIOB as u16`.

### `LbaFormat`

- `[znvme]` `unit: LbaFormat decodes MS LBADS RP fields at documented bit positions`.
- `[znvme]` `unit: LbaFormat isAvailable returns false when LBADS is zero`.
- `[znvme]` `unit: LbaFormat dataSizeBytes returns LbaFormatUnavailable for shift 0`.
- `[znvme]` `unit: LbaFormat dataSizeBytes returns ReservedLbaFormat for shift 1..8`.
- `[znvme]` `unit: LbaFormat dataSizeBytes returns LbaFormatTooLarge for shift >= @bitSizeOf(usize)`.
- `[znvme]` `unit: LbaFormat dataSizeBytes returns 512 for shift 9 and 4096 for shift 12`.
- `[znvme]` `unit: LbaFormat totalLbaSizeBytes sums data and metadata for representable values`.
- `[znvme]` `unit: LbaFormat totalLbaSizeBytes returns LbaFormatTooLarge when data + metadata overflows usize`.
- `[znvme]` `unit: identify namespace lbaFormat rejects index >= numberOfLbaFormats with LbaFormatOutOfRange`.
- `[znvme]` `unit: identify namespace selectedLbaFormat honors 6-bit formatIndex when NLBAF > 16`.

### `Geometry`

- `[znvme]` `unit: identify namespace geometry returns LbaFormatUnavailable when selected LBADS is zero`.
- `[znvme]` `unit: identify namespace geometry returns ReservedLbaFormat when selected LBADS is less than 9`.
- `[znvme]` `unit: identify namespace geometry returns LbaFormatTooLarge when LBADS >= @bitSizeOf(usize)`.
- `[znvme]` `unit: identify namespace geometry with 512-byte LBAs and no metadata sets data=512 metadata=0 stride=512`.
- `[znvme]` `unit: identify namespace geometry with 4KiB LBAs and 8-byte metadata and extended LBA sets data=4096 metadata=8 stride=4104`.
- `[znvme]` `unit: identify namespace geometry with 4KiB LBAs and 8-byte metadata and separate-buffer FLBAS sets data=4096 metadata=8 stride=4096`.
- `[znvme]` `unit: Geometry.containsLba returns false for lba equal to logical_block_count`.
- `[znvme]` `unit: Geometry.totalDataBytes multiplies count by data_size_bytes` — check `1024 * 4096 == 4_194_304`.
- `[znvme]` `unit: Geometry.totalDataBytes returns Overflow when product exceeds u64.max` — construct with `count = u64.max` and `data_size_bytes = 2`.
- `[znvme]` `unit: Geometry.totalTransferBytes multiplies count by transfer_stride_bytes` — extended-LBA fixture with data=4096 metadata=8; check product uses `4104`.
- `[znvme]` `unit: Geometry.totalTransferBytes returns Overflow when product exceeds u64.max` — construct with `count = u64.max` and `transfer_stride_bytes = 2`.
- `[znvme]` `unit: Geometry.dataByteOffsetOf returns lba times data_size_bytes`.
- `[znvme]` `unit: Geometry.dataByteOffsetOf returns Overflow when lba times data_size_bytes exceeds u64.max`.
- `[znvme]` `unit: Geometry.transferByteOffsetOf returns lba times transfer_stride_bytes` — extended-LBA fixture with stride `4104`; check `lba = 3` yields `12312`.
- `[znvme]` `unit: Geometry.transferByteOffsetOf returns Overflow when lba times transfer_stride_bytes exceeds u64.max`.

### `IdentifyNamespace` fixtures

- `[znvme]` `roundtrip: identify namespace accessors return exactly what a byte fixture encodes`.
- `[znvme]` `unit: IdentifyNamespace.init(target, .{}) is spec-legal all-zero storage with default reserved padding` — every reserved region reads zero; `_nguid`, `_eui64`, `_lbaf` default to zero.
- `[znvme]` `roundtrip: IdentifyNamespace.init round-trips every field through accessors including LBAF table` — populate every non-reserved `Init` field including a distinct value in each `lbaf[i]`; construct via `init`; assert every accessor returns the input.
- `[znvme]` `unit: identify namespace accessors emit no barrier` — audit that `validate` and every accessor issue no `stdx.barrier.*` calls; ordering is the caller's responsibility.
- `[znvme]` `golden: identify namespace 512e minimal bytes decode` — fixture with 512-byte LBAs, one namespace, plausible `NSZE` and `NCAP`; documented regeneration command.
- `[znvme]` `golden: identify namespace 4kn minimal bytes decode` — fixture with 4 KiB LBAs, extended-LBA metadata off; documented regeneration command.

### `List` layout

- `[znvme]` `unit: list size is 4096 bytes`.
- `[znvme]` `unit: list _entries starts at offset 0 and spans 4096 bytes`.
- `[znvme]` `unit: List.validate rejects buffer shorter than 4096 with ShortBuffer`.
- `[znvme]` `unit: List.validate rejects misaligned byte pointer with Misaligned`.
- `[znvme]` `unit: List.validate accepts exact 4096-byte buffer`.
- `[znvme]` `unit: list accessors work on a typed pointer without going through validate`.

### `List` accessors

- `[znvme]` `unit: List.entry rejects index >= 1024 with EntryIndexOutOfRange`.
- `[znvme]` `unit: List.entry returns Nsid.from(raw) for every in-range index`.
- `[znvme]` `unit: List.entryCount returns 0 for all-zero buffer`.
- `[znvme]` `unit: List.entryCount returns 1024 when no zero terminator is present`.
- `[znvme]` `unit: List.entryCount returns index of first zero slot` — mid-list terminator.
- `[znvme]` `unit: List.iterator yields the live prefix and stops at zero terminator`.
- `[znvme]` `unit: List.iterator yields all 1024 entries when no zero terminator is present`.
- `[znvme]` `unit: List.rawEntries returns 1024-element u32 slice at offset 0`.

### `List` init

- `[znvme]` `unit: List.init(target, .{}) is spec-legal all-zero storage`.
- `[znvme]` `unit: List.init with N nsids fills slots 0..N-1 and zeroes slots N..1023`.
- `[znvme]` `roundtrip: List.init round-trips slice of Nsid through List.entry` — construct with `Nsid.from(1), Nsid.from(2), Nsid.from(0xFFFF_FFFE)`; verify via `entry(0)`/`entry(1)`/`entry(2)` and `iterator()` prefix.

### `List` ordering

- `[znvme]` `unit: list accessors emit no barrier` — audit that `validate` and every accessor issue no `stdx.barrier.*` calls; ordering is the caller's responsibility.

### `List` fixtures

- `[znvme]` `golden: list two active nsids decode` — fixture `[1, 5, 0, 0, ...]` decodes to `iterator()` yielding `{1, 5}`.
- `[znvme]` `golden: list dense 1024 active nsids decode` — no zero terminator; `iterator()` yields all 1024.

## Open questions

_(none)_
