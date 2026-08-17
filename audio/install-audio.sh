#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# audio/install-audio.sh - Modular Audio UCM2 Installer & Manager for HP Pro c640 (Dratini)
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

UCM_FILES=(
    "conf.d/sof-rt5682/sof-rt5682.conf"
    "conf.d/sof-rt5682/HiFi.conf"
    "conf.d/sof-rt5682/rt5682-headset.conf"
    "conf.d/sof-rt5682/rt5682-init.conf"
    "platforms/intel-sof/platform.conf"
    "platforms/intel-sof/codecs.conf"
    "codecs/max98357a/speaker.conf"
    "codecs/hda/hdmi234.conf"
)
UCM_SRC="$SCRIPT_DIR/ucm/ucm2"
UCM_DST="/usr/share/alsa/ucm2"

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --install, -i      Install ALSA UCM2 audio profiles (default)"
    echo "  --check, -c        Check audio driver and hardware status"
    echo "  --uninstall, -u    Uninstall installed UCM2 audio profiles"
    echo "  --dry-run, -n      Preview changes without modifying the system"
    echo "  --help, -h         Show this help message"
}

check_audio_status() {
    log_section "HP Pro c640 Audio Hardware & Driver Status"
    check_dmi_board || true
    check_sof_audio_modules || true
    check_sof_firmware_files || true

    log_info "ALSA Sound Cards:"
    if command -v aplay > /dev/null 2>&1; then
        LC_ALL=C aplay -l 2> /dev/null | grep -E "^card [0-9]+:" || log_warn "No sound cards detected."
    fi

    log_info "Installed UCM2 Profiles in $UCM_DST:"
    local missing=0
    for rel in "${UCM_FILES[@]}"; do
        if [ -f "$UCM_DST/$rel" ]; then
            log_success "  Found: $rel"
        else
            log_warn "  Missing: $rel"
            missing=1
        fi
    done

    if command -v wpctl > /dev/null 2>&1; then
        log_info "PipeWire Audio Sinks & Sources:"
        if wpctl status 2> /dev/null | grep -q "Speaker"; then
            log_success "  PipeWire Speaker sink is active!"
        else
            log_warn "  Speaker sink not found in wpctl status."
        fi
        if wpctl status 2> /dev/null | grep -q "Mic"; then
            log_success "  PipeWire Microphone source is active!"
        fi
    fi

    return "$missing"
}

uninstall_audio() {
    log_section "Uninstalling ALSA UCM2 Profiles"
    rollback_component "audio"

    if [ "${DRY_RUN:-0}" != "1" ]; then
        # Clean up empty dirs
        sudo rmdir "$UCM_DST/conf.d/sof-rt5682" 2> /dev/null || true
    fi
    log_success "Audio UCM profiles removed successfully."
}

install_audio() {
    log_section "Installing ALSA UCM2 Profiles for HP Pro c640 (Dratini)"

    # Pre-flight check
    check_dmi_board || true
    check_sof_audio_modules || true
    check_sof_firmware_files || true

    log_step 1 4 "Backing up existing configs and copying UCM profiles..."
    for rel in "${UCM_FILES[@]}"; do
        local src_file="$UCM_SRC/$rel"
        local dst_file="$UCM_DST/$rel"

        if [ ! -f "$src_file" ]; then
            log_error "Missing source UCM file: $src_file"
            exit 1
        fi

        local existed=0
        if [ -f "$dst_file" ]; then
            existed=1
            backup_file "$dst_file"
        fi

        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Install -D -m 0644 $src_file -> $dst_file"
        else
            sudo install -D -m 0644 "$src_file" "$dst_file"
            manifest_add_entry "$dst_file" "audio" "$existed"
        fi
        log_success "Installed $rel"
    done

    log_step 2 4 "Initializing ALSA controls..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "sudo alsactl init"
    else
        sudo alsactl init || true
    fi

    log_step 3 4 "Restarting PipeWire and WirePlumber user session..."
    local real_user real_uid
    real_user="$(get_real_user)"
    real_uid="$(get_real_user_uid)"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Restart PipeWire & WirePlumber for user $real_user (UID: $real_uid)"
    else
        if [ -n "$real_user" ] && [ -d "/run/user/$real_uid" ]; then
            sudo -u "$real_user" XDG_RUNTIME_DIR="/run/user/$real_uid" systemctl --user restart pipewire wireplumber 2> /dev/null || true
            log_success "PipeWire & WirePlumber restarted for session user '$real_user'."
        elif systemctl --user restart wireplumber 2> /dev/null; then
            log_success "WirePlumber restarted."
        else
            log_info "No active user audio session found; changes will take effect after next login or reboot."
        fi
    fi

    log_step 4 4 "Verifying Audio Routing..."
    if [ "${DRY_RUN:-0}" != "1" ]; then
        if LC_ALL=C aplay -l 2> /dev/null | grep -q "sofrt5682"; then
            log_success "ALSA card 'sofrt5682' is active."
        fi
        if command -v wpctl > /dev/null 2>&1 && wpctl status 2> /dev/null | grep -q "Speaker"; then
            log_success "PipeWire Speaker sink verified!"
        fi
    fi

    log_success "Audio UCM configuration completed successfully! 🔊"
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
        install_audio
        ;;
    check)
        check_audio_status
        ;;
    uninstall)
        uninstall_audio
        ;;
esac
