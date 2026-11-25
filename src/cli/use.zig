//! `zvm use` subcommand for switching the global default Zig version.

const std = @import("std");
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

const UseError = zvm.errors.CliError ||
    std.mem.Allocator.Error ||
    std.Io.Writer.Error ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.WriteFileError;

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "use",
        .description = "Switch the global default Zig version",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "version",
        .description = "Installed version to set as global default",
        .required = true,
    });
    return cmd;
}

fn handle(ctx: zli.CommandContext) UseError!void {
    const app = ctx.getContextData(AppContext);
    const raw_version = ctx.getArg("version") orelse return zvm.errors.CliError.MissingVersion;

    const parsed = zvm.Version.parse(raw_version) catch {
        try ctx.writer.print("error: Invalid Zig version '{s}'.\n", .{raw_version});
        return zvm.errors.CliError.InvalidVersion;
    };
    const canonical = try parsed.toString(ctx.allocator);
    defer ctx.allocator.free(canonical);

    if (!app.paths.isVersionInstalled(ctx.io, ctx.allocator, canonical)) {
        try ctx.writer.print("error: Zig version '{s}' is not installed.\n", .{canonical});
        try ctx.writer.print("hint: Run 'zvm install {s}' first.\n", .{canonical});
        return zvm.errors.CliError.VersionNotInstalled;
    }

    try app.paths.writeDefaultVersion(ctx.io, canonical);
    try ctx.writer.print("Global default Zig version set to {s}.\n", .{canonical});
}
