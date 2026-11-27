//! Transparent `zig` shim router that resolves the target compiler version and
//! replaces the current process image with all arguments and environment forwarded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const Paths = @import("paths.zig").Paths;
const env_flags = @import("env_flags.zig");
const resolver = @import("resolver.zig");
const downloader = @import("downloader.zig");
const zls_downloader = @import("zls_downloader.zig");
const ResolveError = @import("errors.zig").ResolveError;

pub const Router = struct {
    paths: *const Paths,
    io: Io,
    allocator: Allocator,
    environ_map: ?*const EnvironMap,
    /// Replaces the toolchain download in tests, which cannot fetch a real release.
    /// An error means the version is still missing, and its name is what gets reported.
    install_hook: ?*const fn (router: *const Router, version: []const u8) anyerror!void = null,
    /// The same seam for the ZLS paired install.
    zls_install_hook: ?*const fn (router: *const Router, zig_version: []const u8) anyerror!void = null,

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
        return isToolShim(argv0, "zig", "zig.exe");
    }

    /// Determines whether the program was invoked as the `zls` language server shim.
    pub fn isZlsShim(argv0: []const u8) bool {
        return isToolShim(argv0, "zls", "zls.exe");
    }

    fn isToolShim(argv0: []const u8, posix_name: []const u8, win_name: []const u8) bool {
        // Handle both `/` and `\` regardless of host OS so path checks are uniform.
        const last_slash = std.mem.lastIndexOfAny(u8, argv0, "/\\");
        const base = if (last_slash) |idx| argv0[idx + 1 ..] else argv0;
        return std.mem.eql(u8, base, posix_name) or std.mem.eql(u8, base, win_name);
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
        if (env_flags.boolOverride(environ_map, "ZVM_AUTO_INSTALL")) |overridden| return overridden;
        return paths.isMarkerSet(io, "auto-install");
    }

    fn printStderr(io: Io, comptime fmt: []const u8, args: anytype) void {
        var err_buf: [1024]u8 = undefined;
        var err_writer = Io.File.Writer.init(.stderr(), io, &err_buf);
        const w = &err_writer.interface;
        _ = w.print(fmt, args) catch {};
        w.flush() catch {};
    }

    /// Installs `version`, returning the underlying failure instead of a bare `false` so
    /// the caller can report why the install did not happen.
    fn autoInstallAndWait(self: *const Router, version: []const u8) anyerror!void {
        printStderr(self.io, "[zvm] Auto-installing Zig {s}...\n", .{version});
        if (self.install_hook) |hook| return hook(self, version);
        var res = try downloader.installVersion(self.paths, self.io, self.allocator, self.environ_map, version, .{});
        res.deinit(self.allocator);
    }

    fn reportAutoInstallFailure(self: *const Router, version: []const u8, err: anyerror) void {
        printStderr(self.io, "error: Auto-install failed for Zig '{s}': {s}\n", .{ version, @errorName(err) });
    }

    /// Installs the ZLS paired with `zig_version`, returning the underlying failure for
    /// the caller to report.
    fn autoInstallZlsAndWait(self: *const Router, zig_version: []const u8) anyerror!void {
        printStderr(self.io, "[zvm] Auto-installing ZLS for Zig {s}...\n", .{zig_version});
        if (self.zls_install_hook) |hook| return hook(self, zig_version);
        var res = try zls_downloader.installZls(self.paths, self.io, self.allocator, self.environ_map, zig_version, .{});
        res.deinit(self.allocator);
    }

    /// Warns when a `build.zig.zon` in the resolved project does not parse. The
    /// project is broken even if the scan fallback still recovers the version:
    /// `zig build` rejects the same manifest without a word from zvm.
    fn warnMalformedManifest(self: *const Router, resolved: resolver.ResolvedVersion) void {
        const path = resolved.malformed_zon_path orelse return;
        printStderr(
            self.io,
            "warning: '{s}' is not valid ZON\nhint: Run 'zvm doctor' to see the parse error.\n",
            .{path},
        );
    }

    /// Version the router should auto-install for `current_dir`, or null when the
    /// error is not one an install can fix or auto-install is disabled.
    ///
    /// Split out of `routeAndExec` so the branch can be exercised without actually
    /// spawning an installer.
    fn autoInstallCandidate(self: *const Router, current_dir: []const u8, err: ResolveError) !?[]u8 {
        if (err != ResolveError.NoCompatibleVersionInstalled) return null;
        if (!isAutoInstallEnabled(self.paths, self.io, self.environ_map)) return null;
        return resolver.findProjectMinimumVersion(self.io, self.allocator, current_dir);
    }

    /// Resolves the Zig version to run for `current_dir`, auto-installing it when a
    /// project manifest requires a version that is not installed.
    ///
    /// Every failure is reported here and returned as `error.Reported`, so the caller
    /// only turns it into an exit status. Split from `routeAndExec` so the auto-install
    /// path can be exercised without the final `exec`.
    fn resolveTargetVersion(self: *const Router, current_dir: []const u8) ![]u8 {
        const auto_install = isAutoInstallEnabled(self.paths, self.io, self.environ_map);

        const target_version: []u8 = blk: {
            var resolved = resolver.resolve(self.paths, self.io, self.allocator, self.environ_map, current_dir) catch |err| {
                if (try self.autoInstallCandidate(current_dir, err)) |min_ver| {
                    self.autoInstallAndWait(min_ver) catch |install_err| {
                        self.reportAutoInstallFailure(min_ver, install_err);
                        self.allocator.free(min_ver);
                        return error.Reported;
                    };
                    break :blk min_ver;
                }
                switch (err) {
                    ResolveError.NoCompatibleVersionInstalled => {
                        printStderr(self.io, "error: No installed Zig version satisfies project minimum requirement in build.zig.zon.\nhint: Run 'zvm list-remote' to check available releases, then 'zvm install <version>'.\n", .{});
                    },
                    ResolveError.UnmatchedZigVersionConstraint => {
                        printStderr(self.io, "error: No installed Zig version satisfies the constraint in .zig-version.\nhint: Run 'zvm install <version>' to install a matching release, or 'zvm pin <version>' to change the pin.\n", .{});
                    },
                    ResolveError.InvalidZigVersionConstraint => {
                        printStderr(self.io, "error: The .zig-version file does not contain a valid Zig version or constraint.\nhint: Use a version such as '0.17.0' or 'master', or a range like '^0.17.0'.\n", .{});
                    },
                    ResolveError.NoVersionConfigured => {
                        printStderr(self.io, "error: No Zig version configured for current project or global default.\nhint: Run 'zvm use <version>' to set a global default, or 'zvm pin <version>' for this project.\n", .{});
                    },
                    else => {
                        printStderr(self.io, "error: Failed to resolve Zig version: {s}\n", .{@errorName(err)});
                    },
                }
                return error.Reported;
            };
            defer resolved.deinit(self.allocator);
            self.warnMalformedManifest(resolved);
            break :blk try self.allocator.dupe(u8, resolved.version);
        };
        errdefer self.allocator.free(target_version);

        // A resolved version can still be missing locally (an exact manifest pin, for
        // example), so that case gets its own install attempt.
        if (!self.paths.isVersionInstalled(self.io, target_version)) {
            if (!auto_install) {
                printStderr(self.io, "error: Zig version '{s}' is not installed.\nhint: Run 'zvm install {s}' to install it.\n", .{ target_version, target_version });
                return error.Reported;
            }
            self.autoInstallAndWait(target_version) catch |install_err| {
                self.reportAutoInstallFailure(target_version, install_err);
                return error.Reported;
            };
        }

        return target_version;
    }

    /// Resolves the required Zig version for `current_dir` and delegates execution to
    /// the target Zig compiler binary, forwarding all arguments and exit status.
    pub fn routeAndExec(
        self: *const Router,
        current_dir: []const u8,
        passthrough_args: []const []const u8,
    ) !noreturn {
        const target_version = self.resolveTargetVersion(current_dir) catch std.process.exit(1);
        defer self.allocator.free(target_version);

        const target_bin = try self.paths.versionZigBin(self.allocator, target_version);
        defer self.allocator.free(target_bin);

        try self.execBinary(target_bin, passthrough_args);
    }

    /// Resolves the ZLS binary paired with the active Zig version (or `ZLS_PATH` / `zls-default`)
    /// and delegates execution transparently.
    pub fn routeAndExecZls(
        self: *const Router,
        current_dir: []const u8,
        passthrough_args: []const []const u8,
    ) !noreturn {
        if (self.environ_map) |env| {
            if (env.get("ZLS_PATH")) |zls_env| {
                const trimmed = std.mem.trim(u8, zls_env, " \t\r\n");
                if (trimmed.len > 0) {
                    try self.execBinary(trimmed, passthrough_args);
                }
            }
        }

        const chosen_version = self.resolveZlsVersion(current_dir) catch std.process.exit(1);
        defer self.allocator.free(chosen_version);

        const target_bin = try self.paths.zlsVersionBin(self.allocator, chosen_version);
        defer self.allocator.free(target_bin);

        try self.execBinary(target_bin, passthrough_args);
    }

    /// Resolves the Zig version whose ZLS should run for `current_dir` and makes sure that
    /// ZLS is installed, auto-installing it when enabled.
    ///
    /// Like `resolveTargetVersion`, every failure is reported here and returned as
    /// `error.Reported`, which keeps the auto-install path reachable without the final
    /// `exec`.
    fn resolveZlsVersion(self: *const Router, current_dir: []const u8) ![]u8 {
        const auto_install = isAutoInstallEnabled(self.paths, self.io, self.environ_map);

        const target_zig_version: []u8 = blk: {
            var resolved = resolver.resolve(self.paths, self.io, self.allocator, self.environ_map, current_dir) catch |err| {
                if (err == ResolveError.NoVersionConfigured) {
                    if (try self.paths.readZlsDefaultVersion(self.io, self.allocator)) |zls_def| {
                        break :blk zls_def;
                    }
                    printStderr(self.io, "error: No Zig or ZLS version configured.\nhint: Run 'zvm use <version>' and 'zvm zls install', or set ZLS_PATH.\n", .{});
                    return error.Reported;
                }
                if (err == ResolveError.NoCompatibleVersionInstalled) {
                    if (try resolver.findProjectMinimumVersion(self.io, self.allocator, current_dir)) |min_ver| {
                        break :blk min_ver;
                    }
                }
                printStderr(self.io, "error: Failed to resolve Zig version for ZLS: {s}\n", .{@errorName(err)});
                return error.Reported;
            };
            defer resolved.deinit(self.allocator);
            self.warnMalformedManifest(resolved);
            break :blk try self.allocator.dupe(u8, resolved.version);
        };
        defer self.allocator.free(target_zig_version);

        var chosen_version = try self.allocator.dupe(u8, target_zig_version);
        errdefer self.allocator.free(chosen_version);

        if (!self.paths.isZlsInstalled(self.io, chosen_version)) {
            if (auto_install) {
                self.autoInstallZlsAndWait(chosen_version) catch |install_err| {
                    printStderr(self.io, "error: Auto-install failed for ZLS (Zig '{s}'): {s}\n", .{ chosen_version, @errorName(install_err) });
                    return error.Reported;
                };
            } else if (try self.paths.readZlsDefaultVersion(self.io, self.allocator)) |zls_def| {
                self.allocator.free(chosen_version);
                chosen_version = zls_def;
                if (!self.paths.isZlsInstalled(self.io, chosen_version)) {
                    printStderr(self.io, "error: ZLS for Zig '{s}' is not installed.\nhint: Run 'zvm zls install {s}' to install it.\n", .{ target_zig_version, target_zig_version });
                    return error.Reported;
                }
            } else {
                printStderr(self.io, "error: ZLS for Zig '{s}' is not installed.\nhint: Run 'zvm zls install {s}' to install it.\n", .{ chosen_version, chosen_version });
                return error.Reported;
            }
        }

        return chosen_version;
    }

    fn execBinary(
        self: *const Router,
        target_bin: []const u8,
        passthrough_args: []const []const u8,
    ) !noreturn {
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

/// Stands in for `downloader.installVersion`: records the request and materialises the
/// binary the real installer would have placed.
const StubInstaller = struct {
    var calls: usize = 0;
    var last: ?[]const u8 = null;
    var failure: ?anyerror = null;

    fn install(router: *const Router, version: []const u8) anyerror!void {
        calls += 1;
        last = version;
        if (failure) |err| return err;

        const dir = try router.paths.versionDir(router.allocator, version);
        defer router.allocator.free(dir);
        try Io.Dir.cwd().createDirPath(router.io, dir);

        const bin = try router.paths.versionZigBin(router.allocator, version);
        defer router.allocator.free(bin);
        try Io.Dir.cwd().writeFile(router.io, .{ .sub_path = bin, .data = "zig" });
    }
};

/// Same idea as `StubInstaller`, for the ZLS paired install.
const StubZlsInstaller = struct {
    var calls: usize = 0;
    var last: ?[]const u8 = null;
    var failure: ?anyerror = null;

    fn install(router: *const Router, zig_version: []const u8) anyerror!void {
        calls += 1;
        last = zig_version;
        if (failure) |err| return err;

        const dir = try router.paths.zlsVersionDir(router.allocator, zig_version);
        defer router.allocator.free(dir);
        try Io.Dir.cwd().createDirPath(router.io, dir);

        const bin = try router.paths.zlsVersionBin(router.allocator, zig_version);
        defer router.allocator.free(bin);
        try Io.Dir.cwd().writeFile(router.io, .{ .sub_path = bin, .data = "zls" });
    }
};

test "resolveZlsVersion auto-installs the paired ZLS or reports why it could not" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    // Only 0.17.0 installed, while the manifest wants 0.19.0.
    const v_dir = try paths.versionDir(allocator, "0.17.0");
    defer allocator.free(v_dir);
    try cwd.createDirPath(io, v_dir);
    const zig_bin = try paths.versionZigBin(allocator, "0.17.0");
    defer allocator.free(zig_bin);
    try cwd.writeFile(io, .{ .sub_path = zig_bin, .data = "zig" });

    const zon_path = try std.fs.path.join(allocator, &.{ tmp_path, "build.zig.zon" });
    defer allocator.free(zon_path);
    try cwd.writeFile(io, .{
        .sub_path = zon_path,
        .data =
        \\.{
        \\    .name = .proj,
        \\    .version = "0.0.0",
        \\    .minimum_zig_version = "0.19.0",
        \\    .dependencies = .{},
        \\}
        ,
    });

    var env = EnvironMap.init(allocator);
    defer env.deinit();

    // Without the flag the missing ZLS is reported rather than downloaded.
    var without_auto = Router.init(&paths, io, allocator, &env);
    without_auto.zls_install_hook = &StubZlsInstaller.install;
    StubZlsInstaller.calls = 0;
    StubZlsInstaller.failure = null;
    try std.testing.expectError(error.Reported, without_auto.resolveZlsVersion(tmp_path));
    try std.testing.expectEqual(@as(usize, 0), StubZlsInstaller.calls);
    try std.testing.expect(!paths.isZlsInstalled(io, "0.19.0"));

    try env.put("ZVM_AUTO_INSTALL", "1");
    var router = Router.init(&paths, io, allocator, &env);
    router.zls_install_hook = &StubZlsInstaller.install;

    // The installer's own failure is reported with its reason.
    StubZlsInstaller.calls = 0;
    StubZlsInstaller.failure = error.DownloadFailed;
    try std.testing.expectError(error.Reported, router.resolveZlsVersion(tmp_path));
    try std.testing.expectEqual(@as(usize, 1), StubZlsInstaller.calls);
    try std.testing.expect(!paths.isZlsInstalled(io, "0.19.0"));

    // A successful install is what the router then runs.
    StubZlsInstaller.calls = 0;
    StubZlsInstaller.failure = null;
    const version = try router.resolveZlsVersion(tmp_path);
    defer allocator.free(version);
    try std.testing.expectEqualStrings("0.19.0", version);
    try std.testing.expectEqualStrings("0.19.0", StubZlsInstaller.last.?);
    try std.testing.expectEqual(@as(usize, 1), StubZlsInstaller.calls);
    try std.testing.expect(paths.isZlsInstalled(io, "0.19.0"));
}

