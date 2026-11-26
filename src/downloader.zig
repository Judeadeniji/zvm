//! Release discovery, streaming HTTP download, SHA-256 verification, and
//! archive extraction (`.tar.xz`, `.tar.gz`, `.zip`) for official Zig builds.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Paths = @import("paths.zig").Paths;
const version_mod = @import("version.zig");
const minisig = @import("minisig.zig");
const errors = @import("errors.zig");

pub const TargetError = errors.TargetError;
pub const ArchiveError = errors.ArchiveError;
pub const ChecksumError = errors.ChecksumError;
pub const DownloadError = errors.DownloadError;

pub const index_url = "https://ziglang.org/download/index.json";
pub const community_mirrors_url = "https://ziglang.org/download/community-mirrors.txt";
pub const fallback_mirrors = [_][]const u8{
    "https://pkg.hexops.org/zig",
    "https://zigmirror.hryx.net/zig",
    "https://zig.linus.dev/zig",
    "https://zig.squirl.dev",
    "https://zig.mirror.mschae23.de/zig",
    "https://ziglang.freetls.fastly.net",
    "https://zig.tilok.dev",
    "https://zig-mirror.tsimnet.eu/zig",
    "https://zig.karearl.com/zig",
    "https://pkg.earth/zig",
};

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

pub const ProgressCallback = struct {
    ctx: *anyopaque,
    on_progress: *const fn (ctx: *anyopaque, downloaded: u64, total: ?u64) void,
};

pub const InstallOptions = struct {
    force: bool = false,
    verify_minisig: bool = true,
    minisig_public_key: ?[]const u8 = null,
    progress: ?ProgressCallback = null,
};

pub const InstallResult = struct {
    version: []const u8,
    resolved_version: []const u8,
    install_dir: []const u8,
    already_installed: bool,
    minisig_verified: bool = false,

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

    pub fn fromFilename(name: []const u8) ArchiveError!ArchiveFormat {
        if (std.mem.endsWith(u8, name, ".tar.xz")) return .tar_xz;
        if (std.mem.endsWith(u8, name, ".tar.gz") or std.mem.endsWith(u8, name, ".tgz")) return .tar_gz;
        if (std.mem.endsWith(u8, name, ".zip")) return .zip;
        return ArchiveError.UnsupportedArchiveFormat;
    }
};

/// Maps CPU architecture and OS tag to the target key used in ziglang.org's `index.json`.
pub fn targetKey(arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag) TargetError![]const u8 {
    switch (os) {
        .linux, .macos, .windows, .freebsd => {},
        else => return TargetError.UnsupportedOperatingSystem,
    }

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
            else => TargetError.UnsupportedPlatformCombination,
        },
        .arm => switch (os) {
            .linux => "arm-linux",
            else => TargetError.UnsupportedPlatformCombination,
        },
        .riscv64 => switch (os) {
            .linux => "riscv64-linux",
            else => TargetError.UnsupportedPlatformCombination,
        },
        .powerpc64le => switch (os) {
            .linux => "powerpc64le-linux",
            else => TargetError.UnsupportedPlatformCombination,
        },
        .loongarch64 => switch (os) {
            .linux => "loongarch64-linux",
            else => TargetError.UnsupportedPlatformCombination,
        },
        else => TargetError.UnsupportedArchitecture,
    };
}

pub fn hostTargetKey() TargetError![]const u8 {
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

/// Fetches an HTTP/HTTPS URL into an owned byte slice.
pub fn fetchUrl(io: Io, allocator: Allocator, environ_map: ?*const EnvironMap, url: []const u8) ![]u8 {
    return fetchUrlWithHeaders(io, allocator, environ_map, url, &.{});
}

/// Fetches an HTTP/HTTPS URL with custom headers into an owned byte slice.
pub fn fetchUrlWithHeaders(
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    url: []const u8,
    extra_headers: []const std.http.Header,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var client = try initHttpClient(io, allocator, arena_state.allocator(), environ_map);
    defer client.deinit();

    var body: Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = extra_headers,
        .response_writer = &body.writer,
    });
    if (res.status != .ok) {
        return DownloadError.HttpRequestFailed;
    }

    return try body.toOwnedSlice();
}

