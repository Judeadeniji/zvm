const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

pub fn command(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "which",
        .description = "Display the binary path of the active or specified Zig version",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "version",
        .description = "Optional version to query path for",
        .required = false,
    });
    return cmd;
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);

    if (ctx.getArg("version")) |raw_version| {
        const parsed = zvm.Version.parse(raw_version) catch {
            try ctx.writer.print("error: Invalid Zig version '{s}'.\n", .{raw_version});
            return error.InvalidVersion;
        };
        const canonical = try parsed.toString(ctx.allocator);
        defer ctx.allocator.free(canonical);

        if (!app.paths.isVersionInstalled(ctx.io, ctx.allocator, canonical)) {
            try ctx.writer.print("error: Zig version '{s}' is not installed.\n", .{canonical});
            return error.VersionNotInstalled;
        }
        const bin_path = try app.paths.versionZigBin(ctx.allocator, canonical);
        defer ctx.allocator.free(bin_path);
        try ctx.writer.print("{s}\n", .{bin_path});
        return;
    }

    var resolved = zvm.resolve(app.paths, ctx.io, ctx.allocator, ctx.environ_map, app.cwd) catch |err| {
        try ctx.writer.print("error: Could not resolve active Zig version ({s}).\n", .{@errorName(err)});
        return err;
    };
    defer resolved.deinit(ctx.allocator);

    if (!app.paths.isVersionInstalled(ctx.io, ctx.allocator, resolved.version)) {
        try ctx.writer.print("error: Resolved Zig version '{s}' is not installed.\n", .{resolved.version});
        return error.VersionNotInstalled;
    }

    const bin_path = try app.paths.versionZigBin(ctx.allocator, resolved.version);
    defer ctx.allocator.free(bin_path);
    try ctx.writer.print("{s}\n", .{bin_path});
}
