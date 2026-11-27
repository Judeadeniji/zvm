//! Self-updater for `zvm`, fetching GitHub Releases metadata, verifying SHA-256
//! checksums, extracting platform archives, and atomically replacing the binary.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const errors = @import("errors.zig");
const Paths = @import("paths.zig").Paths;
const Version = @import("version.zig").Version;
const downloader = @import("downloader.zig");

const UpgradeError = errors.UpgradeError;
const DownloadError = errors.DownloadError;

pub const github_api_base = "https://api.github.com/repos/Judeadeniji/zvm/releases";
pub const zvm_exe_name = if (Paths.is_windows) "zvm.exe" else "zvm";

pub const ReleaseAssetInfo = struct {
    tag_name: []const u8,
    asset_name: []const u8,
    download_url: []const u8,
    size: u64,
    sha256sums_url: ?[]const u8,

    pub fn deinit(self: *ReleaseAssetInfo, allocator: Allocator) void {
        allocator.free(self.tag_name);
        allocator.free(self.asset_name);
        allocator.free(self.download_url);
        if (self.sha256sums_url) |u| allocator.free(u);
    }
};

pub const UpgradeOptions = struct {
    target_tag: ?[]const u8 = null,
    nightly: bool = false,
    force: bool = false,
    current_version: []const u8,
    progress: ?downloader.ProgressCallback = null,
};

pub const UpgradeResult = struct {
    from_version: []const u8,
    to_tag: []const u8,
    checksum_verified: bool,
    already_up_to_date: bool,

    pub fn deinit(self: *UpgradeResult, allocator: Allocator) void {
        allocator.free(self.from_version);
        allocator.free(self.to_tag);
    }
};

/// Builds the GitHub Releases API URL for latest stable, `nightly` prereleases, or a specific tag.
pub fn releaseApiUrl(allocator: Allocator, target_tag: ?[]const u8, nightly: bool) Allocator.Error![]u8 {
    if (nightly) {
        return try allocator.print("{s}?per_page=30", .{github_api_base});
    }
    if (target_tag) |tag| {
        return try allocator.print("{s}/tags/{s}", .{ github_api_base, tag });
    }
    return try allocator.print("{s}/latest", .{github_api_base});
}

fn parseGithubReleaseObject(
    allocator: Allocator,
    root: std.json.ObjectMap,
    target_key: []const u8,
    is_windows: bool,
) !ReleaseAssetInfo {
    const tag_val = root.get("tag_name") orelse return UpgradeError.ReleaseNotFound;
    if (tag_val != .string or tag_val.string.len == 0) return UpgradeError.InvalidReleaseMetadata;
    const tag_name = tag_val.string;

    const assets_val = root.get("assets") orelse return UpgradeError.InvalidReleaseMetadata;
    if (assets_val != .array) return UpgradeError.InvalidReleaseMetadata;

    const ext: []const u8 = if (is_windows) "zip" else "tar.gz";
    const expected_asset = try allocator.print("zvm-{s}-{s}.{s}", .{ tag_name, target_key, ext });
    defer allocator.free(expected_asset);

    var download_url: ?[]const u8 = null;
    var size: u64 = 0;
    var sha_url: ?[]const u8 = null;

    for (assets_val.array.items) |item| {
        if (item != .object) continue;
        const name_val = item.object.get("name") orelse continue;
        const url_val = item.object.get("browser_download_url") orelse continue;
        if (name_val != .string or url_val != .string) continue;

        if (std.mem.eql(u8, name_val.string, expected_asset)) {
            download_url = url_val.string;
            if (item.object.get("size")) |sv| {
                if (sv == .integer and sv.integer >= 0) {
                    size = @intCast(sv.integer);
                }
            }
        } else if (std.mem.eql(u8, name_val.string, "SHA256SUMS.txt")) {
            sha_url = url_val.string;
        }
    }

    const found_url = download_url orelse return UpgradeError.AssetNotFound;

    const tag_copy = try allocator.dupe(u8, tag_name);
    errdefer allocator.free(tag_copy);
    const asset_copy = try allocator.dupe(u8, expected_asset);
    errdefer allocator.free(asset_copy);
    const url_copy = try allocator.dupe(u8, found_url);
    errdefer allocator.free(url_copy);
    const sha_copy = if (sha_url) |su| try allocator.dupe(u8, su) else null;

    return .{
        .tag_name = tag_copy,
        .asset_name = asset_copy,
        .download_url = url_copy,
        .size = size,
        .sha256sums_url = sha_copy,
    };
}

