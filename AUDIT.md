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

- [ ] **L** `zvm pin` accepts a constraint no installed version satisfies
  - Deliberate: a pin is a declaration that can be satisfied by a later install; the
    command already reports that nothing matches locally.

- [ ] **L** Minisign non-prehashed verification reads the whole archive
  - Not a defect: Ed25519 over a non-prehashed message needs the full message. Zig
    publishes prehashed signatures, so the streaming path is the one in use.

- [ ] **L** `zvm current` exits 0 when the resolved version is not installed
  - Deliberate: it is a query that successfully reports the resolution (including the
    "not installed" state); `zvm which` and the shim fail because they must produce a
    runnable binary.

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

- [ ] `resolver.resolve` / `findProjectMinimumVersion`: each ancestor level allocates a
      `dupe`, two path joins, and frees them, plus two directory opens. A single owned
      buffer walked with `std.fs.path.dirname` would remove ~4 allocations per level
      (hot path: every `zig` invocation).
- [ ] `Paths.listInstalledVersions` / `listInstalledZlsVersions`: `isVersionInstalled`
      allocates two paths and calls `access` per entry although the directory is already
      open; checking the `zig`/`zls` entry during iteration avoids that.
- [ ] De-duplicate env-boolean parsing (`resolver.exactEnabled`,
      `router.isAutoInstallEnabled`); `report.colorMode` and `config.ConfigAction` have
      intentionally different vocabularies.
- [x] Dead code removed: `Constraint.parse`'s unused join buffer, `targetKey`'s discarded
      arch/OS strings. `94fa107`.
- [x] `downloadToFile` no longer creates the destination before the response is known;
      it writes a temp file and renames. `3e80173`.
- [ ] `self_updater.upgradeSelf` never removes the downloaded archive from `cache/`
      (covered by `zvm clean`).
- [ ] Progress updates every 256 KiB reformat floats; a coarser interval would be
      smoother on slow links (left as-is for responsiveness).

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
