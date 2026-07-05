# Core completion status

Status: Approved.

`[nvme]` The NVMe Completion Queue Entry (CQE) contains a 16-bit Status lane with phase tag, Status Code (`SC`), Status Code Type (`SCT`), Command Retry Delay (`CRD`) index, More (`M`), and Do Not Retry (`DNR`) bits.

`[znvme]` `CompletionStatus` decodes that native status lane into a semantic value exposing those fields.

`[znvme]` This spec owns the status value taxonomy. The 16-byte CQE wire layout is owned by `docs/specs/commands/cqe.md`; queue phase tracking is owned by `docs/specs/controller/queue.md`.

`[znvme]` In the first slice, the owning CQE wire view reads the little-endian status lane as a native `u16` on the required little-endian target before calling `CompletionStatus.from(...)`. Big-endian host/target compatibility does not land until an approved spec updates the owning wire views and this boundary.

## Owned scope

`[znvme]` This spec owns:

- `[znvme]` the CQE Status lane bit layout;
- `[znvme]` `CompletionStatus` semantic wrapper;
- `[znvme]` `CodeType`, `RetryDelay`, and `GenericCode` enums;
- `[znvme]` `Kind` and `Failure` taxonomy values;
- `[znvme]` raw round-trip and field accessors;
- `[znvme]` success/failure classification.

## Deferred scope and non-goals

`[znvme]` This spec does not own:

- `[znvme]` the CQE's 16-byte wire layout or field offsets (`docs/specs/commands/cqe.md`);
- `[znvme]` queue phase validation (`docs/specs/controller/queue.md`);
- `[znvme]` automatic retry policy based on `CRD` or `DNR`;
- `[znvme]` Error Information log retrieval when `M = 1`;
- `[znvme]` exhaustive command-specific, media/data-integrity, path-related, or vendor-specific code names;
- `[znvme]` big-endian host or target support.

`[znvme]` Command-set specs add helper classifiers only for their own status-code domains; helper classifiers do not change `CompletionStatus`.

## Bit layout

`[nvme]` NVMe CQE Status lane layout, least-significant bit first:

| Marker | Bits | Width | Field | Meaning |
| --- | --- | ---: | --- | --- |
| `[nvme]` | `0` | 1 | `P` | Phase Tag |
| `[nvme]` | `1..8` | 8 | `SC` | Status Code |
| `[nvme]` | `9..11` | 3 | `SCT` | Status Code Type |
| `[nvme]` | `12..13` | 2 | `CRD` | Command Retry Delay index |
| `[nvme]` | `14` | 1 | `M` | More status information available |
| `[nvme]` | `15` | 1 | `DNR` | Do Not Retry |

`[znvme]` In the first slice, the owning CQE wire view reads the little-endian lane as native `u16` before calling `CompletionStatus.from`.

## Status Code Type

| Marker | Raw | Name | Meaning |
| --- | ---: | --- | --- |
| `[nvme]` | `0h` | `generic` | Generic status codes applicable to multiple opcodes |
| `[nvme]` | `1h` | `command_specific` | Status code depends on the submitted command or command set |
| `[nvme]` | `2h` | `media_data_integrity` | Media and data-integrity errors |
| `[nvme]` | `3h` | `path_related` | Path-related errors |
| `[nvme]` | `4h..6h` | reserved | Representable, not named |
| `[nvme]` | `7h` | `vendor_specific` | Vendor-specific status code |

`[znvme]` Reserved `SCT` values are decoded as `.reserved_code_type = raw_sct` in `Kind`; they are not rejected.

## Generic status codes

`[znvme]` This spec names the Generic Command Status codes needed by the first slice and by common debugging. The enum is non-exhaustive; unknown Generic codes remain representable.

