#!/usr/bin/env sh
# Installer for zvm (Zig Version Manager) on Linux and macOS.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Judeadeniji/zvm/main/install.sh | sh
#   ZVM_VERSION=nightly curl -fsSL https://raw.githubusercontent.com/Judeadeniji/zvm/main/install.sh | sh

set -eu

REPO="Judeadeniji/zvm"
INSTALL_DIR="${ZVM_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${ZVM_VERSION:-latest}"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: required command '$1' not found" >&2
        exit 1
    fi
}

need_cmd curl
need_cmd tar

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Linux)  OS_TAG="linux" ;;
    Darwin) OS_TAG="macos" ;;
    *)
        echo "error: unsupported OS '$OS'" >&2
        exit 1
        ;;
esac

case "$ARCH" in
    x86_64|amd64)  ARCH_TAG="x86_64" ;;
    arm64|aarch64) ARCH_TAG="aarch64" ;;
    *)
        echo "error: unsupported architecture '$ARCH'" >&2
        exit 1
        ;;
esac

TARGET="${ARCH_TAG}-${OS_TAG}"

if [ "$VERSION" = "latest" ]; then
    TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    if [ -z "$TAG" ]; then
        echo "error: failed to determine latest zvm release tag" >&2
        exit 1
    fi
else
    TAG="$VERSION"
fi

ARCHIVE="zvm-${TAG}-${TARGET}.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading zvm ${TAG} (${TARGET})..."
curl -fsSL "${BASE_URL}/${ARCHIVE}" -o "${TMP_DIR}/${ARCHIVE}"

if curl -fsSL "${BASE_URL}/SHA256SUMS.txt" -o "${TMP_DIR}/SHA256SUMS.txt" 2>/dev/null; then
    EXPECTED="$(grep " ${ARCHIVE}\$" "${TMP_DIR}/SHA256SUMS.txt" | awk '{print $1}' | head -n 1 || true)"
    if [ -n "$EXPECTED" ]; then
        if command -v sha256sum >/dev/null 2>&1; then
            ACTUAL="$(sha256sum "${TMP_DIR}/${ARCHIVE}" | awk '{print $1}')"
        elif command -v shasum >/dev/null 2>&1; then
            ACTUAL="$(shasum -a 256 "${TMP_DIR}/${ARCHIVE}" | awk '{print $1}')"
        else
            ACTUAL=""
        fi
        if [ -n "$ACTUAL" ] && [ "$ACTUAL" != "$EXPECTED" ]; then
            echo "error: SHA-256 mismatch for ${ARCHIVE}" >&2
            exit 1
        fi
        if [ -n "$ACTUAL" ]; then
            echo "SHA-256 verified."
        fi
    fi
fi

tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "${TMP_DIR}"
BIN_PATH="$(find "${TMP_DIR}" -type f -name zvm | head -n 1)"
if [ -z "$BIN_PATH" ]; then
    echo "error: zvm binary not found in downloaded archive" >&2
    exit 1
fi

mkdir -p "${INSTALL_DIR}"
install -m 755 "$BIN_PATH" "${INSTALL_DIR}/zvm"

echo "Installed zvm to ${INSTALL_DIR}/zvm"
case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
        echo "Add ${INSTALL_DIR} to your PATH, e.g.:"
        echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
        ;;
esac
echo "Next: run 'zvm setup' to create the zig/zls shims."
