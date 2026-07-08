# Core identifiers

Status: Approved.

`[nvme]` NVMe defines Namespace Identifier (NSID), Command Identifier (CID), and Queue Identifier (QID) scalar fields with the wire widths listed below.

`Nsid`, `Cid`, and `Qid` are the three strong scalar identifiers `znvme` uses at every wire boundary. Each is a domain-tagged wrapper over `stdx.tags.Tag(Domain, Int)` with predicates for reserved values.

Every raw integer of the underlying width is a representable identifier. Context-specific validity — no-namespace vs broadcast, admin vs I/O, in-range vs reserved — is checked through predicates or the consuming spec, never rejected at construction. Uniqueness within an outstanding-command set is a caller invariant and lives in `docs/specs/controller/queue.md`.

## Owned scope

This spec owns:

- widths, alignments, and colocated layout assertions for `Nsid`, `Cid`, `Qid`;
- domain tags (`NsidDomain`, `CidDomain`, `QidDomain`) that keep the three types distinct at type level;
- constructors (`from`), raw accessor (`raw`), named reserved-value constants, and predicates;
- boundary rule for composition inside wire types.

## Deferred scope and non-goals

This spec does not own:

- CID allocation, reuse, or outstanding-set tracking — owned by `docs/specs/controller/queue.md`, backed by `stdx.tags.TagAllocator.Bounded(CidDomain, u16)`;
- QID upper bound enforcement — depends on Set Features (Number of Queues) negotiation performed by the caller; the negotiated ceiling is caller state, not znvme state. Consumer specs (`docs/specs/examples/controller-bringup.md`) illustrate the caller-side sequence;
- per-command admissibility of `Nsid.broadcast` — each admin command builder decides whether broadcast is legal in its context; owned by `docs/specs/commands/admin.md`;
- byte-order mechanics at the wire boundary — first-slice wire specs either use native little-endian loads/stores on the required target or explicit `stdx.layout.Le(uN)` lanes when that owning wire spec chooses them.

## Widths

`[nvme]` NVMe Base Specification 2.0 fixes the widths:

| Identifier | Width | Notes |
| --- | --- | --- |
| `Nsid` | `u32` | SQE dword 1, Identify Namespace input |
| `Cid` | `u16` | SQE dword 0 bits `[31:16]`, CQE dword 3 bits `[15:0]` |
| `Qid` | `u16` | doorbell array index, Create/Delete I/O SQ/CQ CDW10, Set Features Number-of-Queues |

## Reserved values

### `Nsid`

- `[nvme]` `0x0000_0000` means no namespace. It is legal on admin commands that do not target a namespace (Identify Controller, Get Log Page against the controller, ...) and illegal on NVM commands.
  In this spec that value is named `Nsid.none`.
- `[nvme]` `0xFFFF_FFFF` means broadcast. It is legal on a subset of admin commands (Format NVM, Sanitize, ...) and illegal elsewhere.
- `[nvme]` `0x0000_0001 .. 0xFFFF_FFFE` is the ordinary valid namespace range.
- Per-command admissibility of `Nsid.broadcast` is owned by the command builder specs.

### `Cid`

`[nvme]` `Cid` has no reserved values; any `u16` is legal on the wire.

Uniqueness within a queue's outstanding-command set is a caller invariant, enforced by `stdx.tags.TagAllocator.Bounded(CidDomain, u16)` inside `controller/queue.zig`; the type itself carries no membership state.

### `Qid`

- `[nvme]` `0x0000` is the admin queue identifier. Both the admin SQ and the admin CQ carry `Qid.admin`.
- `[nvme]` `0xFFFF` is a reserved sentinel.
- `[nvme]` `0x0001 .. 0xFFFE` is the I/O queue range.
- The runtime upper bound for I/O queue identifiers is negotiated via Set Features (Number of Queues) by the caller through `docs/specs/commands/admin.md`; the negotiated ceiling is caller state. `Controller(Backend)` does not read or store the negotiated ceiling — `docs/specs/controller/init.md` explicitly excludes Set Features (Number of Queues) from `Controller.enable`.

## Approved API

The approved public API shape is:

