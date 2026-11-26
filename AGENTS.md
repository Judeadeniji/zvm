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
- **Always Commit After Each Step**: Whenever a step or milestone is completed and verified, immediately commit the changes.

## Architectural Rules & Separation of Concerns

- **Strict Separation of Concerns**: Do **not** jam everything into one or two files. Every module must have a single, cohesive responsibility.
- **Modular Directory & File Structure**:
  - `src/errors.zig`: Centralized closed domain error sets (`PathError`, `VersionParseError`, `ConstraintParseError`, `ResolveError`, `ShimError`, `MinisigError`, `DownloadError`, `CliError`); return and match `<ErrorSet>.Member` instead of ad-hoc `error.<Member>` literals.
  - `src/paths.zig`: Manages the root ZVM directory structure (`~/.zvm/versions/`, `bin/`, `cache/`, `default`), environment overrides (`ZVM_PATH`, `XDG_DATA_HOME`), and path resolution.
  - `src/version.zig`: Represents versions (`SemVer`, `master`), version ordering, comparison, and constraint checking.
  - `src/resolver.zig`: Traverses parent directories, parses `.zig-version` and `build.zig.zon`, and determines the target version according to the resolution hierarchy.
  - `src/router.zig`: Handles process delegation (`std.process.replace` / child process spawning) to transparently execute the resolved Zig binary with forwarded arguments and streams.
  - `src/shim.zig`: Creates/inspects the `zig` shim symlink/binary and checks `PATH` precedence.
  - `src/minisig.zig`: Minisign (`Ed25519` + `BLAKE2b-512`) signature verification and public key resolution.
  - `src/downloader.zig`: Release metadata fetching, downloading, SHA-256 integrity verification, and archive extraction.
  - `src/zls_downloader.zig`: ZLS release discovery (`releases.zigtools.org`), SHA-256 verification, and paired extraction.
  - `src/cli/`: CLI subcommands are modularized into dedicated files (e.g., `src/cli/install.zig`, `src/cli/use.zig`, `src/cli/pin.zig`, `src/cli/list.zig`, `src/cli/setup.zig`, `src/cli/doctor.zig`, `src/cli/clean.zig`, `src/cli/config.zig`, `src/cli/env.zig`, `src/cli/completions.zig`, `src/cli/zls.zig`), while `src/main.zig` and `src/cli/root.zig` wire the entrypoint and command tree.

## Zig 0.17.0 API & Idioms (from `.agents/skills/zig-0-17`)

All code in this project targets **Zig 0.17.0**. Adhere to the following Zig 0.17 idioms:

- **String Printing**: Use `allocator.print(...)` directly. `std.fmt.allocPrint` has moved into `std.mem.Allocator`.
- **Enum Conversions**: Use `@backingInt(val)` and `@fromBackingInt(val)` instead of `@intFromEnum` / `@enumFromInt`.
- **Array Repetition**: Use `@splat(val)`. The `[1]T{val} ** len` repetition syntax was removed in 0.17.
- **Bitcasts**: `@bitCast` is strictly for logical bit representation; do not use on `extern struct` or `extern union` (use `@ptrCast` instead).
- **ArrayList**: Use `list.last()` (returns `?T`) instead of `getLastOrNull()`, and `list.last().?` instead of `getLast()`.
- **Memory Allocation**: Use `std.heap.SafeAllocator` for safe/debug allocation instead of `DebugAllocator`.
- **Syntax Removals**:
  - `void{}` is removed; use `{}`.
  - `errdefer |err|` capture syntax is removed. Wrap logic in an inner function and use `catch |err|`.
  - `i0` is removed; use `u0`.
- **Standard Entrypoint**: `pub fn main(init: std.process.Init) !void`. Access system services via `init.io`, `init.gpa`, `init.arena`, and `init.environ_map`.
- **IO & Filesystem**: In Zig 0.17, file I/O operations are organized under `std.Io` and `std.Io.Dir` / `std.Io.File`.
- read @./.agents/skills/zig-0-17

## Idiomatic Zig & Coding Standards

Idiomatic Zig favors explicit control, predictable performance, and clear imperative code over hidden allocations or heavy abstractions.

### Core Idioms & Patterns
- **Explicit allocators**: Pass `std.mem.Allocator` into functions that allocate rather than relying on hidden global allocators.
- **Explicit error handling**: Return error unions (`!T`) and propagate errors with `try` or handle them with `catch` and `errdefer`.
- **Cleanup with `defer` and `errdefer`**: Pair resource acquisition with `defer` for unconditional cleanup or `errdefer` for cleanup only on error paths.
- **Imperative loops over pipelines**: Use explicit `for` and `while` loops rather than chained functional pipelines for clarity and predictable control flow.
- **Dot literals (`.{ ... }`)**: Use anonymous struct, tuple, and enum literals when the target type is already known from context.
- **Intrusive data structures**: Embed linking fields directly inside structs when cache locality or zero-wrapper layout matters (e.g., linked lists, arena-style patterns).
- **Standard Library Preference**: Prefer the Zig standard library (`std`) over external dependencies where practical (e.g., `std.http.Client`, `std.json`, `std.tar`, `std.compress.gzip`, `std.Io`, `std.process`).

### Naming & Structure
- **Variables & fields**: `snake_case` (e.g., `file_path`, `version_str`).
- **Functions**: `camelCase` (e.g., `resolveVersion`, `installRelease`).
- **Types & type-returning functions**: `PascalCase` (e.g., `VersionManager`, `ArrayList(comptime T: type)`).
- **Files**: `snake_case` for general modules (e.g., `version_router.zig`), or `PascalCase` when a `.zig` file directly exposes a single type (e.g., `Version.zig`), since every file is implicitly a struct.