/// Fetches the official release metadata JSON from `https://ziglang.org/download/index.json`.
pub fn fetchIndexJson(io: Io, allocator: Allocator, environ_map: ?*const EnvironMap) ![]u8 {
    return fetchUrl(io, allocator, environ_map, index_url);
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

    if (parsed.value != .object) return DownloadError.InvalidIndexFormat;

    const release_val = parsed.value.object.get(version_key) orelse return DownloadError.VersionNotFound;
    if (release_val != .object) return DownloadError.InvalidReleaseFormat;
    const release_obj = release_val.object;

    const target_val = release_obj.get(target_key) orelse return DownloadError.TargetNotAvailable;
    if (target_val != .object) return DownloadError.InvalidTargetFormat;
    const target_obj = target_val.object;

    const tarball_val = target_obj.get("tarball") orelse return DownloadError.MissingTarballUrl;
    const shasum_val = target_obj.get("shasum") orelse return DownloadError.MissingChecksum;
    if (tarball_val != .string or shasum_val != .string) return DownloadError.InvalidArtifactFields;

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
    return version_mod.greaterThanText({}, a.name, b.name);
}

/// Parses `index.json` into a sorted slice of available releases (newest first).
pub fn parseReleases(
    allocator: Allocator,
    json_bytes: []const u8,
    target_key: []const u8,
) ![]ReleaseSummary {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return DownloadError.InvalidIndexFormat;

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
pub fn verifyFileSha256(
    io: Io,
    file_path: []const u8,
    expected_hex: []const u8,
) (ChecksumError || Io.File.OpenError || Io.File.ReadPositionalError)!void {
    if (expected_hex.len != Sha256.digest_length * 2) return ChecksumError.InvalidExpectedChecksum;

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
        return ChecksumError.ChecksumMismatch;
    }
}

const ProgressWriter = struct {
    interface: Io.Writer,
    inner: *Io.Writer,
    total: ?u64,
    callback: ?ProgressCallback,
    bytes_written: u64 = 0,
    last_reported: u64 = 0,

    const report_interval: u64 = 256 * 1024;

    fn init(inner: *Io.Writer, total: ?u64, callback: ?ProgressCallback) ProgressWriter {
        return .{
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                },
                .buffer = &.{},
            },
            .inner = inner,
            .total = total,
            .callback = callback,
        };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *ProgressWriter = @alignCast(@fieldParentPtr("interface", w));
        const n = try self.inner.writeSplat(data, splat);
        self.bytes_written += n;
        if (self.callback) |cb| {
            if (self.bytes_written - self.last_reported >= report_interval) {
                self.last_reported = self.bytes_written;
                cb.on_progress(cb.ctx, self.bytes_written, self.total);
            }
        }
        return n;
    }

    fn flush(w: *Io.Writer) Io.Writer.Error!void {
        const self: *ProgressWriter = @alignCast(@fieldParentPtr("interface", w));
        try self.inner.flush();
        if (self.callback) |cb| {
            cb.on_progress(cb.ctx, self.bytes_written, self.total);
        }
    }
};

/// Returns a short random hex suffix used to keep scratch paths process-unique,
/// so concurrent `zvm` invocations never share (and delete) each other's files.
pub fn uniqueSuffix(io: Io) [16]u8 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// Streams a URL to `dest_path`, deleting partial files on failure.
///
/// The body is written to a unique temporary file and renamed into place, so a
/// concurrent `zvm` process never observes or truncates a half-written archive.
pub fn downloadToFile(
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    url: []const u8,
    dest_path: []const u8,
    expected_size: ?u64,
    progress: ?ProgressCallback,
) !void {
    const tmp_path = try allocator.print("{s}.partial-{s}", .{ dest_path, uniqueSuffix(io) });
    defer allocator.free(tmp_path);

    downloadToFileInner(io, allocator, environ_map, url, tmp_path, expected_size, progress) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return err;
    };

    const cwd = Io.Dir.cwd();
    Io.Dir.rename(cwd, tmp_path, cwd, dest_path, io) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };
}

