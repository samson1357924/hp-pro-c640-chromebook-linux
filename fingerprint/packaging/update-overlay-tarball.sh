#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# fingerprint/packaging/update-overlay-tarball.sh - Regenerate crfpmoc-driver-overlay.tar.gz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK_DIR="$(mktemp -d -t overlay-XXXXXX)"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

TARGET_DIR="$WORK_DIR/libfprint/drivers/crfpmoc"
mkdir -p "$TARGET_DIR"
cp -f "$FP_DIR"/driver/crfpmoc* "$TARGET_DIR/"

TARBALL="$SCRIPT_DIR/crfpmoc-driver-overlay.tar.gz"
tar --sort=name --mtime='2026-08-19 00:00:00Z' --owner=0 --group=0 --numeric-owner \
    -czf "$TARBALL" -C "$WORK_DIR" libfprint

echo "Regenerated $TARBALL"
sha256sum "$TARBALL"
