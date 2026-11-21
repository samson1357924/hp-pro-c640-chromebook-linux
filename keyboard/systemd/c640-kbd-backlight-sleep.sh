#!/bin/sh
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# c640-kbd-backlight-sleep.sh - systemd system-sleep hook for keyboard backlight
# Saves brightness before suspend and restores after resume, complementing the
# user-session daemon that handles screen blank (org.gnome.ScreenSaver).
#
# Save/restore semantics mirror the daemon: the STATE FILE is the sole
# authority to restore, a brightness of 0 is saved as well, and a post restore
# is deferred while the session ScreenSaver is still active (so a blanked
# screen is not lit back up at full brightness - TROUBLESHOOTING.md §11).
# The D-Bus probe is FAIL-OPEN: any error (no bus, no session user, timeout,
# missing tool) is treated as "not active" so suspend/resume never blocks.
# Installed to /usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh
set -eu

SYSFS="${C640_KBD_SLEEP_SYSFS:-/sys/class/leds/chromeos::kbd_backlight/brightness}"
SYSFS_MAX="${SYSFS%/*}/max_brightness"
STATE_DIR="${C640_KBD_SLEEP_STATE_DIR:-/run/c640-kbd-backlight}"
STATE_FILE="$STATE_DIR/state"

# Session-user overrides are for headless systems and the unit tests. When
# unset, the active logind session (or a UID with /run/user/<uid>) is used.
SLEEP_USER="${C640_KBD_SLEEP_USER:-}"
SLEEP_UID="${C640_KBD_SLEEP_UID:-}"
SLEEP_BUS="${C640_KBD_SLEEP_BUS:-}"
POST_DELAY="${C640_KBD_SLEEP_DELAY:-0.6}"

_has_backlight() {
    [ -f "$SYSFS" ] || command -v ectool > /dev/null 2>&1 || [ -x /usr/local/bin/ectool ]
}

# Translate an ectool percentage into the sysfs 0..max scale. Echo "" if the
# tool returned something we cannot trust.
_ectool_pct() {
    _pct="$1"
    case "$_pct" in
        '' | *[!0-9]*)
            echo ""
            ;;
        *)
            _max_pct="$(cat "$SYSFS_MAX" 2> /dev/null || echo 100)"
            case "$_max_pct" in '' | *[!0-9]*) _max_pct=100 ;; esac
            if [ "$_max_pct" -eq 0 ]; then
                _max_pct=100
            fi
            echo $((_pct * _max_pct / 100))
            ;;
    esac
}

# Echo the current brightness (0 is a valid value) or "" when unreadable.
_read_current() {
    if [ -f "$SYSFS" ]; then
        cat "$SYSFS" 2> /dev/null || echo ""
    elif command -v ectool > /dev/null 2>&1; then
        _ectool_pct "$(ectool pwmgetkblight 2> /dev/null | grep -o '[0-9][0-9]*' | head -n1 || echo "")"
    elif [ -x /usr/local/bin/ectool ]; then
        _ectool_pct "$(/usr/local/bin/ectool pwmgetkblight 2> /dev/null | grep -o '[0-9][0-9]*' | head -n1 || echo "")"
    else
        echo ""
    fi
}

save_state() {
    _has_backlight || return 0
    if [ -f "$STATE_FILE" ]; then
        return 0
    fi
    _curr="$(_read_current)"
    case "$_curr" in
        '' | *[!0-9]*)
            return 0
            ;;
    esac
    # Unlike the old hook, 0 is stored too: it is a legitimate saved value
    # (e.g. the screen was already blank when suspend started).
    mkdir -p "$STATE_DIR" 2> /dev/null || true
    chmod 700 "$STATE_DIR" 2> /dev/null || true
    _tmp="$(mktemp "$STATE_DIR/.state.XXXXXX" 2> /dev/null || mktemp "${TMPDIR:-/tmp}/.c640-kbd-sleep-XXXXXX")"
    echo "$_curr" > "$_tmp" 2> /dev/null || true
    chmod 600 "$_tmp" 2> /dev/null || true
    mv -f "$_tmp" "$STATE_FILE" 2> /dev/null || cp "$_tmp" "$STATE_FILE" 2> /dev/null || true
    rm -f "$_tmp" 2> /dev/null || true
}

