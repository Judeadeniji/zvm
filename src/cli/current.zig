//! `zvm current` subcommand for reporting the active Zig version and its resolution source.

const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    return zli.Command.init(init_options, .{
        .name = "current",
        .description = "Show the currently active Zig version for the current directory",
    }, handle);
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

    var resolved = zvm.resolve(app.paths, ctx.io, ctx.allocator, ctx.environ_map, app.cwd) catch |err| switch (err) {
        zvm.errors.ResolveError.NoVersionConfigured => {
            try ctx.writer.writeAll("No Zig version configured.\n");
            try ctx.writer.writeAll("hint: Run 'zvm use <version>' or 'zvm pin <version>'.\n");
            return;
        },
        zvm.errors.ResolveError.NoCompatibleVersionInstalled => {
            try ctx.writer.writeAll("error: No installed Zig version satisfies minimum_zig_version in build.zig.zon.\n");
            return zvm.errors.ResolveError.NoCompatibleVersionInstalled;
        },
        else => return err,
    };
    defer resolved.deinit(ctx.allocator);

    const installed = app.paths.isVersionInstalled(ctx.io, ctx.allocator, resolved.version);
    const status = if (installed) "installed" else "not installed";

    if (resolved.source_path) |path| {
        try ctx.writer.print("{s} ({s}, from {s}: {s})\n", .{
            resolved.version,
            status,
            sourceLabel(resolved.source),
            path,
        });
    } else {
        try ctx.writer.print("{s} ({s}, from {s})\n", .{
            resolved.version,
            status,
            sourceLabel(resolved.source),
        });
    }
}
