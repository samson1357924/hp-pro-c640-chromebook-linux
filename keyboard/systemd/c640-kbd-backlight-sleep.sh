#!/bin/sh
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# c640-kbd-backlight-sleep.sh - systemd system-sleep hook for keyboard backlight
# Saves brightness before suspend and restores after resume, complementing the
# user-session daemon that handles screen blank (org.gnome.ScreenSaver).
# Installed to /usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh
set -eu

SYSFS="/sys/class/leds/chromeos::kbd_backlight/brightness"
SYSFS_MAX="/sys/class/leds/chromeos::kbd_backlight/max_brightness"
STATE_DIR="/run/c640-kbd-backlight"
STATE_FILE="$STATE_DIR/state"

save_state() {
    if [ ! -f "$SYSFS" ]; then
        return 0
    fi
    if [ -f "$STATE_FILE" ]; then
        return 0
    fi
    curr="$(cat "$SYSFS" 2> /dev/null || echo "")"
    case "$curr" in
        '' | *[!0-9]*)
            return 0
            ;;
    esac
    if [ "$curr" -eq 0 ]; then
        return 0
    fi
    mkdir -p "$STATE_DIR" 2> /dev/null || true
    tmp="$(mktemp "$STATE_DIR/.state.XXXXXX" 2> /dev/null || mktemp /tmp/.c640-kbd-sleep-XXXXXX)"
    echo "$curr" > "$tmp" 2> /dev/null || true
    chmod 600 "$tmp" 2> /dev/null || true
    mv -f "$tmp" "$STATE_FILE" 2> /dev/null || cp "$tmp" "$STATE_FILE" 2> /dev/null || true
    rm -f "$tmp" 2> /dev/null || true
}

restore_state() {
    if [ ! -f "$STATE_FILE" ]; then
        return 0
    fi
    saved="$(cat "$STATE_FILE" 2> /dev/null || echo "")"
    rm -f "$STATE_FILE" 2> /dev/null || true
    case "$saved" in
        '' | *[!0-9]*)
            return 0
            ;;
    esac
    if [ "$saved" -eq 0 ]; then
        return 0
    fi
    if [ ! -f "$SYSFS" ]; then
        return 0
    fi
    curr="$(cat "$SYSFS" 2> /dev/null || echo "")"
    case "$curr" in
        '' | *[!0-9]*)
            curr=0
            ;;
    esac
    # Only restore if currently 0 (avoid overwriting manual change)
    if [ "$curr" -ne 0 ]; then
        return 0
    fi
    max="$(cat "$SYSFS_MAX" 2> /dev/null || echo 100)"
    case "$max" in
        '' | *[!0-9]*)
            max=100
            ;;
    esac
    if [ "$max" -eq 0 ]; then
        max=100
    fi
    if [ "$saved" -gt "$max" ]; then
        saved="$max"
    fi
    if [ -w "$SYSFS" ]; then
        echo "$saved" > "$SYSFS" 2> /dev/null || true
    else
        # hook runs as root, should be writable; fallback to ectool
        echo "$saved" > "$SYSFS" 2> /dev/null || true
        if [ "$(cat "$SYSFS" 2> /dev/null || echo -1)" != "$saved" ]; then
            if command -v ectool > /dev/null 2>&1; then
                pct=$((saved * 100 / max))
                ectool pwmsetkblight "$pct" > /dev/null 2>&1 || true
            elif [ -x /usr/local/bin/ectool ]; then
                pct=$((saved * 100 / max))
                /usr/local/bin/ectool pwmsetkblight "$pct" > /dev/null 2>&1 || true
            fi
        fi
    fi
}

case "${1:-}" in
    pre)
        save_state
        # Optionally turn off backlight before sleep to save power
        # Do not force 0 here; let daemon handle blank and kernel LED_CORE_SUSPENDRESUME
        # keep current brightness during suspend entry.
        ;;
    post)
        # Delay to avoid racing with LED_CORE_SUSPENDRESUME and gsd-power re-blank
        sleep 0.6
        restore_state
        ;;
    *) ;;
esac

exit 0
