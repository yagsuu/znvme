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

    /// True iff `self` is neither `none` nor `broadcast` — a real namespace target.
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
