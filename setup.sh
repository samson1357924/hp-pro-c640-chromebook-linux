#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# HP Pro c640 Chromebook (Google Dratini) Linux Master Setup Script
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install_keyboard() {
    echo ">>> [Keyboard] Installing Chromebook top-row mapping..."
    sudo mkdir -p /etc/udev/hwdb.d/
    sudo cp "$SCRIPT_DIR/keyboard/90-chromebook-keyboard.hwdb" /etc/udev/hwdb.d/
    sudo systemd-hwdb update
    sudo udevadm trigger --subsystem-match=input || true
    echo ">>> [Keyboard] Mapping installed successfully!"
}

install_fingerprint() {
    echo ">>> [Fingerprint] Installing crfpmoc driver & PAM configuration..."
    chmod +x "$SCRIPT_DIR/fingerprint/install-fingerprint.sh"
    "$SCRIPT_DIR/fingerprint/install-fingerprint.sh"
}

check_audio() {
    echo ">>> [Audio] Verifying Intel Comet Lake SOF DSP Audio Subsystem..."
    if lsmod | grep -q "snd_sof_pci_intel_cnl"; then
        echo "  [OK] SOF Comet Lake DSP kernel module loaded (snd_sof_pci_intel_cnl)."
    elif lsmod | grep -q "snd_sof"; then
        echo "  [OK] SOF audio subsystem loaded."
    else
        echo "  [INFO] SOF module not active yet; standard ALSA/PipeWire fallback will be used."
    fi

    if command -v aplay >/dev/null 2>&1; then
        echo ">>> [Audio] Detected Sound Cards:"
        aplay -l 2>/dev/null | grep -E "^card" || echo "  (No sound cards found or permission denied)"
    fi
    echo ">>> [Audio] See audio/README.md for custom ALSA UCM & PipeWire routing details."
}

show_menu() {
    echo "==========================================================="
    echo "   HP Pro c640 Chromebook (Google Dratini) Linux Setup     "
    echo "==========================================================="
    echo ""
    echo "Select components to configure:"
    echo "  [1] Complete Setup (Fingerprint + Keyboard + Audio check)"
    echo "  [2] Fingerprint Driver Only (crfpmoc + fprintd + PAM)"
    echo "  [3] Keyboard Top-Row Mapping Only"
    echo "  [4] Audio Subsystem Status Check Only"
    echo "  [5] Exit"
    echo ""
}

# Support non-interactive CLI arguments
MODE="${1:-}"
case "$MODE" in
    --all|-a|1)
        install_keyboard
        install_fingerprint
        check_audio
        ;;
    --fingerprint|-f|2)
        install_fingerprint
        ;;
    --keyboard|-k|3)
        install_keyboard
        ;;
    --audio)
        check_audio
        ;;
    "")
        show_menu
        read -rp "Enter choice [1-5] (default: 1): " choice
        choice="${choice:-1}"
        case "$choice" in
            1)
                install_keyboard
                install_fingerprint
                check_audio
                ;;
            2)
                install_fingerprint
                ;;
            3)
                install_keyboard
                ;;
            4)
                check_audio
                ;;
            5)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo "Invalid choice. Exiting."
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Unknown option: $MODE"
        echo "Usage: $0 [--all | --fingerprint | --keyboard | --audio]"
        exit 1
        ;;
esac

echo ""
echo "Setup process completed! 🎉"
