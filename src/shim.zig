//! Manages creation and inspection of the `zig` shim binary/symlink in `bin/`
//! and diagnoses `PATH` precedence against system Zig installations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const errors = @import("errors.zig");
const Paths = @import("paths.zig").Paths;

pub const ShimError = errors.ShimError;

pub const ToolKind = enum {
    zig,
    zls,

    pub fn exeName(self: ToolKind) []const u8 {
        return switch (self) {
            .zig => Paths.zig_exe_name,
            .zls => Paths.zls_exe_name,
        };
    }

    pub fn shimPath(self: ToolKind, paths: *const Paths, allocator: Allocator) ![]u8 {
        return switch (self) {
            .zig => paths.zigShimPath(allocator),
            .zls => paths.zlsShimPath(allocator),
        };
    }
};

pub const ShimStatus = union(enum) {
    missing,
    valid: []const u8,
    wrong_target: []const u8,
    broken_symlink: []const u8,
    not_a_symlink,

    pub fn deinit(self: *ShimStatus, allocator: Allocator) void {
        switch (self.*) {
            .valid, .wrong_target, .broken_symlink => |target| allocator.free(target),
            .missing, .not_a_symlink => {},
        }
    }
};

pub const SetupOutcome = enum {
    created,
    updated,
    already_configured,
};

pub const SetupResult = struct {
    outcome: SetupOutcome,
    shim_path: []const u8,
    target_path: []const u8,

    pub fn deinit(self: *SetupResult, allocator: Allocator) void {
        allocator.free(self.shim_path);
        allocator.free(self.target_path);
    }
};

pub const PathCheck = struct {
    bin_dir_in_path: bool,
    bin_dir_index: ?usize,
    first_zig_dir: ?[]const u8,
    shim_takes_precedence: bool,

    pub fn deinit(self: *PathCheck, allocator: Allocator) void {
        if (self.first_zig_dir) |d| allocator.free(d);
    }
};

fn trimTrailingSeps(p: []const u8) []const u8 {
    if (p.len <= 1) return p;
    return std.mem.trimEnd(u8, p, "/\\");
}

fn pathsEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, trimTrailingSeps(a), trimTrailingSeps(b));
}

pub fn isZvmExePath(target: []const u8) bool {
    const last_slash = std.mem.lastIndexOfAny(u8, target, "/\\");
    const base = if (last_slash) |idx| target[idx + 1 ..] else target;
    return std.mem.eql(u8, base, "zvm") or std.mem.eql(u8, base, "zvm.exe");
}

/// Inspects `~/.zvm/bin/zig` (or `zig.exe`) and returns its current status.
pub fn inspectShim(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    expected_exe: ?[]const u8,
) (Allocator.Error || Io.Dir.ReadLinkError || Io.Dir.AccessError)!ShimStatus {
    return inspectShimFor(paths, io, allocator, .zig, expected_exe);
}

/// Inspects a managed shim (`zig` or `zls`) inside `~/.zvm/bin/` and returns its status.
pub fn inspectShimFor(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    tool: ToolKind,
    expected_exe: ?[]const u8,
) (Allocator.Error || Io.Dir.ReadLinkError || Io.Dir.AccessError)!ShimStatus {
    const shim_path = try tool.shimPath(paths, allocator);
    defer allocator.free(shim_path);

    const cwd = Io.Dir.cwd();

    if (Paths.is_windows) {
        cwd.access(io, shim_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        return .{ .valid = try allocator.dupe(u8, shim_path) };
    }

    var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const target_len = cwd.readLink(io, shim_path, &link_buf) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.NotLink => return .not_a_symlink,
        else => return err,
    };
    const target = link_buf[0..target_len];

    cwd.access(io, target, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .broken_symlink = try allocator.dupe(u8, target) },
        else => {},
    };

    if (expected_exe) |expected| {
        if (!std.mem.eql(u8, target, expected)) {
            return .{ .wrong_target = try allocator.dupe(u8, target) };
        }
    } else if (!isZvmExePath(target)) {
        return .{ .wrong_target = try allocator.dupe(u8, target) };
    }

    return .{ .valid = try allocator.dupe(u8, target) };
}

pub const SetupShimError = ShimError ||
    Allocator.Error ||
    Io.Dir.CreateDirPathError ||
    Io.Dir.ReadLinkError ||
    Io.Dir.AccessError ||
    Io.Dir.CopyFileError ||
    Io.Dir.SymLinkError;

/// Creates or updates the `zig` shim in `paths.bin_dir` pointing to `zvm_exe`.
pub fn setupShim(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    zvm_exe: []const u8,
    force: bool,
) SetupShimError!SetupResult {
    return setupShimFor(paths, io, allocator, .zig, zvm_exe, force);
}

