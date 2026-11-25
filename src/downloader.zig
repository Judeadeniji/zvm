const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Paths = @import("paths.zig").Paths;
const Version = @import("version.zig").Version;

pub const index_url = "https://ziglang.org/download/index.json";

pub const ArtifactInfo = struct {
    version_key: []const u8,
    resolved_version: []const u8,
    date: []const u8,
    tarball: []const u8,
    shasum: []const u8,
    size: []const u8,

    pub fn deinit(self: *ArtifactInfo, allocator: Allocator) void {
        allocator.free(self.version_key);
        allocator.free(self.resolved_version);
        allocator.free(self.date);
        allocator.free(self.tarball);
        allocator.free(self.shasum);
        allocator.free(self.size);
    }
};

pub const ReleaseSummary = struct {
    name: []const u8,
    resolved_version: ?[]const u8,
    date: []const u8,
    has_host_target: bool,

    pub fn deinit(self: *ReleaseSummary, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.resolved_version) |rv| allocator.free(rv);
        allocator.free(self.date);
    }
};

pub const InstallResult = struct {
    version: []const u8,
    resolved_version: []const u8,
    install_dir: []const u8,
    already_installed: bool,

    pub fn deinit(self: *InstallResult, allocator: Allocator) void {
        allocator.free(self.version);
        allocator.free(self.resolved_version);
        allocator.free(self.install_dir);
    }
};

pub const ArchiveFormat = enum {
    tar_xz,
    tar_gz,
    zip,

    pub fn fromFilename(name: []const u8) !ArchiveFormat {
        if (std.mem.endsWith(u8, name, ".tar.xz")) return .tar_xz;
        if (std.mem.endsWith(u8, name, ".tar.gz") or std.mem.endsWith(u8, name, ".tgz")) return .tar_gz;
        if (std.mem.endsWith(u8, name, ".zip")) return .zip;
        return error.UnsupportedArchiveFormat;
    }
};

/// Maps CPU architecture and OS tag to the target key used in ziglang.org's `index.json`.
pub fn targetKey(arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag) ![]const u8 {
    const arch_str = switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "x86",
        .arm => "arm",
        .riscv64 => "riscv64",
        .powerpc64le => "powerpc64le",
        .loongarch64 => "loongarch64",
        else => return error.UnsupportedArchitecture,
    };

    const os_str = switch (os) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        .freebsd => "freebsd",
        else => return error.UnsupportedOperatingSystem,
    };

    return switch (arch) {
        .x86_64 => switch (os) {
            .linux => "x86_64-linux",
            .macos => "x86_64-macos",
            .windows => "x86_64-windows",
            .freebsd => "x86_64-freebsd",
            else => unreachable,
        },
        .aarch64 => switch (os) {
            .linux => "aarch64-linux",
            .macos => "aarch64-macos",
            .windows => "aarch64-windows",
            .freebsd => "aarch64-freebsd",
            else => unreachable,
        },
        .x86 => switch (os) {
            .linux => "x86-linux",
            .windows => "x86-windows",
            else => error.UnsupportedPlatformCombination,
        },
        .arm => switch (os) {
            .linux => "arm-linux",
            else => error.UnsupportedPlatformCombination,
        },
        .riscv64 => switch (os) {
            .linux => "riscv64-linux",
            else => error.UnsupportedPlatformCombination,
        },
        .powerpc64le => switch (os) {
            .linux => "powerpc64le-linux",
            else => error.UnsupportedPlatformCombination,
        },
        .loongarch64 => switch (os) {
            .linux => "loongarch64-linux",
            else => error.UnsupportedPlatformCombination,
        },
        else => blk: {
            _ = arch_str;
            _ = os_str;
            break :blk error.UnsupportedArchitecture;
        },
    };
}

pub fn hostTargetKey() ![]const u8 {
    return targetKey(builtin.target.cpu.arch, builtin.target.os.tag);
}

fn initHttpClient(
    io: Io,
    allocator: Allocator,
    arena: Allocator,
    environ_map: ?*const EnvironMap,
) !std.http.Client {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    errdefer client.deinit();

    if (environ_map) |env| {
        try client.initDefaultProxies(arena, env);
    }
    return client;
}

/// Fetches the official release metadata JSON from `https://ziglang.org/download/index.json`.
pub fn fetchIndexJson(io: Io, allocator: Allocator, environ_map: ?*const EnvironMap) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var client = try initHttpClient(io, allocator, arena_state.allocator(), environ_map);
    defer client.deinit();

    var body: Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = index_url },
        .response_writer = &body.writer,
    });
    if (res.status != .ok) {
        return error.HttpRequestFailed;
    }

    return try body.toOwnedSlice();
}

