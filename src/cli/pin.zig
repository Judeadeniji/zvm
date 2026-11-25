//! `zvm pin` subcommand for writing a `.zig-version` file in the current project.

const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "pin",
        .description = "Pin a Zig version or semver constraint for the current project (.zig-version)",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "version",
        .description = "Version or constraint to pin (e.g. '0.17.0', '^0.17.0', '>=0.16.0', 'master')",
        .required = true,
    });
    return cmd;
}

const PinError = zvm.errors.CliError ||
    std.mem.Allocator.Error ||
    std.Io.Writer.Error ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.WriteFileError;

fn handle(ctx: zli.CommandContext) PinError!void {
    const app = ctx.getContextData(AppContext);
    const raw_input = ctx.getArg("version") orelse return zvm.errors.CliError.MissingVersion;
    const trimmed = std.mem.trim(u8, raw_input, " \t\r\n");

    const constraint = zvm.Constraint.parse(trimmed) catch {
        try ctx.writer.print("error: Invalid Zig version or constraint '{s}'.\n", .{trimmed});
        return zvm.errors.CliError.InvalidVersion;
    };

    const pinned_text = if (constraint.exactPin()) |exact|
        try exact.toString(ctx.allocator)
    else
        try ctx.allocator.dupe(u8, trimmed);
    defer ctx.allocator.free(pinned_text);

    const file_path = try std.fs.path.join(ctx.allocator, &.{ app.cwd, ".zig-version" });
    defer ctx.allocator.free(file_path);

    const payload = try ctx.allocator.print("{s}\n", .{pinned_text});
    defer ctx.allocator.free(payload);

    try Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = file_path,
        .data = payload,
    });

    try ctx.writer.print("Pinned {s} to {s}.\n", .{ file_path, pinned_text });

    if (constraint.exactPin() != null) {
        if (!app.paths.isVersionInstalled(ctx.io, ctx.allocator, pinned_text)) {
            try ctx.writer.print("note: Zig version '{s}' is not installed yet. Run 'zvm install {s}' to install it.\n", .{ pinned_text, pinned_text });
        }
    } else {
        const matched = try zvm.resolver.findHighestMatchingInstalled(app.paths, ctx.io, ctx.allocator, constraint);
        defer if (matched) |m| ctx.allocator.free(m);
        if (matched) |m| {
            try ctx.writer.print("Resolved locally installed version matching '{s}': {s}\n", .{ pinned_text, m });
        } else {
            try ctx.writer.print("note: No locally installed Zig version satisfies '{s}'.\n", .{pinned_text});
        }
    }
}
