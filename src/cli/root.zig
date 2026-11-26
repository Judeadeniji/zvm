//! CLI command tree assembly and top-level dispatch between `zig` shim routing and `zvm`.

const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const zvm = @import("zvm");
const build_options = @import("build_options");

pub const AppContext = @import("context.zig").AppContext;
const report = @import("report.zig");
const ansi_strip = @import("ansi_strip.zig");
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
pub fn buildRootCommand(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const root = try zli.Command.init(init_options, .{
        .name = "zvm",
        .description = "A fast, transparent Zig version manager written in Zig",
        .version = build_options.version,
    }, showHelp);
    errdefer root.deinit();

    const subcommands = [_]*const fn (zli.InitOptions) zli.CommandSetupErrors!*zli.Command{
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

    var ebuf: [1024]u8 = undefined;
    var stderr_writer = Io.File.Writer.init(.stderr(), io, &ebuf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var rbuf: [1024]u8 = undefined;
    var stdin_reader = Io.File.Reader.init(.stdin(), io, &rbuf);
    const stdin = &stdin_reader.interface;

    var reporter = report.Reporter.init(io, init.environ_map, stdout, stderr);
    var strip_writer: ansi_strip.Writer = undefined;
    if (!reporter.out_color) {
        strip_writer = .init(stdout);
        reporter = report.Reporter.initWithColor(&strip_writer.interface, stderr, false, reporter.err_color);
    }

    const init_options = zli.InitOptions{
        .allocator = gpa,
        .io = io,
        .writer = reporter.out,
        .reader = stdin,
        .environ_map = init.environ_map,
        .error_writer = stderr,
    };

    const root = try buildRootCommand(init_options);
    defer root.deinit();

    var app_ctx = AppContext{
        .paths = &paths,
        .cwd = cwd,
        .reporter = reporter,
    };

    var args_iter = try init.minimal.args.iterateAllocator(gpa);
    defer args_iter.deinit();

    root.execute(&args_iter, .{ .data = &app_ctx }) catch |err| {
        // `zli` already printed parse/validation errors. Handlers that print
        // their own diagnostic return `Reported`; everything else gets a
        // friendly fallback instead of a raw `error: ErrorName` line.
        if (err != error.Reported and !isZliCommandError(err)) {
            reporter.reportError(err) catch {};
        }
        return 1;
    };
    return 0;
}

/// Whether `err` is one of `zli`'s own command/parse errors (already printed).
fn isZliCommandError(err: anyerror) bool {
    inline for (@typeInfo(zli.CommandErrors).error_set.error_names.?) |name| {
        if (err == @field(zli.CommandErrors, name)) return true;
    }
    return false;
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
    for ([_][]const u8{ "current", "which", "doctor", "list" }) |name| {
        const cmd = root.findCommand(name).?;
        try std.testing.expect(cmd.flags_by_name.contains("exact"));
    }
    try std.testing.expect(root.findCommand("shim") != null);
    _ = clean_cmd;
    _ = env_cmd;
    _ = completions_cmd;
}
