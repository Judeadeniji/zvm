const std = @import("std");
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

pub fn command(init_options: zli.InitOptions) !*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "setup",
        .aliases = &.{"shim"},
        .description = "Create or verify the zig shim symlink in ~/.zvm/bin/",
    }, handle);
    try cmd.addFlag(.{
        .name = "force",
        .shortcut = "f",
        .description = "Overwrite an existing zig file or symlink in ~/.zvm/bin/",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    return cmd;
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const force = ctx.flag("force", bool);

    const self_exe = try std.process.executablePathAlloc(ctx.io, ctx.allocator);
    defer ctx.allocator.free(self_exe);

    var res = zvm.shim.setupShim(app.paths, ctx.io, ctx.allocator, self_exe, force) catch |err| switch (err) {
        error.ShimAlreadyExists => {
            const shim_p = try app.paths.zigShimPath(ctx.allocator);
            defer ctx.allocator.free(shim_p);
            try ctx.writer.print("error: '{s}' already exists and does not point to this zvm binary.\n", .{shim_p});
            try ctx.writer.writeAll("hint: Re-run with '--force' to replace it.\n");
            return err;
        },
        else => return err,
    };
    defer res.deinit(ctx.allocator);

    switch (res.outcome) {
        .created => try ctx.writer.print("Created zig shim: {s} -> {s}\n", .{ res.shim_path, res.target_path }),
        .updated => try ctx.writer.print("Updated zig shim: {s} -> {s}\n", .{ res.shim_path, res.target_path }),
        .already_configured => try ctx.writer.print("Zig shim is already configured: {s} -> {s}\n", .{ res.shim_path, res.target_path }),
    }

    var path_check = try zvm.shim.checkPathOrder(app.paths, ctx.io, ctx.allocator, ctx.environ_map);
    defer path_check.deinit(ctx.allocator);

    if (!path_check.bin_dir_in_path) {
        try ctx.writer.print("\nnote: '{s}' is not in your PATH.\n", .{app.paths.bin_dir});
        try printPathHint(ctx.writer, app.paths.bin_dir);
    } else if (!path_check.shim_takes_precedence) {
        try ctx.writer.print("\nwarning: Another zig binary in '{s}' shadows '{s}'.\n", .{
            path_check.first_zig_dir orelse "(unknown)",
            app.paths.bin_dir,
        });
        try printPathHint(ctx.writer, app.paths.bin_dir);
    }
}

fn printPathHint(writer: *std.Io.Writer, bin_dir: []const u8) !void {
    if (zvm.Paths.is_windows) {
        try writer.print("Add '{s}' to the top of your user PATH environment variable.\n", .{bin_dir});
    } else {
        try writer.print("Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):\n  export PATH=\"{s}:$PATH\"\n", .{bin_dir});
    }
}
