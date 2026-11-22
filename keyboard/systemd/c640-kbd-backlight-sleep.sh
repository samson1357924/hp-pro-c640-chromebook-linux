#!/bin/sh
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# c640-kbd-backlight-sleep.sh - systemd system-sleep hook for keyboard backlight
#
# WHY THIS HOOK NO LONGER TOUCHES BRIGHTNESS
# -----------------------------------------
# This hook runs as root from /usr/lib/systemd/system-sleep/. On a real S3
# cycle systemd freezes user.slice BEFORE the "post" phase runs. The old
# `sudo -u <user> gdbus call --session ... GetActive` therefore always fails
# under the frozen slice; the FAIL-OPEN "false" answer made the hook write
# sysfs directly, re-introducing a second writer and defeating the deferred
# restore. systemd emits PrepareForSleep(false) only AFTER thaw, and the user
# daemon already listens for it (monitor_login1), so it is the correct and
# only writer.
#
# NEW CONTRACT (P1 blocker fix)
# -----------------------------
#   pre  - write the root-readable brightness to STATE_FILE as a single-shot
#          diagnostic snapshot of the first suspend in a boot (first-wins),
#          then publish a user-readable "suspend" handoff (the saved value).
#   post - publish a "resume" handoff flag (epoch + action) and return.
# This hook NEVER queries a user/session D-Bus, NEVER writes brightness
# (sysfs/ectool) in post, and NEVER consumes or deletes the root state file.
# The real restore is owned exclusively by the thawed user daemon (Phase 4b).
# No sleep delay: the post phase must not add latency to resume.
#
# HANDOFF CONTRACT (the Phase 4b daemon depends on this)
# -----------------------------------------------------
#   $XDG_RUNTIME_DIR/c640-kbd-backlight.suspend : one decimal integer, 0 valid.
#   $XDG_RUNTIME_DIR/c640-kbd-backlight.resume  : "<epoch> <action>", e.g.
#                                                   "1763800000 suspend".
# Both files are 0600, owned by the resolved session user when placed under
# /run/user/<uid>, and atomically published (mktemp + printf + chmod + chown +
# mv -f) so the daemon can never observe a half-written value. The daemon-side
# paths are $XDG_RUNTIME_DIR/c640-kbd-backlight.{suspend,resume}.
# Both files are written with a trailing "\n"; the daemon must trim it when
# reading the value (e.g. `read` or command substitution already strips it).
# The hook NEVER deletes the handoff files: after a successful restore the
# daemon MUST consume (remove) them, otherwise the next suspend would reuse
# the stale values left behind by this cycle.
#
# Environment overrides:
#   C640_KBD_SLEEP_SYSFS, C640_KBD_SLEEP_STATE_DIR,
#   C640_KBD_SLEEP_SOURCE_ONLY  (kept)
#   C640_KBD_HANDOFF_DIR        full handoff directory override (tests)
#   C640_KBD_RUN_USER_ROOT      runtime root, defaults to /run/user (tests)
# Removed/deprecated and deliberately ignored:
#   C640_KBD_SLEEP_USER, C640_KBD_SLEEP_UID, C640_KBD_SLEEP_BUS,
#   C640_KBD_SLEEP_DELAY  (no D-Bus and no delay in this hook any more)
set -eu

SYSFS="${C640_KBD_SLEEP_SYSFS:-/sys/class/leds/chromeos::kbd_backlight/brightness}"
SYSFS_MAX="${SYSFS%/*}/max_brightness"
STATE_DIR="${C640_KBD_SLEEP_STATE_DIR:-/run/c640-kbd-backlight}"
STATE_FILE="$STATE_DIR/state"

HANDOFF_DIR="${C640_KBD_HANDOFF_DIR:-}"
RUN_USER_ROOT="${C640_KBD_RUN_USER_ROOT:-/run/user}"
HANDOFF_OWNER=""
SUSPEND_HANDOFF="c640-kbd-backlight.suspend"
RESUME_HANDOFF="c640-kbd-backlight.resume"

log_warn() {
    echo "[WARN] [c640-kbd-backlight-sleep] $*" >&2
}

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

# Root-side single-shot diagnostic snapshot of the first suspend in a boot.
# First-wins and never consumed: neither this hook nor the daemon reads it for
# restore. Only the user handoff files and the daemon's own state are consumed.
# A brightness of 0 is stored as well.
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

# Resolve the session user's numeric UID from LOCAL sources only:
#   SUDO_USER -> loginctl list-sessions -> /run/user/<uid>.
# Deliberately NO gdbus, NO session bus, NO sudo -u, NO timeout: the hook runs
# with user.slice frozen, so every user-session probe is guaranteed to fail
# and would only add latency. loginctl is a system service (not frozen).
_session_uid() {
    _uid=""
    if [ -n "${SUDO_USER:-}" ]; then
        _uid="$(id -u "$SUDO_USER" 2> /dev/null || echo "")"
    fi

    if [ -z "$_uid" ] && command -v loginctl > /dev/null 2>&1; then
        # `loginctl list-sessions --no-legend` columns are
        #   SESSION UID USER SEAT LEADER CLASS TTY IDLE SINCE [...]
        # USER is $3 (never the UID column $2, and never a literal "active").
        # Prefer a live session (IDLE=yes / CLASS=active), else the first real
        # session row. Skip the header line.
        _user="$(loginctl list-sessions --no-legend 2> /dev/null \
            | awk '
                NF >= 3 && $1 != "SESSION" {
                    if ($8 == "yes" || $6 == "active") { chosen = $3; exit }
                    if (first == "") first = $3
                }
                END { if (chosen != "") print chosen; else if (first != "") print first }
              ' 2> /dev/null || true)"
        if [ -n "$_user" ]; then
            _uid="$(id -u "$_user" 2> /dev/null || echo "")"
        fi
    fi

    if [ -z "$_uid" ]; then
        for _dir in "$RUN_USER_ROOT"/[0-9]*; do
            [ -d "$_dir" ] || continue
            _cand="${_dir##*/}"
            case "$_cand" in '' | *[!0-9]*) continue ;; esac
            # Verify the uid maps to a real user before adopting it.
            if [ -n "$(id -nu "$_cand" 2> /dev/null || echo "")" ]; then
                _uid="$_cand"
                break
            fi
        done
    fi

    case "$_uid" in '' | *[!0-9]*) _uid="" ;; esac
    printf '%s' "$_uid"
}

