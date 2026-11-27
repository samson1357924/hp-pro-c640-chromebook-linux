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
#   $XDG_RUNTIME_DIR/c640-kbd-backlight.suspend : "<token> <value> published"
#                                                   e.g. "1763800123-4217-9f3ac1d0e2b4 7 published"
#   $XDG_RUNTIME_DIR/c640-kbd-backlight.resume  : "<token> <epoch> <action> <committed_value>", e.g.
#                                                   "1763800123-4217-9f3ac1d0e2b4 1763800300 suspend 7"
#   $STATE_DIR/cycle (ROOT-ONLY 0600)          : "<token> <dev:ino> <value>"
#                                                   e.g. "1763800123-4217-9f3ac1d0e2b4 27:1048944 7"
# The token is <epoch>-<pid>-<random_hex>, minted fresh by pre for EVERY cycle.
# It binds the two user handoffs to one another and to the exact published
# suspend inode: post refuses to publish a resume flag unless the root commit
# marker exists, is 0600, carries the same token, dev:ino AND committed value
# as the suspend file, and the suspend file still says "published".  A legacy
# two-column marker is refused (fail closed).  post verifies the suspend bytes
# through ONE pinned directory fd + O_NOFOLLOW opened descriptor (fstat plus a
# byte-exact read from that same fd), so a same-inode value rewrite or an
# inode swap with identical text cannot smuggle a different value through.
# The root marker is the LAST step of a successful pre; a failed pre leaves no
# marker, so a stale handoff from a previous cycle can never be adopted after
# this resume.  The committed value is carried in the resume flag so the daemon
# can treat it as authoritative even if the suspend copy is later tampered.
# The `<epoch>` in the resume flag is the POST time (not the token's pre epoch);
# the daemon validates both independently.
# Both handoff files are 0600, owned by the resolved session user (uid AND gid) when
# placed under /run/user/<uid>.  Publication is performed by one inline
# python3 helper using a pinned directory fd: O_DIRECTORY|O_NOFOLLOW on the
# directory, O_CREAT|O_EXCL|O_NOFOLLOW for a same-directory temp, fchmod(0600),
# fchown(uid,gid), fstat verification, directory-identity recheck, then
# rename(src,dst,src_dir_fd=,dst_dir_fd=) - the fd-pinned equivalent of
# `mv -T -f --` (the final path component is never followed as a symlink nor
# treated as a directory container).  The helper re-verifies inode/owner/mode
# after the rename and prints `OK dev:ino` on stdout; that record is the
# published identity consumed by later phases.  Callers capture it (e.g. into
# PUBLISHED_IDENTITY) for binding but MUST printf it back to stdout so the
# published inode remains observable to tests; pre therefore emits two OK
# records (suspend, then root cycle marker) and post emits one (resume).
# The suspend verifier NEVER prints an `OK ` record: its verdict is a separate
# internal channel, so the stdout contract above stays exactly 2/2/1.
# There is deliberately NO cp
# fallback and NO /tmp mktemp fallback: a failed publish fails closed instead
# of escaping the boundary, and cleanup only unlinks a temp that still has the
# original inode.  python3 is therefore a runtime dependency of pre/post; if
# it is unavailable, or any publish step fails, the hook warns and does not
# publish (hook process still exits 0 so resume is never blocked).
# The daemon-side paths are $XDG_RUNTIME_DIR/c640-kbd-backlight.{suspend,resume}.
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
#                      Type=wayland|x11, State != closing, numeric Session.User
#   show-seat <seat> -p ActiveSession: the session must be its seat's active
#                      session (this also resolves the multi-seat case)
# The uid comes from the Session object's User property, which is of type
# (uo) and is printed by loginctl as `User=<numeric uid>` (NOT `UID=`;
# UID= belongs to the User object / logind's private state file and must not
# be parsed here).  Session IDs are strings, not just decimal numbers:
# systemd's session_id_valid() accepts [A-Za-z0-9]+, so IDs such as `c1` are
# legal; only empty/special-character values and the `self`/`auto` aliases are
# skipped before calling show-session.
# Exactly one such candidate is required; 0 or >1 is FAIL-CLOSED (journal
# WARN, root state still saved, no handoff from pre and no flag from post).
# Greeter/background/tty sessions are never selected.  SUDO_USER is ignored:
# sudo may arrive over SSH and cannot pass the loginctl checks above.
#
# To prevent a pre/post split (different sessions, or a session disappearing
# while user.slice is frozen), `pre` pins the chosen uid in root-only
# $STATE_DIR/session-uid (0600, mktemp + `mv -T -f --`, no cp fallback).
# Before anything else, pre also invalidates the PREVIOUS cycle: it removes
# the old user handoffs (both the pinned uid's runtime dir and an explicit
# override dir) and the old root cycle marker, then verifies all of them are
# absent.  The new root commit marker is written LAST, only after the suspend
# handoff has been published successfully.  This hook never touches the
# daemon's retry-epoch / restore-gen / adopted-cycle / cycle-begin files.
# `post` reads that file, validates
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
HANDOFF_GID=""
CYCLE_UID_FILE="$STATE_DIR/session-uid"
# Root-only commit marker for the current cycle: "<token> <dev:ino> <value>".  It is
# published by pre with the hook process' own uid/gid (0:0 in production),
# which makes $STATE_DIR (0700, owner 0) a natural root-only boundary.
CYCLE_FILE="$STATE_DIR/cycle"
SUSPEND_HANDOFF="c640-kbd-backlight.suspend"
RESUME_HANDOFF="c640-kbd-backlight.resume"
# Literal newline for POSIX-sh trimming (dash has no $'\n').
_NL='
'

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
    _tmp="$(mktemp "$STATE_DIR/.state.XXXXXX" 2> /dev/null || echo '')"
    if [ -z "$_tmp" ]; then
        log_warn "cannot create temporary root state file"
        return 0
    fi
    echo "$_curr" > "$_tmp" 2> /dev/null || true
    chmod 600 "$_tmp" 2> /dev/null || true
    # Publish only when the final path component is absent or a regular file.
    # -T prevents mv from following a symlink or using a directory as a
    # container; there is no cp fallback that could dereference a symlink.
    if [ -L "$STATE_FILE" ] || [ -d "$STATE_FILE" ] \
        || { [ -e "$STATE_FILE" ] && [ ! -f "$STATE_FILE" ]; }; then
        rm -f "$_tmp" 2> /dev/null || true
        log_warn "root state skipped (fail-closed): unsafe destination entry $STATE_FILE"
        return 0
    fi
    if ! mv -T -f -- "$_tmp" "$STATE_FILE" 2> /dev/null; then
        rm -f "$_tmp" 2> /dev/null || true
        log_warn "cannot publish root state $STATE_FILE"
        return 0
    fi
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
        # Session IDs are ALPHANUMERIC strings (systemd session_id_valid()),
        # not decimal-only: c1 and similar are legal.  Reject empty values,
        # anything outside [A-Za-z0-9] (also prevents glob expansion) and the
        # reserved self/auto aliases before any loginctl call.
        case "$_id" in '' | *[!A-Za-z0-9]* | self | auto) continue ;; esac
        _seen=$((_seen + 1))
        _props="$(loginctl show-session "$_id" 2> /dev/null || true)"
        _active="$(_session_prop "$_props" Active)"
        _remote="$(_session_prop "$_props" Remote)"
        _class="$(_session_prop "$_props" Class)"
        _type="$(_session_prop "$_props" Type)"
        _state="$(_session_prop "$_props" State)"
        _seat="$(_session_prop "$_props" Seat)"
        # Session.User is typed (uo); loginctl show-session prints the numeric
        # uid as `User=<uid>`.  `UID=` is a User-object property (and logind's
        # private state file), not a session property: it is NOT parseable
        # here and was the cause of the original no-handoff blocker.
        _suid="$(_session_prop "$_props" User)"
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
    _tmp="$(mktemp "$STATE_DIR/.session-uid.XXXXXX" 2> /dev/null || echo '')"
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
    if [ -L "$CYCLE_UID_FILE" ] || [ -d "$CYCLE_UID_FILE" ] \
        || { [ -e "$CYCLE_UID_FILE" ] && [ ! -f "$CYCLE_UID_FILE" ]; }; then
        rm -f "$_tmp" 2> /dev/null || true
        log_warn "cycle uid skipped (fail-closed): unsafe destination entry $CYCLE_UID_FILE"
        return 1
    fi
    if ! mv -T -f -- "$_tmp" "$CYCLE_UID_FILE" 2> /dev/null; then
        rm -f "$_tmp" 2> /dev/null || true
        log_warn "cannot publish cycle uid $_wuid"
        return 1
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
        HANDOFF_GID=""
        return 0
    fi
    if [ "$_phase" = post ]; then
        if ! _uid="$(_read_cycle_uid)"; then
            HANDOFF_DIR=""
            HANDOFF_OWNER=""
            HANDOFF_GID=""
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
            HANDOFF_GID=""
            return 0
        fi
        _dir="$RUN_USER_ROOT/$_uid"
        if ! _runtime_dir_ok "$_dir" "$_uid"; then
            log_warn "suspend handoff skipped (fail-closed): runtime dir $_dir missing/insecure for uid $_uid"
            HANDOFF_DIR=""
            HANDOFF_OWNER=""
            HANDOFF_GID=""
            return 0
        fi
        if ! _write_cycle_uid "$_uid"; then
            log_warn "suspend handoff skipped (fail-closed): cannot pin cycle uid $_uid"
            HANDOFF_DIR=""
            HANDOFF_OWNER=""
            HANDOFF_GID=""
            return 0
        fi
    fi
    # gid is now part of the publish contract: the fd helper fchowns the
    # handoff to the resolved uid:gid and verifies it via fstat.  An
    # unresolvable gid must fail closed here, before any temp is created.
    _gid="$(id -g "$_uid" 2> /dev/null || echo '')"
    case "$_gid" in
        '' | *[!0-9]*)
            log_warn "$_phase handoff skipped (fail-closed): cannot resolve gid for uid $_uid"
            HANDOFF_DIR=""
            HANDOFF_OWNER=""
            HANDOFF_GID=""
            return 0
            ;;
    esac
    HANDOFF_DIR="$RUN_USER_ROOT/$_uid"
    HANDOFF_OWNER="$_uid"
    HANDOFF_GID="$_gid"
    log_info "$_phase handoff dir $HANDOFF_DIR for uid $_uid"
}

