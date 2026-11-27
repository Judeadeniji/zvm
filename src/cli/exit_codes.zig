//! Exit statuses for commands that report their own failures.
//!
//! Those handlers print a diagnostic and return `error.Reported`, and an error value
//! cannot carry a status, so the mapping from failure to status lives here and the
//! handler records the result on `AppContext.exit_code`. The statuses are documented
//! in the README's "Exit codes" section.

const std = @import("std");
const zvm = @import("zvm");
const report = @import("report.zig");
const context = @import("context.zig");

const ExitCode = context.ExitCode;

/// `zvm install`: downloading, verifying, and installing a Zig release.
pub fn installFailure(err: anyerror) u8 {
    if (isTransport(err)) return ExitCode.network;
    return switch (err) {
        zvm.errors.DownloadError.VersionNotFound,
        zvm.errors.DownloadError.TargetNotAvailable,
        => ExitCode.unavailable,

        zvm.errors.DownloadError.ChecksumMismatch,
        zvm.errors.DownloadError.InvalidExpectedChecksum,
        zvm.errors.DownloadError.SignatureVerificationFailed,
        zvm.errors.DownloadError.GlobalSignatureVerificationFailed,
        zvm.errors.DownloadError.KeyIdMismatch,
        => ExitCode.integrity,

        else => 0,
    };
}

/// `zvm zls install`: the paired ZLS release.
pub fn zlsFailure(err: anyerror) u8 {
    if (isTransport(err)) return ExitCode.network;
    return switch (err) {
        zvm.errors.ZlsError.ZlsVersionNotFound,
        zvm.errors.DownloadError.TargetNotAvailable,
        => ExitCode.unavailable,

        zvm.errors.DownloadError.ChecksumMismatch,
        zvm.errors.DownloadError.InvalidExpectedChecksum,
        => ExitCode.integrity,

        else => 0,
    };
}

/// `zvm upgrade`: discovering and replacing the zvm binary itself.
pub fn upgradeFailure(err: anyerror) u8 {
    if (isTransport(err)) return ExitCode.network;
    return switch (err) {
        zvm.errors.UpgradeError.ReleaseNotFound,
        zvm.errors.UpgradeError.AssetNotFound,
        zvm.errors.UpgradeError.ChecksumNotFound,
        => ExitCode.unavailable,

        // Throttling and a missing digest are both worth retrying, so they share the
        // transport status rather than looking like a bad release.
        zvm.errors.UpgradeError.RateLimited,
        zvm.errors.UpgradeError.ChecksumManifestUnavailable,
        => ExitCode.network,

        zvm.errors.DownloadError.ChecksumMismatch,
        zvm.errors.DownloadError.InvalidExpectedChecksum,
        => ExitCode.integrity,

        else => 0,
    };
}

/// Whether the failure is about reaching the host. A dead host reaches a command
/// unwrapped from the metadata fetch, so this recognizes more than the download
/// error that wraps it.
fn isTransport(err: anyerror) bool {
    return report.isNetworkError(err) or err == zvm.errors.DownloadError.HttpRequestFailed;
}

test "installFailure classifies unavailable, transport, and integrity failures" {
    try std.testing.expectEqual(ExitCode.unavailable, installFailure(zvm.errors.DownloadError.VersionNotFound));
    try std.testing.expectEqual(ExitCode.unavailable, installFailure(zvm.errors.DownloadError.TargetNotAvailable));
    try std.testing.expectEqual(ExitCode.network, installFailure(zvm.errors.DownloadError.HttpRequestFailed));
    try std.testing.expectEqual(ExitCode.network, installFailure(error.ConnectionRefused));
    try std.testing.expectEqual(ExitCode.integrity, installFailure(zvm.errors.DownloadError.ChecksumMismatch));
    try std.testing.expectEqual(ExitCode.integrity, installFailure(zvm.errors.DownloadError.KeyIdMismatch));
    // Anything else keeps the generic status rather than inventing one.
    try std.testing.expectEqual(0, installFailure(error.OutOfMemory));
}

test "zlsFailure and upgradeFailure use the same vocabulary" {
    try std.testing.expectEqual(ExitCode.unavailable, zlsFailure(zvm.errors.ZlsError.ZlsVersionNotFound));
    try std.testing.expectEqual(ExitCode.network, zlsFailure(error.ConnectionTimedOut));
    try std.testing.expectEqual(ExitCode.integrity, zlsFailure(zvm.errors.DownloadError.ChecksumMismatch));
    try std.testing.expectEqual(0, zlsFailure(error.OutOfMemory));

    try std.testing.expectEqual(ExitCode.unavailable, upgradeFailure(zvm.errors.UpgradeError.ReleaseNotFound));
    try std.testing.expectEqual(ExitCode.unavailable, upgradeFailure(zvm.errors.UpgradeError.ChecksumNotFound));
    try std.testing.expectEqual(ExitCode.network, upgradeFailure(zvm.errors.UpgradeError.RateLimited));
    try std.testing.expectEqual(ExitCode.network, upgradeFailure(zvm.errors.UpgradeError.ChecksumManifestUnavailable));
    try std.testing.expectEqual(ExitCode.network, upgradeFailure(zvm.errors.DownloadError.HttpRequestFailed));
    try std.testing.expectEqual(ExitCode.integrity, upgradeFailure(zvm.errors.DownloadError.ChecksumMismatch));
    try std.testing.expectEqual(0, upgradeFailure(zvm.errors.UpgradeError.ExecutableReplaceFailed));
}
