//! Color-aware terminal reporting and friendly CLI error messages.
//!
//! Commands write user-facing errors and hints through `Reporter`, which keeps
//! diagnostics on stderr and colors them only when the target stream supports
//! ANSI escapes. Expected failures print a helpful message and return
//! `Reported`, so `zli` never appends a raw `error: ErrorName` line.

const std = @import("std");
const Io = std.Io;
const zvm = @import("zvm");

/// Sentinel returned by command handlers that already reported a user-facing error.
/// Handlers return `error.Reported` so `zli` does not append a raw error name.
pub const Reported = error{Reported};

const ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const cyan = "\x1b[36m";
    const bold_green = "\x1b[1;32m";
};

pub const Status = enum { ok, warn, fail, info };

const ColorMode = enum { auto, always, never };

pub const Reporter = struct {
    out: *Io.Writer,
    err: *Io.Writer,
    out_color: bool,
    err_color: bool,
    /// The buffered stdout writer behind `out`, when it is wrapped (for example by
    /// the ANSI stripper). Flushed before stderr writes so terminal output stays in
    /// order instead of releasing the whole stdout buffer at exit.
    out_sink: ?*Io.Writer = null,

    /// Detects color support from the environment and the real stdout/stderr.
    pub fn init(io: Io, environ_map: ?*const std.process.Environ.Map, out: *Io.Writer, err: *Io.Writer) Reporter {
        const mode = colorMode(environ_map);
        return .{
            .out = out,
            .err = err,
            .out_color = colorFor(Io.File.stdout(), io, mode),
            .err_color = colorFor(Io.File.stderr(), io, mode),
        };
    }

    /// Constructor for tests and embedders that already decided about color.
    pub fn initWithColor(out: *Io.Writer, err: *Io.Writer, out_color: bool, err_color: bool) Reporter {
        return .{
            .out = out,
            .err = err,
            .out_color = out_color,
            .err_color = err_color,
        };
    }

    /// Flushes buffered stdout so a following stderr message appears after it.
    fn syncStdout(self: *const Reporter) void {
        if (self.out_sink) |sink| sink.flush() catch {};
    }

    fn paint(
        self: *const Reporter,
        writer: *Io.Writer,
        enabled: bool,
        code: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const trailing_newline = comptime fmt.len > 0 and fmt[fmt.len - 1] == '\n';

        if (enabled) try writer.writeAll(code);
        if (trailing_newline) {
            try writer.print(fmt[0 .. fmt.len - 1], args);
            if (enabled) try writer.writeAll(ansi.reset);
            try writer.writeByte('\n');
        } else {
            try writer.print(fmt, args);
            if (enabled) try writer.writeAll(ansi.reset);
        }

        // Diagnostics are line-buffered: flush stderr so the terminal sees them in
        // the order they were produced.
        if (writer == self.err) try writer.flush();
    }

    /// Green success message on stdout.
    pub fn success(self: *const Reporter, comptime fmt: []const u8, args: anytype) !void {
        try self.paint(self.out, self.out_color, ansi.green, fmt, args);
    }

    /// Blue informational message on stdout.
    pub fn info(self: *const Reporter, comptime fmt: []const u8, args: anytype) !void {
        try self.paint(self.out, self.out_color, ansi.blue, fmt, args);
    }

    /// Yellow warning on stderr.
    pub fn warn(self: *const Reporter, comptime fmt: []const u8, args: anytype) !void {
        self.syncStdout();
        try self.paint(self.err, self.err_color, ansi.yellow, "warning: " ++ fmt, args);
    }

    /// Red error on stderr.
    pub fn fail(self: *const Reporter, comptime fmt: []const u8, args: anytype) !void {
        self.syncStdout();
        try self.paint(self.err, self.err_color, ansi.red, "error: " ++ fmt, args);
    }

    /// Dim hint on stderr, usually printed after a failure.
    pub fn hint(self: *const Reporter, comptime fmt: []const u8, args: anytype) !void {
        self.syncStdout();
        try self.paint(self.err, self.err_color, ansi.dim, "hint: " ++ fmt, args);
    }

    /// Dim note on stdout, for non-fatal follow-up information.
    pub fn note(self: *const Reporter, comptime fmt: []const u8, args: anytype) !void {
        try self.paint(self.out, self.out_color, ansi.dim, "note: " ++ fmt, args);
    }

    /// Dim suggestion on stdout, for non-fatal follow-up information.
    pub fn tip(self: *const Reporter, comptime fmt: []const u8, args: anytype) !void {
        try self.paint(self.out, self.out_color, ansi.dim, "tip: " ++ fmt, args);
    }

    /// Bold heading on stdout.
    pub fn heading(self: *const Reporter, comptime fmt: []const u8, args: anytype) !void {
        try self.paint(self.out, self.out_color, ansi.bold, fmt, args);
    }

    /// Dim text without a prefix.
    pub fn muted(self: *const Reporter, comptime fmt: []const u8, args: anytype) !void {
        try self.paint(self.out, self.out_color, ansi.dim, fmt, args);
    }

    /// Colored `[OK]`, `[WARN]`, `[FAIL]`, or `[INFO]` status row.
    /// Failures and warnings go to stderr so redirecting stdout never hides problems.
    pub fn status(self: *const Reporter, kind: Status, comptime fmt: []const u8, args: anytype) !void {
        const code = switch (kind) {
            .ok => ansi.green,
            .warn => ansi.yellow,
            .fail => ansi.red,
            .info => ansi.blue,
        };
        const tag = switch (kind) {
            .ok => "[OK]",
            .warn => "[WARN]",
            .fail => "[FAIL]",
            .info => "[INFO]",
        };
        const writer = switch (kind) {
            .ok, .info => self.out,
            .warn, .fail => blk: {
                self.syncStdout();
                break :blk self.err;
            },
        };
        const color = switch (kind) {
            .ok, .info => self.out_color,
            .warn, .fail => self.err_color,
        };
        if (color) try writer.writeAll(code);
        try writer.writeAll(tag);
        if (color) try writer.writeAll(ansi.reset);
        try writer.splatByteAll(' ', 7 - tag.len);
        try writer.print(fmt, args);
        if (writer == self.err) try writer.flush();
    }

    /// Writes `text` with a raw ANSI code, if color is enabled on stdout.
    pub fn paintOut(self: *const Reporter, code: []const u8, text: []const u8) !void {
        if (self.out_color) try self.out.writeAll(code);
        try self.out.writeAll(text);
        if (self.out_color) try self.out.writeAll(ansi.reset);
    }

    pub fn version(self: *const Reporter, text: []const u8) !void {
        try self.paintOut(ansi.cyan, text);
    }

    pub fn active(self: *const Reporter, text: []const u8) !void {
        try self.paintOut(ansi.bold_green, text);
    }

    pub fn successText(self: *const Reporter, text: []const u8) !void {
        try self.paintOut(ansi.green, text);
    }

    pub fn warnText(self: *const Reporter, text: []const u8) !void {
        try self.paintOut(ansi.yellow, text);
    }

    pub fn dim(self: *const Reporter, text: []const u8) !void {
        try self.paintOut(ansi.dim, text);
    }

    pub fn bold(self: *const Reporter, text: []const u8) !void {
        try self.paintOut(ansi.bold, text);
    }

    /// Friendly fallback for errors that escaped a command handler.
    pub fn reportError(self: *const Reporter, err: anyerror) !void {
        switch (err) {
            zvm.errors.CliError.InvalidVersion => {
                try self.fail("The provided Zig version is not valid.\n", .{});
                try self.hint("Use a version such as '0.17.0', 'master', or a constraint like '^0.17.0'.\n", .{});
            },
            zvm.errors.CliError.VersionNotInstalled => {
                try self.fail("The requested Zig version is not installed.\n", .{});
                try self.hint("Run 'zvm list' to see installed versions, or 'zvm install <version>' to install it.\n", .{});
            },
            zvm.errors.CliError.MissingVersion => {
                try self.fail("A Zig version is required.\n", .{});
                try self.hint("Run 'zvm <command> --help' for usage.\n", .{});
            },
            zvm.errors.CliError.MissingShell => {
                try self.fail("A shell name is required.\n", .{});
                try self.hint("Expected bash, zsh, fish, or powershell.\n", .{});
            },
            zvm.errors.CliError.UnsupportedShell => {
                try self.fail("Unsupported shell.\n", .{});
                try self.hint("Expected bash, zsh, fish, or powershell.\n", .{});
            },
            zvm.errors.ResolveError.NoVersionConfigured => {
                try self.fail("No Zig version is configured for this project.\n", .{});
                try self.hint("Run 'zvm use <version>' to set a global default, or 'zvm pin <version>' for this project.\n", .{});
            },
            zvm.errors.ResolveError.NoCompatibleVersionInstalled => {
                try self.fail("No installed Zig version satisfies the project's minimum_zig_version.\n", .{});
                try self.hint("Run 'zvm install <version>' to install a compatible release.\n", .{});
            },
            zvm.errors.ResolveError.UnmatchedZigVersionConstraint => {
                try self.fail("No installed Zig version satisfies the constraint in .zig-version.\n", .{});
                try self.hint("Run 'zvm install <version>' to install a matching release, or 'zvm pin <version>' to change the pin.\n", .{});
            },
            zvm.errors.ResolveError.InvalidZigVersionConstraint => {
                try self.fail("The .zig-version file does not contain a valid Zig version or constraint.\n", .{});
                try self.hint("Use a version such as '0.17.0' or 'master', or a range like '^0.17.0'.\n", .{});
            },
            zvm.errors.DownloadError.VersionNotFound => {
                try self.fail("That Zig version was not found in the release index.\n", .{});
                try self.hint("Run 'zvm list-remote' to see available versions.\n", .{});
            },
            zvm.errors.DownloadError.TargetNotAvailable => {
                try self.fail("No binary release is available for this platform.\n", .{});
                try self.hint("Run 'zvm list-remote --all' to see every published release.\n", .{});
            },
            zvm.errors.DownloadError.ChecksumMismatch, zvm.errors.DownloadError.InvalidExpectedChecksum => {
                try self.fail("The downloaded archive failed SHA-256 verification.\n", .{});
                try self.hint("Try again, or clear the cache with 'zvm clean' first.\n", .{});
            },
            zvm.errors.DownloadError.HttpRequestFailed => {
                try self.fail("Could not download the Zig release.\n", .{});
                try self.hint("Check your network connection and try again.\n", .{});
            },
            zvm.errors.DownloadError.InvalidIndexFormat, zvm.errors.DownloadError.InvalidReleaseFormat, zvm.errors.DownloadError.InvalidArtifactFields, zvm.errors.DownloadError.InvalidTargetFormat, zvm.errors.DownloadError.MissingChecksum, zvm.errors.DownloadError.MissingTarballUrl => {
                try self.fail("The Zig release index has an unexpected format.\n", .{});
                try self.hint("Try again later; if the problem persists, report it at https://github.com/Judeadeniji/zvm/issues.\n", .{});
            },
            zvm.errors.DownloadError.UnsupportedArchitecture, zvm.errors.DownloadError.UnsupportedOperatingSystem, zvm.errors.DownloadError.UnsupportedPlatformCombination => {
                try self.fail("Zig does not publish a binary for this platform.\n", .{});
                try self.hint("Run 'zvm list-remote --all' to see published targets, or build Zig from source.\n", .{});
            },
            zvm.errors.DownloadError.UnsupportedArchiveFormat => {
                try self.fail("The downloaded archive uses an unsupported format.\n", .{});
                try self.hint("Try again, or clear the cache with 'zvm clean' first.\n", .{});
            },
            zvm.errors.DownloadError.DecompressionFailed, zvm.errors.DownloadError.ExtractionFailed => {
                try self.fail("Could not extract the downloaded Zig archive.\n", .{});
                try self.hint("Clear the cache with 'zvm clean' and try again.\n", .{});
            },
            zvm.errors.DownloadError.SignatureVerificationFailed, zvm.errors.DownloadError.GlobalSignatureVerificationFailed, zvm.errors.DownloadError.KeyIdMismatch, zvm.errors.DownloadError.InvalidSignatureFormat, zvm.errors.DownloadError.InvalidPublicKey, zvm.errors.DownloadError.UnsupportedKeyAlgorithm, zvm.errors.DownloadError.UnsupportedSignatureAlgorithm => {
                try self.fail("The Zig release signature could not be verified.\n", .{});
                try self.hint("The download may be corrupted or tampered with. Try again, or pass --no-minisig only if you trust the source.\n", .{});
            },
            zvm.errors.ShimError.ShimAlreadyExists => {
                try self.fail("The zig shim already exists and points somewhere else.\n", .{});
                try self.hint("Re-run 'zvm setup --force' to replace it.\n", .{});
            },
            zvm.errors.PathError.EnvironmentHomeMissing => {
                try self.fail("Could not determine your home directory.\n", .{});
                try self.hint("Set HOME (or USERPROFILE on Windows) and try again.\n", .{});
            },
            error.Reported => {},
            error.OutOfMemory => {
                try self.fail("Out of memory.\n", .{});
                try self.hint("Close some programs and try again.\n", .{});
            },
            error.AccessDenied, error.PermissionDenied => {
                try self.fail("Permission denied.\n", .{});
                try self.hint("Check the permissions of the zvm directory and try again.\n", .{});
            },
            error.FileNotFound => {
                try self.fail("A required file or directory was not found.\n", .{});
                try self.hint("Run 'zvm doctor' to check your setup.\n", .{});
            },
            error.ReadOnlyFileSystem, error.NoSpaceLeft, error.DiskQuota => {
                try self.fail("Could not write to disk.\n", .{});
                try self.hint("Check free disk space and write permissions, then try again.\n", .{});
            },
            error.BrokenPipe, error.Canceled => {},
            else => if (isNetworkError(err)) {
                try self.fail("Could not reach the network.\n", .{});
                try self.hint("Check your network connection and try again.\n", .{});
            } else {
                try self.fail("Unexpected failure ({s}).\n", .{@errorName(err)});
                try self.hint("Run 'zvm doctor' to check your setup, or report this issue.\n", .{});
            },
        }
    }
};

