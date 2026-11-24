# Roadmap: zvm

This document outlines the development phases, architecture milestones, and planned features for `zvm` (Zig Version Manager).

---

## Phase 1: Core Foundation & Version Resolution

- [ ] **Data Model & Directory Layout**
  - Define directory structure (`~/.zvm/versions/`, `~/.zvm/bin/`, `~/.zvm/cache/`, `~/.zvm/default`).
  - Implement platform-aware configuration directory discovery (XDG on Linux, `~/Library/Application Support` on macOS, `%LOCALAPPDATA%` on Windows).
- [ ] **Semver & Version Representation**
  - Parse semver strings (`X.Y.Z`, pre-releases, and `master`).
  - Implement version comparisons and constraint checking (`>=`, `^`, `~`).
- [ ] **Project Context & Walk-up Resolver**
  - Walk parent directories to discover `.zig-version`.
  - Parse `build.zig.zon` and extract `minimum_zig_version`.
  - Resolve precedence: `ZIG_VERSION` env > `.zig-version` > `build.zig.zon` > user global default.

---

## Phase 2: Transparent Router / Shim

- [ ] **Execution Dispatcher**
  - Forward calls to the resolved Zig binary transparently.
  - Implement zero-overhead process replacement (`execv` / `execve`) on POSIX systems.
  - Implement process spawning with stream inheritance and exit code propagation on Windows.
- [ ] **Shim Management**
  - Generate a `zig` shim in `~/.zvm/bin/` pointing to the `zvm` dispatcher.
  - Provide self-check helper (`zvm doctor`) to verify PATH priority.
- [ ] **Friendly Fallbacks**
  - Clear error reporting if no compatible version is installed, with guidance on how to install the required version (e.g. `Run 'zvm install 0.17.0' to install`).

---

## Phase 3: Release Discovery & Installation Engine

- [ ] **Metadata Fetching**
  - Fetch and parse `https://ziglang.org/download/index.json` using `std.http.Client` and `std.json`.
  - Detect target system architecture and OS to pick appropriate tarball URLs.
- [ ] **Download & Integrity Verification**
  - Download release archives to cache directory with progress indication.
  - Compute SHA-256 checksums and verify against release manifest.
- [ ] **Archive Extraction**
  - Unpack `.tar.xz`, `.tar.gz`, or `.zip` directly into `~/.zvm/versions/<version>/`.
  - Set appropriate executable permissions on extracted binaries.
- [ ] **Master / Nightly Handling**
  - Support installing and updating `master` builds with commit hash tracking.

---

## Phase 4: CLI Interface & Management Commands

- [ ] **CLI Argument Parser**
  - Implement lightweight, dependency-free argument parser in idiomatic Zig.
- [ ] **Commands**
  - `zvm install <version>`: Download and install a specific version or `master`.
  - `zvm use <version>`: Set the global default version.
  - `zvm pin <version>`: Pin version for the current directory by creating/updating `.zig-version`.
  - `zvm list`: List locally installed Zig versions.
  - `zvm list-remote`: List available upstream stable releases and nightly builds.
  - `zvm current`: Display which version is active in the current directory and how it was resolved.
  - `zvm which [version]`: Print path to the active or specified Zig executable.
  - `zvm uninstall <version>`: Remove an installed Zig version.
  - `zvm clean`: Remove cached download tarballs.

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
