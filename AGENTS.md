# Agent Guidelines

## Project Overview

`zvm` is a Zig version manager written in Zig. Its primary goal is to easily manage, install, switch, and maintain multiple versions of the Zig compiler (including stable releases and master/nightly builds).

### Core Architecture & Router Mechanism
- **Transparent Router / Shim**: `zvm` acts as (or provides a shim for) the `zig` command in `PATH`. When `zig` is invoked:
  - It resolves the target version dynamically based on the current directory context.
  - Transparently delegates execution to the resolved Zig binary (e.g. via `execv` on POSIX systems or child process spawn on Windows), forwarding all arguments, standard I/O streams, and exit codes.
- **Version Resolution Hierarchy**:
  1. Environment variable override (e.g. `ZIG_VERSION`).
  2. Ancestor directory walk-up:
     - `.zig-version` file (pinning an exact version, semver constraint, or `master`).
     - Project config: `build.zig.zon` honoring `minimum_zig_version` (resolves to the newest installed version satisfying the constraint).
  3. Global default version (stored in user config, e.g. `~/.zvm/default` or `config.json`).
  4. If no compatible version is installed: provide a clear error message with an option/hint to install it (e.g., `zvm install <version>`).

### Planned Features
- Fetch and parse official release metadata from `https://ziglang.org/download/index.json`.
- Download, verify (checksum/minisig if applicable), extract, and manage installed versions in a central directory (e.g., `~/.zvm/versions/<version>/`).
- Switch versions globally (`zvm use <version>`) or per-project (`zvm pin <version>` creating `.zig-version`).
- Cross-platform support (Linux, macOS, Windows).

## Toolchain & Command Usage

- Always use `zig17` instead of `zig` for all Zig-related commands (e.g., `zig17 build`, `zig17 build test`, `zig17 run`, etc.).
- Do **not** invoke the `zig` command directly; always use `zig17`.

## Idiomatic Zig & Coding Standards

Idiomatic Zig favors explicit control, predictable performance, and clear imperative code over hidden allocations or heavy abstractions.

### Core Idioms & Patterns
- **Explicit allocators**: Pass `std.mem.Allocator` into functions that allocate rather than relying on hidden global allocators.
- **Explicit error handling**: Return error unions (`!T`) and propagate errors with `try` or handle them with `catch` and `errdefer`.
- **Cleanup with `defer` and `errdefer`**: Pair resource acquisition with `defer` for unconditional cleanup or `errdefer` for cleanup only on error paths.
- **Imperative loops over pipelines**: Use explicit `for` and `while` loops rather than chained functional pipelines for clarity and predictable control flow.
- **Dot literals (`.{ ... }`)**: Use anonymous struct, tuple, and enum literals when the target type is already known from context.
- **Intrusive data structures**: Embed linking fields directly inside structs when cache locality or zero-wrapper layout matters (e.g., linked lists, arena-style patterns).
- **Standard Library Preference**: Prefer the Zig standard library (`std`) over external dependencies where practical (e.g., `std.http.Client`, `std.json`, `std.tar`, `std.compress.gzip`, `std.fs`, `std.process`).

### Naming & Structure
- **Variables & fields**: `snake_case` (e.g., `file_path`, `version_str`).
- **Functions**: `camelCase` (e.g., `resolveVersion`, `installRelease`).
- **Types & type-returning functions**: `PascalCase` (e.g., `VersionManager`, `ArrayList(comptime T: type)`).
- **Files**: `snake_case` for general modules (e.g., `version_router.zig`), or `PascalCase` when a `.zig` file directly exposes a single type (e.g., `Version.zig`), since every file is implicitly a struct.
