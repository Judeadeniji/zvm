//! `zvm uninstall` subcommand for deleting an installed Zig version directory.

const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;
const report = @import("report.zig");

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "uninstall",
        .description = "Remove an installed Zig version",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "version",
        .description = "Installed version to remove",
        .required = true,
    });
    return cmd;
}

const UninstallError = zvm.errors.CliError ||
    std.mem.Allocator.Error ||
    std.Io.Writer.Error ||
    Io.Dir.AccessError ||
    Io.Dir.DeleteTreeError ||
    Io.Dir.DeleteFileError ||
    Io.Dir.ReadFileError ||
    report.Reported;

fn handle(ctx: zli.CommandContext) UninstallError!void {
    const app = ctx.getContextData(AppContext);
    const raw_version = ctx.getArg("version") orelse return zvm.errors.CliError.MissingVersion;

    const parsed = zvm.Version.parse(raw_version) catch {
        try app.reporter.fail("Invalid Zig version '{s}'.\n", .{raw_version});
        try app.reporter.hint("Use a version such as '0.17.0' or 'master'.\n", .{});
        return error.Reported;
    };
    const canonical = try parsed.toString(ctx.allocator);
    defer ctx.allocator.free(canonical);

    const v_dir = try app.paths.versionDir(ctx.allocator, canonical);
    defer ctx.allocator.free(v_dir);

    const cwd = Io.Dir.cwd();
    cwd.access(ctx.io, v_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try app.reporter.fail("Zig version '{s}' is not installed.\n", .{canonical});
            try app.reporter.hint("Run 'zvm list' to see installed versions.\n", .{});
            return error.Reported;
        },
        else => return err,
    };

    try cwd.deleteTree(ctx.io, v_dir);

    // Do not leave the global default (or ZLS fallback) pointing at a version that no longer exists.
    const default_ver = try app.paths.readDefaultVersion(ctx.io, ctx.allocator);
    defer if (default_ver) |d| ctx.allocator.free(d);
    if (default_ver != null and std.mem.eql(u8, default_ver.?, canonical)) {
        try app.paths.clearDefaultVersion(ctx.io);
    }

    const zls_default = try app.paths.readZlsDefaultVersion(ctx.io, ctx.allocator);
    defer if (zls_default) |d| ctx.allocator.free(d);
    if (zls_default != null and std.mem.eql(u8, zls_default.?, canonical)) {
        try app.paths.clearZlsDefaultVersion(ctx.io);
    }

    try app.reporter.success("Uninstalled Zig {s}.\n", .{canonical});

    if (app.paths.isZlsInstalled(ctx.io, canonical)) {
        try app.reporter.muted("ZLS for Zig {s} is still installed; run 'zvm zls uninstall {s}' to remove it.\n", .{ canonical, canonical });
    }
}