/// Creates or updates a managed shim (`zig` or `zls`) in `paths.bin_dir` pointing to `zvm_exe`.
pub fn setupShimFor(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    tool: ToolKind,
    zvm_exe: []const u8,
    force: bool,
) SetupShimError!SetupResult {
    try paths.ensureDirs(io);

    const shim_path = try tool.shimPath(paths, allocator);
    errdefer allocator.free(shim_path);

    const target_copy = try allocator.dupe(u8, zvm_exe);
    errdefer allocator.free(target_copy);

    var status = try inspectShimFor(paths, io, allocator, tool, zvm_exe);
    defer status.deinit(allocator);

    const outcome: SetupOutcome = switch (status) {
        .valid => {
            if (!force) {
                return .{
                    .outcome = .already_configured,
                    .shim_path = shim_path,
                    .target_path = target_copy,
                };
            }
            // Force requested: fall through to update
            return try writeShim(io, shim_path, target_copy, .updated);
        },
        .missing => .created,
        .broken_symlink => .updated,
        .wrong_target, .not_a_symlink => blk: {
            if (!force) return ShimError.ShimAlreadyExists;
            break :blk .updated;
        },
    };

    return try writeShim(io, shim_path, target_copy, outcome);
}

fn writeShim(io: Io, shim_path: []const u8, target_path: []const u8, outcome: SetupOutcome) !SetupResult {
    const cwd = Io.Dir.cwd();
    if (Paths.is_windows) {
        // Symlinks on Windows require Developer Mode or admin rights; copy instead.
        try Io.Dir.copyFile(cwd, target_path, cwd, shim_path, io, .{});
    } else {
        try cwd.symLinkAtomic(io, target_path, shim_path, .{});
    }

    return .{
        .outcome = outcome,
        .shim_path = shim_path,
        .target_path = target_path,
    };
}

/// Inspects `PATH` to verify whether `paths.bin_dir` is included and takes precedence over other `zig` binaries.
pub fn checkPathOrder(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
) Allocator.Error!PathCheck {
    return checkPathOrderFor(paths, io, allocator, environ_map, .zig);
}

/// Inspects `PATH` to verify whether `paths.bin_dir` takes precedence for `tool` (`zig` or `zls`).
pub fn checkPathOrderFor(
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    tool: ToolKind,
) Allocator.Error!PathCheck {
    const path_env = if (environ_map) |env| (env.get("PATH") orelse "") else "";
    if (path_env.len == 0) {
        return .{
            .bin_dir_in_path = false,
            .bin_dir_index = null,
            .first_zig_dir = null,
            .shim_takes_precedence = false,
        };
    }

    const cwd = Io.Dir.cwd();
    var bin_dir_in_path = false;
    var bin_dir_index: ?usize = null;
    var first_zig_dir: ?[]const u8 = null;
    errdefer if (first_zig_dir) |d| allocator.free(d);
    var shim_takes_precedence = false;

    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    var idx: usize = 0;
    while (it.next()) |raw_entry| {
        if (raw_entry.len == 0) continue;
        defer idx += 1;

        const is_bin_dir = pathsEqual(raw_entry, paths.bin_dir);
        if (is_bin_dir and !bin_dir_in_path) {
            bin_dir_in_path = true;
            bin_dir_index = idx;
        }

        if (first_zig_dir == null) {
            const candidate = try std.fs.path.join(allocator, &.{ raw_entry, tool.exeName() });
            defer allocator.free(candidate);

            if (cwd.access(io, candidate, .{ .execute = !Paths.is_windows })) {
                first_zig_dir = try allocator.dupe(u8, raw_entry);
                shim_takes_precedence = is_bin_dir;
            } else |_| {}
        }
    }

    return .{
        .bin_dir_in_path = bin_dir_in_path,
        .bin_dir_index = bin_dir_index,
        .first_zig_dir = first_zig_dir,
        .shim_takes_precedence = shim_takes_precedence,
    };
}

test "setupShim creates, detects, and updates symlink" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();

    // Create a fake zvm executable target
    const fake_zvm = try std.fs.path.join(allocator, &.{ tmp_path, "zvm" });
    defer allocator.free(fake_zvm);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fake_zvm, .data = "fake-zvm" });

    var missing = try inspectShim(&paths, io, allocator, fake_zvm);
    defer missing.deinit(allocator);
    try std.testing.expectEqual(ShimStatus.missing, missing);

    var res1 = try setupShim(&paths, io, allocator, fake_zvm, false);
    defer res1.deinit(allocator);
    try std.testing.expectEqual(SetupOutcome.created, res1.outcome);

    var valid = try inspectShim(&paths, io, allocator, fake_zvm);
    defer valid.deinit(allocator);
    switch (valid) {
        // On POSIX the symlink target is fake_zvm; on Windows inspectShim
        // returns the shim_path itself because it copies instead of symlinking.
        .valid => |t| {
            if (Paths.is_windows) {
                const shim = try paths.zigShimPath(allocator);
                defer allocator.free(shim);
                try std.testing.expectEqualStrings(shim, t);
            } else {
                try std.testing.expectEqualStrings(fake_zvm, t);
            }
        },
        else => return error.TestUnexpectedResult,
    }

    // Running again without force reports already_configured
    var res2 = try setupShim(&paths, io, allocator, fake_zvm, false);
    defer res2.deinit(allocator);
    try std.testing.expectEqual(SetupOutcome.already_configured, res2.outcome);
}

