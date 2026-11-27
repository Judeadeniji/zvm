//! Shared context passed to CLI subcommand handlers.

const zvm = @import("zvm");
const report = @import("report.zig");

/// Exit statuses a command may ask for. Every handler that prints its own diagnostic
/// returns `error.Reported`, so the specific status travels here instead of in the
/// error value, which cannot carry a payload.
pub const ExitCode = struct {
    /// Unspecified: the CLI reports a generic failure.
    pub const generic: u8 = 1;
    /// The requested version or platform build does not exist.
    pub const unavailable: u8 = 2;
    /// The network request failed.
    pub const network: u8 = 3;
    /// A checksum or signature did not verify.
    pub const integrity: u8 = 4;
};

/// Shared application state passed to every CLI command via `zli`'s `DataContext`.
pub const AppContext = struct {
    paths: *const zvm.Paths,
    cwd: []const u8,
    reporter: report.Reporter,
    /// Set by a handler that wants a specific status for `error.Reported`; 0 means the
    /// generic one.
    exit_code: u8 = 0,
};
