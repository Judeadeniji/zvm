//! `zvm use` subcommand for switching the global default Zig version.

const std = @import("std");
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;
const ExitCode = @import("context.zig").ExitCode;
const report = @import("report.zig");
const zls_cmd = @import("zls.zig");

const UseError = zvm.errors.CliError ||
    std.mem.Allocator.Error ||
    std.Io.Writer.Error ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.WriteFileError ||
    report.Reported;

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "use",
        .description = "Switch the global default Zig version",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "version",
        .description = "Installed version to set as global default",
        .required = true,
    });
    try cmd.addFlag(.{
        .name = "with-zls",
        .description = "Also install/activate the paired ZLS release if missing",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    return cmd;
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const raw_version = ctx.getArg("version") orelse return zvm.errors.CliError.MissingVersion;
    const with_zls = ctx.flag("with-zls", bool);

    const parsed = zvm.Version.parse(raw_version) catch {
        try app.reporter.fail("Invalid Zig version '{s}'.\n", .{raw_version});
        try app.reporter.hint("Use a version such as '0.17.0' or 'master'.\n", .{});
        return error.Reported;
    };
    const canonical = try parsed.toString(ctx.allocator);
    defer ctx.allocator.free(canonical);

    if (!app.paths.isVersionInstalled(ctx.io, canonical)) {
        app.exit_code = ExitCode.unavailable;
        try app.reporter.fail("Zig version '{s}' is not installed.\n", .{canonical});
        try app.reporter.hint("Run 'zvm install {s}' first.\n", .{canonical});
        return error.Reported;
    }

    try app.paths.writeDefaultVersion(ctx.io, canonical);
    try app.reporter.success("Global default Zig version set to {s}.\n", .{canonical});

    if (with_zls) {
        if (!app.paths.isZlsInstalled(ctx.io, canonical)) {
            try zls_cmd.installZlsWithSpinner(app, ctx, canonical, false);
        }
        try app.paths.writeZlsDefaultVersion(ctx.io, canonical);
    }

    var shim_status = zvm.shim.inspectShim(app.paths, ctx.io, ctx.allocator, null) catch null;
    defer if (shim_status) |*s| s.deinit(ctx.allocator);
    if (shim_status != null and shim_status.? == .missing) {
        try app.reporter.hint("Next: Run 'zvm setup' to create the 'zig' shim, then 'zig version' to verify.\n", .{});
    } else {
        try app.reporter.muted("Run 'zig version' to verify (or 'zvm doctor' to inspect PATH and shim status).\n", .{});
    }
}