| Marker | Raw | Name |
| --- | ---: | --- |
| `[nvme]` | `00h` | `success` |
| `[nvme]` | `01h` | `invalid_command_opcode` |
| `[nvme]` | `02h` | `invalid_field` |
| `[nvme]` | `03h` | `command_id_conflict` |
| `[nvme]` | `04h` | `data_transfer_error` |
| `[nvme]` | `05h` | `commands_aborted_power_loss` |
| `[nvme]` | `06h` | `internal_error` |
| `[nvme]` | `07h` | `command_abort_requested` |
| `[nvme]` | `08h` | `command_aborted_sq_deletion` |
| `[nvme]` | `09h` | `fused_command_failed` |
| `[nvme]` | `0Ah` | `fused_command_missing` |
| `[nvme]` | `0Bh` | `invalid_namespace_or_format` |
| `[nvme]` | `0Ch` | `command_sequence_error` |
| `[nvme]` | `0Dh` | `invalid_sgl_segment_descriptor` |
| `[nvme]` | `0Eh` | `invalid_number_sgl_descriptors` |
| `[nvme]` | `0Fh` | `data_sgl_length_invalid` |
| `[nvme]` | `10h` | `metadata_sgl_length_invalid` |
| `[nvme]` | `11h` | `sgl_descriptor_type_invalid` |
| `[nvme]` | `12h` | `invalid_use_controller_memory_buffer` |
| `[nvme]` | `13h` | `prp_offset_invalid` |

`[znvme]` Command-specific, media/data-integrity, path-related, and vendor-specific status-code names are deliberately not introduced here. The raw `u8` is preserved until the owning command-set spec needs a named interpretation.

## znvme behavior

`[znvme]` `CompletionStatus.init(params)` composes a semantic status value from `Init` fields `phase`, `code_type`, `code`, `retry_delay`, `more`, and `do_not_retry`. `CompletionStatus.success(phase)` and `CompletionStatus.genericFailure(phase, code)` are shortcuts for the two common fixture shapes. These constructors exist for device-emulator fixtures and test authoring; the polling loop still consumes device-authored bytes through `CompletionStatus.from`.

`[znvme]` `CompletionStatus.init(params).raw()` fed back through `CompletionStatus.from` reproduces the same accessor values; the builders are decode-symmetric.

## Approved API

`[znvme]` The approved public API shape is:

