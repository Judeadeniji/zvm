//! `zvm install` subcommand for downloading, verifying, and installing Zig releases.

const std = @import("std");
const zli = @import("zli");
const zvm = @import("zvm");
const context = @import("context.zig");
const report = @import("report.zig");
const AppContext = context.AppContext;
const flags = @import("flags.zig");
const zls_cmd = @import("zls.zig");

const SpinnerProgress = struct {
    spinner: *zli.Spinner,
    version: []const u8,

    fn update(raw_ctx: *anyopaque, downloaded: u64, total: ?u64) void {
        const self: *SpinnerProgress = @ptrCast(@alignCast(raw_ctx));
        const dl_mb = @as(f64, @floatFromInt(downloaded)) / (1024.0 * 1024.0);
        if (total) |t| {
            if (t > 0) {
                const total_mb = @as(f64, @floatFromInt(t)) / (1024.0 * 1024.0);
                const pct = @min(@as(u64, 100), (downloaded * 100) / t);
                self.spinner.updateMessage("Downloading Zig {s} ({d:.1} / {d:.1} MB, {d}%)...", .{
                    self.version,
                    dl_mb,
                    total_mb,
                    pct,
                }) catch {};
                return;
            }
        }
        self.spinner.updateMessage("Downloading Zig {s} ({d:.1} MB)...", .{
            self.version,
            dl_mb,
        }) catch {};
    }
};

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "install",
        .description = "Download and install a Zig compiler version (e.g. 0.17.0, master)",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "version",
        .description = "Version to install (defaults to current project version if omitted)",
        .required = false,
    });
    try cmd.addFlag(.{
        .name = "force",
        .shortcut = "f",
        .description = "Re-download and reinstall even if already installed",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try cmd.addFlag(.{
        .name = "no-minisig",
        .description = "Skip Minisign cryptographic signature verification",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try cmd.addFlag(.{
        .name = "minisig-key",
        .description = "Override Minisign public key (or use ZVM_MINISIG_PUBLIC_KEY / ~/.zvm/minisig.pub)",
        .type = .String,
        .default_value = .{ .String = "" },
    });
    try cmd.addFlag(flags.exact);
    try cmd.addFlag(.{
        .name = "with-zls",
        .description = "Also install the compatible ZLS release for this Zig version",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    return cmd;
}

fn resolveProjectInstallVersion(app: *AppContext, ctx: zli.CommandContext) !?[]u8 {
    if (zvm.resolveWithOptions(app.paths, ctx.io, ctx.allocator, ctx.environ_map, app.cwd, .{
        .exact = flags.exactOverride(ctx),
    })) |resolved| {
        var r = resolved;
        defer r.deinit(ctx.allocator);
        return try ctx.allocator.dupe(u8, r.version);
    } else |err| switch (err) {
        zvm.errors.ResolveError.NoCompatibleVersionInstalled => {
            // Only a build.zig.zon minimum is a deterministic install target. A pinned
            // .zig-version range must be satisfied explicitly, never replaced by the zon.
            return try zvm.resolver.findProjectMinimumVersion(ctx.io, ctx.allocator, app.cwd);
        },
        zvm.errors.ResolveError.UnmatchedZigVersionConstraint => {
            try app.reporter.fail("No installed Zig version satisfies the constraint in .zig-version.\n", .{});
            try app.reporter.hint("Pass a version explicitly (e.g. 'zvm install 0.17.0') or change the pin with 'zvm pin <version>'.\n", .{});
            return error.Reported;
        },
        zvm.errors.ResolveError.InvalidZigVersionConstraint => {
            try app.reporter.fail("The .zig-version file does not contain a valid Zig version or constraint.\n", .{});
            try app.reporter.hint("Use a version such as '0.17.0' or 'master', or a range like '^0.17.0'.\n", .{});
            return error.Reported;
        },
        zvm.errors.ResolveError.NoVersionConfigured => return null,
        else => return err,
    }
}

/// Maps a download failure onto the status the process exits with, so a script can
/// distinguish an unavailable release from a network fault from a failed verification
/// without parsing the message. Unrecognized errors keep the generic status.
fn installExitCode(err: anyerror) u8 {
    const codes = context.ExitCode;
    // A dead host arrives here unwrapped from the release-index fetch, so it is
    // recognized by the same predicate that turns it into a message.
    if (report.isNetworkError(err)) return codes.network;
    return switch (err) {
        zvm.errors.DownloadError.VersionNotFound, zvm.errors.DownloadError.TargetNotAvailable => codes.unavailable,
        zvm.errors.DownloadError.HttpRequestFailed => codes.network,
        zvm.errors.DownloadError.ChecksumMismatch,
        zvm.errors.DownloadError.InvalidExpectedChecksum,
        zvm.errors.MinisigError.SignatureVerificationFailed,
        zvm.errors.MinisigError.GlobalSignatureVerificationFailed,
        zvm.errors.MinisigError.KeyIdMismatch,
        => codes.integrity,
        else => 0,
    };
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    var resolved_owned: ?[]u8 = null;
    defer if (resolved_owned) |v| ctx.allocator.free(v);

    const raw_version = ctx.getArg("version") orelse blk: {
        resolved_owned = (try resolveProjectInstallVersion(app, ctx)) orelse {
            try app.reporter.fail("No version specified and no project version found.\n", .{});
            try app.reporter.hint("Pass a version (e.g. 'zvm install 0.17.0') or run inside a project with .zig-version or build.zig.zon.\n", .{});
            return error.Reported;
        };
        break :blk resolved_owned.?;
    };
    const force = ctx.flag("force", bool);
    const with_zls = ctx.flag("with-zls", bool);
    const no_minisig = ctx.flag("no-minisig", bool);
    const minisig_key_flag = ctx.flag("minisig-key", []const u8);
    const minisig_override: ?[]const u8 = if (minisig_key_flag.len > 0) minisig_key_flag else null;

    const parsed = zvm.Version.parse(raw_version) catch {
        try app.reporter.fail("Invalid Zig version '{s}'.\n", .{raw_version});
        try app.reporter.hint("Use a version such as '0.17.0' or 'master'.\n", .{});
        return error.Reported;
    };
    const canonical = try parsed.toString(ctx.allocator);
    defer ctx.allocator.free(canonical);

    try ctx.spinner.start("Installing Zig {s}...", .{canonical});

    var progress_state = SpinnerProgress{
        .spinner = ctx.spinner,
        .version = canonical,
    };

    var res = zvm.downloader.installVersion(
        app.paths,
        ctx.io,
        ctx.allocator,
        ctx.environ_map,
        canonical,
        .{
            .force = force,
            .verify_minisig = !no_minisig,
            .minisig_public_key = minisig_override,
            .progress = .{
                .ctx = &progress_state,
                .on_progress = SpinnerProgress.update,
            },
        },
    ) catch |err| {
        ctx.spinner.stop();
        app.exit_code = installExitCode(err);
        switch (err) {
            zvm.errors.DownloadError.VersionNotFound => {
                try app.reporter.fail("Zig version '{s}' was not found in the release index.\n", .{canonical});
                try app.reporter.hint("Run 'zvm list-remote' to see available versions.\n", .{});
            },
            zvm.errors.DownloadError.TargetNotAvailable => {
                try app.reporter.fail("No binary release for Zig '{s}' is available on this platform.\n", .{canonical});
                try app.reporter.hint("Run 'zvm list-remote --all' to see every published release.\n", .{});
            },
            zvm.errors.DownloadError.ChecksumMismatch, zvm.errors.DownloadError.InvalidExpectedChecksum => {
                try app.reporter.fail("SHA-256 checksum verification failed for Zig '{s}'.\n", .{canonical});
                try app.reporter.hint("Try again, or clear the cache with 'zvm clean' first.\n", .{});
            },
            zvm.errors.MinisigError.SignatureVerificationFailed, zvm.errors.MinisigError.GlobalSignatureVerificationFailed, zvm.errors.MinisigError.KeyIdMismatch => {
                try app.reporter.fail("Minisig signature verification failed for Zig '{s}'.\n", .{canonical});
                try app.reporter.hint("The download may be corrupted or tampered with. Try again.\n", .{});
            },
            zvm.errors.DownloadError.HttpRequestFailed => {
                try app.reporter.fail("Failed to download Zig '{s}' from ziglang.org.\n", .{canonical});
                try app.reporter.hint("Check your network connection and try again.\n", .{});
            },
            else => try app.reporter.reportError(err),
        }
        return error.Reported;
    };
    defer res.deinit(ctx.allocator);

    const sig_note: []const u8 = if (res.minisig_verified) " (SHA-256 + Minisig verified)" else "";

    if (res.already_installed) {
        if (!std.mem.eql(u8, res.version, res.resolved_version)) {
            try ctx.spinner.info("Zig {s} ({s}) is already up to date at {s} (use --force to reinstall).", .{
                res.version,
                res.resolved_version,
                res.install_dir,
            });
        } else {
            try ctx.spinner.info("Zig {s} is already installed at {s} (use --force to reinstall).", .{
                res.version,
                res.install_dir,
            });
        }
    } else if (!std.mem.eql(u8, res.version, res.resolved_version)) {
        try ctx.spinner.succeed("Installed Zig {s} ({s}) to {s}{s}.", .{
            res.version,
            res.resolved_version,
            res.install_dir,
            sig_note,
        });
    } else {
        try ctx.spinner.succeed("Installed Zig {s} to {s}{s}.", .{
            res.version,
            res.install_dir,
            sig_note,
        });
    }

    if (!res.already_installed) {
        const default_ver = app.paths.readDefaultVersion(ctx.io, ctx.allocator) catch null;
        defer if (default_ver) |v| ctx.allocator.free(v);
        if (default_ver == null) {
            try app.reporter.hint("Next: Run 'zvm use {s}' to set it as your global default (or 'zvm pin {s}' for a project).\n", .{ res.version, res.version });
        }

        var shim_status = zvm.shim.inspectShim(app.paths, ctx.io, ctx.allocator, null) catch null;
        defer if (shim_status) |*s| s.deinit(ctx.allocator);
        if (shim_status != null and shim_status.? == .missing) {
            try app.reporter.muted("Tip: Run 'zvm setup' to create the 'zig' shim so 'zig' routes through zvm.\n", .{});
        }
    }

    if (with_zls) {
        try zls_cmd.installZlsWithSpinner(app, ctx, canonical, force);
    }
}

test "installExitCode distinguishes unavailable, network, and integrity failures" {
    try std.testing.expectEqual(context.ExitCode.unavailable, installExitCode(zvm.errors.DownloadError.VersionNotFound));
    try std.testing.expectEqual(context.ExitCode.unavailable, installExitCode(zvm.errors.DownloadError.TargetNotAvailable));
    try std.testing.expectEqual(context.ExitCode.network, installExitCode(zvm.errors.DownloadError.HttpRequestFailed));
    try std.testing.expectEqual(context.ExitCode.integrity, installExitCode(zvm.errors.DownloadError.ChecksumMismatch));
    try std.testing.expectEqual(context.ExitCode.integrity, installExitCode(zvm.errors.MinisigError.KeyIdMismatch));
    try std.testing.expectEqual(context.ExitCode.network, installExitCode(error.ConnectionRefused));
    // Anything else keeps the generic status rather than inventing one.
    try std.testing.expectEqual(0, installExitCode(error.OutOfMemory));
}