test "resolveTargetVersion auto-installs the minimum a project requires" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    const zon_path = try std.fs.path.join(allocator, &.{ tmp_path, "build.zig.zon" });
    defer allocator.free(zon_path);
    try cwd.writeFile(io, .{
        .sub_path = zon_path,
        .data =
        \\.{
        \\    .name = .proj,
        \\    .version = "0.0.0",
        \\    .minimum_zig_version = "0.19.0",
        \\    .dependencies = .{},
        \\}
        ,
    });

    var env = EnvironMap.init(allocator);
    defer env.deinit();
    try env.put("ZVM_AUTO_INSTALL", "1");

    var router = Router.init(&paths, io, allocator, &env);
    router.install_hook = &StubInstaller.install;

    // A failed install is reported to the caller, which turns it into an exit status.
    StubInstaller.calls = 0;
    StubInstaller.failure = error.DownloadFailed;
    try std.testing.expectError(error.Reported, router.resolveTargetVersion(tmp_path));
    try std.testing.expectEqual(@as(usize, 1), StubInstaller.calls);
    try std.testing.expect(!paths.isVersionInstalled(io, "0.19.0"));

    // A successful one is what the router then runs.
    StubInstaller.calls = 0;
    StubInstaller.failure = null;
    const version = try router.resolveTargetVersion(tmp_path);
    defer allocator.free(version);
    try std.testing.expectEqualStrings("0.19.0", version);
    try std.testing.expectEqualStrings("0.19.0", StubInstaller.last.?);
    try std.testing.expectEqual(@as(usize, 1), StubInstaller.calls);
    try std.testing.expect(paths.isVersionInstalled(io, "0.19.0"));
}

