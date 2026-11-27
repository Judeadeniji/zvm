//! Parsing of `ZVM_*` boolean environment flags.
//!
//! The resolver and the router each expose a toggle (`ZVM_EXACT`,
//! `ZVM_AUTO_INSTALL`) that overrides a persistent marker file, and both accepted
//! the same vocabulary in their own copy of this code.

const std = @import("std");
const EnvironMap = std.process.Environ.Map;

const truthy = [_][]const u8{ "1", "true", "yes" };
const falsy = [_][]const u8{ "0", "false", "no" };

/// Reads a boolean override from the environment, or null when the variable is
/// unset or holds a value that is neither truthy nor falsy, so the caller can fall
/// back to its marker file.
pub fn boolOverride(environ_map: ?*const EnvironMap, name: []const u8) ?bool {
    const env = environ_map orelse return null;
    const raw = env.get(name) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");

    for (truthy) |value| {
        if (std.ascii.eqlIgnoreCase(trimmed, value)) return true;
    }
    for (falsy) |value| {
        if (std.ascii.eqlIgnoreCase(trimmed, value)) return false;
    }
    return null;
}

test "boolOverride accepts the shared boolean vocabulary" {
    var map: EnvironMap = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("ZVM_FLAG_ON", " TRUE\n");
    try map.put("ZVM_FLAG_OFF", "No ");
    try map.put("ZVM_FLAG_ODD", "maybe");
    try map.put("ZVM_FLAG_EMPTY", "");

    try std.testing.expectEqual(@as(?bool, true), boolOverride(&map, "ZVM_FLAG_ON"));
    try std.testing.expectEqual(@as(?bool, false), boolOverride(&map, "ZVM_FLAG_OFF"));
    try std.testing.expectEqual(@as(?bool, null), boolOverride(&map, "ZVM_FLAG_ODD"));
    try std.testing.expectEqual(@as(?bool, null), boolOverride(&map, "ZVM_FLAG_EMPTY"));
    try std.testing.expectEqual(@as(?bool, null), boolOverride(&map, "ZVM_FLAG_MISSING"));
    try std.testing.expectEqual(@as(?bool, null), boolOverride(null, "ZVM_FLAG_ON"));
}
