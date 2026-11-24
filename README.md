# zvm

A fast, transparent Zig version manager written in Zig.

`zvm` simplifies managing, installing, switching, and running multiple versions of the [Zig compiler](https://ziglang.org) (both stable releases and master/nightly builds).

## Features

- **Transparent Router / Shim**: Acts as the `zig` command in your `PATH`, delegating execution to the appropriate compiler version based on context.
- **Context-Aware Version Resolution**:
  1. **Environment Variable**: `ZIG_VERSION` override.
  2. **Local Project Walk-up**:
     - `.zig-version` file (explicit version, semantic constraint, or `master`).
     - `build.zig.zon` project config (honors `minimum_zig_version` by picking the newest compatible installed version).
  3. **Global Default**: User-configured fallback (`~/.zvm/default`).
- **Release Management**: Download, verify, extract, and maintain official Zig builds directly from `https://ziglang.org/download/index.json`.
- **Fast & Zero-Overhead**: Transparent process execution (`execv` on POSIX, child process spawn on Windows) preserving standard streams, exit codes, and arguments.

## CLI Usage (Planned)

```bash
# Install a version (stable release or nightly)
zvm install 0.17.0
zvm install master

# Switch versions
zvm use 0.17.0         # Set global default
zvm pin 0.17.0         # Pin version for the current project (.zig-version)

# List versions
zvm list               # List locally installed versions
zvm list-remote        # List available upstream releases

# Remove an installed version
zvm uninstall 0.16.0
```

## How the Router Works

When `zig` is invoked in a project directory:
1. `zvm` checks `ZIG_VERSION`.
2. `zvm` traverses parent directories to locate `.zig-version` or `build.zig.zon`.
3. If `build.zig.zon` is present with `minimum_zig_version = "0.17.0"`, `zvm` selects an installed version that satisfies the requirement.
4. If no project-level version is specified, it falls back to the global default.
5. `zvm` executes the target `zig` binary directly with all passed arguments.

## Building from Source

### Prerequisites
- Zig 0.17.0 or compatible toolchain (`zig17`)

### Build & Test

```bash
# Build the project
zig17 build

# Run unit tests
zig17 build test
```

## License

MIT