test "resolveTargetVersion installs an exact pin that is missing and refuses without the flag" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    const zon_path = try std.fs.path.join(allocator, &.{ tmp_path, "build.zig.zon" });
    defer allocator.free(zon_path);
    try cwd.writeFile(io, .{
        .sub_path = zon_path,
        .data =
        \\.{
        \\    .name = .proj,
        \\    .version = "0.0.0",
        \\    .minimum_zig_version = "0.19.0",
        \\    .dependencies = .{},
        \\}
        ,
    });

    // Exact mode resolves the declared version even though nothing matches locally, so
    // this route reaches the `isVersionInstalled` check instead of the resolve failure.
    var env = EnvironMap.init(allocator);
    defer env.deinit();
    try env.put("ZVM_EXACT", "1");

    var without_auto = Router.init(&paths, io, allocator, &env);
    StubInstaller.calls = 0;
    try std.testing.expectError(error.Reported, without_auto.resolveTargetVersion(tmp_path));
    try std.testing.expectEqual(@as(usize, 0), StubInstaller.calls);

    try env.put("ZVM_AUTO_INSTALL", "1");
    var router = Router.init(&paths, io, allocator, &env);
    router.install_hook = &StubInstaller.install;
    StubInstaller.calls = 0;
    StubInstaller.failure = null;

    const version = try router.resolveTargetVersion(tmp_path);
    defer allocator.free(version);
    try std.testing.expectEqualStrings("0.19.0", version);
    try std.testing.expectEqual(@as(usize, 1), StubInstaller.calls);
    try std.testing.expect(paths.isVersionInstalled(io, "0.19.0"));
}

