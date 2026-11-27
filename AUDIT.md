# zvm Audit Checklist

Audit performed against Zig 0.17.0 (`zig17 build` and `zig17 build test` both pass;

behavioral findings confirmed by running the built binary against temporary
`ZVM_PATH` / project directories).

Severity legend: **H** high, **M** medium, **L** low. `file:line` refers to the state at
audit time. Commit hashes are from the fix series that followed the audit.

---

## Bugs

- [x] **H** `zvm uninstall` left the global default dangling — `src/cli/uninstall.zig`
  - Now clears `default`/`zls-default` when they name the removed version and points at
    the paired ZLS instead of deleting it. `zvm zls uninstall` clears its own default.
  - Fixed in `c5e323f`.

- [x] **H** Auto-install could override a `.zig-version` range pin — `src/resolver.zig`, `src/router.zig`
  - Resolution errors now carry their source; `UnmatchedZigVersionConstraint` never falls
    back to the zon minimum, for the router or `zvm install`.
  - Fixed in `209bf52`.

- [x] **H** Invalid `.zig-version` content was silently accepted — `src/resolver.zig`
  - Unparseable content returns `InvalidZigVersionConstraint`; `zvm current`, `doctor`,
    `install`, `which`, `zls` and the shim all report it.
  - Fixed in `209bf52`.

- [x] **H** `zvm install` (no args) installed the minimum instead of the resolved version
  - Resolved by the same provenance split: a `.zig-version` miss is an error, and only a
    `build.zig.zon` minimum is treated as a deterministic install target (which is also
    what the router would auto-install). `209bf52`.

- [x] **H** Wrong diagnostics when a `.zig-version` constraint had no match
  - Every message now names the actual source (`.zig-version` vs `minimum_zig_version`).
    `209bf52`.

- [x] **M** Downgrades were treated as upgrades — `src/self_updater.zig`
  - `needsUpgrade` now requires a strictly newer tag; `--force` is still required to
    downgrade. Fixed in `4340401`.

- [x] **M** `zvm pin` wrote before validating and printed the file first
  - Message is now `Pinned Zig <version> in <path>.`; `--with-zls` reports when ZLS is
    already installed instead of doing nothing. `3347ee6`.

- [x] **M** Misleading/duplicated status streams — `src/cli/report.zig`
  - `Reporter.status(.warn/.fail)` now writes to stderr, so `zvm doctor > /dev/null`
    still surfaces failures. `94fa107`.
  - Buffered stdout is flushed before each stderr write, and stderr is flushed per
    line, so warnings no longer jump ahead of the report that precedes them.

- [x] **M** A malformed `build.zig.zon` was only discoverable via `zig build`
  - `zvm doctor` now parses the current project's manifest with `std.zon.parse` and,
    when it fails, prints `Diagnostics.fmt(path)` (file:line:column plus the source
    excerpt) and notes that `minimum_zig_version` is being ignored.
  - `resolver.manifestErrorText` keeps the arena alive while formatting; the returned
    string is owned by the caller.

- [x] **M** A malformed `build.zig.zon` was invisible during normal `zig` invocations
  - `resolve` now reports the first manifest `std.zon.parse` rejected via
    `ResolvedVersion.malformed_zon_path`, and the router prints a one-line warning
    with a pointer to `zvm doctor`. It fires even when the scan fallback recovers the
    version, because `zig build` rejects that same manifest.
  - Not warned about when `.zig-version` short-circuits the walk first: the manifest is
    never consulted, so warning would be noise.

- [x] **M** Non-destructive install ordering — `src/downloader.zig`
  - The previous tree is kept as a `.old-<suffix>` sibling and restored if the swap
    fails. `3e80173`.

- [x] **M** Concurrent `zvm` processes could delete each other's staging
  - Staging, partial downloads, backups, and the upgrade stage now use a random suffix;
    archives are published into the cache with an atomic rename. There is still no
    blocking cross-process lock (a crashed process cannot strand one, but two installs
    of the same version can briefly race on the final rename). `3e80173`.

- [x] **L** Oversized config files were silently ignored
  - `.zig-version` and `build.zig.zon` are read with bounded allocs (64 KiB / 1 MiB)
    instead of 256 B / 8 KiB stack buffers, so large manifests keep their
    `minimum_zig_version`. `dd99dec`.

- [x] **L** Naive `build.zig.zon` scan
  - Extracted with `std.zon.parse` (`ignore_unknown_fields`, arena copy-out), with the
    comment-aware text scan as a fallback for manifests the parser rejects. `3fd9db1`,
    `b8e3f6c`.

- [x] **L** Shell hooks were not equivalent — `src/cli/env.zig`
  - The bash hook now only runs `zvm current` when `$PWD` changes, matching the zsh/fish
    hooks. (The `PROMPT_COMMAND` dedupe guard was already correct.) `dd99dec`.

- [x] **L** `clean` byte accounting under-reported
  - Nested directories contribute their recursive size. `dd99dec`.

- [x] **L** Inconsistent sort order
  - `zvm list`, `zvm zls list`, and the remote listing share `version.lessThanText` /
  `greaterThanText`, which sorts parseable versions before junk names. `94fa107`.

