//! ZLS (Zig Language Server) release discovery, SHA-256 verification, and extraction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const errors = @import("errors.zig");
const Paths = @import("paths.zig").Paths;
const downloader = @import("downloader.zig");

const DownloadError = errors.DownloadError;
const ZlsError = errors.ZlsError;

pub const select_version_base = "https://releases.zigtools.org/v1/zls/select-version";

pub const ZlsArtifact = struct {
    version: []const u8,
    date: []const u8,
    tarball: []const u8,
    shasum: []const u8,
    size: []const u8,

    pub fn deinit(self: *ZlsArtifact, allocator: Allocator) void {
        allocator.free(self.version);
        allocator.free(self.date);
        allocator.free(self.tarball);
        allocator.free(self.shasum);
        allocator.free(self.size);
    }
};

pub const ZlsInstallOptions = struct {
    force: bool = false,
    progress: ?downloader.ProgressCallback = null,
};

pub const ZlsInstallResult = struct {
    zig_version: []const u8,
    zls_version: []const u8,
    install_dir: []const u8,
    already_installed: bool,

    pub fn deinit(self: *ZlsInstallResult, allocator: Allocator) void {
        allocator.free(self.zig_version);
        allocator.free(self.zls_version);
        allocator.free(self.install_dir);
    }
};

/// Builds the `releases.zigtools.org` query URL for `zig_version`.
pub fn selectVersionUrl(allocator: Allocator, zig_version: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, select_version_base ++ "?zig_version=");
    for (zig_version) |c| {
        const is_unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (is_unreserved) {
            try out.append(allocator, c);
        } else {
            var esc: [3]u8 = undefined;
            const s = std.fmt.bufPrint(&esc, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(allocator, s);
        }
    }
    try out.appendSlice(allocator, "&compatibility=only-runtime");
    return try out.toOwnedSlice(allocator);
}

/// Parses a `select-version` JSON response for `target_key`.
pub fn parseZlsArtifact(
    allocator: Allocator,
    json_bytes: []const u8,
    target_key: []const u8,
) !ZlsArtifact {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return ZlsError.InvalidZlsResponse;
    const root = parsed.value.object;

    // `releases.zigtools.org` returns `{ "code": ..., "message": ... }` when no ZLS matches.
    if (root.get("code") != null and root.get("version") == null) {
        return ZlsError.ZlsVersionNotFound;
    }

    const version_val = root.get("version") orelse return ZlsError.InvalidZlsResponse;
    if (version_val != .string or version_val.string.len == 0) return ZlsError.InvalidZlsResponse;

    const date_str: []const u8 = if (root.get("date")) |dv|
        (if (dv == .string) dv.string else "")
    else
        "";

    const target_val = root.get(target_key) orelse return DownloadError.TargetNotAvailable;
    if (target_val != .object) return DownloadError.InvalidTargetFormat;

    const tarball_val = target_val.object.get("tarball") orelse return DownloadError.MissingTarballUrl;
    const shasum_val = target_val.object.get("shasum") orelse return DownloadError.MissingChecksum;
    if (tarball_val != .string or shasum_val != .string) return DownloadError.InvalidArtifactFields;

    const size_str: []const u8 = if (target_val.object.get("size")) |sv|
        (if (sv == .string) sv.string else "")
    else
        "";

    const version_copy = try allocator.dupe(u8, version_val.string);
    errdefer allocator.free(version_copy);
    const date_copy = try allocator.dupe(u8, date_str);
    errdefer allocator.free(date_copy);
    const tarball_copy = try allocator.dupe(u8, tarball_val.string);
    errdefer allocator.free(tarball_copy);
    const shasum_copy = try allocator.dupe(u8, shasum_val.string);
    errdefer allocator.free(shasum_copy);
    const size_copy = try allocator.dupe(u8, size_str);

    return .{
        .version = version_copy,
        .date = date_copy,
        .tarball = tarball_copy,
        .shasum = shasum_copy,
        .size = size_copy,
    };
}