test "autoInstallCandidate picks the project minimum only when auto-install is on" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    // Only 0.17.0 installed, while the manifest wants 0.19.0.
    const v_dir = try paths.versionDir(allocator, "0.17.0");
    defer allocator.free(v_dir);
    try cwd.createDirPath(io, v_dir);
    const bin_path = try paths.versionZigBin(allocator, "0.17.0");
    defer allocator.free(bin_path);
    try cwd.writeFile(io, .{ .sub_path = bin_path, .data = "zig" });

    const zon_path = try std.fs.path.join(allocator, &.{ tmp_path, "build.zig.zon" });
    defer allocator.free(zon_path);
    try cwd.writeFile(io, .{
        .sub_path = zon_path,
        .data =
        \\.{
        \\    .name = .proj,
        \\    .version = "0.0.0",
        \\    .minimum_zig_version = "0.19.0",
        \\    .dependencies = .{},
        \\}
        ,
    });

    // The premise of the branch: resolution fails because nothing satisfies the manifest.
    try std.testing.expectError(
        ResolveError.NoCompatibleVersionInstalled,
        resolver.resolve(&paths, io, allocator, null, tmp_path),
    );

    var env = EnvironMap.init(allocator);
    defer env.deinit();
    try env.put("ZVM_AUTO_INSTALL", "1");

    var enabled = Router.init(&paths, io, allocator, &env);
    {
        const candidate = try enabled.autoInstallCandidate(tmp_path, ResolveError.NoCompatibleVersionInstalled);
        defer if (candidate) |name| allocator.free(name);
        try std.testing.expectEqualStrings("0.19.0", candidate.?);
    }

    // Without the flag the router reports the error instead of installing anything.
    var disabled = Router.init(&paths, io, allocator, null);
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try disabled.autoInstallCandidate(tmp_path, ResolveError.NoCompatibleVersionInstalled),
    );

    // Resolve errors that an install cannot fix are never turned into a download.
    const unfixable = [_]ResolveError{
        ResolveError.NoVersionConfigured,
        ResolveError.InvalidZigVersionConstraint,
        ResolveError.UnmatchedZigVersionConstraint,
    };
    for (unfixable) |other| {
        try std.testing.expectEqual(null, try enabled.autoInstallCandidate(tmp_path, other));
    }
}

