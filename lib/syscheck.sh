#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lib/syscheck.sh - Hardware & Firmware Compatibility Pre-flight Checks

if [ -n "${_LIB_SYSCHECK_SH_LOADED:-}" ]; then
    return 0
fi
_LIB_SYSCHECK_SH_LOADED=1

SCRIPT_DIR_SYSCHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logger.sh
source "$SCRIPT_DIR_SYSCHECK/logger.sh"

check_dmi_board() {
    local board_name="Unknown"
    local product_name="Unknown"
    local sys_vendor="Unknown"

    if [ -f /sys/class/dmi/id/board_name ]; then
        board_name="$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo 'Unknown')"
    fi
    if [ -f /sys/class/dmi/id/product_name ]; then
        product_name="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 'Unknown')"
    fi
    if [ -f /sys/class/dmi/id/sys_vendor ]; then
        sys_vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo 'Unknown')"
    fi

    log_info "Detected Hardware:"
    log_info "  - Vendor:  $sys_vendor"
    log_info "  - Product: $product_name"
    log_info "  - Board:   $board_name"

    # Dratini / Jinlon / Hatch platform detection
    case "$board_name" in
        *Dratini*|*dratini*|*Jinlon*|*jinlon*|*Hatch*|*hatch*)
            log_success "Target Chromebook board ($board_name) matches HP Pro c640 / Hatch platform."
            return 0
            ;;
        *)
            case "$product_name" in
                *Dratini*|*dratini*|*HP*Pro*c640*|*Hatch*|*hatch*)
                    log_success "Target device product ($product_name) matches HP Pro c640."
                    return 0
                    ;;
                *)
                    log_warn "Board '$board_name' / Product '$product_name' is not Dratini/Hatch. Generic Chromebook compatibility logic will be applied."
                    return 1
                    ;;
            esac
            ;;
    esac
}

check_cros_fp_device() {
    if [ -e /dev/cros_fp ]; then
        local perms
        perms="$(ls -l /dev/cros_fp | awk '{print $1, $3, $4}')"
        log_success "ChromeOS Fingerprint device node /dev/cros_fp is present ($perms)."
        return 0
    else
        log_warn "Device node /dev/cros_fp not found. Is ChromeOS EC SPI driver loaded (cros_ec_spi / cros_ec_chardev)?"
        return 1
    fi
}

check_sof_audio_modules() {
    if lsmod | grep -q "snd_sof_pci_intel_cnl"; then
        log_success "Intel Comet Lake SOF DSP module loaded (snd_sof_pci_intel_cnl)."
        return 0
    elif lsmod | grep -q "snd_sof"; then
        log_success "Generic Intel SOF subsystem loaded."
        return 0
    else
        log_warn "Sound Open Firmware (SOF) driver module not active in kernel."
        return 1
    fi
}

check_sof_firmware_files() {
    local fw_paths=(
        "/lib/firmware/intel/sof/community/sof-cml.ri"
        "/lib/firmware/intel/sof/sof-cml.ri"
        "/usr/lib/firmware/intel/sof/community/sof-cml.ri"
    )
    for p in "${fw_paths[@]}"; do
        if [ -f "$p" ]; then
            log_success "Found SOF Comet Lake DSP firmware: $p"
            return 0
        fi
    done
    log_warn "SOF Comet Lake firmware (sof-cml.ri) not found in /lib/firmware/intel/sof/. Please install firmware-sof-signed or linux-firmware."
    return 1
}