fn downloadToFileInner(
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    url: []const u8,
    dest_path: []const u8,
    expected_size: ?u64,
    progress: ?ProgressCallback,
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
    var prog_writer = ProgressWriter.init(&file_writer.interface, expected_size, progress);

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &prog_writer.interface,
    });
    try prog_writer.interface.flush();

    if (res.status != .ok) {
        return DownloadError.HttpRequestFailed;
    }
}

pub const ExtractError = ArchiveError ||
    Allocator.Error ||
    Io.Dir.OpenError ||
    Io.Dir.CreateDirPathError ||
    Io.Dir.RenameError ||
    Io.File.OpenError;

pub const ExtractOptions = struct {
    strip_components: u32 = 1,
};

/// Extracts `archive_path` into `dest_dir_path`, stripping the single top-level archive folder.
pub fn extractArchive(
    io: Io,
    allocator: Allocator,
    archive_path: []const u8,
    dest_dir_path: []const u8,
) ExtractError!void {
    return extractArchiveWithOptions(io, allocator, archive_path, dest_dir_path, .{});
}

/// Extracts `archive_path` into `dest_dir_path` with explicit extraction options.
pub fn extractArchiveWithOptions(
    io: Io,
    allocator: Allocator,
    archive_path: []const u8,
    dest_dir_path: []const u8,
    options: ExtractOptions,
) ExtractError!void {
    const format = try ArchiveFormat.fromFilename(archive_path);
    const cwd = Io.Dir.cwd();

    // A per-process staging directory keeps concurrent installs from deleting
    // each other's work.
    const stage_path = try allocator.print("{s}.staging-{s}", .{ dest_dir_path, uniqueSuffix(io) });
    defer allocator.free(stage_path);

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
            var xz = std.compress.xz.Decompress.init(&file_reader.interface, allocator, &.{}) catch {
                return ArchiveError.DecompressionFailed;
            };
            defer xz.deinit();
            std.tar.extract(io, stage_dir, &xz.reader, .{
                .strip_components = options.strip_components,
                .mode_mode = .executable_bit_only,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return ArchiveError.ExtractionFailed,
            };
        },
        .tar_gz => {
            var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var gz: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &flate_buf);
            std.tar.extract(io, stage_dir, &gz.reader, .{
                .strip_components = options.strip_components,
                .mode_mode = .executable_bit_only,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return ArchiveError.ExtractionFailed,
            };
        },
        .zip => {
            var diag: std.zip.Diagnostics = .{ .allocator = allocator };
            defer diag.deinit();
            std.zip.extract(stage_dir, &file_reader, .{ .diagnostics = &diag }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return ArchiveError.ExtractionFailed,
            };

            if (diag.root_dir.len > 0) {
                const nested_src = try std.fs.path.join(allocator, &.{ stage_path, diag.root_dir });
                defer allocator.free(nested_src);

                stage_dir.close(io);
                stage_open = false;

                try replaceDir(cwd, io, allocator, nested_src, dest_dir_path);
                cwd.deleteTree(io, stage_path) catch {};
                return;
            }
        },
    }

    stage_dir.close(io);
    stage_open = false;

    try replaceDir(cwd, io, allocator, stage_path, dest_dir_path);
}