# Atomically publish one handoff file through a PINNED directory fd (finding
# #4, P2).  Every privileged step in the old _atomic_write re-resolved an
# attacker-controlled pathname (printf/chmod/chown/mv after mktemp) and every
# failure only warned with rc 0.  Here one inline python3 helper owns the
# whole sequence:
#   - open(dir, O_RDONLY|O_DIRECTORY|O_NOFOLLOW) + fstat: uid/mode 0700 check
#     for the real /run/user/<uid>; an explicit test override is trusted;
#   - lstat the destination through dir_fd: absent or regular only;
#   - open(temp, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0600, dir_fd=dfd) then
#     write/fchmod/fchown/fstat - no pathname is re-resolved for these ops;
#   - re-check the pinned dir identity, the destination entry and the TEMP
#     inode (a swapped temp is never renamed);
#   - rename(src,dst,src_dir_fd=dfd,dst_dir_fd=dfd): the fd-based equivalent
#     of `mv -T -f --` (never follows the final symlink, never treats a
#     directory as a container), with no cp and no /tmp fallback;
#   - re-stat the published entry via dir_fd and compare inode/owner/mode;
#   - on success print `OK dev:ino` on stdout (the published identity that
#     later phases consume); on any failure warn, return nonzero, and only
#     unlink a temp that STILL has the original inode.
# python3 is a new pre/post runtime dependency; a missing interpreter is
# fail-closed too.  Callers must check the rc; main() downgrades the WARN so
# the hook itself still exits 0 and never blocks resume.
_publish_handoff() {
    _file="$1"
    _content="$2"
    _uid="${3:-}"
    _gid="${4:-}"
    _dir="${_file%/*}"
    _name="${_file##*/}"

    [ -n "$_dir" ] && [ -n "$_name" ] || return 1
    if ! _runtime_dir_ok "$_dir" "$_uid"; then
        log_warn "handoff skipped (fail-closed): $_dir missing/insecure for uid '${_uid:-<override>}'"
        return 1
    fi
    if ! command -v python3 > /dev/null 2>&1; then
        log_warn "handoff skipped (fail-closed): python3 unavailable; cannot publish $_file"
        return 1
    fi
    if [ -n "$_uid" ]; then
        case "$_gid" in
            '' | *[!0-9]*)
                log_warn "handoff skipped (fail-closed): no numeric gid for uid $_uid"
                return 1
                ;;
        esac
    fi
    if ! _out="$(python3 -c '
