# Core PRP construction

Status: Approved.

`[znvme]` `PrpEntry`, `DataPointers`, `PageSize`, `PrpList`, and contiguous PRP construction own the PRP1/PRP2 data-pointer shape used by NVMe commands. This spec covers descriptor construction only: caller-owned DMA memory goes in, PRP data-pointer lanes and optional PRP-list entries come out.

`[znvme]` PRP construction never allocates, maps, pins, flushes, invalidates, rings a doorbell, or chooses a command opcode. It composes `stdx.dma.Buffer(T)` and `stdx.addr.DmaAddr` from `docs/specs/core/dma.md`.

## Owned scope

`[znvme]` This spec owns:

- `[znvme]` `PrpEntry`, the 64-bit PRP wire lane;
- `[znvme]` `DataPointers`, the `PRP1` / `PRP2` pair embedded by SQE data-transfer command layouts;
- `[znvme]` `IoQueueBase`, the single page-aligned queue-base DMA pointer for Create I/O SQ/CQ with `PC=1`;
- `[znvme]` `PageSize`, the validated memory-page size consumed by PRP construction;
- `[znvme]` `PrpList`, caller-owned PRP-list storage backed by `stdx.dma.Buffer(PrpEntry)`;
- `[znvme]` contiguous payload PRP construction from `stdx.dma.Buffer(u8)`;
- `[znvme]` PRP-list entry emission for payloads that cross more than one page boundary after `PRP1`;
- `[znvme]` validation and error taxonomy for descriptor-construction failures;
- `[znvme]` first-slice limit of one PRP-list page.

## Deferred scope and non-goals

`[znvme]` This spec does not own:

- `[znvme]` SQE layout, PRP field offsets, or command dword layout (`docs/specs/commands/sqe.md`);
- `[znvme]` command-specific transfer length, data direction, opcode legality, or namespace policy;
- `[znvme]` metadata pointer (`MPTR`) construction;
- `[znvme]` SGL descriptors or SGL-vs-PRP selection;
- `[znvme]` scatter-gather payload input;
- `[znvme]` DMA allocation, mapping, pinning, IOMMU policy, bounce buffers, or cache maintenance;
- `[znvme]` queue barriers, doorbell ordering, or command submission;
- `[znvme]` Maximum Data Transfer Size (`MDTS`) policy;
- `[znvme]` chained PRP-list pages;
- `[znvme]` big-endian host or target support.

## NVMe behavior

`[nvme]` A Physical Region Page (PRP) entry is a fixed 64-bit pointer lane used by NVMe commands to describe data-transfer memory.

`[nvme]` Bits `1:0` of a PRP entry are reserved zero.

`[nvme]` The Page Base Address and Offset (`PBAO`) field occupies bits `63:2`. The low offset bits inside `PBAO` are determined by the configured memory page size. For a 4 KiB page, offset bits are `11:2`; for an 8 KiB page, offset bits are `12:2`; and so on.

`[nvme]` The memory page size used by PRPs is configured by host software in `CC.MPS`, within the controller-supported range reported by `CAP.MPSMIN` and `CAP.MPSMAX`.

`[nvme]` `PRP1` contains the first PRP entry for a command data transfer.

`[nvme]` `PRP2` is reserved when the command data transfer does not cross a memory page boundary.

`[nvme]` When the command data transfer crosses exactly one memory page boundary, `PRP2` contains the page base address of the second memory page.

`[nvme]` When the command data transfer crosses more than one memory page boundary, `PRP2` is a PRP List pointer.

## znvme behavior

`[znvme]` `PrpEntry` stores the PRP lane as a native `u64` on the first-slice little-endian target. Wire encoding writes `stdx.addr.DmaAddr.raw()` into that field; it never pointer-casts DMA addresses into command bytes.

`[znvme]` First-slice `PageSize` accepts only power-of-two byte sizes `>= 4096`.

`[znvme]` Controller initialization owns deriving `PageSize` from `CAP.MPSMIN`, `CAP.MPSMAX`, and the selected `CC.MPS` value. PRP construction receives an already selected page size and validates only the local invariants it consumes.

`[znvme]` Empty payloads are rejected by PRP construction. A command with no data transfer does not need PRP construction.

