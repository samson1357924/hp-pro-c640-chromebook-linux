#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# keyboard/install-keyboard.sh - Independent Keyboard Top-Row Mapping & Backlight Sync Installer
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

HWDB_SRC="$SCRIPT_DIR/90-chromebook-keyboard.hwdb"
HWDB_DST="/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb"
UDEV_SRC="$SCRIPT_DIR/udev/61-chromeos-kbd-backlight.rules"
UDEV_DST="/etc/udev/rules.d/61-chromeos-kbd-backlight.rules"
DAEMON_SRC="$SCRIPT_DIR/c640-kbd-backlight-sync"
DAEMON_DST="/usr/local/bin/c640-kbd-backlight-sync"
SERVICE_SRC="$SCRIPT_DIR/systemd/c640-kbd-backlight-sync.service"
SERVICE_DST="/etc/systemd/user/c640-kbd-backlight-sync.service"
SLEEP_SRC="$SCRIPT_DIR/systemd/c640-kbd-backlight-sleep.sh"
SLEEP_DST="/usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh"

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --install, -i      Install Chromebook top-row udev hwdb mapping + kbd backlight sync (default)"
    echo "  --check, -c        Check current keyboard hwdb and backlight sync status"
    echo "  --uninstall, -u    Uninstall top-row hwdb mapping and backlight sync"
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

    log_info "=== Keyboard Backlight Sync Status ==="
    if [ -f "$DAEMON_DST" ]; then
        log_success "Backlight daemon installed at $DAEMON_DST"
        if [ -x "$DAEMON_DST" ]; then
            "$DAEMON_DST" --check 2> /dev/null | sed 's/^/  /' || true
        fi
    else
        log_warn "Backlight daemon NOT installed at $DAEMON_DST"
    fi
    if [ -f "$UDEV_DST" ]; then
        log_success "Backlight udev rule installed at $UDEV_DST"
    else
        log_warn "Backlight udev rule NOT installed"
    fi
    if [ -f "$SERVICE_DST" ]; then
        log_success "Backlight user service installed at $SERVICE_DST"
        if systemctl --global is-enabled c640-kbd-backlight-sync.service > /dev/null 2>&1; then
            log_success "  User service is enabled (global)"
        else
            log_warn "  User service is NOT enabled (global)"
        fi
        local real_user
        real_user="$(get_real_user)"
        if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
            local uid
            uid="$(id -u "$real_user" 2> /dev/null || echo "")"
            if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
                if sudo -u "$real_user" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user is-active c640-kbd-backlight-sync.service > /dev/null 2>&1; then
                    log_success "  User service is active for $real_user"
                else
                    log_info "  User service not active for $real_user (will start on next graphical login)"
                fi
            fi
        fi
    else
        log_warn "Backlight user service NOT installed"
    fi
    if [ -f "$SLEEP_DST" ]; then
        log_success "Backlight sleep hook installed at $SLEEP_DST"
    else
        log_warn "Backlight sleep hook NOT installed"
    fi
    if [ -f "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
        local curr max
        curr="$(cat /sys/class/leds/chromeos::kbd_backlight/brightness 2> /dev/null || echo "?")"
        max="$(cat /sys/class/leds/chromeos::kbd_backlight/max_brightness 2> /dev/null || echo "?")"
        log_info "Current kbd backlight: $curr / $max"
    else
        log_warn "No kbd backlight sysfs found (/sys/class/leds/chromeos::kbd_backlight)"
    fi
}

