//! `zvm doctor` subcommand for diagnosing ZVM directories, shim health, and `PATH` precedence.

const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

pub fn command(init_options: zli.InitOptions) !*zli.Command {
    return zli.Command.init(init_options, .{
        .name = "doctor",
        .description = "Check zvm directories, zig shim status, and PATH precedence",
    }, handle);
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const cwd = Io.Dir.cwd();

    try ctx.writer.writeAll("zvm doctor\n\n");

    // 1. Base & bin directories
    const base_exists = blk: {
        cwd.access(ctx.io, app.paths.base_dir, .{}) catch break :blk false;
        break :blk true;
    };
    if (base_exists) {
        try ctx.writer.print("[OK]   Base directory: {s}\n", .{app.paths.base_dir});
    } else {
        try ctx.writer.print("[WARN] Base directory missing: {s} (run 'zvm setup')\n", .{app.paths.base_dir});
    }

    // 2. Shim verification
    const self_exe = try std.process.executablePathAlloc(ctx.io, ctx.allocator);
    defer ctx.allocator.free(self_exe);

    const shim_path = try app.paths.zigShimPath(ctx.allocator);
    defer ctx.allocator.free(shim_path);

    var shim_status = try zvm.shim.inspectShim(app.paths, ctx.io, ctx.allocator, self_exe);
    defer shim_status.deinit(ctx.allocator);

    switch (shim_status) {
        .valid => |target| {
            try ctx.writer.print("[OK]   Zig shim: {s} -> {s}\n", .{ shim_path, target });
        },
        .missing => {
            try ctx.writer.print("[FAIL] Zig shim missing at {s} (run 'zvm setup')\n", .{shim_path});
        },
        .broken_symlink => |target| {
            try ctx.writer.print("[FAIL] Zig shim symlink is broken: {s} -> {s} (run 'zvm setup --force')\n", .{ shim_path, target });
        },
        .wrong_target => |target| {
            try ctx.writer.print("[WARN] Zig shim points elsewhere: {s} -> {s} (expected {s})\n", .{ shim_path, target, self_exe });
        },
        .not_a_symlink => {
            try ctx.writer.print("[WARN] {s} is a regular file, not a zvm symlink (run 'zvm setup --force')\n", .{shim_path});
        },
    }

    // 3. PATH ordering check
    var path_check = try zvm.shim.checkPathOrder(app.paths, ctx.io, ctx.allocator, ctx.environ_map);
    defer path_check.deinit(ctx.allocator);

    if (!path_check.bin_dir_in_path) {
        try ctx.writer.print("[FAIL] '{s}' is not in PATH\n", .{app.paths.bin_dir});
        if (!zvm.Paths.is_windows) {
            try ctx.writer.print("       Add: export PATH=\"{s}:$PATH\"\n", .{app.paths.bin_dir});
        }
    } else if (!path_check.shim_takes_precedence) {
        try ctx.writer.print("[WARN] PATH shadows zvm shim: first zig found in '{s}' (zvm bin at index {d})\n", .{
            path_check.first_zig_dir orelse "(none)",
            path_check.bin_dir_index orelse 0,
        });
        if (!zvm.Paths.is_windows) {
            try ctx.writer.print("       Prepend: export PATH=\"{s}:$PATH\"\n", .{app.paths.bin_dir});
        }
    } else {
        try ctx.writer.print("[OK]   PATH order: '{s}' takes precedence for 'zig'\n", .{app.paths.bin_dir});
    }

    // 4. Installed versions
    const versions = try app.paths.listInstalledVersions(ctx.io, ctx.allocator);
    defer zvm.Paths.freeInstalledVersions(ctx.allocator, versions);
    try ctx.writer.print("[INFO] Installed Zig versions: {d}\n", .{versions.len});

    // 5. Active version resolution in current dir
    var resolved = zvm.resolve(app.paths, ctx.io, ctx.allocator, ctx.environ_map, app.cwd) catch |err| {
        try ctx.writer.print("[INFO] Active version in '{s}': unresolved ({s})\n", .{ app.cwd, @errorName(err) });
        return;
    };
    defer resolved.deinit(ctx.allocator);

    const is_installed = app.paths.isVersionInstalled(ctx.io, ctx.allocator, resolved.version);
    const state = if (is_installed) "installed" else "not installed";
    try ctx.writer.print("[INFO] Active version in '{s}': {s} ({s})\n", .{ app.cwd, resolved.version, state });
}
