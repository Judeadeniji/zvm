//! CLI command tree assembly and top-level dispatch between `zig` shim routing and `zvm`.

const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const zvm = @import("zvm");

pub const AppContext = @import("context.zig").AppContext;
const install_cmd = @import("install.zig");
const use_cmd = @import("use.zig");
const pin_cmd = @import("pin.zig");
const list_cmd = @import("list.zig");
const list_remote_cmd = @import("list_remote.zig");
const current_cmd = @import("current.zig");
const which_cmd = @import("which.zig");
const uninstall_cmd = @import("uninstall.zig");
const setup_cmd = @import("setup.zig");
const doctor_cmd = @import("doctor.zig");
const clean_cmd = @import("clean.zig");
const env_cmd = @import("env.zig");
const completions_cmd = @import("completions.zig");

fn showHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}

/// Builds the full `zvm` CLI command tree.
pub fn buildRootCommand(init_options: zli.InitOptions) !*zli.Command {
    const root = try zli.Command.init(init_options, .{
        .name = "zvm",
        .description = "A fast, transparent Zig version manager written in Zig",
        .version = .{ .major = 0, .minor = 0, .patch = 0, .pre = null, .build = null },
    }, showHelp);
    errdefer root.deinit();

    const subcommands = [_]*const fn (zli.InitOptions) anyerror!*zli.Command{
        install_cmd.command,
        use_cmd.command,
        pin_cmd.command,
        list_cmd.command,
        list_remote_cmd.command,
        current_cmd.command,
        which_cmd.command,
        uninstall_cmd.command,
        setup_cmd.command,
        doctor_cmd.command,
        clean_cmd.command,
        env_cmd.command,
        completions_cmd.command,
    };

    for (subcommands) |builder| {
        const sub = try builder(init_options);
        errdefer sub.deinit();
        try root.addCommand(sub);
    }

    return root;
}

/// Runs either the transparent `zig` shim router or the `zvm` management CLI.
pub fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var paths = try zvm.Paths.init(gpa, init.environ_map, null);
    defer paths.deinit();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);

    const args = try init.minimal.args.toSlice(arena);
    // Short-circuit before building the `zli` tree so shim invocations have minimal startup overhead.
    if (args.len > 0 and zvm.Router.isZigShim(args[0])) {
        const router = zvm.Router.init(&paths, io, gpa, init.environ_map);
        try router.routeAndExec(cwd, args[1..]);
    }

    var wbuf: [1024]u8 = undefined;
    var stdout_writer = Io.File.Writer.init(.stdout(), io, &wbuf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var rbuf: [1024]u8 = undefined;
    var stdin_reader = Io.File.Reader.init(.stdin(), io, &rbuf);
    const stdin = &stdin_reader.interface;

    const init_options = zli.InitOptions{
        .allocator = gpa,
        .io = io,
        .writer = stdout,
        .reader = stdin,
        .environ_map = init.environ_map,
    };

    const root = try buildRootCommand(init_options);
    defer root.deinit();

    var app_ctx = AppContext{
        .paths = &paths,
        .cwd = cwd,
    };

    var args_iter = try init.minimal.args.iterateAllocator(gpa);
    defer args_iter.deinit();
    return root.run(&args_iter, .{ .data = &app_ctx });
}

test "buildRootCommand registers expected subcommands" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var wbuf: [256]u8 = undefined;
    var out_writer = Io.Writer.fixed(&wbuf);
    var rbuf: [16]u8 = undefined;
    var in_reader = Io.Reader.fixed(&rbuf);

    const root = try buildRootCommand(.{
        .allocator = allocator,
        .io = io,
        .writer = &out_writer,
        .reader = &in_reader,
    });
    defer root.deinit();

    const expected = [_][]const u8{
        "install",
        "use",
        "pin",
        "list",
        "list-remote",
        "current",
        "which",
        "uninstall",
        "setup",
        "doctor",
        "clean",
        "env",
        "completions",
    };

    for (expected) |name| {
        try std.testing.expect(root.commands_by_name.contains(name));
    }
    try std.testing.expect(root.findCommand("shim") != null);
    _ = clean_cmd;
    _ = env_cmd;
    _ = completions_cmd;
}