`[znvme]` `PRP1` is always the payload buffer's base `DmaAddr`.

`[znvme]` `IoQueueBase` is the SQE-side queue-base DMA pointer for Create I/O SQ/CQ with `PC=1`. It carries only `PRP1` and is distinct from `core.registers.QueueBase`, which is the register-block value type used to store `ASQ`/`ACQ`. `IoQueueBase.fromContiguous(buffer, page_size)` requires the queue-base buffer to be non-empty and aligned to the caller's configured page size. The admin builder writes `PRP1 = IoQueueBase.prp1` and `PRP2 = 0`; chained or PRP-list queue bases are not supported.

`[znvme]` `PRP1` permits a non-zero page offset, but bits `1:0` must be zero.

`[znvme]` Every payload PRP entry after `PRP1` must be page-aligned.

`[znvme]` If the payload fits in the bytes remaining in `PRP1`'s page, `PRP2` is zero.

`[znvme]` If the payload remainder after `PRP1` fits in one page, `PRP2` is the DMA address of that next payload page.

`[znvme]` If the payload remainder after `PRP1` needs more than one page, `PRP2` is the DMA address of a caller-supplied PRP-list page and that page is filled with page-aligned payload addresses.

`[znvme]` `PrpList` storage is caller-owned DMA memory. `DataPointers.fromContiguous` writes PRP-list entries through `PrpList.buffer.slice()` and uses `PrpList.buffer.dmaAddr()` for the `PRP2` list pointer.

`[znvme]` First-slice `PrpList` DMA addresses must be page-aligned. This is a conservative local rule for the one-page PRP-list form; it does not describe SGL or chained-list behavior.

`[znvme]` `PrpList.wrap` rejects PRP-list buffers longer than one configured page with `error.PrpListTooLarge`.

`[znvme]` First-slice PRP construction rejects transfers requiring more PRP-list entries than fit in one page. Chained PRP-list pages are deferred.

`[znvme]` The last PRP entry can describe a partial final page. The command's transfer length determines how many bytes the controller transfers from the final page.

`[znvme]` Big-endian host/target compatibility is deferred in `docs/specs/project/scope.md`; first-slice code targets little-endian `x86_64-freestanding-none`.

## Construction algorithm

For `DataPointers.fromContiguous(.{ .payload = payload, .page_size = page_size, .prp_list_output = prp_list_output })`:

1. `[znvme]` Reject empty payloads.
2. `[znvme]` Reject payload base addresses with bits `1:0` set.
3. `[znvme]` Set `PRP1 = payload.dmaAddr()`.
4. `[znvme]` Compute `first_page_bytes = min(payload.byteLen(), page_size.bytes - page_offset(PRP1))`.
5. `[znvme]` If `payload.byteLen() == first_page_bytes`, return `PRP2 = 0`.
6. `[znvme]` Compute `second_addr = payload.dmaAddr() + first_page_bytes` and require it to be page-aligned.
7. `[znvme]` If `payload.byteLen() - first_page_bytes <= page_size.bytes`, return `PRP2 = second_addr`.
8. `[znvme]` Otherwise require `prp_list_output`.
9. `[znvme]` Let `required = ceil((payload.byteLen() - first_page_bytes) / page_size.bytes)`.
10. `[znvme]` Reject when `required > page_size.bytes / @sizeOf(PrpEntry)`.
11. `[znvme]` Reject when `required > PrpList.capacity()`.
12. `[znvme]` Write `required` page-aligned payload addresses into the PRP list, starting with `second_addr` and advancing by `page_size.bytes`.
13. `[znvme]` Return `PRP2 = PrpList.buffer.dmaAddr()`.

For `IoQueueBase.fromContiguous(buffer_bytes, page_size)`:

1. `[znvme]` Reject empty buffers.
2. `[znvme]` Reject buffers whose base is not aligned to `page_size.bytes`.
3. `[znvme]` Return `IoQueueBase{ .prp1 = PrpEntry.fromDmaAddr(buffer_bytes.dmaAddr()) }`.

## Approved API

