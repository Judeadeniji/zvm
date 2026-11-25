const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

pub fn command(init_options: zli.InitOptions) !*zli.Command {
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

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const raw_version = ctx.getArg("version") orelse return error.MissingVersion;

    const parsed = zvm.Version.parse(raw_version) catch {
        try ctx.writer.print("error: Invalid Zig version '{s}'.\n", .{raw_version});
        return error.InvalidVersion;
    };
    const canonical = try parsed.toString(ctx.allocator);
    defer ctx.allocator.free(canonical);

    const v_dir = try app.paths.versionDir(ctx.allocator, canonical);
    defer ctx.allocator.free(v_dir);

    const cwd = Io.Dir.cwd();
    cwd.access(ctx.io, v_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.writer.print("error: Zig version '{s}' is not installed.\n", .{canonical});
            return error.VersionNotInstalled;
        },
        else => return err,
    };

    try cwd.deleteTree(ctx.io, v_dir);
    try ctx.writer.print("Uninstalled Zig {s}.\n", .{canonical});
}
