//! `zvm current` subcommand for reporting the active Zig version and its resolution source.

const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;
const flags = @import("flags.zig");

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "current",
        .description = "Show the currently active Zig version for the current directory",
    }, handle);
    try cmd.addFlag(flags.exact);
    return cmd;
}

fn sourceLabel(source: zvm.ResolutionSource) []const u8 {
    return switch (source) {
        .env_var => "ZIG_VERSION environment variable",
        .zig_version_file => ".zig-version file",
        .build_zig_zon => "build.zig.zon minimum_zig_version",
        .global_default => "global default",
    };
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);

    var resolved = zvm.resolveWithOptions(app.paths, ctx.io, ctx.allocator, ctx.environ_map, app.cwd, .{
        .exact = flags.exactOverride(ctx),
    }) catch |err| switch (err) {
        zvm.errors.ResolveError.NoVersionConfigured => {
            try app.reporter.fail("No Zig version is configured.\n", .{});
            try app.reporter.hint("Run 'zvm use <version>' to set a global default, or 'zvm pin <version>' for this project.\n", .{});
            return error.Reported;
        },
        zvm.errors.ResolveError.NoCompatibleVersionInstalled => {
            try app.reporter.fail("No installed Zig version satisfies minimum_zig_version in build.zig.zon.\n", .{});
            try app.reporter.hint("Run 'zvm install <version>' to install a compatible release.\n", .{});
            return error.Reported;
        },
        else => return err,
    };
    defer resolved.deinit(ctx.allocator);

    const installed = app.paths.isVersionInstalled(ctx.io, ctx.allocator, resolved.version);

    try app.reporter.version(resolved.version);
    try ctx.writer.writeAll(" (");
    if (installed) {
        try app.reporter.successText("installed");
    } else {
        try app.reporter.warnText("not installed");
    }
    if (resolved.source_path) |path| {
        try ctx.writer.print(", from {s}: {s})\n", .{ sourceLabel(resolved.source), path });
    } else {
        try ctx.writer.print(", from {s})\n", .{sourceLabel(resolved.source)});
    }
}
