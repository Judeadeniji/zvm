//! `zvm setup` (`zvm shim`) subcommand for installing the `zig` shim and checking `PATH`.

const std = @import("std");
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;
const report = @import("report.zig");

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "setup",
        .aliases = &.{"shim"},
        .description = "Create or verify the zig shim symlink in ~/.zvm/bin/",
    }, handle);
    try cmd.addFlag(.{
        .name = "force",
        .shortcut = "f",
        .description = "Overwrite an existing zig file or symlink in ~/.zvm/bin/",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    return cmd;
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const force = ctx.flag("force", bool);

    const self_exe = try std.process.executablePathAlloc(ctx.io, ctx.allocator);
    defer ctx.allocator.free(self_exe);

    var res = zvm.shim.setupShim(app.paths, ctx.io, ctx.allocator, self_exe, force) catch |err| switch (err) {
        zvm.errors.ShimError.ShimAlreadyExists => {
            const shim_p = try app.paths.zigShimPath(ctx.allocator);
            defer ctx.allocator.free(shim_p);
            try app.reporter.fail("'{s}' already exists and does not point to this zvm binary.\n", .{shim_p});
            try app.reporter.hint("Re-run with '--force' to replace it.\n", .{});
            return error.Reported;
        },
        else => return err,
    };
    defer res.deinit(ctx.allocator);

    switch (res.outcome) {
        .created => try app.reporter.success("Created zig shim: {s} -> {s}\n", .{ res.shim_path, res.target_path }),
        .updated => try app.reporter.success("Updated zig shim: {s} -> {s}\n", .{ res.shim_path, res.target_path }),
        .already_configured => try app.reporter.info("Zig shim is already configured: {s} -> {s}\n", .{ res.shim_path, res.target_path }),
    }

    var path_check = try zvm.shim.checkPathOrder(app.paths, ctx.io, ctx.allocator, ctx.environ_map);
    defer path_check.deinit(ctx.allocator);

    if (!path_check.bin_dir_in_path) {
        try ctx.writer.writeByte('\n');
        try app.reporter.note("'{s}' is not in your PATH.\n", .{app.paths.bin_dir});
        try printPathHint(&app.reporter, app.paths.bin_dir);
    } else if (!path_check.shim_takes_precedence) {
        try ctx.writer.writeByte('\n');
        try app.reporter.warn("Another zig binary in '{s}' shadows '{s}'.\n", .{
            path_check.first_zig_dir orelse "(unknown)",
            app.paths.bin_dir,
        });
        try printPathHint(&app.reporter, app.paths.bin_dir);
    }

    const installed = zvm.Paths.listInstalledVersions(app.paths, ctx.io, ctx.allocator) catch null;
    defer if (installed) |list| zvm.Paths.freeInstalledVersions(ctx.allocator, list);
    if (installed == null or installed.?.len == 0) {
        try ctx.writer.writeByte('\n');
        try app.reporter.hint("Next: Run 'zvm install <version>' (e.g. 'zvm install 0.17.0', or 'zvm list-remote' to browse).\n", .{});
        try app.reporter.muted("Optional: 'zvm completions <shell>' for tab completion, 'zvm config auto-install on' for automatic installs.\n", .{});
    } else if (res.outcome == .created) {
        try ctx.writer.writeByte('\n');
        try app.reporter.hint("Next: Run 'zvm doctor' to verify your setup, or 'zig version' to test the shim.\n", .{});
    }
}

fn printPathHint(reporter: *const report.Reporter, bin_dir: []const u8) !void {
    if (zvm.Paths.is_windows) {
        try reporter.muted("Add '{s}' to the top of your user PATH environment variable, or run:\n  zvm env powershell | Out-String | Invoke-Expression\n", .{bin_dir});
    } else {
        try reporter.muted("Add to your shell profile (~/.bashrc, ~/.zshrc, etc.):\n  eval \"$(zvm env bash)\"   # or: export PATH=\"{s}:$PATH\"\n", .{bin_dir});
    }
}
