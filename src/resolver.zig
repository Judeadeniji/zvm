//! Context-aware version resolution traversing `ZIG_VERSION`, ancestor `.zig-version`
//! and `build.zig.zon` files, and the global default configuration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const errors = @import("errors.zig");
const Paths = @import("paths.zig").Paths;
const env_flags = @import("env_flags.zig");
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
    /// First `build.zig.zon` the walk found that `std.zon.parse` rejected, so the
    /// caller can warn that its `minimum_zig_version` was ignored.
    malformed_zon_path: ?[]const u8 = null,

    pub fn deinit(self: *ResolvedVersion, allocator: Allocator) void {
        allocator.free(self.version);
        if (self.source_path) |p| allocator.free(p);
        if (self.malformed_zon_path) |p| allocator.free(p);
    }
};

/// Builds a `ResolvedVersion`, taking ownership of `version` and freeing it again
/// if copying the optional `source_path` fails.
fn makeResolved(
    allocator: Allocator,
    version: []u8,
    source: ResolutionSource,
    source_path: ?[]const u8,
) Allocator.Error!ResolvedVersion {
    errdefer allocator.free(version);
    return .{
        .version = version,
        .source = source,
        .source_path = if (source_path) |p| try allocator.dupe(u8, p) else null,
    };
}

pub const ResolveOptions = struct {
    /// Overrides `ZVM_EXACT` for this resolution. `null` leaves the environment
    /// variable in charge.
    exact: ?bool = null,
};

fn exactEnabled(paths: *const Paths, io: Io, options: ResolveOptions, environ_map: ?*const EnvironMap) bool {
    if (options.exact) |exact| return exact;
    if (env_flags.boolOverride(environ_map, "ZVM_EXACT")) |overridden| return overridden;
    return paths.isMarkerSet(io, "exact");
}

pub const ZonExtract = struct {
    /// Owned `.minimum_zig_version` value, or null when the manifest has none.
    version: ?[]u8 = null,
    /// `std.zon.parse` rejected the manifest, so the textual fallback produced
    /// the result (if any). Resolution can continue either way, but a rejected
    /// manifest is worth reporting.
    malformed: bool = false,
};

/// Extracts `.minimum_zig_version` from a `build.zig.zon` buffer.
///
/// Uses the real zon parser so comments, inline manifests, and nested tables are
/// handled exactly like `zig build` does. If the manifest cannot be parsed at
/// all, falls back to the textual scan below and flags the result as malformed:
/// reporting it is the caller's decision, because ancestor directories may not
/// belong to this project.
pub fn extractMinimumZigVersion(allocator: Allocator, content: []const u8) Allocator.Error!ZonExtract {
    var malformed = false;
    if (try parseMinimumZigVersionStructured(allocator, content, &malformed)) |version| {
        return .{ .version = version, .malformed = malformed };
    }

    const scanned = parseMinimumZigVersionFromZon(content) orelse return .{ .malformed = malformed };
    return .{ .version = try allocator.dupe(u8, scanned), .malformed = malformed };
}

const ZonPackage = struct {
    minimum_zig_version: ?[]const u8 = null,
};