/// Downloads, verifies, and installs the ZLS release compatible with `zig_version_key`.
pub fn installZls(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    zig_version_key: []const u8,
    options: ZlsInstallOptions,
) !ZlsInstallResult {
    try paths.ensureDirs(io);

    const install_dir = try paths.zlsVersionDir(allocator, zig_version_key);
    errdefer allocator.free(install_dir);

    var install_lock = try downloader.InstallLock.acquire(io, allocator, install_dir);
    defer install_lock.release();

    // For `master`, resolve the concrete Zig dev version recorded in `.zvm-version` if available.
    const query_version: []u8 = blk: {
        if (std.mem.eql(u8, zig_version_key, "master")) {
            if (paths.readVersionMeta(io, allocator, "master") catch null) |meta| {
                break :blk meta;
            }
        }
        break :blk try allocator.dupe(u8, zig_version_key);
    };
    defer allocator.free(query_version);

    const url = try selectVersionUrl(allocator, query_version);
    defer allocator.free(url);

    const json_bytes = try downloader.fetchUrl(io, allocator, environ_map, url);
    defer allocator.free(json_bytes);

    const tkey = try downloader.hostTargetKey();
    var artifact = try parseZlsArtifact(allocator, json_bytes, tkey);
    defer artifact.deinit(allocator);

    if (!options.force and paths.isZlsInstalled(io, zig_version_key)) {
        const current_meta = paths.readZlsVersionMeta(io, allocator, zig_version_key) catch null;
        defer if (current_meta) |m| allocator.free(m);
        if (current_meta != null and std.mem.eql(u8, current_meta.?, artifact.version)) {
            const zig_copy = try allocator.dupe(u8, zig_version_key);
            errdefer allocator.free(zig_copy);
            const zls_copy = try allocator.dupe(u8, artifact.version);
            return .{
                .zig_version = zig_copy,
                .zls_version = zls_copy,
                .install_dir = install_dir,
                .already_installed = true,
            };
        }
    }

    const cache_path = try downloader.ensureCachedArchive(
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

    // ZLS tarballs place `zls` at the archive root without a top-level wrapper directory.
    try downloader.extractArchiveWithOptions(io, allocator, cache_path, install_dir, .{
        .strip_components = 0,
    });
    try paths.writeZlsVersionMeta(io, allocator, zig_version_key, artifact.version);

    const zig_copy = try allocator.dupe(u8, zig_version_key);
    errdefer allocator.free(zig_copy);
    const zls_copy = try allocator.dupe(u8, artifact.version);
    return .{
        .zig_version = zig_copy,
        .zls_version = zls_copy,
        .install_dir = install_dir,
        .already_installed = false,
    };
}

test "selectVersionUrl encodes dev versions cleanly" {
    const allocator = std.testing.allocator;

    const url_stable = try selectVersionUrl(allocator, "0.14.0");
    defer allocator.free(url_stable);
    try std.testing.expectEqualStrings(
        "https://releases.zigtools.org/v1/zls/select-version?zig_version=0.14.0&compatibility=only-runtime",
        url_stable,
    );

    const url_dev = try selectVersionUrl(allocator, "0.18.0-dev.10+abc123");
    defer allocator.free(url_dev);
    try std.testing.expectEqualStrings(
        "https://releases.zigtools.org/v1/zls/select-version?zig_version=0.18.0-dev.10%2Babc123&compatibility=only-runtime",
        url_dev,
    );
}

test "parseZlsArtifact parses valid response and error payloads" {
    const allocator = std.testing.allocator;
    const fixture =
        \\{
        \\  "version": "0.14.0",
        \\  "date": "2025-03-06",
        \\  "x86_64-linux": {
        \\    "tarball": "https://builds.zigtools.org/zls-linux-x86_64-0.14.0.tar.xz",
        \\    "shasum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\    "size": "3369008"
        \\  }
        \\}
    ;

    var art = try parseZlsArtifact(allocator, fixture, "x86_64-linux");
    defer art.deinit(allocator);
    try std.testing.expectEqualStrings("0.14.0", art.version);
    try std.testing.expectEqualStrings("2025-03-06", art.date);
    try std.testing.expectEqualStrings("https://builds.zigtools.org/zls-linux-x86_64-0.14.0.tar.xz", art.tarball);
    try std.testing.expectEqualStrings("3369008", art.size);

    try std.testing.expectError(
        DownloadError.TargetNotAvailable,
        parseZlsArtifact(allocator, fixture, "aarch64-macos"),
    );

    const err_fixture =
        \\{ "code": 1, "message": "No compatible ZLS version found" }
    ;
    try std.testing.expectError(
        ZlsError.ZlsVersionNotFound,
        parseZlsArtifact(allocator, err_fixture, "x86_64-linux"),
    );
}