/// Moves `staged_path` into `dest_path`, keeping the previous destination as a
/// `.old` sibling until the swap succeeds so a failure never destroys a working
/// install.
fn replaceDir(
    cwd: Io.Dir,
    io: Io,
    allocator: Allocator,
    staged_path: []const u8,
    dest_path: []const u8,
) ExtractError!void {
    // Unique backup name so two processes replacing the same version never
    // delete each other's only copy.
    const backup_path = try allocator.print("{s}.old-{s}", .{ dest_path, uniqueSuffix(io) });
    defer allocator.free(backup_path);

    cwd.deleteTree(io, backup_path) catch {};

    const moved_previous = blk: {
        Io.Dir.rename(cwd, dest_path, cwd, backup_path, io) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };

    Io.Dir.rename(cwd, staged_path, cwd, dest_path, io) catch |err| {
        if (moved_previous) Io.Dir.rename(cwd, backup_path, cwd, dest_path, io) catch {};
        return err;
    };

    cwd.deleteTree(io, backup_path) catch {};
}

/// Fetches a `.minisig` signature file if available (`null` on HTTP 404 for older releases).
pub fn fetchMinisigOptional(
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    tarball_url: []const u8,
) !?[]u8 {
    const sig_url = try allocator.print("{s}.minisig", .{tarball_url});
    defer allocator.free(sig_url);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var client = try initHttpClient(io, allocator, arena_state.allocator(), environ_map);
    defer client.deinit();

    var body: Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = sig_url },
        .response_writer = &body.writer,
    });
    if (res.status == .not_found) return null;
    if (res.status != .ok) return DownloadError.HttpRequestFailed;

    return try body.toOwnedSlice();
}

/// Ensures the archive for `tarball` is cached in `paths.cache_dir` and matches `shasum`.
/// Caller owns the returned cache path slice.
pub fn ensureCachedArchive(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    tarball: []const u8,
    shasum: []const u8,
    size_str: []const u8,
    progress: ?ProgressCallback,
) ![]u8 {
    const archive_name = std.fs.path.basename(tarball);
    const cache_path = try std.fs.path.join(allocator, &.{ paths.cache_dir, archive_name });
    errdefer allocator.free(cache_path);

    const cache_valid = blk: {
        verifyFileSha256(io, cache_path, shasum) catch break :blk false;
        break :blk true;
    };

    if (!cache_valid) {
        const expected_size: ?u64 = if (size_str.len > 0)
            std.fmt.parseInt(u64, size_str, 10) catch null
        else
            null;
        try downloadToFile(io, allocator, environ_map, tarball, cache_path, expected_size, progress);
        verifyFileSha256(io, cache_path, shasum) catch |err| {
            Io.Dir.cwd().deleteFile(io, cache_path) catch {};
            return err;
        };
    }

    return cache_path;
}

/// Parses newline-separated mirror base URLs from `community-mirrors.txt`.
pub fn parseMirrorList(allocator: Allocator, text: []const u8) Allocator.Error![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |m| allocator.free(m);
        list.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "https://") and !std.mem.startsWith(u8, line, "http://")) continue;
        try list.append(allocator, try allocator.dupe(u8, std.mem.trimEnd(u8, line, "/")));
    }

    return try list.toOwnedSlice(allocator);
}

pub fn freeMirrorList(allocator: Allocator, mirrors: [][]u8) void {
    for (mirrors) |m| allocator.free(m);
    allocator.free(mirrors);
}

/// Builds a Zig community mirror tarball URL (`<mirror>/<archive>?source=zvm`).
pub fn buildMirrorTarballUrl(allocator: Allocator, mirror_base: []const u8, archive_name: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trimEnd(u8, mirror_base, "/");
    return try allocator.print("{s}/{s}?source=zvm", .{ trimmed, archive_name });
}