/// Returns a human-readable diagnostic when `build.zig.zon` content cannot be
/// parsed, or null when it parses cleanly. Used by `zvm doctor` to explain why
/// a project pin is being ignored.
pub fn manifestErrorText(allocator: Allocator, content: []const u8) Allocator.Error!?[]u8 {
    const source = try allocator.allocSentinel(u8, content.len, 0);
    defer allocator.free(source);
    @memcpy(source, content);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    _ = std.zon.parse.fromSlice(ZonPackage, .{
        .gpa = allocator,
        .arena = arena_state.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return try allocator.print("{f}", .{diagnostics.fmt("build.zig.zon")}),
    };

    return null;
}

fn parseMinimumZigVersionStructured(
    allocator: Allocator,
    content: []const u8,
    malformed: *bool,
) Allocator.Error!?[]u8 {
    // The zon parser requires a sentinel-terminated source.
    const source = try allocator.allocSentinel(u8, content.len, 0);
    defer allocator.free(source);
    @memcpy(source, content);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const package = std.zon.parse.fromSlice(ZonPackage, .{
        .gpa = allocator,
        .arena = arena_state.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            malformed.* = true;
            return null;
        },
    };

    const raw = package.minimum_zig_version orelse return null;
    // Parsed strings live in the arena above, so copy before returning.
    return try allocator.dupe(u8, raw);
}

/// Textual fallback for manifests `std.zon.parse` rejects.
///
/// Commented-out declarations are ignored, so a stale `// .minimum_zig_version`
/// line never wins over the real field (or substitutes for a missing one).
pub fn parseMinimumZigVersionFromZon(content: []const u8) ?[]const u8 {
    const key = ".minimum_zig_version";

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = stripLineComment(raw_line);
        const idx = std.mem.indexOf(u8, line, key) orelse continue;

        const rest = std.mem.trimStart(u8, line[idx + key.len ..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;

        const after_eq = std.mem.trimStart(u8, rest[1..], " \t");
        if (after_eq.len == 0 or after_eq[0] != '"') continue;

        const val_start = after_eq[1..];
        const end_quote = std.mem.indexOfScalar(u8, val_start, '"') orelse continue;
        return val_start[0..end_quote];
    }
    return null;
}

/// Drops a trailing `//` comment from a manifest line, ignoring `//` inside a
/// quoted string.
fn stripLineComment(line: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
        } else if (c == '"') {
            in_string = true;
        } else if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            return line[0..i];
        }
    }
    return line;
}

/// Upper bound for reading `build.zig.zon`; manifests with many dependencies can
/// easily exceed a stack buffer, and a truncated manifest silently hides the pin.
const max_zon_bytes = 1024 * 1024;

/// Upper bound for `.zig-version`; anything larger is not a version string.
const max_zig_version_bytes = 64 * 1024;

/// Formats `dir` + separator + `name` into `buf`, or returns null when it does
/// not fit. Avoids heap-joining candidate paths on every ancestor level.
fn appendName(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, name }) catch null;
}

/// Whether a repository root sits strictly between `start_dir` and `found_dir`, the
/// level holding a config file. A `.zig-version` or manifest above that root belongs
/// to an enclosing repository, not to this project.
///
/// `found_dir` must be `start_dir` or one of its ancestors; both are prefixes of the
/// same path buffer, so the walk compares lengths instead of rebuilding paths.
///
/// Checked only once a config was found: probing `.git` on every ancestor made a
/// path with no config pay a lookup per level, and that path always falls through to
/// the global default regardless of a repository boundary.
fn crossedRepositoryRoot(io: Io, start_dir: []const u8, found_dir: []const u8) bool {
    const cwd = Io.Dir.cwd();
    // Own buffer: callers still hold slices of their own path buffer for the
    // config file they just found.
    var git_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    // Ascend from the start directory towards `found_dir`; the found level itself is
    // a valid home for a config, so it is never probed.
    var current = start_dir;
    while (std.fs.path.dirname(current)) |parent| {
        if (parent.len <= found_dir.len) return false;
        const git_path = appendName(&git_buf, parent, ".git") orelse return false;
        cwd.access(io, git_path, .{}) catch {
            current = parent;
            continue;
        };
        return true;
    }
    return false;
}

/// State for walking `start_dir` and its ancestors, one level at a time.
///
/// The path lives in one owned buffer that a parent step only shortens, so a walk
/// costs no allocations per level. Candidate files are still probed by full path:
/// keeping an open directory handle and probing short names instead was measured
/// slower, because opening `..` costs a third syscall per level and the extra work
/// is syscalls, not path resolution (see `AUDIT.md`).
const AncestorWalk = struct {
    /// Full path of the current level; truncated in place when moving up.
    path_buf: []u8,
    path_len: usize,

    fn init(allocator: Allocator, start_dir: []const u8) !AncestorWalk {
        const path_buf = try allocator.alloc(u8, start_dir.len);
        @memcpy(path_buf, start_dir);
        return .{ .path_buf = path_buf, .path_len = start_dir.len };
    }

    fn deinit(self: *AncestorWalk, allocator: Allocator) void {
        allocator.free(self.path_buf);
    }

    fn path(self: *const AncestorWalk) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Moves to the parent directory. Returns false when the walk is over.
    fn toParent(self: *AncestorWalk) bool {
        const current = self.path();
        const parent = std.fs.path.dirname(current) orelse return false;
        if (parent.len == 0 or std.mem.eql(u8, parent, current)) return false;
        // `dirname` returns a prefix of the input; verify before reusing its length.
        if (!std.mem.eql(u8, self.path_buf[0..parent.len], parent)) return false;
        self.path_len = parent.len;
        return true;
    }
};

