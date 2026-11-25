//! Semantic version representation, ordering, and constraint matching (`>=`, `^`, `~`, `master`).

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

pub const Constraint = struct {
    atoms: [max_atoms]Atom = undefined,
    len: usize = 0,

    pub const max_atoms = 8;

    pub const Op = enum {
        exact,
        gt,
        gte,
        lt,
        lte,
        caret,
        tilde,
    };

    pub const Atom = struct {
        op: Op,
        version: Version,

        pub fn parse(raw: []const u8) !Atom {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) return error.EmptyConstraint;

            const parsed_op: struct { op: Op, rest: []const u8 } = if (std.mem.startsWith(u8, trimmed, ">="))
                .{ .op = .gte, .rest = trimmed[2..] }
            else if (std.mem.startsWith(u8, trimmed, "<="))
                .{ .op = .lte, .rest = trimmed[2..] }
            else if (std.mem.startsWith(u8, trimmed, ">"))
                .{ .op = .gt, .rest = trimmed[1..] }
            else if (std.mem.startsWith(u8, trimmed, "<"))
                .{ .op = .lt, .rest = trimmed[1..] }
            else if (std.mem.startsWith(u8, trimmed, "^"))
                .{ .op = .caret, .rest = trimmed[1..] }
            else if (std.mem.startsWith(u8, trimmed, "~"))
                .{ .op = .tilde, .rest = trimmed[1..] }
            else if (std.mem.startsWith(u8, trimmed, "="))
                .{ .op = .exact, .rest = trimmed[1..] }
            else
                .{ .op = .exact, .rest = trimmed };

            const ver = try Version.parse(parsed_op.rest);
            if (ver.tag == .master and parsed_op.op != .exact) {
                return error.InvalidMasterConstraint;
            }
            return .{ .op = parsed_op.op, .version = ver };
        }

        pub fn satisfies(self: Atom, candidate: Version) bool {
            if (self.version.tag == .master) {
                return candidate.tag == .master;
            }
            if (candidate.tag == .master) {
                // `master` satisfies lower-bound-only (`>=`, `>`) constraints,
                // but does not match exact/upper-bounded/caret/tilde constraints.
                return switch (self.op) {
                    .gte, .gt => true,
                    .exact, .lt, .lte, .caret, .tilde => false,
                };
            }

            const cand_sv = candidate.semver.?;
            const req_sv = self.version.semver.?;
            const ord = cand_sv.order(req_sv);

            return switch (self.op) {
                .exact => ord == .eq,
                .gt => ord == .gt,
                .gte => ord != .lt,
                .lt => ord == .lt,
                .lte => ord != .gt,
                .caret => blk: {
                    if (ord == .lt) break :blk false;
                    const upper: SemanticVersion = if (req_sv.major > 0)
                        .{ .major = req_sv.major + 1, .minor = 0, .patch = 0 }
                    else if (req_sv.minor > 0)
                        .{ .major = 0, .minor = req_sv.minor + 1, .patch = 0 }
                    else
                        .{ .major = 0, .minor = 0, .patch = req_sv.patch + 1 };
                    break :blk cand_sv.order(upper) == .lt;
                },
                .tilde => blk: {
                    if (ord == .lt) break :blk false;
                    const upper: SemanticVersion = .{
                        .major = req_sv.major,
                        .minor = req_sv.minor + 1,
                        .patch = 0,
                    };
                    break :blk cand_sv.order(upper) == .lt;
                },
            };
        }
    };

    /// Creates a `>= <min_ver>` constraint.
    pub fn gte(min_ver: Version) Constraint {
        var c: Constraint = .{};
        c.atoms[0] = .{ .op = .gte, .version = min_ver };
        c.len = 1;
        return c;
    }

    /// Parses a version constraint string such as `"0.17.0"`, `"master"`, `">=0.16.0"`,
    /// `"^0.17.0"`, `"~0.17.0"`, or space-separated ranges like `">=0.16.0 <0.18.0"`.
    pub fn parse(text: []const u8) !Constraint {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyConstraint;

        var c: Constraint = .{};
        var it = std.mem.tokenizeAny(u8, trimmed, " \t,");
        while (it.next()) |token| {
            // Merge standalone operator tokens like `>= 0.17.0`? No, check below if token is bare operator:
            if (isBareOperator(token)) {
                const next_tok = it.next() orelse return error.MissingVersionAfterOperator;
                var joined_buf: [128]u8 = undefined;
                if (token.len + next_tok.len > joined_buf.len) return error.ConstraintTooLong;
                @memcpy(joined_buf[0..token.len], token);
                @memcpy(joined_buf[token.len .. token.len + next_tok.len], next_tok);
                // Re-parse using Version.parse on next_tok directly + op
                const atom_op = parseBareOp(token).?;
                const ver = try Version.parse(next_tok);
                if (ver.tag == .master and atom_op != .exact) return error.InvalidMasterConstraint;
                try c.append(.{ .op = atom_op, .version = ver });
                continue;
            }
            try c.append(try Atom.parse(token));
        }

        if (c.len == 0) return error.EmptyConstraint;
        return c;
    }

    fn parseBareOp(tok: []const u8) ?Op {
        if (std.mem.eql(u8, tok, ">=")) return .gte;
        if (std.mem.eql(u8, tok, "<=")) return .lte;
        if (std.mem.eql(u8, tok, ">")) return .gt;
        if (std.mem.eql(u8, tok, "<")) return .lt;
        if (std.mem.eql(u8, tok, "^")) return .caret;
        if (std.mem.eql(u8, tok, "~")) return .tilde;
        if (std.mem.eql(u8, tok, "=")) return .exact;
        return null;
    }

    fn isBareOperator(tok: []const u8) bool {
        return parseBareOp(tok) != null;
    }

    fn append(self: *Constraint, atom: Atom) !void {
        if (self.len >= max_atoms) return error.TooManyConstraintTerms;
        self.atoms[self.len] = atom;
        self.len += 1;
    }

    /// Returns true if the constraint is a single pinned version (`0.17.0` or `master`)
    /// rather than a range/operator constraint (`>=`, `^`, `~`, etc.).
    pub fn exactPin(self: *const Constraint) ?Version {
        if (self.len != 1) return null;
        if (self.atoms[0].op != .exact) return null;
        return self.atoms[0].version;
    }

    /// Checks whether `candidate` satisfies all terms of the constraint.
    pub fn satisfies(self: *const Constraint, candidate: Version) bool {
        for (self.atoms[0..self.len]) |atom| {
            if (!atom.satisfies(candidate)) return false;
        }
        return true;
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

test "Constraint exact, >=, ^, ~, and compound ranges" {
    const v160 = try Version.parse("0.16.0");
    const v170 = try Version.parse("0.17.0");
    const v171 = try Version.parse("0.17.1");
    const v180 = try Version.parse("0.18.0");
    const v123 = try Version.parse("1.2.3");
    const v190 = try Version.parse("1.9.0");
    const v200 = try Version.parse("2.0.0");
    const master = try Version.parse("master");

    // Exact pin
    const c_exact = try Constraint.parse("0.17.0");
    try std.testing.expect(c_exact.exactPin() != null);
    try std.testing.expect(c_exact.satisfies(v170));
    try std.testing.expect(!c_exact.satisfies(v171));
    try std.testing.expect(!c_exact.satisfies(master));

    // Master pin
    const c_master = try Constraint.parse("master");
    try std.testing.expect(c_master.exactPin() != null);
    try std.testing.expect(c_master.satisfies(master));
    try std.testing.expect(!c_master.satisfies(v170));

    // >= constraint (including space after operator)
    const c_gte = try Constraint.parse(">= 0.17.0");
    try std.testing.expect(c_gte.exactPin() == null);
    try std.testing.expect(!c_gte.satisfies(v160));
    try std.testing.expect(c_gte.satisfies(v170));
    try std.testing.expect(c_gte.satisfies(v171));
    try std.testing.expect(c_gte.satisfies(master));

    // Caret ^0.17.0 allows >=0.17.0 <0.18.0
    const c_caret_zero = try Constraint.parse("^0.17.0");
    try std.testing.expect(!c_caret_zero.satisfies(v160));
    try std.testing.expect(c_caret_zero.satisfies(v170));
    try std.testing.expect(c_caret_zero.satisfies(v171));
    try std.testing.expect(!c_caret_zero.satisfies(v180));
    try std.testing.expect(!c_caret_zero.satisfies(master));

    // Caret ^1.2.3 allows >=1.2.3 <2.0.0
    const c_caret_one = try Constraint.parse("^1.2.3");
    try std.testing.expect(c_caret_one.satisfies(v123));
    try std.testing.expect(c_caret_one.satisfies(v190));
    try std.testing.expect(!c_caret_one.satisfies(v200));

    // Tilde ~1.2.3 allows >=1.2.3 <1.3.0
    const c_tilde = try Constraint.parse("~1.2.3");
    try std.testing.expect(c_tilde.satisfies(v123));
    try std.testing.expect(!c_tilde.satisfies(v190));

    // Compound range >=0.16.0 <0.18.0
    const c_range = try Constraint.parse(">=0.16.0 <0.18.0");
    try std.testing.expect(c_range.satisfies(v160));
    try std.testing.expect(c_range.satisfies(v171));
    try std.testing.expect(!c_range.satisfies(v180));
}