```zig
// src/core/status.zig
//! CQE status decode. Spec: docs/specs/core/status.md.

const std = @import("std");

pub const CompletionStatus = struct {
    bits: Bits,

    pub const Raw = u16;

    pub const Bits = packed struct(u16) {
        phase: u1,
        code: u8,
        code_type: u3,
        retry_delay: u2,
        more: u1,
        do_not_retry: u1,
    };

    pub const CodeType = enum(u3) {
        generic = 0x0,
        command_specific = 0x1,
        media_data_integrity = 0x2,
        path_related = 0x3,
        vendor_specific = 0x7,
        _,
    };

    pub const RetryDelay = enum(u2) {
        none = 0,
        crdt1 = 1,
        crdt2 = 2,
        crdt3 = 3,
    };

    pub const GenericCode = enum(u8) {
        success = 0x00,
        invalid_command_opcode = 0x01,
        invalid_field = 0x02,
        command_id_conflict = 0x03,
        data_transfer_error = 0x04,
        commands_aborted_power_loss = 0x05,
        internal_error = 0x06,
        command_abort_requested = 0x07,
        command_aborted_sq_deletion = 0x08,
        fused_command_failed = 0x09,
        fused_command_missing = 0x0A,
        invalid_namespace_or_format = 0x0B,
        command_sequence_error = 0x0C,
        invalid_sgl_segment_descriptor = 0x0D,
        invalid_number_sgl_descriptors = 0x0E,
        data_sgl_length_invalid = 0x0F,
        metadata_sgl_length_invalid = 0x10,
        sgl_descriptor_type_invalid = 0x11,
        invalid_use_controller_memory_buffer = 0x12,
        prp_offset_invalid = 0x13,
        _,
    };

    pub const Kind = union(enum) {
        success,
        generic: GenericCode,
        command_specific: u8,
        media_data_integrity: u8,
        path_related: u8,
        vendor_specific: u8,
        reserved_code_type: u3,
    };

    pub const Failure = struct {
        kind: Kind,
        retry_delay: RetryDelay,
        more: bool,
        do_not_retry: bool,
    };

    /// Semantic construction inputs. `phase` is required; every other field
    /// defaults to the "success" side so `CompletionStatus.init(.{ .phase = true })`
    /// yields a phase-1 generic-success value.
    pub const Init = struct {
        phase: bool,
        code_type: CodeType = .generic,
        code: u8 = @intFromEnum(GenericCode.success),
        retry_delay: RetryDelay = .none,
        more: bool = false,
        do_not_retry: bool = false,
    };

    /// Compose a `CompletionStatus` from semantic fields.
    pub fn init(params: Init) CompletionStatus {
        return .{ .bits = .{
            .phase = @intFromBool(params.phase),
            .code = params.code,
            .code_type = @intFromEnum(params.code_type),
            .retry_delay = @intFromEnum(params.retry_delay),
            .more = @intFromBool(params.more),
            .do_not_retry = @intFromBool(params.do_not_retry),
        } };
    }

    /// Shortcut for the common "posted successful admin completion" fixture:
    /// `CompletionStatus.init(.{ .phase = phase })`.
    pub fn success(phase: bool) CompletionStatus {
        return init(.{ .phase = phase });
    }

    /// Shortcut for a generic-status failure with a chosen `GenericCode`.
    pub fn genericFailure(phase: bool, code: GenericCode) CompletionStatus {
        return init(.{
            .phase = phase,
            .code_type = .generic,
            .code = @intFromEnum(code),
        });
    }

    pub fn from(value: Raw) CompletionStatus {
        return .{ .bits = @bitCast(value) };
    }

    pub fn raw(self: CompletionStatus) Raw {
        return @bitCast(self.bits);
    }

    pub fn phase(self: CompletionStatus) bool {
        return self.bits.phase != 0;
    }

    pub fn code(self: CompletionStatus) u8 {
        return self.bits.code;
    }

    pub fn codeType(self: CompletionStatus) CodeType {
        return @enumFromInt(self.bits.code_type);
    }

    pub fn retryDelay(self: CompletionStatus) RetryDelay {
        return @enumFromInt(self.bits.retry_delay);
    }

    pub fn hasMore(self: CompletionStatus) bool {
        return self.bits.more != 0;
    }

    pub fn doNotRetry(self: CompletionStatus) bool {
        return self.bits.do_not_retry != 0;
    }

    /// True iff the status field decodes to a generic-success completion:
    /// `codeType == .generic` and `code == GenericCode.success`. This is a
    /// pure status-field decoder and never consults the phase bit. Callers
    /// reading a CQ slot directly must verify phase separately through
    /// `Cqe.phase()` or `Cqe.isPostedSuccess(expected_phase)`;
    /// callers using a `queue.Completion` returned from `pollOne` have
    /// already had phase verified and use `Completion.statusIsSuccess()`.
    pub fn isSuccess(self: CompletionStatus) bool {
        return self.codeType() == .generic and self.code() == @intFromEnum(GenericCode.success);
    }

    pub fn kind(self: CompletionStatus) Kind {
        if (self.isSuccess()) return .success;

        return switch (self.codeType()) {
            .generic => .{ .generic = @enumFromInt(self.code()) },
            .command_specific => .{ .command_specific = self.code() },
            .media_data_integrity => .{ .media_data_integrity = self.code() },
            .path_related => .{ .path_related = self.code() },
            .vendor_specific => .{ .vendor_specific = self.code() },
            else => .{ .reserved_code_type = self.bits.code_type },
        };
    }

    pub fn failure(self: CompletionStatus) ?Failure {
        if (self.isSuccess()) return null;

        return .{
            .kind = self.kind(),
            .retry_delay = self.retryDelay(),
            .more = self.hasMore(),
            .do_not_retry = self.doNotRetry(),
        };
    }

    comptime {
        std.debug.assert(@bitSizeOf(Bits) == 16);
        std.debug.assert(@bitSizeOf(CodeType) == 3);
        std.debug.assert(@bitSizeOf(RetryDelay) == 2);
        std.debug.assert(@bitSizeOf(GenericCode) == 8);
        std.debug.assert(@sizeOf(CompletionStatus) == 2);
        std.debug.assert(@alignOf(CompletionStatus) == @alignOf(u16));
    }
};
```

## Boundary rule