/// Walks parent directories from `start_dir` to find `.minimum_zig_version` in `build.zig.zon`.
pub fn findProjectMinimumVersion(io: Io, allocator: Allocator, start_dir: []const u8) !?[]u8 {
    var walk = try AncestorWalk.init(allocator, start_dir);
    defer walk.deinit(allocator);

    const cwd = Io.Dir.cwd();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;

    while (true) {
        const zon_path = appendName(&path_buf, walk.path(), "build.zig.zon") orelse break;
        const zon_bytes: ?[]u8 = cwd.readFileAlloc(io, zon_path, allocator, .limited(max_zon_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (zon_bytes) |bytes| allocator.free(bytes);
        if (zon_bytes) |bytes| {
            if (crossedRepositoryRoot(io, start_dir, walk.path())) return null;
            const extracted = try extractMinimumZigVersion(allocator, bytes);
            if (extracted.version) |min_str| return min_str;
        }

        if (!walk.toParent()) break;
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

    // Check the binary relative to the already-open directory: rebuilding an
    // absolute path per candidate allocated twice on every installed version. The
    // cheap parse runs first, so the lookup happens only for a version that could
    // actually become the result.
    var bin_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    while (try it.next(io)) |entry| {
        const parsed = Version.parse(entry.name) catch continue;
        if (!constraint.satisfies(parsed)) continue;
        if (best_ver) |best| {
            if (parsed.order(best) != .gt) continue;
        }

        const bin_rel = std.fmt.bufPrint(&bin_buf, "{s}{c}{s}", .{
            entry.name,
            std.fs.path.sep,
            Paths.zig_exe_name,
        }) catch continue;
        v_dir.access(io, bin_rel, .{}) catch continue;

        best_ver = parsed;
        // Allocate the replacement before freeing the old name so a failed
        // allocation leaves `best_name` valid for the `errdefer` above.
        const replacement = try allocator.dupe(u8, entry.name);
        if (best_name) |old| allocator.free(old);
        best_name = replacement;
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
    return resolveWithOptions(paths, io, allocator, environ_map, start_dir, .{});
}

/// Like `resolve`, but callers may override exact mode. When `options.exact` is
/// null, `ZVM_EXACT` is honored. Exact mode treats `minimum_zig_version` as an
/// exact requirement instead of a lower bound.
pub fn resolveWithOptions(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    start_dir: []const u8,
    options: ResolveOptions,
) ResolveError!ResolvedVersion {
    var malformed_zon: ?[]u8 = null;
    errdefer if (malformed_zon) |p| allocator.free(p);

    var resolved = try resolveWalk(paths, io, allocator, environ_map, start_dir, options, &malformed_zon);
    resolved.malformed_zon_path = malformed_zon;
    return resolved;
}

fn resolveWalk(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    start_dir: []const u8,
    options: ResolveOptions,
    malformed_zon: *?[]u8,
) ResolveError!ResolvedVersion {
    const exact = exactEnabled(paths, io, options, environ_map);

    // 1. Environment variable override
    if (environ_map) |env| {
        if (env.get("ZIG_VERSION")) |zig_env| {
            const trimmed = std.mem.trim(u8, zig_env, " \t\r\n");
            if (trimmed.len > 0) {
                return makeResolved(allocator, try allocator.dupe(u8, trimmed), .env_var, null);
            }
        }
    }

    // 2. Ancestor directory walk-up. The path is carried in one owned buffer that a
    // parent step only shortens, and candidate paths are formatted into a stack
    // buffer, so a level without a config file allocates nothing.
    var walk = try AncestorWalk.init(allocator, start_dir);
    defer walk.deinit(allocator);

    const cwd = Io.Dir.cwd();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;

    while (true) {
        // 2a. Check for .zig-version
        if (appendName(&path_buf, walk.path(), ".zig-version")) |zig_version_path| {
            const zig_version_text: ?[]u8 = cwd.readFileAlloc(io, zig_version_path, allocator, .limited(max_zig_version_bytes)) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            defer if (zig_version_text) |text| allocator.free(text);
            if (zig_version_text) |text| {
                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                if (trimmed.len > 0) {
                    // A pin above the repository root belongs to an enclosing project.
                    if (crossedRepositoryRoot(io, start_dir, walk.path())) break;
                    // A `.zig-version` file is authoritative: an unparseable file must be
                    // reported, never treated as a version name or silently skipped.
                    const constraint = Constraint.parse(trimmed) catch
                        return ResolveError.InvalidZigVersionConstraint;

                    if (constraint.exactPin()) |exact_pin| {
                        return makeResolved(
                            allocator,
                            try exact_pin.toString(allocator),
                            .zig_version_file,
                            zig_version_path,
                        );
                    }
                    if (try findHighestMatchingInstalled(paths, io, allocator, constraint)) |matched| {
                        return makeResolved(allocator, matched, .zig_version_file, zig_version_path);
                    }
                    return ResolveError.UnmatchedZigVersionConstraint;
                }
            }
        }

        // 2b. Check for build.zig.zon
        if (appendName(&path_buf, walk.path(), "build.zig.zon")) |zon_path| {
            const zon_text: ?[]u8 = cwd.readFileAlloc(io, zon_path, allocator, .limited(max_zon_bytes)) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            defer if (zon_text) |text| allocator.free(text);
            if (zon_text) |zon_bytes| {
                if (crossedRepositoryRoot(io, start_dir, walk.path())) break;
                const extracted = try extractMinimumZigVersion(allocator, zon_bytes);
                defer if (extracted.version) |s| allocator.free(s);
                // Report the first rejected manifest even when the fallback scan
                // still recovers the version: `zig build` will reject it too.
                if (extracted.malformed and malformed_zon.* == null) {
                    malformed_zon.* = try allocator.dupe(u8, zon_path);
                }
                if (extracted.version) |min_str| {
                    const min_ver = Version.parse(min_str) catch null;
                    if (min_ver) |mv| {
                        if (exact) {
                            // Return the declared version even when it is not installed;
                            // `zvm current` can report it and the router can install it.
                            return makeResolved(
                                allocator,
                                try mv.toString(allocator),
                                .build_zig_zon,
                                zon_path,
                            );
                        }
                        if (try findHighestSatisfyingInstalled(paths, io, allocator, mv)) |matched| {
                            return makeResolved(allocator, matched, .build_zig_zon, zon_path);
                        } else {
                            return ResolveError.NoCompatibleVersionInstalled;
                        }
                    }
                }
            }
        }

        if (!walk.toParent()) break;
    }

    // 3. Global default
    if (try paths.readDefaultVersion(io, allocator)) |def_v| {
        return makeResolved(allocator, def_v, .global_default, paths.default_file);
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

test "manifestErrorText reports diagnostics only for unparseable manifests" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(
        @as(?[]u8, null),
        try manifestErrorText(allocator, ".{ .name = .zvm, .paths = .{ \"a\" } }"),
    );

    const broken =
        \\.{
        \\    .name = .zvm,
        \\    .paths = .{ "build.zig"
        \\}
    ;
    const message = (try manifestErrorText(allocator, broken)).?;
    defer allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "build.zig.zon") != null);
    try std.testing.expect(message.len > 0);
}

test "extractMinimumZigVersion parses real manifests and returns owned memory" {
    const allocator = std.testing.allocator;

    const zon =
        \\.{
        \\    .name = .zvm,
        \\    .version = "0.0.0",
        \\    .fingerprint = 0xec41f7018f55b9e5,
        \\    // .minimum_zig_version = "0.10.0",
        \\    .minimum_zig_version = "0.17.0",
        \\    .dependencies = .{
        \\        .zli = .{ .url = "https://example.com/zli.tar.gz", .hash = "h", .lazy = true },
        \\    },
        \\    .paths = .{ "build.zig", "src" },
        \\}
    ;

    const extracted = try extractMinimumZigVersion(allocator, zon);
    const value = extracted.version.?;
    defer allocator.free(value);
    try std.testing.expectEqualStrings("0.17.0", value);
    try std.testing.expect(!extracted.malformed);

    try std.testing.expectEqual(
        @as(?[]u8, null),
        (try extractMinimumZigVersion(allocator, ".{ .name = .zvm, .paths = .{ \"a\" } }")).version,
    );
}

test "extractMinimumZigVersion falls back to the scan for unparseable manifests" {
    const allocator = std.testing.allocator;

    // Missing the closing brace of `.paths`, so the realistic parser rejects it.
    const broken =
        \\.{
        \\    .minimum_zig_version = "0.16.0",
        \\    .paths = .{ "build.zig"
        \\}
    ;

    const extracted = try extractMinimumZigVersion(allocator, broken);
    const value = extracted.version.?;
    defer allocator.free(value);
    try std.testing.expectEqualStrings("0.16.0", value);
    try std.testing.expect(extracted.malformed);
}

test "parseMinimumZigVersionFromZon ignores commented-out declarations" {
    const zon =
        \\.{
        \\    .name = .zvm,
        \\    // .minimum_zig_version = "0.10.0",
        \\    .version = "0.0.0",
        \\    .minimum_zig_version = "0.17.0",
        \\}
    ;
    try std.testing.expectEqualStrings("0.17.0", parseMinimumZigVersionFromZon(zon).?);

    const only_commented =
        \\.{
        \\    // .minimum_zig_version = "0.10.0",
        \\    .name = .zvm,
        \\}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseMinimumZigVersionFromZon(only_commented));
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

test "resolve hierarchy stops the walk at the repository root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    for ([_][]const u8{ "0.12.0", "0.13.0" }) |ver| {
        const v_dir = try paths.versionDir(allocator, ver);
        defer allocator.free(v_dir);
        try Io.Dir.cwd().createDirPath(io, v_dir);

        const bin_path = try paths.versionZigBin(allocator, ver);
        defer allocator.free(bin_path);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = "zig" });
    }
    try paths.writeDefaultVersion(io, "0.13.0");

    const repo_dir = try std.fs.path.join(allocator, &.{ tmp_path, "repo" });
    defer allocator.free(repo_dir);
    const project_dir = try std.fs.path.join(allocator, &.{ repo_dir, "sub", "deep" });
    defer allocator.free(project_dir);
    try Io.Dir.cwd().createDirPath(io, project_dir);

    const git_dir = try std.fs.path.join(allocator, &.{ repo_dir, ".git" });
    defer allocator.free(git_dir);
    try Io.Dir.cwd().createDirPath(io, git_dir);

    // A pin above the repository root belongs to an enclosing project.
    const outer_pin = try std.fs.path.join(allocator, &.{ tmp_path, ".zig-version" });
    defer allocator.free(outer_pin);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = outer_pin, .data = "0.12.0\n" });

    var resolved = try resolve(&paths, io, allocator, null, project_dir);
    defer resolved.deinit(allocator);
    try std.testing.expectEqualStrings("0.13.0", resolved.version);
    try std.testing.expectEqual(ResolutionSource.global_default, resolved.source);

    // A pin at the repository root itself still applies.
    const repo_pin = try std.fs.path.join(allocator, &.{ repo_dir, ".zig-version" });
    defer allocator.free(repo_pin);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = repo_pin, .data = "0.12.0\n" });

    var from_repo = try resolve(&paths, io, allocator, null, project_dir);
    defer from_repo.deinit(allocator);
    try std.testing.expectEqualStrings("0.12.0", from_repo.version);
    try std.testing.expectEqual(ResolutionSource.zig_version_file, from_repo.source);
}

