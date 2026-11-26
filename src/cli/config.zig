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

pub const ConfigKey = enum {
    auto_install,
    exact,

    pub fn parse(raw: []const u8) ?ConfigKey {
        if (std.ascii.eqlIgnoreCase(raw, "auto-install")) return .auto_install;
        if (std.ascii.eqlIgnoreCase(raw, "exact")) return .exact;
        return null;
    }

    pub fn markerName(self: ConfigKey) []const u8 {
        return switch (self) {
            .auto_install => "auto-install",
            .exact => "exact",
        };
    }

    pub fn envVarName(self: ConfigKey) []const u8 {
        return switch (self) {
            .auto_install => "ZVM_AUTO_INSTALL",
            .exact => "ZVM_EXACT",
        };
    }
};

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "config",
        .description = "Inspect or toggle persistent zvm settings (auto-install, exact)",
    }, handle);
    try cmd.addPositionalArg(.{
        .name = "key",
        .description = "Setting name: auto-install or exact",
        .required = false,
    });
    try cmd.addPositionalArg(.{
        .name = "value",
        .description = "New value: on, off, or toggle",
        .required = false,
    });
    return cmd;
}

fn printKeyStatus(app: *AppContext, ctx: zli.CommandContext, key: ConfigKey) !void {
    const marker_set = app.paths.isMarkerSet(ctx.io, key.markerName());
    const marker_state: []const u8 = if (marker_set) "on" else "off";
    const status_kind: report.Status = if (marker_set) .ok else .info;
    try app.reporter.status(status_kind, "{s}: {s}\n", .{ key.markerName(), marker_state });

    if (ctx.environ_map) |env| {
        if (env.get(key.envVarName())) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                try app.reporter.muted("  (overridden in environment by {s}={s})\n", .{ key.envVarName(), trimmed });
            }
        }
    }
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const raw_key = ctx.getArg("key");
    const raw_value = ctx.getArg("value");

    if (raw_key == null) {
        try printKeyStatus(app, ctx, .auto_install);
        try printKeyStatus(app, ctx, .exact);
        return;
    }

    const key = ConfigKey.parse(raw_key.?) orelse {
        try app.reporter.fail("Unknown config key '{s}'.\n", .{raw_key.?});
        try app.reporter.hint("Supported keys: auto-install, exact\n", .{});
        return error.Reported;
    };

    if (raw_value == null) {
        try printKeyStatus(app, ctx, key);
        return;
    }

    const action = ConfigAction.parse(raw_value.?) orelse {
        try app.reporter.fail("Invalid value '{s}' for {s}.\n", .{ raw_value.?, key.markerName() });
        try app.reporter.hint("Expected 'on', 'off', or 'toggle'.\n", .{});
        return error.Reported;
    };

    const next_enabled = switch (action) {
        .enable => true,
        .disable => false,
        .toggle => !app.paths.isMarkerSet(ctx.io, key.markerName()),
    };

    try app.paths.setMarker(ctx.io, key.markerName(), next_enabled);
    if (next_enabled) {
        try app.reporter.success("{s} enabled.\n", .{key.markerName()});
    } else {
        try app.reporter.info("{s} disabled.\n", .{key.markerName()});
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

test "ConfigKey.parse and Paths.setMarker handle auto-install and exact" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expectEqual(ConfigKey.auto_install, ConfigKey.parse("auto-install").?);
    try std.testing.expectEqual(ConfigKey.exact, ConfigKey.parse("EXACT").?);
    try std.testing.expectEqual(@as(?ConfigKey, null), ConfigKey.parse("unknown"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try zvm.Paths.init(allocator, null, tmp_path);
    defer paths.deinit();

    try std.testing.expect(!paths.isMarkerSet(io, "auto-install"));
    try std.testing.expect(!paths.isMarkerSet(io, "exact"));

    try paths.setMarker(io, "auto-install", true);
    try paths.setMarker(io, "exact", true);
    try std.testing.expect(paths.isMarkerSet(io, "auto-install"));
    try std.testing.expect(paths.isMarkerSet(io, "exact"));
    try std.testing.expect(zvm.Router.isAutoInstallEnabled(&paths, io, null));

    try paths.setMarker(io, "auto-install", false);
    try paths.setMarker(io, "exact", false);
    try std.testing.expect(!paths.isMarkerSet(io, "auto-install"));
    try std.testing.expect(!paths.isMarkerSet(io, "exact"));
    try std.testing.expect(!zvm.Router.isAutoInstallEnabled(&paths, io, null));
}
