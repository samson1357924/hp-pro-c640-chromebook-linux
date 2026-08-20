#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# HP Pro c640 Chromebook (Google Dratini) Linux Master Setup Script
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# shellcheck source=lib/logger.sh
source "$SCRIPT_DIR/lib/logger.sh"
# shellcheck source=lib/distro.sh
source "$SCRIPT_DIR/lib/distro.sh"
# shellcheck source=lib/backup.sh
source "$ROOT_DIR/lib/backup.sh"
# shellcheck source=lib/syscheck.sh
source "$SCRIPT_DIR/lib/syscheck.sh"

show_banner() {
    echo -e "${CLR_CYAN}${CLR_BOLD}"
    echo "==========================================================="
    echo "   HP Pro c640 Chromebook (Google Dratini) Linux Setup     "
    echo "   Complete Hardware Enablement & Out-of-the-Box Solution  "
    echo "==========================================================="
    echo -e "${CLR_RESET}"
}

show_menu() {
    show_banner
    echo "Detected Environment:"
    echo "  - OS:      $DISTRO_NAME ($DISTRO_FAMILY)"
    echo "  - Kernel:  $(uname -r)"
    echo "  - User:    $(get_real_user)"
    echo ""
    echo "Select action to perform:"
    echo "  [1] Complete Setup (Keyboard + Audio + Fingerprint + Power S0ix)"
    echo "  [2] Audio UCM Profiles Only (sofrt5682 + PipeWire)"
    echo "  [3] Fingerprint Driver Only (crfpmoc + fprintd + PAM)"
    echo "  [4] Keyboard Top-Row Mapping Only (systemd-hwdb)"
    echo "  [5] Power Management & S0ix Modern Standby Tuning"
    echo "  [6] ChromeOS EC Control (Battery 80% limit & Fan tuning)"
    echo "  [7] Full Hardware & Diagnostics Check"
    echo "  [8] Generate Diagnostic Bundle (sysreport.tar.gz)"
    echo "  [9] Uninstall / Rollback All Components"
    echo "  [0] Exit"
    echo ""
}

show_help() {
    show_banner
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --all, -a            Run complete setup (Keyboard + Audio + Fingerprint + Power)"
    echo "  --audio, -u          Install ALSA UCM2 audio profiles"
    echo "  --fingerprint, -f    Install crfpmoc libfprint driver (Hybrid: prebuilt package with source fallback)"
    echo "  --source, --build    Force building fingerprint driver from source (Plan A)"
    echo "  --keyboard, -k       Install Chromebook top-row function keys mapping"
    echo "  --power, -p          Install power management & S0ix modern standby tuning"
    echo "  --ec                 Install ChromeOS EC control utility (c640-ec-control)"
    echo "  --check, -c          Run full hardware diagnostic check"
    echo "  --sysreport          Generate comprehensive diagnostic archive"
    echo "  --uninstall          Uninstall all installed components and restore configs"
    echo "  --dry-run, -n        Preview all actions without modifying the system"
    echo "  --help, -h           Show this help message"
    echo ""
}

make_executable() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "chmod +x $*"
        return 0
    fi
    chmod +x "$@"
}

run_keyboard() {
    make_executable "$SCRIPT_DIR/keyboard/install-keyboard.sh"
    "$SCRIPT_DIR/keyboard/install-keyboard.sh" --install
}

run_fingerprint() {
    make_executable "$SCRIPT_DIR/fingerprint/install-fingerprint.sh"
    if [ "${FP_FORCE_SOURCE:-0}" = "1" ]; then
        "$SCRIPT_DIR/fingerprint/install-fingerprint.sh" --source
    else
        "$SCRIPT_DIR/fingerprint/install-fingerprint.sh" --install
    fi
}

run_audio() {
    make_executable "$SCRIPT_DIR/audio/install-audio.sh"
    "$SCRIPT_DIR/audio/install-audio.sh" --install
}

run_power() {
    make_executable "$SCRIPT_DIR/power/install-power.sh"
    "$SCRIPT_DIR/power/install-power.sh" --install
}