test "inspectShim without an expected executable accepts any zvm target" {
    if (Paths.is_windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(rel_tmp_path);
    const tmp_path = try Io.Dir.cwd().realPathFileAlloc(io, rel_tmp_path, allocator);
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();

    const fake_zvm = try std.fs.path.join(allocator, &.{ tmp_path, "zvm" });
    defer allocator.free(fake_zvm);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fake_zvm, .data = "fake-zvm" });

    var setup = try setupShim(&paths, io, allocator, fake_zvm, false);
    defer setup.deinit(allocator);
    try Io.Dir.cwd().access(io, setup.shim_path, .{});

    // A shim pointing at any executable named `zvm` is healthy, even when it is
    // not the exact binary running `zvm doctor`.
    var valid = try inspectShim(&paths, io, allocator, null);
    defer valid.deinit(allocator);
    switch (valid) {
        .valid => |target| try std.testing.expectEqualStrings(fake_zvm, target),
        else => return error.TestUnexpectedResult,
    }

    // A symlink to something that is not a zvm executable is still suspicious.
    const fake_other = try std.fs.path.join(allocator, &.{ tmp_path, "other" });
    defer allocator.free(fake_other);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fake_other, .data = "not-zvm" });

    var replaced = try setupShim(&paths, io, allocator, fake_other, true);
    defer replaced.deinit(allocator);

    var wrong = try inspectShim(&paths, io, allocator, null);
    defer wrong.deinit(allocator);
    switch (wrong) {
        .wrong_target => |target| try std.testing.expectEqualStrings(fake_other, target),
        else => return error.TestUnexpectedResult,
    }
}

test "checkPathOrder detects precedence and shadowing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    const sys_dir = try std.fs.path.join(allocator, &.{ tmp_path, "sysbin" });
    defer allocator.free(sys_dir);
    try Io.Dir.cwd().createDirPath(io, sys_dir);

    const sys_zig = try std.fs.path.join(allocator, &.{ sys_dir, Paths.zig_exe_name });
    defer allocator.free(sys_zig);
    var f = try Io.Dir.cwd().createFile(io, sys_zig, .{
        .permissions = if (Paths.is_windows) .default_file else .fromMode(0o755),
    });
    f.close(io);

    const zvm_base = try std.fs.path.join(allocator, &.{ tmp_path, "zvmhome" });
    defer allocator.free(zvm_base);
    var paths = try Paths.init(allocator, null, zvm_base);
    defer paths.deinit();
    try paths.ensureDirs(io);

    const zvm_shim = try paths.zigShimPath(allocator);
    defer allocator.free(zvm_shim);
    var sf = try Io.Dir.cwd().createFile(io, zvm_shim, .{
        .permissions = if (Paths.is_windows) .default_file else .fromMode(0o755),
    });
    sf.close(io);

    // Case 1: sys_dir comes before paths.bin_dir -> shadowed
    var env_shadowed = EnvironMap.init(allocator);
    defer env_shadowed.deinit();
    const path_shadowed = try allocator.print("{s}{c}{s}", .{ sys_dir, std.fs.path.delimiter, paths.bin_dir });
    defer allocator.free(path_shadowed);
    try env_shadowed.put("PATH", path_shadowed);

    var check1 = try checkPathOrder(&paths, io, allocator, &env_shadowed);
    defer check1.deinit(allocator);
    try std.testing.expect(check1.bin_dir_in_path);
    try std.testing.expect(!check1.shim_takes_precedence);
    try std.testing.expectEqualStrings(sys_dir, check1.first_zig_dir.?);

    // Case 2: paths.bin_dir comes first -> takes precedence
    var env_ok = EnvironMap.init(allocator);
    defer env_ok.deinit();
    const path_ok = try allocator.print("{s}{c}{s}", .{ paths.bin_dir, std.fs.path.delimiter, sys_dir });
    defer allocator.free(path_ok);
    try env_ok.put("PATH", path_ok);

    var check2 = try checkPathOrder(&paths, io, allocator, &env_ok);
    defer check2.deinit(allocator);
    try std.testing.expect(check2.bin_dir_in_path);
    try std.testing.expect(check2.shim_takes_precedence);
    try std.testing.expectEqualStrings(paths.bin_dir, check2.first_zig_dir.?);
}

test "setupShimFor creates and inspects zls shim" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();

    const fake_zvm = try std.fs.path.join(allocator, &.{ tmp_path, "zvm" });
    defer allocator.free(fake_zvm);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fake_zvm, .data = "fake-zvm" });

    var res = try setupShimFor(&paths, io, allocator, .zls, fake_zvm, false);
    defer res.deinit(allocator);
    try std.testing.expectEqual(SetupOutcome.created, res.outcome);
    try std.testing.expect(std.mem.endsWith(u8, res.shim_path, Paths.zls_exe_name));

    var status = try inspectShimFor(&paths, io, allocator, .zls, fake_zvm);
    defer status.deinit(allocator);
    try std.testing.expect(status == .valid);
}