import os, stat, sys

dirpath, name, content, uid_s, gid_s = sys.argv[1:6]
uid = int(uid_s) if uid_s else None
gid = int(gid_s) if gid_s else None
failpoint = os.environ.get("C640_KBD_PUBLISH_TEST_FAILPOINT", "")
outside = os.environ.get("C640_KBD_PUBLISH_TEST_OUTSIDE", "/dev/null")
# The old printf writer always terminated handoff content with a trailing
# newline (the daemon strips it on read); keep that wire format opaque here.
data = (content + "\n").encode("utf-8")
dfd = tfd = None
tname = tst = None
published = False

def identity(st):
    return (st.st_dev, st.st_ino, stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid)

def inode(st):
    return (st.st_dev, st.st_ino)

# Test-only stat wrapper: report a different owner (uid AND gid) while keeping
# the real dev/ino/mode/size.  Used to simulate a root-created temp (uid/gid 0)
# in an unprivileged test process, and to tamper with the post-publish owner
# check.  Faking both fields is load-bearing: verification must read the final
# fstat owner, not a faked pre-chown stat.
def fake_owner(st, uid, gid):
    class _St(object):
        def __init__(self, src, fake_uid, fake_gid):
            self._src = src
            self._fake_uid = fake_uid
            self._fake_gid = fake_gid

        def __getattr__(self, name):
            if name == "st_uid":
                return self._fake_uid
            if name == "st_gid":
                return self._fake_gid
            return getattr(self._src, name)

    return _St(st, uid, gid)


# The injection must sit at the syscall boundary, not on a line before it:
# a mutation that deletes the fchmod/fchown call must become observable.
marker_dir = os.environ.get("C640_KBD_PUBLISH_TEST_MARKER_DIR", "")


def mark_syscall(name):
    if not marker_dir:
        return
    try:
        with open(os.path.join(marker_dir, name), "a") as handle:
            handle.write("called\n")
    except OSError:
        pass


real_fchmod = os.fchmod
real_fchown = os.fchown


def traced_fchmod(fd, mode):
    if failpoint == "mode":
        mark_syscall("fchmod")
        raise RuntimeError("injected fchmod failure")
    return real_fchmod(fd, mode)


