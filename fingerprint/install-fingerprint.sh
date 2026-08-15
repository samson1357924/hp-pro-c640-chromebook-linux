#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# HP Pro c640 Chromebook Fingerprint Driver Installer
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==========================================================="
echo "  HP Pro c640 Chromebook Fingerprint Driver Installer      "
echo "==========================================================="

# 1. Install required build dependencies
echo "[1/6] Installing build dependencies..."
sudo apt update -y
sudo apt install -y build-essential meson ninja-build pkg-config git \
                    libglib2.0-dev libgusb-dev libpixman-1-dev \
                    libgudev-1.0-dev libudev-dev libjson-glib-dev \
                    libgirepository1.0-dev gobject-introspection \
                    libssl-dev fprintd libpam-fprintd

# 2. Configure udev device permissions for /dev/cros_fp
echo "[2/6] Configuring udev rules for /dev/cros_fp..."
sudo mkdir -p /etc/udev/rules.d
sudo cp "$SCRIPT_DIR/60-cros-fp.rules" /etc/udev/rules.d/60-cros-fp.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc 2>/dev/null || true
[ -e /dev/cros_fp ] && sudo chmod 0666 /dev/cros_fp 2>/dev/null || true

# 3. Locate / Clone crfpmoc build tree
echo "[3/6] Preparing crfpmoc libfprint tree..."
if [ -n "$CRFPMOC_DIR" ] && [ -d "$CRFPMOC_DIR" ]; then
    echo "Using user-specified CRFPMOC_DIR: $CRFPMOC_DIR"
elif [ -d "$REPO_ROOT/../crfpmoc" ]; then
    CRFPMOC_DIR="$(cd "$REPO_ROOT/../crfpmoc" && pwd)"
    echo "Found local sibling crfpmoc repository: $CRFPMOC_DIR"
else
    CRFPMOC_DIR="/tmp/crfpmoc-build"
    echo "Cloning crfpmoc upstream into $CRFPMOC_DIR..."
    rm -rf "$CRFPMOC_DIR"
    git clone --depth 1 https://github.com/samson1357924/crfpmoc.git "$CRFPMOC_DIR"
fi

# Sync bundled driver source into the build tree to guarantee local changes are compiled
if [ -d "$SCRIPT_DIR/driver" ] && [ -d "$CRFPMOC_DIR/libfprint/drivers/crfpmoc" ]; then
    echo "Syncing bundled driver source files to build tree..."
    cp -f "$SCRIPT_DIR"/driver/crfpmoc* "$CRFPMOC_DIR/libfprint/drivers/crfpmoc/"
fi

# Detect architecture multiarch libdir
ARCH_LIBDIR="lib/$(uname -m)-linux-gnu"
if command -v dpkg-architecture >/dev/null 2>&1; then
    ARCH_LIBDIR="lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
fi

# Build & Install
cd "$CRFPMOC_DIR"
if [ ! -f "build/build.ninja" ]; then
    rm -rf build
    meson setup build --prefix=/usr --libdir="$ARCH_LIBDIR" \
                      -Ddrivers=default -Dintrospection=true \
                      -Dgtk-examples=false -Ddoc=false
else
    meson setup build --reconfigure --prefix=/usr --libdir="$ARCH_LIBDIR" \
                      -Ddrivers=default -Dintrospection=true \
                      -Dgtk-examples=false -Ddoc=false
fi

ninja -C build

# Clean stale /usr/local artifacts if present
sudo rm -f /usr/local/lib/*/libfprint-2.so* \
           /usr/local/lib/libfprint-2.so* \
           /usr/local/lib/*/pkgconfig/libfprint-2.pc \
           /usr/local/lib/*/girepository-1.0/FPrint-2.0.typelib \
           /usr/local/share/gir-1.0/FPrint-2.0.gir || true
sudo rm -rf /usr/local/include/libfprint-2 || true

sudo ninja -C build install
sudo ldconfig

# 4. Configure fprintd service
echo "[4/6] Configuring fprintd service..."
sudo rm -f /etc/systemd/system/fprintd.service.d/cros-fp.conf || true
sudo systemctl daemon-reload
sudo systemctl restart fprintd.service 2>/dev/null || sudo systemctl restart fprintd 2>/dev/null || true

# 5. Enable PAM authentication
echo "[5/6] Enabling PAM fingerprint authentication..."
if command -v pam-auth-update >/dev/null 2>&1; then
    sudo pam-auth-update --enable fprintd || true
fi

# 6. Verify device discovery
echo "[6/6] Verifying biometric device discovery..."
fprintd-list "$USER" || true

echo ""
echo "=== Fingerprint setup completed successfully! 🎉 ==="
echo "Enroll your fingerprint with:"
echo "    fprintd-enroll \"\$USER\""
echo "Verify enrollment with:"
echo "    fprintd-verify \"\$USER\""