/// Parses a GitHub Release JSON payload and picks the asset matching `target_key`.
pub fn parseGithubRelease(
    allocator: Allocator,
    json_bytes: []const u8,
    target_key: []const u8,
    is_windows: bool,
) !ReleaseAssetInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return UpgradeError.InvalidReleaseMetadata;
    return try parseGithubReleaseObject(allocator, parsed.value.object, target_key, is_windows);
}

/// Parses a GitHub Releases list JSON payload and picks the newest non-draft nightly prerelease.
pub fn parseLatestNightlyRelease(
    allocator: Allocator,
    json_bytes: []const u8,
    target_key: []const u8,
    is_windows: bool,
) !ReleaseAssetInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return UpgradeError.InvalidReleaseMetadata;

    var saw_nightly = false;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get("draft")) |dv| {
            if (dv == .bool and dv.bool) continue;
        }
        const pre_val = item.object.get("prerelease") orelse continue;
        if (pre_val != .bool or !pre_val.bool) continue;

        const tag_val = item.object.get("tag_name") orelse continue;
        if (tag_val != .string or std.mem.indexOf(u8, tag_val.string, "nightly") == null) continue;

        saw_nightly = true;
        return parseGithubReleaseObject(allocator, item.object, target_key, is_windows) catch |err| switch (err) {
            UpgradeError.AssetNotFound => continue,
            else => return err,
        };
    }

    return if (saw_nightly) UpgradeError.AssetNotFound else UpgradeError.ReleaseNotFound;
}

/// Extracts the 64-char SHA-256 hex digest for `asset_name` from `SHA256SUMS.txt`.
pub fn parseSha256Sums(sums_bytes: []const u8, asset_name: []const u8) ?[]const u8 {
    var line_it = std.mem.splitScalar(u8, sums_bytes, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len < 66) continue;

        const sep_idx = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const digest = line[0..sep_idx];
        if (digest.len != 64) continue;

        const rest = std.mem.trimStart(u8, line[sep_idx..], " \t*");
        const base = std.fs.path.basename(rest);
        if (std.mem.eql(u8, rest, asset_name) or std.mem.eql(u8, base, asset_name)) {
            return digest;
        }
    }
    return null;
}

fn isNightlyVersion(v: std.SemanticVersion) bool {
    const pre = v.pre orelse return false;
    return std.mem.startsWith(u8, pre, "nightly");
}

/// Returns true if `target_tag` is strictly newer than `current_version`, or switches
/// from a stable release onto a nightly build.
pub fn needsUpgrade(current_version: []const u8, target_tag: []const u8) bool {
    if (std.mem.eql(u8, target_tag, "nightly")) return true;

    const clean_cur = std.mem.trimStart(u8, current_version, "vV");
    const clean_target = std.mem.trimStart(u8, target_tag, "vV");
    const cur_v = Version.parse(clean_cur) catch return !std.mem.eql(u8, clean_cur, clean_target);
    const tgt_v = Version.parse(clean_target) catch return !std.mem.eql(u8, clean_cur, clean_target);

    if (cur_v.semver != null and tgt_v.semver != null) {
        const cs = cur_v.semver.?;
        const ts = tgt_v.semver.?;
        if (!isNightlyVersion(cs) and isNightlyVersion(ts)) {
            return true;
        }
        const ord = ts.order(cs);
        if (ord != .eq) return ord == .gt;
        // SemVer ignores build metadata (`+sha`); for same-day nightlies, a different commit is newer.
        if (isNightlyVersion(ts)) {
            return !std.mem.eql(u8, cs.build orelse "", ts.build orelse "");
        }
        return false;
    }

    return tgt_v.order(cur_v) == .gt;
}

fn fetchGithubJson(io: Io, allocator: Allocator, environ_map: ?*const EnvironMap, url: []const u8) ![]u8 {
    var status: std.http.Status = undefined;
    const body = downloader.fetchUrlWithStatus(io, allocator, environ_map, url, &.{
        .{ .name = "User-Agent", .value = "zvm" },
        .{ .name = "Accept", .value = "application/vnd.github+json" },
    }, &status) catch |err| return githubFetchError(status, err);
    return body;
}

