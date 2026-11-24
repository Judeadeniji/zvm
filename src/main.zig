const std = @import("std");
const Io = std.Io;
const zli = @import("zli");

fn showHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}

fn handleInstall(ctx: zli.CommandContext) !void {
    const version = ctx.getArg("version") orelse "latest";
    try ctx.writer.print("Install Zig version: {s}\n", .{version});
}

fn handleUse(ctx: zli.CommandContext) !void {
    const version = ctx.getArg("version") orelse return;
    try ctx.writer.print("Set global default Zig version to: {s}\n", .{version});
}

fn handlePin(ctx: zli.CommandContext) !void {
    const version = ctx.getArg("version") orelse return;
    try ctx.writer.print("Pinned .zig-version to: {s}\n", .{version});
}

fn handleList(ctx: zli.CommandContext) !void {
    try ctx.writer.print("Installed Zig versions:\n  (none installed yet)\n", .{});
}

fn handleListRemote(ctx: zli.CommandContext) !void {
    try ctx.writer.print("Available upstream Zig releases:\n  (fetching from ziglang.org...)\n", .{});
}

fn handleCurrent(ctx: zli.CommandContext) !void {
    try ctx.writer.print("Current Zig version: (none configured)\n", .{});
}

fn handleWhich(ctx: zli.CommandContext) !void {
    const version = ctx.getArg("version");
    if (version) |v| {
        try ctx.writer.print("Path for Zig {s}: (not installed)\n", .{v});
    } else {
        try ctx.writer.print("Active Zig path: (none)\n", .{});
    }
}

fn handleUninstall(ctx: zli.CommandContext) !void {
    const version = ctx.getArg("version") orelse return;
    try ctx.writer.print("Uninstalling Zig version: {s}\n", .{version});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var wbuf: [1024]u8 = undefined;
    var stdout_writer = Io.File.Writer.init(.stdout(), io, &wbuf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var rbuf: [1024]u8 = undefined;
    var stdin_reader = Io.File.Reader.init(.stdin(), io, &rbuf);
    const stdin = &stdin_reader.interface;

    const init_options = zli.InitOptions{
        .allocator = init.gpa,
        .io = io,
        .writer = stdout,
        .reader = stdin,
    };

    const root = try zli.Command.init(init_options, .{
        .name = "zvm",
        .description = "A fast, transparent Zig version manager written in Zig",
        .version = .{ .major = 0, .minor = 0, .patch = 0, .pre = null, .build = null },
    }, showHelp);
    defer root.deinit();

    // install
    const cmd_install = try zli.Command.init(init_options, .{
        .name = "install",
        .description = "Download and install a Zig compiler version (e.g. 0.17.0, master)",
    }, handleInstall);
    try cmd_install.addPositionalArg(.{
        .name = "version",
        .description = "Version to install (e.g. '0.17.0', 'master')",
        .required = true,
    });
    try root.addCommand(cmd_install);

    // use
    const cmd_use = try zli.Command.init(init_options, .{
        .name = "use",
        .description = "Switch the global default Zig version",
    }, handleUse);
    try cmd_use.addPositionalArg(.{
        .name = "version",
        .description = "Installed version to set as global default",
        .required = true,
    });
    try root.addCommand(cmd_use);

    // pin
    const cmd_pin = try zli.Command.init(init_options, .{
        .name = "pin",
        .description = "Pin the Zig version for the current project (.zig-version)",
    }, handlePin);
    try cmd_pin.addPositionalArg(.{
        .name = "version",
        .description = "Version to pin in .zig-version",
        .required = true,
    });
    try root.addCommand(cmd_pin);

    // list
    const cmd_list = try zli.Command.init(init_options, .{
        .name = "list",
        .description = "List locally installed Zig versions",
    }, handleList);
    try root.addCommand(cmd_list);

    // list-remote
    const cmd_list_remote = try zli.Command.init(init_options, .{
        .name = "list-remote",
        .description = "List available releases from ziglang.org",
    }, handleListRemote);
    try root.addCommand(cmd_list_remote);

    // current
    const cmd_current = try zli.Command.init(init_options, .{
        .name = "current",
        .description = "Show the currently active Zig version for the current directory",
    }, handleCurrent);
    try root.addCommand(cmd_current);

    // which
    const cmd_which = try zli.Command.init(init_options, .{
        .name = "which",
        .description = "Display the binary path of the active or specified Zig version",
    }, handleWhich);
    try cmd_which.addPositionalArg(.{
        .name = "version",
        .description = "Optional version to query path for",
        .required = false,
    });
    try root.addCommand(cmd_which);

    // uninstall
    const cmd_uninstall = try zli.Command.init(init_options, .{
        .name = "uninstall",
        .description = "Remove an installed Zig version",
    }, handleUninstall);
    try cmd_uninstall.addPositionalArg(.{
        .name = "version",
        .description = "Installed version to remove",
        .required = true,
    });
    try root.addCommand(cmd_uninstall);

    var args_iter = init.minimal.args.iterate();
    root.runAndExit(&args_iter, .{});
}
