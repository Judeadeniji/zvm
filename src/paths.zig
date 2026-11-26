//! Manages ZVM's directory layout (`versions/`, `bin/`, `cache/`, `default`),
//! environment overrides (`ZVM_PATH`, `XDG_DATA_HOME`), and installed version metadata.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const errors = @import("errors.zig");

const PathError = errors.PathError;
pub const PathInitError = errors.PathInitError;

pub const Paths = struct {
    allocator: Allocator,
    base_dir: []const u8,
    versions_dir: []const u8,
    zls_versions_dir: []const u8,
    bin_dir: []const u8,
    cache_dir: []const u8,
    default_file: []const u8,
    zls_default_file: []const u8,

    pub const is_windows = builtin.target.os.tag == .windows;
    pub const zig_exe_name = if (is_windows) "zig.exe" else "zig";
    pub const zls_exe_name = if (is_windows) "zls.exe" else "zls";

    /// Resolves the zvm base directory for a given OS tag using environment overrides:
    /// 1. `custom_base` (if provided)
    /// 2. `ZVM_PATH`
    /// 3. Platform default:
    ///    - Windows: `%LOCALAPPDATA%/zvm` (fallback: `%USERPROFILE%/.zvm`)
    ///    - macOS: `$XDG_DATA_HOME/zvm` (fallback: `$HOME/Library/Application Support/zvm`)
    ///    - Linux/other POSIX: `$XDG_DATA_HOME/zvm` (fallback: `$HOME/.zvm`)
    pub fn resolveBaseDirForOs(
        allocator: Allocator,
        os_tag: std.Target.Os.Tag,
        environ_map: ?*const EnvironMap,
        custom_base: ?[]const u8,
    ) PathInitError![]u8 {
        if (custom_base) |b| return allocator.dupe(u8, b);

        const env = environ_map orelse return PathError.EnvironmentHomeMissing;

        if (getNonEmpty(env, "ZVM_PATH")) |zvm_path| {
            return allocator.dupe(u8, zvm_path);
        }

        switch (os_tag) {
            .windows => {
                if (getNonEmpty(env, "LOCALAPPDATA")) |local_app_data| {
                    return std.fs.path.join(allocator, &.{ local_app_data, "zvm" });
                }
                if (getNonEmpty(env, "USERPROFILE")) |profile| {
                    return std.fs.path.join(allocator, &.{ profile, ".zvm" });
                }
                return PathError.EnvironmentHomeMissing;
            },
            .macos => {
                if (getNonEmpty(env, "XDG_DATA_HOME")) |xdg| {
                    return std.fs.path.join(allocator, &.{ xdg, "zvm" });
                }
                if (getNonEmpty(env, "HOME")) |home| {
                    return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "zvm" });
                }
                return PathError.EnvironmentHomeMissing;
            },
            else => {
                if (getNonEmpty(env, "XDG_DATA_HOME")) |xdg| {
                    return std.fs.path.join(allocator, &.{ xdg, "zvm" });
                }
                if (getNonEmpty(env, "HOME")) |home| {
                    return std.fs.path.join(allocator, &.{ home, ".zvm" });
                }
                return PathError.EnvironmentHomeMissing;
            },
        }
    }

    fn getNonEmpty(env: *const EnvironMap, key: []const u8) ?[]const u8 {
        const val = env.get(key) orelse return null;
        const trimmed = std.mem.trim(u8, val, " \t\r\n");
        if (trimmed.len == 0) return null;
        return trimmed;
    }

    /// Initialize Paths using the host OS's configuration discovery rules.
    pub fn init(allocator: Allocator, environ_map: ?*const EnvironMap, custom_base: ?[]const u8) PathInitError!Paths {
        const base = try resolveBaseDirForOs(allocator, builtin.target.os.tag, environ_map, custom_base);
        errdefer allocator.free(base);

        const versions = try std.fs.path.join(allocator, &.{ base, "versions" });
        errdefer allocator.free(versions);

        const zls_versions = try std.fs.path.join(allocator, &.{ base, "zls-versions" });
        errdefer allocator.free(zls_versions);

        const bin = try std.fs.path.join(allocator, &.{ base, "bin" });
        errdefer allocator.free(bin);

        const cache = try std.fs.path.join(allocator, &.{ base, "cache" });
        errdefer allocator.free(cache);

        const default_f = try std.fs.path.join(allocator, &.{ base, "default" });
        errdefer allocator.free(default_f);

        const zls_default_f = try std.fs.path.join(allocator, &.{ base, "zls-default" });
        errdefer allocator.free(zls_default_f);

        return .{
            .allocator = allocator,
            .base_dir = base,
            .versions_dir = versions,
            .zls_versions_dir = zls_versions,
            .bin_dir = bin,
            .cache_dir = cache,
            .default_file = default_f,
            .zls_default_file = zls_default_f,
        };
    }

    pub fn deinit(self: *Paths) void {
        self.allocator.free(self.base_dir);
        self.allocator.free(self.versions_dir);
        self.allocator.free(self.zls_versions_dir);
        self.allocator.free(self.bin_dir);
        self.allocator.free(self.cache_dir);
        self.allocator.free(self.default_file);
        self.allocator.free(self.zls_default_file);
    }

    /// Creates base, versions, zls-versions, bin, and cache directories if they don't exist.
    pub fn ensureDirs(self: *const Paths, io: Io) !void {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, self.base_dir);
        try cwd.createDirPath(io, self.versions_dir);
        try cwd.createDirPath(io, self.zls_versions_dir);
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

    /// Returns path to the `zig` shim inside `~/.zvm/bin/`.
    pub fn zigShimPath(self: *const Paths, allocator: Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.bin_dir, zig_exe_name });
    }

    /// Returns a list of installed version names found in `versions_dir`.
    /// Caller owns the returned slice and each string (free with `freeInstalledVersions`).
    pub fn listInstalledVersions(self: *const Paths, io: Io, allocator: Allocator) ![][]u8 {
        const cwd = Io.Dir.cwd();
        var v_dir = cwd.openDir(io, self.versions_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return try allocator.alloc([]u8, 0),
            else => return err,
        };
        defer v_dir.close(io);

        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }

        var it = v_dir.iterate();
        while (try it.next(io)) |entry| {
            if (self.isVersionInstalled(io, allocator, entry.name)) {
                try list.append(allocator, try allocator.dupe(u8, entry.name));
            }
        }

        return try list.toOwnedSlice(allocator);
    }

    pub fn freeInstalledVersions(allocator: Allocator, versions: [][]u8) void {
        for (versions) |v| allocator.free(v);
        allocator.free(versions);
    }

    /// Reads the resolved version metadata file (`.zvm-version`) inside a version directory, if present.
    pub fn readVersionMeta(self: *const Paths, io: Io, allocator: Allocator, version: []const u8) !?[]u8 {
        const v_dir = try self.versionDir(allocator, version);
        defer allocator.free(v_dir);
        const meta_path = try std.fs.path.join(allocator, &.{ v_dir, ".zvm-version" });
        defer allocator.free(meta_path);

        var buf: [256]u8 = undefined;
        const bytes = Io.Dir.cwd().readFile(io, meta_path, &buf) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try allocator.dupe(u8, trimmed);
    }

    /// Writes the resolved version metadata file (`.zvm-version`) inside a version directory.
    pub fn writeVersionMeta(self: *const Paths, io: Io, allocator: Allocator, version: []const u8, resolved_version: []const u8) !void {
        const v_dir = try self.versionDir(allocator, version);
        defer allocator.free(v_dir);
        const meta_path = try std.fs.path.join(allocator, &.{ v_dir, ".zvm-version" });
        defer allocator.free(meta_path);

        const payload = try allocator.print("{s}\n", .{resolved_version});
        defer allocator.free(payload);
        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = meta_path,
            .data = payload,
        });
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

    /// Returns path to the directory for a given ZLS-paired Zig version, e.g. ~/.zvm/zls-versions/0.17.0
    pub fn zlsVersionDir(self: *const Paths, allocator: Allocator, zig_version: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.zls_versions_dir, zig_version });
    }

    /// Returns path to the zls executable for a given Zig version, e.g. ~/.zvm/zls-versions/0.17.0/zls
    pub fn zlsVersionBin(self: *const Paths, allocator: Allocator, zig_version: []const u8) ![]u8 {
        const v_dir = try self.zlsVersionDir(allocator, zig_version);
        defer allocator.free(v_dir);
        return std.fs.path.join(allocator, &.{ v_dir, zls_exe_name });
    }

    /// Checks if ZLS is installed for the given Zig version.
    pub fn isZlsInstalled(self: *const Paths, io: Io, allocator: Allocator, zig_version: []const u8) bool {
        const bin_path = self.zlsVersionBin(allocator, zig_version) catch return false;
        defer allocator.free(bin_path);
        Io.Dir.cwd().access(io, bin_path, .{}) catch return false;
        return true;
    }

    /// Returns path to the `zls` shim inside `~/.zvm/bin/`.
    pub fn zlsShimPath(self: *const Paths, allocator: Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.bin_dir, zls_exe_name });
    }

    /// Returns a list of Zig version names that have a paired ZLS installed in `zls_versions_dir`.
    pub fn listInstalledZlsVersions(self: *const Paths, io: Io, allocator: Allocator) ![][]u8 {
        const cwd = Io.Dir.cwd();
        var v_dir = cwd.openDir(io, self.zls_versions_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return try allocator.alloc([]u8, 0),
            else => return err,
        };
        defer v_dir.close(io);

        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }

        var it = v_dir.iterate();
        while (try it.next(io)) |entry| {
            if (self.isZlsInstalled(io, allocator, entry.name)) {
                try list.append(allocator, try allocator.dupe(u8, entry.name));
            }
        }

        return try list.toOwnedSlice(allocator);
    }

    /// Reads the ZLS resolved version metadata (`.zls-version`) inside a ZLS version directory, if present.
    pub fn readZlsVersionMeta(self: *const Paths, io: Io, allocator: Allocator, zig_version: []const u8) !?[]u8 {
        const v_dir = try self.zlsVersionDir(allocator, zig_version);
        defer allocator.free(v_dir);
        const meta_path = try std.fs.path.join(allocator, &.{ v_dir, ".zls-version" });
        defer allocator.free(meta_path);

        var buf: [256]u8 = undefined;
        const bytes = Io.Dir.cwd().readFile(io, meta_path, &buf) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try allocator.dupe(u8, trimmed);
    }

    /// Writes the ZLS resolved version metadata (`.zls-version`) inside a ZLS version directory.
    pub fn writeZlsVersionMeta(self: *const Paths, io: Io, allocator: Allocator, zig_version: []const u8, zls_version: []const u8) !void {
        const v_dir = try self.zlsVersionDir(allocator, zig_version);
        defer allocator.free(v_dir);
        const meta_path = try std.fs.path.join(allocator, &.{ v_dir, ".zls-version" });
        defer allocator.free(meta_path);

        const payload = try allocator.print("{s}\n", .{zls_version});
        defer allocator.free(payload);
        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = meta_path,
            .data = payload,
        });
    }

    /// Reads the global default ZLS version (by paired Zig version) from `~/.zvm/zls-default`, or null if unset.
    pub fn readZlsDefaultVersion(self: *const Paths, io: Io, allocator: Allocator) !?[]u8 {
        const cwd = Io.Dir.cwd();
        var buf: [256]u8 = undefined;
        const bytes = cwd.readFile(io, self.zls_default_file, &buf) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try allocator.dupe(u8, trimmed);
    }

    /// Sets the global default ZLS version (by paired Zig version) in `~/.zvm/zls-default`.
    pub fn writeZlsDefaultVersion(self: *const Paths, io: Io, zig_version: []const u8) !void {
        try self.ensureDirs(io);
        const payload = try self.allocator.print("{s}\n", .{zig_version});
        defer self.allocator.free(payload);
        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = self.zls_default_file,
            .data = payload,
        });
    }

    /// Checks whether a persistent boolean marker file (e.g. `auto-install`, `exact`) exists.
    pub fn isMarkerSet(self: *const Paths, io: Io, name: []const u8) bool {
        const marker_path = std.fs.path.join(self.allocator, &.{ self.base_dir, name }) catch return false;
        defer self.allocator.free(marker_path);
        Io.Dir.cwd().access(io, marker_path, .{}) catch return false;
        return true;
    }

    /// Creates or removes a persistent boolean marker file inside `base_dir`.
    pub fn setMarker(self: *const Paths, io: Io, name: []const u8, enabled: bool) !void {
        const marker_path = try std.fs.path.join(self.allocator, &.{ self.base_dir, name });
        defer self.allocator.free(marker_path);

        const cwd = Io.Dir.cwd();
        if (enabled) {
            try self.ensureDirs(io);
            try cwd.writeFile(io, .{ .sub_path = marker_path, .data = "" });
        } else {
            cwd.deleteFile(io, marker_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
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
    // Use platform-native separator so this passes on both POSIX and Windows.
    try std.testing.expect(std.mem.endsWith(u8, v_dir, "versions" ++ std.fs.path.sep_str ++ "0.17.0"));

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

test "resolveBaseDirForOs platform discovery" {
    const allocator = std.testing.allocator;

    var env = EnvironMap.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/alice");
    try env.put("USERPROFILE", "C:/Users/alice");

    // Linux fallback to ~/.zvm when XDG_DATA_HOME unset
    const linux_default = try Paths.resolveBaseDirForOs(allocator, .linux, &env, null);
    defer allocator.free(linux_default);
    // Normalize to forward slashes: std.fs.path.join uses the host separator,
    // so on Windows this would produce backslashes even for a .linux os_tag.
    std.mem.replaceScalar(u8, linux_default, '\\', '/');
    try std.testing.expectEqualStrings("/home/alice/.zvm", linux_default);

    // macOS Application Support
    const mac_default = try Paths.resolveBaseDirForOs(allocator, .macos, &env, null);
    defer allocator.free(mac_default);
    std.mem.replaceScalar(u8, mac_default, '\\', '/');
    try std.testing.expectEqualStrings("/home/alice/Library/Application Support/zvm", mac_default);

    // Windows USERPROFILE fallback then LOCALAPPDATA
    const win_fallback = try Paths.resolveBaseDirForOs(allocator, .windows, &env, null);
    defer allocator.free(win_fallback);
    std.mem.replaceScalar(u8, win_fallback, '\\', '/');
    try std.testing.expectEqualStrings("C:/Users/alice/.zvm", win_fallback);

    try env.put("LOCALAPPDATA", "C:/Users/alice/AppData/Local");
    const win_local = try Paths.resolveBaseDirForOs(allocator, .windows, &env, null);
    defer allocator.free(win_local);
    std.mem.replaceScalar(u8, win_local, '\\', '/');
    try std.testing.expectEqualStrings("C:/Users/alice/AppData/Local/zvm", win_local);

    // XDG_DATA_HOME overrides Linux and macOS
    try env.put("XDG_DATA_HOME", "/home/alice/.local/share");
    const linux_xdg = try Paths.resolveBaseDirForOs(allocator, .linux, &env, null);
    defer allocator.free(linux_xdg);
    std.mem.replaceScalar(u8, linux_xdg, '\\', '/');
    try std.testing.expectEqualStrings("/home/alice/.local/share/zvm", linux_xdg);

    // ZVM_PATH overrides everything except custom_base
    try env.put("ZVM_PATH", "/opt/zvm");
    const zvm_override = try Paths.resolveBaseDirForOs(allocator, .linux, &env, null);
    defer allocator.free(zvm_override);
    std.mem.replaceScalar(u8, zvm_override, '\\', '/');
    try std.testing.expectEqualStrings("/opt/zvm", zvm_override);
}
