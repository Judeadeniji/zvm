//! `zvm which` subcommand for printing the binary path of the active or specified Zig version.

const std = @import("std");
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;
const report = @import("report.zig");
const flags = @import("flags.zig");

const WhichError = zvm.errors.CliError || zvm.resolver.ResolveError || std.Io.Writer.Error || report.Reported;

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "which",
        .description = "Display the binary path of the active or specified Zig version",
    }, handle);
    try cmd.addFlag(flags.exact);
    try cmd.addPositionalArg(.{
        .name = "version",
        .description = "Optional version to query path for",
        .required = false,
    });
    return cmd;
}

fn handle(ctx: zli.CommandContext) WhichError!void {
    const app = ctx.getContextData(AppContext);

    if (ctx.getArg("version")) |raw_version| {
        const parsed = zvm.Version.parse(raw_version) catch {
            try app.reporter.fail("Invalid Zig version '{s}'.\n", .{raw_version});
            try app.reporter.hint("Use a version such as '0.17.0' or 'master'.\n", .{});
            return error.Reported;
        };
        const canonical = try parsed.toString(ctx.allocator);
        defer ctx.allocator.free(canonical);

        if (!app.paths.isVersionInstalled(ctx.io, ctx.allocator, canonical)) {
            try app.reporter.fail("Zig version '{s}' is not installed.\n", .{canonical});
            try app.reporter.hint("Run 'zvm install {s}' first.\n", .{canonical});
            return error.Reported;
        }
        const bin_path = try app.paths.versionZigBin(ctx.allocator, canonical);
        defer ctx.allocator.free(bin_path);
        try ctx.writer.print("{s}\n", .{bin_path});
        return;
    }

    var resolved = zvm.resolveWithOptions(app.paths, ctx.io, ctx.allocator, ctx.environ_map, app.cwd, .{
        .exact = flags.exactOverride(ctx),
    }) catch |err| {
        try app.reporter.reportError(err);
        return error.Reported;
    };
    defer resolved.deinit(ctx.allocator);

    if (!app.paths.isVersionInstalled(ctx.io, ctx.allocator, resolved.version)) {
        try app.reporter.fail("Resolved Zig version '{s}' is not installed.\n", .{resolved.version});
        try app.reporter.hint("Run 'zvm install {s}' to install it.\n", .{resolved.version});
        return error.Reported;
    }

    const bin_path = try app.paths.versionZigBin(ctx.allocator, resolved.version);
    defer ctx.allocator.free(bin_path);
    try ctx.writer.print("{s}\n", .{bin_path});
}
