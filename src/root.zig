const std = @import("std");

pub const paths = @import("paths.zig");
pub const Paths = paths.Paths;

pub const version = @import("version.zig");
pub const Version = version.Version;

test {
    _ = paths;
    _ = version;
}
