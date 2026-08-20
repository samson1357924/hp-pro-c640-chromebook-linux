#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# fingerprint/packaging/create-source-tarball.sh - Bundle pre-patched libfprint source tarball
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PKG_VERSION="${PKG_VERSION:-1.94.10}"
PINNED_COMMIT="56442591a5c302a906289f30988fb50fc3d82ed6"
OUTPUT_DIR="${1:-$SCRIPT_DIR/output}"
mkdir -p "$OUTPUT_DIR"

WORK_DIR="$(mktemp -d -t libfprint-src-XXXXXX)"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "=== Creating libfprint-crfpmoc-$PKG_VERSION Source Tarball ==="
TARBALL_DIR="$WORK_DIR/libfprint-crfpmoc-$PKG_VERSION"

# 1. Clone pinned upstream
git clone --depth 1 --branch feature/crfpmoc --single-branch \
    https://gitlab.freedesktop.org/3v1n0/libfprint.git "$TARBALL_DIR"
git -C "$TARBALL_DIR" fetch --depth 1 origin "$PINNED_COMMIT"
git -C "$TARBALL_DIR" checkout --detach FETCH_HEAD

# Remove .git metadata to keep clean
rm -rf "$TARBALL_DIR/.git"

# 2. Overlay audited driver sources
cp -f "$FP_DIR"/driver/crfpmoc* "$TARBALL_DIR/libfprint/drivers/crfpmoc/"

# Ensure crfpmoc-proto.c is listed in libfprint/meson.build
MESON_BUILD="$TARBALL_DIR/libfprint/meson.build"
if [ -f "$FP_DIR/driver/crfpmoc-proto.c" ] && [ -f "$MESON_BUILD" ] \
    && ! grep -q "drivers/crfpmoc/crfpmoc-proto.c" "$MESON_BUILD"; then
    sed -i "s|'drivers/crfpmoc/crfpmoc-ec-transfer.c',|'drivers/crfpmoc/crfpmoc-ec-transfer.c',\n        'drivers/crfpmoc/crfpmoc-proto.c',|" "$MESON_BUILD"
fi

# 3. Create tarball
TARBALL_FILE="$OUTPUT_DIR/libfprint-crfpmoc-${PKG_VERSION}-source.tar.gz"
tar -czf "$TARBALL_FILE" -C "$WORK_DIR" "libfprint-crfpmoc-$PKG_VERSION"

echo "=== Successfully created $TARBALL_FILE ==="
ls -lh "$TARBALL_FILE"