```zig
// src/core/ids.zig
//! Core identifiers: Nsid, Cid, Qid. Spec: docs/specs/core/ids.md.

const std = @import("std");

const stdx = @import("stdx");

pub const NsidDomain = opaque {};
pub const CidDomain = opaque {};
pub const QidDomain = opaque {};

/// Namespace Identifier. `u32` on the wire.
pub const Nsid = struct {
    tag: stdx.tags.Tag(NsidDomain, u32),

    pub const Raw = u32;

    /// `0x0000_0000` — no namespace. Legal on admin commands that do not target a namespace.
    pub const none: Nsid = .{ .tag = .fromInt(0x0000_0000) };

    /// `0xFFFF_FFFF` — broadcast. Legal on a subset of admin commands; per-command builders decide.
    pub const broadcast: Nsid = .{ .tag = .fromInt(0xFFFF_FFFF) };

    pub fn from(value: Raw) Nsid {
        return .{ .tag = .fromInt(value) };
    }

    pub fn raw(self: Nsid) Raw {
        return self.tag.raw();
    }

    pub fn isNone(self: Nsid) bool {
        return self.raw() == 0x0000_0000;
    }

    pub fn isBroadcast(self: Nsid) bool {
        return self.raw() == 0xFFFF_FFFF;
    }

    pub fn isValidNamespace(self: Nsid) bool {
        const v = self.raw();
        return v != 0x0000_0000 and v != 0xFFFF_FFFF;
    }

    comptime {
        std.debug.assert(@sizeOf(Nsid) == 4);
        std.debug.assert(@alignOf(Nsid) == @alignOf(u32));
        std.debug.assert(@bitSizeOf(Nsid) == 32);
    }
};

/// Command Identifier. `u16` on the wire. Uniqueness within a queue is a caller invariant.
pub const Cid = struct {
    tag: stdx.tags.Tag(CidDomain, u16),

    pub const Raw = u16;

    pub fn from(value: Raw) Cid {
        return .{ .tag = .fromInt(value) };
    }

    pub fn raw(self: Cid) Raw {
        return self.tag.raw();
    }

    comptime {
        std.debug.assert(@sizeOf(Cid) == 2);
        std.debug.assert(@alignOf(Cid) == @alignOf(u16));
        std.debug.assert(@bitSizeOf(Cid) == 16);
    }
};

/// Queue Identifier. `u16` on the wire. `0` = admin queue. `0xFFFF` reserved.
pub const Qid = struct {
    tag: stdx.tags.Tag(QidDomain, u16),

    pub const Raw = u16;

    /// Admin queue id. Both admin SQ and admin CQ carry `Qid.admin`.
    pub const admin: Qid = .{ .tag = .fromInt(0x0000) };

    /// Reserved sentinel `0xFFFF`.
    pub const reserved_max: Qid = .{ .tag = .fromInt(0xFFFF) };

    pub fn from(value: Raw) Qid {
        return .{ .tag = .fromInt(value) };
    }

    pub fn raw(self: Qid) Raw {
        return self.tag.raw();
    }

    pub fn isAdmin(self: Qid) bool {
        return self.raw() == 0x0000;
    }

    pub fn isReserved(self: Qid) bool {
        return self.raw() == 0xFFFF;
    }

    pub fn isIoQueue(self: Qid) bool {
        const v = self.raw();
        return v != 0x0000 and v != 0xFFFF;
    }

    comptime {
        std.debug.assert(@sizeOf(Qid) == 2);
        std.debug.assert(@alignOf(Qid) == @alignOf(u16));
        std.debug.assert(@bitSizeOf(Qid) == 16);
    }
};
```

## Boundary rule

The `Nsid`/`Cid`/`Qid` types themselves are host-native scalar values wrapped in one-field structs. `@sizeOf`, `@alignOf`, and `@bitSizeOf` match the wire width exactly, so the wrapper is layout-transparent for first-slice native little-endian use.

Owning wire specs decide the byte-order mechanism at each field: they may use native little-endian loads/stores on the required first-slice target, or wrap the lane in `stdx.layout.Le(u32)` / `stdx.layout.Le(u16)` when explicit endian wrappers are part of that wire spec. Wire decoding reads the raw integer and calls `Nsid.from(...)`, `Cid.from(...)`, or `Qid.from(...)`.