/// Looks up the release artifact for `version_key` (e.g., `"0.17.0"` or `"master"`) and `target_key`.
pub fn findArtifact(
    allocator: Allocator,
    json_bytes: []const u8,
    version_key: []const u8,
    target_key: []const u8,
) !ArtifactInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidIndexFormat;

    const release_val = parsed.value.object.get(version_key) orelse return error.VersionNotFound;
    if (release_val != .object) return error.InvalidReleaseFormat;
    const release_obj = release_val.object;

    const target_val = release_obj.get(target_key) orelse return error.TargetNotAvailable;
    if (target_val != .object) return error.InvalidTargetFormat;
    const target_obj = target_val.object;

    const tarball_val = target_obj.get("tarball") orelse return error.MissingTarballUrl;
    const shasum_val = target_obj.get("shasum") orelse return error.MissingChecksum;
    if (tarball_val != .string or shasum_val != .string) return error.InvalidArtifactFields;

    const date_str = if (release_obj.get("date")) |d| (if (d == .string) d.string else "") else "";
    const resolved_str = if (release_obj.get("version")) |v| (if (v == .string) v.string else version_key) else version_key;
    const size_str = if (target_obj.get("size")) |s| (if (s == .string) s.string else "") else "";

    const owned_vkey = try allocator.dupe(u8, version_key);
    errdefer allocator.free(owned_vkey);
    const owned_resolved = try allocator.dupe(u8, resolved_str);
    errdefer allocator.free(owned_resolved);
    const owned_date = try allocator.dupe(u8, date_str);
    errdefer allocator.free(owned_date);
    const owned_tarball = try allocator.dupe(u8, tarball_val.string);
    errdefer allocator.free(owned_tarball);
    const owned_shasum = try allocator.dupe(u8, shasum_val.string);
    errdefer allocator.free(owned_shasum);
    const owned_size = try allocator.dupe(u8, size_str);
    errdefer allocator.free(owned_size);

    return .{
        .version_key = owned_vkey,
        .resolved_version = owned_resolved,
        .date = owned_date,
        .tarball = owned_tarball,
        .shasum = owned_shasum,
        .size = owned_size,
    };
}

fn lessThanReleaseSummary(_: void, a: ReleaseSummary, b: ReleaseSummary) bool {
    const va = Version.parse(a.name) catch return std.mem.order(u8, a.name, b.name) == .gt;
    const vb = Version.parse(b.name) catch return std.mem.order(u8, a.name, b.name) == .gt;
    return va.order(vb) == .gt;
}

/// Parses `index.json` into a sorted slice of available releases (newest first).
pub fn parseReleases(
    allocator: Allocator,
    json_bytes: []const u8,
    target_key: []const u8,
) ![]ReleaseSummary {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidIndexFormat;

    var list: std.ArrayList(ReleaseSummary) = .empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const release_obj = entry.value_ptr.object;

        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);

        const resolved_version: ?[]const u8 = if (release_obj.get("version")) |v|
            if (v == .string) try allocator.dupe(u8, v.string) else null
        else
            null;
        errdefer if (resolved_version) |rv| allocator.free(rv);

        const date_raw = if (release_obj.get("date")) |d| (if (d == .string) d.string else "") else "";
        const date = try allocator.dupe(u8, date_raw);
        errdefer allocator.free(date);

        const has_host_target = release_obj.contains(target_key);

        try list.append(allocator, .{
            .name = name,
            .resolved_version = resolved_version,
            .date = date,
            .has_host_target = has_host_target,
        });
    }

    std.mem.sort(ReleaseSummary, list.items, {}, lessThanReleaseSummary);
    return try list.toOwnedSlice(allocator);
}

pub fn freeReleases(allocator: Allocator, releases: []ReleaseSummary) void {
    for (releases) |*item| item.deinit(allocator);
    allocator.free(releases);
}

/// Computes the SHA-256 hex digest of a file and checks it against `expected_hex`.
pub fn verifyFileSha256(io: Io, file_path: []const u8, expected_hex: []const u8) !void {
    if (expected_hex.len != Sha256.digest_length * 2) return error.InvalidExpectedChecksum;

    const cwd = Io.Dir.cwd();
    var file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    var hasher: Sha256 = .init(.{});
    var buf: [32 * 1024]u8 = undefined;
    var offset: u64 = 0;

    while (true) {
        const bytes_read = try file.readPositionalAll(io, &buf, offset);
        if (bytes_read == 0) break;
        hasher.update(buf[0..bytes_read]);
        offset += bytes_read;
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(&actual_hex, expected_hex)) {
        return error.ChecksumMismatch;
    }
}