def traced_fchown(fd, uid, gid):
    if failpoint == "ownership":
        mark_syscall("fchown")
        raise RuntimeError("injected fchown failure")
    return real_fchown(fd, uid, gid)


if failpoint == "mode":
    os.fchmod = traced_fchmod
elif failpoint == "ownership":
    os.fchown = traced_fchown


def unlink_if_ours(path, st):
    if st is None or path is None:
        return
    try:
        cur = os.stat(path, dir_fd=dfd, follow_symlinks=False)
        if inode(cur) == inode(st):
            os.unlink(path, dir_fd=dfd)
    except OSError:
        pass

try:
    dfd = os.open(dirpath, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    dirst = os.fstat(dfd)
    if not stat.S_ISDIR(dirst.st_mode):
        raise RuntimeError("handoff path is not a directory")
    if uid is not None and (
        dirst.st_uid != uid or stat.S_IMODE(dirst.st_mode) != 0o700
    ):
        raise RuntimeError("handoff dir owner/mode mismatch")
    try:
        dent = os.stat(name, dir_fd=dfd, follow_symlinks=False)
    except FileNotFoundError:
        dent = None
    if dent is not None and not stat.S_ISREG(dent.st_mode):
        raise RuntimeError("unsafe destination entry")
    tname = ".c640-kbd-handoff.%d.%s" % (os.getpid(), os.urandom(6).hex())
    tfd = os.open(
        tname,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=dfd,
    )
    written = 0
    while written < len(data):
        written += os.write(tfd, data[written:])
    # tst is ONLY the original (dev, ino): inode-bound cleanup and the
    # post-publish identity check must not trust its pre-fchown owner/mode.
    tst = os.fstat(tfd)
    if failpoint == "root-creator":
        tst = fake_owner(tst, 0, 0)
    os.fchmod(tfd, 0o600)
    if uid is not None:
        os.fchown(tfd, uid, gid)
    # Verify the FINAL state after both privileged operations.  The old
    # pre-chown stat made a real root-created temp fail "owner mismatch".
    vst = os.fstat(tfd)
    if not stat.S_ISREG(vst.st_mode):
        raise RuntimeError("temp is not a regular file")
    if stat.S_IMODE(vst.st_mode) != 0o600:
        raise RuntimeError("temp mode is not 0600")
    if vst.st_size != len(data):
        raise RuntimeError("temp size mismatch")
    if uid is not None and (vst.st_uid != uid or vst.st_gid != gid):
        raise RuntimeError("temp owner mismatch")
    if identity(os.fstat(dfd)) != identity(dirst):
        raise RuntimeError("handoff dir identity changed")
    try:
        dent = os.stat(name, dir_fd=dfd, follow_symlinks=False)
    except FileNotFoundError:
        dent = None
    if dent is not None and not stat.S_ISREG(dent.st_mode):
        raise RuntimeError("destination entry changed during write")
    if failpoint == "dir-swap":
        os.rename(dirpath, dirpath + ".swapped")
        os.mkdir(dirpath, 0o700)
    if failpoint == "temp-symlink":
        os.unlink(tname, dir_fd=dfd)
        os.symlink(outside, tname, dir_fd=dfd)
    elif failpoint == "temp-regular":
        os.unlink(tname, dir_fd=dfd)
        ffd = os.open(
            tname,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=dfd,
        )
        os.write(ffd, b"FOREIGN")
        os.close(ffd)
    now = os.stat(tname, dir_fd=dfd, follow_symlinks=False)
    if inode(now) != inode(tst):
        raise RuntimeError("temp identity changed before rename")
    if failpoint == "rename":
        raise RuntimeError("injected rename failure")
    os.rename(tname, name, src_dir_fd=dfd, dst_dir_fd=dfd)
    published = True
    # Test-only: swap the published entry AFTER rename but BEFORE the
    # post-publish verification, proving that verification is load-bearing.
    if failpoint == "post-swap":
        os.unlink(name, dir_fd=dfd)
        sfd = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=dfd,
        )
        os.write(sfd, b"FOREIGN")
        os.close(sfd)
    pst = None
    if failpoint == "post-mode":
        # Same inode, wrong mode: only the post-publish verification can see it.
        pfd = os.open(name, os.O_WRONLY | os.O_NOFOLLOW, dir_fd=dfd)
        os.fchmod(pfd, 0o644)
        os.close(pfd)
    elif failpoint == "post-owner":
        # Same inode, wrong owner (unprivileged tests cannot really chown away).
        pfd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
        pst = fake_owner(os.fstat(pfd), 0, 0)
        os.close(pfd)
    if pst is None:
        pst = os.stat(name, dir_fd=dfd, follow_symlinks=False)
    if inode(pst) != inode(tst):
        raise RuntimeError("published identity mismatch")
    if (
        not stat.S_ISREG(pst.st_mode)
        or stat.S_IMODE(pst.st_mode) != 0o600
        or pst.st_size != len(data)
    ):
        raise RuntimeError("published mode/size mismatch")
    if uid is not None and (pst.st_uid != uid or pst.st_gid != gid):
        raise RuntimeError("published owner mismatch")
    try:
        os.stat(tname, dir_fd=dfd, follow_symlinks=False)
        raise RuntimeError("temp path survived rename")
    except FileNotFoundError:
        pass
    if failpoint == "post-dir-mode":
        os.fchmod(dfd, 0o755)
    if identity(os.fstat(dfd)) != identity(dirst):
        raise RuntimeError("handoff dir identity changed after rename")
    sys.stdout.write("OK %d:%d\n" % inode(tst))
