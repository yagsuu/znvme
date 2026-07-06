//! Aggregates every host-side test. Spec: docs/specs/architecture.md,
//! docs/specs/verification/test-strategy.md.

comptime {
    _ = @import("core/ids_test.zig");
    _ = @import("core/status_test.zig");
    _ = @import("core/registers_test.zig");
    _ = @import("core/prp_test.zig");
    _ = @import("identify/controller_test.zig");
}
