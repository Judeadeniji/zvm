//! `zvm zls` subcommand group for managing ZLS (Zig Language Server) versions paired to Zig.

const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;
const ExitCode = @import("context.zig").ExitCode;
const flags = @import("flags.zig");
const report = @import("report.zig");
const exit_codes = @import("exit_codes.zig");

const ZlsSpinnerProgress = struct {
    spinner: *zli.Spinner,
    zig_version: []const u8,

    fn update(raw_ctx: *anyopaque, downloaded: u64, total: ?u64) void {
        const self: *ZlsSpinnerProgress = @ptrCast(@alignCast(raw_ctx));
        const dl_mb = @as(f64, @floatFromInt(downloaded)) / (1024.0 * 1024.0);
        if (total) |t| {
            if (t > 0) {
                const total_mb = @as(f64, @floatFromInt(t)) / (1024.0 * 1024.0);
                const pct = @min(@as(u64, 100), (downloaded * 100) / t);
                self.spinner.updateMessage("Downloading ZLS for Zig {s} ({d:.1} / {d:.1} MB, {d}%)...", .{
                    self.zig_version,
                    dl_mb,
                    total_mb,
                    pct,
                }) catch {};
                return;
            }
        }
        self.spinner.updateMessage("Downloading ZLS for Zig {s} ({d:.1} MB)...", .{
            self.zig_version,
            dl_mb,
        }) catch {};
    }
};

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "zls",
        .description = "Manage ZLS (Zig Language Server) versions paired to Zig",
    }, showHelp);
    errdefer cmd.deinit();

    const install_sub = try zli.Command.init(init_options, .{
        .name = "install",
        .description = "Install ZLS paired to the active or specified Zig version",
    }, handleInstall);
    errdefer install_sub.deinit();
    try install_sub.addPositionalArg(.{
        .name = "version",
        .description = "Zig version to pair ZLS with (defaults to active version)",
        .required = false,
    });
    try install_sub.addFlag(.{
        .name = "force",
        .shortcut = "f",
        .description = "Re-download and reinstall even if already installed",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try install_sub.addFlag(flags.exact);
    try cmd.addCommand(install_sub);

    const update_sub = try zli.Command.init(init_options, .{
        .name = "update",
        .description = "Update ZLS for the active Zig version to the latest compatible release",
    }, handleUpdate);
    errdefer update_sub.deinit();
    try update_sub.addFlag(flags.exact);
    try cmd.addCommand(update_sub);

    const list_sub = try zli.Command.init(init_options, .{
        .name = "list",
        .description = "List installed ZLS versions and their paired Zig versions",
    }, handleList);
    errdefer list_sub.deinit();
    try list_sub.addFlag(flags.exact);
    try cmd.addCommand(list_sub);

    const use_sub = try zli.Command.init(init_options, .{
        .name = "use",
        .description = "Set the global fallback ZLS version (by paired Zig version)",
    }, handleUse);
    errdefer use_sub.deinit();
    try use_sub.addPositionalArg(.{
        .name = "version",
        .description = "Paired Zig version whose ZLS should be the global default",
        .required = true,
    });
    try cmd.addCommand(use_sub);

    const which_sub = try zli.Command.init(init_options, .{
        .name = "which",
        .description = "Print path to ZLS for the active or specified Zig version",
    }, handleWhich);
    errdefer which_sub.deinit();
    try which_sub.addPositionalArg(.{
        .name = "version",
        .description = "Paired Zig version (defaults to active version)",
        .required = false,
    });
    try which_sub.addFlag(flags.exact);
    try cmd.addCommand(which_sub);

    const uninstall_sub = try zli.Command.init(init_options, .{
        .name = "uninstall",
        .description = "Remove an installed ZLS version (by paired Zig version)",
    }, handleUninstall);
    errdefer uninstall_sub.deinit();
    try uninstall_sub.addPositionalArg(.{
        .name = "version",
        .description = "Paired Zig version to remove ZLS for",
        .required = true,
    });
    try cmd.addCommand(uninstall_sub);

    return cmd;
}

fn showHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}

