#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Hardware Diagnostic Script for HP Pro c640 Chromebook (Google Dratini)

echo "==========================================================="
echo "   HP Pro c640 Chromebook Hardware Diagnostic Report       "
echo "==========================================================="
echo ""

echo "--- [1/5] System Identification ---"
echo "Product Name : $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 'Unknown')"
echo "Sys Vendor   : $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo 'Unknown')"
echo "Board Name   : $(cat /sys/class/dmi/id/board_name 2>/dev/null || echo 'Unknown')"
echo "Kernel       : $(uname -r)"
echo ""

echo "--- [2/5] Fingerprint Sensor (/dev/cros_fp) ---"
if [ -e /dev/cros_fp ]; then
    echo "  [OK] /dev/cros_fp character device exists."
    ls -l /dev/cros_fp
else
    echo "  [FAIL] /dev/cros_fp not found. Ensure cros_ec_chardev kernel driver is active."
fi

if command -v fprintd-list >/dev/null 2>&1; then
    echo "Fprintd Registered Fingers for $USER:"
    fprintd-list "$USER" || true
fi
echo ""

echo "--- [3/5] Audio Subsystem (SOF DSP) ---"
if lsmod | grep -q "snd_sof"; then
    echo "  [OK] Sound Open Firmware (SOF) kernel module is loaded."
else
    echo "  [INFO] SOF module not detected; standard HD-Audio fallback in use."
fi

if command -v aplay >/dev/null 2>&1; then
    echo "Detected Sound Cards:"
    aplay -l 2>/dev/null | grep -E "^card" || echo "  No cards detected"
fi
echo ""

echo "--- [4/5] Keyboard & Input Devices ---"
if [ -f /etc/udev/hwdb.d/90-chromebook-keyboard.hwdb ]; then
    echo "  [OK] 90-chromebook-keyboard.hwdb installed in /etc/udev/hwdb.d/"
else
    echo "  [INFO] Custom keyboard hwdb not found. Run ./setup.sh to install."
fi
echo ""

echo "--- [5/5] PAM Fingerprint Authentication ---"
if grep -q "pam_fprintd.so" /etc/pam.d/common-auth 2>/dev/null; then
    echo "  [OK] pam_fprintd is active in /etc/pam.d/common-auth"
else
    echo "  [INFO] pam_fprintd not enabled in common-auth. Run 'sudo pam-auth-update --enable fprintd'"
fi
echo ""
echo "Diagnostic complete!"
