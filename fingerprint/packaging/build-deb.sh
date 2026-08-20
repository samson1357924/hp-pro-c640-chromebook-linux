#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# fingerprint/packaging/build-deb.sh - Build Debian/Ubuntu .deb package for libfprint-crfpmoc
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PKG_VERSION="${PKG_VERSION:-1.94.10-1}"
PKG_NAME="libfprint-crfpmoc"
PINNED_COMMIT="56442591a5c302a906289f30988fb50fc3d82ed6"
OUTPUT_DIR="${1:-$SCRIPT_DIR/output}"
mkdir -p "$OUTPUT_DIR"

WORK_DIR="$(mktemp -d -t libfprint-deb-XXXXXX)"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "=== Building $PKG_NAME $PKG_VERSION (.deb) ==="
echo "Work directory: $WORK_DIR"
echo "Output directory: $OUTPUT_DIR"

# 1. Clone pinned upstream libfprint
echo "--> Cloning 3v1n0/libfprint (feature/crfpmoc @ $PINNED_COMMIT)..."
git clone --depth 1 --branch feature/crfpmoc --single-branch \
    https://gitlab.freedesktop.org/3v1n0/libfprint.git "$WORK_DIR/src"
git -C "$WORK_DIR/src" fetch --depth 1 origin "$PINNED_COMMIT"
git -C "$WORK_DIR/src" checkout --detach FETCH_HEAD

# 2. Overlay audited driver sources
echo "--> Overlaying audited crfpmoc driver..."
cp -f "$FP_DIR"/driver/crfpmoc* "$WORK_DIR/src/libfprint/drivers/crfpmoc/"

# Ensure crfpmoc-proto.c is listed in libfprint/meson.build
MESON_BUILD="$WORK_DIR/src/libfprint/meson.build"
if [ -f "$FP_DIR/driver/crfpmoc-proto.c" ] && [ -f "$MESON_BUILD" ] \
    && ! grep -q "drivers/crfpmoc/crfpmoc-proto.c" "$MESON_BUILD"; then
    echo "--> Adding crfpmoc-proto.c to meson.build..."
    sed -i "s|'drivers/crfpmoc/crfpmoc-ec-transfer.c',|'drivers/crfpmoc/crfpmoc-ec-transfer.c',\n        'drivers/crfpmoc/crfpmoc-proto.c',|" "$MESON_BUILD"
fi

# 3. Determine Debian multiarch libdir
DEB_HOST_MULTIARCH="x86_64-linux-gnu"
if command -v dpkg-architecture > /dev/null 2>&1; then
    DEB_HOST_MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2> /dev/null || echo "x86_64-linux-gnu")"
fi

# 4. Configure & Build
echo "--> Configuring Meson build (libdir=lib/$DEB_HOST_MULTIARCH)..."
meson setup "$WORK_DIR/build" "$WORK_DIR/src" \
    --prefix=/usr \
    --libdir="lib/$DEB_HOST_MULTIARCH" \
    -Ddrivers=default \
    -Dintrospection=true \
    -Dgtk-examples=false \
    -Ddoc=false

echo "--> Compiling with Ninja..."
ninja -C "$WORK_DIR/build"

# 5. Stage files into package root
PKG_STAGE="$WORK_DIR/pkg"
mkdir -p "$PKG_STAGE"
DESTDIR="$PKG_STAGE" ninja -C "$WORK_DIR/build" install

# Copy udev rule
install -D -m 0644 "$FP_DIR/60-cros-fp.rules" "$PKG_STAGE/usr/lib/udev/rules.d/60-cros-fp.rules"

# 6. Create DEBIAN metadata
mkdir -p "$PKG_STAGE/DEBIAN"
cat > "$PKG_STAGE/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Section: libs
Priority: optional
Architecture: amd64
Depends: libc6, libglib2.0-0t64 | libglib2.0-0, libgudev-1.0-0, libgusb2, libnss3, libpixman-1-0
Provides: libfprint-2-2, libfprint-2-tod1
Conflicts: libfprint-2-2
Replaces: libfprint-2-2
Maintainer: HP Pro c640 Linux Enablement Team <samson1357924@users.noreply.github.com>
Description: ChromeOS Match-on-Chip (crfpmoc) libfprint driver for HP Pro c640
 Library for fingerprint readers with ChromeOS Match-on-Chip (MoC) driver
 support, audited for HP Pro c640 Chromebook (Google Dratini).
EOF

cat > "$PKG_STAGE/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    ldconfig
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=misc 2>/dev/null || true
fi
EOF
chmod 0755 "$PKG_STAGE/DEBIAN/postinst"

cat > "$PKG_STAGE/DEBIAN/postrm" << 'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    ldconfig
    udevadm control --reload-rules 2>/dev/null || true
fi
EOF
chmod 0755 "$PKG_STAGE/DEBIAN/postrm"

# 7. Build .deb package
DEB_FILE="$OUTPUT_DIR/${PKG_NAME}_${PKG_VERSION}_amd64.deb"
echo "--> Packaging to $DEB_FILE..."
dpkg-deb --build --root-owner-group "$PKG_STAGE" "$DEB_FILE"

echo "=== Successfully built $DEB_FILE ==="
ls -lh "$DEB_FILE"
