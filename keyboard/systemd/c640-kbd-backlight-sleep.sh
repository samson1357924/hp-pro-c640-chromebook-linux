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
# SESSION SELECTION / SAME-CYCLE CONTRACT (finding #5)
# ---------------------------------------------------
# The handoff owner is NOT chosen by `loginctl list-sessions`' IDLE/CLASS
# columns: IDLE=yes means "idle", not "active", and CLASS is user/greeter/
# background, never "active".  On a host with a local graphical user plus an
# idle SSH session that heuristic picked the SSH user (often nobody, 65534).
# Only loginctl's real properties are authoritative:
#   show-session <id>: Active=yes, Remote=no, Class=user,
#                      Type=wayland|x11, State != closing, numeric UID
#   show-seat <seat> -p ActiveSession: the session must be its seat's active
#                      session (this also resolves the multi-seat case)
# Exactly one such candidate is required; 0 or >1 is FAIL-CLOSED (journal
# WARN, root state still saved, no handoff from pre and no flag from post).
# Greeter/background/tty sessions are never selected.  SUDO_USER is ignored:
# sudo may arrive over SSH and cannot pass the loginctl checks above.
#
# To prevent a pre/post split (different sessions, or a session disappearing
# while user.slice is frozen), `pre` pins the chosen uid in root-only
# $STATE_DIR/session-uid (0600, mktemp+mv).  `post` reads that file, validates
# the uid and its runtime dir, and reuses it without re-selecting.  A missing
# or invalid file fails closed.  The hook never creates, chmods or chowns a
# runtime dir; an absent/insecure /run/user/<uid> is a fail-closed condition.
#
# Environment overrides:
#   C640_KBD_SLEEP_SYSFS, C640_KBD_SLEEP_STATE_DIR,
#   C640_KBD_SLEEP_SOURCE_ONLY  (kept)
#   C640_KBD_HANDOFF_DIR        full handoff directory override (tests);
#                               a caller-supplied path is trusted as-is and
#                               bypasses loginctl/uid pinning by design
#   C640_KBD_RUN_USER_ROOT      runtime root, defaults to /run/user (tests)
# Removed/deprecated and deliberately ignored:
#   C640_KBD_SLEEP_USER, C640_KBD_SLEEP_UID, C640_KBD_SLEEP_BUS,
#   C640_KBD_SLEEP_DELAY  (no D-Bus and no delay in this hook any more)
#   SUDO_USER             (not authoritative; see above)
set -eu

SYSFS="${C640_KBD_SLEEP_SYSFS:-/sys/class/leds/chromeos::kbd_backlight/brightness}"
SYSFS_MAX="${SYSFS%/*}/max_brightness"
STATE_DIR="${C640_KBD_SLEEP_STATE_DIR:-/run/c640-kbd-backlight}"
STATE_FILE="$STATE_DIR/state"

HANDOFF_DIR="${C640_KBD_HANDOFF_DIR:-}"
RUN_USER_ROOT="${C640_KBD_RUN_USER_ROOT:-/run/user}"
HANDOFF_OWNER=""
CYCLE_UID_FILE="$STATE_DIR/session-uid"
SUSPEND_HANDOFF="c640-kbd-backlight.suspend"
RESUME_HANDOFF="c640-kbd-backlight.resume"

log_info() {
    echo "[c640-kbd-backlight-sleep] $*" >&2
}

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

# Extract one Key=Value property from a `loginctl show-*` snapshot.  Values
# may contain '=', so slice from the original line rather than using -F=$N.
_session_prop() {
    printf '%s\n' "$1" | awk -F= -v key="$2" '$1 == key { print substr($0, length($1) + 2); exit }'
}

# A runtime dir is usable only when it ALREADY exists, is a real directory,
# has mode 0700 and is owned by the resolved uid.  Root must never create,
# chmod or chown a user's runtime dir: an absent/insecure dir is fail-closed.
# With no uid (explicit C640_KBD_HANDOFF_DIR override) only existence is
# checked - the caller owns that path and deliberately bypasses loginctl.
_runtime_dir_ok() {
    _rd="$1"
    _ru="${2:-}"
    [ -d "$_rd" ] || return 1
    if [ -n "$_ru" ]; then
        [ ! -L "$_rd" ] || return 1
        _rmode="$(stat -c %a "$_rd" 2> /dev/null || echo '')"
        [ "$_rmode" = 700 ] || return 1
        _rowner="$(stat -c %u "$_rd" 2> /dev/null || echo '')"
        [ "$_rowner" = "$_ru" ] || return 1
    fi
    return 0
}

