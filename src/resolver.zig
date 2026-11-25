//! Context-aware version resolution traversing `ZIG_VERSION`, ancestor `.zig-version`
//! and `build.zig.zon` files, and the global default configuration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const errors = @import("errors.zig");
const Paths = @import("paths.zig").Paths;
const version_mod = @import("version.zig");
const Version = version_mod.Version;
const Constraint = version_mod.Constraint;

pub const ResolveError = errors.ResolveError;

pub const ResolutionSource = enum {
    env_var,
    zig_version_file,
    build_zig_zon,
    global_default,
};

pub const ResolvedVersion = struct {
    version: []const u8,
    source: ResolutionSource,
    source_path: ?[]const u8 = null,

    pub fn deinit(self: *ResolvedVersion, allocator: Allocator) void {
        allocator.free(self.version);
        if (self.source_path) |p| allocator.free(p);
    }
};

/// Parse the `.minimum_zig_version` string from a `build.zig.zon` buffer.
pub fn parseMinimumZigVersionFromZon(content: []const u8) ?[]const u8 {
    const key = ".minimum_zig_version";
    const idx = std.mem.indexOf(u8, content, key) orelse return null;
    const rest = content[idx + key.len ..];
    const eq_idx = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    const after_eq = rest[eq_idx + 1 ..];
    const quote_idx = std.mem.indexOfScalar(u8, after_eq, '"') orelse return null;
    const val_start = after_eq[quote_idx + 1 ..];
    const end_quote = std.mem.indexOfScalar(u8, val_start, '"') orelse return null;
    return val_start[0..end_quote];
}

/// Walks parent directories from `start_dir` to find `.minimum_zig_version` in `build.zig.zon`.
pub fn findProjectMinimumVersion(io: Io, allocator: Allocator, start_dir: []const u8) !?[]u8 {
    var current_dir = try allocator.dupe(u8, start_dir);
    defer allocator.free(current_dir);

    const cwd = Io.Dir.cwd();
    while (true) {
        const zon_path = try std.fs.path.join(allocator, &.{ current_dir, "build.zig.zon" });
        defer allocator.free(zon_path);

        var zon_buf: [8192]u8 = undefined;
        if (cwd.readFile(io, zon_path, &zon_buf)) |zon_bytes| {
            if (parseMinimumZigVersionFromZon(zon_bytes)) |min_str| {
                return try allocator.dupe(u8, min_str);
            }
        } else |_| {}

        const parent = std.fs.path.dirname(current_dir);
        if (parent == null or std.mem.eql(u8, parent.?, current_dir)) break;

        const next_parent = try allocator.dupe(u8, parent.?);
        allocator.free(current_dir);
        current_dir = next_parent;
    }
    return null;
}

