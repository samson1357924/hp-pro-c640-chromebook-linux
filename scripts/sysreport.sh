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

# sed rules applied to every collected text file before bundling so personal
# information (MAC/IP/email/hostname/home dirs/serial numbers) never ships.
REDACT_HOSTNAME="$(hostname 2> /dev/null || true)"
REDACT_HOSTNAME="$(printf '%s' "$REDACT_HOSTNAME" | sed 's/[][\.|$(){}?+*^]/\\&/g')"
REDACT_ARGS=(
    -E
    -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/<MAC>/g'
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<IP>/g'
    -e 's/[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4})*::[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{1,4})*/<IP6>/g'
    -e 's/::[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{1,4})*/<IP6>/g'
    -e 's/[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){3,}/<IP6>/g'
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<EMAIL>/g'
    -e 's|/home/[A-Za-z0-9._-]+|/home/<USER>|g'
    -e 's/[Ss]erial[[:space:]]*[:=]?[[:space:]]*[A-Za-z0-9][A-Za-z0-9_-]{5,}/<SERIAL>/g'
)
if [ -n "$REDACT_HOSTNAME" ]; then
    REDACT_ARGS+=(-e "s/[[:space:]]${REDACT_HOSTNAME}([[:space:]])/ <HOSTNAME>\1/g")
fi

redact() {
    sed "${REDACT_ARGS[@]}"
}

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
dmesg -T -l err,warn 2> /dev/null > "$REPORT_DIR/system/dmesg_warnings.txt" || true

# 6. Uniform privacy redaction across every collected file
log_info "Redacting personal information (MAC/IP/email/hostname/home/serial)..."
while IFS= read -r -d '' f; do
    tmp="${f}.redact.$$"
    if redact < "$f" > "$tmp" 2> /dev/null; then
        mv -f "$tmp" "$f"
    else
        rm -f "$tmp"
    fi
done < <(find "$REPORT_DIR" -type f -print0)

# Compress into tar.gz
tar -czf "$ROOT_DIR/$ARCHIVE_NAME" -C "$REPORT_DIR" .
rm -rf "$REPORT_DIR"

log_success "Diagnostic report generated successfully: $ARCHIVE_NAME"
echo "You can attach this file when opening issues or seeking community assistance."
echo "NOTE: The bundle is redacted, but double-check it before sharing."