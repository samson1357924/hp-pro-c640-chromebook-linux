#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==========================================================="
echo "   HP Pro c640 Chromebook (Google Dratini) Linux Setup     "
echo "==========================================================="
echo ""
echo "Select components to configure:"
echo "  [1] Complete Setup (Fingerprint + Keyboard + Audio checks)"
echo "  [2] Fingerprint Driver Only (crfpmoc + fprintd + PAM)"
echo "  [3] Keyboard Top-Row Mapping Only"
echo "  [4] Exit"
echo ""

read -rp "Enter choice [1-4] (default: 1): " choice
choice="${choice:-1}"

case "$choice" in
    1)
        echo ">>> Running complete setup..."
        # 1. Keyboard
        echo ">>> Installing keyboard mapping..."
        sudo cp "$SCRIPT_DIR/keyboard/90-chromebook-keyboard.hwdb" /etc/udev/hwdb.d/
        sudo systemd-hwdb update
        sudo udevadm trigger --subsystem-match=input || true

        # 2. Fingerprint
        echo ">>> Installing fingerprint driver..."
        chmod +x "$SCRIPT_DIR/fingerprint/install-fingerprint.sh"
        "$SCRIPT_DIR/fingerprint/install-fingerprint.sh"
        ;;
    2)
        echo ">>> Installing fingerprint driver..."
        chmod +x "$SCRIPT_DIR/fingerprint/install-fingerprint.sh"
        "$SCRIPT_DIR/fingerprint/install-fingerprint.sh"
        ;;
    3)
        echo ">>> Installing keyboard mapping..."
        sudo cp "$SCRIPT_DIR/keyboard/90-chromebook-keyboard.hwdb" /etc/udev/hwdb.d/
        sudo systemd-hwdb update
        sudo udevadm trigger --subsystem-match=input || true
        echo "Keyboard mapping installed!"
        ;;
    4)
        echo "Exiting."
        exit 0
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo ""
echo "Setup process completed! 🎉"
