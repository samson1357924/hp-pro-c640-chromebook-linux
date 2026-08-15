#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# scripts/sysreport.sh - Unified System Diagnostic & Hardware Report Generator for HP Pro c640
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logger.sh
source "$ROOT_DIR/lib/logger.sh"

REPORT_DIR=$(mktemp -d -t c640-sysreport-XXXXXX)
ARCHIVE_NAME="c640-diagnostic-$(date '+%Y%m%d_%H%M%S').tar.gz"

log_section "Generating HP Pro c640 Linux Diagnostic Bundle"
log_info "Collecting system information into temporary folder: $REPORT_DIR..."

# 1. Hardware & DMI
mkdir -p "$REPORT_DIR/hardware"
cat /sys/class/dmi/id/product_name > "$REPORT_DIR/hardware/dmi_product" 2> /dev/null || true
cat /sys/class/dmi/id/product_family > "$REPORT_DIR/hardware/dmi_family" 2> /dev/null || true
cat /sys/class/dmi/id/bios_version > "$REPORT_DIR/hardware/bios_version" 2> /dev/null || true
lspci -nnk > "$REPORT_DIR/hardware/lspci.txt" 2> /dev/null || true
lsusb -tv > "$REPORT_DIR/hardware/lsusb.txt" 2> /dev/null || true

# 2. Kernel & OS
mkdir -p "$REPORT_DIR/system"
uname -a > "$REPORT_DIR/system/uname.txt" 2> /dev/null || true
cat /proc/cmdline > "$REPORT_DIR/system/cmdline.txt" 2> /dev/null || true
cat /etc/os-release > "$REPORT_DIR/system/os-release.txt" 2> /dev/null || true
cat /sys/power/mem_sleep > "$REPORT_DIR/system/mem_sleep.txt" 2> /dev/null || true

# 3. Audio & PipeWire
mkdir -p "$REPORT_DIR/audio"
if command -v aplay > /dev/null 2>&1; then
    LC_ALL=C aplay -l > "$REPORT_DIR/audio/aplay.txt" 2> /dev/null || true
fi
if command -v wpctl > /dev/null 2>&1; then
    wpctl status > "$REPORT_DIR/audio/wpctl.txt" 2> /dev/null || true
fi

# 4. Fingerprint & EC
mkdir -p "$REPORT_DIR/fingerprint_ec"
ls -la /dev/cros_* > "$REPORT_DIR/fingerprint_ec/dev_nodes.txt" 2> /dev/null || true
if [ -d "/sys/class/power_supply/BAT0" ]; then
    cat /sys/class/power_supply/BAT0/uevent > "$REPORT_DIR/fingerprint_ec/battery.txt" 2> /dev/null || true
fi

# 5. Dmesg Errors & Warnings
dmesg -T -l err,warn > "$REPORT_DIR/system/dmesg_warnings.txt" 2> /dev/null || true

# Compress into tar.gz
tar -czf "$ROOT_DIR/$ARCHIVE_NAME" -C "$REPORT_DIR" .
rm -rf "$REPORT_DIR"

log_success "Diagnostic report generated successfully: $ARCHIVE_NAME"
echo "You can attach this file when opening issues or seeking community assistance."
