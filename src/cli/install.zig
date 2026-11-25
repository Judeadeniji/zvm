//! `zvm install` subcommand for downloading, verifying, and installing Zig releases.

const std = @import("std");
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

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

pub fn command(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "install",
        .description = "Download and install a Zig compiler version (e.g. 0.17.0, master)",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "version",
        .description = "Version to install (e.g. '0.17.0', 'master')",
        .required = true,
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
    return cmd;
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const raw_version = ctx.getArg("version") orelse return error.MissingVersion;
    const force = ctx.flag("force", bool);
    const no_minisig = ctx.flag("no-minisig", bool);
    const minisig_key_flag = ctx.flag("minisig-key", []const u8);
    const minisig_override: ?[]const u8 = if (minisig_key_flag.len > 0) minisig_key_flag else null;

    const parsed = zvm.Version.parse(raw_version) catch {
        try ctx.writer.print("error: Invalid Zig version '{s}'.\n", .{raw_version});
        return error.InvalidVersion;
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
        switch (err) {
            error.VersionNotFound => try ctx.spinner.fail("Zig version '{s}' was not found in release index.", .{canonical}),
            error.TargetNotAvailable => try ctx.spinner.fail("No binary release for '{s}' on this platform.", .{canonical}),
            error.ChecksumMismatch => try ctx.spinner.fail("SHA-256 checksum verification failed for '{s}'.", .{canonical}),
            error.SignatureVerificationFailed, error.GlobalSignatureVerificationFailed, error.KeyIdMismatch => try ctx.spinner.fail("Minisig signature verification failed for '{s}'.", .{canonical}),
            error.HttpRequestFailed => try ctx.spinner.fail("Failed to download Zig '{s}' from ziglang.org.", .{canonical}),
            else => try ctx.spinner.fail("Failed to install Zig '{s}': {s}", .{ canonical, @errorName(err) }),
        }
        return err;
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
}
