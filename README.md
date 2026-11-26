# zvm

A fast, transparent Zig version manager written in Zig.

`zvm` simplifies managing, installing, switching, and running multiple versions of the [Zig compiler](https://ziglang.org) (both stable releases and `master` builds).

## Features

- **Transparent Router / Shim**: Acts as the `zig` command in your `PATH`, delegating execution to the appropriate compiler version based on context (`std.process.replace`/`execv` on POSIX, child process spawn on Windows).
- **Context-Aware Version Resolution**:
  1. **Environment Variable**: `ZIG_VERSION` override.
  2. **Local Project Walk-up**:
     - `.zig-version` file (exact version, `master`, or semver constraints like `^0.17.0`, `~0.17.0`, `>=0.16.0 <0.18.0`).
     - `build.zig.zon` project config (honors `minimum_zig_version` by picking the newest compatible installed version).
  3. **Global Default**: User-configured fallback (`default` in ZVM's data directory).
- **Exact Minimum Mode**: Pass `--exact` to `zvm install`, `zvm current`, `zvm which`, `zvm doctor`, or `zvm list`, set `ZVM_EXACT=1`, or run `zvm config exact on` to treat `build.zig.zon`'s `minimum_zig_version` as an exact requirement instead of a lower bound.
- **Cryptographic & Integrity Verification**: Verifies downloaded archives with both SHA-256 checksums and Minisign (`Ed25519` + `BLAKE2b-512`) signatures.
- **Release & Cache Management**: Fetches `https://ziglang.org/download/index.json`, unpacks `.tar.xz`/`.tar.gz`/`.zip`, tracks `master` dev versions, and supports cache cleanup (`zvm clean`).
- **Shell Integration & Diagnostics**: Includes `zvm setup` (`zvm shim`), `zvm doctor`, `zvm env`, `zvm completions`, and `ZVM_AUTO_INSTALL`.

## Quick Start

```bash
# 1. Create the `zig` shim symlink in ~/.zvm/bin/ and check PATH precedence
zvm setup
zvm doctor

# 2. Add ~/.zvm/bin to PATH (or eval shell hook)
eval "$(zvm env bash)"

# 3. Install and activate a Zig version
zvm install 0.17.0
zvm use 0.17.0

# 4. Run zig transparently through the shim
zig version
```

## CLI Usage

```bash
# Install versions
zvm install                        # Install the active project's Zig version
zvm install --exact                # Install exact minimum_zig_version from build.zig.zon
zvm install 0.17.0                 # Install stable release (SHA-256 + Minisign verified)
zvm install master                 # Install/update master build (tracks resolved dev version)
zvm install 0.17.0 --force         # Reinstall even if already installed
zvm install 0.17.0 --minisig-key <KEY>  # Override Minisign public key
zvm install 0.17.0 --no-minisig    # Skip Minisign verification

# Switch & inspect versions
zvm use 0.17.0                     # Set global default
zvm pin 0.17.0                     # Pin exact version in .zig-version
zvm pin "^0.17.0"                  # Pin semver constraint in .zig-version
zvm list                           # List installed versions (* marks active)
zvm list-remote [--all]            # List upstream releases from ziglang.org
zvm current                        # Show active version and resolution source
zvm which [version]                # Print path to active or specified zig binary
zvm uninstall 0.16.0               # Remove an installed version

# Maintenance & shell integration
zvm setup [--force]                # Create/verify zig shim (alias: shim)
zvm doctor                         # Diagnose base dir, shim, and PATH precedence
zvm clean [--dry-run]              # Remove cached release archives
zvm config [auto-install|exact [on|off|toggle]] # Inspect or toggle persistent settings
zvm env <bash|zsh|fish|powershell> [--auto-install]
zvm completions <bash|zsh|fish|powershell>
```

## Configuration & Overrides

- **Base Directory**: `ZVM_PATH` overrides the data directory. Otherwise ZVM uses `$XDG_DATA_HOME/zvm` (fallback `$HOME/.zvm`) on Linux, `$XDG_DATA_HOME/zvm` (fallback `$HOME/Library/Application Support/zvm`) on macOS, and `%LOCALAPPDATA%\zvm` (fallback `%USERPROFILE%\.zvm`) on Windows.
- **Auto-Install**: Set `ZVM_AUTO_INSTALL=1` or run `zvm config auto-install on` (creates `<base_dir>/auto-install`) to automatically download and install missing project versions when `zig` is invoked.
- **Minisign Public Key**: Override the built-in ZSF public key at compile time via `-Dminisig-key=...` or at runtime via `--minisig-key`, `ZVM_MINISIG_PUBLIC_KEY`, or `<base_dir>/minisig.pub`.
- **Colored Output**: Colors are used only when the target stream is a terminal. Override detection with `ZVM_COLOR=always` or `ZVM_COLOR=never`; `NO_COLOR`, `CLICOLOR=0`, `CLICOLOR_FORCE=1`, and `TERM=dumb` are also honored.

## Building from Source

### Prerequisites
- Zig 0.17.0 (`zig17`)

### Build & Test

```bash
# Build
zig17 build

# Build with a custom compile-time Minisign public key
zig17 build -Doptimize=ReleaseSafe -Dminisig-key="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"

# Run unit tests
zig17 build test
```

## License

[MIT](LICENSE)
