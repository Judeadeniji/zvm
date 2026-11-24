const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;

pub const Paths = struct {
    allocator: Allocator,
    base_dir: []const u8,
    versions_dir: []const u8,
    bin_dir: []const u8,
    cache_dir: []const u8,
    default_file: []const u8,

    pub const is_windows = builtin.target.os.tag == .windows;
    pub const zig_exe_name = if (is_windows) "zig.exe" else "zig";

    /// Initialize Paths.
    /// - If `custom_base` is given, it will be used as the base directory.
    /// - Else if `environ_map` contains "ZVM_PATH", that will be used.
    /// - Else if `environ_map` contains "HOME" (or "USERPROFILE" on Windows), `<HOME>/.zvm` is used.
    pub fn init(allocator: Allocator, environ_map: ?*const EnvironMap, custom_base: ?[]const u8) !Paths {
        const base = if (custom_base) |b|
            try allocator.dupe(u8, b)
        else if (environ_map != null and environ_map.?.get("ZVM_PATH") != null)
            try allocator.dupe(u8, environ_map.?.get("ZVM_PATH").?)
        else blk: {
            const home_key = if (is_windows) "USERPROFILE" else "HOME";
            const home_val = if (environ_map) |m| m.get(home_key) else null;
            if (home_val) |home| {
                break :blk try std.fs.path.join(allocator, &.{ home, ".zvm" });
            }
            return error.EnvironmentHomeMissing;
        };
        errdefer allocator.free(base);

        const versions = try std.fs.path.join(allocator, &.{ base, "versions" });
        errdefer allocator.free(versions);

        const bin = try std.fs.path.join(allocator, &.{ base, "bin" });
        errdefer allocator.free(bin);

        const cache = try std.fs.path.join(allocator, &.{ base, "cache" });
        errdefer allocator.free(cache);

        const default_f = try std.fs.path.join(allocator, &.{ base, "default" });
        errdefer allocator.free(default_f);

        return .{
            .allocator = allocator,
            .base_dir = base,
            .versions_dir = versions,
            .bin_dir = bin,
            .cache_dir = cache,
            .default_file = default_f,
        };
    }

    pub fn deinit(self: *Paths) void {
        self.allocator.free(self.base_dir);
        self.allocator.free(self.versions_dir);
        self.allocator.free(self.bin_dir);
        self.allocator.free(self.cache_dir);
        self.allocator.free(self.default_file);
    }

    /// Creates base, versions, bin, and cache directories if they don't exist.
    pub fn ensureDirs(self: *const Paths, io: Io) !void {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, self.base_dir);
        try cwd.createDirPath(io, self.versions_dir);
        try cwd.createDirPath(io, self.bin_dir);
        try cwd.createDirPath(io, self.cache_dir);
    }

    /// Returns path to the directory for a given version, e.g. ~/.zvm/versions/0.17.0
    pub fn versionDir(self: *const Paths, allocator: Allocator, version: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.versions_dir, version });
    }

    /// Returns path to the zig executable for a given version, e.g. ~/.zvm/versions/0.17.0/zig
    pub fn versionZigBin(self: *const Paths, allocator: Allocator, version: []const u8) ![]u8 {
        const v_dir = try self.versionDir(allocator, version);
        defer allocator.free(v_dir);
        return std.fs.path.join(allocator, &.{ v_dir, zig_exe_name });
    }

    /// Checks if a given version is installed (i.e. its zig binary exists).
    pub fn isVersionInstalled(self: *const Paths, io: Io, allocator: Allocator, version: []const u8) bool {
        const bin_path = self.versionZigBin(allocator, version) catch return false;
        defer allocator.free(bin_path);
        const cwd = Io.Dir.cwd();
        cwd.access(io, bin_path, .{}) catch return false;
        return true;
    }

    /// Reads the global default version from ~/.zvm/default, or null if not set / file missing.
    pub fn readDefaultVersion(self: *const Paths, io: Io, allocator: Allocator) !?[]u8 {
        const cwd = Io.Dir.cwd();
        var buf: [256]u8 = undefined;
        const bytes = cwd.readFile(io, self.default_file, &buf) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try allocator.dupe(u8, trimmed);
    }

    /// Sets the global default version by writing to ~/.zvm/default.
    pub fn writeDefaultVersion(self: *const Paths, io: Io, version: []const u8) !void {
        try self.ensureDirs(io);
        const cwd = Io.Dir.cwd();
        const payload = try self.allocator.print("{s}\n", .{version});
        defer self.allocator.free(payload);
        try cwd.writeFile(io, .{
            .sub_path = self.default_file,
            .data = payload,
        });
    }
};

test "Paths initialization and directory resolution" {
    const allocator = std.testing.allocator;
    var paths = try Paths.init(allocator, null, "/tmp/zvm_test_paths");
    defer paths.deinit();

    try std.testing.expectEqualStrings("/tmp/zvm_test_paths", paths.base_dir);
    try std.testing.expect(std.mem.endsWith(u8, paths.versions_dir, "versions"));
    try std.testing.expect(std.mem.endsWith(u8, paths.bin_dir, "bin"));
    try std.testing.expect(std.mem.endsWith(u8, paths.cache_dir, "cache"));
    try std.testing.expect(std.mem.endsWith(u8, paths.default_file, "default"));

    const v_dir = try paths.versionDir(allocator, "0.17.0");
    defer allocator.free(v_dir);
    try std.testing.expect(std.mem.endsWith(u8, v_dir, "versions/0.17.0"));

    const bin_path = try paths.versionZigBin(allocator, "0.17.0");
    defer allocator.free(bin_path);
    try std.testing.expect(std.mem.endsWith(u8, bin_path, Paths.zig_exe_name));
}

test "Paths read and write default version" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp_dir.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();

    // Initially, no default version exists
    const initial = try paths.readDefaultVersion(io, allocator);
    try std.testing.expectEqual(@as(?[]u8, null), initial);

    // Write default version
    try paths.writeDefaultVersion(io, "0.17.0");

    const read_back = try paths.readDefaultVersion(io, allocator);
    try std.testing.expect(read_back != null);
    defer allocator.free(read_back.?);
    try std.testing.expectEqualStrings("0.17.0", read_back.?);
}