test "resolve hierarchy treats a vendored repository as its own root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    for ([_][]const u8{ "0.12.0", "0.13.0", "0.14.0" }) |ver| {
        const v_dir = try paths.versionDir(allocator, ver);
        defer allocator.free(v_dir);
        try cwd.createDirPath(io, v_dir);

        const bin_path = try paths.versionZigBin(allocator, ver);
        defer allocator.free(bin_path);
        try cwd.writeFile(io, .{ .sub_path = bin_path, .data = "zig" });
    }
    try paths.writeDefaultVersion(io, "0.14.0");

    // A monorepo with its own repository root and pin.
    const mono_dir = try std.fs.path.join(allocator, &.{ tmp_path, "mono" });
    defer allocator.free(mono_dir);
    const mono_git = try std.fs.path.join(allocator, &.{ mono_dir, ".git" });
    defer allocator.free(mono_git);
    try cwd.createDirPath(io, mono_git);
    const mono_pin = try std.fs.path.join(allocator, &.{ mono_dir, ".zig-version" });
    defer allocator.free(mono_pin);
    try cwd.writeFile(io, .{ .sub_path = mono_pin, .data = "0.12.0\n" });

    // A vendored checkout inside the monorepo, which is a repository of its own.
    const dep_dir = try std.fs.path.join(allocator, &.{ mono_dir, "third_party", "dep" });
    defer allocator.free(dep_dir);
    const dep_git = try std.fs.path.join(allocator, &.{ dep_dir, ".git" });
    defer allocator.free(dep_git);
    try cwd.createDirPath(io, dep_git);
    const dep_src = try std.fs.path.join(allocator, &.{ dep_dir, "src" });
    defer allocator.free(dep_src);
    try cwd.createDirPath(io, dep_src);

    // The vendored checkout without a pin does not inherit the monorepo pin.
    {
        var resolved = try resolve(&paths, io, allocator, null, dep_src);
        defer resolved.deinit(allocator);
        try std.testing.expectEqualStrings("0.14.0", resolved.version);
        try std.testing.expectEqual(ResolutionSource.global_default, resolved.source);
    }

    // Its own pin wins over the monorepo pin.
    const dep_pin = try std.fs.path.join(allocator, &.{ dep_dir, ".zig-version" });
    defer allocator.free(dep_pin);
    try cwd.writeFile(io, .{ .sub_path = dep_pin, .data = "0.13.0\n" });
    {
        var resolved = try resolve(&paths, io, allocator, null, dep_src);
        defer resolved.deinit(allocator);
        try std.testing.expectEqualStrings("0.13.0", resolved.version);
        try std.testing.expectEqual(ResolutionSource.zig_version_file, resolved.source);
    }

    // Code elsewhere in the monorepo still gets the monorepo pin.
    const mono_src = try std.fs.path.join(allocator, &.{ mono_dir, "src" });
    defer allocator.free(mono_src);
    try cwd.createDirPath(io, mono_src);
    var mono_resolved = try resolve(&paths, io, allocator, null, mono_src);
    defer mono_resolved.deinit(allocator);
    try std.testing.expectEqualStrings("0.12.0", mono_resolved.version);
    try std.testing.expectEqual(ResolutionSource.zig_version_file, mono_resolved.source);
}

