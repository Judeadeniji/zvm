# Roadmap: zvm

This document outlines the development phases, architecture milestones, and planned features for `zvm` (Zig Version Manager).

---

## Phase 1: Core Foundation & Version Resolution

- [x] **Data Model & Directory Layout** (`src/paths.zig`)
  - [x] Define directory structure (`~/.zvm/versions/`, `~/.zvm/bin/`, `~/.zvm/cache/`, `~/.zvm/default`) and `ZVM_PATH` override.
  - [ ] Implement platform-aware configuration directory discovery (`XDG_DATA_HOME` on Linux, `~/Library/Application Support` on macOS, `%LOCALAPPDATA%` on Windows).
- [x] **Semver & Version Representation** (`src/version.zig`)
  - [x] Parse semver strings (`X.Y.Z`, pre-releases, and `master` / `nightly`).
  - [x] Implement version ordering and `minimum_zig_version` satisfaction checks.
  - [ ] Implement full semver constraint expressions (`>=`, `^`, `~`) for `.zig-version`.
- [x] **Project Context & Walk-up Resolver** (`src/resolver.zig`)
  - [x] Walk parent directories to discover `.zig-version`.
  - [x] Parse `build.zig.zon` and extract `minimum_zig_version`.
  - [x] Resolve precedence: `ZIG_VERSION` env > `.zig-version` > `build.zig.zon` > user global default.

---

## Phase 2: Transparent Router / Shim

- [x] **Execution Dispatcher** (`src/router.zig`)
  - [x] Forward calls to the resolved Zig binary transparently.
  - [x] Implement zero-overhead process replacement (`std.process.replace` / `execv`) on POSIX systems.
  - [ ] Verify/implement child process spawning with stream inheritance and exit code propagation on Windows.
- [x] **Shim Management** (`src/shim.zig`)
  - [x] Generate a `zig` shim in `~/.zvm/bin/` pointing to the `zvm` dispatcher (`zvm setup` / `zvm shim`).
  - [x] Provide self-check helper (`zvm doctor`) to verify shim state and `PATH` priority.
- [x] **Friendly Fallbacks**
  - [x] Clear error reporting if no compatible version is installed, with guidance on how to install the required version (e.g. `Run 'zvm install 0.17.0' to install`).

---

## Phase 3: Release Discovery & Installation Engine

- [x] **Metadata Fetching** (`src/downloader.zig`)
  - [x] Fetch and parse `https://ziglang.org/download/index.json` using `std.http.Client` and `std.json`.
  - [x] Detect target system architecture and OS to pick appropriate tarball URLs.
- [x] **Download & Integrity Verification** (`src/downloader.zig`)
  - [x] Stream release archives to `~/.zvm/cache/` and reuse valid cached files.
  - [x] Compute SHA-256 checksums and verify against release manifest.
  - [x] Display bytes/percentage progress indication during archive downloads.
- [x] **Archive Extraction** (`src/downloader.zig`)
  - [x] Unpack `.tar.xz`, `.tar.gz`, or `.zip` directly into `~/.zvm/versions/<version>/` (via staging directory).
  - [x] Set appropriate executable permissions on extracted binaries (`executable_bit_only`).
  - [x] Add verification tests against real `.tar.xz` and `.tar.gz` archives (`.zip` test pending).
- [x] **Master / Nightly Handling**
  - [x] Track resolved `master` commit/dev version strings (`.zvm-version`) for `zvm install master` update checks.

---

## Phase 4: CLI Interface & Management Commands

- [x] **CLI Framework & Modular Commands** (`src/cli/`, powered by `zli`)
  - [x] Modularize subcommands under `src/cli/` with shared `AppContext` (`src/cli/context.zig`).
- [x] **Commands**
  - [x] `zvm install <version> [--force]`: Download, verify, and install a specific version or `master`.
  - [x] `zvm use <version>`: Set the global default version.
  - [x] `zvm pin <version>`: Pin version for the current directory by creating/updating `.zig-version`.
  - [x] `zvm list`: List locally installed Zig versions and highlight active version.
  - [x] `zvm list-remote [--all]`: List available upstream stable releases and `master`.
  - [x] `zvm current`: Display which version is active in the current directory and how it was resolved.
  - [x] `zvm which [version]`: Print path to the active or specified Zig executable.
  - [x] `zvm uninstall <version>`: Remove an installed Zig version.
  - [x] `zvm setup` / `zvm shim` & `zvm doctor`: Manage the `zig` shim and diagnose `PATH` precedence.
  - [x] `zvm clean [--dry-run]`: Remove cached download tarballs.

---

## Phase 5: Hardening & Advanced Features

- [ ] **Minisig Signature Verification**
  - Cryptographic signature check for official releases.
- [ ] **Auto-Install Option**
  - Optional flag / config to prompt or auto-install missing versions when entering a project.
- [ ] **Shell Integration**
  - Shell completions for Bash, Zsh, Fish, and PowerShell.
  - Automatic environment hook for instant subshell version switching.
- [ ] **CI & Cross-Platform Distribution**
  - GitHub Actions CI matrix building for Linux (x86_64, aarch64), macOS (Apple Silicon, Intel), and Windows (x86_64).
  - Standalone single-binary distribution.