/// GitHub answers an unknown tag with 404, which is a wrong tag rather than a network
/// problem, and throttling with 429, which is retryable; the caller words and scores
/// all three differently.
fn githubFetchError(status: std.http.Status, err: anyerror) anyerror {
    if (err != DownloadError.HttpRequestFailed) return err;
    return switch (status) {
        .not_found => UpgradeError.ReleaseNotFound,
        .too_many_requests => UpgradeError.RateLimited,
        else => err,
    };
}

/// Classifies a failed `SHA256SUMS.txt` fetch. The archive itself downloaded fine, so
/// this is not the release query failing; outside throttling the distinction is only
/// that the digest is missing.
fn manifestFetchFailure(err: anyerror) anyerror {
    return switch (err) {
        UpgradeError.RateLimited => err,
        else => UpgradeError.ChecksumManifestUnavailable,
    };
}

/// Queries GitHub Releases for the target release asset without downloading the binary.
pub fn checkRelease(
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    target_tag: ?[]const u8,
    nightly: bool,
) !ReleaseAssetInfo {
    const api_url = try releaseApiUrl(allocator, target_tag, nightly);
    defer allocator.free(api_url);

    const json_bytes = try fetchGithubJson(io, allocator, environ_map, api_url);
    defer allocator.free(json_bytes);

    const tkey = try downloader.hostTargetKey();
    if (nightly) {
        return try parseLatestNightlyRelease(allocator, json_bytes, tkey, Paths.is_windows);
    }
    return try parseGithubRelease(allocator, json_bytes, tkey, Paths.is_windows);
}

