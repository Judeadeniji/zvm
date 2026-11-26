//! Shared context passed to CLI subcommand handlers.

const zvm = @import("zvm");
const report = @import("report.zig");

/// Shared application state passed to every CLI command via `zli`'s `DataContext`.
pub const AppContext = struct {
    paths: *const zvm.Paths,
    cwd: []const u8,
    reporter: report.Reporter,
};