`[znvme]` `CompletionStatus` is a semantic host value. The CQE wire view owns loading the status lane from CQE bytes. In the first slice, that load is native little-endian on the required target; big-endian portability does not land until an approved CQE/status endian spec exists.

`[znvme]` The queue owns phase matching. A status whose `phase()` does not equal the queue's expected phase is not a failed command; it is an empty/not-yet-posted CQ slot for that queue pass. `CompletionStatus.isSuccess()` is phase-agnostic: it returns `true` iff the status field decodes to `codeType == .generic` and `code == GenericCode.success`. An all-zero status lane (unposted slot) therefore has `isSuccess() == true` when viewed through `CompletionStatus` alone; posted-vs-not-posted is a queue-level predicate exposed by `Cqe.isPostedSuccess` and pre-checked before `queue.Completion` is returned to callers.

## Validation behavior

`[znvme]` No `validate` method exists. Every `u16` lane is representable:

- `[znvme]` reserved `SCT` values are preserved as `.reserved_code_type`;
- `[znvme]` unknown Generic codes are preserved by the non-exhaustive `GenericCode` enum;
- `[znvme]` command-specific, media/data-integrity, path-related, and vendor-specific codes are preserved as raw `u8`;
- `[znvme]` `CRD`, `M`, and `DNR` are decoded even when paired with success or reserved types.

`[znvme]` This module decodes device output. It does not reject device output.

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Concurrency | Ordering | Errors |
| --- | --- | --- | --- | --- | --- | --- |
| `[znvme]` `CompletionStatus.from` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `raw` | never | never | O(1) | value type | none | infallible |
| `[znvme]` scalar accessors (`phase`, `code`, `codeType`, `retryDelay`, `hasMore`, `doNotRetry`) | never | never | O(1) | value type | none | infallible |
| `[znvme]` `isSuccess` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `kind` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `failure` | never | never | O(1) | value type | none | infallible |
| `[znvme]` `init` / `success` / `genericFailure` | never | never | O(1) | value type | none | infallible |

`[znvme]` Every operation is a pure value operation. No allocation, hidden global state, target probing, barriers, volatile access, or I/O.

## Required tests `[znvme]`

`[znvme]` Test file `test/core/status_test.zig`. Naming per `docs/guidelines/testing.md`.

- `[znvme]` `unit: status decodes success with phase one` — `CompletionStatus.from(0x0001)` decodes phase `true`, success, `failure() == null`.
- `[znvme]` `unit: status decodes generic invalid field` — `CompletionStatus.from(raw)` with phase set, SCT generic, and SC invalid_field yields `failure().kind.generic == .invalid_field`.
- `[znvme]` `unit: status decodes command specific raw code` — `CompletionStatus.from(raw)` with SCT command_specific and SC `0x02` yields `failure().kind.command_specific == 0x02`.
- `[znvme]` `unit: status decodes media and path raw codes` — raw codes preserved under `.media_data_integrity` and `.path_related`.
- `[znvme]` `unit: status decodes vendor specific raw code` — raw code preserved under `.vendor_specific`.
- `[znvme]` `unit: status preserves reserved code type` — SCT `4`, `5`, or `6` yields `.reserved_code_type`.
- `[znvme]` `unit: status decodes retry delay more and do-not-retry` — CRD `2`, M `1`, DNR `1` decode to `.crdt2`, `true`, `true`.
- `[znvme]` `unit: status raw roundtrip preserves all bits` — every tested lane value constructed with `CompletionStatus.from` returns from `raw()` unchanged.
- `[znvme]` `unit: completion status isSuccess returns true for all-zero status field regardless of phase bit` — asserts the phase-agnostic contract; a `0x0000` lane decodes to generic-success even though its phase bit is clear.
- `[znvme]` `unit: CompletionStatus.init round-trips through raw and from` — every builder-produced value equals `CompletionStatus.from(built.raw())` on every accessor.
- `[znvme]` `unit: CompletionStatus.success(phase) returns a generic-success value with the given phase bit`.
- `[znvme]` `unit: CompletionStatus.genericFailure(phase, code) sets code_type generic and preserves phase and code`.

`[znvme]` Round-trip through a CQE byte fixture is owned by `docs/specs/commands/cqe.md`.

## Open questions

_(none)_
