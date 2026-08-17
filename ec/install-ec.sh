#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ec/install-ec.sh - ChromeOS EC Tool & Battery Protection Installer for HP Pro c640
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logger.sh
source "$ROOT_DIR/lib/logger.sh"
# shellcheck source=lib/distro.sh
source "$ROOT_DIR/lib/distro.sh"
# shellcheck source=lib/backup.sh
source "$ROOT_DIR/lib/backup.sh"
# shellcheck source=lib/syscheck.sh
source "$ROOT_DIR/lib/syscheck.sh"

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --install, -i           Install c640-ec-control utility (default)"
    echo "  --enable-battery-limit  Enable automatic 80% battery protection service"
    echo "  --uninstall, -u         Uninstall EC tools and services"
    echo "  --dry-run, -n           Preview steps without execution"
    echo "  --help, -h              Show this help message"
}

install_ec_tools() {
    log_section "Installing ChromeOS EC Utilities for HP Pro c640 ($DISTRO_NAME)"
    check_dmi_board || true

    local bin_dst="/usr/local/bin/c640-ec-control"
    local bin_src="$ROOT_DIR/scripts/c640-ec-control.sh"

    log_step 1 2 "Installing c640-ec-control to $bin_dst..."
    local bin_existed=0
    if [ -e "$bin_dst" ]; then
        bin_existed=1
    fi
    backup_file "$bin_dst"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0755 $bin_src -> $bin_dst"
    else
        sudo install -D -m 0755 "$bin_src" "$bin_dst"
        manifest_add_entry "$bin_dst" "ec" "$bin_existed"
        log_success "Installed $bin_dst"
    fi

    # Install udev rule for /dev/cros_ec if not present
    local udev_dst="/etc/udev/rules.d/60-cros-ec.rules"
    local udev_existed=0
    if [ -e "$udev_dst" ]; then
        udev_existed=1
    fi
    backup_file "$udev_dst"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install 60-cros-ec.rules"
    else
        echo 'KERNEL=="cros_ec", SUBSYSTEM=="misc", GROUP="plugdev", MODE="0660", TAG+="uaccess"' | sudo tee "$udev_dst" > /dev/null
        manifest_add_entry "$udev_dst" "ec" "$udev_existed"

        # Ensure plugdev group exists and add user
        if ! getent group plugdev > /dev/null 2>&1; then
            sudo groupadd plugdev 2> /dev/null || true
        fi
        local real_user
        real_user="$(get_real_user)"
        if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
            sudo usermod -aG plugdev "$real_user" || true
        fi

        sudo udevadm control --reload-rules 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=misc 2> /dev/null || true
        [ -e /dev/cros_ec ] && sudo chmod 0660 /dev/cros_ec 2> /dev/null || true
        log_success "Configured udev access for /dev/cros_ec."
    fi

    log_section "c640-ec-control installed successfully! 🔋"
    echo "You can now run:"
    echo "    c640-ec-control status"
    echo "    c640-ec-control battery-limit 80"
}

enable_battery_service() {
    log_section "Enabling 80% Battery Protection Service"
    local srv_dst="/etc/systemd/system/c640-battery-limit.service"
    local srv_src="$SCRIPT_DIR/systemd/c640-battery-limit.service"

    # The service runs `c640-ec-control battery-limit 80`, which requires
    # the ectool binary. Refuse to enable it if ectool is unavailable,
    # otherwise the service would fail on every boot.
    if ! command -v ectool > /dev/null 2>&1 && [ ! -x /usr/local/bin/ectool ]; then
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Require ectool for the battery limit service (would abort without it)"
        else
            log_error "ectool not found. The battery limit service requires ectool to talk to the ChromeOS EC."
            log_info "Provide ectool (e.g. install a prebuilt binary at /usr/local/bin/ectool or add one to ec/bin/) and re-run with --enable-battery-limit."
            return 1
        fi
    fi

    if [ -f "$srv_src" ]; then
        local srv_existed=0
        if [ -e "$srv_dst" ]; then
            srv_existed=1
        fi
        backup_file "$srv_dst"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Deploy and enable $srv_dst"
        else
            sudo install -D -m 0644 "$srv_src" "$srv_dst"
            manifest_add_entry "$srv_dst" "ec" "$srv_existed"
            sudo systemctl daemon-reload
            sudo systemctl enable --now c640-battery-limit.service
            log_success "80% Battery protection service enabled!"
        fi
    fi
}

uninstall_ec_tools() {
    log_section "Uninstalling ChromeOS EC Utilities"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        sudo systemctl disable --now c640-battery-limit.service 2> /dev/null || true
    fi

    rollback_component "ec"

    if [ "${DRY_RUN:-0}" != "1" ]; then
        sudo systemctl daemon-reload
    fi
    log_success "EC utilities removed."
}

ACTION="install"
ENABLE_BATTERY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --install | -i)
            ACTION="install"
            shift
            ;;
        --enable-battery-limit)
            ENABLE_BATTERY=1
            shift
            ;;
        --uninstall | -u)
            ACTION="uninstall"
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

case "$ACTION" in
    install)
        install_ec_tools
        if [ "$ENABLE_BATTERY" = "1" ]; then
            enable_battery_service
        fi
        ;;
    uninstall)
        uninstall_ec_tools
        ;;
esac