# Resolve the ONE explicitly active, local, graphical user session from LOCAL
# sources only.  `loginctl list-sessions` supplies session IDs; the real
# properties come from `loginctl show-session <id>` and the seat's own active
# session from `loginctl show-seat <seat> -p ActiveSession`.  Deliberately NO
# gdbus, NO session bus, NO sudo -u: user.slice is frozen, and loginctl is a
# system service.  Prints the single uid, or empty on 0/multiple candidates.
# $1=1 (post verification) suppresses the "selected" info line but still
# emits fail-closed warnings; the caller never re-selects from that result.
_session_uid() {
    _quiet="${1:-0}"
    _uid=""
    # In post this call is VERIFICATION ONLY: post reuses the uid pinned by
    # pre, so a 0/multi-candidate result must not claim "no handoff" (post
    # still writes the resume flag with the pinned uid).
    if [ "$_quiet" = 1 ]; then
        _verdict="verification only; pinned uid still used"
    else
        _verdict="no handoff"
    fi
    if ! command -v loginctl > /dev/null 2>&1; then
        log_warn "session selection fail-closed: loginctl unavailable; $_verdict"
        printf '%s' "$_uid"
        return 0
    fi
    _ids="$(loginctl list-sessions --no-legend 2> /dev/null \
        | awk 'NF >= 1 && $1 != "SESSION" { print $1 }' 2> /dev/null || true)"
    _seen=0
    _candidates=0
    _chosen=""
    _desc=""
    for _id in $_ids; do
        case "$_id" in '' | *[!0-9]*) continue ;; esac
        _seen=$((_seen + 1))
        _props="$(loginctl show-session "$_id" 2> /dev/null || true)"
        _active="$(_session_prop "$_props" Active)"
        _remote="$(_session_prop "$_props" Remote)"
        _class="$(_session_prop "$_props" Class)"
        _type="$(_session_prop "$_props" Type)"
        _state="$(_session_prop "$_props" State)"
        _seat="$(_session_prop "$_props" Seat)"
        _suid="$(_session_prop "$_props" UID)"
        # IDLE=yes / CLASS=active are NOT session activity indicators.  Only
        # these explicit properties describe an active local graphical USER.
        [ "$_active" = yes ] || continue
        [ "$_remote" = no ] || continue
        [ "$_class" = user ] || continue
        case "$_type" in wayland | x11) ;; *) continue ;; esac
        [ -n "$_state" ] || continue
        [ "$_state" != closing ] || continue
        [ -n "$_seat" ] || continue
        case "$_suid" in '' | *[!0-9]*) continue ;; esac
        # A multi-seat host must agree on which session this seat is showing.
        _seat_active="$(loginctl show-seat "$_seat" -p ActiveSession 2> /dev/null \
            | awk -F= '$1 == "ActiveSession" { print substr($0, length($1) + 2); exit }' 2> /dev/null || true)"
        [ "$_seat_active" = "$_id" ] || continue
        # loginctl is the authority; SUDO_USER is ignored (it may be SSH).
        [ -n "$(id -nu "$_suid" 2> /dev/null || echo '')" ] || continue
        _candidates=$((_candidates + 1))
        if [ "$_candidates" -eq 1 ]; then
            _chosen="$_suid"
            _desc="session $_id on seat $_seat"
        else
            _desc="$_desc, session $_id on seat $_seat"
        fi
    done
    if [ "$_candidates" -ne 1 ]; then
        if [ "$_candidates" -eq 0 ]; then
            _reason="no active local graphical user session"
        else
            _reason="$_candidates candidates ($_desc)"
        fi
        log_warn "session selection fail-closed: $_reason (examined $_seen session(s)); $_verdict"
        printf '%s' ""
        return 0
    fi
    if [ "$_quiet" != 1 ]; then
        log_info "selected $_desc for uid $_chosen"
    fi
    printf '%s' "$_chosen"
}

# Pin the chosen uid for this suspend cycle (root-only, atomic).
_write_cycle_uid() {
    _wuid="$1"
    mkdir -p "$STATE_DIR" 2> /dev/null || true
    chmod 700 "$STATE_DIR" 2> /dev/null || true
    _tmp="$(mktemp "$STATE_DIR/.session-uid.XXXXXX" 2> /dev/null \
        || mktemp "${TMPDIR:-/tmp}/.c640-kbd-session-uid.XXXXXX" 2> /dev/null || echo '')"
    if [ -z "$_tmp" ]; then
        log_warn "cannot create temporary cycle uid file"
        return 1
    fi
    if ! printf '%s\n' "$_wuid" > "$_tmp" 2> /dev/null; then
        rm -f "$_tmp" 2> /dev/null || true
        log_warn "cannot write cycle uid $_wuid"
        return 1
    fi
    chmod 600 "$_tmp" 2> /dev/null || true
    if ! mv -f "$_tmp" "$CYCLE_UID_FILE" 2> /dev/null; then
        cp "$_tmp" "$CYCLE_UID_FILE" 2> /dev/null || {
            rm -f "$_tmp" 2> /dev/null || true
            log_warn "cannot publish cycle uid $_wuid"
            return 1
        }
    fi
    rm -f "$_tmp" 2> /dev/null || true
    chmod 600 "$CYCLE_UID_FILE" 2> /dev/null || true
    return 0
}