# Echo "true" only when a session ScreenSaver positively reports active.
# GNOME is queried first, freedesktop is the fallback. Every failure mode
# echoes "false" - the caller then restores as before (fail-open).
_screensaver_active() {
    command -v sudo > /dev/null 2>&1 || {
        echo false
        return 0
    }
    command -v timeout > /dev/null 2>&1 || {
        echo false
        return 0
    }
    command -v gdbus > /dev/null 2>&1 || {
        echo false
        return 0
    }

    _ss_user="$SLEEP_USER"
    if [ -z "$_ss_user" ] && command -v loginctl > /dev/null 2>&1; then
        # `loginctl list-sessions --no-legend` columns are
        #   SESSION UID USER SEAT LEADER CLASS TTY IDLE SINCE [...]
        # The user name is $3 (and the session id is $1); the old
        # `$3 == "active"` test could never match. Prefer a live session
        # (IDLE=yes / an "active" marker) and otherwise take the first real
        # session user. Never treat the UID column ($2) as a user name.
        _ss_user="$(loginctl list-sessions --no-legend 2> /dev/null \
            | awk '
                NF >= 3 && $1 != "SESSION" {
                    if ($8 == "yes" || $6 == "active") { chosen = $3; exit }
                    if (first == "") first = $3
                }
                END { if (chosen != "") print chosen; else if (first != "") print first }
              ' 2> /dev/null || true)"
    fi
    if [ -z "$_ss_user" ]; then
        _ss_user="${SUDO_USER:-}"
    fi
    if [ -z "$_ss_user" ]; then
        for _ss_dir in /run/user/[0-9]*; do
            [ -d "$_ss_dir" ] || continue
            _ss_cand="$(id -nu "${_ss_dir##*/}" 2> /dev/null || echo "")"
            if [ -n "$_ss_cand" ]; then
                _ss_user="$_ss_cand"
                break
            fi
        done
    fi
    [ -n "$_ss_user" ] || {
        echo false
        return 0
    }

    _ss_uid="$SLEEP_UID"
    [ -n "$_ss_uid" ] || _ss_uid="$(id -u "$_ss_user" 2> /dev/null || echo "")"
    [ -n "$_ss_uid" ] || {
        echo false
        return 0
    }

    _ss_bus="$SLEEP_BUS"
    [ -n "$_ss_bus" ] || _ss_bus="/run/user/$_ss_uid/bus"
    # Deliberately no -S test here: a missing socket makes the gdbus call
    # fail, which is already a fail-open "false".

    _ss_out="$(sudo -u "$_ss_user" env \
        XDG_RUNTIME_DIR="/run/user/$_ss_uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$_ss_bus" \
        timeout 2 gdbus call --session \
        --dest org.gnome.ScreenSaver \
        --object-path /org/gnome/ScreenSaver \
        --method org.gnome.ScreenSaver.GetActive 2> /dev/null || true)"
    case "$_ss_out" in *true*)
        echo true
        return 0
        ;;
    esac

    _ss_out="$(sudo -u "$_ss_user" env \
        XDG_RUNTIME_DIR="/run/user/$_ss_uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$_ss_bus" \
        timeout 2 gdbus call --session \
        --dest org.freedesktop.ScreenSaver \
        --object-path /org/freedesktop/ScreenSaver \
        --method org.freedesktop.ScreenSaver.GetActive 2> /dev/null || true)"
    case "$_ss_out" in *true*)
        echo true
        return 0
        ;;
    esac

    echo false
}

restore_state() {
    [ -f "$STATE_FILE" ] || return 0
    _saved="$(cat "$STATE_FILE" 2> /dev/null || echo "")"
    case "$_saved" in
        '' | *[!0-9]*)
            rm -f "$STATE_FILE" 2> /dev/null || true
            return 0
            ;;
    esac

    # ScreenSaver re-check BEFORE writing. Still blank -> keep the state file
    # untouched so the next unblank/daemon restore still knows the old value.
    if [ "$(_screensaver_active)" = "true" ]; then
        return 0
    fi

    _has_backlight || {
        rm -f "$STATE_FILE" 2> /dev/null || true
        return 0
    }

    _max="$(cat "$SYSFS_MAX" 2> /dev/null || echo 100)"
    case "$_max" in '' | *[!0-9]*) _max=100 ;; esac
    if [ "$_max" -eq 0 ]; then
        _max=100
    fi
    if [ "$_saved" -gt "$_max" ]; then
        _saved="$_max"
    fi

    # The state file's existence is the ownership signal. Do NOT skip a
    # non-zero current value here: once we saved, the saved value wins even
    # if the kernel restored a residual brightness during resume. Without a
    # state file nothing is ever written, so manual changes stay untouched.
    rm -f "$STATE_FILE" 2> /dev/null || true
    _wrote=0
    if [ -f "$SYSFS" ]; then
        echo "$_saved" > "$SYSFS" 2> /dev/null || true
        _cur="$(cat "$SYSFS" 2> /dev/null || echo -1)"
        if [ "$_cur" = "$_saved" ]; then
            _wrote=1
        fi
    fi
    if [ "$_wrote" -ne 1 ]; then
        # No sysfs (or the write did not stick): fall back to the EC.
        _pct=$((_saved * 100 / _max))
        if command -v ectool > /dev/null 2>&1; then
            ectool pwmsetkblight "$_pct" > /dev/null 2>&1 || true
        elif [ -x /usr/local/bin/ectool ]; then
            /usr/local/bin/ectool pwmsetkblight "$_pct" > /dev/null 2>&1 || true
        fi
    fi
}

main() {
    case "${1:-}" in
        pre)
            save_state
            # Do not force 0 here: the daemon owns screen blank, and
            # LED_CORE_SUSPENDRESUME keeps the current value during suspend.
            ;;
        post)
            # Delay to avoid racing LED_CORE_SUSPENDRESUME / gsd-power re-blank.
            sleep "$POST_DELAY"
            restore_state
            ;;
    esac
}

# Sourcing with C640_KBD_SLEEP_SOURCE_ONLY=1 is used by the unit test; the
# real system-sleep hook always runs main and exits.
if [ -z "${C640_KBD_SLEEP_SOURCE_ONLY:-}" ]; then
    main "$@"
    exit 0
fi