/// Replaces `self_exe` with `staged_bin` using OS-safe atomic rename semantics.
fn replaceSelfExecutable(io: Io, allocator: Allocator, self_exe: []const u8, staged_bin: []const u8) !void {
    const cwd = Io.Dir.cwd();

    if (Paths.is_windows) {
        const old_exe = try allocator.print("{s}.old", .{self_exe});
        defer allocator.free(old_exe);
        cwd.deleteFile(io, old_exe) catch {};

        // Windows allows renaming a running executable, freeing the target filename.
        Io.Dir.rename(cwd, self_exe, cwd, old_exe, io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try Io.Dir.copyFile(cwd, staged_bin, cwd, self_exe, io, .{});
    } else {
        const tmp_exe = try allocator.print("{s}.new", .{self_exe});
        defer allocator.free(tmp_exe);
        cwd.deleteFile(io, tmp_exe) catch {};

        try Io.Dir.copyFile(cwd, staged_bin, cwd, tmp_exe, io, .{ .permissions = .fromMode(0o755) });
        errdefer cwd.deleteFile(io, tmp_exe) catch {};
        try Io.Dir.rename(cwd, tmp_exe, cwd, self_exe, io);
    }
}

/// Downloads, verifies, extracts, and atomically installs a new `zvm` binary over `self_exe`.
pub fn upgradeSelf(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    self_exe: []const u8,
    options: UpgradeOptions,
) !UpgradeResult {
    try paths.ensureDirs(io);

    var info = try checkRelease(io, allocator, environ_map, options.target_tag, options.nightly);
    defer info.deinit(allocator);

    if (!options.force and !needsUpgrade(options.current_version, info.tag_name)) {
        const from_copy = try allocator.dupe(u8, options.current_version);
        errdefer allocator.free(from_copy);
        const tag_copy = try allocator.dupe(u8, info.tag_name);
        return .{
            .from_version = from_copy,
            .to_tag = tag_copy,
            .checksum_verified = false,
            .already_up_to_date = true,
        };
    }

    const cache_path = try std.fs.path.join(allocator, &.{ paths.cache_dir, info.asset_name });
    defer allocator.free(cache_path);

    const expected_size: ?u64 = if (info.size > 0) info.size else null;
    try downloader.downloadToFile(io, allocator, environ_map, info.download_url, cache_path, expected_size, options.progress);

    var checksum_verified = false;
    if (info.sha256sums_url) |sums_url| {
        const sums_bytes = fetchGithubJson(io, allocator, environ_map, sums_url) catch |err| {
            // Without the digest the archive cannot be used, and a retry downloads it
            // again, so it is not left behind in the cache.
            Io.Dir.cwd().deleteFile(io, cache_path) catch {};
            return manifestFetchFailure(err);
        };
        defer allocator.free(sums_bytes);

        const digest = parseSha256Sums(sums_bytes, info.asset_name) orelse return UpgradeError.ChecksumNotFound;
        downloader.verifyFileSha256(io, cache_path, digest) catch |err| {
            Io.Dir.cwd().deleteFile(io, cache_path) catch {};
            return err;
        };
        checksum_verified = true;
    }

    // Unique per process so two concurrent upgrades do not share a staging dir.
    const stage_dir = try allocator.print("{s}{c}.zvm-upgrade-stage-{s}", .{
        paths.cache_dir,
        std.fs.path.sep,
        downloader.uniqueSuffix(io),
    });
    defer allocator.free(stage_dir);
    defer Io.Dir.cwd().deleteTree(io, stage_dir) catch {};

    try downloader.extractArchive(io, allocator, cache_path, stage_dir);

    const staged_bin = try std.fs.path.join(allocator, &.{ stage_dir, zvm_exe_name });
    defer allocator.free(staged_bin);
    Io.Dir.cwd().access(io, staged_bin, .{}) catch return UpgradeError.AssetNotFound;

    try replaceSelfExecutable(io, allocator, self_exe, staged_bin);

    // The archive was only needed until the binary was replaced. A failed delete must
    // not fail an upgrade that already succeeded; `zvm clean` covers the leftover.
    Io.Dir.cwd().deleteFile(io, cache_path) catch {};

    const from_copy = try allocator.dupe(u8, options.current_version);
    errdefer allocator.free(from_copy);
    const tag_copy = try allocator.dupe(u8, info.tag_name);
    return .{
        .from_version = from_copy,
        .to_tag = tag_copy,
        .checksum_verified = checksum_verified,
        .already_up_to_date = false,
    };
}

test "releaseApiUrl selects latest, nightly, or specific tag" {
    const allocator = std.testing.allocator;

    const latest = try releaseApiUrl(allocator, null, false);
    defer allocator.free(latest);
    try std.testing.expectEqualStrings(github_api_base ++ "/latest", latest);

    const nightly = try releaseApiUrl(allocator, null, true);
    defer allocator.free(nightly);
    try std.testing.expectEqualStrings(github_api_base ++ "?per_page=30", nightly);

    const tagged = try releaseApiUrl(allocator, "v0.2.0", false);
    defer allocator.free(tagged);
    try std.testing.expectEqualStrings(github_api_base ++ "/tags/v0.2.0", tagged);
}

test "parseLatestNightlyRelease picks newest non-draft nightly prerelease" {
    const allocator = std.testing.allocator;
    const fixture =
        \\[
        \\  {
        \\    "tag_name": "v0.2.0",
        \\    "prerelease": false,
        \\    "draft": false,
        \\    "assets": []
        \\  },
        \\  {
        \\    "tag_name": "v0.1.0-nightly.20261128+deadbee",
        \\    "prerelease": true,
        \\    "draft": true,
        \\    "assets": []
        \\  },
        \\  {
        \\    "tag_name": "v0.1.0-rc.1",
        \\    "prerelease": true,
        \\    "draft": false,
        \\    "assets": []
        \\  },
        \\  {
        \\    "tag_name": "v0.1.0-nightly.20261127+59b3757",
        \\    "prerelease": true,
        \\    "draft": false,
        \\    "assets": [
        \\      {
        \\        "name": "zvm-v0.1.0-nightly.20261127+59b3757-x86_64-linux.tar.gz",
        \\        "size": 98765,
        \\        "browser_download_url": "https://example.com/nightly.tar.gz"
        \\      }
        \\    ]
        \\  }
        \\]
    ;

    var info = try parseLatestNightlyRelease(allocator, fixture, "x86_64-linux", false);
    defer info.deinit(allocator);
    try std.testing.expectEqualStrings("v0.1.0-nightly.20261127+59b3757", info.tag_name);
    try std.testing.expectEqualStrings("zvm-v0.1.0-nightly.20261127+59b3757-x86_64-linux.tar.gz", info.asset_name);
}

test "parseGithubRelease and parseSha256Sums extract asset metadata" {
    const allocator = std.testing.allocator;
    const fixture =
        \\{
        \\  "tag_name": "v0.2.0",
        \\  "assets": [
        \\    {
        \\      "name": "zvm-v0.2.0-x86_64-linux.tar.gz",
        \\      "size": 123456,
        \\      "browser_download_url": "https://example.com/zvm-v0.2.0-x86_64-linux.tar.gz"
        \\    },
        \\    {
        \\      "name": "zvm-v0.2.0-x86_64-windows.zip",
        \\      "size": 234567,
        \\      "browser_download_url": "https://example.com/zvm-v0.2.0-x86_64-windows.zip"
        \\    },
        \\    {
        \\      "name": "SHA256SUMS.txt",
        \\      "size": 256,
        \\      "browser_download_url": "https://example.com/SHA256SUMS.txt"
        \\    }
        \\  ]
        \\}
    ;

    var linux_info = try parseGithubRelease(allocator, fixture, "x86_64-linux", false);
    defer linux_info.deinit(allocator);
    try std.testing.expectEqualStrings("v0.2.0", linux_info.tag_name);
    try std.testing.expectEqualStrings("zvm-v0.2.0-x86_64-linux.tar.gz", linux_info.asset_name);
    try std.testing.expectEqual(@as(u64, 123456), linux_info.size);
    try std.testing.expectEqualStrings("https://example.com/SHA256SUMS.txt", linux_info.sha256sums_url.?);

    var win_info = try parseGithubRelease(allocator, fixture, "x86_64-windows", true);
    defer win_info.deinit(allocator);
    try std.testing.expectEqualStrings("zvm-v0.2.0-x86_64-windows.zip", win_info.asset_name);

    try std.testing.expectError(
        UpgradeError.AssetNotFound,
        parseGithubRelease(allocator, fixture, "riscv64-linux", false),
    );

    const sums =
        \\0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  zvm-v0.2.0-x86_64-linux.tar.gz
        \\fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210  zvm-v0.2.0-x86_64-windows.zip
        \\
    ;
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        parseSha256Sums(sums, linux_info.asset_name).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), parseSha256Sums(sums, "missing.tar.gz"));
}