/// Find the highest installed version that satisfies the given constraint.
pub fn findHighestMatchingInstalled(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    constraint: Constraint,
) !?[]u8 {
    const cwd = Io.Dir.cwd();
    var v_dir = cwd.openDir(io, paths.versions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer v_dir.close(io);

    var it = v_dir.iterate();
    var best_ver: ?Version = null;
    var best_name: ?[]u8 = null;
    errdefer if (best_name) |b| allocator.free(b);

    while (try it.next(io)) |entry| {
        if (!paths.isVersionInstalled(io, allocator, entry.name)) continue;

        const parsed = Version.parse(entry.name) catch continue;
        if (!constraint.satisfies(parsed)) continue;

        if (best_ver == null or parsed.order(best_ver.?) == .gt) {
            best_ver = parsed;
            if (best_name) |old| allocator.free(old);
            best_name = try allocator.dupe(u8, entry.name);
        }
    }

    return best_name;
}

/// Find the highest installed version that satisfies the given minimum required version.
pub fn findHighestSatisfyingInstalled(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    min_ver: Version,
) !?[]u8 {
    return findHighestMatchingInstalled(paths, io, allocator, Constraint.gte(min_ver));
}

/// Resolves the Zig version following the resolution hierarchy:
/// 1. ZIG_VERSION env var
/// 2. Directory walk-up:
///    a. .zig-version file
///    b. build.zig.zon minimum_zig_version
/// 3. Global default (~/.zvm/default)
pub fn resolve(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    start_dir: []const u8,
) ResolveError!ResolvedVersion {
    // 1. Environment variable override
    if (environ_map) |env| {
        if (env.get("ZIG_VERSION")) |zig_env| {
            const trimmed = std.mem.trim(u8, zig_env, " \t\r\n");
            if (trimmed.len > 0) {
                return .{
                    .version = try allocator.dupe(u8, trimmed),
                    .source = .env_var,
                    .source_path = null,
                };
            }
        }
    }

    // 2. Ancestor directory walk-up
    var current_dir = try allocator.dupe(u8, start_dir);
    defer allocator.free(current_dir);

    const cwd = Io.Dir.cwd();

    while (true) {
        // 2a. Check for .zig-version
        const zig_version_path = try std.fs.path.join(allocator, &.{ current_dir, ".zig-version" });
        defer allocator.free(zig_version_path);

        var buf: [256]u8 = undefined;
        if (cwd.readFile(io, zig_version_path, &buf)) |bytes| {
            const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
            if (trimmed.len > 0) {
                const constraint = Constraint.parse(trimmed) catch null;
                if (constraint) |c| {
                    if (c.exactPin()) |exact| {
                        return .{
                            .version = try exact.toString(allocator),
                            .source = .zig_version_file,
                            .source_path = try allocator.dupe(u8, zig_version_path),
                        };
                    }
                    if (try findHighestMatchingInstalled(paths, io, allocator, c)) |matched| {
                        return .{
                            .version = matched,
                            .source = .zig_version_file,
                            .source_path = try allocator.dupe(u8, zig_version_path),
                        };
                    }
                    return ResolveError.NoCompatibleVersionInstalled;
                }
                return .{
                    .version = try allocator.dupe(u8, trimmed),
                    .source = .zig_version_file,
                    .source_path = try allocator.dupe(u8, zig_version_path),
                };
            }
        } else |_| {}

        // 2b. Check for build.zig.zon
        const zon_path = try std.fs.path.join(allocator, &.{ current_dir, "build.zig.zon" });
        defer allocator.free(zon_path);

        var zon_buf: [8192]u8 = undefined;
        if (cwd.readFile(io, zon_path, &zon_buf)) |zon_bytes| {
            if (parseMinimumZigVersionFromZon(zon_bytes)) |min_str| {
                const min_ver = Version.parse(min_str) catch null;
                if (min_ver) |mv| {
                    if (try findHighestSatisfyingInstalled(paths, io, allocator, mv)) |matched| {
                        return .{
                            .version = matched,
                            .source = .build_zig_zon,
                            .source_path = try allocator.dupe(u8, zon_path),
                        };
                    } else {
                        return ResolveError.NoCompatibleVersionInstalled;
                    }
                }
            }
        } else |_| {}

        // Walk to parent directory
        const parent = std.fs.path.dirname(current_dir);
        if (parent == null or std.mem.eql(u8, parent.?, current_dir)) {
            break;
        }

        const next_parent = try allocator.dupe(u8, parent.?);
        allocator.free(current_dir);
        current_dir = next_parent;
    }

    // 3. Global default
    if (try paths.readDefaultVersion(io, allocator)) |def_v| {
        return .{
            .version = def_v,
            .source = .global_default,
            .source_path = try allocator.dupe(u8, paths.default_file),
        };
    }

    return ResolveError.NoVersionConfigured;
}

test "parseMinimumZigVersionFromZon" {
    const zon =
        \\.{
        \\    .name = .zvm,
        \\    .version = "0.0.0",
        \\    .minimum_zig_version = "0.17.0",
        \\    .dependencies = .{},
        \\}
    ;
    const min_v = parseMinimumZigVersionFromZon(zon);
    try std.testing.expect(min_v != null);
    try std.testing.expectEqualStrings("0.17.0", min_v.?);
}

test "resolve hierarchy env override" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var paths = try Paths.init(allocator, null, "/tmp/zvm_test_resolve");
    defer paths.deinit();

    var env_map = EnvironMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("ZIG_VERSION", "0.17.0");

    var resolved = try resolve(&paths, io, allocator, &env_map, "/tmp");
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("0.17.0", resolved.version);
    try std.testing.expectEqual(ResolutionSource.env_var, resolved.source);
    try std.testing.expectEqual(@as(?[]const u8, null), resolved.source_path);
}

test "resolve hierarchy .zig-version file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    // Create a sub project directory
    const project_dir = try std.fs.path.join(allocator, &.{ tmp_path, "sub_proj" });
    defer allocator.free(project_dir);
    try Io.Dir.cwd().createDirPath(io, project_dir);

    // Write .zig-version in parent
    const zv_file = try std.fs.path.join(allocator, &.{ tmp_path, ".zig-version" });
    defer allocator.free(zv_file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zv_file, .data = "0.16.0\n" });

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();

    // Resolving from sub_proj should find parent's .zig-version
    var resolved = try resolve(&paths, io, allocator, null, project_dir);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("0.16.0", resolved.version);
    try std.testing.expectEqual(ResolutionSource.zig_version_file, resolved.source);
}

test "resolve hierarchy .zig-version semver constraint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    // Install fake 0.16.0, 0.17.0, 0.17.1, 0.18.0 binaries
    for ([_][]const u8{ "0.16.0", "0.17.0", "0.17.1", "0.18.0" }) |ver| {
        const v_dir = try paths.versionDir(allocator, ver);
        defer allocator.free(v_dir);
        try Io.Dir.cwd().createDirPath(io, v_dir);

        const bin_path = try paths.versionZigBin(allocator, ver);
        defer allocator.free(bin_path);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = "zig" });
    }

    const zv_file = try std.fs.path.join(allocator, &.{ tmp_path, ".zig-version" });
    defer allocator.free(zv_file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zv_file, .data = "^0.17.0\n" });

    var resolved = try resolve(&paths, io, allocator, null, tmp_path);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("0.17.1", resolved.version);
    try std.testing.expectEqual(ResolutionSource.zig_version_file, resolved.source);
}