/// Streams a URL to `dest_path`, deleting partial files on failure.
pub fn downloadToFile(
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    url: []const u8,
    dest_path: []const u8,
) !void {
    downloadToFileInner(io, allocator, environ_map, url, dest_path) catch |err| {
        Io.Dir.cwd().deleteFile(io, dest_path) catch {};
        return err;
    };
}

fn downloadToFileInner(
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    url: []const u8,
    dest_path: []const u8,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var client = try initHttpClient(io, allocator, arena_state.allocator(), environ_map);
    defer client.deinit();

    const cwd = Io.Dir.cwd();
    var out_file = try cwd.createFile(io, dest_path, .{ .truncate = true });
    defer out_file.close(io);

    var write_buf: [32 * 1024]u8 = undefined;
    var file_writer = out_file.writer(io, &write_buf);

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &file_writer.interface,
    });
    try file_writer.interface.flush();

    if (res.status != .ok) {
        return error.HttpRequestFailed;
    }
}

/// Extracts `archive_path` into `dest_dir_path`, stripping the single top-level archive folder.
pub fn extractArchive(
    io: Io,
    allocator: Allocator,
    archive_path: []const u8,
    dest_dir_path: []const u8,
) !void {
    const format = try ArchiveFormat.fromFilename(archive_path);
    const cwd = Io.Dir.cwd();

    const stage_path = try allocator.print("{s}.staging", .{dest_dir_path});
    defer allocator.free(stage_path);

    // Ensure clean staging and destination directories
    cwd.deleteTree(io, stage_path) catch {};
    errdefer cwd.deleteTree(io, stage_path) catch {};
    try cwd.createDirPath(io, stage_path);

    var stage_dir = try cwd.openDir(io, stage_path, .{});
    var stage_open = true;
    defer if (stage_open) stage_dir.close(io);

    var archive_file = try cwd.openFile(io, archive_path, .{});
    defer archive_file.close(io);

    var read_buf: [32 * 1024]u8 = undefined;
    var file_reader = archive_file.reader(io, &read_buf);

    switch (format) {
        .tar_xz => {
            var xz = try std.compress.xz.Decompress.init(&file_reader.interface, allocator, &.{});
            defer xz.deinit();
            try std.tar.extract(io, stage_dir, &xz.reader, .{
                .strip_components = 1,
                .mode_mode = .executable_bit_only,
            });
        },
        .tar_gz => {
            var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var gz: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &flate_buf);
            try std.tar.extract(io, stage_dir, &gz.reader, .{
                .strip_components = 1,
                .mode_mode = .executable_bit_only,
            });
        },
        .zip => {
            var diag: std.zip.Diagnostics = .{ .allocator = allocator };
            defer diag.deinit();
            try std.zip.extract(stage_dir, &file_reader, .{ .diagnostics = &diag });

            if (diag.root_dir.len > 0) {
                const nested_src = try std.fs.path.join(allocator, &.{ stage_path, diag.root_dir });
                defer allocator.free(nested_src);

                stage_dir.close(io);
                stage_open = false;

                cwd.deleteTree(io, dest_dir_path) catch {};
                try Io.Dir.rename(cwd, nested_src, cwd, dest_dir_path, io);
                cwd.deleteTree(io, stage_path) catch {};
                return;
            }
        },
    }

    stage_dir.close(io);
    stage_open = false;

    cwd.deleteTree(io, dest_dir_path) catch {};
    try Io.Dir.rename(cwd, stage_path, cwd, dest_dir_path, io);
}

/// Downloads, verifies, and installs the requested Zig version into `paths.versions_dir`.
pub fn installVersion(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    version_key: []const u8,
    force: bool,
) !InstallResult {
    try paths.ensureDirs(io);

    const install_dir = try paths.versionDir(allocator, version_key);
    errdefer allocator.free(install_dir);

    const is_master = std.mem.eql(u8, version_key, "master");
    if (!force and !is_master and paths.isVersionInstalled(io, allocator, version_key)) {
        return .{
            .version = try allocator.dupe(u8, version_key),
            .resolved_version = try allocator.dupe(u8, version_key),
            .install_dir = install_dir,
            .already_installed = true,
        };
    }

    const index_bytes = try fetchIndexJson(io, allocator, environ_map);
    defer allocator.free(index_bytes);

    const tkey = try hostTargetKey();
    var artifact = try findArtifact(allocator, index_bytes, version_key, tkey);
    defer artifact.deinit(allocator);

    const archive_name = std.fs.path.basename(artifact.tarball);
    const cache_path = try std.fs.path.join(allocator, &.{ paths.cache_dir, archive_name });
    defer allocator.free(cache_path);

    // Re-use cached archive if its checksum already matches; otherwise re-download.
    const cache_valid = blk: {
        verifyFileSha256(io, cache_path, artifact.shasum) catch break :blk false;
        break :blk true;
    };

    if (!cache_valid) {
        try downloadToFile(io, allocator, environ_map, artifact.tarball, cache_path);
        verifyFileSha256(io, cache_path, artifact.shasum) catch |err| {
            Io.Dir.cwd().deleteFile(io, cache_path) catch {};
            return err;
        };
    }

    try extractArchive(io, allocator, cache_path, install_dir);

    return .{
        .version = try allocator.dupe(u8, artifact.version_key),
        .resolved_version = try allocator.dupe(u8, artifact.resolved_version),
        .install_dir = install_dir,
        .already_installed = false,
    };
}

