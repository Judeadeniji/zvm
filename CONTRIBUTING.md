# Contributing to zvm

Thank you for your interest in contributing! This document explains how to get started, the development workflow, and what to expect from the review process.

## Table of Contents

- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Making Changes](#making-changes)
- [Testing](#testing)
- [Submitting a Pull Request](#submitting-a-pull-request)
- [Reporting Bugs](#reporting-bugs)
- [Requesting Features](#requesting-features)
- [Code Style](#code-style)

---

## Getting Started

Before contributing, please:

1. Check [existing issues](https://github.com/Judeadeniji/zvm/issues) and [pull requests](https://github.com/Judeadeniji/zvm/pulls) to avoid duplicate work.
2. For non-trivial changes, open an issue first to discuss the approach.
3. Read the [SECURITY.md](SECURITY.md) before reporting any security issues.

---

## Development Setup

**Requirements**: Zig **0.17.0** (minimum).

```bash
git clone https://github.com/Judeadeniji/zvm.git
cd zvm

# Build
zig build

# Run all unit tests
zig build test

# Check formatting
zig fmt --check src/

# Cross-compile for Windows (from Linux/macOS)
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

> **Note**: Always use Zig 0.17.0. The project targets exactly this version. The CI matrix tests Linux, macOS, and Windows.

---

## Project Structure

```
src/
  main.zig          — Entrypoint, wires CLI and router
  errors.zig        — Closed domain error sets (all error types live here)
  paths.zig         — ZVM directory layout and environment resolution
  version.zig       — SemVer parsing, ordering, and constraint evaluation
  resolver.zig      — Walk-up resolver (.zig-version, build.zig.zon, env)
  router.zig        — Transparent dispatcher (execv / child-process spawn)
  shim.zig          — zig shim symlink creation and PATH inspection
  minisig.zig       — Ed25519 + BLAKE2b-512 Minisign verification
  downloader.zig    — HTTP fetch, SHA-256 verify, archive extraction
  cli/
    root.zig        — Command tree wiring (powered by zli)
    context.zig     — Shared AppContext passed to all subcommands
    install.zig     — zvm install
    use.zig         — zvm use
    pin.zig         — zvm pin
    list.zig        — zvm list
    list_remote.zig — zvm list-remote
    current.zig     — zvm current
    which.zig       — zvm which
    uninstall.zig   — zvm uninstall
    setup.zig       — zvm setup / zvm shim
    doctor.zig      — zvm doctor
    clean.zig       — zvm clean
    env.zig         — zvm env
    completions.zig — zvm completions
```

New modules must follow the **single-responsibility rule**: one cohesive concern per file.

---

## Making Changes

1. Fork the repository and create a branch from `main`:
   ```bash
   git checkout -b feat/my-feature
   ```
2. Make your changes following the [Code Style](#code-style) guidelines.
3. Add or update tests for any new behaviour.
4. Verify the full test suite passes and formatting is clean:
   ```bash
   zig fmt --check src/ && zig build test
   ```
5. Commit with a clear, imperative message:
   ```
   Add aarch64-windows cross-compilation support
   Fix path separator normalization in resolveBaseDirForOs test
   ```

---

## Testing

- Unit tests live alongside production code in each `src/*.zig` file.
- Tests use only the Zig standard library test harness (`std.testing`).
- Tests that require the filesystem use `std.testing.tmpDir` for isolation.
- Tests that are inherently OS-specific guard themselves with `builtin.target.os.tag` or `Paths.is_windows`.
- **No test should require a live network connection.** Downloader tests use embedded byte fixtures.

Run the full suite:
```bash
zig build test
```

---

## Submitting a Pull Request

- Target `main`.
- Keep PRs focused — one logical change per PR.
- Fill in the PR description: what changed, why, and how to test it.
- All CI checks (format, build, test on Linux/macOS/Windows, cross-compile) must pass.
- A maintainer will review within a few days. Expect iterative feedback.

---

## Reporting Bugs

Open a [GitHub Issue](https://github.com/Judeadeniji/zvm/issues/new?template=bug_report.md) with:

- `zvm` version (`git rev-parse --short HEAD` or release tag).
- Operating system and architecture.
- Exact command and full output.
- Expected vs. actual behaviour.

---

## Requesting Features

Open a [GitHub Issue](https://github.com/Judeadeniji/zvm/issues/new?template=feature_request.md) describing:

- The use case / problem being solved.
- Proposed solution (optional).
- Alternatives you've considered.

---

## Code Style

zvm follows idiomatic Zig conventions:

| Element | Convention |
|---|---|
| Variables & fields | `snake_case` |
| Functions | `camelCase` |
| Types / type-returning functions | `PascalCase` |
| Files (general modules) | `snake_case.zig` |
| Files (single-type exports) | `PascalCase.zig` |

Additional rules:

- **Explicit allocators** — pass `std.mem.Allocator` into functions that allocate; no hidden globals.
- **Explicit error handling** — return error unions (`!T`), propagate with `try`, handle with `catch`.
- **Closed error sets** — all error types are defined in `src/errors.zig`; return `ErrorSet.Member` not bare `error.Member`.
- **`defer` / `errdefer`** — pair every resource acquisition with cleanup at the site of acquisition.
- **Imperative loops** over functional pipelines for predictable control flow.
- Run `zig fmt src/` before committing — CI enforces formatting on Linux.