fn ensureCachedZigArchive(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    tarball: []const u8,
    shasum: []const u8,
    size_str: []const u8,
    progress: ?ProgressCallback,
) ![]u8 {
    return ensureCachedArchive(paths, io, allocator, environ_map, tarball, shasum, size_str, progress) catch |primary_err| {
        const archive_name = std.fs.path.basename(tarball);
        const cache_path = try std.fs.path.join(allocator, &.{ paths.cache_dir, archive_name });
        errdefer allocator.free(cache_path);

        const expected_size: ?u64 = if (size_str.len > 0)
            std.fmt.parseInt(u64, size_str, 10) catch null
        else
            null;

        const fetched_list = fetchUrl(io, allocator, environ_map, community_mirrors_url) catch null;
        defer if (fetched_list) |b| allocator.free(b);

        var dynamic_mirrors: ?[][]u8 = null;
        defer if (dynamic_mirrors) |dm| freeMirrorList(allocator, dm);

        const mirror_slice: []const []const u8 = if (fetched_list) |body| blk: {
            dynamic_mirrors = try parseMirrorList(allocator, body);
            if (dynamic_mirrors.?.len > 0) break :blk dynamic_mirrors.?;
            break :blk &fallback_mirrors;
        } else &fallback_mirrors;

        for (mirror_slice) |mirror_base| {
            const mirror_url = try buildMirrorTarballUrl(allocator, mirror_base, archive_name);
            defer allocator.free(mirror_url);

            downloadToFile(io, allocator, environ_map, mirror_url, cache_path, expected_size, progress) catch {
                Io.Dir.cwd().deleteFile(io, cache_path) catch {};
                continue;
            };
            verifyFileSha256(io, cache_path, shasum) catch {
                Io.Dir.cwd().deleteFile(io, cache_path) catch {};
                continue;
            };
            return cache_path;
        }

        return primary_err;
    };
}

/// Downloads, verifies, and installs the requested Zig version into `paths.versions_dir`.
pub fn installVersion(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    version_key: []const u8,
    options: InstallOptions,
) !InstallResult {
    try paths.ensureDirs(io);

    const install_dir = try paths.versionDir(allocator, version_key);
    errdefer allocator.free(install_dir);

    const is_master = std.mem.eql(u8, version_key, "master");
    if (!options.force and !is_master and paths.isVersionInstalled(io, allocator, version_key)) {
        const version_copy = try allocator.dupe(u8, version_key);
        errdefer allocator.free(version_copy);
        const resolved_copy = try allocator.dupe(u8, version_key);
        return .{
            .version = version_copy,
            .resolved_version = resolved_copy,
            .install_dir = install_dir,
            .already_installed = true,
        };
    }

    const index_bytes = try fetchIndexJson(io, allocator, environ_map);
    defer allocator.free(index_bytes);

    const tkey = try hostTargetKey();
    var artifact = try findArtifact(allocator, index_bytes, version_key, tkey);
    defer artifact.deinit(allocator);

    // For `master`, compare against stored `.zvm-version` so up-to-date builds skip download.
    if (!options.force and is_master and paths.isVersionInstalled(io, allocator, version_key)) {
        const current_meta = paths.readVersionMeta(io, allocator, version_key) catch null;
        defer if (current_meta) |m| allocator.free(m);
        if (current_meta != null and std.mem.eql(u8, current_meta.?, artifact.resolved_version)) {
            const version_copy = try allocator.dupe(u8, artifact.version_key);
            errdefer allocator.free(version_copy);
            const resolved_copy = try allocator.dupe(u8, artifact.resolved_version);
            return .{
                .version = version_copy,
                .resolved_version = resolved_copy,
                .install_dir = install_dir,
                .already_installed = true,
            };
        }
    }

    const cache_path = try ensureCachedZigArchive(
        paths,
        io,
        allocator,
        environ_map,
        artifact.tarball,
        artifact.shasum,
        artifact.size,
        options.progress,
    );
    defer allocator.free(cache_path);

    var minisig_verified = false;
    if (options.verify_minisig) {
        if (try fetchMinisigOptional(io, allocator, environ_map, artifact.tarball)) |sig_text| {
            defer allocator.free(sig_text);
            const pubkey_text = try minisig.resolvePublicKeyText(
                paths,
                io,
                allocator,
                environ_map,
                options.minisig_public_key,
            );
            defer allocator.free(pubkey_text);
            minisig.verifyFile(io, allocator, cache_path, sig_text, pubkey_text) catch |err| {
                Io.Dir.cwd().deleteFile(io, cache_path) catch {};
                return err;
            };
            minisig_verified = true;
        }
    }

    try extractArchive(io, allocator, cache_path, install_dir);
    try paths.writeVersionMeta(io, allocator, version_key, artifact.resolved_version);

    const version_copy = try allocator.dupe(u8, artifact.version_key);
    errdefer allocator.free(version_copy);
    const resolved_copy = try allocator.dupe(u8, artifact.resolved_version);
    return .{
        .version = version_copy,
        .resolved_version = resolved_copy,
        .install_dir = install_dir,
        .already_installed = false,
        .minisig_verified = minisig_verified,
    };
}