test "targetKey mapping" {
    try std.testing.expectEqualStrings("x86_64-linux", try targetKey(.x86_64, .linux));
    try std.testing.expectEqualStrings("aarch64-macos", try targetKey(.aarch64, .macos));
    try std.testing.expectEqualStrings("x86_64-windows", try targetKey(.x86_64, .windows));
    try std.testing.expectError(error.UnsupportedPlatformCombination, targetKey(.riscv64, .macos));
}

test "ArchiveFormat detection" {
    try std.testing.expectEqual(ArchiveFormat.tar_xz, try ArchiveFormat.fromFilename("zig-x86_64-linux-0.17.0.tar.xz"));
    try std.testing.expectEqual(ArchiveFormat.tar_gz, try ArchiveFormat.fromFilename("zig.tar.gz"));
    try std.testing.expectEqual(ArchiveFormat.zip, try ArchiveFormat.fromFilename("zig-x86_64-windows-0.17.0.zip"));
    try std.testing.expectError(error.UnsupportedArchiveFormat, ArchiveFormat.fromFilename("zig.tar.bz2"));
}

test "findArtifact and parseReleases from index json" {
    const allocator = std.testing.allocator;
    const sample_json =
        \\{
        \\  "master": {
        \\    "version": "0.18.0-dev.10+abc123",
        \\    "date": "2026-11-24",
        \\    "x86_64-linux": {
        \\      "tarball": "https://ziglang.org/builds/zig-x86_64-linux-0.18.0-dev.10+abc123.tar.xz",
        \\      "shasum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\      "size": "12345"
        \\    }
        \\  },
        \\  "0.17.0": {
        \\    "date": "2026-10-01",
        \\    "x86_64-linux": {
        \\      "tarball": "https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz",
        \\      "shasum": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\      "size": "23456"
        \\    }
        \\  },
        \\  "0.16.0": {
        \\    "date": "2026-05-01"
        \\  }
        \\}
    ;

    var master_art = try findArtifact(allocator, sample_json, "master", "x86_64-linux");
    defer master_art.deinit(allocator);
    try std.testing.expectEqualStrings("master", master_art.version_key);
    try std.testing.expectEqualStrings("0.18.0-dev.10+abc123", master_art.resolved_version);
    try std.testing.expectEqualStrings("2026-11-24", master_art.date);

    var rel_art = try findArtifact(allocator, sample_json, "0.17.0", "x86_64-linux");
    defer rel_art.deinit(allocator);
    try std.testing.expectEqualStrings("0.17.0", rel_art.resolved_version);

    try std.testing.expectError(error.VersionNotFound, findArtifact(allocator, sample_json, "0.15.0", "x86_64-linux"));
    try std.testing.expectError(error.TargetNotAvailable, findArtifact(allocator, sample_json, "0.16.0", "x86_64-linux"));

    const releases = try parseReleases(allocator, sample_json, "x86_64-linux");
    defer freeReleases(allocator, releases);
    try std.testing.expectEqual(@as(usize, 3), releases.len);
    // Sorted newest first: master -> 0.17.0 -> 0.16.0
    try std.testing.expectEqualStrings("master", releases[0].name);
    try std.testing.expect(releases[0].has_host_target);
    try std.testing.expectEqualStrings("0.17.0", releases[1].name);
    try std.testing.expect(releases[1].has_host_target);
    try std.testing.expectEqualStrings("0.16.0", releases[2].name);
    try std.testing.expect(!releases[2].has_host_target);
}

test "verifyFileSha256 matches and catches mismatch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "sample.bin" });
    defer allocator.free(tmp_path);

    const data = "zvm sha256 verification test payload";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = data });

    var expected_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &expected_digest, .{});
    const expected_hex = std.fmt.bytesToHex(expected_digest, .lower);

    try verifyFileSha256(io, tmp_path, &expected_hex);

    const bad_hex = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.ChecksumMismatch, verifyFileSha256(io, tmp_path, bad_hex));
}
