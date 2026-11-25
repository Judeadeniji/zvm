const zli = @import("zli");
const zvm = @import("zvm");

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
    return cmd;
}

fn handle(ctx: zli.CommandContext) !void {
    const raw_version = ctx.getArg("version") orelse return error.MissingVersion;
    const parsed = zvm.Version.parse(raw_version) catch {
        try ctx.writer.print("error: Invalid Zig version '{s}'.\n", .{raw_version});
        return error.InvalidVersion;
    };

    const canonical = try parsed.toString(ctx.allocator);
    defer ctx.allocator.free(canonical);

    try ctx.writer.print("Installing Zig version {s}...\n", .{canonical});
    try ctx.writer.writeAll("note: Release downloader is not implemented yet (upcoming milestone).\n");
}
