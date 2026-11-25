const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

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
    return cmd;
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const raw_version = ctx.getArg("version") orelse return error.MissingVersion;
    const force = ctx.flag("force", bool);

    const parsed = zvm.Version.parse(raw_version) catch {
        try ctx.writer.print("error: Invalid Zig version '{s}'.\n", .{raw_version});
        return error.InvalidVersion;
    };
    const canonical = try parsed.toString(ctx.allocator);
    defer ctx.allocator.free(canonical);

    try ctx.spinner.start("Installing Zig {s}...", .{canonical});

    var res = zvm.downloader.installVersion(
        app.paths,
        ctx.io,
        ctx.allocator,
        ctx.environ_map,
        canonical,
        force,
    ) catch |err| {
        switch (err) {
            error.VersionNotFound => try ctx.spinner.fail("Zig version '{s}' was not found in release index.", .{canonical}),
            error.TargetNotAvailable => try ctx.spinner.fail("No binary release for '{s}' on this platform.", .{canonical}),
            error.ChecksumMismatch => try ctx.spinner.fail("SHA-256 checksum verification failed for '{s}'.", .{canonical}),
            error.HttpRequestFailed => try ctx.spinner.fail("Failed to download Zig '{s}' from ziglang.org.", .{canonical}),
            else => try ctx.spinner.fail("Failed to install Zig '{s}': {s}", .{ canonical, @errorName(err) }),
        }
        return err;
    };
    defer res.deinit(ctx.allocator);

    if (res.already_installed) {
        try ctx.spinner.info("Zig {s} is already installed at {s} (use --force to reinstall).", .{
            res.version,
            res.install_dir,
        });
    } else if (!@import("std").mem.eql(u8, res.version, res.resolved_version)) {
        try ctx.spinner.succeed("Installed Zig {s} ({s}) to {s}.", .{
            res.version,
            res.resolved_version,
            res.install_dir,
        });
    } else {
        try ctx.spinner.succeed("Installed Zig {s} to {s}.", .{
            res.version,
            res.install_dir,
        });
    }
}