/// Whether `err` is a transport failure, i.e. the host could not be reached. Callers
/// that map failures onto exit codes classify them the same way `reportError` does,
/// since an unreachable host surfaces as one of these and not as a wrapped error.
pub fn isNetworkError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.NameServerFailure,
        => true,
        else => false,
    };
}

fn colorMode(environ_map: ?*const std.process.Environ.Map) ColorMode {
    const env = environ_map orelse return .auto;

    if (env.get("ZVM_COLOR")) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "always") or std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true")) return .always;
        if (std.ascii.eqlIgnoreCase(value, "never") or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false")) return .never;
        if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
    }
    if (env.get("NO_COLOR")) |value| {
        if (value.len > 0) return .never;
    }
    if (env.get("CLICOLOR_FORCE")) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (value.len > 0 and !std.mem.eql(u8, value, "0")) return .always;
    }
    if (env.get("CLICOLOR")) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.eql(u8, value, "0")) return .never;
    }
    if (env.get("TERM")) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.eql(u8, value, "dumb")) return .never;
    }
    return .auto;
}

fn colorFor(file: Io.File, io: Io, mode: ColorMode) bool {
    return switch (mode) {
        .never => false,
        .always => {
            // Best effort: enable VT processing on Windows consoles.
            file.enableAnsiEscapeCodes(io) catch {};
            return true;
        },
        .auto => {
            file.enableAnsiEscapeCodes(io) catch return false;
            return true;
        },
    };
}

