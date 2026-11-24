const std = @import("std");

pub const paths = @import("paths.zig");
pub const Paths = paths.Paths;

pub const version = @import("version.zig");
pub const Version = version.Version;

pub const resolver = @import("resolver.zig");
pub const resolve = resolver.resolve;
pub const ResolvedVersion = resolver.ResolvedVersion;
pub const ResolutionSource = resolver.ResolutionSource;

test {
    _ = paths;
    _ = version;
    _ = resolver;
}