except Exception as exc:
    unlink_if_ours(tname, tst)
    if published:
        unlink_if_ours(name, tst)
    sys.stderr.write("publish failed: %s\n" % exc)
    sys.exit(1)
finally:
    if tfd is not None:
        os.close(tfd)
    if dfd is not None:
        os.close(dfd)
' "$_dir" "$_name" "$_content" "$_uid" "$_gid" 2>&1)"; then
        log_warn "cannot publish $_file: $_out"
        return 1
    fi
    _lines="$(printf '%s\n' "$_out" | wc -l)"
    if [ "$_lines" -ne 1 ] \
        || ! printf '%s\n' "$_out" | grep -Eq '^OK [0-9]+:[0-9]+$'; then
        log_warn "cannot publish $_file: invalid publish record '$_out'"
        return 1
    fi
    printf '%s\n' "$_out"
    return 0
}

# --- Per-cycle handoff identity (finding #2) -------------------------------
# A token is <epoch>-<pid>-<random_hex>.  grep -E is used because this hook is
# /bin/sh; the daemon has its own matching bash regex.
_CYCLE_TOKEN_RE='^[0-9]+-[0-9]+-[0-9a-f]{6,12}$'

_new_cycle_token() {
    _te="$(date +%s 2> /dev/null || echo '')"
    case "$_te" in '' | *[!0-9]*) return 1 ;; esac
    _tr="$(od -An -N6 -tx1 /dev/urandom 2> /dev/null | tr -d ' \n' | cut -c1-12)"
    case "$_tr" in
        '' | *[!0-9a-f]*)
            # Best-effort fallback; still fail closed if it cannot produce a
            # valid 6..12 digit lowercase hex string.
            _tr="$(awk -v seed="$_te.$$" 'BEGIN { srand(seed); printf "%06x", int(rand() * 16777215) }' 2> /dev/null || echo '')"
            ;;
    esac
    case "$_tr" in '' | *[!0-9a-f]*) return 1 ;; esac
    if [ "${#_tr}" -lt 6 ] || [ "${#_tr}" -gt 12 ]; then
        return 1
    fi
    printf '%s-%s-%s\n' "$_te" "$$" "$_tr"
}

# Invalidate EVERY artifact of the previous cycle before minting a new token.
# Only hook-owned files are touched: the pinned uid's user handoffs, an
# explicit override dir's handoffs and the root commit marker.  The daemon's
# retry-epoch / restore-gen / adopted-cycle / cycle-begin files are never
# touched here (Phase D's coordination tokens are not ours to truncate).
_invalidate_previous_cycle() {
    _irc=0
    _old="$(cat "$CYCLE_UID_FILE" 2> /dev/null || echo '')"
    _old="${_old%$_NL}"
    case "$_old" in
        '' | *[!0-9]*) : ;;
        *)
            _old_dir="$RUN_USER_ROOT/$_old"
            for _f in "$_old_dir/$SUSPEND_HANDOFF" "$_old_dir/$RESUME_HANDOFF"; do
                if [ -L "$_f" ] || [ -d "$_f" ] \
                    || { [ -e "$_f" ] && [ ! -f "$_f" ]; }; then
                    log_warn "previous cycle handoff skipped (fail-closed): unsafe destination entry $_f"
                    _irc=1
                    continue
                fi
                rm -f "$_f" 2> /dev/null || _irc=1
                if [ -e "$_f" ] || [ -L "$_f" ]; then
                    log_warn "previous cycle handoff could not be invalidated: $_f"
                    _irc=1
                fi
            done
            ;;
    esac
    if [ -n "$HANDOFF_DIR" ]; then
        for _f in "$HANDOFF_DIR/$SUSPEND_HANDOFF" "$HANDOFF_DIR/$RESUME_HANDOFF"; do
            if [ -L "$_f" ] || [ -d "$_f" ] \
                || { [ -e "$_f" ] && [ ! -f "$_f" ]; }; then
                log_warn "previous cycle handoff skipped (fail-closed): unsafe destination entry $_f"
                _irc=1
                continue
            fi
            rm -f "$_f" 2> /dev/null || _irc=1
            if [ -e "$_f" ] || [ -L "$_f" ]; then
                log_warn "previous cycle handoff could not be invalidated: $_f"
                _irc=1
            fi
        done
    fi
    if [ -L "$CYCLE_FILE" ] || [ -d "$CYCLE_FILE" ] \
        || { [ -e "$CYCLE_FILE" ] && [ ! -f "$CYCLE_FILE" ]; }; then
        log_warn "previous cycle commit marker skipped (fail-closed): unsafe destination entry $CYCLE_FILE"
        _irc=1
    else
        rm -f "$CYCLE_FILE" 2> /dev/null || _irc=1
        if [ -e "$CYCLE_FILE" ] || [ -L "$CYCLE_FILE" ]; then
            log_warn "previous cycle commit marker could not be invalidated: $CYCLE_FILE"
            _irc=1
        fi
    fi
    if [ "$_irc" -ne 0 ]; then
        log_warn "previous cycle invalidation failed; no new handoff will be published"
        return 1
    fi
    return 0
}

