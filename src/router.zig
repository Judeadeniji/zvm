//! Transparent `zig` shim router that resolves the target compiler version and
//! replaces the current process image with all arguments and environment forwarded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const Paths = @import("paths.zig").Paths;
const resolver = @import("resolver.zig");
const downloader = @import("downloader.zig");

pub const Router = struct {
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,

    pub fn init(paths: *const Paths, io: Io, allocator: Allocator, environ_map: ?*const EnvironMap) Router {
        return .{
            .paths = paths,
            .io = io,
            .allocator = allocator,
            .environ_map = environ_map,
        };
    }

    /// Determines whether the program was invoked as the `zig` command shim (e.g. `zig build`, `zig test`).
    pub fn isZigShim(argv0: []const u8) bool {
        // Handle both `/` and `\` regardless of host OS so path checks are uniform.
        const last_slash = std.mem.lastIndexOfAny(u8, argv0, "/\\");
        const base = if (last_slash) |idx| argv0[idx + 1 ..] else argv0;
        return std.mem.eql(u8, base, "zig") or std.mem.eql(u8, base, "zig.exe");
    }

    /// Converts a child process termination status into a POSIX-compatible exit code.
    pub fn termToExitCode(term: std.process.Child.Term) u8 {
        return switch (term) {
            .exited => |code| code,
            .signal => |sig| 128 +% @as(u8, @truncate(@backingInt(sig))),
            .stopped => |sig| 128 +% @as(u8, @truncate(@backingInt(sig))),
            .unknown => 1,
        };
    }

    /// Spawns a child process with inherited standard streams and waits for its exit code.
    /// Used on targets where `std.process.can_replace` is false (such as Windows).
    pub fn spawnAndWait(
        io: Io,
        argv: []const []const u8,
        environ_map: ?*const EnvironMap,
    ) !u8 {
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .environ_map = environ_map,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        errdefer child.kill(io);

        const term = try child.wait(io);
        return termToExitCode(term);
    }

    fn printExecError(io: Io, target_bin: []const u8, err: anyerror) void {
        var err_buf: [256]u8 = undefined;
        var err_writer = Io.File.Writer.init(.stderr(), io, &err_buf);
        const w = &err_writer.interface;
        _ = w.print("error: Failed to execute '{s}': {s}\n", .{ target_bin, @errorName(err) }) catch {};
        w.flush() catch {};
    }

    /// Checks whether auto-install is enabled via `ZVM_AUTO_INSTALL` or `<base_dir>/auto-install`.
    pub fn isAutoInstallEnabled(paths: *const Paths, io: Io, environ_map: ?*const EnvironMap) bool {
        if (environ_map) |env| {
            if (env.get("ZVM_AUTO_INSTALL")) |raw| {
                const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                if (std.ascii.eqlIgnoreCase(trimmed, "1") or
                    std.ascii.eqlIgnoreCase(trimmed, "true") or
                    std.ascii.eqlIgnoreCase(trimmed, "yes"))
                {
                    return true;
                }
                if (std.ascii.eqlIgnoreCase(trimmed, "0") or
                    std.ascii.eqlIgnoreCase(trimmed, "false") or
                    std.ascii.eqlIgnoreCase(trimmed, "no"))
                {
                    return false;
                }
            }
        }

        const flag_path = std.fs.path.join(paths.allocator, &.{ paths.base_dir, "auto-install" }) catch return false;
        defer paths.allocator.free(flag_path);
        Io.Dir.cwd().access(io, flag_path, .{}) catch return false;
        return true;
    }

    fn printStderr(io: Io, comptime fmt: []const u8, args: anytype) void {
        var err_buf: [512]u8 = undefined;
        var err_writer = Io.File.Writer.init(.stderr(), io, &err_buf);
        const w = &err_writer.interface;
        _ = w.print(fmt, args) catch {};
        w.flush() catch {};
    }

    fn autoInstallAndWait(self: *const Router, version: []const u8) bool {
        printStderr(self.io, "[zvm] Auto-installing Zig {s}...\n", .{version});
        var res = downloader.installVersion(self.paths, self.io, self.allocator, self.environ_map, version, .{}) catch |err| {
            printStderr(self.io, "error: Auto-install failed for Zig '{s}': {s}\n", .{ version, @errorName(err) });
            return false;
        };
        res.deinit(self.allocator);
        return true;
    }

    /// Resolves the required Zig version for `current_dir` and delegates execution to
    /// the target Zig compiler binary, forwarding all arguments and exit status.
    pub fn routeAndExec(
        self: *const Router,
        current_dir: []const u8,
        passthrough_args: []const []const u8,
    ) !noreturn {
        const auto_install = isAutoInstallEnabled(self.paths, self.io, self.environ_map);

        const target_version: []u8 = blk: {
            var resolved = resolver.resolve(self.paths, self.io, self.allocator, self.environ_map, current_dir) catch |err| {
                if (err == error.NoCompatibleVersionInstalled and auto_install) {
                    if (try resolver.findProjectMinimumVersion(self.io, self.allocator, current_dir)) |min_ver| {
                        errdefer self.allocator.free(min_ver);
                        if (!self.autoInstallAndWait(min_ver)) std.process.exit(1);
                        break :blk min_ver;
                    }
                }
                switch (err) {
                    error.NoCompatibleVersionInstalled => {
                        printStderr(self.io, "error: No installed Zig version satisfies project minimum requirement in build.zig.zon.\nhint: Run 'zvm list-remote' to check available releases, then 'zvm install <version>'.\n", .{});
                    },
                    error.NoVersionConfigured => {
                        printStderr(self.io, "error: No Zig version configured for current project or global default.\nhint: Run 'zvm use <version>' to set a global default, or 'zvm pin <version>' for this project.\n", .{});
                    },
                    else => {
                        printStderr(self.io, "error: Failed to resolve Zig version: {s}\n", .{@errorName(err)});
                    },
                }
                std.process.exit(1);
            };
            defer resolved.deinit(self.allocator);
            break :blk try self.allocator.dupe(u8, resolved.version);
        };
        defer self.allocator.free(target_version);

        if (!self.paths.isVersionInstalled(self.io, self.allocator, target_version)) {
            if (!auto_install or !self.autoInstallAndWait(target_version)) {
                if (!auto_install) {
                    printStderr(self.io, "error: Zig version '{s}' is not installed.\nhint: Run 'zvm install {s}' to install it.\n", .{ target_version, target_version });
                }
                std.process.exit(1);
            }
        }

        const target_bin = try self.paths.versionZigBin(self.allocator, target_version);
        defer self.allocator.free(target_bin);

        // Construct argv: [target_bin, arg1, arg2, ...]
        var argv = try self.allocator.alloc([]const u8, passthrough_args.len + 1);
        defer self.allocator.free(argv);

        argv[0] = target_bin;
        for (passthrough_args, 0..) |arg, i| {
            argv[i + 1] = arg;
        }

        if (std.process.can_replace) {
            const replace_err = std.process.replace(self.io, .{
                .argv = argv,
                .environ_map = self.environ_map,
            });
            printExecError(self.io, target_bin, replace_err);
            std.process.exit(1);
        } else {
            const exit_code = spawnAndWait(self.io, argv, self.environ_map) catch |err| {
                printExecError(self.io, target_bin, err);
                std.process.exit(1);
            };
            std.process.exit(exit_code);
        }
    }
};

