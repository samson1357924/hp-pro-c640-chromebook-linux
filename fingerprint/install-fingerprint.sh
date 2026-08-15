#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRFPMOC_DIR="$(cd "$SCRIPT_DIR/../../crfpmoc" 2>/dev/null && pwd || echo "")"

echo "=== HP Pro c640 Chromebook Fingerprint Driver Installer ==="

# 1. Install required build dependencies
echo "[1/6] Installing dependencies..."
sudo apt update -y
sudo apt install -y meson ninja-build libglib2.0-dev libgusb-dev libpixman-1-dev \
                    libgudev-1.0-dev libjson-glib-dev libgirepository1.0-dev \
                    fprintd libpam-fprintd pkg-config git

# 2. Configure udev device permissions
echo "[2/6] Configuring udev rules for /dev/cros_fp..."
sudo cp "$SCRIPT_DIR/60-cros-fp.rules" /etc/udev/rules.d/60-cros-fp.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc

# 3. Build & Install crfpmoc driver
echo "[3/6] Building and installing crfpmoc driver..."
if [ -z "$CRFPMOC_DIR" ] || [ ! -d "$CRFPMOC_DIR" ]; then
    CRFPMOC_DIR="/tmp/crfpmoc-build"
    rm -rf "$CRFPMOC_DIR"
    git clone https://github.com/samson1357924/crfpmoc.git "$CRFPMOC_DIR"
fi

cd "$CRFPMOC_DIR"
if [ ! -d "build" ]; then
    meson setup build --prefix=/usr --libdir=lib/x86_64-linux-gnu -Ddrivers=default -Dintrospection=true -Dgtk-examples=false -Ddoc=false
fi

ninja -C build
# Clean stale /usr/local artifacts if present
sudo rm -f /usr/local/lib/x86_64-linux-gnu/libfprint-2.so* \
           /usr/local/lib/libfprint-2.so* \
           /usr/local/lib/x86_64-linux-gnu/pkgconfig/libfprint-2.pc \
           /usr/local/lib/x86_64-linux-gnu/girepository-1.0/FPrint-2.0.typelib \
           /usr/local/share/gir-1.0/FPrint-2.0.gir || true
sudo rm -rf /usr/local/include/libfprint-2 || true

sudo ninja -C build install
sudo ldconfig

# 4. Configure fprintd service
echo "[4/6] Configuring fprintd service..."
sudo rm -f /etc/systemd/system/fprintd.service.d/cros-fp.conf || true
sudo systemctl daemon-reload
sudo systemctl restart fprintd.service

# 5. Enable PAM authentication
echo "[5/6] Enabling PAM fingerprint authentication..."
sudo pam-auth-update --enable fprintd || true

# 6. Verify device discovery
echo "[6/6] Verifying biometric device discovery..."
fprintd-list "$USER" || true

echo ""
echo "=== Fingerprint setup completed successfully! ==="
echo "You can now enroll your fingerprint by running:"
echo "    fprintd-enroll \"\$USER\""
echo "And verify with:"
echo "    fprintd-verify \"\$USER\""