# Read the root-only commit marker produced by the LAST successful pre.
# Sets CYCLE_TOKEN / CYCLE_IDENTITY / CYCLE_VALUE.  A legacy two-column marker
# is deliberately refused: without a committed value there is nothing to bind
# the suspend payload to.  0644, symlinks, directories, extra newlines,
# missing/extra columns and out-of-range values are all refused.
_read_cycle_commit() {
    CYCLE_TOKEN=""
    CYCLE_IDENTITY=""
    CYCLE_VALUE=""
    if [ ! -f "$CYCLE_FILE" ] || [ -L "$CYCLE_FILE" ]; then
        log_warn "resume handoff skipped (fail-closed): missing/unsafe cycle marker $CYCLE_FILE"
        return 1
    fi
    _cmode="$(stat -c %a "$CYCLE_FILE" 2> /dev/null || echo '')"
    if [ "$_cmode" != 600 ]; then
        log_warn "resume handoff skipped (fail-closed): $CYCLE_FILE is not 0600"
        return 1
    fi
    _c="$(cat "$CYCLE_FILE" 2> /dev/null || echo '')"
    _c="${_c%$_NL}"
    case "$_c" in *"$_NL"*)
        log_warn "resume handoff skipped (fail-closed): cycle marker has extra lines"
        return 1
        ;;
    esac
    case "$_c" in *' '*) : ;; *)
        log_warn "resume handoff skipped (fail-closed): invalid cycle marker '$_c'"
        return 1
        ;;
    esac
    CYCLE_TOKEN="${_c%% *}"
    _crest="${_c#* }"
    case "$_crest" in *' '*) : ;; *)
        log_warn "resume handoff skipped (fail-closed): invalid cycle marker '$_c'"
        return 1
        ;;
    esac
    CYCLE_IDENTITY="${_crest%% *}"
    CYCLE_VALUE="${_crest#* }"
    if [ "$_c" != "$CYCLE_TOKEN $CYCLE_IDENTITY $CYCLE_VALUE" ] \
        || ! printf '%s\n' "$CYCLE_TOKEN" | grep -Eq "$_CYCLE_TOKEN_RE" \
        || ! printf '%s\n' "$CYCLE_IDENTITY" | grep -Eq '^[0-9]+:[0-9]+$' \
        || ! printf '%s\n' "$CYCLE_VALUE" | grep -Eq '^[0-9]{1,10}$'; then
        log_warn "resume handoff skipped (fail-closed): invalid cycle marker '$_c'"
        CYCLE_TOKEN=""
        CYCLE_IDENTITY=""
        CYCLE_VALUE=""
        return 1
    fi
    return 0
}