test "findHighestMatchingInstalled ignores installed versions without a binary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    for ([_][]const u8{ "0.13.0", "0.14.0" }) |ver| {
        const v_dir = try paths.versionDir(allocator, ver);
        defer allocator.free(v_dir);
        try cwd.createDirPath(io, v_dir);

        const bin_path = try paths.versionZigBin(allocator, ver);
        defer allocator.free(bin_path);
        try cwd.writeFile(io, .{ .sub_path = bin_path, .data = "zig" });
    }
    // Highest version directory exists but holds no compiler binary.
    const empty_dir = try paths.versionDir(allocator, "0.15.0");
    defer allocator.free(empty_dir);
    try cwd.createDirPath(io, empty_dir);

    const matched = try findHighestMatchingInstalled(&paths, io, allocator, Constraint.gte(try Version.parse("0.1.0")));
    defer if (matched) |name| allocator.free(name);
    try std.testing.expectEqualStrings("0.14.0", matched.?);
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

/// Creates a project with `minimum_zig_version` and only Zig 0.17.0 installed.
/// An empty `.zig-version` shadows any pin in the repository's ancestors.
fn setupBuildZonProject(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    tmp_path: []const u8,
    min_version: []const u8,
) !void {
    try paths.ensureDirs(io);

    const v_dir = try paths.versionDir(allocator, "0.17.0");
    defer allocator.free(v_dir);
    try Io.Dir.cwd().createDirPath(io, v_dir);

    const bin_path = try paths.versionZigBin(allocator, "0.17.0");
    defer allocator.free(bin_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = "zig" });

    const zv_file = try std.fs.path.join(allocator, &.{ tmp_path, ".zig-version" });
    defer allocator.free(zv_file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zv_file, .data = "\n" });

    const zon_file = try std.fs.path.join(allocator, &.{ tmp_path, "build.zig.zon" });
    defer allocator.free(zon_file);
    const payload = try allocator.print(".{{ .minimum_zig_version = \"{s}\" }}\n", .{min_version});
    defer allocator.free(payload);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zon_file, .data = payload });
}

