//! `zvm upgrade` (`zvm self-update`) subcommand for upgrading the `zvm` binary in place.

const std = @import("std");
const zli = @import("zli");
const zvm = @import("zvm");
const build_options = @import("build_options");
const AppContext = @import("context.zig").AppContext;
const exit_codes = @import("exit_codes.zig");

const UpgradeProgress = struct {
    spinner: *zli.Spinner,

    fn update(raw_ctx: *anyopaque, downloaded: u64, total: ?u64) void {
        const self: *UpgradeProgress = @ptrCast(@alignCast(raw_ctx));
        const dl_mb = @as(f64, @floatFromInt(downloaded)) / (1024.0 * 1024.0);
        if (total) |t| {
            if (t > 0) {
                const total_mb = @as(f64, @floatFromInt(t)) / (1024.0 * 1024.0);
                const pct = @min(@as(u64, 100), (downloaded * 100) / t);
                // The body is complete at 100%, so the remaining work (the digest, the
                // extract, the swap) belongs to a different message than the download.
                if (pct == 100) {
                    self.spinner.updateMessage("Verifying and installing zvm...", .{}) catch {};
                    return;
                }
                self.spinner.updateMessage("Downloading zvm ({d:.1} / {d:.1} MB, {d}%)...", .{
                    dl_mb,
                    total_mb,
                    pct,
                }) catch {};
                return;
            }
        }
        self.spinner.updateMessage("Downloading zvm ({d:.1} MB)...", .{dl_mb}) catch {};
    }
};

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "upgrade",
        .aliases = &.{"self-update"},
        .description = "Upgrade zvm itself to the latest GitHub release (or --nightly / <tag>)",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "version",
        .description = "Optional release tag to install (e.g. v0.2.0, nightly)",
        .required = false,
    });
    try cmd.addFlag(.{
        .name = "check",
        .shortcut = "c",
        .description = "Check if a newer release is available without installing",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try cmd.addFlag(.{
        .name = "nightly",
        .description = "Upgrade to the rolling nightly development build",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try cmd.addFlag(.{
        .name = "force",
        .shortcut = "f",
        .description = "Reinstall even if already on the target version",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    return cmd;
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const check_only = ctx.flag("check", bool);
    const nightly = ctx.flag("nightly", bool);
    const force = ctx.flag("force", bool);
    const target_tag = ctx.getArg("version");

    const current_ver = try (zvm.Version{
        .tag = .semver,
        .semver = build_options.version,
        .raw = "",
    }).toString(ctx.allocator);
    defer ctx.allocator.free(current_ver);

    if (check_only) {
        var info = zvm.self_updater.checkRelease(ctx.io, ctx.allocator, ctx.environ_map, target_tag, nightly) catch |err| {
            app.exit_code = exit_codes.upgradeFailure(err);
            try reportUpgradeError(app, err);
            return error.Reported;
        };
        defer info.deinit(ctx.allocator);

        if (zvm.self_updater.needsUpgrade(current_ver, info.tag_name)) {
            try app.reporter.info("Update available: {s} -> {s}\n", .{ current_ver, info.tag_name });
            try app.reporter.hint("Run 'zvm upgrade{s}' to install it.\n", .{if (nightly) " --nightly" else ""});
        } else {
            try app.reporter.success("zvm is already up to date ({s}).\n", .{current_ver});
        }
        return;
    }

    const self_exe = try std.process.executablePathAlloc(ctx.io, ctx.allocator);
    defer ctx.allocator.free(self_exe);

    try ctx.spinner.start("Checking for zvm updates...", .{});
    var progress_state = UpgradeProgress{ .spinner = ctx.spinner };

    var res = zvm.self_updater.upgradeSelf(app.paths, ctx.io, ctx.allocator, ctx.environ_map, self_exe, .{
        .target_tag = target_tag,
        .nightly = nightly,
        .force = force,
        .current_version = current_ver,
        .progress = .{
            .ctx = &progress_state,
            .on_progress = UpgradeProgress.update,
        },
    }) catch |err| {
        ctx.spinner.stop();
        app.exit_code = exit_codes.upgradeFailure(err);
        try reportUpgradeError(app, err);
        return error.Reported;
    };
    defer res.deinit(ctx.allocator);

    if (res.already_up_to_date) {
        try ctx.spinner.info("zvm is already up to date ({s}; use --force to reinstall).", .{res.from_version});
    } else {
        const sha_note: []const u8 = if (res.checksum_verified) " (SHA-256 verified)" else "";
        try ctx.spinner.succeed("Upgraded zvm from {s} to {s}{s}.", .{
            res.from_version,
            res.to_tag,
            sha_note,
        });
    }
}

fn reportUpgradeError(app: *AppContext, err: anyerror) !void {
    switch (err) {
        zvm.errors.UpgradeError.ReleaseNotFound => {
            try app.reporter.fail("Target zvm release was not found on GitHub.\n", .{});
        },
        zvm.errors.UpgradeError.AssetNotFound => {
            try app.reporter.fail("No prebuilt zvm archive was found for this platform.\n", .{});
        },
        zvm.errors.DownloadError.ChecksumMismatch => {
            try app.reporter.fail("SHA-256 checksum verification failed for the downloaded zvm archive.\n", .{});
        },
        zvm.errors.UpgradeError.RateLimited => {
            try app.reporter.fail("GitHub is rate-limiting zvm's requests (HTTP 429).\n", .{});
            try app.reporter.hint("Wait a few minutes and run 'zvm upgrade' again.\n", .{});
        },
        zvm.errors.UpgradeError.ChecksumManifestUnavailable => {
            try app.reporter.fail("Downloaded the zvm archive but could not fetch its SHA256SUMS.txt.\n", .{});
            try app.reporter.hint("Nothing was installed; run 'zvm upgrade' again to retry.\n", .{});
        },
        zvm.errors.DownloadError.HttpRequestFailed => {
            try app.reporter.fail("Failed to query GitHub Releases for zvm.\n", .{});
            try app.reporter.hint("Check your network connection and try again.\n", .{});
        },
        else => try app.reporter.reportError(err),
    }
}
