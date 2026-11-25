//! `zvm list-remote` subcommand for listing upstream releases from ziglang.org.

const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "list-remote",
        .description = "List available releases from ziglang.org",
    }, handle);
    try cmd.addFlag(.{
        .name = "all",
        .shortcut = "a",
        .description = "Include releases without binaries for this platform",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    return cmd;
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const show_all = ctx.flag("all", bool);

    try ctx.spinner.start("Fetching release index from ziglang.org...", .{});

    const json_bytes = zvm.downloader.fetchIndexJson(ctx.io, ctx.allocator, ctx.environ_map) catch |err| {
        ctx.spinner.stop();
        try app.reporter.reportError(err);
        return error.Reported;
    };
    defer ctx.allocator.free(json_bytes);

    const tkey = try zvm.downloader.hostTargetKey();
    const releases = try zvm.downloader.parseReleases(ctx.allocator, json_bytes, tkey);
    defer zvm.downloader.freeReleases(ctx.allocator, releases);

    ctx.spinner.stop();

    try app.reporter.heading("Available Zig releases ({s}):\n", .{tkey});
    for (releases) |rel| {
        if (!show_all and !rel.has_host_target) continue;

        const installed = app.paths.isVersionInstalled(ctx.io, ctx.allocator, rel.name);
        if (installed) {
            try app.reporter.active("* ");
        } else {
            try ctx.writer.writeAll("  ");
        }
        try app.reporter.version(rel.name);
        if (rel.name.len < 10) {
            try ctx.writer.splatByteAll(' ', 10 - rel.name.len);
        }

        if (rel.resolved_version) |rv| {
            try ctx.writer.print(" ({s}, {s})", .{ rv, rel.date });
        } else {
            try ctx.writer.print(" ({s})", .{rel.date});
        }
        if (!rel.has_host_target) {
            try app.reporter.dim(" [unavailable for target]");
        }
        try ctx.writer.writeByte('\n');
    }
}