This keeps the id types semantic values usable in host arithmetic (doorbell address computation, `Set Features` payload construction) while confining byte-order concerns to the owning encode/decode boundary.

## `stdx` primitives consumed

- `stdx.tags.Tag(Domain, Int)` — the underlying strong-typed enum wrapper for each of the three id types.

## Composition sites

- **`core/registers.zig`** — the doorbell address computation composes `Qid.raw()` with `CAP.DSTRD`; the arithmetic lives in `core/doorbell.zig`.
- **`commands/sqe.zig`** — SQE carries CID in dword 0 and NSID in dword 1. Builder and view convert to and from `Cid` / `Nsid` using the wire spec's endian-lane policy.
- **`commands/cqe.zig`** — CQE carries CID in dword 3 low half. View converts back to `Cid`.
- **`commands/admin.zig`** — Set Features (Number of Queues) requests carry `u16` I/O SQ and I/O CQ counts; the negotiated ceiling is caller state (read from `NumberOfQueues.ResponseDw0.allocated()`), not stored on `Qid` or on `Controller(Backend)`.
- **`controller/queue.zig`** — outstanding-CID tracking uses `stdx.tags.TagAllocator.Bounded(CidDomain, u16)` over a caller-supplied bitmap; the allocator issues `Cid` values, and the queue pairs them with SQ slots.
- **`identify/namespace.zig`** — Identify Namespace input takes `Nsid`; broadcast is admissible for CNS `1Bh` (allocated namespace list) but not for CNS `00h`.

## Validation phases

Per `docs/specs/architecture.md` §"Validation phases":

- **Compile time.** `@sizeOf` / `@alignOf` / `@bitSizeOf` per type, colocated with the type body.
- **Public validation.** None on the id types. Wire types that embed them decide whether a decoded value is admissible in their context.
- **Assertions.** None on the id types. Programmer errors involving id use (double-CID, unallocated CID release, doorbell on reserved QID) fire inside the consuming type (queue, register accessor).

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `Nsid.from` / `Cid.from` / `Qid.from` | never | never | O(1) | pure | none | infallible |
| `raw` on any id | never | never | O(1) | pure | none | infallible |
| `isNone` / `isBroadcast` / `isValidNamespace` | never | never | O(1) | pure | none | infallible |
| `isAdmin` / `isReserved` / `isIoQueue` | never | never | O(1) | pure | none | infallible |

Every operation is a value-type method with no state, no allocation, no waiting, and no hidden global access.

## Required tests

Test file `test/core/ids_test.zig`. Naming per `docs/guidelines/testing.md`.

- `unit: ids Nsid.none and Nsid.broadcast match spec sentinels` — raw values are `0` and `0xFFFF_FFFF`.
- `unit: ids Nsid predicates classify none / broadcast / valid namespace` — values constructed with `Nsid.from` are exhaustive over `{0, 1, 0xFFFF_FFFE, 0xFFFF_FFFF}` plus a mid-range value.
- `unit: ids Cid round-trips every boundary u16` — values constructed with `Cid.from` cover `0`, `1`, `0x7FFF`, `0x8000`, `0xFFFE`, `0xFFFF`. No reserved-value predicates because there are none.
- `unit: ids Qid.admin and Qid.reserved_max match spec sentinels` — raw values are `0` and `0xFFFF`.
- `unit: ids Qid predicates classify admin / io queue / reserved` — values constructed with `Qid.from` are exhaustive over `{0, 1, 0xFFFE, 0xFFFF}`.
- `unit: ids sizes and alignments match wire widths` — asserts `@sizeOf`, `@alignOf`, `@bitSizeOf` per type. Redundant with the comptime block, but present as a host-side behavioral check.
- `unit: ids distinct domains do not implicitly convert` — comptime `@TypeOf(Nsid.none) != @TypeOf(Cid.from(0))` and `@TypeOf(Cid.from(0)) != @TypeOf(Qid.from(0))`. Demonstrates the type-level guarantee that `stdx.tags.Tag` gives.

Round-trip tests through SQE and CQE wire fields live in the SQE and CQE specs, not here.

## Open questions

_(none)_
