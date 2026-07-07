//! NVMe controller reset/enable/shutdown state machine.
//! Spec: docs/specs/controller/init.md.

const std = @import("std");

const stdx = @import("stdx");

const doorbell = @import("../core/doorbell.zig");
const prp = @import("../core/prp.zig");
const queue = @import("queue.zig");
const registers = @import("../core/registers.zig");

const Aqa = registers.Aqa;
const Cc = registers.Cc;
const ControllerRegisters = registers.ControllerRegisters;
const Cqe = @import("../commands/cqe.zig").Cqe;
const PageSize = prp.PageSize;
const QueueBase = registers.QueueBase;
const ShutdownNotification = registers.ShutdownNotification;
const Sqe = @import("../commands/sqe.zig").Sqe;

pub const State = enum {
    unknown,
    disabled,
    ready,
    shutdown_occurring,
    shutdown_complete,
    fatal,
};

pub const Error = error{
    ControllerFatal,
    Timeout,
    NotDisabled,
    NotReady,
    PageSizeUnsupported,
    UnsupportedCommandSet,
    AdminBufferLengthMismatch,
    AdminPairMismatch,
} || QueueBase.Error || Aqa.Error || stdx.time.Duration.Error || queue.InitError || queue.ReserveError || queue.FlushError || queue.PollError;

pub const default_backoff_policy: stdx.time.Backoff.Policy = .{
    .spin_iterations = 128,
    .yield_iterations = 0,
    .yield = null,
    .initial_wait = stdx.time.Duration.fromMicros(1) catch unreachable,
    .max_wait = stdx.time.Duration.fromMillis(1) catch unreachable,
    .growth_shift = 1,
};