test "ZVM_AUTO_INSTALL vocabulary reaches the routing decision" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(tmp_path);

    var paths = try Paths.init(allocator, null, tmp_path);
    defer paths.deinit();
    try paths.ensureDirs(io);

    var env = EnvironMap.init(allocator);
    defer env.deinit();

    // `routeAndExec` reads this once per invocation; every accepted spelling has to
    // survive it, not just "1".
    for ([_][]const u8{ "1", "true", "TRUE", " yes " }) |value| {
        try env.put("ZVM_AUTO_INSTALL", value);
        try std.testing.expect(Router.isAutoInstallEnabled(&paths, io, &env));
    }
    for ([_][]const u8{ "0", "false", "NO" }) |value| {
        try env.put("ZVM_AUTO_INSTALL", value);
        try paths.setMarker(io, "auto-install", true);
        try std.testing.expect(!Router.isAutoInstallEnabled(&paths, io, &env));
    }

    // An unrecognized value leaves the persistent marker in charge.
    try env.put("ZVM_AUTO_INSTALL", "sometimes");
    try std.testing.expect(Router.isAutoInstallEnabled(&paths, io, &env));
    try paths.setMarker(io, "auto-install", false);
    try std.testing.expect(!Router.isAutoInstallEnabled(&paths, io, &env));
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