# Verify the suspend handoff against the root marker through ONE opened
# descriptor.  The directory is pinned with O_DIRECTORY|O_NOFOLLOW and the
# file is opened with O_NOFOLLOW via dir_fd; fstat supplies the incarnation
# identity and EVERY byte is read from that SAME fd before the byte-exact
# comparison with "<token> <value> published\n".  No pathname is re-resolved
# after the open, so swapping the directory entry mid-verification cannot
# change the verdict.  Stdout is either "VALUE <value>" (success) or
# "FAIL <TOKEN|VALUE|INODE|STRUCT|IO> <detail>" (failure); it deliberately
# never prints an `OK ` record, preserving the publisher stdout contract.
_verify_suspend_fd() {
    _vdir="$1"
    _vname="$2"
    _vtoken="$3"
    _vident="$4"
    _vvalue="$5"

    [ -n "$_vdir" ] && [ -n "$_vname" ] || return 1
    if ! command -v python3 > /dev/null 2>&1; then
        log_warn "resume handoff skipped (fail-closed): python3 unavailable; cannot verify suspend handoff"
        return 1
    fi
    # The verifier's test-only knobs are inert unless a test mode is explicitly
    # enabled.  A production process that inherits either variable only gets a
    # WARN: it can neither bypass the inode gate nor rewrite the verified bytes.
    _vtest_mode="${C640_KBD_TEST_MODE:-}"
    if [ "$_vtest_mode" != 1 ]; then
        if [ -n "${C640_KBD_VERIFY_TEST_FAILPOINT:-}" ] \
            || [ -n "${C640_KBD_VERIFY_TEST_SWAP_VALUE:-}" ]; then
            log_warn "verify test hooks ignored (C640_KBD_TEST_MODE is not 1)"
        fi
    fi
    if ! _vout="$(python3 -c '
import os, stat, sys

dirpath, name, token, expected_ident, expected_value, test_mode = sys.argv[1:7]
# The test-only failpoints are gated by an explicit C640_KBD_TEST_MODE=1;
# otherwise an inherited env var must have no effect on the verdict.
failpoint = os.environ.get("C640_KBD_VERIFY_TEST_FAILPOINT", "") if test_mode == "1" else ""
swap_value = os.environ.get("C640_KBD_VERIFY_TEST_SWAP_VALUE", "9") if test_mode == "1" else "9"
dfd = sfd = None


def inode(st):
    return (st.st_dev, st.st_ino)


def emit(verdict, detail=""):
    sys.stdout.write("FAIL %s %s\n" % (verdict, detail))
    sys.exit(1)


try:
    dfd = os.open(dirpath, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    if not stat.S_ISDIR(os.fstat(dfd).st_mode):
        emit("IO", "not-a-directory")
    sfd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
    sst = os.fstat(sfd)
    if not stat.S_ISREG(sst.st_mode):
        emit("IO", "not-regular")
    actual_ident = "%d:%d" % inode(sst)
    # Test-mode only: force the identity gate to pass even for a swapped inode.
    # Only the byte-exact value gate can then stop a tampered payload.
    if failpoint == "force-identity":
        actual_ident = expected_ident
    if actual_ident != expected_ident:
        emit("INODE", actual_ident)
    # Test-mode only TOCTOU: swap the directory entry AFTER this fd was opened
    # and stat-ed.  Reading from sfd still yields the original bytes; a
    # pathname re-read would yield the swapped payload instead.
    if failpoint == "swap-after-fstat":
        tname = ".c640-kbd-verify.%d.%s" % (os.getpid(), os.urandom(6).hex())
        tfd = os.open(
            tname,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=dfd,
        )
        data = ("%s %s published\n" % (token, swap_value)).encode("utf-8")
        written = 0
        while written < len(data):
            written += os.write(tfd, data[written:])
        os.close(tfd)
        os.rename(tname, name, src_dir_fd=dfd, dst_dir_fd=dfd)
    chunks = []
    while True:
        chunk = os.read(sfd, 4096)
        if not chunk:
            break
        chunks.append(chunk)
    data = b"".join(chunks)
    expected = ("%s %s published\n" % (token, expected_value)).encode("utf-8")
    if data == expected:
        sys.stdout.write("VALUE %s\n" % expected_value)
        sys.exit(0)
    if data.count(b"\n") != 1 or not data.endswith(b"\n"):
        emit("STRUCT", "bad-framing")
    fields = data[:-1].split(b" ")
    if len(fields) != 3 or fields[2] != b"published":
        emit("STRUCT", "bad-fields")
    try:
        actual_token = fields[0].decode("ascii")
        actual_value = fields[1].decode("ascii")
    except UnicodeDecodeError:
        emit("STRUCT", "non-ascii")
    if actual_token != token:
        emit("TOKEN", actual_token)
    if actual_value != expected_value:
        emit("VALUE", actual_value)
    emit("STRUCT", "mismatch")
except Exception as exc:
    sys.stdout.write("FAIL IO %s\n" % str(exc).replace(" ", "-"))
    sys.exit(1)
finally:
    if sfd is not None:
        os.close(sfd)
    if dfd is not None:
        os.close(dfd)
' "$_vdir" "$_vname" "$_vtoken" "$_vident" "$_vvalue" "$_vtest_mode")"; then
        # Map the internal verdict back onto the established journal strings
        # (H5 token mismatch / H6 inode mismatch) so existing assertion
        # patterns remain valid.  VALUE and STRUCT get their own WARN text.
        case "$_vout" in
            "FAIL INODE "*)
                _detail="${_vout#FAIL INODE }"
                log_warn "resume handoff skipped (fail-closed): suspend inode $_detail != cycle marker $CYCLE_IDENTITY"
                ;;
            "FAIL TOKEN "*)
                log_warn "resume handoff skipped (fail-closed): suspend/cycle token mismatch"
                ;;
            "FAIL VALUE "*)
                _detail="${_vout#FAIL VALUE }"
                log_warn "resume handoff skipped (fail-closed): suspend/cycle value mismatch ('$_detail' vs '$CYCLE_VALUE')"
                ;;
            "FAIL STRUCT "*)
                _detail="${_vout#FAIL STRUCT }"
                log_warn "resume handoff skipped (fail-closed): invalid suspend handoff ($_detail)"
                ;;
            *)
                log_warn "resume handoff skipped (fail-closed): suspend handoff verification failed ('$_vout')"
                ;;
        esac
        return 1
    fi
    return 0
}

# post may publish its flag only when the root marker, the suspend handoff
# bytes and the ACTUAL suspend inode all agree on the same token, identity
# and committed value.  Sets the globals _token and _svalue used in the
# resume record.
_verify_cycle_commit() {
    _token=""
    _svalue=""
    _read_cycle_commit || return 1
    if [ -z "$HANDOFF_DIR" ] || [ ! -f "$HANDOFF_DIR/$SUSPEND_HANDOFF" ] \
        || [ -L "$HANDOFF_DIR/$SUSPEND_HANDOFF" ]; then
        log_warn "resume handoff skipped (fail-closed): suspend handoff missing/unsafe"
        return 1
    fi
    if ! _verify_suspend_fd "$HANDOFF_DIR" "$SUSPEND_HANDOFF" \
        "$CYCLE_TOKEN" "$CYCLE_IDENTITY" "$CYCLE_VALUE"; then
        return 1
    fi
    if [ "${_vout#VALUE }" = "$_vout" ] \
        || ! printf '%s\n' "${_vout#VALUE }" | grep -Eq '^[0-9]{1,10}$'; then
        log_warn "resume handoff skipped (fail-closed): invalid suspend verification record '$_vout'"
        return 1
    fi
    _svalue="${_vout#VALUE }"
    _token="$CYCLE_TOKEN"
    return 0
}

