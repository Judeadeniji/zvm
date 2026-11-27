//! Core library module for `zvm`, exposing path management, version parsing,
//! project resolution, transparent process routing, shim diagnostics, and downloading.

const std = @import("std");

pub const errors = @import("errors.zig");
pub const env_flags = @import("env_flags.zig");
pub const paths = @import("paths.zig");
pub const Paths = paths.Paths;

pub const version = @import("version.zig");
pub const Version = version.Version;
pub const Constraint = version.Constraint;

pub const resolver = @import("resolver.zig");
pub const resolve = resolver.resolve;
pub const resolveWithOptions = resolver.resolveWithOptions;
pub const ResolveOptions = resolver.ResolveOptions;
pub const ResolvedVersion = resolver.ResolvedVersion;
pub const ResolutionSource = resolver.ResolutionSource;

pub const router = @import("router.zig");
pub const Router = router.Router;

pub const downloader = @import("downloader.zig");
pub const zls_downloader = @import("zls_downloader.zig");
pub const self_updater = @import("self_updater.zig");
pub const shim = @import("shim.zig");
pub const minisig = @import("minisig.zig");

test {
    _ = errors;
    _ = paths;
    _ = version;
    _ = resolver;
    _ = router;
    _ = downloader;
    _ = zls_downloader;
    _ = self_updater;
    _ = shim;
    _ = minisig;
}
