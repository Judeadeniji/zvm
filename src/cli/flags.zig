//! Shared flag definitions for commands that inspect version resolution.

const zli = @import("zli");

/// Treat `build.zig.zon`'s `minimum_zig_version` as an exact requirement
/// instead of a lower bound. The `ZVM_EXACT` environment variable provides the
/// same override for the `zig` shim, where a CLI flag cannot be passed.
pub const exact = zli.Flag{
    .name = "exact",
    .description = "Treat build.zig.zon minimum_zig_version as an exact requirement",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

/// Returns the command-line override for exact mode, or null when the flag was
/// not given so the resolver can fall back to `ZVM_EXACT`.
pub fn exactOverride(ctx: zli.CommandContext) ?bool {
    return if (ctx.isFlagSet("exact")) ctx.flag("exact", bool) else null;
}
