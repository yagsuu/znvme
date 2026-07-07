//! Aggregates every host-side test. Spec: docs/specs/architecture.md,
//! docs/specs/verification/test-strategy.md.

comptime {
    _ = @import("core/ids_test.zig");
    _ = @import("core/status_test.zig");
    _ = @import("core/registers_test.zig");
    _ = @import("core/doorbell_test.zig");
    _ = @import("core/prp_test.zig");
    _ = @import("commands/sqe_test.zig");
    _ = @import("commands/cqe_test.zig");
    _ = @import("commands/admin_test.zig");
    _ = @import("commands/nvm_test.zig");
    _ = @import("controller/queue_test.zig");
    _ = @import("controller/init_test.zig");
    _ = @import("identify/controller_test.zig");
    _ = @import("identify/namespace_test.zig");
}
