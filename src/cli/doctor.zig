//! `zvm doctor` subcommand for diagnosing ZVM directories, shim health, and `PATH` precedence.

const std = @import("std");
const Io = std.Io;
const zli = @import("zli");
const zvm = @import("zvm");
const AppContext = @import("context.zig").AppContext;
const flags = @import("flags.zig");

pub fn command(init_options: zli.InitOptions) zli.CommandSetupErrors!*zli.Command {
    const cmd = try zli.Command.init(init_options, .{
        .name = "doctor",
        .description = "Check zvm directories, zig shim status, and PATH precedence",
    }, handle);
    try cmd.addFlag(flags.exact);
    return cmd;
}

fn handle(ctx: zli.CommandContext) !void {
    const app = ctx.getContextData(AppContext);
    const cwd = Io.Dir.cwd();

    try app.reporter.heading("zvm doctor\n\n", .{});

    // 1. Base & bin directories
    const base_exists = blk: {
        cwd.access(ctx.io, app.paths.base_dir, .{}) catch break :blk false;
        break :blk true;
    };
    if (base_exists) {
        try app.reporter.status(.ok, "Base directory: {s}\n", .{app.paths.base_dir});
    } else {
        try app.reporter.status(.warn, "Base directory missing: {s} (run 'zvm setup')\n", .{app.paths.base_dir});
    }

    // 1b. Project manifest sanity: explain a build.zig.zon that cannot be parsed,
    // because resolution silently ignores its minimum_zig_version.
    const manifest_path = try std.fs.path.join(ctx.allocator, &.{ app.cwd, "build.zig.zon" });
    defer ctx.allocator.free(manifest_path);

    const manifest_text = cwd.readFileAlloc(ctx.io, manifest_path, ctx.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (manifest_text) |text| ctx.allocator.free(text);

    if (manifest_text) |text| {
        if (try zvm.resolver.manifestErrorText(ctx.allocator, text)) |message| {
            defer ctx.allocator.free(message);
            try app.reporter.status(.warn, "build.zig.zon does not parse: {s}\n", .{manifest_path});
            try app.reporter.muted("{s}\n", .{std.mem.trimEnd(u8, message, "\n")});
            try app.reporter.muted("       Fix the manifest or remove it; until then its minimum_zig_version is ignored.\n", .{});
        }
    }

    // 2. Shim verification
    const shim_path = try app.paths.zigShimPath(ctx.allocator);
    defer ctx.allocator.free(shim_path);

    // Doctor accepts a shim pointing to the current executable (even if renamed)
    // or any other `zvm` executable (e.g., an older build).
    const self_exe = std.process.executablePathAlloc(ctx.io, ctx.allocator) catch null;
    defer if (self_exe) |p| ctx.allocator.free(p);

    var shim_status = try zvm.shim.inspectShim(app.paths, ctx.io, ctx.allocator, self_exe);
    defer shim_status.deinit(ctx.allocator);

    if (shim_status == .wrong_target and zvm.shim.isZvmExePath(shim_status.wrong_target)) {
        const valid_target = try ctx.allocator.dupe(u8, shim_status.wrong_target);
        shim_status.deinit(ctx.allocator);
        shim_status = .{ .valid = valid_target };
    }

    switch (shim_status) {
        .valid => |target| {
            try app.reporter.status(.ok, "Zig shim: {s} -> {s}\n", .{ shim_path, target });
        },
        .missing => {
            try app.reporter.status(.fail, "Zig shim missing at {s} (run 'zvm setup')\n", .{shim_path});
        },
        .broken_symlink => |target| {
            try app.reporter.status(.fail, "Zig shim symlink is broken: {s} -> {s} (run 'zvm setup --force')\n", .{ shim_path, target });
        },
        .wrong_target => |target| {
            try app.reporter.status(.warn, "Zig shim points to a non-zvm executable: {s} -> {s} (run 'zvm setup --force')\n", .{ shim_path, target });
        },
        .not_a_symlink => {
            try app.reporter.status(.warn, "{s} is a regular file, not a zvm symlink (run 'zvm setup --force')\n", .{shim_path});
        },
    }

    // 2b. ZLS shim verification
    const zls_shim_path = try app.paths.zlsShimPath(ctx.allocator);
    defer ctx.allocator.free(zls_shim_path);

    var zls_shim_status = try zvm.shim.inspectShimFor(app.paths, ctx.io, ctx.allocator, .zls, self_exe);
    defer zls_shim_status.deinit(ctx.allocator);

    if (zls_shim_status == .wrong_target and zvm.shim.isZvmExePath(zls_shim_status.wrong_target)) {
        const valid_target = try ctx.allocator.dupe(u8, zls_shim_status.wrong_target);
        zls_shim_status.deinit(ctx.allocator);
        zls_shim_status = .{ .valid = valid_target };
    }

    switch (zls_shim_status) {
        .valid => |target| {
            try app.reporter.status(.ok, "ZLS shim: {s} -> {s}\n", .{ zls_shim_path, target });
        },
        .missing => {
            try app.reporter.status(.info, "ZLS shim: not configured at {s} (run 'zvm setup')\n", .{zls_shim_path});
        },
        .broken_symlink => |target| {
            try app.reporter.status(.fail, "ZLS shim symlink is broken: {s} -> {s} (run 'zvm setup --force')\n", .{ zls_shim_path, target });
        },
        .wrong_target => |target| {
            try app.reporter.status(.warn, "ZLS shim points to a non-zvm executable: {s} -> {s} (run 'zvm setup --force')\n", .{ zls_shim_path, target });
        },
        .not_a_symlink => {
            try app.reporter.status(.warn, "{s} is a regular file, not a zvm symlink (run 'zvm setup --force')\n", .{zls_shim_path});
        },
    }

    // 3. PATH ordering check
    var path_check = try zvm.shim.checkPathOrder(app.paths, ctx.io, ctx.allocator, ctx.environ_map);
    defer path_check.deinit(ctx.allocator);

    if (!path_check.bin_dir_in_path) {
        try app.reporter.status(.fail, "'{s}' is not in PATH\n", .{app.paths.bin_dir});
        if (!zvm.Paths.is_windows) {
            try app.reporter.muted("       Add: export PATH=\"{s}:$PATH\"\n", .{app.paths.bin_dir});
        }
    } else if (!path_check.shim_takes_precedence) {
        try app.reporter.status(.warn, "PATH shadows zvm shim: first zig found in '{s}' (zvm bin at index {d})\n", .{
            path_check.first_zig_dir orelse "(none)",
            path_check.bin_dir_index orelse 0,
        });
        if (!zvm.Paths.is_windows) {
            try app.reporter.muted("       Prepend: export PATH=\"{s}:$PATH\"\n", .{app.paths.bin_dir});
        }
    } else {
        try app.reporter.status(.ok, "PATH order: '{s}' takes precedence for 'zig'\n", .{app.paths.bin_dir});
    }

    // 4. Installed versions
    const versions = try app.paths.listInstalledVersions(ctx.io, ctx.allocator);
    defer zvm.Paths.freeInstalledVersions(ctx.allocator, versions);
    try app.reporter.status(.info, "Installed Zig versions: {d}\n", .{versions.len});
    if (versions.len == 0) {
        try app.reporter.muted("       Next: Run 'zvm install <version>' (run 'zvm list-remote' to see available versions).\n", .{});
    }

    const zls_versions = try app.paths.listInstalledZlsVersions(ctx.io, ctx.allocator);
    defer zvm.Paths.freeInstalledVersions(ctx.allocator, zls_versions);
    try app.reporter.status(.info, "Installed ZLS versions: {d}\n", .{zls_versions.len});

    // 5. Active version resolution in current dir
    var resolved = zvm.resolveWithOptions(app.paths, ctx.io, ctx.allocator, ctx.environ_map, app.cwd, .{
        .exact = flags.exactOverride(ctx),
    }) catch |err| {
        const reason: []const u8 = switch (err) {
            zvm.errors.ResolveError.NoVersionConfigured => "no version configured",
            zvm.errors.ResolveError.NoCompatibleVersionInstalled => "no installed version satisfies minimum_zig_version in build.zig.zon",
            zvm.errors.ResolveError.UnmatchedZigVersionConstraint => "no installed version satisfies the constraint in .zig-version",
            zvm.errors.ResolveError.InvalidZigVersionConstraint => ".zig-version is not a valid version or constraint",
            else => "could not read the version configuration",
        };
        try app.reporter.status(.info, "Active version in '{s}': unresolved ({s})\n", .{ app.cwd, reason });
        if (versions.len > 0 and err == zvm.errors.ResolveError.NoVersionConfigured) {
            try app.reporter.muted("       Next: Run 'zvm use <version>' for a global default or 'zvm pin <version>' for this project.\n", .{});
        }
        return;
    };
    defer resolved.deinit(ctx.allocator);

    const is_installed = app.paths.isVersionInstalled(ctx.io, ctx.allocator, resolved.version);
    const state = if (is_installed) "installed" else "not installed";
    try app.reporter.status(.info, "Active version in '{s}': {s} ({s})\n", .{ app.cwd, resolved.version, state });

    if (app.paths.isZlsInstalled(ctx.io, ctx.allocator, resolved.version)) {
        const zls_meta = app.paths.readZlsVersionMeta(ctx.io, ctx.allocator, resolved.version) catch null;
        defer if (zls_meta) |m| ctx.allocator.free(m);
        if (zls_meta) |m| {
            try app.reporter.status(.ok, "Paired ZLS for Zig {s}: {s}\n", .{ resolved.version, m });
        } else {
            try app.reporter.status(.ok, "Paired ZLS for Zig {s}: installed\n", .{resolved.version});
        }
    } else {
        try app.reporter.status(.info, "Paired ZLS for Zig {s}: not installed (optional: 'zvm zls install')\n", .{resolved.version});
    }
}
