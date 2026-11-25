const zli = @import("zli");

pub fn command(init_options: zli.InitOptions) !*zli.Command {
    return zli.Command.init(init_options, .{
        .name = "list-remote",
        .description = "List available releases from ziglang.org",
    }, handle);
}

fn handle(ctx: zli.CommandContext) !void {
    try ctx.writer.writeAll("Available upstream Zig releases:\n");
    try ctx.writer.writeAll("note: Remote release index fetcher is not implemented yet (upcoming milestone).\n");
}
