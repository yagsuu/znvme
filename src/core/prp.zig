//! PRP1/PRP2 construction. Spec: docs/specs/core/prp.md.

const std = @import("std");

const stdx = @import("stdx");

const DMAAddr = stdx.addr.DMAAddr;

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

/// Single 64-bit PRP entry: `DMAAddr` in host byte order on the wire.
pub const PrpEntry = extern struct {
    value: u64,

    pub const zero: PrpEntry = .{ .value = 0 };

    pub fn fromDmaAddr(addr: DMAAddr) PrpEntry {
        return .{ .value = addr.raw() };
    }

    pub fn raw(self: PrpEntry) u64 {
        return self.value;
    }

    pub fn dmaAddr(self: PrpEntry) DMAAddr {
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

/// SQE PRP field pair (PRP1, PRP2). `fromContiguous` picks between inline
/// PRP2 and a caller-supplied PRP list based on transfer size.
pub const DataPointers = extern struct {
    prp1: PrpEntry,
    prp2: PrpEntry = .zero,

    pub const zero: DataPointers = .{
        .prp1 = .zero,
        .prp2 = .zero,
    };

    /// `prp_list_output` is required only when the transfer spans more than
    /// two pages; otherwise leave it `null` and PRP2 goes inline.
    pub const Contiguous = struct {
        payload: stdx.dma.Buffer(u8),
        page_size: PageSize,
        prp_list_output: ?PrpList = null,
    };

    /// Compose PRP1/PRP2 for a contiguous transfer. Transfers up to one page
    /// use PRP1 alone; up to two pages inline PRP2; beyond that a caller-owned
    /// `PrpList` fills with page-aligned entries and PRP2 points at its base.
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

/// PRP1 for I/O queue base pages. Same wire encoding as an SQE PRP1 but the
/// queue base must be page-aligned, not merely dword-aligned.
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

/// Host page size. Must be a power of two at or above 4 KiB.
pub const PageSize = struct {
    bytes: u64,

    pub fn fromBytes(bytes: u64) Error!PageSize {
        if (bytes < 4096 or !std.math.isPowerOfTwo(bytes)) {
            return error.InvalidPageSize;
        }
        return .{ .bytes = bytes };
    }

    pub fn offset(self: PageSize, addr: DMAAddr) u64 {
        return addr.raw() & (self.bytes - 1);
    }

    pub fn isPageAligned(self: PageSize, addr: DMAAddr) bool {
        return self.offset(addr) == 0;
    }

    pub fn remainingInPage(self: PageSize, addr: DMAAddr) u64 {
        return self.bytes - self.offset(addr);
    }

    pub fn entriesPerListPage(self: PageSize) usize {
        return @intCast(@divExact(self.bytes, @sizeOf(PrpEntry)));
    }
};

/// Caller-owned page of PRP entries. `wrap` enforces page alignment and the
/// `pageSize / 8` capacity ceiling; entry slots are written by
/// `DataPointers.fromContiguous`.
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

/// Number of PRP-list entries a contiguous transfer requires beyond
/// PRP1/PRP2. Returns 0 when PRP1 (and optionally inline PRP2) suffice;
/// callers size their `PrpList` from the non-zero return.
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
    std.debug.assert(divisor != 0);

    const rounded = std.math.divCeil(u64, value, divisor) catch unreachable;
    return std.math.cast(usize, rounded) orelse error.Overflow;
}