test "needsUpgrade compares semver and versioned nightly builds" {
    try std.testing.expect(!needsUpgrade("0.1.0", "v0.1.0"));
    try std.testing.expect(needsUpgrade("0.1.0", "v0.2.0"));
    try std.testing.expect(needsUpgrade("0.1.0", "nightly"));
    // Stable -> nightly channel switch.
    try std.testing.expect(needsUpgrade("0.1.0", "v0.1.0-nightly.20261127+59b3757"));
    // Same nightly build is already up to date; same-day newer commit is an upgrade.
    try std.testing.expect(!needsUpgrade("0.1.0-nightly.20261127+59b3757", "v0.1.0-nightly.20261127+59b3757"));
    try std.testing.expect(needsUpgrade("0.1.0-nightly.20261127+59b3757", "v0.1.0-nightly.20261127+deadbee"));
    // Newer / older nightly dates.
    try std.testing.expect(needsUpgrade("0.1.0-nightly.20261126+abc1111", "v0.1.0-nightly.20261127+59b3757"));
    try std.testing.expect(!needsUpgrade("0.1.0-nightly.20261127+59b3757", "v0.1.0-nightly.20261126+abc1111"));
    // Nightly -> stable release.
    try std.testing.expect(needsUpgrade("0.1.0-nightly.20261127+59b3757", "v0.1.0"));
    // An older target is not an upgrade; downgrading requires --force.
    try std.testing.expect(!needsUpgrade("0.2.0", "v0.1.0"));
    try std.testing.expect(!needsUpgrade("0.2.0", "0.2.0"));
}

test "githubFetchError turns a 404 into a missing release, not a network failure" {
    try std.testing.expectEqual(
        UpgradeError.ReleaseNotFound,
        githubFetchError(.not_found, DownloadError.HttpRequestFailed),
    );
    // A reachable host that answers with an error is still a failed request.
    try std.testing.expectEqual(
        DownloadError.HttpRequestFailed,
        githubFetchError(.internal_server_error, DownloadError.HttpRequestFailed),
    );
    // Throttling is its own failure, because retrying is the fix.
    try std.testing.expectEqual(
        UpgradeError.RateLimited,
        githubFetchError(.too_many_requests, DownloadError.HttpRequestFailed),
    );
    // The checksum manifest is a separate step from the release query.
    try std.testing.expectEqual(
        UpgradeError.ChecksumManifestUnavailable,
        manifestFetchFailure(DownloadError.HttpRequestFailed),
    );
    try std.testing.expectEqual(
        UpgradeError.RateLimited,
        manifestFetchFailure(UpgradeError.RateLimited),
    );
    // Transport errors never had a response, so they pass through untouched.
    try std.testing.expectEqual(
        error.ConnectionRefused,
        githubFetchError(undefined, error.ConnectionRefused),
    );
}
