#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# keyboard/install-keyboard.sh - Independent Keyboard Top-Row Mapping Installer
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logger.sh
source "$ROOT_DIR/lib/logger.sh"
# shellcheck source=lib/backup.sh
source "$ROOT_DIR/lib/backup.sh"
# shellcheck source=lib/syscheck.sh
source "$ROOT_DIR/lib/syscheck.sh"

HWDB_SRC="$SCRIPT_DIR/90-chromebook-keyboard.hwdb"
HWDB_DST="/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb"

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --install, -i      Install Chromebook top-row udev hwdb mapping (default)"
    echo "  --check, -c        Check current keyboard hwdb mapping status"
    echo "  --uninstall, -u    Uninstall top-row hwdb mapping and revert systemd-hwdb"
    echo "  --dry-run, -n      Preview changes without modifying files"
    echo "  --help, -h         Show this help message"
}

check_keyboard_status() {
    log_section "HP Pro c640 Keyboard Hardware & hwdb Status"
    check_dmi_board || true

    if [ -f "$HWDB_DST" ]; then
        log_success "Keyboard hwdb mapping is installed at $HWDB_DST."
    else
        log_warn "Keyboard hwdb mapping is NOT installed in /etc/udev/hwdb.d/."
    fi
}

uninstall_keyboard() {
    log_section "Uninstalling Keyboard Top-Row hwdb Mapping"
    rollback_component "keyboard"

    if [ "${DRY_RUN:-0}" != "1" ]; then
        if [ -f "$HWDB_DST" ]; then
            sudo rm -f "$HWDB_DST"
            sudo systemd-hwdb update 2>/dev/null || true
            sudo udevadm trigger --subsystem-match=input 2>/dev/null || true
            log_info "Removed $HWDB_DST and updated systemd-hwdb."
        fi
    fi
    log_success "Keyboard mapping uninstallation completed."
}

install_keyboard() {
    log_section "Installing Chromebook Top-Row Function Keys Mapping"
    check_dmi_board || true

    log_step 1 3 "Installing hwdb mapping to $HWDB_DST..."
    local existed=0
    if [ -f "$HWDB_DST" ]; then
        existed=1
        backup_file "$HWDB_DST"
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0644 $HWDB_SRC -> $HWDB_DST"
        log_dryrun "sudo systemd-hwdb update"
        log_dryrun "sudo udevadm trigger --subsystem-match=input"
    else
        sudo install -D -m 0644 "$HWDB_SRC" "$HWDB_DST"
        manifest_add_entry "$HWDB_DST" "keyboard" "$existed"

        log_step 2 3 "Updating systemd-hwdb database..."
        sudo systemd-hwdb update

        log_step 3 3 "Triggering udev input subsystem rules..."
        sudo udevadm trigger --subsystem-match=input || true
    fi

    log_success "Chromebook top-row keyboard mapping installed and active! ⌨️"
}

# CLI Argument Parsing
ACTION="install"
while [ $# -gt 0 ]; do
    case "$1" in
        --install|-i)
            ACTION="install"
            shift
            ;;
        --check|-c)
            ACTION="check"
            shift
            ;;
        --uninstall|-u)
            ACTION="uninstall"
            shift
            ;;
        --dry-run|-n)
            export DRY_RUN=1
            shift
            ;;
        --help|-h)
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

case "$ACTION" in
    install)
        install_keyboard
        ;;
    check)
        check_keyboard_status
        ;;
    uninstall)
        uninstall_keyboard
        ;;
esac