# pre: publish the brightness the daemon must restore after thaw. The value
# is the raw root reading (0 valid), NOT clamped here - clamping belongs to
# the daemon's single-writer set_brightness path.  The root commit marker is
# written LAST: no marker means no committed cycle for post/daemon to adopt.
publish_suspend_handoff() {
    _invalidate_previous_cycle || return 1
    resolve_handoff_dir pre
    [ -n "$HANDOFF_DIR" ] || return 0
    _curr="$(_read_current)"
    case "$_curr" in
        '' | *[!0-9]*)
            log_warn "unreadable brightness; suspend handoff skipped"
            return 1
            ;;
    esac
    _token="$(_new_cycle_token)" || {
        log_warn "cannot mint cycle token; suspend handoff skipped"
        return 1
    }
    # PUBLISHED_IDENTITY is captured for binding, but the Phase B stdout
    # contract is preserved by printing it back below.
    if ! PUBLISHED_IDENTITY="$(_publish_handoff "$HANDOFF_DIR/$SUSPEND_HANDOFF" \
        "$_token $_curr published" "$HANDOFF_OWNER" "$HANDOFF_GID")"; then
        return 1
    fi
    printf '%s\n' "$PUBLISHED_IDENTITY"
    _ident="${PUBLISHED_IDENTITY#OK }"
    if [ "$_ident" = "$PUBLISHED_IDENTITY" ] \
        || ! printf '%s\n' "$_ident" | grep -Eq '^[0-9]+:[0-9]+$'; then
        log_warn "invalid published identity '$PUBLISHED_IDENTITY'; cycle not committed"
        return 1
    fi
    _hook_uid="$(id -u 2> /dev/null || echo '')"
    _hook_gid="$(id -g 2> /dev/null || echo '')"
    case "$_hook_uid" in '' | *[!0-9]*)
        log_warn "cannot resolve hook uid for cycle commit marker"
        return 1
        ;;
    esac
    case "$_hook_gid" in '' | *[!0-9]*)
        log_warn "cannot resolve hook gid for cycle commit marker"
        return 1
        ;;
    esac
    # The committed value is part of the marker: post binds the suspend
    # payload byte-for-byte to it, and the daemon carries it in the resume
    # flag as the authoritative restore value.
    if ! _commit_out="$(_publish_handoff "$CYCLE_FILE" "$_token $_ident $_curr" \
        "$_hook_uid" "$_hook_gid")"; then
        rm -f "$CYCLE_FILE" "$HANDOFF_DIR/$SUSPEND_HANDOFF" 2> /dev/null || true
        log_warn "cycle commit marker publish failed; suspend handoff rolled back"
        return 1
    fi
    printf '%s\n' "$_commit_out"
    return 0
}

# post: only drop the resume flag. No brightness read/write, no state change,
# no D-Bus. The daemon uses this flag (plus the suspend handoff) after thaw.
write_resume_handoff() {
    _action="${1:-suspend}"
    resolve_handoff_dir post
    [ -n "$HANDOFF_DIR" ] || return 0
    _verify_cycle_commit || return 1
    _epoch="$(date +%s 2> /dev/null || echo 0)"
    case "$_epoch" in '' | *[!0-9]*) _epoch=0 ;; esac
    if ! PUBLISHED_IDENTITY="$(_publish_handoff "$HANDOFF_DIR/$RESUME_HANDOFF" \
        "$_token $_epoch $_action $_svalue" "$HANDOFF_OWNER" "$HANDOFF_GID")"; then
        return 1
    fi
    printf '%s\n' "$PUBLISHED_IDENTITY"
}

main() {
    case "${1:-}" in
        pre)
            save_state
            # A failed fd publish is still a WARN only: the hook must never
            # turn a suspend into a failed systemd job (phase C builds the
            # per-cycle invalid marker on top of this rc contract).
            publish_suspend_handoff || log_warn "suspend handoff publish failed; root state retained"
            ;;
        post)
            # No sleep, no ScreenSaver probe, no sysfs/ectool write, no state
            # deletion. The thawed user daemon owns the restore (Phase 4b).
            write_resume_handoff "${2:-}" || log_warn "resume handoff publish failed; no state change"
            ;;
    esac
}

# Sourcing with C640_KBD_SLEEP_SOURCE_ONLY=1 is used by the unit test; the
# real system-sleep hook always runs main and exits.
if [ -z "${C640_KBD_SLEEP_SOURCE_ONLY:-}" ]; then
    main "$@"
    exit 0
fi