- [x] **L** README overpromised signature verification — `README.md`
  - Now says the Minisign signature is checked "when upstream publishes one". `dd99dec`.

- [x] **M** A nonexistent `zvm upgrade` tag was reported as a network failure
  - GitHub answers an unknown tag with 404, which `fetchUrlWithHeaders` collapsed into
    `HttpRequestFailed`, so `zvm upgrade v99.9.9` printed "check your network" and
    exited with the transport status. `fetchUrlWithStatus` now exposes the response
    status, `fetchGithubJson` maps 404 to `ReleaseNotFound` (exit 2), and the generic
    unreachable-host message no longer names ziglang.org for a GitHub query.

- [x] **M** `zvm upgrade --nightly` blamed the network when the checksum manifest failed
  - The archive download (3.4 MB on this machine) reached 100%, then the `SHA256SUMS.txt`
    fetch failed with any non-200 and was reported as "Failed to query GitHub Releases",
    which names the wrong request and reads like a corrupted download.
  - Non-200s now keep their meaning: 404 is `ReleaseNotFound`, 429 is `RateLimited`
    (message says to retry, since that is the fix), and a manifest fetch that fails for
    any other reason is `ChecksumManifestUnavailable` ("Downloaded the zvm archive but
    could not fetch its SHA256SUMS.txt"). The archive is deleted in that case: without a
    digest it cannot be used, and a retry downloads it again anyway.
  - The progress message switches to "Verifying and installing zvm..." at 100% instead of
    sitting on the download percentage while a different request runs.
  - Reproduced as a transient upstream failure: the same command succeeded on the next
    run, so the throttled/blocked status itself is gone. The reporting half is covered by
    `githubFetchError` / `manifestFetchFailure` / `upgradeFailure` tests; the exact live
    manifest failure was not re-triggered, because blocking one host's path needs a TLS
    intercepting proxy.

- [x] **L** `zvm pin` accepts a constraint no installed version satisfies
  - Accepted as designed: a pin is a declaration that can be satisfied by a later
    install, and the command already reports that nothing matches locally.

- [x] **L** Minisign non-prehashed verification reads the whole archive
  - Closed as not a defect: Ed25519 over a non-prehashed message needs the full
    message. Zig publishes prehashed signatures, so the streaming path is the one in
    use.

- [x] **L** `zvm current` exits 0 when the resolved version is not installed
  - Accepted as designed: it is a query that successfully reports the resolution
    (including the "not installed" state); `zvm which` and the shim fail because they
    must produce a runnable binary.

---

## Memory

- [x] **M** Double free on the OOM path — `src/resolver.zig`
  - The replacement name is allocated before the old one is freed. `7846e0a`.

- [x] **L** Ownership-transfer leaks when a later field allocation failed (OOM only)
  - `resolver.resolve` (via `makeResolved`), `downloader.installVersion`,
    `zls_downloader.installZls`, `self_updater.upgradeSelf` now allocate each owned
    string behind its own `errdefer`. `7846e0a`.

---

## Optimization

- [x] `resolver.resolve` / `findProjectMinimumVersion` allocated a `dupe`, two path
      joins, and freed them on every ancestor level. Both now walk one owned buffer
      shortened in place and build candidate paths in a stack buffer, so a level with
      no config file allocates nothing.
  - Measured (3000 resolutions over 20 levels, ReleaseFast): 400-450 ms before,
    405-459 ms after. Unchanged: the walk is bound by the two failed file opens per
    level, not by these allocations, so this is a churn reduction, not a speedup.
  - `4f010db`.
  - Also tried holding one open directory handle per level and probing
    `".zig-version"` / `"build.zig.zon"` by short name instead of full ancestor paths.
    That trades 2 lookups for 3 syscalls per level and measured 446-469 ms against
    430-446 ms for the path-based walk, so it was reverted, not shipped.
- [x] Resolution is syscall-bound, not CPU-bound: 1 level costs ~13 us and each
      additional ancestor ~6.6 us (~3.3 us per file probe) on this machine, i.e.
      ~140 us for a 20-level path. Two lookups per level (`.zig-version` then
      `build.zig.zon`) is the floor; batching them needs one directory read plus an
      upward open, which is not fewer syscalls. Making the walk materially faster
      would require a semantic change (stopping at the repository root) or a
      resolution cache with its own invalidation cost.
- [x] The walk ignores configs above the repository root (nearest ancestor containing
      `.git`), so a pin in an enclosing repository is not applied to a nested checkout.
  - A `.git` probe on every ancestor cost ~2.7 us per level and pushed the full
    20-level walk from 555-586 ms to 797-841 ms for paths with no repository root.
  - The boundary is now resolved only once a config file was actually found above the
    start directory (`crossedRepositoryRoot`): the levels between the start directory
    and the found config are probed, and the found level itself is exempt. A path with
    no config pays nothing, because it falls through to the global default whatever the
    boundary is.
  - Measured (3000 resolutions, ReleaseFast, 20-level path, no config): 797-841 ms with
    the per-level probe, 559-594 ms now, i.e. back to the pre-boundary baseline.
    With a pin above the repository root: 587-610 ms (boundary probes run only for that
    case, ~14 lookups for a 20-level path).
  - `.git` may be a file (worktrees, submodules); `access` covers both.
  - `59b3757`.
- [x] `Paths.listInstalledVersions` / `listInstalledZlsVersions` checked the binary by
      allocating two absolute paths (`versionDir` join + `versionZigBin` join) per entry.
      Both now format `"<entry>/zig"` into a stack buffer and `access` it relative to the
      already-open `versions` directory: one `access` syscall per entry, no per-entry
      allocation beyond the returned name.
  - `2b00bd7`.
- [x] `Paths.isVersionInstalled` / `isZlsInstalled` built the binary path with two heap
      joins and freed it per call, and they run on every resolve, every router dispatch
      and once per entry in `zvm list --remote`. Both now format
      `"<dir>/<version>/<exe>"` into a stack buffer and `access` it: one syscall, no
      allocation. The `allocator` argument had no other use, so it is gone from the
      signatures and the ~20 call sites.
- [x] `resolver.exactEnabled` and `router.isAutoInstallEnabled` each carried a copy of
      the same trimming and case-insensitive `1/true/yes` and `0/false/no` matching.
      Both now call `env_flags.boolOverride`, which also documents why an unrecognized
      value falls through to the marker file instead of erroring.
  - Tests cover the vocabulary the modules actually consume (padded, upper-case, and
    unrecognized values falling back to the marker), not just the `1`/`false`
    spellings.
  - `report.colorMode` and `config.ConfigAction` are left alone: they accept their own
    vocabularies (`auto`/`always`/`never`, subcommand-like words) on purpose.
- [x] Dead code removed: `Constraint.parse`'s unused join buffer, `targetKey`'s discarded
      arch/OS strings. `94fa107`.
- [x] `downloadToFile` no longer creates the destination before the response is known;
      it writes a temp file and renames. `3e80173`.
- [x] `self_updater.upgradeSelf` never removed the downloaded archive from `cache/`,
      so every upgrade left a release tarball behind until some later `zvm clean`. It
      is deleted after the atomic replacement, best-effort so a failed delete cannot
      turn a completed upgrade into an error. Verified against the real `v0.1.0`
      release: after a successful upgrade `cache/` is empty.
- [x] The enabled auto-install path had no coverage: exercising it meant fetching a
      real toolchain and `exec`-ing it. The resolve-and-ensure step is now
      `Router.resolveTargetVersion`, and `Router.install_hook` replaces the download in
      tests while staying null in production. Covered: a project minimum nothing
      satisfies, an exact pin that resolves but is not installed (with and without the
      flag), and a failed install reporting through the exit status.
  - `autoInstallAndWait` returns its error instead of a boolean, so the reason survives
    into the message: a manifest pinning `0.99.99` now exits with
    `Auto-install failed for Zig '0.99.99': VersionNotFound`.
- [x] Progress updates reformatted floats every 256 KiB. The interval is now 1 MiB,
      which cuts the spinner work on slow links while `flush` still reports the final
      count. `src/downloader.zig`.
- [x] The final delegation of both route functions was untested, since a real `exec`
      replaces or exits the test process. `Router.exec_hook` substitutes it, and the
      tests now assert what each route delegates to: the project pin, the `ZIG_VERSION`
      override winning over it, `ZLS_PATH` (trimmed) ahead of the paired ZLS, and the
      paired ZLS itself. `execBinary` and the route functions return `void` accordingly;
      in production the delegation still never returns.
- [x] Download failures were only exercised by hand. `downloadToFile` now has a
      server-free failure test: an unreachable host returns an error and leaves neither
      the destination nor a `.partial-*` scratch file behind.
- [x] Every reported failure exited `1`, so a script could not tell an unavailable
      release from a dead network from a failed verification. `AppContext.exit_code`
      carries a specific status for `error.Reported`, and `src/cli/exit_codes.zig` maps
      failures for `zvm install` (`2` unavailable, `3` transport, `4` integrity), plus
      the same vocabulary for `zvm zls install` and `zvm upgrade`. Documented in the
      README. Live-verified: `install 0.99.99` -> `2`, a dead proxy -> `3`, a wrong
      Minisig key -> `4`.

---

## Tooling

- [x] Commit attribution stripped from history and blocked going forward:
  `scripts/strip-commit-attribution.sh` plus `.githooks/commit-msg`, enabled with
  `git config core.hooksPath .githooks`.

---

## Verified clean

Version ordering and constraint semantics (`^`, `~`, compound ranges, `master` supremacy);
SHA-256 streaming verification; Minisign parsing and verification (key id, prehashed global
signature); archive staging and extraction for tar.xz / tar.gz / zip including zip root-dir
stripping; mirror URL construction (matches the live `community-mirrors.txt` format);
`PATH` precedence detection; shim create/inspect/update incl. the Windows copy fallback;
ANSI stripping across chunk boundaries; shim exit-code propagation (signal → 128+n).
