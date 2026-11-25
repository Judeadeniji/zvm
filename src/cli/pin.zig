const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

pub fn command(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "pin",
        .description = "Pin the Zig version for the current project (.zig-version)",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "version",
        .description = "Version to pin in .zig-version",
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

    const file_path = try std.fs.path.join(ctx.allocator, &.{ app.cwd, ".zig-version" });
    defer ctx.allocator.free(file_path);

    const payload = try ctx.allocator.print("{s}\n", .{canonical});
    defer ctx.allocator.free(payload);

    try Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = file_path,
        .data = payload,
    });

    try ctx.writer.print("Pinned {s} to {s}.\n", .{ file_path, canonical });
    if (!app.paths.isVersionInstalled(ctx.io, ctx.allocator, canonical)) {
        try ctx.writer.print("note: Zig version '{s}' is not installed yet. Run 'zvm install {s}' to install it.\n", .{ canonical, canonical });
    }
}
