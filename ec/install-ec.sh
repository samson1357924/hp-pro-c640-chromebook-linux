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
    echo "  --enable-battery-limit  Enable automatic 90% battery protection service and sleep hook"
    echo "  --uninstall, -u         Uninstall EC tools and services"
    echo "  --dry-run, -n           Preview steps without execution"
    echo "  --help, -h              Show this help message"
}

install_ec_tools() {
    log_section "Installing ChromeOS EC Utilities for HP Pro c640 ($DISTRO_NAME)"
    check_dmi_board || true

    local bin_dst="/usr/local/bin/c640-ec-control"
    local bin_src="$ROOT_DIR/scripts/c640-ec-control.sh"

    log_step 1 3 "Installing c640-ec-control to $bin_dst..."
    backup_file_manifest_aware "$bin_dst" "ec"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0755 $bin_src -> $bin_dst"
    else
        sudo install -D -m 0755 "$bin_src" "$bin_dst"
        log_success "Installed $bin_dst"
    fi

    # Install runtime libraries required by c640-ec-control (logger + syscheck).
    # Without these the installed binary fails on every boot (missing libs).
    local lib_dst_dir="/usr/local/lib/c640-ec"
    log_step 2 3 "Installing runtime libraries to $lib_dst_dir..."
    local lib_files=("logger.sh" "syscheck.sh")
    for lib in "${lib_files[@]}"; do
        local lib_dst="$lib_dst_dir/$lib"
        backup_file_manifest_aware "$lib_dst" "ec"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Install -D -m 0644 $ROOT_DIR/lib/$lib -> $lib_dst"
        else
            sudo install -D -m 0644 "$ROOT_DIR/lib/$lib" "$lib_dst"
            log_success "Installed $lib_dst"
        fi
    done

    # Deploy bundled ectool if the user placed one in ec/bin/ (optional)
    if [ -f "$ROOT_DIR/ec/bin/ectool" ]; then
        local ectool_dst="/usr/local/bin/ectool"
        backup_file_manifest_aware "$ectool_dst" "ec"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Install -D -m 0755 $ROOT_DIR/ec/bin/ectool -> $ectool_dst"
        else
            sudo install -D -m 0755 "$ROOT_DIR/ec/bin/ectool" "$ectool_dst"
            log_success "Installed $ectool_dst"
        fi
    fi

    # Install udev rule for /dev/cros_ec if not present
    local udev_dst="/etc/udev/rules.d/60-cros-ec.rules"
    backup_file_manifest_aware "$udev_dst" "ec"
    log_step 3 3 "Installing udev rule for /dev/cros_ec..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install 60-cros-ec.rules"
    else
        sudo mkdir -p "$(dirname "$udev_dst")"
        echo 'KERNEL=="cros_ec", SUBSYSTEM=="misc", GROUP="plugdev", MODE="0660", TAG+="uaccess"' | sudo tee "$udev_dst" > /dev/null

        # Ensure plugdev group exists and add user
        if ! getent group plugdev > /dev/null 2>&1; then
            sudo groupadd plugdev 2> /dev/null || true
        fi
        local real_user
        real_user="$(get_real_user)"
        if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
            if id -u "$real_user" > /dev/null 2>&1; then
                local was_member=0
                id -nG "$real_user" 2> /dev/null | tr ' ' '\n' | grep -qx "plugdev" && was_member=1
                sudo usermod -aG plugdev "$real_user" || true
                manifest_add_group "plugdev" "$real_user" "ec" "$was_member"
            else
                log_warn "User '$real_user' does not exist; skipping plugdev membership."
            fi
        fi

        sudo udevadm control --reload-rules 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=misc 2> /dev/null || true
        [ -e /dev/cros_ec ] && sudo chmod 0660 /dev/cros_ec 2> /dev/null || true
        log_success "Configured udev access for /dev/cros_ec."
    fi

    log_section "c640-ec-control installed successfully! 🔋"
    echo "You can now run:"
    echo "    c640-ec-control status"
    echo "    c640-ec-control battery-limit 90"
}

enable_battery_service() {
    log_section "Enabling 90% Battery Protection Service & Sleep Hook"
    local srv_dst="/etc/systemd/system/c640-battery-limit.service"
    local srv_src="$SCRIPT_DIR/systemd/c640-battery-limit.service"
    local sleep_dst="/usr/lib/systemd/system-sleep/c640-ec-sleep.sh"
    local sleep_src="$SCRIPT_DIR/systemd/c640-ec-sleep.sh"

    # Deploy system-sleep hook for instant resume protection
    if [ -f "$sleep_src" ]; then
        backup_file_manifest_aware "$sleep_dst" "ec"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Install -D -m 0755 $sleep_src -> $sleep_dst"
        else
            sudo install -D -m 0755 "$sleep_src" "$sleep_dst"
            log_success "Installed $sleep_dst (resume hook)"
        fi
    fi

    if [ -f "$srv_src" ]; then
        backup_file_manifest_aware "$srv_dst" "ec"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Deploy and enable $srv_dst"
        else
            sudo install -D -m 0644 "$srv_src" "$srv_dst"
            manifest_add_service "c640-battery-limit.service" "ec"
            sudo systemctl daemon-reload
            sudo systemctl enable --now c640-battery-limit.service
            log_success "90% Battery protection service and resume hook enabled!"
        fi
    fi
}

uninstall_ec_tools() {
    log_section "Uninstalling ChromeOS EC Utilities"
    if [ "${DRY_RUN:-0}" != "1" ]; then
        if [ -x "/usr/local/bin/c640-ec-control" ]; then
            /usr/local/bin/c640-ec-control battery-full 2> /dev/null || true
            /usr/local/bin/c640-ec-control fan-auto 2> /dev/null || true
        fi
        sudo systemctl disable --now c640-battery-limit.service 2> /dev/null || true
    fi

    rollback_component "ec"
    remove_group_membership "plugdev" "$(get_real_user)" "ec"

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
