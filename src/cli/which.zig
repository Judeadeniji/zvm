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
    try cmd.addFlag(.{
        .name = "zls",
        .description = "Print the path to the paired ZLS binary instead of zig",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try cmd.addPositionalArg(.{
        .name = "version",
        .description = "Optional version (or 'zls') to query path for",
        .required = false,
    });
    return cmd;
}

fn handle(ctx: zli.CommandContext) WhichError!void {
    const app = ctx.getContextData(AppContext);
    var want_zls = ctx.flag("zls", bool);
    var version_arg = ctx.getArg("version");

    if (version_arg) |arg| {
        if (std.ascii.eqlIgnoreCase(arg, "zls")) {
            want_zls = true;
            version_arg = null;
        }
    }

    const target_ver: []u8 = if (version_arg) |raw_version| blk: {
        const parsed = zvm.Version.parse(raw_version) catch {
            try app.reporter.fail("Invalid Zig version '{s}'.\n", .{raw_version});
            try app.reporter.hint("Use a version such as '0.17.0', 'master', or 'zls'.\n", .{});
            return error.Reported;
        };
        break :blk try parsed.toString(ctx.allocator);
    } else blk: {
        var resolved = zvm.resolveWithOptions(app.paths, ctx.io, ctx.allocator, ctx.environ_map, app.cwd, .{
            .exact = flags.exactOverride(ctx),
        }) catch |err| {
            try app.reporter.reportError(err);
            return error.Reported;
        };
        defer resolved.deinit(ctx.allocator);
        break :blk try ctx.allocator.dupe(u8, resolved.version);
    };
    defer ctx.allocator.free(target_ver);

    if (want_zls) {
        if (!app.paths.isZlsInstalled(ctx.io, target_ver)) {
            try app.reporter.fail("ZLS for Zig '{s}' is not installed.\n", .{target_ver});
            try app.reporter.hint("Run 'zvm zls install {s}' to install it.\n", .{target_ver});
            return error.Reported;
        }
        const bin_path = try app.paths.zlsVersionBin(ctx.allocator, target_ver);
        defer ctx.allocator.free(bin_path);
        try ctx.writer.print("{s}\n", .{bin_path});
        return;
    }

    if (!app.paths.isVersionInstalled(ctx.io, target_ver)) {
        try app.reporter.fail("Zig version '{s}' is not installed.\n", .{target_ver});
        try app.reporter.hint("Run 'zvm install {s}' to install it.\n", .{target_ver});
        return error.Reported;
    }

    const bin_path = try app.paths.versionZigBin(ctx.allocator, target_ver);
    defer ctx.allocator.free(bin_path);
    try ctx.writer.print("{s}\n", .{bin_path});
}