test "targetKey mapping" {
    try std.testing.expectEqualStrings("x86_64-linux", try targetKey(.x86_64, .linux));
    try std.testing.expectEqualStrings("aarch64-macos", try targetKey(.aarch64, .macos));
    try std.testing.expectEqualStrings("x86_64-windows", try targetKey(.x86_64, .windows));
    try std.testing.expectError(TargetError.UnsupportedPlatformCombination, targetKey(.riscv64, .macos));
}

test "ArchiveFormat detection" {
    try std.testing.expectEqual(ArchiveFormat.tar_xz, try ArchiveFormat.fromFilename("zig-x86_64-linux-0.17.0.tar.xz"));
    try std.testing.expectEqual(ArchiveFormat.tar_gz, try ArchiveFormat.fromFilename("zig.tar.gz"));
    try std.testing.expectEqual(ArchiveFormat.zip, try ArchiveFormat.fromFilename("zig-x86_64-windows-0.17.0.zip"));
    try std.testing.expectError(ArchiveError.UnsupportedArchiveFormat, ArchiveFormat.fromFilename("zig.tar.bz2"));
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

    try std.testing.expectError(DownloadError.VersionNotFound, findArtifact(allocator, sample_json, "0.15.0", "x86_64-linux"));
    try std.testing.expectError(DownloadError.TargetNotAvailable, findArtifact(allocator, sample_json, "0.16.0", "x86_64-linux"));

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
    try std.testing.expectError(DownloadError.ChecksumMismatch, verifyFileSha256(io, tmp_path, bad_hex));
}