```zig
// src/core/prp.zig
//! PRP1/PRP2 construction. Spec: docs/specs/core/prp.md.

const std = @import("std");

const stdx = @import("stdx");

const DmaAddr = stdx.addr.DmaAddr;

pub const Error = error{
    EmptyPayload,
    InvalidPageSize,
    MisalignedPrpEntry,
    MisalignedPrpList,
    MisalignedQueueBase,
    PrpListRequired,
    PrpListTooSmall,
    PrpListTooLarge,
    TransferTooLarge,
    Overflow,
};

pub const PrpEntry = extern struct {
    value: u64,

    pub const zero: PrpEntry = .{ .value = 0 };

    pub fn fromDmaAddr(addr: DmaAddr) PrpEntry {
        return .{ .value = addr.raw() };
    }

    pub fn raw(self: PrpEntry) u64 {
        return self.value;
    }

    pub fn dmaAddr(self: PrpEntry) DmaAddr {
        return .fromInt(self.raw());
    }

    pub fn isZero(self: PrpEntry) bool {
        return self.raw() == 0;
    }

    comptime {
        std.debug.assert(@sizeOf(PrpEntry) == 8);
        std.debug.assert(@alignOf(PrpEntry) == @alignOf(u64));
    }
};

pub const DataPointers = extern struct {
    prp1: PrpEntry,
    prp2: PrpEntry = .zero,

    pub const zero: DataPointers = .{
        .prp1 = .zero,
        .prp2 = .zero,
    };

    pub const Contiguous = struct {
        payload: stdx.dma.Buffer(u8),
        page_size: PageSize,
        prp_list_output: ?PrpList = null,
    };

    pub fn fromContiguous(input: Contiguous) Error!DataPointers {
        const payload = input.payload;
        const page_size = input.page_size;
        const base = payload.dmaAddr();
        const len = payload.byteLen();

        if (len == 0) return error.EmptyPayload;
        if ((base.raw() & 0x3) != 0) return error.MisalignedPrpEntry;

        const prp1 = PrpEntry.fromDmaAddr(base);
        const first_bytes = @min(len, page_size.remainingInPage(base));
        const remaining = len - first_bytes;
        if (remaining == 0) {
            return .{ .prp1 = prp1, .prp2 = .zero };
        }

        const second_addr = base.add(first_bytes) catch return error.Overflow;
        if (!page_size.isPageAligned(second_addr)) {
            return error.MisalignedPrpEntry;
        }

        if (remaining <= page_size.bytes) {
            return .{ .prp1 = prp1, .prp2 = PrpEntry.fromDmaAddr(second_addr) };
        }

        const list = input.prp_list_output orelse return error.PrpListRequired;
        const required = try ceilDivU64ToUsize(remaining, page_size.bytes);
        if (required > page_size.entriesPerListPage()) return error.TransferTooLarge;
        if (required > list.capacity()) return error.PrpListTooSmall;

        var addr = second_addr;
        const entries = list.buffer.slice();
        var i: usize = 0;
        while (i < required) : (i += 1) {
            if (!page_size.isPageAligned(addr)) return error.MisalignedPrpEntry;
            entries[i] = PrpEntry.fromDmaAddr(addr);

            if (i + 1 < required) {
                addr = addr.add(page_size.bytes) catch return error.Overflow;
            }
        }

        return .{
            .prp1 = prp1,
            .prp2 = PrpEntry.fromDmaAddr(list.buffer.dmaAddr()),
        };
    }

    comptime {
        std.debug.assert(@offsetOf(DataPointers, "prp1") == 0);
        std.debug.assert(@offsetOf(DataPointers, "prp2") == 8);
        std.debug.assert(@sizeOf(DataPointers) == 16);
        std.debug.assert(@alignOf(DataPointers) == @alignOf(u64));
    }
};

pub const IoQueueBase = extern struct {
    prp1: PrpEntry,

    pub fn fromContiguous(buffer_bytes: stdx.dma.Buffer(u8), page_size: PageSize) Error!IoQueueBase {
        if (buffer_bytes.byteLen() == 0) return error.EmptyPayload;
        const base = buffer_bytes.dmaAddr();
        if (!page_size.isPageAligned(base)) return error.MisalignedQueueBase;
        return .{ .prp1 = PrpEntry.fromDmaAddr(base) };
    }

    comptime {
        std.debug.assert(@offsetOf(IoQueueBase, "prp1") == 0);
        std.debug.assert(@sizeOf(IoQueueBase) == @sizeOf(PrpEntry));
        std.debug.assert(@alignOf(IoQueueBase) == @alignOf(u64));
    }
};

pub const PageSize = struct {
    bytes: u64,

    pub fn fromBytes(bytes: u64) Error!PageSize {
        if (bytes < 4096 or !std.math.isPowerOfTwo(bytes)) {
            return error.InvalidPageSize;
        }
        return .{ .bytes = bytes };
    }

    pub fn offset(self: PageSize, addr: DmaAddr) u64 {
        return addr.raw() & (self.bytes - 1);
    }

    pub fn isPageAligned(self: PageSize, addr: DmaAddr) bool {
        return self.offset(addr) == 0;
    }

    pub fn remainingInPage(self: PageSize, addr: DmaAddr) u64 {
        return self.bytes - self.offset(addr);
    }

    pub fn entriesPerListPage(self: PageSize) usize {
        return @intCast(@divExact(self.bytes, @sizeOf(PrpEntry)));
    }
};

pub const PrpList = struct {
    buffer: stdx.dma.Buffer(PrpEntry),

    pub fn wrap(buffer: stdx.dma.Buffer(PrpEntry), page_size: PageSize) Error!PrpList {
        if (!page_size.isPageAligned(buffer.dmaAddr())) {
            return error.MisalignedPrpList;
        }
        if (buffer.len() > page_size.entriesPerListPage()) {
            return error.PrpListTooLarge;
        }
        return .{ .buffer = buffer };
    }

    pub fn capacity(self: PrpList) usize {
        return self.buffer.len();
    }
};

pub fn requiredListEntries(payload: stdx.dma.Buffer(u8), page_size: PageSize) Error!usize {
    const remaining_after_prp1 = try remainingAfterPrp1(payload, page_size);
    if (remaining_after_prp1 == 0) return 0;
    if (remaining_after_prp1 <= page_size.bytes) return 0;

    return ceilDivU64ToUsize(remaining_after_prp1, page_size.bytes);
}

fn remainingAfterPrp1(payload: stdx.dma.Buffer(u8), page_size: PageSize) Error!u64 {
    const base = payload.dmaAddr();
    const len = payload.byteLen();

    if (len == 0) return error.EmptyPayload;
    if ((base.raw() & 0x3) != 0) return error.MisalignedPrpEntry;

    const first_bytes = @min(len, page_size.remainingInPage(base));
    return len - first_bytes;
}

fn ceilDivU64ToUsize(value: u64, divisor: u64) Error!usize {
    const rounded = std.math.divCeil(u64, value, divisor) catch unreachable;
    return std.math.cast(usize, rounded) orelse error.Overflow;
}
```


