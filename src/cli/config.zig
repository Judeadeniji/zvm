//! `zvm config` subcommand for inspecting and toggling persistent ZVM settings.

const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;
const report = @import("report.zig");

pub const ConfigAction = enum {
    enable,
    disable,
    toggle,

    pub fn parse(raw: []const u8) ?ConfigAction {
        if (std.ascii.eqlIgnoreCase(raw, "on") or
            std.ascii.eqlIgnoreCase(raw, "true") or
            std.ascii.eqlIgnoreCase(raw, "1") or
            std.ascii.eqlIgnoreCase(raw, "enable"))
        {
            return .enable;
        }
        if (std.ascii.eqlIgnoreCase(raw, "off") or
            std.ascii.eqlIgnoreCase(raw, "false") or
            std.ascii.eqlIgnoreCase(raw, "0") or
            std.ascii.eqlIgnoreCase(raw, "disable"))
        {
            return .disable;
        }
        if (std.ascii.eqlIgnoreCase(raw, "toggle")) {
            return .toggle;
        }
        return null;
    }
};

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "config",
        .description = "Inspect or toggle persistent zvm settings (e.g. auto-install)",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "key",
        .description = "Setting name (e.g. 'auto-install')",
        .required = false,
    });
    try cmd.addPositionalArg(.{
        .name = "value",
        .description = "New value: on, off, or toggle",
        .required = false,
    });
    return cmd;
}

pub fn autoInstallMarkerPath(paths: *const zvm.Paths, allocator: std.mem.Allocator) ![]u8 {
    return std.fs.path.join(allocator, &.{ paths.base_dir, "auto-install" });
}

pub fn isAutoInstallMarkerSet(paths: *const zvm.Paths, io: Io, allocator: std.mem.Allocator) !bool {
    const marker_path = try autoInstallMarkerPath(paths, allocator);
    defer allocator.free(marker_path);
    Io.Dir.cwd().access(io, marker_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn setAutoInstall(paths: *const zvm.Paths, io: Io, allocator: std.mem.Allocator, enabled: bool) !void {
    const marker_path = try autoInstallMarkerPath(paths, allocator);
    defer allocator.free(marker_path);

    const cwd = Io.Dir.cwd();
    if (enabled) {
        try paths.ensureDirs(io);
        try cwd.writeFile(io, .{ .sub_path = marker_path, .data = "" });
    } else {
        cwd.deleteFile(io, marker_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn printAutoInstallStatus(app: *AppContext, ctx: zli.CommandContext) !void {
    const marker_set = try isAutoInstallMarkerSet(app.paths, ctx.io, ctx.allocator);
    const marker_state: []const u8 = if (marker_set) "on" else "off";
    const status_kind: report.Status = if (marker_set) .ok else .info;
    try app.reporter.status(status_kind, "auto-install: {s}\n", .{marker_state});

    if (ctx.environ_map) |env| {
        if (env.get("ZVM_AUTO_INSTALL")) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                try app.reporter.muted("  (overridden in environment by ZVM_AUTO_INSTALL={s})\n", .{trimmed});
            }
        }
    }
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const key = ctx.getArg("key");
    const value = ctx.getArg("value");

    if (key == null) {
        try printAutoInstallStatus(app, ctx);
        return;
    }

    if (!std.ascii.eqlIgnoreCase(key.?, "auto-install")) {
        try app.reporter.fail("Unknown config key '{s}'.\n", .{key.?});
        try app.reporter.hint("Supported keys: auto-install\n", .{});
        return error.Reported;
    }

    if (value == null) {
        try printAutoInstallStatus(app, ctx);
        return;
    }

    const action = ConfigAction.parse(value.?) orelse {
        try app.reporter.fail("Invalid value '{s}' for auto-install.\n", .{value.?});
        try app.reporter.hint("Expected 'on', 'off', or 'toggle'.\n", .{});
        return error.Reported;
    };

    const next_enabled = switch (action) {
        .enable => true,
        .disable => false,
        .toggle => !(try isAutoInstallMarkerSet(app.paths, ctx.io, ctx.allocator)),
    };

    try setAutoInstall(app.paths, ctx.io, ctx.allocator, next_enabled);
    if (next_enabled) {
        try app.reporter.success("Auto-install enabled.\n", .{});
    } else {
        try app.reporter.info("Auto-install disabled.\n", .{});
    }
}

test "ConfigAction.parse recognizes on, off, and toggle aliases" {
    try std.testing.expectEqual(ConfigAction.enable, ConfigAction.parse("on").?);
    try std.testing.expectEqual(ConfigAction.enable, ConfigAction.parse("TRUE").?);
    try std.testing.expectEqual(ConfigAction.enable, ConfigAction.parse("1").?);
    try std.testing.expectEqual(ConfigAction.disable, ConfigAction.parse("off").?);
    try std.testing.expectEqual(ConfigAction.disable, ConfigAction.parse("false").?);
    try std.testing.expectEqual(ConfigAction.disable, ConfigAction.parse("0").?);
    try std.testing.expectEqual(ConfigAction.toggle, ConfigAction.parse("toggle").?);
    try std.testing.expectEqual(@as(?ConfigAction, null), ConfigAction.parse("maybe"));
}

test "setAutoInstall creates and removes marker file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try zvm.Paths.init(allocator, null, tmp_path);
    defer paths.deinit();

    try std.testing.expect(!(try isAutoInstallMarkerSet(&paths, io, allocator)));

    try setAutoInstall(&paths, io, allocator, true);
    try std.testing.expect(try isAutoInstallMarkerSet(&paths, io, allocator));
    try std.testing.expect(zvm.Router.isAutoInstallEnabled(&paths, io, null));

    try setAutoInstall(&paths, io, allocator, false);
    try std.testing.expect(!(try isAutoInstallMarkerSet(&paths, io, allocator)));
    try std.testing.expect(!zvm.Router.isAutoInstallEnabled(&paths, io, null));
}
