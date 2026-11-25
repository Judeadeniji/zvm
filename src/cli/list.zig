const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;

pub fn command(init_options: zli.InitOptions) !*zli.Command {
    return zli.Command.init(init_options, .{
        .name = "list",
        .description = "List locally installed Zig versions",
    }, handle);
}

fn lessThanVersion(_: void, a: []const u8, b: []const u8) bool {
    const va = zvm.Version.parse(a) catch return std.mem.order(u8, a, b) == .lt;
    const vb = zvm.Version.parse(b) catch return std.mem.order(u8, a, b) == .lt;
    return va.order(vb) == .lt;
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const cwd = Io.Dir.cwd();

    var v_dir = cwd.openDir(ctx.io, app.paths.versions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.writer.writeAll("No Zig versions installed.\n");
            return;
        },
        else => return err,
    };
    defer v_dir.close(ctx.io);

    var versions: std.ArrayList([]u8) = .empty;
    defer {
        for (versions.items) |item| ctx.allocator.free(item);
        versions.deinit(ctx.allocator);
    }

    var it = v_dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (app.paths.isVersionInstalled(ctx.io, ctx.allocator, entry.name)) {
            const copy = try ctx.allocator.dupe(u8, entry.name);
            try versions.append(ctx.allocator, copy);
        }
    }

    if (versions.items.len == 0) {
        try ctx.writer.writeAll("No Zig versions installed.\n");
        return;
    }

    std.mem.sort([]u8, versions.items, {}, lessThanVersion);

    var active_version: ?[]const u8 = null;
    var resolved = zvm.resolve(app.paths, ctx.io, ctx.allocator, ctx.environ_map, app.cwd) catch null;
    defer if (resolved) |*r| r.deinit(ctx.allocator);
    if (resolved) |r| {
        active_version = r.version;
    }

    for (versions.items) |ver| {
        const is_active = if (active_version) |act| std.mem.eql(u8, act, ver) else false;
        const marker = if (is_active) "* " else "  ";
        try ctx.writer.print("{s}{s}\n", .{ marker, ver });
    }
}