fn resolveTargetZigVersion(app: *AppContext, ctx: zli.CommandContext, raw_arg: ?[]const u8) ![]u8 {
    if (raw_arg) |raw| {
        const parsed = zvm.Version.parse(raw) catch {
            try app.reporter.fail("Invalid Zig version '{s}'.\n", .{raw});
            try app.reporter.hint("Use a version such as '0.17.0' or 'master'.\n", .{});
            return error.Reported;
        };
        return try parsed.toString(ctx.allocator);
    }

    var resolved = zvm.resolveWithOptions(app.paths, ctx.io, ctx.allocator, ctx.environ_map, app.cwd, .{
        .exact = flags.exactOverride(ctx),
    }) catch |err| switch (err) {
        zvm.errors.ResolveError.NoVersionConfigured => {
            app.exit_code = ExitCode.unavailable;
            try app.reporter.fail("No Zig version is configured.\n", .{});
            try app.reporter.hint("Pass a Zig version (e.g. 'zvm zls install 0.14.0') or run 'zvm use <version>'.\n", .{});
            return error.Reported;
        },
        zvm.errors.ResolveError.NoCompatibleVersionInstalled => {
            if (try zvm.resolver.findProjectMinimumVersion(ctx.io, ctx.allocator, app.cwd)) |min_ver| {
                return min_ver;
            }
            app.exit_code = ExitCode.unavailable;
            try app.reporter.fail("No installed Zig version satisfies the project's constraint.\n", .{});
            return error.Reported;
        },
        zvm.errors.ResolveError.UnmatchedZigVersionConstraint => {
            app.exit_code = ExitCode.unavailable;
            try app.reporter.fail("No installed Zig version satisfies the constraint in .zig-version.\n", .{});
            try app.reporter.hint("Pass a Zig version explicitly (e.g. 'zvm zls install 0.17.0').\n", .{});
            return error.Reported;
        },
        zvm.errors.ResolveError.InvalidZigVersionConstraint => {
            try app.reporter.fail("The .zig-version file does not contain a valid Zig version or constraint.\n", .{});
            return error.Reported;
        },
        else => return err,
    };
    defer resolved.deinit(ctx.allocator);
    return try ctx.allocator.dupe(u8, resolved.version);
}

/// Downloads and installs ZLS paired to `zig_version` with spinner feedback.
pub fn installZlsWithSpinner(
    app: *AppContext,
    ctx: zli.CommandContext,
    zig_version: []const u8,
    force: bool,
) !void {
    try ctx.spinner.start("Installing ZLS for Zig {s}...", .{zig_version});

    var progress_state = ZlsSpinnerProgress{
        .spinner = ctx.spinner,
        .zig_version = zig_version,
    };

    var res = zvm.zls_downloader.installZls(
        app.paths,
        ctx.io,
        ctx.allocator,
        ctx.environ_map,
        zig_version,
        .{
            .force = force,
            .progress = .{
                .ctx = &progress_state,
                .on_progress = ZlsSpinnerProgress.update,
            },
        },
    ) catch |err| {
        ctx.spinner.stop();
        app.exit_code = exit_codes.zlsFailure(err);
        switch (err) {
            zvm.errors.ZlsError.ZlsVersionNotFound => {
                try app.reporter.fail("No compatible ZLS release was found for Zig '{s}'.\n", .{zig_version});
                try app.reporter.hint("Check https://releases.zigtools.org or install a matching Zig release.\n", .{});
            },
            zvm.errors.DownloadError.TargetNotAvailable => {
                try app.reporter.fail("No ZLS binary release for Zig '{s}' is available on this platform.\n", .{zig_version});
            },
            zvm.errors.DownloadError.HttpRequestFailed => {
                try app.reporter.fail("Failed to fetch ZLS release metadata or archive.\n", .{});
                try app.reporter.hint("Check your network connection and try again.\n", .{});
            },
            else => try app.reporter.reportError(err),
        }
        return error.Reported;
    };
    defer res.deinit(ctx.allocator);

    if (res.already_installed) {
        try ctx.spinner.info("ZLS {s} (for Zig {s}) is already installed at {s} (use --force to reinstall).", .{
            res.zls_version,
            res.zig_version,
            res.install_dir,
        });
    } else {
        try ctx.spinner.succeed("Installed ZLS {s} (for Zig {s}) to {s}.", .{
            res.zls_version,
            res.zig_version,
            res.install_dir,
        });
    }
}

fn handleInstall(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const force = ctx.flag("force", bool);
    const zig_ver = try resolveTargetZigVersion(app, ctx, ctx.getArg("version"));
    defer ctx.allocator.free(zig_ver);

    try installZlsWithSpinner(app, ctx, zig_ver, force);

    var zls_shim = zvm.shim.inspectShimFor(app.paths, ctx.io, ctx.allocator, .zls, null) catch null;
    defer if (zls_shim) |*s| s.deinit(ctx.allocator);
    if (zls_shim != null and zls_shim.? == .missing) {
        try app.reporter.muted("Tip: Run 'zvm setup' to create the 'zls' shim in PATH.\n", .{});
    }
}

fn handleUpdate(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const zig_ver = try resolveTargetZigVersion(app, ctx, null);
    defer ctx.allocator.free(zig_ver);

    try installZlsWithSpinner(app, ctx, zig_ver, true);
}

