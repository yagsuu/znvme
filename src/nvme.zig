//! Public nvme surface. Spec: docs/specs/architecture.md.

pub const core = @import("core/root.zig");
pub const controller = @import("controller/root.zig");
pub const commands = @import("commands/root.zig");
pub const identify = @import("identify/root.zig");
