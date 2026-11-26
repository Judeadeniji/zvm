//! `zvm clean` subcommand for removing cached Zig release archives.

const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const AppContext = @import("context.zig").AppContext;

pub const CleanSummary = struct {
    files_removed: usize,
    bytes_freed: u64,
};

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "clean",
        .description = "Remove cached download archives from ~/.zvm/cache/",
    }, handle);
    try cmd.addFlag(.{
        .name = "dry-run",
        .shortcut = "n",
        .description = "Show what would be removed without deleting files",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    return cmd;
}

/// Recursively sums the file sizes below `dir/name` (0 when it cannot be read).
fn dirSizeBytes(io: Io, dir: Io.Dir, name: []const u8) u64 {
    var sub = dir.openDir(io, name, .{ .iterate = true }) catch return 0;
    defer sub.close(io);

    var total: u64 = 0;
    var it = sub.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            total += dirSizeBytes(io, sub, entry.name);
        } else {
            const st = sub.statFile(io, entry.name, .{}) catch continue;
            total += st.size;
        }
    }
    return total;
}

pub fn cleanCacheDir(io: Io, cache_dir_path: []const u8, dry_run: bool) !CleanSummary {
    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, cache_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .files_removed = 0, .bytes_freed = 0 },
        else => return err,
    };
    defer dir.close(io);

    var summary: CleanSummary = .{ .files_removed = 0, .bytes_freed = 0 };
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            summary.bytes_freed += dirSizeBytes(io, dir, entry.name);
            if (!dry_run) try dir.deleteTree(io, entry.name);
            summary.files_removed += 1;
            continue;
        }

        const st = dir.statFile(io, entry.name, .{}) catch null;
        if (st) |s| summary.bytes_freed += s.size;
        if (!dry_run) try dir.deleteFile(io, entry.name);
        summary.files_removed += 1;
    }

    return summary;
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const dry_run = ctx.flag("dry-run", bool);

    const summary = try cleanCacheDir(ctx.io, app.paths.cache_dir, dry_run);
    if (summary.files_removed == 0) {
        try app.reporter.note("Cache is already empty.\n", .{});
        return;
    }

    const mb = @as(f64, @floatFromInt(summary.bytes_freed)) / (1024.0 * 1024.0);
    if (dry_run) {
        try app.reporter.info("Would remove {d} cached item(s) ({d:.2} MB).\n", .{
            summary.files_removed,
            mb,
        });
    } else {
        try app.reporter.success("Removed {d} cached item(s) ({d:.2} MB freed).\n", .{
            summary.files_removed,
            mb,
        });
    }
}

test "cleanCacheDir dry-run and delete" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cache_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "cache" });
    defer allocator.free(cache_path);
    try Io.Dir.cwd().createDirPath(io, cache_path);

    const file_a = try std.fs.path.join(allocator, &.{ cache_path, "a.tar.xz" });
    defer allocator.free(file_a);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file_a, .data = "0123456789" });

    // A nested directory contributes its contents, not just an item count.
    const nested_dir = try std.fs.path.join(allocator, &.{ cache_path, "stage" });
    defer allocator.free(nested_dir);
    try Io.Dir.cwd().createDirPath(io, nested_dir);
    const nested_file = try std.fs.path.join(allocator, &.{ nested_dir, "b.bin" });
    defer allocator.free(nested_file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = nested_file, .data = "01234" });

    const dry = try cleanCacheDir(io, cache_path, true);
    try std.testing.expectEqual(@as(usize, 2), dry.files_removed);
    try std.testing.expectEqual(@as(u64, 15), dry.bytes_freed);
    try Io.Dir.cwd().access(io, file_a, .{});

    const real = try cleanCacheDir(io, cache_path, false);
    try std.testing.expectEqual(@as(usize, 2), real.files_removed);
    try std.testing.expectEqual(@as(u64, 15), real.bytes_freed);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, file_a, .{}));
}