fn handleList(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const versions = try app.paths.listInstalledZlsVersions(ctx.io, ctx.allocator);
    defer zvm.Paths.freeInstalledVersions(ctx.allocator, versions);

    if (versions.len == 0) {
        try app.reporter.info("No ZLS versions installed yet.\n", .{});
        try app.reporter.hint("Run 'zvm zls install' to install ZLS for your active Zig version.\n", .{});
        return;
    }

    var active_ver: ?[]u8 = null;
    defer if (active_ver) |a| ctx.allocator.free(a);

    if (zvm.resolveWithOptions(app.paths, ctx.io, ctx.allocator, ctx.environ_map, app.cwd, .{
        .exact = flags.exactOverride(ctx),
    })) |r| {
        var resolved = r;
        defer resolved.deinit(ctx.allocator);
        active_ver = try ctx.allocator.dupe(u8, resolved.version);
    } else |_| {
        active_ver = app.paths.readZlsDefaultVersion(ctx.io, ctx.allocator) catch null;
    }

    std.mem.sort([]u8, versions, {}, zvm.version.lessThanText);

    for (versions) |v| {
        const is_active = if (active_ver) |a| std.mem.eql(u8, a, v) else false;
        const meta = app.paths.readZlsVersionMeta(ctx.io, ctx.allocator, v) catch null;
        defer if (meta) |m| ctx.allocator.free(m);

        const prefix: []const u8 = if (is_active) "* " else "  ";
        if (meta) |m| {
            if (is_active) {
                try ctx.writer.print("{s}zig {s} -> zls {s} (active)\n", .{ prefix, v, m });
            } else {
                try ctx.writer.print("{s}zig {s} -> zls {s}\n", .{ prefix, v, m });
            }
        } else {
            try ctx.writer.print("{s}zig {s}\n", .{ prefix, v });
        }
    }
}

fn handleUse(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const raw_version = ctx.getArg("version") orelse return zvm.errors.CliError.MissingVersion;

    const parsed = zvm.Version.parse(raw_version) catch {
        try app.reporter.fail("Invalid Zig version '{s}'.\n", .{raw_version});
        return error.Reported;
    };
    const canonical = try parsed.toString(ctx.allocator);
    defer ctx.allocator.free(canonical);

    if (!app.paths.isZlsInstalled(ctx.io, canonical)) {
        app.exit_code = ExitCode.unavailable;
        try app.reporter.fail("ZLS for Zig '{s}' is not installed.\n", .{canonical});
        try app.reporter.hint("Run 'zvm zls install {s}' first.\n", .{canonical});
        return error.Reported;
    }

    try app.paths.writeZlsDefaultVersion(ctx.io, canonical);
    try app.reporter.success("Global fallback ZLS set to Zig {s}.\n", .{canonical});
}

fn handleWhich(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const zig_ver = try resolveTargetZigVersion(app, ctx, ctx.getArg("version"));
    defer ctx.allocator.free(zig_ver);

    if (!app.paths.isZlsInstalled(ctx.io, zig_ver)) {
        app.exit_code = ExitCode.unavailable;
        try app.reporter.fail("ZLS for Zig '{s}' is not installed.\n", .{zig_ver});
        try app.reporter.hint("Run 'zvm zls install {s}' to install it.\n", .{zig_ver});
        return error.Reported;
    }

    const bin_path = try app.paths.zlsVersionBin(ctx.allocator, zig_ver);
    defer ctx.allocator.free(bin_path);
    try ctx.writer.print("{s}\n", .{bin_path});
}

fn handleUninstall(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const raw_version = ctx.getArg("version") orelse return zvm.errors.CliError.MissingVersion;

    const parsed = zvm.Version.parse(raw_version) catch {
        try app.reporter.fail("Invalid Zig version '{s}'.\n", .{raw_version});
        return error.Reported;
    };
    const canonical = try parsed.toString(ctx.allocator);
    defer ctx.allocator.free(canonical);

    const v_dir = try app.paths.zlsVersionDir(ctx.allocator, canonical);
    defer ctx.allocator.free(v_dir);

    if (!app.paths.isZlsInstalled(ctx.io, canonical)) {
        app.exit_code = ExitCode.unavailable;
        try app.reporter.fail("ZLS for Zig '{s}' is not installed.\n", .{canonical});
        return error.Reported;
    }

    try Io.Dir.cwd().deleteTree(ctx.io, v_dir);

    // Do not leave the global ZLS fallback pointing at a version that no longer exists.
    const zls_default = try app.paths.readZlsDefaultVersion(ctx.io, ctx.allocator);
    defer if (zls_default) |d| ctx.allocator.free(d);
    if (zls_default != null and std.mem.eql(u8, zls_default.?, canonical)) {
        try app.paths.clearZlsDefaultVersion(ctx.io);
    }

    try app.reporter.success("Uninstalled ZLS for Zig {s}.\n", .{canonical});
}
