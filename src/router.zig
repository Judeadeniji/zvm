//! Transparent `zig` shim router that resolves the target compiler version and
//! replaces the current process image with all arguments and environment forwarded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const Paths = @import("paths.zig").Paths;
const resolver = @import("resolver.zig");

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

    /// Resolves the required Zig version for `current_dir` and delegates execution to
    /// the target Zig compiler binary, forwarding all arguments and exit status.
    pub fn routeAndExec(
        self: *const Router,
        current_dir: []const u8,
        passthrough_args: []const []const u8,
    ) !noreturn {
        const resolved = resolver.resolve(self.paths, self.io, self.allocator, self.environ_map, current_dir) catch |err| {
            var err_buf: [256]u8 = undefined;
            var err_writer = Io.File.Writer.init(.stderr(), self.io, &err_buf);
            const w = &err_writer.interface;

            switch (err) {
                error.NoCompatibleVersionInstalled => {
                    _ = w.write("error: No installed Zig version satisfies project minimum requirement in build.zig.zon.\n") catch {};
                    _ = w.write("hint: Run 'zvm list-remote' to check available releases, then 'zvm install <version>'.\n") catch {};
                },
                error.NoVersionConfigured => {
                    _ = w.write("error: No Zig version configured for current project or global default.\n") catch {};
                    _ = w.write("hint: Run 'zvm use <version>' to set a global default, or 'zvm pin <version>' for this project.\n") catch {};
                },
                else => {
                    _ = w.print("error: Failed to resolve Zig version: {s}\n", .{@errorName(err)}) catch {};
                },
            }
            w.flush() catch {};
            std.process.exit(1);
        };
        defer {
            var r = resolved;
            r.deinit(self.allocator);
        }

        // Check if version is installed
        if (!self.paths.isVersionInstalled(self.io, self.allocator, resolved.version)) {
            var err_buf: [256]u8 = undefined;
            var err_writer = Io.File.Writer.init(.stderr(), self.io, &err_buf);
            const w = &err_writer.interface;

            _ = w.print("error: Zig version '{s}' is not installed.\n", .{resolved.version}) catch {};
            _ = w.print("hint: Run 'zvm install {s}' to install it.\n", .{resolved.version}) catch {};
            w.flush() catch {};
            std.process.exit(1);
        }

        const target_bin = try self.paths.versionZigBin(self.allocator, resolved.version);
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