# Read and validate the uid pinned by pre.  Never fall back to re-selecting.
_read_cycle_uid() {
    if [ ! -f "$CYCLE_UID_FILE" ]; then
        log_warn "resume handoff skipped (fail-closed): no cycle uid file $CYCLE_UID_FILE"
        return 1
    fi
    _umode="$(stat -c %a "$CYCLE_UID_FILE" 2> /dev/null || echo '')"
    if [ "$_umode" != 600 ]; then
        log_warn "resume handoff skipped (fail-closed): $CYCLE_UID_FILE is not 0600"
        return 1
    fi
    _puid="$(cat "$CYCLE_UID_FILE" 2> /dev/null || echo '')"
    case "$_puid" in '' | *[!0-9]*)
        log_warn "resume handoff skipped (fail-closed): invalid cycle uid '$_puid'"
        return 1
        ;;
    esac
    if [ -z "$(id -nu "$_puid" 2> /dev/null || echo '')" ]; then
        log_warn "resume handoff skipped (fail-closed): unknown cycle uid $_puid"
        return 1
    fi
    _pdir="$RUN_USER_ROOT/$_puid"
    if ! _runtime_dir_ok "$_pdir" "$_puid"; then
        log_warn "resume handoff skipped (fail-closed): runtime dir $_pdir missing/insecure for uid $_puid"
        return 1
    fi
    printf '%s' "$_puid"
}

# Decide where handoff files go.  With an explicit override the caller owns
# the directory, so neither loginctl nor uid pinning is consulted.  Otherwise
# pre selects+pins a single uid and post reuses the pinned uid (verification
# only: a changed loginctl answer is warned about, never followed).  An empty
# result means "skip handoff" - the root state is still saved.
resolve_handoff_dir() {
    _phase="${1:-pre}"
    if [ -n "$HANDOFF_DIR" ]; then
        HANDOFF_OWNER=""
        return 0
    fi
    if [ "$_phase" = post ]; then
        if ! _uid="$(_read_cycle_uid)"; then
            HANDOFF_DIR=""
            HANDOFF_OWNER=""
            return 0
        fi
        _now="$(_session_uid 1)"
        if [ "$_now" != "$_uid" ]; then
            log_warn "session changed since pre (now '$_now', pinned '$_uid'); keeping pre's uid (fail-closed against pre/post split)"
        fi
    else
        # A new cycle must not inherit the previous cycle's uid: clear it
        # first so a failed selection cannot be "rescued" by a stale file.
        rm -f "$CYCLE_UID_FILE" 2> /dev/null || true
        _uid="$(_session_uid)"
        if [ -z "$_uid" ]; then
            log_warn "suspend handoff skipped (fail-closed): no unambiguous local graphical session"
            HANDOFF_DIR=""
            HANDOFF_OWNER=""
            return 0
        fi
        _dir="$RUN_USER_ROOT/$_uid"
        if ! _runtime_dir_ok "$_dir" "$_uid"; then
            log_warn "suspend handoff skipped (fail-closed): runtime dir $_dir missing/insecure for uid $_uid"
            HANDOFF_DIR=""
            HANDOFF_OWNER=""
            return 0
        fi
        if ! _write_cycle_uid "$_uid"; then
            log_warn "suspend handoff skipped (fail-closed): cannot pin cycle uid $_uid"
            HANDOFF_DIR=""
            HANDOFF_OWNER=""
            return 0
        fi
    fi
    HANDOFF_DIR="$RUN_USER_ROOT/$_uid"
    HANDOFF_OWNER="$_uid"
    log_info "$_phase handoff dir $HANDOFF_DIR for uid $_uid"
}

# Atomically publish one handoff file. All failures are best-effort: warn
# only, never propagate, so suspend/resume never blocks on a handoff write.
# The runtime dir must already exist with the right owner/mode; never create
# a root-owned 0755 stand-in for a user's /run/user/<uid> (finding #5).
_atomic_write() {
    _file="$1"
    _content="$2"
    _uid="${3:-}"
    _dir="${_file%/*}"

    [ -n "$_dir" ] || return 0
    if ! _runtime_dir_ok "$_dir" "$_uid"; then
        log_warn "handoff skipped (fail-closed): $_dir missing/insecure for uid '${_uid:-<override>}'"
        return 0
    fi
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
    resolve_handoff_dir pre
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
    resolve_handoff_dir post
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