test "resolve exact minimum_zig_version" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try setupBuildZonProject(&paths, io, allocator, tmp_path, "0.15.2");

    // Default: newest installed version satisfying the lower bound.
    var default_resolved = try resolve(&paths, io, allocator, null, tmp_path);
    defer default_resolved.deinit(allocator);
    try std.testing.expectEqualStrings("0.17.0", default_resolved.version);

    // Exact: the declared minimum, even when it is not installed.
    var exact_resolved = try resolveWithOptions(&paths, io, allocator, null, tmp_path, .{ .exact = true });
    defer exact_resolved.deinit(allocator);
    try std.testing.expectEqualStrings("0.15.2", exact_resolved.version);
    try std.testing.expectEqual(ResolutionSource.build_zig_zon, exact_resolved.source);
}

test "ZVM_EXACT enables exact minimum resolution and --no-exact overrides it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try setupBuildZonProject(&paths, io, allocator, tmp_path, "0.15.2");

    var env_map = EnvironMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("ZVM_EXACT", "1");

    var from_env = try resolve(&paths, io, allocator, &env_map, tmp_path);
    defer from_env.deinit(allocator);
    try std.testing.expectEqualStrings("0.15.2", from_env.version);

    // A command-line `--no-exact` override wins over the environment.
    var overridden = try resolveWithOptions(&paths, io, allocator, &env_map, tmp_path, .{ .exact = false });
    defer overridden.deinit(allocator);
    try std.testing.expectEqualStrings("0.17.0", overridden.version);
}