uninstall_keyboard() {
    log_section "Uninstalling Keyboard Top-Row hwdb Mapping & Backlight Sync"

    # Disable user service before rollback (so manifest can capture state, but we also proactively disable)
    if [ "${DRY_RUN:-0}" != "1" ]; then
        local real_user
        real_user="$(get_real_user)"
        if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
            local uid
            uid="$(id -u "$real_user" 2> /dev/null || echo "")"
            if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
                sudo -u "$real_user" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user disable --now c640-kbd-backlight-sync.service 2> /dev/null || true
            fi
        fi
        sudo systemctl --global disable c640-kbd-backlight-sync.service 2> /dev/null || true
        # Also try system scope disable for backwards compat
        sudo systemctl disable c640-kbd-backlight-sync.service 2> /dev/null || true
    else
        log_dryrun "Would disable user service: c640-kbd-backlight-sync.service (global + user)"
    fi

    rollback_component "keyboard"
    remove_group_membership "plugdev" "$(get_real_user)" "keyboard"

    if [ "${DRY_RUN:-0}" != "1" ]; then
        sudo systemd-hwdb update 2> /dev/null || true
        sudo udevadm control --reload-rules 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=input 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=leds 2> /dev/null || true
        sudo systemctl daemon-reload 2> /dev/null || true
        local real_user2
        real_user2="$(get_real_user)"
        if [ -n "$real_user2" ] && [ "$real_user2" != "root" ]; then
            local uid2
            uid2="$(id -u "$real_user2" 2> /dev/null || echo "")"
            if [ -n "$uid2" ] && [ -d "/run/user/$uid2" ]; then
                sudo -u "$real_user2" XDG_RUNTIME_DIR="/run/user/$uid2" systemctl --user daemon-reload 2> /dev/null || true
            fi
        fi
        log_info "Updated systemd-hwdb, udev and daemon-reload."

        # Restore kbd backlight if left at 0 (avoid dark after uninstall)
        if [ -f "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
            local curr max val
            curr="$(cat /sys/class/leds/chromeos::kbd_backlight/brightness 2> /dev/null || echo "?")"
            if [ "$curr" = "0" ]; then
                max="$(cat /sys/class/leds/chromeos::kbd_backlight/max_brightness 2> /dev/null || echo 100)"
                if ! [[ "$max" =~ ^[0-9]+$ ]] || [ "$max" -eq 0 ]; then
                    max=100
                fi
                val=$(( max / 2 ))
                if [ -w "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
                    echo "$val" > /sys/class/leds/chromeos::kbd_backlight/brightness 2> /dev/null || true
                else
                    echo "$val" | sudo tee /sys/class/leds/chromeos::kbd_backlight/brightness > /dev/null 2>&1 || true
                fi
                log_info "Restored kbd backlight to $val/$max after uninstall."
            fi
        fi
        # Clean up state files
        sudo rm -f /run/c640-kbd-backlight/state 2> /dev/null || true
        sudo rmdir /run/c640-kbd-backlight 2> /dev/null || true
        local ru
        ru="$(get_real_user)"
        if [ -n "$ru" ] && [ "$ru" != "root" ]; then
            local ruid
            ruid="$(id -u "$ru" 2> /dev/null || echo "")"
            if [ -n "$ruid" ]; then
                sudo rm -f "/run/user/$ruid/c640-kbd-backlight.state" 2> /dev/null || true
                sudo rm -f "/run/user/$ruid/c640-kbd-backlight.lock" 2> /dev/null || true
            fi
        fi
    else
        log_dryrun "Would run: systemd-hwdb update, udevadm trigger, daemon-reload, restore brightness, clean state"
    fi
    log_success "Keyboard mapping uninstallation completed."
}

install_keyboard() {
    log_section "Installing Chromebook Top-Row Function Keys Mapping & Backlight Sync"
    check_dmi_board || true

    log_step 1 5 "Installing hwdb mapping to $HWDB_DST..."
    backup_file_manifest_aware "$HWDB_DST" "keyboard"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0644 $HWDB_SRC -> $HWDB_DST"
    else
        sudo install -D -m 0644 "$HWDB_SRC" "$HWDB_DST"
    fi

    log_step 2 5 "Installing kbd backlight udev rule to $UDEV_DST..."
    backup_file_manifest_aware "$UDEV_DST" "keyboard"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0644 $UDEV_SRC -> $UDEV_DST"
    else
        sudo install -D -m 0644 "$UDEV_SRC" "$UDEV_DST"
        # Ensure plugdev group exists and add user if rule references it
        if grep -q 'GROUP="plugdev"' "$UDEV_SRC" 2> /dev/null; then
            if ! getent group plugdev > /dev/null 2>&1; then
                sudo groupadd plugdev 2> /dev/null || true
            fi
            local real_user
            real_user="$(get_real_user)"
            if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
                if id -u "$real_user" > /dev/null 2>&1; then
                    local was_member=0
                    id -nG "$real_user" 2> /dev/null | tr ' ' '\n' | grep -qx "plugdev" && was_member=1 || was_member=0
                    # Only add if not already member
                    if [ "$was_member" = "0" ]; then
                        sudo usermod -aG plugdev "$real_user" 2> /dev/null || true
                        log_info "Added $real_user to plugdev group for kbd backlight access (re-login required)"
                    fi
                    manifest_add_group "plugdev" "$real_user" "keyboard" "$was_member"
                fi
            fi
        fi
    fi

    log_step 3 5 "Installing kbd backlight sync daemon to $DAEMON_DST..."
    backup_file_manifest_aware "$DAEMON_DST" "keyboard"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0755 $DAEMON_SRC -> $DAEMON_DST"
    else
        sudo install -D -m 0755 "$DAEMON_SRC" "$DAEMON_DST"
    fi

    log_step 4 5 "Installing kbd backlight user service to $SERVICE_DST..."
    backup_file_manifest_aware "$SERVICE_DST" "keyboard"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0644 $SERVICE_SRC -> $SERVICE_DST"
        log_dryrun "systemctl --global enable c640-kbd-backlight-sync.service"
        log_dryrun "systemctl --user daemon-reload (as $(get_real_user))"
    else
        sudo install -D -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
        # Record service state before enabling (first-wins)
        manifest_add_service "c640-kbd-backlight-sync.service" "keyboard"
        sudo systemctl daemon-reload 2> /dev/null || true
        # Reload user manager and enable globally
        local real_user3
        real_user3="$(get_real_user)"
        if [ -n "$real_user3" ] && [ "$real_user3" != "root" ]; then
            local uid3
            uid3="$(id -u "$real_user3" 2> /dev/null || echo "")"
            if [ -n "$uid3" ] && [ -d "/run/user/$uid3" ]; then
                sudo -u "$real_user3" XDG_RUNTIME_DIR="/run/user/$uid3" systemctl --user daemon-reload 2> /dev/null || true
            fi
        fi
        sudo systemctl --global enable c640-kbd-backlight-sync.service 2> /dev/null || true
        # Try to start for current user if graphical session is active
        if [ -n "${real_user3:-}" ] && [ "$real_user3" != "root" ]; then
            local uid4
            uid4="$(id -u "$real_user3" 2> /dev/null || echo "")"
            if [ -n "$uid4" ] && [ -d "/run/user/$uid4" ]; then
                sudo -u "$real_user3" XDG_RUNTIME_DIR="/run/user/$uid4" systemctl --user start c640-kbd-backlight-sync.service 2> /dev/null || true
            fi
        fi
        log_success "User service enabled (global) and started where possible"
    fi

    log_step 5 5 "Installing kbd backlight sleep hook to $SLEEP_DST..."
    backup_file_manifest_aware "$SLEEP_DST" "keyboard"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0755 $SLEEP_SRC -> $SLEEP_DST"
        log_dryrun "sudo systemd-hwdb update"
        log_dryrun "sudo udevadm trigger --subsystem-match=input"
        log_dryrun "sudo udevadm trigger --subsystem-match=leds"
        log_dryrun "sudo systemctl daemon-reload"
    else
        sudo install -D -m 0755 "$SLEEP_SRC" "$SLEEP_DST"

        log_info "Updating systemd-hwdb and udev..."
        sudo systemd-hwdb update 2> /dev/null || true
        sudo udevadm control --reload-rules 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=input 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=leds 2> /dev/null || true
        sudo systemctl daemon-reload 2> /dev/null || true
        local real_user4
        real_user4="$(get_real_user)"
        if [ -n "$real_user4" ] && [ "$real_user4" != "root" ]; then
            local uid5
            uid5="$(id -u "$real_user4" 2> /dev/null || echo "")"
            if [ -n "$uid5" ] && [ -d "/run/user/$uid5" ]; then
                sudo -u "$real_user4" XDG_RUNTIME_DIR="/run/user/$uid5" systemctl --user daemon-reload 2> /dev/null || true
            fi
        fi
    fi

    log_success "Chromebook top-row keyboard mapping and backlight sync installed! ⌨️"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_info "Dry-run: no system files were changed. Run without --dry-run to apply."
    else
        log_info "Tip: re-login or run 'systemctl --user start c640-kbd-backlight-sync.service' to start the daemon immediately."
        log_info "Test blank: c640-kbd-backlight-sync --test-blank  && c640-kbd-backlight-sync --test-unblank"
    fi
}

# CLI Argument Parsing
ACTION="install"
while [ $# -gt 0 ]; do
    case "$1" in
        --install | -i)
            ACTION="install"
            shift
            ;;
        --check | -c)
            ACTION="check"
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
        install_keyboard
        ;;
    check)
        check_keyboard_status
        ;;
    uninstall)
        uninstall_keyboard
        ;;
esac
