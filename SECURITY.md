# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| `main` (latest) | ✅ |
| Tagged releases | ✅ (latest tag) |
| Older tags | ❌ |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, report them privately via one of:

- **GitHub private vulnerability reporting**: [Security tab → "Report a vulnerability"](https://github.com/Judeadeniji/zvm/security/advisories/new)
- **Email**: Send details to the maintainer (see the GitHub profile for contact info).

Please include:

- A clear description of the vulnerability.
- Steps to reproduce or a proof-of-concept.
- Potential impact and affected versions.
- Any suggested mitigations, if known.

You will receive an acknowledgement within **48 hours** and a status update within **7 days**.

## Security Design Notes

### Archive Integrity

All Zig release archives downloaded by `zvm` are verified with:

1. **SHA-256** checksum against the value published in `https://ziglang.org/download/index.json`.
2. **Minisign** (`Ed25519` + `BLAKE2b-512`) signature verification against the Zig Software Foundation's public key.

Minisig verification can be overridden at build time (`-Dminisig-key`) or runtime (`--minisig-key`, `ZVM_MINISIG_PUBLIC_KEY`, `~/.zvm/minisig.pub`), but should never be disabled in production use.

### Shim / PATH Hijacking

The `zig` shim placed in `~/.zvm/bin/` delegates directly to the resolved Zig binary via `std.process.replace` (POSIX) or a child process (Windows). It does not evaluate shell code or modify environment variables beyond what `zig` itself receives.

Ensure `~/.zvm/bin/` appears **before** any untrusted directory in your `PATH`. Use `zvm doctor` to verify correct precedence.

### Dependency Surface

`zvm` has a single build dependency ([`zli`](https://github.com/xcaeser/zli)) used only for CLI argument parsing; it is not linked into the shim/router path. All cryptographic operations use the Zig standard library (`std.crypto`).