test "persistent exact marker enables exact mode unless ZVM_EXACT=0 overrides it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try setupBuildZonProject(&paths, io, allocator, tmp_path, "0.15.2");
    try paths.setMarker(io, "exact", true);

    var from_marker = try resolve(&paths, io, allocator, null, tmp_path);
    defer from_marker.deinit(allocator);
    try std.testing.expectEqualStrings("0.15.2", from_marker.version);

    var env_map = EnvironMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("ZVM_EXACT", "0");

    var env_disabled = try resolve(&paths, io, allocator, &env_map, tmp_path);
    defer env_disabled.deinit(allocator);
    try std.testing.expectEqualStrings("0.17.0", env_disabled.version);
}

test "ZVM_EXACT vocabulary drives resolution and unknown values fall back to the marker" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try setupBuildZonProject(&paths, io, allocator, tmp_path, "0.15.2");

    var env_map = EnvironMap.init(allocator);
    defer env_map.deinit();

    // Padded and upper-case values are still understood.
    try env_map.put("ZVM_EXACT", " Yes \n");
    {
        var resolved = try resolve(&paths, io, allocator, &env_map, tmp_path);
        defer resolved.deinit(allocator);
        try std.testing.expectEqualStrings("0.15.2", resolved.version);
    }

    // An unrecognized value is not an error and not a silent "true": without a
    // marker the default lower-bound behaviour stays in place.
    try env_map.put("ZVM_EXACT", "maybe");
    {
        var resolved = try resolve(&paths, io, allocator, &env_map, tmp_path);
        defer resolved.deinit(allocator);
        try std.testing.expectEqualStrings("0.17.0", resolved.version);
    }

    // ...and with the marker set it still falls back to the marker rather than
    // discarding the persistent setting.
    try paths.setMarker(io, "exact", true);
    {
        var resolved = try resolve(&paths, io, allocator, &env_map, tmp_path);
        defer resolved.deinit(allocator);
        try std.testing.expectEqualStrings("0.15.2", resolved.version);
    }
}

