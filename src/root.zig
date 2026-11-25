const std = @import("std");

pub const paths = @import("paths.zig");
pub const Paths = paths.Paths;

pub const version = @import("version.zig");
pub const Version = version.Version;

pub const resolver = @import("resolver.zig");
pub const resolve = resolver.resolve;
pub const ResolvedVersion = resolver.ResolvedVersion;
pub const ResolutionSource = resolver.ResolutionSource;

pub const router = @import("router.zig");
pub const Router = router.Router;

pub const downloader = @import("downloader.zig");

test {
    _ = paths;
    _ = version;
    _ = resolver;
    _ = router;
    _ = downloader;
}