pub fn Controller(comptime Backend: type) type {
    return struct {
        const Self = @This();

        pub const Clock = stdx.time.Clock.Monotonic(Backend);
        pub const Pair = queue.Pair(Backend);

        pub const Admin = struct {
            pub const Storage = struct {
                sq: stdx.dma.Buffer(Sqe),
                cq: stdx.dma.Buffer(Cqe),
                sq_depth: u16,
                cq_depth: u16,
                cid_words: []queue.CidAllocator.Word,
            };

            _storage: Storage,
            _pair: ?Pair = null,

            pub fn ready(self: *const Admin) bool {
                return self._pair != null;
            }

            pub fn sq(self: *Admin) *queue.SubmissionQueue {
                std.debug.assert(self.ready());
                return self._pair.?.sq();
            }

            pub fn cq(self: *Admin) *Pair.Cq {
                std.debug.assert(self.ready());
                return self._pair.?.cq();
            }

            pub fn pollOne(
                self: *Admin,
                deadline: stdx.time.Deadline,
                backoff: *stdx.time.Backoff,
            ) queue.PollError!queue.Completion {
                std.debug.assert(self.ready());
                return self._pair.?.pollOne(deadline, backoff);
            }
        };

        pub const Config = struct {
            registers: ControllerRegisters,
            admin: Admin.Storage,
            page_size: PageSize,
            clock: Clock,
            ready_timeout_override: ?stdx.time.Duration = null,
        };

        registers: ControllerRegisters,
        admin: Admin,
        page_size: PageSize,
        clock: Clock,
        db: doorbell.Doorbells,
        ready_timeout: stdx.time.Duration,
        state: State = .unknown,

        pub fn init(config: Config) Error!Self {
            const cap = config.registers.cap();
            if (!cap.supportsNvmCommandSet()) return error.UnsupportedCommandSet;

            const mps_bytes = config.page_size.bytes;
            if (mps_bytes < cap.minPageSizeBytes()) return error.PageSizeUnsupported;
            if (mps_bytes > cap.maxPageSizeBytes()) return error.PageSizeUnsupported;

            if (config.admin.sq.len() != config.admin.sq_depth) return error.AdminBufferLengthMismatch;
            if (config.admin.cq.len() != config.admin.cq_depth) return error.AdminBufferLengthMismatch;
            if (config.admin.sq_depth != config.admin.cq_depth) return error.AdminPairMismatch;

            _ = try Aqa.fromDepths(.{
                .submission_entries = config.admin.sq_depth,
                .completion_entries = config.admin.cq_depth,
            });
            _ = try QueueBase.fromDmaAddr(config.admin.sq.dmaAddr());
            _ = try QueueBase.fromDmaAddr(config.admin.cq.dmaAddr());
            _ = try queue.CidAllocator.wrap(config.admin.cid_words, config.admin.sq_depth);

            const ready_timeout = if (config.ready_timeout_override) |override|
                override
            else
                try stdx.time.Duration.fromMillis(@as(i64, cap.readyTimeoutUnits500ms()) * 500);

            return .{
                .registers = config.registers,
                .admin = .{ ._storage = config.admin },
                .page_size = config.page_size,
                .clock = config.clock,
                .db = doorbell.Doorbells.fromRegisters(config.registers, cap),
                .ready_timeout = ready_timeout,
            };
        }

        pub fn doorbells(self: Self) doorbell.Doorbells {
            return self.db;
        }

        pub fn reset(
            self: *Self,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void {
            const current = self.registers.cc();
            if (current.en != 0) self.registers.storeCc(Cc.disabled());

            try self.pollReady(false, deadline, backoff);
            self.admin._pair = null;
            self.state = .disabled;
        }

        pub fn enable(
            self: *Self,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void {
            if (self.state != .disabled) return error.NotDisabled;

            const storage = self.admin._storage;
            const aqa = Aqa.fromDepths(.{
                .submission_entries = storage.sq_depth,
                .completion_entries = storage.cq_depth,
            }) catch unreachable;
            const asq = QueueBase.fromDmaAddr(storage.sq.dmaAddr()) catch unreachable;
            const acq = QueueBase.fromDmaAddr(storage.cq.dmaAddr()) catch unreachable;

            self.registers.storeAqa(aqa);
            self.registers.storeAsq(asq);
            self.registers.storeAcq(acq);

            const shift_bits: u6 = @intCast(std.math.log2(self.page_size.bytes) - 12);
            const mps: u4 = @intCast(shift_bits);
            self.registers.storeCc(Cc.nvmEnabled(mps));

            try self.pollReady(true, deadline, backoff);

            const admin_sq = queue.SubmissionQueue.init(.{
                .qid = .admin,
                .capacity = storage.sq_depth,
                .ring = storage.sq,
                .cid_words = storage.cid_words,
                .doorbell = self.db.submissionQueue(.admin),
            }) catch unreachable;
            const admin_cq = Pair.Cq.init(.{
                .qid = .admin,
                .capacity = storage.cq_depth,
                .ring = storage.cq,
                .doorbell = self.db.completionQueue(.admin),
                .clock = self.clock,
            }) catch unreachable;
            self.admin._pair = Pair.init(admin_sq, admin_cq) catch unreachable;
            self.state = .ready;
        }

        pub fn shutdown(
            self: *Self,
            kind: ShutdownNotification,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void {
            if (self.state != .ready) return error.NotReady;
            std.debug.assert(kind == .normal or kind == .abrupt);

            const current = self.registers.cc();
            self.registers.storeCc(current.withShutdown(kind));
            self.state = .shutdown_occurring;

            try self.pollShutdown(deadline, backoff);
            self.state = .shutdown_complete;
        }

        pub fn pollReady(
            self: *Self,
            target: bool,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void {
            const Predicate = struct {
                ctrl: *Self,
                target: bool,

                pub fn call(p: @This()) Error!?void {
                    const csts = p.ctrl.registers.csts();
                    stdx.barrier.mmio.acquire();

                    if (csts.fatal()) {
                        p.ctrl.state = .fatal;
                        return error.ControllerFatal;
                    }

                    if (csts.ready() == p.target) return {};
                    return null;
                }
            };
            return stdx.io.poll.until(
                &self.clock,
                deadline,
                backoff,
                Predicate{ .ctrl = self, .target = target },
            );
        }

        pub fn pollShutdown(
            self: *Self,
            deadline: stdx.time.Deadline,
            backoff: *stdx.time.Backoff,
        ) Error!void {
            const Predicate = struct {
                ctrl: *Self,

                pub fn call(p: @This()) Error!?void {
                    const csts = p.ctrl.registers.csts();
                    stdx.barrier.mmio.acquire();

                    if (csts.fatal()) {
                        p.ctrl.state = .fatal;
                        return error.ControllerFatal;
                    }

                    if (csts.shst == .complete) return {};
                    return null;
                }
            };
            return stdx.io.poll.until(
                &self.clock,
                deadline,
                backoff,
                Predicate{ .ctrl = self },
            );
        }
    };
}