## Required tests `[znvme]`

- `[znvme]` `unit: prp entry layout is native 64-bit lane on little-endian target`
- `[znvme]` `unit: data pointers layout matches PRP1 PRP2 pair`
- `[znvme]` `unit: page size rejects zero non-power-of-two and below 4 KiB`
- `[znvme]` `unit: data pointers from contiguous one-page payload clears PRP2`
- `[znvme]` `unit: data pointers from contiguous offset payload uses PRP2 for second page`
- `[znvme]` `unit: data pointers from contiguous multi-page payload fills PRP list`
- `[znvme]` `unit: PRP construction rejects empty payload`
- `[znvme]` `unit: PRP construction rejects low reserved PRP bits`
- `[znvme]` `unit: PRP construction requires list for more than two PRP regions`
- `[znvme]` `unit: PRP construction rejects short PRP list`
- `[znvme]` `unit: PRP construction rejects misaligned PRP list DMA address`
- `[znvme]` `unit: PRP construction rejects oversized PRP list buffer`
- `[znvme]` `unit: PRP construction rejects transfers requiring chained PRP-list pages`
- `[znvme]` `unit: io queue base fromContiguous rejects empty buffer`.
- `[znvme]` `unit: io queue base fromContiguous rejects non-page-aligned base with MisalignedQueueBase`.
- `[znvme]` `unit: io queue base fromContiguous returns PRP1 equal to buffer dmaAddr for a page-aligned buffer`.
- `[znvme]` `unit: io queue base layout is a single PRP entry at offset zero`.

## Open questions

_(none)_