test "colorMode honors environment overrides" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    try std.testing.expectEqual(ColorMode.auto, colorMode(&env));

    try env.put("NO_COLOR", "1");
    try std.testing.expectEqual(ColorMode.never, colorMode(&env));

    try env.put("ZVM_COLOR", "always");
    try std.testing.expectEqual(ColorMode.always, colorMode(&env));

    try env.put("ZVM_COLOR", "never");
    try std.testing.expectEqual(ColorMode.never, colorMode(&env));
}

test "Reporter writes errors to stderr without raw error names" {
    const allocator = std.testing.allocator;

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    const reporter = Reporter.initWithColor(&out.writer, &err.writer, false, false);
    try reporter.reportError(zvm.errors.CliError.InvalidVersion);

    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "error: The provided Zig version is not valid.") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "InvalidVersion") == null);
}

test "Reporter status rows share a consistent tag width" {
    const allocator = std.testing.allocator;

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    const reporter = Reporter.initWithColor(&out.writer, &err.writer, false, false);
    try reporter.status(.ok, "ok\n", .{});
    try reporter.status(.warn, "warn\n", .{});
    try reporter.status(.fail, "fail\n", .{});
    try reporter.status(.info, "info\n", .{});

    // Warnings and failures belong on stderr; successes and info on stdout.
    try std.testing.expectEqualStrings("[OK]   ok\n[INFO] info\n", out.written());
    try std.testing.expectEqualStrings("[WARN] warn\n[FAIL] fail\n", err.written());
}

test "Reporter colors output only when enabled" {
    const allocator = std.testing.allocator;

    var plain_out: Io.Writer.Allocating = .init(allocator);
    defer plain_out.deinit();
    var plain_err: Io.Writer.Allocating = .init(allocator);
    defer plain_err.deinit();

    const plain = Reporter.initWithColor(&plain_out.writer, &plain_err.writer, false, false);
    try plain.success("done\n", .{});
    try std.testing.expectEqualStrings("done\n", plain_out.written());

    var colored_out: Io.Writer.Allocating = .init(allocator);
    defer colored_out.deinit();
    var colored_err: Io.Writer.Allocating = .init(allocator);
    defer colored_err.deinit();

    const colored = Reporter.initWithColor(&colored_out.writer, &colored_err.writer, true, true);
    try colored.success("done\n", .{});
    try std.testing.expect(std.mem.indexOf(u8, colored_out.written(), "\x1b[32m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored_out.written(), "\x1b[0m") != null);
}
