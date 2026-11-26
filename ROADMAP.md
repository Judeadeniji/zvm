# Roadmap: zvm

This document outlines the development phases, architecture milestones, and planned features for `zvm` (Zig Version Manager).

---

## Phase 1: Core Foundation & Version Resolution

- [x] **Data Model & Directory Layout** (`src/paths.zig`)
  - [x] Define directory structure (`~/.zvm/versions/`, `~/.zvm/bin/`, `~/.zvm/cache/`, `~/.zvm/default`) and `ZVM_PATH` override.
  - [x] Implement platform-aware configuration directory discovery (`XDG_DATA_HOME` on Linux, `~/Library/Application Support` on macOS, `%LOCALAPPDATA%` on Windows).
- [x] **Semver & Version Representation** (`src/version.zig`)
  - [x] Parse semver strings (`X.Y.Z`, pre-releases, and `master` / `nightly`).
  - [x] Implement version ordering and `minimum_zig_version` satisfaction checks.
  - [x] Implement full semver constraint expressions (`>=`, `^`, `~`, compound ranges) for `.zig-version`.
- [x] **Project Context & Walk-up Resolver** (`src/resolver.zig`)
  - [x] Walk parent directories to discover `.zig-version`.
  - [x] Parse `build.zig.zon` and extract `minimum_zig_version`.
  - [x] Resolve precedence: `ZIG_VERSION` env > `.zig-version` > `build.zig.zon` > user global default.

---

## Phase 2: Transparent Router / Shim

- [x] **Execution Dispatcher** (`src/router.zig`)
  - [x] Forward calls to the resolved Zig binary transparently.
  - [x] Implement zero-overhead process replacement (`std.process.replace` / `execv`) on POSIX systems.
  - [x] Implement child process spawning with stream inheritance and exit code propagation on Windows (`spawnAndWait`, verified via `x86_64-windows` build).
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
  - [x] Add verification tests against real `.tar.xz`, `.tar.gz`, and `.zip` archives.
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

- [x] **Minisig Signature Verification** (`src/minisig.zig`, `src/downloader.zig`)
  - [x] Cryptographic `Ed25519` + `BLAKE2b-512` signature check for official releases (`-Dminisig-key`, `--minisig-key`, `ZVM_MINISIG_PUBLIC_KEY`, `~/.zvm/minisig.pub`).
- [x] **Auto-Install Option** (`src/router.zig`)
  - [x] `ZVM_AUTO_INSTALL` / `~/.zvm/auto-install` support to install missing versions automatically when `zig` is invoked.
- [x] **Shell Integration** (`src/cli/completions.zig`, `src/cli/env.zig`)
  - [x] Shell completions for Bash, Zsh, Fish, and PowerShell (`zvm completions`).
  - [x] Automatic environment hook and `PATH` setup (`zvm env`).
- [x] **CI & Cross-Platform Distribution** (`.github/workflows/ci.yml`)
  - [x] GitHub Actions CI matrix building and testing across Linux, macOS, and Windows.
  - [x] Standalone single-binary cross-compilation (`x86_64`/`aarch64` Linux & macOS, `x86_64` Windows) with build-time `-Dminisig-key` injection.

---

## Phase 6: ZLS & Editor Support

> **Goal**: First-class ZLS (Zig Language Server) management, automatically paired to the active Zig version, with zero-config editor integration.

### 6.1 — ZLS Directory Layout & Paths

- [x] Extend `src/paths.zig` with ZLS-specific paths:
  - `~/.zvm/zls-versions/<zig-version>/zls[.exe]` — ZLS binary paired to its Zig version.
  - `~/.zvm/bin/zls[.exe]` — ZLS shim (alongside the existing `zig` shim).
  - `~/.zvm/cache/zls-*.tar.xz` / `zls-*.zip` — cached ZLS archives.

### 6.2 — ZLS Metadata & Download (`src/zls_downloader.zig`)

- [x] Fetch ZLS release metadata from `https://releases.zigtools.org/v1/zls/select-version?zig_version=<ver>&compatibility=only-runtime`.
  - Response shape: `{ version, date, "<arch>-<os>": { tarball, shasum, size } }`.
- [x] SHA-256 verify ZLS archives against `shasum` from the API response.
- [x] Extract to `~/.zvm/zls-versions/<zig-version>/` (same staging + atomic-move pattern as Zig).
- [x] Cache downloaded archives in `~/.zvm/cache/`.

### 6.3 — ZLS Shim & Router

- [x] Extend `src/shim.zig` to create/update `~/.zvm/bin/zls[.exe]` shim.
- [x] Extend `src/router.zig` to resolve the correct ZLS binary:
  - Resolution order: `ZLS_PATH` env > ZLS paired to active Zig version > global ZLS default (`zls-default`).
  - Transparent delegation via `std.process.replace` / child-process spawn (same as `zig`).

### 6.4 — CLI Commands (`src/cli/`)

| Command | Description |
|---|---|
| `zvm zls install [<zig-version>]` | Install ZLS paired to the active (or specified) Zig version |
| `zvm zls install --force` | Reinstall even if already present |
| `zvm zls list` | List installed ZLS versions and which Zig version each is paired to |
| `zvm zls use <zig-version>` | Set the globally active ZLS (by its paired Zig version) |
| `zvm zls which [<zig-version>]` | Print path to ZLS paired to the active or specified Zig version |
| `zvm zls uninstall <zig-version>` | Remove a ZLS installation |
| `zvm zls update` | Upgrade ZLS paired to current Zig version to the latest compatible release |

- [x] Implement `src/cli/zls.zig` as the top-level `zvm zls` subcommand dispatcher.
- [x] Add `--with-zls` flag to `zvm install` and `zvm use` to co-install/switch ZLS automatically.
- [x] Extend `zvm doctor` to check ZLS shim state and pairing validity.
- [x] Extend `zvm clean` to include ZLS cache archives (shared `~/.zvm/cache/`).
- [x] Extend `zvm env` to emit ZLS path hints for editor config (`--editor`).
- [x] Extend `zvm completions` to cover all `zvm zls` subcommands.

### 6.5 — Editor Integration Guides & Tooling

> Guides live in `docs/editors/` and are linked from `README.md`.

- [x] **VS Code** (`docs/editors/vscode.md`)
- [x] **Neovim** (`docs/editors/neovim.md`)
- [x] **Helix** (`docs/editors/helix.md`)
- [x] **Emacs** (`docs/editors/emacs.md`)
- [x] **Zed** (`docs/editors/zed.md`)
- [x] `zvm env --editor <vscode|nvim|helix|emacs|zed>` — print a ready-to-paste editor config snippet.

### 6.6 — `zvm doctor` ZLS Checks

- [x] Check ZLS binary exists for the active Zig version.
- [x] Check `~/.zvm/bin/zls` shim exists and points to `zvm`.

### 6.7 — Tests

- [x] Unit tests for ZLS metadata parsing (embedded JSON fixture, same pattern as `downloader.zig`).
- [x] Unit tests for ZLS URL encoding (`selectVersionUrl`).
- [x] Unit tests for ZLS shim creation (`setupShimFor` in `src/shim.zig`).
