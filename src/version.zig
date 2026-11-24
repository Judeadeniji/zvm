const std = @import("std");
const Allocator = std.mem.Allocator;
const SemanticVersion = std.SemanticVersion;

pub const Version = struct {
    tag: Tag,
    semver: ?SemanticVersion = null,
    raw: []const u8,

    pub const Tag = enum {
        master,
        semver,
    };

    /// Parse a version string, e.g. "0.17.0", "v0.17.0", "master", "nightly", "0.17.0-dev.12+abc".
    pub fn parse(text: []const u8) !Version {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyVersionString;

        if (std.mem.eql(u8, trimmed, "master") or std.mem.eql(u8, trimmed, "nightly")) {
            return .{
                .tag = .master,
                .semver = null,
                .raw = "master",
            };
        }

        // Strip optional leading 'v' or 'V'
        const clean = if (trimmed.len > 1 and (trimmed[0] == 'v' or trimmed[0] == 'V'))
            trimmed[1..]
        else
            trimmed;

        const sv = try SemanticVersion.parse(clean);
        return .{
            .tag = .semver,
            .semver = sv,
            .raw = clean,
        };
    }

    /// Compare two versions. "master" is considered strictly newer than any numbered release.
    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.tag == .master and b.tag == .master) return .eq;
        if (a.tag == .master) return .gt;
        if (b.tag == .master) return .lt;

        return a.semver.?.order(b.semver.?);
    }

    /// Check if this version satisfies a given minimum required version constraint.
    pub fn satisfiesMinimum(self: Version, min: Version) bool {
        if (self.tag == .master) return true;
        if (min.tag == .master) return false;

        return self.semver.?.order(min.semver.?) != .lt;
    }

    /// Formats the version string into the writer.
    pub fn format(self: Version, writer: anytype) !void {
        switch (self.tag) {
            .master => try writer.writeAll("master"),
            .semver => {
                const sv = self.semver.?;
                try writer.print("{d}.{d}.{d}", .{ sv.major, sv.minor, sv.patch });
                if (sv.pre) |pre| try writer.print("-{s}", .{pre});
                if (sv.build) |bld| try writer.print("+{s}", .{bld});
            },
        }
    }

    /// Returns an allocated string representation of the version.
    pub fn toString(self: Version, allocator: Allocator) ![]u8 {
        switch (self.tag) {
            .master => return allocator.dupe(u8, "master"),
            .semver => {
                const sv = self.semver.?;
                if (sv.pre != null and sv.build != null) {
                    return allocator.print("{d}.{d}.{d}-{s}+{s}", .{ sv.major, sv.minor, sv.patch, sv.pre.?, sv.build.? });
                } else if (sv.pre) |pre| {
                    return allocator.print("{d}.{d}.{d}-{s}", .{ sv.major, sv.minor, sv.patch, pre });
                } else if (sv.build) |bld| {
                    return allocator.print("{d}.{d}.{d}+{s}", .{ sv.major, sv.minor, sv.patch, bld });
                } else {
                    return allocator.print("{d}.{d}.{d}", .{ sv.major, sv.minor, sv.patch });
                }
            },
        }
    }
};

test "parse master and releases" {
    const v_master = try Version.parse("master");
    try std.testing.expectEqual(Version.Tag.master, v_master.tag);

    const v_nightly = try Version.parse("nightly");
    try std.testing.expectEqual(Version.Tag.master, v_nightly.tag);

    const v_release = try Version.parse("0.17.0");
    try std.testing.expectEqual(Version.Tag.semver, v_release.tag);
    try std.testing.expectEqual(@as(usize, 0), v_release.semver.?.major);
    try std.testing.expectEqual(@as(usize, 17), v_release.semver.?.minor);
    try std.testing.expectEqual(@as(usize, 0), v_release.semver.?.patch);

    const v_with_prefix = try Version.parse("v0.16.0");
    try std.testing.expectEqual(Version.Tag.semver, v_with_prefix.tag);
    try std.testing.expectEqual(@as(usize, 16), v_with_prefix.semver.?.minor);
}

test "version ordering" {
    const v15 = try Version.parse("0.15.0");
    const v16 = try Version.parse("0.16.0");
    const v17 = try Version.parse("0.17.0");
    const master = try Version.parse("master");

    try std.testing.expectEqual(std.math.Order.lt, v15.order(v16));
    try std.testing.expectEqual(std.math.Order.lt, v16.order(v17));
    try std.testing.expectEqual(std.math.Order.gt, v17.order(v16));
    try std.testing.expectEqual(std.math.Order.eq, v17.order(v17));

    // Master is greater than all semver
    try std.testing.expectEqual(std.math.Order.gt, master.order(v17));
    try std.testing.expectEqual(std.math.Order.lt, v17.order(master));
    try std.testing.expectEqual(std.math.Order.eq, master.order(master));
}

test "satisfiesMinimum" {
    const v15 = try Version.parse("0.15.0");
    const v16 = try Version.parse("0.16.0");
    const v17 = try Version.parse("0.17.0");
    const master = try Version.parse("master");

    try std.testing.expect(v17.satisfiesMinimum(v16));
    try std.testing.expect(v16.satisfiesMinimum(v16));
    try std.testing.expect(!v15.satisfiesMinimum(v16));

    // Master satisfies any minimum version
    try std.testing.expect(master.satisfiesMinimum(v17));
    try std.testing.expect(master.satisfiesMinimum(v15));
}

test "toString formatting" {
    const allocator = std.testing.allocator;

    const v17 = try Version.parse("0.17.0");
    const str17 = try v17.toString(allocator);
    defer allocator.free(str17);
    try std.testing.expectEqualStrings("0.17.0", str17);

    const v_master = try Version.parse("master");
    const str_m = try v_master.toString(allocator);
    defer allocator.free(str_m);
    try std.testing.expectEqualStrings("master", str_m);
}
