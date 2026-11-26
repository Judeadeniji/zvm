# zvm

**A fast, zero-dependency Zig version manager written in Zig.**

Install, switch, and manage multiple [Zig](https://ziglang.org) compiler versions (stable releases and `master` builds) with automatic per-project version switching.

---

## Why zvm?

- **Automatic project switching** — Reads `.zig-version` and `build.zig.zon` as you move between projects, so `zig` always runs the version your project expects.
- **Fast & self-contained** — Single native binary with no runtime dependencies and near-zero overhead when invoking `zig`.
- **Verified downloads** — Every Zig release is checked with both SHA-256 checksums and Minisign signatures before extraction.
- **Built-in `master` tracking** — Install `master` and keep it up to date as new dev builds land.
- **Cross-platform** — Works on Linux, macOS, and Windows with completions for Bash, Zsh, Fish, and PowerShell.

---

## Quick Start

### 1. Install `zvm`

Download the archive for your platform from [GitHub Releases](https://github.com/Judeadeniji/zvm/releases), extract it, and place `zvm` in your `PATH` (for example `~/.local/bin/zvm`).

*(Or [build from source](#building-from-source) if you already have Zig 0.17.0.)*

### 2. Set up the `zig` shim & shell

```bash
zvm setup
```

Add `zvm` to your shell config (choose your shell below), then reload your terminal:

<details open>
<summary><b>Bash</b> (<code>~/.bashrc</code>)</summary>

```bash
eval "$(zvm env bash)"
eval "$(zvm completions bash)"   # optional: tab completions
```

</details>

<details>
<summary><b>Zsh</b> (<code>~/.zshrc</code>)</summary>

```zsh
eval "$(zvm env zsh)"

# Optional: tab completions
mkdir -p ~/.zfunc
zvm completions zsh > ~/.zfunc/_zvm
fpath=(~/.zfunc $fpath)
autoload -Uz compinit && compinit
```

</details>

<details>
<summary><b>Fish</b> (<code>~/.config/fish/config.fish</code>)</summary>

```fish
zvm env fish | source

# Optional: tab completions (one-time)
zvm completions fish > ~/.config/fish/completions/zvm.fish
```

</details>

<details>
<summary><b>PowerShell</b> (<code>$PROFILE</code>)</summary>

```powershell
zvm env powershell | Out-String | Invoke-Expression
zvm completions powershell | Out-String | Invoke-Expression   # optional
```

</details>

Check that everything is wired up properly:

```bash
zvm doctor
```

### 3. Install and use Zig

```bash
zvm install 0.17.0
zvm use 0.17.0
zig version
```

---

## Everyday Usage

### Switching & pinning versions

```bash
zvm use 0.17.0          # Set your global default
zvm pin 0.16.0          # Pin a project to 0.16.0 (creates .zig-version)
zvm pin "^0.17.0"       # Or pin a semver range
zvm install             # Install the version required by the current project
zvm install master      # Install or update the latest master build
```

### How `zvm` picks a Zig version

When you run `zig`, `zvm` checks in order:

1. **`ZIG_VERSION`** environment variable (e.g. `ZIG_VERSION=0.16.0 zig build`)
2. **`.zig-version`** in the current or any parent directory (exact version, `master`, or semver range like `^0.17.0`, `~0.17.0`, `>=0.16.0 <0.18.0`)
3. **`build.zig.zon`** (`minimum_zig_version`) in the current or any parent directory
4. **Global default** set via `zvm use <version>`

### Exact `minimum_zig_version` mode

By default, `build.zig.zon`'s `minimum_zig_version` means *"this version or newer"* — so `zvm` picks the newest installed Zig that satisfies it.

If a project only compiles on the exact version listed in `build.zig.zon`, use `--exact` (or enable it globally):

```bash
zvm install --exact          # Install the exact minimum_zig_version
zvm current --exact          # Preview which version exact mode resolves
ZVM_EXACT=1 zig build        # Run zig with exact mode for one command
zvm config exact on          # Always treat minimum_zig_version as exact
```

### Auto-installing missing versions

Let `zvm` automatically download and install a project's required Zig version the first time you run `zig`:

```bash
zvm config auto-install on
```

*(Or pass `--auto-install` to `zvm env <shell> --auto-install`, or set `ZVM_AUTO_INSTALL=1`.)*

### ZLS & Editor Integration

`zvm` can install and route **ZLS** (the Zig Language Server) automatically alongside your active Zig version:

```bash
zvm install 0.17.0 --with-zls   # Install Zig + compatible ZLS together
zvm zls install                 # Or install ZLS for the current project's Zig
zvm env --editor vscode         # Print config for vscode, nvim, helix, emacs, or zed
```

Editor setup guides: [VS Code](docs/editors/vscode.md) · [Neovim](docs/editors/neovim.md) · [Helix](docs/editors/helix.md) · [Emacs](docs/editors/emacs.md) · [Zed](docs/editors/zed.md)

---

## Command Reference

| Command | Description |
|---|---|
| `zvm install [version]` | Install a Zig version, `master`, or the current project's version (`--exact`, `--force`, `--no-minisig`) |
| `zvm use <version>` | Set the global default Zig version |
| `zvm pin <version>` | Write `.zig-version` in the current directory |
| `zvm list` | List installed Zig versions (`*` marks active) |
| `zvm list-remote [--all]` | List available releases from `ziglang.org` |
| `zvm current [--exact]` | Show the active Zig version and where it was resolved from |
| `zvm which [version]` | Print the path to the active or specified `zig` binary |
| `zvm uninstall <version>` | Remove an installed Zig version |
| `zvm config [key [on\|off\|toggle]]` | Inspect or toggle persistent settings (`auto-install`, `exact`) |
| `zvm setup [--force]` | Create or repair the `zig` shim (alias: `shim`) |
| `zvm doctor [--exact]` | Check directories, shim health, and `PATH` order |
| `zvm clean [--dry-run]` | Delete cached download archives |
| `zvm env <shell> [--auto-install]` | Print shell `PATH` and directory-hook snippet (or `--editor <name>` for ZLS config) |
| `zvm zls <subcommand>` | Manage ZLS paired to Zig (`install`, `update`, `list`, `use`, `which`, `uninstall`) |
| `zvm completions <shell>` | Print tab-completion script (`bash`, `zsh`, `fish`, `powershell`) |

---

## Configuration

| Variable / Setting | Purpose |
|---|---|
| `ZVM_PATH` | Override where `zvm` stores versions and cache |
| `ZVM_AUTO_INSTALL` | Set to `1` / `0` to override `zvm config auto-install` |
| `ZVM_EXACT` | Set to `1` / `0` to override `zvm config exact` |
| `ZVM_COLOR` | `always` or `never` (also respects `NO_COLOR`, `CLICOLOR`, `CLICOLOR_FORCE`, `TERM=dumb`) |
| `ZVM_MINISIG_PUBLIC_KEY` | Override the Zig Software Foundation Minisign public key (`--minisig-key` or `<data_dir>/minisig.pub`) |

Default data directories:
- **Linux**: `$XDG_DATA_HOME/zvm` (fallback: `~/.zvm`)
- **macOS**: `$XDG_DATA_HOME/zvm` (fallback: `~/Library/Application Support/zvm`)
- **Windows**: `%LOCALAPPDATA%\zvm` (fallback: `%USERPROFILE%\.zvm`)

---

## Building from Source

Requires **Zig 0.17.0**:

```bash
git clone https://github.com/Judeadeniji/zvm.git
cd zvm
zig build -Doptimize=ReleaseSafe
zig build test
```

The compiled binary is placed at `zig-out/bin/zvm`.

---

## Contributing & Security

- See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, and PR guidelines.
- See [SECURITY.md](SECURITY.md) to report security issues privately.

## License

[MIT](LICENSE)