run_ec() {
    make_executable "$SCRIPT_DIR/ec/install-ec.sh"
    "$SCRIPT_DIR/ec/install-ec.sh" --install
}

run_check() {
    make_executable "$SCRIPT_DIR/scripts/detect-hardware.sh"
    "$SCRIPT_DIR/scripts/detect-hardware.sh"
}

run_sysreport() {
    make_executable "$SCRIPT_DIR/scripts/sysreport.sh"
    "$SCRIPT_DIR/scripts/sysreport.sh"
}

run_uninstall() {
    log_section "Uninstalling All HP Pro c640 Linux Enablement Components"
    make_executable "$SCRIPT_DIR/keyboard/install-keyboard.sh" \
        "$SCRIPT_DIR/audio/install-audio.sh" \
        "$SCRIPT_DIR/fingerprint/install-fingerprint.sh" \
        "$SCRIPT_DIR/power/install-power.sh" \
        "$SCRIPT_DIR/ec/install-ec.sh" || true

    local failed=0
    "$SCRIPT_DIR/keyboard/install-keyboard.sh" --uninstall || failed=1
    "$SCRIPT_DIR/audio/install-audio.sh" --uninstall || failed=1
    "$SCRIPT_DIR/fingerprint/install-fingerprint.sh" --uninstall || failed=1
    "$SCRIPT_DIR/power/install-power.sh" --uninstall || failed=1
    "$SCRIPT_DIR/ec/install-ec.sh" --uninstall || failed=1

    if [ "$failed" -ne 0 ]; then
        log_error "One or more components failed to uninstall; check the log above."
        return 1
    fi
    log_success "All components uninstalled."
}

# Parse CLI flags
MODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --all | -a | 1)
            MODE="all"
            shift
            ;;
        --audio | --audio-install | -u | 2)
            MODE="audio"
            shift
            ;;
        --fingerprint | -f | --fp | 3)
            MODE="fingerprint"
            shift
            ;;
        --source | --build | --build-from-source)
            MODE="fingerprint"
            export FP_FORCE_SOURCE=1
            shift
            ;;
        --keyboard | -k | --kbd | 4)
            MODE="keyboard"
            shift
            ;;
        --power | -p | 5)
            MODE="power"
            shift
            ;;
        --ec | 6)
            MODE="ec"
            shift
            ;;
        --check | -c | --status | 7)
            MODE="check"
            shift
            ;;
        --sysreport | 8)
            MODE="sysreport"
            shift
            ;;
        --uninstall | --rollback | 9)
            MODE="uninstall"
            shift
            ;;
        --dry-run | -n)
            export DRY_RUN=1
            shift
            ;;
        --help | -h)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

if [ -z "$MODE" ]; then
    show_menu
    read -rp "Enter choice [0-9] (default: 1): " choice
    choice="${choice:-1}"
    case "$choice" in
        1) MODE="all" ;;
        2) MODE="audio" ;;
        3) MODE="fingerprint" ;;
        4) MODE="keyboard" ;;
        5) MODE="power" ;;
        6) MODE="ec" ;;
        7) MODE="check" ;;
        8) MODE="sysreport" ;;
        9) MODE="uninstall" ;;
        0)
            echo "Exiting."
            exit 0
            ;;
        *)
            log_error "Invalid choice: $choice"
            exit 1
            ;;
    esac
fi

case "$MODE" in
    all)
        log_section "Starting Complete HP Pro c640 Linux Enablement"
        run_keyboard
        run_audio
        run_fingerprint
        run_power
        run_check
        log_success "Complete setup finished successfully! 🎉"
        ;;
    keyboard)
        run_keyboard
        ;;
    audio)
        run_audio
        ;;
    fingerprint)
        run_fingerprint
        ;;
    power)
        run_power
        ;;
    ec)
        run_ec
        ;;
    check)
        run_check
        ;;
    sysreport)
        run_sysreport
        ;;
    uninstall)
        run_uninstall
        ;;
esac