# Decide where handoff files go. With an explicit override the directory is
# already owned/writable by the caller (tests), so no chown is attempted.
# Otherwise use /run/user/<resolved uid> and remember the owner for chown.
# An empty result means "skip handoff" - the root state is still saved.
resolve_handoff_dir() {
    if [ -n "$HANDOFF_DIR" ]; then
        HANDOFF_OWNER=""
        return 0
    fi
    _uid="$(_session_uid)"
    if [ -z "$_uid" ]; then
        log_warn "no session uid resolved; suspend/resume handoff skipped"
        HANDOFF_DIR=""
        HANDOFF_OWNER=""
        return 0
    fi
    HANDOFF_DIR="$RUN_USER_ROOT/$_uid"
    HANDOFF_OWNER="$_uid"
}

# Atomically publish one handoff file. All failures are best-effort: warn
# only, never propagate, so suspend/resume never blocks on a handoff write.
_atomic_write() {
    _file="$1"
    _content="$2"
    _uid="${3:-}"
    _dir="${_file%/*}"

    [ -n "$_dir" ] || return 0
    mkdir -p "$_dir" 2> /dev/null || true
    _tmp="$(mktemp "$_dir/.c640-kbd-handoff.XXXXXX" 2> /dev/null \
        || mktemp "${TMPDIR:-/tmp}/.c640-kbd-handoff.XXXXXX" 2> /dev/null || echo "")"
    if [ -z "$_tmp" ]; then
        log_warn "cannot create temporary handoff file for $_file"
        return 0
    fi
    if ! printf '%s\n' "$_content" > "$_tmp" 2> /dev/null; then
        rm -f "$_tmp" 2> /dev/null || true
        log_warn "cannot write handoff content to $_file"
        return 0
    fi
    chmod 600 "$_tmp" 2> /dev/null || true
    if [ -n "$_uid" ]; then
        _gid="$(id -g "$_uid" 2> /dev/null || echo "")"
        if [ -n "$_gid" ]; then
            chown "$_uid:$_gid" "$_tmp" 2> /dev/null || log_warn "cannot chown $_uid:$_gid on $_file"
        fi
    fi
    # One rename publishes the complete file; the daemon never sees a partial
    # line. cp is a last resort for filesystems without atomic rename.
    if ! mv -f "$_tmp" "$_file" 2> /dev/null; then
        cp "$_tmp" "$_file" 2> /dev/null || log_warn "cannot publish $_file"
    fi
    rm -f "$_tmp" 2> /dev/null || true
}

# pre: publish the brightness the daemon must restore after thaw. The value
# is the raw root reading (0 valid), NOT clamped here - clamping belongs to
# the daemon's single-writer set_brightness path.
publish_suspend_handoff() {
    resolve_handoff_dir
    [ -n "$HANDOFF_DIR" ] || return 0
    _curr="$(_read_current)"
    case "$_curr" in
        '' | *[!0-9]*)
            log_warn "unreadable brightness; suspend handoff skipped"
            return 0
            ;;
    esac
    _atomic_write "$HANDOFF_DIR/$SUSPEND_HANDOFF" "$_curr" "$HANDOFF_OWNER"
}

# post: only drop the resume flag. No brightness read/write, no state change,
# no D-Bus. The daemon uses this flag (plus the suspend handoff) after thaw.
write_resume_handoff() {
    _action="${1:-suspend}"
    resolve_handoff_dir
    [ -n "$HANDOFF_DIR" ] || return 0
    _epoch="$(date +%s 2> /dev/null || echo 0)"
    case "$_epoch" in '' | *[!0-9]*) _epoch=0 ;; esac
    _atomic_write "$HANDOFF_DIR/$RESUME_HANDOFF" "$_epoch $_action" "$HANDOFF_OWNER"
}

main() {
    case "${1:-}" in
        pre)
            save_state
            publish_suspend_handoff
            ;;
        post)
            # No sleep, no ScreenSaver probe, no sysfs/ectool write, no state
            # deletion. The thawed user daemon owns the restore (Phase 4b).
            write_resume_handoff "${2:-}"
            ;;
    esac
}

# Sourcing with C640_KBD_SLEEP_SOURCE_ONLY=1 is used by the unit test; the
# real system-sleep hook always runs main and exits.
if [ -z "${C640_KBD_SLEEP_SOURCE_ONLY:-}" ]; then
    main "$@"
    exit 0
fi