test "extractArchive unpacks real tar.xz, tar.gz, and zip stripping root directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tar_xz_bytes =
        "\xfd\x37\x7a\x58\x5a\x00\x00\x04\xe6\xd6\xb4\x46\x02\x00\x21\x01" ++
        "\x16\x00\x00\x00\x74\x2f\xe5\xa3\xe0\x27\xff\x00\xab\x5d\x00\x3d" ++
        "\x1a\x49\x15\x79\xcd\x8f\x6b\xfb\x5f\xa8\xdc\xc5\xa6\xfd\xdf\xd1" ++
        "\x61\x8c\xb8\xb5\x95\x48\x61\x17\xda\xb8\xa8\xf9\x08\x56\xbc\x0e" ++
        "\xbe\x6b\xfb\x78\xa9\x48\x3f\x6e\x28\x81\x76\x1b\x11\xfc\xc4\xf6" ++
        "\xbf\xd9\x3c\x50\x63\x89\x82\x01\xdd\x0f\x8c\x3b\x4f\x9e\x64\x6a" ++
        "\x5b\x21\xe4\x9e\x47\x5a\x1b\xa5\x82\xf5\xd7\xda\x59\xf1\x45\x35" ++
        "\x30\x4c\x16\x06\x24\x30\xa9\xec\xbc\xaa\x8f\x20\xd1\x86\x90\x6e" ++
        "\x03\x91\xc6\x32\x55\x92\x5d\x3f\x4b\x0e\x75\x53\x60\x85\xc0\x86" ++
        "\xb2\xe3\xa8\xbc\x61\xb9\xa3\xc3\x9e\x90\x4b\x36\x5c\x0d\xd6\x53" ++
        "\x9c\x62\x39\x80\x75\xa1\xeb\x81\x37\x83\xb8\xe0\x85\xaa\xf8\xaf" ++
        "\xdd\x83\x48\x97\xa7\x0b\xf3\x19\xc3\x48\x7d\x9e\x8c\xac\x61\xc6" ++
        "\x9a\xa7\x88\x31\x4d\x1b\xd6\xbd\x42\x80\x00\x00\x1e\x5f\x9e\x4b" ++
        "\xab\x15\xe3\x86\x00\x01\xc7\x01\x80\x50\x00\x00\xea\x4b\x3d\x73" ++
        "\xb1\xc4\x67\xfb\x02\x00\x00\x00\x00\x04\x59\x5a";

    const tar_gz_bytes =
        "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xed\xd4\xb1\x0a\x83\x30" ++
        "\x10\xc6\xf1\xcc\x3e\x45\x4a\x67\x4d\x82\xda\x0c\xa5\x0f\x53\xad" ++
        "\x68\xa0\x28\x34\x29\x14\x9f\xbe\xd1\x0e\x05\xa1\x9b\x08\x6d\xff" ++
        "\x3f\x38\x2e\x64\xb9\xe5\xbe\x1b\x5d\x9b\x86\xc6\x87\x54\x67\xc6" ++
        "\x66\x5a\x8d\xae\x15\x6b\xd3\x91\x2d\xcb\xb9\x47\xcb\xae\x75\x9e" ++
        "\xbf\xdf\xd3\xbf\xd1\xb6\xb0\x42\x6a\xb1\x81\xbb\x0f\xe7\x5b\x1c" ++
        "\x2f\xfe\xd3\x7e\xa7\x2a\xd7\x2b\xdf\x25\x4d\xdd\x0d\xf2\xb5\x05" ++
        "\xf3\x46\x24\x02\xbf\x6f\x5c\xe4\xff\xea\x2a\xe5\xc3\x65\xaa\x6c" ++
        "\xad\x5b\x30\x85\xfa\x50\x14\x9f\xf3\x6f\xca\x45\xfe\xf3\x78\x2f" ++
        "\xc8\xff\x16\xea\xa1\xf7\x41\x3e\xe4\x49\x9a\x23\x89\x07\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\xf8\x3e\x4f\x02\x81\x1c\xcd" ++
        "\x00\x28\x00\x00";

    const zip_bytes =
        "\x50\x4b\x03\x04\x14\x00\x00\x00\x08\x00\x1a\x4b\x79\x5d\x67\xf5" ++
        "\xc5\x8c\x1d\x00\x00\x00\x1b\x00\x00\x00\x13\x00\x00\x00\x7a\x69" ++
        "\x67\x2d\x74\x65\x73\x74\x2d\x30\x2e\x31\x37\x2e\x30\x2f\x7a\x69" ++
        "\x67\x53\x56\xd4\x4f\xca\xcc\xd3\x2f\xce\xe0\x4a\x4d\xce\xc8\x57" ++
        "\x30\xd0\x33\x34\xd7\x33\xd0\x2d\x49\x2d\x2e\xe1\x02\x00\x50\x4b" ++
        "\x03\x04\x14\x00\x00\x00\x08\x00\x1a\x4b\x79\x5d\xb3\xb1\x08\x75" ++
        "\x0f\x00\x00\x00\x0d\x00\x00\x00\x1f\x00\x00\x00\x7a\x69\x67\x2d" ++
        "\x74\x65\x73\x74\x2d\x30\x2e\x31\x37\x2e\x30\x2f\x6c\x69\x62\x2f" ++
        "\x73\x74\x64\x2f\x73\x74\x64\x2e\x7a\x69\x67\x4b\xce\xcf\x2b\x2e" ++
        "\x51\xa8\x50\xb0\x55\x30\xb4\xe6\x02\x00\x50\x4b\x01\x02\x14\x03" ++
        "\x14\x00\x00\x00\x08\x00\x1a\x4b\x79\x5d\x67\xf5\xc5\x8c\x1d\x00" ++
        "\x00\x00\x1b\x00\x00\x00\x13\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x80\x01\x00\x00\x00\x00\x7a\x69\x67\x2d\x74\x65\x73\x74" ++
        "\x2d\x30\x2e\x31\x37\x2e\x30\x2f\x7a\x69\x67\x50\x4b\x01\x02\x14" ++
        "\x03\x14\x00\x00\x00\x08\x00\x1a\x4b\x79\x5d\xb3\xb1\x08\x75\x0f" ++
        "\x00\x00\x00\x0d\x00\x00\x00\x1f\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x80\x01\x4e\x00\x00\x00\x7a\x69\x67\x2d\x74\x65\x73" ++
        "\x74\x2d\x30\x2e\x31\x37\x2e\x30\x2f\x6c\x69\x62\x2f\x73\x74\x64" ++
        "\x2f\x73\x74\x64\x2e\x7a\x69\x67\x50\x4b\x05\x06\x00\x00\x00\x00" ++
        "\x02\x00\x02\x00\x8e\x00\x00\x00\x9a\x00\x00\x00\x00\x00";

    const cases = [_]struct { filename: []const u8, data: []const u8, dest_name: []const u8 }{
        .{ .filename = "zig-test.tar.xz", .data = tar_xz_bytes, .dest_name = "out-xz" },
        .{ .filename = "zig-test.tar.gz", .data = tar_gz_bytes, .dest_name = "out-gz" },
        .{ .filename = "zig-test.zip", .data = zip_bytes, .dest_name = "out-zip" },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = Io.Dir.cwd();
    for (cases) |c| {
        const archive_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, c.filename });
        defer allocator.free(archive_path);
        try cwd.writeFile(io, .{ .sub_path = archive_path, .data = c.data });

        const dest_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, c.dest_name });
        defer allocator.free(dest_path);

        try extractArchive(io, allocator, archive_path, dest_path);

        const zig_path = try std.fs.path.join(allocator, &.{ dest_path, "zig" });
        defer allocator.free(zig_path);
        var buf: [64]u8 = undefined;
        const zig_content = try cwd.readFile(io, zig_path, &buf);
        try std.testing.expectEqualStrings("#!/bin/sh\necho 0.17.0-test\n", zig_content);

        const std_path = try std.fs.path.join(allocator, &.{ dest_path, "lib", "std", "std.zig" });
        defer allocator.free(std_path);
        const std_content = try cwd.readFile(io, std_path, &buf);
        try std.testing.expectEqualStrings("const x = 1;\n", std_content);

        // Extracting over an existing install must replace it without leftovers.
        try extractArchive(io, allocator, archive_path, dest_path);
        const zig_again = try cwd.readFile(io, zig_path, &buf);
        try std.testing.expectEqualStrings("#!/bin/sh\necho 0.17.0-test\n", zig_again);
    }

    var staging_scan = try cwd.openDir(io, ".zig-cache/tmp/" ++ tmp.sub_path, .{ .iterate = true });
    defer staging_scan.close(io);
    var entries = staging_scan.iterate();
    while (try entries.next(io)) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".staging-") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".old-") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".partial-") == null);
    }
}

test "parseMirrorList and buildMirrorTarballUrl handle community mirrors" {
    const allocator = std.testing.allocator;
    const raw =
        \\# community mirrors
        \\https://pkg.hexops.org/zig/
        \\
        \\https://zigmirror.hryx.net/zig
        \\invalid-line
    ;
    const mirrors = try parseMirrorList(allocator, raw);
    defer freeMirrorList(allocator, mirrors);

    try std.testing.expectEqual(@as(usize, 2), mirrors.len);
    try std.testing.expectEqualStrings("https://pkg.hexops.org/zig", mirrors[0]);
    try std.testing.expectEqualStrings("https://zigmirror.hryx.net/zig", mirrors[1]);

    const url = try buildMirrorTarballUrl(allocator, "https://pkg.hexops.org/zig/", "zig-linux-x86_64-0.17.0.tar.xz");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://pkg.hexops.org/zig/zig-linux-x86_64-0.17.0.tar.xz?source=zvm",
        url,
    );
}
