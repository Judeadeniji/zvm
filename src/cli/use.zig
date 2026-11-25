const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

pub fn command(init_options: zli.InitOptions) !*zli.Command {
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

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const raw_version = ctx.getArg("version") orelse return error.MissingVersion;

    const parsed = zvm.Version.parse(raw_version) catch {
        try ctx.writer.print("error: Invalid Zig version '{s}'.\n", .{raw_version});
        return error.InvalidVersion;
    };
    const canonical = try parsed.toString(ctx.allocator);
    defer ctx.allocator.free(canonical);

    if (!app.paths.isVersionInstalled(ctx.io, ctx.allocator, canonical)) {
        try ctx.writer.print("error: Zig version '{s}' is not installed.\n", .{canonical});
        try ctx.writer.print("hint: Run 'zvm install {s}' first.\n", .{canonical});
        return error.VersionNotInstalled;
    }

    try app.paths.writeDefaultVersion(ctx.io, canonical);
    try ctx.writer.print("Global default Zig version set to {s}.\n", .{canonical});
}
