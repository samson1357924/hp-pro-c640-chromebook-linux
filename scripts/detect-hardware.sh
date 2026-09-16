#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# scripts/detect-hardware.sh - Comprehensive Hardware Diagnostic Tool for HP Pro c640 (Dratini)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logger.sh
source "$ROOT_DIR/lib/logger.sh"
# shellcheck source=lib/distro.sh
source "$ROOT_DIR/lib/distro.sh"
# shellcheck source=lib/syscheck.sh
source "$ROOT_DIR/lib/syscheck.sh"

run_diagnostic() {
    log_section "HP Pro c640 Chromebook (Google Dratini) Full Diagnostic Report"

    # 1. System & Firmware Identification
    log_step 1 6 "System & OS Identification"
    log_info "OS / Distro  : $DISTRO_NAME ($DISTRO_FAMILY, ID: $DISTRO_ID)"
    log_info "Kernel       : $(uname -r)"
    check_dmi_board || true

    # 2. Audio Subsystem
    log_step 2 6 "Audio Subsystem (SOF DSP & UCM2)"
    check_sof_audio_modules || true
    check_sof_firmware_files || true

    if command -v aplay > /dev/null 2>&1; then
        log_info "ALSA Playback Sound Cards:"
        if LC_ALL=C aplay -l 2> /dev/null | grep -E "^card [0-9]+:"; then
            LC_ALL=C aplay -l 2> /dev/null | grep -E "^card [0-9]+:" | while read -r line; do
                log_success "  $line"
            done
        elif aplay -l 2> /dev/null | grep -E "(card|卡|裝置)"; then
            aplay -l 2> /dev/null | grep -E "(card|卡|裝置)" | while read -r line; do
                log_success "  $line"
            done
        else
            log_warn "  No ALSA sound cards detected."
        fi
    fi

    local ucm_files=(
        "conf.d/sof-rt5682/sof-rt5682.conf"
        "conf.d/sof-rt5682/HiFi.conf"
        "conf.d/sof-rt5682/rt5682-headset.conf"
        "conf.d/sof-rt5682/rt5682-init.conf"
        "platforms/intel-sof/platform.conf"
        "platforms/intel-sof/codecs.conf"
        "codecs/max98357a/speaker.conf"
        "codecs/hda/hdmi234.conf"
    )
    log_info "ALSA UCM2 Profile Status (/usr/share/alsa/ucm2/):"
    local missing_ucm=0
    for rel in "${ucm_files[@]}"; do
        if [ -f "/usr/share/alsa/ucm2/$rel" ]; then
            log_success "  [OK] $rel"
        else
            log_warn "  [MISSING] $rel"
            missing_ucm=1
        fi
    done
    [ "$missing_ucm" = 0 ] || log_info "  Tip: Run './setup.sh --audio-install' to deploy missing UCM profiles."

    if command -v wpctl > /dev/null 2>&1; then
        log_info "PipeWire Routing Status:"
        if wpctl status 2> /dev/null | grep -q "Speaker"; then
            log_success "  PipeWire Speaker sink is active!"
        else
            log_warn "  Speaker sink not found in wpctl status."
        fi
    fi

    # 3. Fingerprint Subsystem
    log_step 3 6 "Fingerprint Subsystem (ChromeOS MoC)"
    check_cros_fp_device || true

    local local_user
    local_user="$(get_real_user)"
    log_info "User '$local_user' group membership:"
    if id -nG "$local_user" 2> /dev/null | grep -qw "plugdev"; then
        log_success "  User '$local_user' is in 'plugdev' group."
    else
        log_warn "  User '$local_user' is NOT in 'plugdev' group. (Run: sudo usermod -aG plugdev $local_user)"
    fi

    log_info "Installed libfprint binaries in $LIBDIR:"
    ls -la "$LIBDIR"/libfprint-2.so* 2> /dev/null || log_warn "  No custom libfprint-2.so in $LIBDIR"

    if command -v fprintd-list > /dev/null 2>&1; then
        log_info "fprintd Enrolled Fingerprints for $local_user:"
        fprintd-list "$local_user" 2> /dev/null || log_warn "  fprintd returned non-zero. Device may not be registered yet."
    fi

    # 4. Keyboard & Function Keys (+ Backlight Sync)
    log_step 4 6 "Keyboard Top-Row Action Mapping & Backlight Sync"
    if [ -f /etc/udev/hwdb.d/90-chromebook-keyboard.hwdb ]; then
        log_success "  90-chromebook-keyboard.hwdb installed in /etc/udev/hwdb.d/"
        if command -v systemd-hwdb > /dev/null 2>&1; then
            if systemd-hwdb query "evdev:atkbd:dmi:bvn*:bvr*:bd*:svnGoogle*:pn*Dratini*:pvr*" 2> /dev/null | grep -q "KEYBOARD_KEY_db=leftmeta"; then
                log_success "  hwdb query for Dratini OK (KEYBOARD_KEY_db=leftmeta present)"
            elif systemd-hwdb query "evdev:atkbd:dmi:bvn*:bvr*:bd*:svnGoogle*:pn*Dratini*:pvr*" 2> /dev/null | grep -q "KEYBOARD_KEY_ea=back"; then
                log_success "  hwdb query for Dratini OK (KEYBOARD_KEY_ea present, but db missing - update hwdb)"
            else
                log_warn "  hwdb query for Dratini missing KEYBOARD_KEY_ea (run systemd-hwdb update)"
            fi
            for q in "evdev:atkbd:dmi:bvnGoogle:bvr13579:bd01/01/2021:svnGoogle:pnHatch:pvr1.0" "evdev:atkbd:dmi:bvnHP:bvr13579:bd01/01/2021:svnHP:pnc640:pvr1.0" "evdev:atkbd:dmi:bvnHP:bvr13579:bd01/01/2021:svnHP:pnHP Pro c640 Chromebook:pvr1.0"; do
                if ! systemd-hwdb query "$q" 2> /dev/null | grep -q "KEYBOARD_KEY_db=leftmeta"; then
                    log_warn "  hwdb query missing db for $q"
                fi
            done
        fi
    else
        log_warn "  Custom keyboard hwdb not deployed. Run './setup.sh --keyboard' to install."
    fi

    if [ -f /etc/udev/rules.d/61-chromeos-kbd-backlight.rules ]; then
        log_success "  61-chromeos-kbd-backlight.rules installed"
    else
        log_info "  Backlight udev rule not installed (optional, run './setup.sh --keyboard')"
    fi

    if [ -f /usr/local/bin/c640-kbd-backlight-sync ]; then
        log_success "  c640-kbd-backlight-sync daemon installed at /usr/local/bin/c640-kbd-backlight-sync"
        if [ -x /usr/local/bin/c640-kbd-backlight-sync ]; then
            /usr/local/bin/c640-kbd-backlight-sync --check 2> /dev/null | sed 's/^/    /' || true
        fi
        if systemctl --global is-enabled c640-kbd-backlight-sync.service > /dev/null 2>&1; then
            log_success "  Backlight user service enabled (global)"
        else
            log_warn "  Backlight user service not enabled (global)"
        fi
        if [ -f /etc/systemd/user/c640-kbd-backlight-sync.service ]; then
            log_success "  Backlight user service file present"
        fi
    else
        log_info "  Backlight daemon not installed (run './setup.sh --keyboard')"
    fi

    if [ -f /usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh ]; then
        log_success "  Backlight sleep hook present at /usr/lib/systemd/system-sleep/"
    else
        log_info "  Backlight sleep hook not installed"
    fi

    if [ -f /sys/class/leds/chromeos::kbd_backlight/brightness ]; then
        local curr max
        curr="$(cat /sys/class/leds/chromeos::kbd_backlight/brightness 2> /dev/null || echo "?")"
        max="$(cat /sys/class/leds/chromeos::kbd_backlight/max_brightness 2> /dev/null || echo "?")"
        log_info "  Current kbd backlight: $curr / $max"
    else
        log_warn "  No kbd backlight sysfs (/sys/class/leds/chromeos::kbd_backlight) - is this a hatch device?"
    fi

    if systemctl is-active --quiet keyd 2> /dev/null; then
        log_success "  keyd daemon is running for advanced dual-role (Search tap=CapsLock hold=Super)"
    elif systemctl is-enabled --quiet keyd 2> /dev/null; then
        log_warn "  keyd is enabled but not active"
    else
        if [ -f /etc/keyd/cros.conf ] || [ -f /etc/keyd/default.conf ] || [ -L /etc/keyd/default.conf ]; then
            log_info "  keyd config present but keyd not active (sudo systemctl enable --now keyd)"
        else
            log_info "  keyd not installed (optional, use --with-keyd)"
        fi
    fi
    if [ -f /etc/keyd/cros.conf ]; then
        log_success "  keyd config at /etc/keyd/cros.conf"
        if command -v keyd > /dev/null 2>&1; then
            if keyd check /etc/keyd/cros.conf > /dev/null 2>&1; then
                log_success "  keyd config syntax valid"
            else
                log_warn "  keyd config syntax check failed for /etc/keyd/cros.conf"
            fi
        fi
    fi
    if [ -L /etc/keyd/default.conf ]; then
        local kd_target
        kd_target="$(readlink /etc/keyd/default.conf 2> /dev/null || echo "?")"
        log_info "  keyd default.conf -> $kd_target"
        if [ ! -e /etc/keyd/default.conf ]; then
            log_warn "  keyd default.conf is dangling symlink"
        fi
    fi

    # 5. Power & Battery Management
    log_step 5 6 "Power Management & S0ix Sleep"
    if [ -f /sys/power/mem_sleep ]; then
        log_info "Supported mem_sleep modes: $(cat /sys/power/mem_sleep)"
    fi

    if [ -d /sys/class/power_supply/BAT0 ]; then
        local bat_status bat_cap
        bat_status="$(cat /sys/class/power_supply/BAT0/status 2> /dev/null || echo Unknown)"
        bat_cap="$(cat /sys/class/power_supply/BAT0/capacity 2> /dev/null || echo Unknown)"
        log_success "Battery BAT0 detected: ${bat_cap}% ($bat_status)"
    fi

    # 6. Summary
    log_step 6 6 "Diagnostic Summary"
    log_info "Hardware diagnostic run complete! Log saved to $LOG_FILE."
}

run_diagnostic