test "isZigShim detection" {
    try std.testing.expect(Router.isZigShim("zig"));
    try std.testing.expect(Router.isZigShim("/usr/local/bin/zig"));
    try std.testing.expect(Router.isZigShim("C:\\bin\\zig.exe"));
    try std.testing.expect(!Router.isZigShim("zvm"));
    try std.testing.expect(!Router.isZigShim("/usr/local/bin/zvm"));
}

test "termToExitCode and spawnAndWait propagation" {
    try std.testing.expectEqual(0, Router.termToExitCode(.{ .exited = 0 }));
    try std.testing.expectEqual(42, Router.termToExitCode(.{ .exited = 42 }));
    try std.testing.expectEqual(1, Router.termToExitCode(.{ .unknown = 9 }));

    if (@import("builtin").target.os.tag != .windows) {
        const io = std.testing.io;
        const ok_code = try Router.spawnAndWait(io, &.{ "/bin/sh", "-c", "exit 0" }, null);
        try std.testing.expectEqual(0, ok_code);

        const fail_code = try Router.spawnAndWait(io, &.{ "/bin/sh", "-c", "exit 7" }, null);
        try std.testing.expectEqual(7, fail_code);
    }
}

test "isAutoInstallEnabled checks ZVM_AUTO_INSTALL and auto-install marker" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    try std.testing.expect(!Router.isAutoInstallEnabled(&paths, io, null));

    var env = EnvironMap.init(allocator);
    defer env.deinit();
    try env.put("ZVM_AUTO_INSTALL", "1");
    try std.testing.expect(Router.isAutoInstallEnabled(&paths, io, &env));

    // Explicit env "false" overrides marker file
    const marker = try std.fs.path.join(allocator, &.{ paths.base_dir, "auto-install" });
    defer allocator.free(marker);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "" });
    try std.testing.expect(Router.isAutoInstallEnabled(&paths, io, null));

    try env.put("ZVM_AUTO_INSTALL", "false");
    try std.testing.expect(!Router.isAutoInstallEnabled(&paths, io, &env));
}