test "minimum_zig_version is honored in zon manifests larger than a small buffer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    const v_dir = try paths.versionDir(allocator, "0.17.0");
    defer allocator.free(v_dir);
    try Io.Dir.cwd().createDirPath(io, v_dir);
    const bin_path = try paths.versionZigBin(allocator, "0.17.0");
    defer allocator.free(bin_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = "zig" });

    // An empty .zig-version keeps this repository's own pin out of the walk-up.
    const zv_file = try std.fs.path.join(allocator, &.{ tmp_path, ".zig-version" });
    defer allocator.free(zv_file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zv_file, .data = "\n" });

    const padding = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(padding);
    @memset(padding, 'x');

    const zon = try allocator.print(
        ".{{\n    // {s}\n    .name = .big,\n    .minimum_zig_version = \"0.17.0\",\n}}\n",
        .{padding},
    );
    defer allocator.free(zon);

    const zon_file = try std.fs.path.join(allocator, &.{ tmp_path, "build.zig.zon" });
    defer allocator.free(zon_file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zon_file, .data = zon });

    var resolved = try resolve(&paths, io, allocator, null, tmp_path);
    defer resolved.deinit(allocator);
    try std.testing.expectEqualStrings("0.17.0", resolved.version);
    try std.testing.expectEqual(ResolutionSource.build_zig_zon, resolved.source);
}

test "resolve reports a build.zig.zon the real parser rejects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    // Installs 0.17.0, writes an empty .zig-version, and a valid manifest.
    try setupBuildZonProject(&paths, io, allocator, tmp_path, "0.17.0");

    // Broken manifest: the version is still recovered by the scan fallback, but the
    // router must be able to say the manifest does not parse.
    const zon_file = try std.fs.path.join(allocator, &.{ tmp_path, "build.zig.zon" });
    defer allocator.free(zon_file);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = zon_file,
        .data = ".{\n    .minimum_zig_version = \"0.17.0\",\n    .paths = .{ \"build.zig\"\n}\n",
    });

    var resolved = try resolve(&paths, io, allocator, null, tmp_path);
    defer resolved.deinit(allocator);
    try std.testing.expectEqualStrings("0.17.0", resolved.version);
    try std.testing.expectEqualStrings(zon_file, resolved.malformed_zon_path.?);
}

test "invalid .zig-version is reported instead of treated as a version" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    const zv_file = try std.fs.path.join(allocator, &.{ tmp_path, ".zig-version" });
    defer allocator.free(zv_file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zv_file, .data = "banana\n" });

    try std.testing.expectError(
        ResolveError.InvalidZigVersionConstraint,
        resolve(&paths, io, allocator, null, tmp_path),
    );
}

test ".zig-version constraint without a matching install is distinguishable from a zon miss" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try setupBuildZonProject(&paths, io, allocator, tmp_path, "0.15.2");

    // The pin wins over the zon minimum and cannot be auto-installed from the zon.
    const zv_file = try std.fs.path.join(allocator, &.{ tmp_path, ".zig-version" });
    defer allocator.free(zv_file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = zv_file, .data = ">=9.0.0\n" });

    try std.testing.expectError(
        ResolveError.UnmatchedZigVersionConstraint,
        resolve(&paths, io, allocator, null, tmp_path),
    );
}
