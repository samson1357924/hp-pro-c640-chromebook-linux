#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# kbd-backlight-sleep-hook-test.sh - unit tests for the system-sleep hook.
#
# The hook now works through HANDOFF FILES, not by restoring brightness
# itself. No root, no real sysfs, no real D-Bus, no writes to real /run/user:
# everything lives in a temp dir and gdbus/sudo/loginctl/ectool are stubbed
# via PATH. The frozen-user.slice scenario is simulated by making gdbus/sudo
# fail immediately (STUB_FROZEN=1); the hook must never call them at all.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
HOOK="$REPO_ROOT/keyboard/systemd/c640-kbd-backlight-sleep.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
STUB_DIR="$TMP_DIR/stubs"
STATE_DIR="$TMP_DIR/state"
FAKE_SYSFS="$TMP_DIR/brightness"
FAKE_MAX="$TMP_DIR/max_brightness"
HANDOFF_DIR="$TMP_DIR/handoff"
RUN_USER_ROOT="$TMP_DIR/run-user"
GDBUS_LOG="$TMP_DIR/gdbus.log"
ECTOOL_LOG="$TMP_DIR/ectool.log"
SUDO_LOG="$TMP_DIR/sudo.log"
LOGINCTL_LOG="$TMP_DIR/loginctl.log"
HOOK_ERR="$TMP_DIR/hook.err"
CHMOD_LOG="$TMP_DIR/chmod.log"
CHOWN_LOG="$TMP_DIR/chown.log"
MKTEMP_LOG="$TMP_DIR/mktemp.log"
MV_LOG="$TMP_DIR/mv.log"
CP_LOG="$TMP_DIR/cp.log"
STAT_COUNT="$TMP_DIR/stat-count"
PUBLISH_OUT="$TMP_DIR/publish.out"
HOOK_MARKER_DIR="$TMP_DIR/publish-markers"
FALLBACK_DIR="$TMP_DIR/tmp-fallback"
SUSPEND_FILE="$HANDOFF_DIR/c640-kbd-backlight.suspend"
RESUME_FILE="$HANDOFF_DIR/c640-kbd-backlight.resume"
# The independent oracle runs with the runner's ORIGINAL PATH and the real
# interpreter, never with the stub PATH used to drive the hook.  Capture both
# before any stub is installed (the hook's own python3 is stubbed below).
CLEAN_PATH="$PATH"
REAL_PYTHON="$(command -v python3)"
ORACLE_PY="$TMP_DIR/dir-oracle.py"
mkdir -p "$STUB_DIR" "$STATE_DIR" "$HANDOFF_DIR" "$RUN_USER_ROOT" "$FALLBACK_DIR" \
    "$HOOK_MARKER_DIR"

passed=0
failed=0
ok() {
    printf 'PASS: %s\n' "$1"
    passed=$((passed + 1))
}
bad() {
    printf 'FAIL: %s\n' "$1" >&2
    failed=$((failed + 1))
}
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        ok "$label"
    else
        bad "$label (expected '$expected', got '$actual')"
    fi
}
assert_file() {
    local label="$1" file="$2" expected="$3" actual
    actual="$(cat "$file" 2> /dev/null || echo '<missing>')"
    assert_eq "$label" "$expected" "$actual"
}
assert_absent() {
    local label="$1" file="$2"
    if [ -e "$file" ]; then
        bad "$label (file still exists)"
    else
        ok "$label"
    fi
}
assert_empty_log() {
    local label="$1" file="$2" actual
    actual="$(cat "$file" 2> /dev/null || echo '')"
    assert_eq "$label" "" "$actual"
}
assert_mode() {
    local label="$1" expected="$2" file="$3" actual
    actual="$(stat -c %a "$file" 2> /dev/null || echo '<missing>')"
    assert_eq "$label" "$expected" "$actual"
}
assert_owner() {
    local label="$1" expected="$2" file="$3" actual
    actual="$(stat -c '%u:%g' "$file" 2> /dev/null || echo '<missing>')"
    assert_eq "$label" "$expected" "$actual"
}
# stat-only owner/mode checks pass even when the hook omits chmod/chown,
# because mktemp already creates a 0600 file owned by the current user. The
# recorded stub calls below are what make those hook steps falsifiable.
assert_log_matches() {
    local label="$1" file="$2" pattern="$3" actual
    actual="$(cat "$file" 2> /dev/null || echo '')"
    if printf '%s\n' "$actual" | grep -Eq -- "$pattern"; then
        ok "$label"
    else
        bad "$label (no match for '$pattern' in: $actual)"
    fi
}
# The hook must not touch any session/user bus or any brightness tool in post.
assert_no_bus_or_led_writes() {
    local tag="$1"
    assert_empty_log "gdbus never called ($tag)" "$GDBUS_LOG"
    assert_empty_log "sudo never called ($tag)" "$SUDO_LOG"
    assert_empty_log "ectool never called ($tag)" "$ECTOOL_LOG"
}
assert_resume_flag() {
    local label="$1" action="$2" content
    content="$(cat "$RESUME_FILE" 2> /dev/null || echo '<missing>')"
    if [[ "$content" =~ ^[0-9]+[[:space:]]"$action"$ ]]; then
        ok "$label"
    else
        bad "$label (expected '<epoch> $action', got '$content')"
    fi
}
# A failed publish must not leave its temp file behind.
assert_no_handoff_temp() {
    local label="$1" dir="${2:-$HANDOFF_DIR}" found
    found="$(find "$dir" -maxdepth 1 -name '.c640-kbd-handoff.*' -print -quit 2> /dev/null || echo '')"
    if [ -n "$found" ]; then
        bad "$label (left $found behind)"
    else
        ok "$label"
    fi
}
# The fd publisher never calls `mv`; success is recorded as `OK dev:ino` on
# stdout.  A guard rejection must leave no publish record at all (an empty
# MV_LOG would be a vacuous pass with the new implementation).
assert_no_handoff_publish() {
    local label="$1" out
    out="$(cat "$PUBLISH_OUT" 2> /dev/null || echo '')"
    assert_eq "$label" "" "$out"
}
assert_text_matches() {
    local label="$1" text="$2" pattern="$3"
    if printf '%s\n' "$text" | grep -Eq -- "$pattern"; then
        ok "$label"
    else
        bad "$label (no match for '$pattern' in: $text)"
    fi
}
# dev:ino of the last recorded successful publish; Phase C consumes the same
# `OK dev:ino` record as PUBLISHED_IDENTITY.
published_identity() {
    sed -n 's/^OK \([0-9][0-9]*:[0-9][0-9]*\)$/\1/p' "$PUBLISH_OUT" \
        2> /dev/null | tail -n1
}
assert_publish_identity() {
    local label="$1" file="$2" expected actual
    expected="$(stat -c '%d:%i' "$file" 2> /dev/null || echo '<missing>')"
    actual="$(published_identity)"
    assert_eq "$label" "$expected" "$actual"
}
# Independent oracle: a separate python3 program under the CLEAN_PATH reads
# every directory entry with lstat (name/dev/ino/mode/uid/gid) and hashes
# regular-file bytes.  It does not source the hook, use its stubs, or trust
# any hook log, so "zero mutation" comparisons cannot pass on empty logs.
cat > "$ORACLE_PY" << 'PY'
import hashlib
import os
import stat
import sys

root = sys.argv[1]
rows = []
for name in sorted(os.listdir(root)):
    path = os.path.join(root, name)
    st = os.lstat(path)
    digest = ""
    if stat.S_ISREG(st.st_mode):
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
    rows.append("|".join((
        name,
        str(st.st_dev),
        str(st.st_ino),
        oct(stat.S_IMODE(st.st_mode)),
        str(st.st_uid),
        str(st.st_gid),
        digest,
    )))
sys.stdout.write("\n".join(rows))
if rows:
    sys.stdout.write("\n")
PY
snapshot_dir() {
    env -i PATH="$CLEAN_PATH" "$REAL_PYTHON" "$ORACLE_PY" "$1" 2> /dev/null \
        || echo '<unreadable>'
}
assert_snapshot_same() {
    local label="$1" dir="$2" expected="$3" actual
    actual="$(snapshot_dir "$dir")"
    assert_eq "$label" "$expected" "$actual"
}

# --- stubs -----------------------------------------------------------------
cat > "$STUB_DIR/gdbus" << 'STUB'
#!/bin/sh
printf 'gdbus %s | XDG=%s BUS=%s\n' "$*" "${XDG_RUNTIME_DIR:-}" "${DBUS_SESSION_BUS_ADDRESS:-}" >> "$STUB_GDBUS_LOG"
# Frozen user.slice simulation: any attempt to reach the session bus dies
# immediately, exactly like a frozen/timeout'd gdbus call on real S3 resume.
if [ "${STUB_FROZEN:-0}" = "1" ]; then
    exit 124
fi
case "$*" in
    *org.gnome.ScreenSaver*GetActive*)
        if [ "${STUB_GNOME_ACTIVE:-false}" = "true" ]; then
            printf '(true,)\n'
        else
            printf '(false,)\n'
        fi
        ;;
    *org.freedesktop.ScreenSaver*GetActive*)
        if [ "${STUB_FDO_ACTIVE:-false}" = "true" ]; then
            printf '(true,)\n'
        else
            printf '(false,)\n'
        fi
        ;;
esac
exit 0
STUB

# Drop "-u <user>" and run the rest as the current (unprivileged) test user.
# Any invocation at all is a bug in the new hook, so it is logged and, when
# frozen, fails immediately.
cat > "$STUB_DIR/sudo" << 'STUB'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$STUB_SUDO_LOG"
if [ "${STUB_FROZEN:-0}" = "1" ]; then
    exit 124
fi
if [ "${1:-}" = "-u" ]; then
    shift 2
fi
exec "$@"
STUB

# loginctl stub.  `list-sessions --no-legend` supplies only SESSION IDs; the
# real properties come from `show-session <id>` and the seat's active session
# from `show-seat <seat> -p ActiveSession` (Key=Value, no --value).  Each mode
# models a realistic host; an idle SSH session is Active=no/Remote=yes and a
# greeter is Class=greeter, neither of which may own the handoff.
# STUB_UID_FIELD defaults to the real schema `User=`; the legacy-UID
# sensitivity case flips ONLY that key to `UID=`, leaving every other
# property in the PASS state, so the hook's schema choice is falsifiable.
cat > "$STUB_DIR/loginctl" << 'STUB'
#!/bin/sh
printf 'loginctl %s\n' "$*" >> "${STUB_LOGINCTL_LOG:-/dev/null}"
_mode="${STUB_LOGINCTL_MODE:-none}"
_field="${STUB_UID_FIELD:-User}"
_me="$(id -u)"
_nobody="$(id -u nobody)"

_graphical() { # id uid seat type state
    printf 'Id=%s\nName=%s\n%s=%s\nSeat=%s\nTTY=tty7\nType=%s\nClass=user\nActive=yes\nRemote=no\nState=%s\n' \
        "$1" "$1" "$_field" "$2" "$3" "$4" "$5"
}
# Single-property override helper for the load-bearing gate cases: every
# property except the one under test stays in the PASS state, and the session
# IS its seat's ActiveSession.  That makes exactly one gate responsible for
# exclusion, so removing that gate must change the outcome.
_props() { # id uid seat type class active remote state
    printf 'Id=%s\nName=%s\n%s=%s\nSeat=%s\nTTY=tty7\nType=%s\nClass=%s\nActive=%s\nRemote=%s\nState=%s\n' \
        "$1" "$1" "$_field" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}
_idle_ssh() { # id uid
    printf 'Id=%s\nName=%s\n%s=%s\nSeat=seat0\nTTY=pts/0\nType=tty\nClass=user\nActive=no\nRemote=yes\nState=idle\n' \
        "$1" "$1" "$_field" "$2"
}
_greeter() { # id uid
    printf 'Id=%s\nName=%s\n%s=%s\nSeat=seat0\nTTY=tty2\nType=x11\nClass=greeter\nActive=yes\nRemote=no\nState=active\n' \
        "$1" "$1" "$_field" "$2"
}

_cmd="${1:-}"
if [ "$_cmd" = "show-session" ]; then
    case "$_mode:$2" in
        real:3 | idle-ssh:3 | pre-post-other:3 | bad-dir-mode:3)
            _graphical 3 "$_me" seat0 wayland active ;;
        closing:3) _graphical 3 "$_me" seat0 wayland closing ;;
        pre-post-other:7 | bad-dir-missing:3 | bad-dir-owner:3)
            _graphical "${2:-3}" "$_nobody" seat0 wayland active ;;
        idle-ssh:4) _idle_ssh 4 "$_nobody" ;;
        greeter-user:5) _greeter 5 "$_nobody" ;;
        greeter-user:6) _graphical 6 "$_me" seat0 x11 active ;;
        ambiguous:10) _graphical 10 "$_me" seat0 wayland active ;;
        ambiguous:11) _graphical 11 "$_nobody" seat1 x11 active ;;
        active-no:20) _props 20 "$_me" seat0 wayland user no no active ;;
        remote-yes:30) _props 30 "$_me" seat0 x11 user yes yes active ;;
        seat-active:41) _graphical 41 "$_me" seat0 wayland active ;;
        seat-active:42) _graphical 42 "$_me" seat0 x11 active ;;
        greeter-active:50) _greeter 50 "$_me" ;;
        greeter-active:51) _graphical 51 "$_me" seat0 x11 active ;;
        type-tty:60) _props 60 "$_me" seat0 tty user yes no active ;;
        c-prefix:c1) _graphical c1 "$_me" seat0 wayland active ;;
    esac
    exit 0
fi
if [ "$_cmd" = "show-seat" ]; then
    case "$_mode:$2" in
        real:seat0 | idle-ssh:seat0 | bad-dir-*:seat0 | closing:seat0)
            printf 'Name=seat0\nActiveSession=3\n' ;;
        pre-post-other:seat0) printf 'Name=seat0\nActiveSession=7\n' ;;
        greeter-user:seat0) printf 'Name=seat0\nActiveSession=6\n' ;;
        ambiguous:seat0) printf 'Name=seat0\nActiveSession=10\n' ;;
        ambiguous:seat1) printf 'Name=seat1\nActiveSession=11\n' ;;
        active-no:seat0) printf 'Name=seat0\nActiveSession=20\n' ;;
        remote-yes:seat0) printf 'Name=seat0\nActiveSession=30\n' ;;
        seat-active:seat0) printf 'Name=seat0\nActiveSession=41\n' ;;
        greeter-active:seat0) printf 'Name=seat0\nActiveSession=50\n' ;;
        type-tty:seat0) printf 'Name=seat0\nActiveSession=60\n' ;;
        c-prefix:seat0) printf 'Name=seat0\nActiveSession=c1\n' ;;
    esac
    exit 0
fi

# SESSION UID USER SEAT LEADER CLASS TTY IDLE SINCE (real column layout).
case "$_mode" in
    real | bad-dir-mode | closing)
        printf '3 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me" ;;
    bad-dir-missing | bad-dir-owner)
        printf '3 %s nobody seat0 %s user tty7 no 2026-11-25 08:00\n' "$_nobody" "$_nobody" ;;
    idle-ssh)
        printf '3 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me"
        printf '4 %s nobody seat0 %s user pts/0 yes 2026-11-25 09:00\n' "$_nobody" "$_nobody" ;;
    pre-post-other)
        printf '7 %s nobody seat0 %s user tty7 no 2026-11-25 08:00\n' "$_nobody" "$_nobody" ;;
    greeter-user)
        printf '5 %s nobody seat0 %s greeter tty2 no 2026-11-25 07:00\n' "$_nobody" "$_nobody"
        printf '6 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me" ;;
    ambiguous)
        printf '10 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me"
        printf '11 %s nobody seat1 %s user tty7 no 2026-11-25 08:00\n' "$_nobody" "$_nobody" ;;
    active-no)
        printf '20 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me" ;;
    remote-yes)
        printf '30 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me" ;;
    seat-active)
        printf '41 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me"
        printf '42 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me" ;;
    greeter-active)
        printf '50 %s %s seat0 %s greeter tty2 no 2026-11-25 07:00\n' "$_me" "$(id -nu)" "$_me"
        printf '51 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me" ;;
    type-tty)
        printf '60 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me" ;;
    c-prefix)
        # systemd's session_id_valid() also accepts c-prefixed IDs.
        printf 'c1 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me" ;;
    ambiguous-ids)
        # Malformed / reserved IDs.  show-session must NEVER be called for
        # any of them and _session_uid must fail closed with 0 candidates.
        printf 'c;1 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me"
        printf '../x %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me"
        printf 'self %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me"
        printf 'auto %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me"
        # A whitespace-bearing raw ID: list-sessions column splitting leaves
        # "c" as the first field; show-session must not see the raw value.
        printf 'c 1 %s %s seat0 %s user tty7 no 2026-11-25 08:00\n' "$_me" "$(id -nu)" "$_me" ;;
esac
exit 0
STUB

cat > "$STUB_DIR/ectool" << 'STUB'
#!/bin/sh
printf 'ectool %s\n' "$*" >> "$STUB_ECTOOL_LOG"
if [ "${1:-}" = "pwmgetkblight" ]; then
    printf '100\n'
fi
exit 0
STUB
# Legacy chmod/chown stubs are kept to prove the fd publisher does NOT go
# back to pathname-based chmod/chown: those calls are now fchmod/fchown inside
# the pinned python helper.  They exec the real binaries so any other caller
# (save_state / the cycle-uid pin) still behaves normally.
cat > "$STUB_DIR/chmod" << 'STUB'
#!/bin/sh
printf 'chmod %s\n' "$*" >> "$STUB_CHMOD_LOG"
exec /bin/chmod "$@"
STUB
cat > "$STUB_DIR/chown" << 'STUB'
#!/bin/sh
printf 'chown %s\n' "$*" >> "$STUB_CHOWN_LOG"
exec /bin/chown "$@"
STUB
# Legacy mktemp stub: the fd publisher never calls mktemp, but save_state and
# the cycle-uid pin still use same-directory mktemp.  Kept so those root-only
# paths remain observable; the no-/tmp-fallback case now uses the independent
# directory oracle instead of this log.
cat > "$STUB_DIR/mktemp" << 'STUB'
#!/bin/sh
printf 'mktemp %s\n' "$*" >> "$STUB_MKTEMP_LOG"
exec /usr/bin/mktemp "$@"
STUB
# Legacy mv stub: save_state and the cycle-uid pin still use `mv -T -f --`.
# The handoff publisher now uses rename(dir_fd -> dir_fd) in python, so the
# handoff rename-failure sensitivity cases use the failpoint env instead of
# STUB_MV_FAIL (an empty MV_LOG would be a vacuous pass).
cat > "$STUB_DIR/mv" << 'STUB'
#!/bin/sh
printf 'mv %s\n' "$*" >> "${STUB_MV_LOG:-/dev/null}"
_fail=0
for _arg in "$@"; do
    case "$_arg" in
        *.c640-kbd-handoff.*)
            if [ "${STUB_MV_FAIL:-0}" = "1" ]; then
                _fail=1
            fi
            ;;
    esac
done
if [ "$_fail" = "1" ]; then
    exit 1
fi
exec /bin/mv "$@"
STUB
# Any cp call is a bug: cp follows a user-controlled symlink and would
# overwrite the victim outside the runtime directory.
cat > "$STUB_DIR/cp" << 'STUB'
#!/bin/sh
printf 'cp %s\n' "$*" >> "${STUB_CP_LOG:-/dev/null}"
exec /bin/cp "$@"
STUB
# python3 is a new pre/post runtime dependency.  STUB_PYTHON_FAIL=1 models an
# interpreter that cannot be executed; the hook must warn, return nonzero
# from _publish_handoff and leave the handoff directory untouched.  Otherwise
# pass through to the real interpreter captured before the stub PATH existed.
cat > "$STUB_DIR/python3" << STUB
#!/bin/sh
if [ "\${STUB_PYTHON_FAIL:-0}" = "1" ]; then
    printf 'python3 unavailable\n' >&2
    exit 127
fi
exec "$REAL_PYTHON" "\$@"
STUB
# `id -g` is a load-bearing part of the publish contract (fchown uid:gid).
# STUB_ID_G_FAIL=1 makes ONLY -g fail; `id -nu` (session validation) still
# works, so the gid failure is isolated and must fail closed before any temp.
cat > "$STUB_DIR/id" << 'STUB'
#!/bin/sh
if [ "${STUB_ID_G_FAIL:-0}" = "1" ]; then
    for _arg in "$@"; do
        if [ "$_arg" = "-g" ]; then
            printf 'id: cannot resolve gid\n' >&2
            exit 1
        fi
    done
fi
exec /usr/bin/id "$@"
STUB
# Optional TOCTOU simulation for the -T sensitivity case.  On the Nth full
# directory-identity stat (2 = the re-check just before the rename), replace
# a regular destination with a symlink to an outside dir.  `mv -T` then
# replaces that symlink in place; plain `mv -f` follows it and drops the temp
# file into the outside dir.  With no STUB_RACE_AT this is pure passthrough.
cat > "$STUB_DIR/stat" << 'STUB'
#!/bin/sh
_count_file="${STUB_STAT_COUNT_FILE:-/dev/null}"
case "$*" in
    *'%d:%i %a %u:%g'*)
        _n=0
        if [ -r "$_count_file" ]; then
            _n="$(cat "$_count_file" 2> /dev/null || echo 0)"
        fi
        case "$_n" in '' | *[!0-9]*) _n=0 ;; esac
        _n=$((_n + 1))
        printf '%s' "$_n" > "$_count_file" 2> /dev/null || true
        if [ "$_n" = "${STUB_RACE_AT:-0}" ] && [ -n "${STUB_RACE_LINK:-}" ]; then
            rm -f "$STUB_RACE_LINK" 2> /dev/null || true
            ln -s "$STUB_RACE_TARGET" "$STUB_RACE_LINK" 2> /dev/null || true
        fi
        ;;
esac
exec /bin/stat "$@"
STUB
chmod +x "$STUB_DIR/gdbus" "$STUB_DIR/sudo" "$STUB_DIR/ectool" "$STUB_DIR/loginctl" \
    "$STUB_DIR/chmod" "$STUB_DIR/chown" "$STUB_DIR/mktemp" \
    "$STUB_DIR/mv" "$STUB_DIR/cp" "$STUB_DIR/stat" \
    "$STUB_DIR/python3" "$STUB_DIR/id"

# 0. Fixture schema self-check: the stub itself must emit the REAL loginctl
#    session schema (User=<numeric uid>, never UID=).  Without this guard a
#    future edit could silently move the stub and the hook to the same wrong
#    schema and make all the resolution cases self-confirming green.
_fixture_props="$(PATH="$STUB_DIR:$PATH" STUB_LOGINCTL_MODE=real \
    "$STUB_DIR/loginctl" show-session 3 2> /dev/null || true)"
if printf '%s\n' "$_fixture_props" | grep -Eq '^User=[0-9]+$'; then
    ok "fixture schema: stub show-session prints numeric User="
else
    bad "fixture schema: no numeric User= in stub output ($_fixture_props)"
fi
if printf '%s\n' "$_fixture_props" | grep -Eq '^UID='; then
    bad "fixture schema: stub must not print UID= ($_fixture_props)"
else
    ok "fixture schema: stub does not print UID="
fi

# --- harness ----------------------------------------------------------------
# Empty HOOK_HANDOFF_DIR means "unset": the hook must resolve /run/user/<uid>
# itself (used by the loginctl-resolution and no-user cases).
HOOK_HANDOFF_DIR="$HANDOFF_DIR"
HOOK_SUDO_USER=""
HOOK_TMPDIR=""
STUB_FROZEN=0
STUB_MV_FAIL=0
STUB_RACE_AT=0
STUB_RACE_LINK=""
STUB_RACE_TARGET=""
STUB_PYTHON_FAIL=0
STUB_ID_G_FAIL=0
HOOK_FAILPOINT=""
HOOK_OUTSIDE="$TMP_DIR/boundary-victim"
STUB_GNOME_ACTIVE=false
STUB_FDO_ACTIVE=false
STUB_LOGINCTL_MODE=none
STUB_UID_FIELD=User

reset_case() {
    : > "$HOOK_ERR"
    : > "$GDBUS_LOG"
    : > "$ECTOOL_LOG"
    : > "$SUDO_LOG"
    : > "$LOGINCTL_LOG"
    : > "$CHMOD_LOG"
    : > "$CHOWN_LOG"
    : > "$MKTEMP_LOG"
    : > "$MV_LOG"
    : > "$CP_LOG"
    : > "$PUBLISH_OUT"
    rm -f "$HOOK_MARKER_DIR/fchmod" "$HOOK_MARKER_DIR/fchown"
    printf '0' > "$STAT_COUNT"
    rm -f "$STATE_DIR/state" "$STATE_DIR"/.state.* "$STATE_DIR/session-uid" \
        "$STATE_DIR"/.session-uid.* "$FAKE_SYSFS" "$FAKE_MAX"
    # The boundary cases deliberately make the handoff path a symlink or a
    # real directory; rm -f alone cannot clean those up for the next case.
    rm -f "$SUSPEND_FILE" "$RESUME_FILE" 2> /dev/null || true
    rm -rf "$SUSPEND_FILE" "$RESUME_FILE" 2> /dev/null || true
    rm -f "$HANDOFF_DIR"/.c640-kbd-handoff.* 2> /dev/null || true
    # 9ag chmods the pinned dir to 0755; restore 0700 so later cases start
    # from the same clean state (even though the override path skips the check).
    if [ -d "$HANDOFF_DIR" ]; then
        chmod 700 "$HANDOFF_DIR"
    fi
    rm -rf "$TMP_DIR/boundary-target" "$TMP_DIR/boundary-victim" "$TMP_DIR/boundary-outside"
    # The dir-swap failpoint moves the pinned dir aside; remove that too.
    rm -rf "$HANDOFF_DIR.swapped"
    rm -rf "$RUN_USER_ROOT"
    mkdir -p "$RUN_USER_ROOT/$(id -u)"
    chmod 700 "$RUN_USER_ROOT/$(id -u)"
    printf '7\n' > "$FAKE_SYSFS"
    printf '100\n' > "$FAKE_MAX"
    HOOK_HANDOFF_DIR="$HANDOFF_DIR"
    HOOK_SUDO_USER=""
    HOOK_TMPDIR=""
    STUB_FROZEN=0
    STUB_GNOME_ACTIVE=false
    STUB_FDO_ACTIVE=false
    STUB_LOGINCTL_MODE=none
    STUB_UID_FIELD=User
    STUB_MV_FAIL=0
    STUB_RACE_AT=0
    STUB_RACE_LINK=""
    STUB_RACE_TARGET=""
    STUB_PYTHON_FAIL=0
    STUB_ID_G_FAIL=0
    HOOK_FAILPOINT=""
    HOOK_OUTSIDE="$TMP_DIR/boundary-victim"
}

run_hook() {
    local -a env_args=(
        "PATH=$STUB_DIR:$PATH"
        "STUB_GDBUS_LOG=$GDBUS_LOG"
        "STUB_ECTOOL_LOG=$ECTOOL_LOG"
        "STUB_SUDO_LOG=$SUDO_LOG"
        "STUB_LOGINCTL_LOG=$LOGINCTL_LOG"
        "STUB_CHMOD_LOG=$CHMOD_LOG"
        "STUB_CHOWN_LOG=$CHOWN_LOG"
        "STUB_MKTEMP_LOG=$MKTEMP_LOG"
        "STUB_MV_LOG=$MV_LOG"
        "STUB_CP_LOG=$CP_LOG"
        "STUB_MV_FAIL=$STUB_MV_FAIL"
        "STUB_STAT_COUNT_FILE=$STAT_COUNT"
        "STUB_RACE_AT=$STUB_RACE_AT"
        "STUB_RACE_LINK=$STUB_RACE_LINK"
        "STUB_RACE_TARGET=$STUB_RACE_TARGET"
        "STUB_PYTHON_FAIL=$STUB_PYTHON_FAIL"
        "STUB_ID_G_FAIL=$STUB_ID_G_FAIL"
        "C640_KBD_PUBLISH_TEST_FAILPOINT=$HOOK_FAILPOINT"
        "C640_KBD_PUBLISH_TEST_OUTSIDE=$HOOK_OUTSIDE"
        "C640_KBD_PUBLISH_TEST_MARKER_DIR=$HOOK_MARKER_DIR"
        "STUB_LOGINCTL_MODE=$STUB_LOGINCTL_MODE"
        "STUB_UID_FIELD=$STUB_UID_FIELD"
        "STUB_GNOME_ACTIVE=$STUB_GNOME_ACTIVE"
        "STUB_FDO_ACTIVE=$STUB_FDO_ACTIVE"
        "STUB_FROZEN=$STUB_FROZEN"
        "C640_KBD_SLEEP_SYSFS=$FAKE_SYSFS"
        "C640_KBD_SLEEP_STATE_DIR=$STATE_DIR"
        "C640_KBD_HANDOFF_DIR=$HOOK_HANDOFF_DIR"
        "C640_KBD_RUN_USER_ROOT=$RUN_USER_ROOT"
    )
    # SUDO_USER is unset by default (no stale hint from the test runner).  A
    # case may set HOOK_SUDO_USER to prove the hint cannot override loginctl.
    if [ -n "$HOOK_SUDO_USER" ]; then
        env_args+=("SUDO_USER=$HOOK_SUDO_USER")
    fi
    if [ -n "$HOOK_TMPDIR" ]; then
        env_args+=("TMPDIR=$HOOK_TMPDIR")
    fi
    # The old D-Bus knobs are removed so resolution is deterministic.
    env -u SUDO_USER -u C640_KBD_SLEEP_USER -u C640_KBD_SLEEP_UID \
        -u C640_KBD_SLEEP_BUS -u C640_KBD_SLEEP_DELAY \
        "${env_args[@]}" "$HOOK" "$@" >> "$PUBLISH_OUT" 2>> "$HOOK_ERR"
}

# Source the hook read-only and call its session resolver directly, so the
# return value of _session_uid itself is testable (not only its downstream
# handoff side effects).  The stub's loginctl is on PATH and logs every call.
_probe_session_uid() {
    (
        export PATH="$STUB_DIR:$PATH"
        export C640_KBD_SLEEP_SOURCE_ONLY=1
        export C640_KBD_RUN_USER_ROOT="$RUN_USER_ROOT"
        export STUB_LOGINCTL_MODE="$STUB_LOGINCTL_MODE"
        export STUB_UID_FIELD="$STUB_UID_FIELD"
        export STUB_LOGINCTL_LOG="$LOGINCTL_LOG"
        # shellcheck source=../systemd/c640-kbd-backlight-sleep.sh
        . "$HOOK"
        _session_uid
    ) 2>> "$HOOK_ERR"
}

if [ ! -f "$HOOK" ]; then
    printf 'FAIL: sleep hook not found at %s\n' "$HOOK" >&2
    exit 1
fi

# 1. pre stores the value in BOTH places; post only publishes the resume flag.
#    The brightness and the root state are left completely untouched.
reset_case
run_hook pre suspend
assert_mode "root state dir is 0700" "700" "$STATE_DIR"
assert_mode "root state file is 0600" "600" "$STATE_DIR/state"
assert_file "pre saves root state" "$STATE_DIR/state" "7"
assert_file "pre publishes suspend handoff" "$SUSPEND_FILE" "7"
assert_mode "suspend handoff is 0600" "600" "$SUSPEND_FILE"
# The publish is now an fd-pinned rename; its success record is `OK dev:ino`.
assert_log_matches "publish records OK dev:ino" "$PUBLISH_OUT" '^OK [0-9]+:[0-9]+$'
assert_publish_identity "publish identity matches published inode" "$SUSPEND_FILE"
assert_empty_log "publish has no cp fallback" "$CP_LOG"
printf '0\n' > "$FAKE_SYSFS"
run_hook post suspend
assert_file "post does NOT write sysfs" "$FAKE_SYSFS" "0"
assert_file "post does NOT consume root state" "$STATE_DIR/state" "7"
assert_file "post does NOT change suspend handoff" "$SUSPEND_FILE" "7"
assert_resume_flag "post publishes <epoch> suspend flag" "suspend"
assert_mode "resume handoff is 0600" "600" "$RESUME_FILE"
assert_no_bus_or_led_writes "pre/post delegate"

# 2. Frozen user.slice simulation: gdbus/sudo die with 124 the instant they are
#    called. The hook must never call them, must never restore or delete state,
#    and must return quickly so resume is not blocked.
reset_case
run_hook pre suspend
STUB_FROZEN=1
printf '0\n' > "$FAKE_SYSFS"
start_us="${EPOCHREALTIME/./}"
run_hook post suspend
end_us="${EPOCHREALTIME/./}"
elapsed_ms=$(((end_us - start_us) / 1000))
if [ "$elapsed_ms" -lt 2000 ]; then
    ok "frozen post returns quickly (${elapsed_ms}ms)"
else
    bad "frozen post blocked for ${elapsed_ms}ms"
fi
assert_file "frozen: brightness untouched" "$FAKE_SYSFS" "0"
assert_file "frozen: state untouched" "$STATE_DIR/state" "7"
assert_resume_flag "frozen: resume flag still written" "suspend"
assert_no_bus_or_led_writes "frozen"

# 3/4. A ScreenSaver answer is irrelevant in either direction: post never asks.
reset_case
run_hook pre suspend
printf '0\n' > "$FAKE_SYSFS"
STUB_GNOME_ACTIVE=true
run_hook post suspend
assert_file "active ScreenSaver: no sysfs write" "$FAKE_SYSFS" "0"
assert_file "active ScreenSaver: state retained" "$STATE_DIR/state" "7"
assert_no_bus_or_led_writes "active ScreenSaver"
reset_case
run_hook pre suspend
printf '0\n' > "$FAKE_SYSFS"
STUB_GNOME_ACTIVE=false
run_hook post suspend
assert_file "inactive ScreenSaver: no sysfs write" "$FAKE_SYSFS" "0"
assert_file "inactive ScreenSaver: state retained" "$STATE_DIR/state" "7"
assert_no_bus_or_led_writes "inactive ScreenSaver"

# 5. A brightness of 0 is a valid handoff value; post must not re-light.
reset_case
printf '0\n' > "$FAKE_SYSFS"
run_hook pre suspend
assert_file "0: root state" "$STATE_DIR/state" "0"
assert_file "0: suspend handoff" "$SUSPEND_FILE" "0"
printf '5\n' > "$FAKE_SYSFS"
run_hook post suspend
assert_file "0: post does not write sysfs" "$FAKE_SYSFS" "5"
assert_file "0: state retained" "$STATE_DIR/state" "0"
assert_resume_flag "0: resume flag written" "suspend"

# 6. No state file: post still publishes the flag and never touches brightness.
reset_case
printf '9\n' > "$FAKE_SYSFS"
run_hook post suspend
assert_file "no state: brightness untouched" "$FAKE_SYSFS" "9"
assert_absent "no state: no root state created" "$STATE_DIR/state"
assert_resume_flag "no state: resume flag written" "suspend"

# 7. Clamping moved to the daemon: the handoff stores the raw value verbatim
#    even when max_brightness shrinks, and post neither clamps nor writes.
reset_case
printf '70\n' > "$FAKE_SYSFS"
run_hook pre suspend
assert_file "clamp: handoff stores raw 70" "$SUSPEND_FILE" "70"
assert_file "clamp: root state stores raw 70" "$STATE_DIR/state" "70"
printf '0\n' > "$FAKE_SYSFS"
printf '50\n' > "$FAKE_MAX"
run_hook post suspend
assert_file "clamp: handoff unchanged after post" "$SUSPEND_FILE" "70"
assert_file "clamp: post does not clamp/write" "$FAKE_SYSFS" "0"

# 8. ectool is a READ source in pre only; post must never invoke it.
reset_case
rm -f "$FAKE_SYSFS"
run_hook pre suspend
assert_file "ectool: pre reads via ectool" "$STATE_DIR/state" "100"
assert_file "ectool: handoff stores ectool reading" "$SUSPEND_FILE" "100"
: > "$ECTOOL_LOG"
run_hook post suspend
assert_no_bus_or_led_writes "ectool post"
assert_file "ectool: state retained" "$STATE_DIR/state" "100"
assert_resume_flag "ectool: resume flag written" "suspend"

# 9. Without C640_KBD_HANDOFF_DIR, one active local graphical session (checked
#    with show-session + show-seat ActiveSession) supplies the uid.  The
#    handoff lands in $RUN_USER_ROOT/<uid>, 0600 and chowned to that user.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_file "loginctl: suspend handoff in uid runtime dir" "$_user_dir/c640-kbd-backlight.suspend" "7"
assert_mode "loginctl: suspend handoff 0600" "600" "$_user_dir/c640-kbd-backlight.suspend"
assert_owner "loginctl: suspend handoff chowned to session user" "$(id -u):$(id -g)" "$_user_dir/c640-kbd-backlight.suspend"
assert_file "loginctl: pre pins the chosen uid root-only" "$STATE_DIR/session-uid" "$(id -u)"
assert_mode "loginctl: cycle uid file is 0600" "600" "$STATE_DIR/session-uid"
# fchmod/fchown now happen inside the pinned python helper, so the old
# pathname-based chmod/chown log assertions would be vacuous.  The positive
# evidence is the `OK dev:ino` record plus the real stat mode/owner above;
# failpoints 9u/9y make the fchown/fchmod steps independently falsifiable.
assert_log_matches "loginctl: suspend publish identity recorded" "$PUBLISH_OUT" '^OK [0-9]+:[0-9]+$'
assert_publish_identity "loginctl: suspend identity matches inode" "$_user_dir/c640-kbd-backlight.suspend"
assert_log_matches "loginctl: selected session/seat logged" "$HOOK_ERR" "selected session 3 on seat seat0 for uid $(id -u)"
assert_log_matches "loginctl: handoff path logged" "$HOOK_ERR" "pre handoff dir $_user_dir for uid $(id -u)"
assert_log_matches "loginctl: show-session consulted" "$LOGINCTL_LOG" '^loginctl show-session 3$'
assert_log_matches "loginctl: show-seat ActiveSession consulted" "$LOGINCTL_LOG" '^loginctl show-seat seat0 -p ActiveSession$'
printf '0\n' > "$FAKE_SYSFS"
: > "$CHMOD_LOG"
: > "$CHOWN_LOG"
run_hook post suspend
assert_file "loginctl: post leaves sysfs alone" "$FAKE_SYSFS" "0"
assert_file "loginctl: state retained" "$STATE_DIR/state" "7"
assert_mode "loginctl: resume handoff 0600" "600" "$_user_dir/c640-kbd-backlight.resume"
assert_owner "loginctl: resume handoff chowned to session user" "$(id -u):$(id -g)" "$_user_dir/c640-kbd-backlight.resume"
assert_log_matches "loginctl: resume publish identity recorded" "$PUBLISH_OUT" '^OK [0-9]+:[0-9]+$'
assert_publish_identity "loginctl: resume identity matches inode" "$_user_dir/c640-kbd-backlight.resume"
assert_log_matches "loginctl: post handoff path logged" "$HOOK_ERR" "post handoff dir $_user_dir for uid $(id -u)"
if grep -q 'list-sessions --no-legend' "$LOGINCTL_LOG"; then
    ok "loginctl list-sessions --no-legend consulted"
else
    bad "loginctl was not consulted: $(cat "$LOGINCTL_LOG")"
fi
assert_empty_log "no gdbus calls (loginctl case)" "$GDBUS_LOG"
assert_empty_log "no sudo calls (loginctl case)" "$SUDO_LOG"
assert_empty_log "no ectool calls (loginctl case)" "$ECTOOL_LOG"

# 9b. A local graphical user session plus an IDLE SSH session.  The old
#     IDLE=yes/CLASS=active heuristic picked the SSH user (nobody); the
#     explicit Active/Remote/Class/Type/Seat properties must pick the local
#     graphical uid instead.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=idle-ssh
_nobody_uid="$(id -u nobody)"
mkdir -p "$RUN_USER_ROOT/$_nobody_uid"
chmod 700 "$RUN_USER_ROOT/$_nobody_uid"
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_file "idle-ssh: handoff in local graphical user's dir" "$_user_dir/c640-kbd-backlight.suspend" "7"
assert_absent "idle-ssh: no handoff in idle SSH user's dir" "$RUN_USER_ROOT/$_nobody_uid/c640-kbd-backlight.suspend"
assert_log_matches "idle-ssh: show-session checked both sessions" "$LOGINCTL_LOG" '^loginctl show-session 4$'
assert_log_matches "idle-ssh: selected session 3 on seat0" "$HOOK_ERR" "selected session 3 on seat seat0 for uid $(id -u)"
printf '0\n' > "$FAKE_SYSFS"
run_hook post suspend
if grep -Eq '^[0-9]+ suspend$' "$_user_dir/c640-kbd-backlight.resume"; then
    ok "idle-ssh: resume flag written for graphical user"
else
    bad "idle-ssh: no valid resume flag in graphical user's dir ($(cat "$_user_dir/c640-kbd-backlight.resume" 2> /dev/null))"
fi
assert_absent "idle-ssh: no resume flag in SSH user's dir" "$RUN_USER_ROOT/$_nobody_uid/c640-kbd-backlight.resume"
assert_mode "idle-ssh: resume handoff only in graphical dir" "600" "$_user_dir/c640-kbd-backlight.resume"
assert_empty_log "idle-ssh: no gdbus calls" "$GDBUS_LOG"

# 9c. Greeter + user on the same seat: the greeter (Class=greeter) is never
#     a handoff owner even though it is Active=yes and local.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=greeter-user
mkdir -p "$RUN_USER_ROOT/$_nobody_uid"
chmod 700 "$RUN_USER_ROOT/$_nobody_uid"
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_file "greeter+user: handoff in the user session dir" "$_user_dir/c640-kbd-backlight.suspend" "7"
assert_absent "greeter+user: no handoff in greeter's dir" "$RUN_USER_ROOT/$_nobody_uid/c640-kbd-backlight.suspend"
assert_log_matches "greeter+user: show-session checked greeter" "$LOGINCTL_LOG" '^loginctl show-session 5$'
assert_log_matches "greeter+user: selected the user session" "$HOOK_ERR" "selected session 6 on seat seat0 for uid $(id -u)"
assert_log_matches "greeter+user: seat active session verified" "$LOGINCTL_LOG" '^loginctl show-seat seat0 -p ActiveSession$'

# 9d. Two active local graphical sessions on two different seats: no single
#     owner is safe.  Both pre and post fail closed; root state is still
#     saved and neither runtime dir receives a handoff.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=ambiguous
_user_dir="$RUN_USER_ROOT/$(id -u)"
_other_dir="$RUN_USER_ROOT/$_nobody_uid"
mkdir -p "$_user_dir" "$_other_dir"
chmod 700 "$_user_dir" "$_other_dir"
run_hook pre suspend
assert_file "ambiguous: root state still saved" "$STATE_DIR/state" "7"
assert_absent "ambiguous: no suspend handoff in seat0 user dir" "$_user_dir/c640-kbd-backlight.suspend"
assert_absent "ambiguous: no suspend handoff in seat1 user dir" "$_other_dir/c640-kbd-backlight.suspend"
assert_absent "ambiguous: no cycle uid pinned" "$STATE_DIR/session-uid"
assert_log_matches "ambiguous: fail-closed WARN names 2 candidates" "$HOOK_ERR" 'session selection fail-closed: 2 candidates'
assert_log_matches "ambiguous: fail-closed WARN names both sessions" "$HOOK_ERR" 'session 10 on seat seat0, session 11 on seat seat1'
assert_log_matches "ambiguous: show-session checked both seats" "$LOGINCTL_LOG" '^loginctl show-session 11$'
run_hook post suspend
assert_absent "ambiguous: no resume flag in seat0 user dir" "$_user_dir/c640-kbd-backlight.resume"
assert_absent "ambiguous: no resume flag in seat1 user dir" "$_other_dir/c640-kbd-backlight.resume"
assert_log_matches "ambiguous: post fails closed without cycle uid" "$HOOK_ERR" 'no cycle uid file'

# 9e. pre/post split: the session changes between the two phases.  post
#     WARNs about the change but still writes to the uid pinned by pre.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
STUB_LOGINCTL_MODE=pre-post-other
: > "$HOOK_ERR"
run_hook post suspend
if grep -Eq '^[0-9]+ suspend$' "$_user_dir/c640-kbd-backlight.resume"; then
    ok "pre/post split: resume flag uses pre's uid dir"
else
    bad "pre/post split: no valid resume flag in pre's uid dir ($(cat "$_user_dir/c640-kbd-backlight.resume" 2> /dev/null))"
fi
assert_log_matches "pre/post split: WARN reports the changed session" "$HOOK_ERR" 'session changed since pre'
assert_absent "pre/post split: no resume flag in the new session's dir" "$RUN_USER_ROOT/$_nobody_uid/c640-kbd-backlight.resume"

# 9f. SUDO_USER is only a hint at most: a sudo issued from an SSH session
#     must not override the loginctl-verified local graphical user.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=idle-ssh
HOOK_SUDO_USER="$(id -nu nobody)"
mkdir -p "$RUN_USER_ROOT/$_nobody_uid"
chmod 700 "$RUN_USER_ROOT/$_nobody_uid"
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_file "SUDO_USER hint: handoff still in graphical user's dir" "$_user_dir/c640-kbd-backlight.suspend" "7"
assert_absent "SUDO_USER hint: no handoff in SUDO_USER's dir" "$RUN_USER_ROOT/$_nobody_uid/c640-kbd-backlight.suspend"

# 9g. Runtime dir validation: pre/post must never create, chmod or chown a
#     user runtime dir.  Missing, wrong-owner or world-writable dirs fail
#     closed with a WARN while the root diagnostic snapshot is still saved.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=bad-dir-missing
run_hook pre suspend
assert_file "runtime dir missing: root state still saved" "$STATE_DIR/state" "7"
assert_absent "runtime dir missing: no handoff" "$RUN_USER_ROOT/$_nobody_uid/c640-kbd-backlight.suspend"
assert_absent "runtime dir missing: hook did not create the dir" "$RUN_USER_ROOT/$_nobody_uid"
assert_log_matches "runtime dir missing: fail-closed WARN" "$HOOK_ERR" 'runtime dir .* missing/insecure'

reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=bad-dir-owner
mkdir -p "$RUN_USER_ROOT/$_nobody_uid"
chmod 700 "$RUN_USER_ROOT/$_nobody_uid"
run_hook pre suspend
assert_absent "runtime dir wrong owner: no handoff" "$RUN_USER_ROOT/$_nobody_uid/c640-kbd-backlight.suspend"
assert_log_matches "runtime dir wrong owner: fail-closed WARN" "$HOOK_ERR" 'runtime dir .* missing/insecure'
assert_mode "runtime dir wrong owner: hook did not chmod it" "700" "$RUN_USER_ROOT/$_nobody_uid"
assert_empty_log "runtime dir wrong owner: hook did not chown it" "$CHOWN_LOG"

reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=bad-dir-mode
_user_dir="$RUN_USER_ROOT/$(id -u)"
chmod 777 "$_user_dir"
run_hook pre suspend
assert_absent "runtime dir world-writable: no handoff" "$_user_dir/c640-kbd-backlight.suspend"
assert_log_matches "runtime dir world-writable: fail-closed WARN" "$HOOK_ERR" 'runtime dir .* missing/insecure'
assert_mode "runtime dir world-writable: hook did not tighten it" "777" "$_user_dir"

# post validates the pinned uid's runtime dir too.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
chmod 777 "$_user_dir"
: > "$HOOK_ERR"
run_hook post suspend
assert_absent "runtime dir invalidated before post: no resume flag" "$_user_dir/c640-kbd-backlight.resume"
assert_log_matches "runtime dir invalidated before post: fail-closed WARN" "$HOOK_ERR" 'runtime dir .* missing/insecure'

# 9h. State=closing is not a live graphical session either.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=closing
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_absent "closing session: no handoff" "$_user_dir/c640-kbd-backlight.suspend"
assert_log_matches "closing session: fail-closed WARN" "$HOOK_ERR" 'session selection fail-closed: no active local graphical user session'

# 9i. Load-bearing gates.  Each stub below fails ONLY ONE gate (Active /
#     Remote / Class / Type / seat ActiveSession): all other properties are in
#     the PASS state and the session IS its seat's ActiveSession.  Removing
#     that one gate must turn the expected fail-closed result into a handoff.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=active-no
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_absent "gate Active=no: no handoff" "$_user_dir/c640-kbd-backlight.suspend"
assert_absent "gate Active=no: no cycle uid pinned" "$STATE_DIR/session-uid"
assert_log_matches "gate Active=no: fail-closed WARN" "$HOOK_ERR" 'session selection fail-closed: no active local graphical user session'

reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=remote-yes
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_absent "gate Remote=yes: no handoff" "$_user_dir/c640-kbd-backlight.suspend"
assert_absent "gate Remote=yes: no cycle uid pinned" "$STATE_DIR/session-uid"
assert_log_matches "gate Remote=yes: fail-closed WARN" "$HOOK_ERR" 'session selection fail-closed: no active local graphical user session'

reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=type-tty
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_absent "gate Type=tty: no handoff" "$_user_dir/c640-kbd-backlight.suspend"
assert_absent "gate Type=tty: no cycle uid pinned" "$STATE_DIR/session-uid"
assert_log_matches "gate Type=tty: fail-closed WARN" "$HOOK_ERR" 'session selection fail-closed: no active local graphical user session'

# Two graphical user sessions on the SAME seat, both otherwise perfect.  Only
# show-seat ActiveSession distinguishes them; removing that comparison makes
# two candidates and fail-closes instead of selecting session 41.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=seat-active
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_file "gate seat ActiveSession: handoff written" "$_user_dir/c640-kbd-backlight.suspend" "7"
assert_log_matches "gate seat ActiveSession: chose the seat's active session" "$HOOK_ERR" "selected session 41 on seat seat0 for uid $(id -u)"
assert_log_matches "gate seat ActiveSession: second session was examined" "$LOGINCTL_LOG" '^loginctl show-session 42$'
assert_log_matches "gate seat ActiveSession: show-seat consulted" "$LOGINCTL_LOG" '^loginctl show-seat seat0 -p ActiveSession$'

# Greeter and user on the same seat; the GREETER is the seat's ActiveSession,
# is Active=yes / Remote=no / Type=x11, so only Class=greeter excludes it.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=greeter-active
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_absent "gate Class=greeter: no handoff for greeter" "$_user_dir/c640-kbd-backlight.suspend"
assert_absent "gate Class=greeter: no cycle uid pinned" "$STATE_DIR/session-uid"
assert_log_matches "gate Class=greeter: greeter was examined" "$LOGINCTL_LOG" '^loginctl show-session 50$'
assert_log_matches "gate Class=greeter: show-seat agreed with greeter" "$LOGINCTL_LOG" '^loginctl show-seat seat0 -p ActiveSession$'
assert_log_matches "gate Class=greeter: fail-closed WARN" "$HOOK_ERR" 'session selection fail-closed: no active local graphical user session'

# 9j. Cycle uid pin file: 0644 must fail closed in post; a stale pin from a
#     previous cycle must be cleared before this cycle's failed selection so
#     post cannot reuse it.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
# Tolerate a missing pin under a broken hook: the assertions below must still
# run (and fail) instead of aborting the whole suite via `set -e`.
chmod 644 "$STATE_DIR/session-uid" 2> /dev/null || true
: > "$HOOK_ERR"
run_hook post suspend
assert_absent "cycle uid 0644: no resume flag" "$_user_dir/c640-kbd-backlight.resume"
assert_log_matches "cycle uid 0644: post fails closed" "$HOOK_ERR" "$STATE_DIR/session-uid is not 0600"

reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_file "stale pin setup: previous cycle pinned uid" "$STATE_DIR/session-uid" "$(id -u)"
rm -f "$_user_dir/c640-kbd-backlight.suspend" "$_user_dir/c640-kbd-backlight.resume"
STUB_LOGINCTL_MODE=closing
: > "$HOOK_ERR"
run_hook pre suspend
assert_absent "stale pin: pre cleared the pin after failed selection" "$STATE_DIR/session-uid"
assert_absent "stale pin: no new handoff" "$_user_dir/c640-kbd-backlight.suspend"
: > "$HOOK_ERR"
run_hook post suspend
assert_absent "stale pin: post did not reuse the old uid" "$_user_dir/c640-kbd-backlight.resume"
assert_log_matches "stale pin: post fails closed without cycle uid" "$HOOK_ERR" 'no cycle uid file'

# 9k. post's _session_uid call is verification only.  A 0-candidate or
#     multi-candidate answer must NOT log "no handoff": post still publishes
#     the resume flag using the uid pinned by pre.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
STUB_LOGINCTL_MODE=closing
: > "$HOOK_ERR"
run_hook post suspend
if grep -Eq '^[0-9]+ suspend$' "$_user_dir/c640-kbd-backlight.resume"; then
    ok "post verification (0 candidates): resume flag still written"
else
    bad "post verification (0 candidates): no resume flag ($(cat "$_user_dir/c640-kbd-backlight.resume" 2> /dev/null))"
fi
assert_log_matches "post verification (0 candidates): pinned uid still used" "$HOOK_ERR" 'verification only; pinned uid still used'
if grep -q 'no handoff' "$HOOK_ERR"; then
    bad "post verification (0 candidates): misleading 'no handoff' log"
else
    ok "post verification (0 candidates): no misleading 'no handoff' log"
fi

reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
STUB_LOGINCTL_MODE=ambiguous
: > "$HOOK_ERR"
run_hook post suspend
if grep -Eq '^[0-9]+ suspend$' "$_user_dir/c640-kbd-backlight.resume"; then
    ok "post verification (2 candidates): resume flag still written"
else
    bad "post verification (2 candidates): no resume flag ($(cat "$_user_dir/c640-kbd-backlight.resume" 2> /dev/null))"
fi
assert_log_matches "post verification (2 candidates): pinned uid still used" "$HOOK_ERR" 'verification only; pinned uid still used'
if grep -q 'no handoff' "$HOOK_ERR"; then
    bad "post verification (2 candidates): misleading 'no handoff' log"
else
    ok "post verification (2 candidates): no misleading 'no handoff' log"
fi

# 9l. A vanished handoff dir must not be replaced by a /tmp stand-in: the
#     [ -d ] guard in _runtime_dir_ok / _publish_handoff rejects it before
#     any fd is opened.  The fd publisher never calls mktemp, so the oracle
#     inspects the fallback dir entry set directly (no vacuous log check).
reset_case
HOOK_HANDOFF_DIR="$TMP_DIR/vanished-handoff"
HOOK_TMPDIR="$FALLBACK_DIR"
_fallback_before="$(snapshot_dir "$FALLBACK_DIR")"
run_hook pre suspend
assert_absent "tmp fallback: no handoff at the vanished target" "$TMP_DIR/vanished-handoff/c640-kbd-backlight.suspend"
assert_absent "tmp fallback: nothing written into TMPDIR" "$FALLBACK_DIR/c640-kbd-backlight.suspend"
assert_snapshot_same "tmp fallback: fallback entry set unchanged" "$FALLBACK_DIR" "$_fallback_before"
assert_no_handoff_publish "tmp fallback: no publish record"
assert_log_matches "tmp fallback: fail-closed WARN" "$HOOK_ERR" 'handoff skipped \(fail-closed\)'

# 9m. Sensitivity for the finding #1 schema bug: flip ONLY the uid key from
#     the real `User=` to the legacy `UID=`.  Every other property (including
#     Active/Remote/Class/Type/Seat/State and show-seat) stays in the PASS
#     state, so a hook that reads the wrong key must fail closed here while
#     all the real-schema cases above stay green.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
STUB_UID_FIELD=UID
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_file "legacy-UID schema: root state still saved" "$STATE_DIR/state" "7"
assert_absent "legacy-UID schema: no suspend handoff" "$_user_dir/c640-kbd-backlight.suspend"
assert_absent "legacy-UID schema: no cycle uid pinned" "$STATE_DIR/session-uid"
assert_log_matches "legacy-UID schema: 0-candidate WARN" "$HOOK_ERR" 'session selection fail-closed: no active local graphical user session'
assert_log_matches "legacy-UID schema: show-session still consulted" "$LOGINCTL_LOG" '^loginctl show-session 3$'
printf '0\n' > "$FAKE_SYSFS"
run_hook post suspend
assert_absent "legacy-UID schema: no resume flag" "$_user_dir/c640-kbd-backlight.resume"

# 9n. Session IDs are strings, not decimal-only: systemd's session_id_valid()
#     accepts [A-Za-z0-9]+, e.g. c1.  The hook must call show-session c1,
#     accept ActiveSession=c1, select it, pin the uid in pre and write the
#     resume flag in post.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=c-prefix
_user_dir="$RUN_USER_ROOT/$(id -u)"
assert_eq "c-prefix id: _session_uid resolves uid" "$(id -u)" "$(_probe_session_uid)"
run_hook pre suspend
assert_file "c-prefix id: suspend handoff written" "$_user_dir/c640-kbd-backlight.suspend" "7"
assert_file "c-prefix id: uid pinned in pre" "$STATE_DIR/session-uid" "$(id -u)"
assert_log_matches "c-prefix id: selected session c1 on seat seat0" "$HOOK_ERR" "selected session c1 on seat seat0 for uid $(id -u)"
assert_log_matches "c-prefix id: show-session c1 consulted" "$LOGINCTL_LOG" '^loginctl show-session c1$'
assert_log_matches "c-prefix id: show-seat ActiveSession consulted" "$LOGINCTL_LOG" '^loginctl show-seat seat0 -p ActiveSession$'
printf '0\n' > "$FAKE_SYSFS"
: > "$HOOK_ERR"
run_hook post suspend
if grep -Eq '^[0-9]+ suspend$' "$_user_dir/c640-kbd-backlight.resume"; then
    ok "c-prefix id: post wrote resume flag using pinned uid"
else
    bad "c-prefix id: no valid resume flag ($(cat "$_user_dir/c640-kbd-backlight.resume" 2> /dev/null))"
fi
assert_log_matches "c-prefix id: post used pinned uid dir" "$HOOK_ERR" "post handoff dir $_user_dir for uid $(id -u)"

# 9o. Negative session-ID cases: special characters, reserved aliases and
#     whitespace-bearing IDs must never be passed to `loginctl show-session`,
#     and _session_uid must fail closed with 0 candidates / no handoff.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=ambiguous-ids
assert_eq "ambiguous ids: _session_uid returns empty" "" "$(_probe_session_uid)"
assert_log_matches "ambiguous ids: 0-candidate WARN" "$HOOK_ERR" 'session selection fail-closed: no active local graphical user session'
for _bad_id in 'c;1' '../x' 'self' 'auto' 'c 1'; do
    if grep -Fqx "loginctl show-session $_bad_id" "$LOGINCTL_LOG"; then
        bad "ambiguous ids: show-session called for bad id '$_bad_id'"
    else
        ok "ambiguous ids: show-session never called for '$_bad_id'"
    fi
done
if grep -Eq '^loginctl show-session .*[[:space:]]' "$LOGINCTL_LOG"; then
    bad "ambiguous ids: show-session called with a whitespace-bearing id"
else
    ok "ambiguous ids: show-session never called with whitespace in id"
fi
: > "$HOOK_ERR"
run_hook pre suspend
assert_absent "ambiguous ids: no suspend handoff" "$RUN_USER_ROOT/$(id -u)/c640-kbd-backlight.suspend"
assert_absent "ambiguous ids: no cycle uid pinned" "$STATE_DIR/session-uid"
assert_file "ambiguous ids: root state still saved" "$STATE_DIR/state" "7"

# 9q. ROOT WRITE BOUNDARY - destination is a symlink to an OUTSIDE directory.
# The fd publisher rejects it via lstat(dir_fd) before creating any temp.
# The independent oracle compares the outside directory's full entry set
# (name/dev/ino/mode/uid/gid/sha256), so an empty log alone cannot pass.
reset_case
_target="$TMP_DIR/boundary-target"
mkdir -p "$_target"
printf 'SENTINEL\n' > "$_target/sentinel"
ln -s "$_target" "$SUSPEND_FILE"
_target_before="$(snapshot_dir "$_target")"
_handoff_before="$(snapshot_dir "$HANDOFF_DIR")"
run_hook pre suspend
if [ -L "$SUSPEND_FILE" ]; then
    ok "symlink-to-dir: destination symlink left intact"
else
    bad "symlink-to-dir: destination symlink was replaced/followed"
fi
assert_snapshot_same "symlink-to-dir: outside dir inode/content unchanged" "$_target" "$_target_before"
assert_snapshot_same "symlink-to-dir: handoff dir unchanged" "$HANDOFF_DIR" "$_handoff_before"
assert_no_handoff_publish "symlink-to-dir: guard rejected before publish"
assert_empty_log "symlink-to-dir: cp never called" "$CP_LOG"
assert_log_matches "symlink-to-dir: fail-closed WARN names unsafe entry" "$HOOK_ERR" 'unsafe destination entry'
assert_file "symlink-to-dir: root state still saved" "$STATE_DIR/state" "7"

# The same boundary applies to the post-phase resume flag.
reset_case
_target="$TMP_DIR/boundary-target"
mkdir -p "$_target"
ln -s "$_target" "$RESUME_FILE"
_target_before="$(snapshot_dir "$_target")"
_handoff_before="$(snapshot_dir "$HANDOFF_DIR")"
run_hook post suspend
if [ -L "$RESUME_FILE" ]; then
    ok "symlink-to-dir: resume destination symlink left intact"
else
    bad "symlink-to-dir: resume destination symlink was replaced/followed"
fi
assert_snapshot_same "symlink-to-dir: post wrote nothing into outside dir" "$_target" "$_target_before"
assert_snapshot_same "symlink-to-dir: post handoff dir unchanged" "$HANDOFF_DIR" "$_handoff_before"
assert_no_handoff_publish "symlink-to-dir: post guard rejected before publish"
assert_empty_log "symlink-to-dir: post never called cp" "$CP_LOG"
assert_log_matches "symlink-to-dir: post fail-closed WARN" "$HOOK_ERR" 'unsafe destination entry'

# Same destination, but swapped AFTER the fd was opened (the old TOCTOU
# sensitivity case).  The `dir-swap` failpoint renames the whole handoff dir
# aside and creates a fresh dir at the old pathname.  Because the publisher
# holds the pinned fd, the file lands in the ORIGINAL dir and the replacement
# dir stays empty: this is the fd-based equivalent of `mv -T` protection.
reset_case
HOOK_FAILPOINT='dir-swap'
_replacement_before="$(snapshot_dir "$HANDOFF_DIR")"
run_hook pre suspend
if [ -f "$HANDOFF_DIR.swapped/${SUSPEND_FILE##*/}" ]; then
    ok "dir-swap: handoff published into the pinned directory"
else
    bad "dir-swap: handoff was diverted by the pathname swap"
fi
assert_snapshot_same "dir-swap: new dir at original path stays empty" \
    "$HANDOFF_DIR" "$_replacement_before"
assert_file "dir-swap: pinned-dir handoff content" "$HANDOFF_DIR.swapped/${SUSPEND_FILE##*/}" "7"
assert_publish_identity "dir-swap: identity matches pinned inode" "$HANDOFF_DIR.swapped/${SUSPEND_FILE##*/}"
assert_no_handoff_temp "dir-swap: no temp in pinned dir" "$HANDOFF_DIR.swapped"
assert_no_handoff_temp "dir-swap: no temp in replacement dir" "$HANDOFF_DIR"
assert_empty_log "dir-swap: cp never called" "$CP_LOG"

# 9r. ROOT WRITE BOUNDARY - destination is a regular symlink to an external
# file.  The old cp fallback dereferenced it and overwrote the victim; the
# dir_fd lstat guard must reject the symlink before any temp is created.
reset_case
_outside="$TMP_DIR/boundary-outside"
mkdir -p "$_outside"
printf 'ORIGINAL\n' > "$_outside/victim"
ln -s "$_outside/victim" "$SUSPEND_FILE"
_outside_before="$(snapshot_dir "$_outside")"
run_hook pre suspend
assert_file "symlink-to-file: external victim not overwritten" "$_outside/victim" "ORIGINAL"
assert_snapshot_same "symlink-to-file: outside dir inode/content unchanged" "$_outside" "$_outside_before"
if [ -L "$SUSPEND_FILE" ]; then
    ok "symlink-to-file: destination symlink left intact"
else
    bad "symlink-to-file: destination symlink was replaced/followed"
fi
assert_no_handoff_publish "symlink-to-file: guard rejected before publish"
assert_empty_log "symlink-to-file: cp never called" "$CP_LOG"
assert_log_matches "symlink-to-file: fail-closed WARN names unsafe entry" "$HOOK_ERR" 'unsafe destination entry'
assert_no_handoff_temp "symlink-to-file: no temp left in handoff dir"

# Rename failure after a valid temp: no handoff, no cp fallback, and the
# handoff dir entry set is byte/inode-identical to the pre-run snapshot.
rm -f "$SUSPEND_FILE"
HOOK_FAILPOINT=rename
_handoff_before="$(snapshot_dir "$HANDOFF_DIR")"
run_hook pre suspend
assert_absent "symlink-to-file: failed rename publishes no handoff" "$SUSPEND_FILE"
assert_snapshot_same "symlink-to-file: rename fail left dir identical" "$HANDOFF_DIR" "$_handoff_before"
assert_no_handoff_publish "symlink-to-file: no publish record after rename failure"
assert_empty_log "symlink-to-file: no cp fallback after rename failure" "$CP_LOG"
assert_no_handoff_temp "symlink-to-file: no temp after rename failure"
assert_log_matches "symlink-to-file: rename fail reason recorded" "$HOOK_ERR" 'injected rename failure'

# 9s. ROOT WRITE BOUNDARY - destination is a real directory.  The dir_fd
# guard must reject it explicitly before creating a temp.
reset_case
mkdir -p "$SUSPEND_FILE"
printf 'SENTINEL\n' > "$SUSPEND_FILE/keep"
_dest_before="$(snapshot_dir "$SUSPEND_FILE")"
run_hook pre suspend
if [ -d "$SUSPEND_FILE" ] && [ ! -L "$SUSPEND_FILE" ]; then
    ok "real-dir: destination directory left intact"
else
    bad "real-dir: destination directory was replaced"
fi
assert_snapshot_same "real-dir: destination dir inode/content unchanged" "$SUSPEND_FILE" "$_dest_before"
assert_no_handoff_publish "real-dir: guard rejected before publish"
assert_no_handoff_temp "real-dir: no temp left in handoff dir"
assert_empty_log "real-dir: cp never called" "$CP_LOG"
assert_log_matches "real-dir: fail-closed WARN names unsafe entry" "$HOOK_ERR" 'unsafe destination entry'

# 9t. ROOT WRITE BOUNDARY - rename fails after a valid temp.  Fail closed
# with no handoff, no publish record, no cp fallback, a WARN and zero
# mutation of the handoff directory entry set.
reset_case
HOOK_FAILPOINT=rename
_handoff_before="$(snapshot_dir "$HANDOFF_DIR")"
run_hook pre suspend
assert_absent "rename fail: no suspend handoff published" "$SUSPEND_FILE"
assert_file "rename fail: root state still saved" "$STATE_DIR/state" "7"
assert_snapshot_same "rename fail: handoff dir entry set unchanged" "$HANDOFF_DIR" "$_handoff_before"
assert_no_handoff_publish "rename fail: no OK record"
assert_log_matches "rename fail: WARN cannot publish" "$HOOK_ERR" 'cannot publish .*c640-kbd-backlight\.suspend'
assert_log_matches "rename fail: reason recorded" "$HOOK_ERR" 'injected rename failure'
assert_empty_log "rename fail: no cp fallback" "$CP_LOG"
assert_no_handoff_temp "rename fail: temp cleaned up"

# 9u. FAILPOINT `ownership`: fchown in the pinned helper fails.  This must go
# through uid/gid resolution: with an explicit HANDOFF_DIR override the helper
# intentionally skips owner checks, so that path cannot falsify fchown at all.
# The old code merely warned and kept publishing with the wrong owner; now
# there must be no handoff and zero mutation of the runtime directory.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
HOOK_FAILPOINT=ownership
_user_dir="$RUN_USER_ROOT/$(id -u)"
_dir_before="$(snapshot_dir "$_user_dir")"
run_hook pre suspend
assert_absent "ownership fail: no suspend handoff" "$_user_dir/c640-kbd-backlight.suspend"
assert_no_handoff_publish "ownership fail: no OK record"
assert_snapshot_same "ownership fail: handoff dir unchanged" "$_user_dir" "$_dir_before"
assert_log_matches "ownership fail: WARN names fchown failure" "$HOOK_ERR" 'injected fchown failure'
assert_file "ownership fail: fchown syscall reached" "$HOOK_MARKER_DIR/fchown" "called"
assert_no_handoff_temp "ownership fail: original temp cleaned up" "$_user_dir"
assert_file "ownership fail: root state still saved" "$STATE_DIR/state" "7"

# 9v. `id -g` fails while `id -nu` still succeeds: resolve_handoff_dir must
# fail closed BEFORE any temp is created (gid is part of the publish contract).
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
STUB_ID_G_FAIL=1
_user_dir="$RUN_USER_ROOT/$(id -u)"
_dir_before="$(snapshot_dir "$_user_dir")"
run_hook pre suspend
assert_absent "id-g fail: no suspend handoff" "$_user_dir/c640-kbd-backlight.suspend"
assert_no_handoff_publish "id-g fail: no OK record"
assert_snapshot_same "id-g fail: runtime dir unchanged" "$_user_dir" "$_dir_before"
assert_log_matches "id-g fail: WARN names gid failure" "$HOOK_ERR" 'cannot resolve gid'
assert_file "id-g fail: root state still saved" "$STATE_DIR/state" "7"

# 9w. FAILPOINT `temp-symlink`: the temp pathname is swapped for a symlink to
# an outside victim after the fd is opened.  The helper must compare the
# lstat inode with its own fstat inode and refuse the rename.  Cleanup must
# NOT unlink the foreign inode, so the symlink survives untouched.
reset_case
_outside="$TMP_DIR/boundary-outside"
mkdir -p "$_outside"
printf 'ORIGINAL\n' > "$_outside/victim"
HOOK_FAILPOINT='temp-symlink'
HOOK_OUTSIDE="$_outside/victim"
_outside_before="$(snapshot_dir "$_outside")"
run_hook pre suspend
assert_absent "temp-symlink: no handoff published" "$SUSPEND_FILE"
assert_no_handoff_publish "temp-symlink: no OK record"
assert_snapshot_same "temp-symlink: outside victim unchanged" "$_outside" "$_outside_before"
assert_log_matches "temp-symlink: WARN names identity mismatch" "$HOOK_ERR" 'temp identity changed'
_temp_path="$(find "$HANDOFF_DIR" -maxdepth 1 -name '.c640-kbd-handoff.*' -print -quit 2> /dev/null || echo '')"
if [ -n "$_temp_path" ] && [ -L "$_temp_path" ]; then
    ok "temp-symlink: foreign symlink left in place (only original inode cleaned)"
else
    bad "temp-symlink: foreign temp was removed or not a symlink ($_temp_path)"
fi
assert_eq "temp-symlink: symlink still points at outside victim" "$_outside/victim" \
    "$(readlink "$_temp_path" 2> /dev/null || echo '')"
assert_file "temp-symlink: root state still saved" "$STATE_DIR/state" "7"

# 9x. FAILPOINT `temp-regular`: the temp pathname is swapped for a DIFFERENT
# regular inode carrying foreign content.  Same inode check must refuse the
# rename; the foreign inode must not be cleaned up by the failing publisher.
reset_case
HOOK_FAILPOINT='temp-regular'
run_hook pre suspend
assert_absent "temp-regular: no handoff published" "$SUSPEND_FILE"
assert_no_handoff_publish "temp-regular: no OK record"
assert_log_matches "temp-regular: WARN names identity mismatch" "$HOOK_ERR" 'temp identity changed'
_temp_path="$(find "$HANDOFF_DIR" -maxdepth 1 -name '.c640-kbd-handoff.*' -print -quit 2> /dev/null || echo '')"
if [ -n "$_temp_path" ] && [ -f "$_temp_path" ] && [ ! -L "$_temp_path" ]; then
    ok "temp-regular: foreign regular temp left in place"
else
    bad "temp-regular: foreign temp missing or not regular ($_temp_path)"
fi
assert_file "temp-regular: foreign temp content untouched" "$_temp_path" "FOREIGN"
assert_file "temp-regular: root state still saved" "$STATE_DIR/state" "7"

# 9y. FAILPOINT `mode`: fchmod is injected to fail, so the helper must abort
# before rename.  The old code ignored a chmod failure and published anyway.
reset_case
HOOK_FAILPOINT=mode
_handoff_before="$(snapshot_dir "$HANDOFF_DIR")"
run_hook pre suspend
assert_absent "mode fail: no suspend handoff" "$SUSPEND_FILE"
assert_no_handoff_publish "mode fail: no OK record"
assert_snapshot_same "mode fail: handoff dir unchanged" "$HANDOFF_DIR" "$_handoff_before"
assert_log_matches "mode fail: WARN names fchmod failure" "$HOOK_ERR" 'injected fchmod failure'
assert_file "mode fail: fchmod syscall reached" "$HOOK_MARKER_DIR/fchmod" "called"
assert_no_handoff_temp "mode fail: original temp cleaned up"
assert_file "mode fail: root state still saved" "$STATE_DIR/state" "7"

# 9z. Rename failure in POST with an already-published suspend handoff: the
# successful suspend file must remain byte/inode-identical while the resume
# publish fails closed (no mutation, no OK, no temp).
reset_case
run_hook pre suspend
_handoff_before="$(snapshot_dir "$HANDOFF_DIR")"
: > "$PUBLISH_OUT"
: > "$HOOK_ERR"
HOOK_FAILPOINT=rename
run_hook post suspend
assert_snapshot_same "post rename fail: suspend handoff unchanged" "$HANDOFF_DIR" "$_handoff_before"
assert_absent "post rename fail: no resume handoff" "$RESUME_FILE"
assert_no_handoff_publish "post rename fail: no OK record"
assert_log_matches "post rename fail: WARN cannot publish" "$HOOK_ERR" 'cannot publish .*c640-kbd-backlight\.resume'
assert_log_matches "post rename fail: reason recorded" "$HOOK_ERR" 'injected rename failure'
assert_no_handoff_temp "post rename fail: temp cleaned up"

# 9aa. python3 unavailable: a new runtime dependency must FAIL CLOSED rather
# than silently falling back to the old pathname-based writer.
reset_case
STUB_PYTHON_FAIL=1
_handoff_before="$(snapshot_dir "$HANDOFF_DIR")"
run_hook pre suspend
assert_absent "python3 missing: no suspend handoff" "$SUSPEND_FILE"
assert_no_handoff_publish "python3 missing: no OK record"
assert_snapshot_same "python3 missing: handoff dir unchanged" "$HANDOFF_DIR" "$_handoff_before"
assert_log_matches "python3 missing: WARN names interpreter" "$HOOK_ERR" 'python3 unavailable'
assert_no_handoff_temp "python3 missing: no temp created"
assert_file "python3 missing: root state still saved" "$STATE_DIR/state" "7"
: > "$HOOK_ERR"
run_hook post suspend
assert_absent "python3 missing: no resume handoff" "$RESUME_FILE"
assert_log_matches "python3 missing: post also warns" "$HOOK_ERR" 'python3 unavailable'

# 9ab. Explicit HANDOFF_DIR override deliberately skips uid/gid checks, so the
# dirfd O_NOFOLLOW is the ONLY guard against a symlinked handoff directory.
# Removing it makes the helper follow the link and publish into the target.
reset_case
_link_dir="$TMP_DIR/handoff-link"
_target_dir="$TMP_DIR/real-handoff"
mkdir -p "$_target_dir"
ln -s "$_target_dir" "$_link_dir"
HOOK_HANDOFF_DIR="$_link_dir"
_target_before="$(snapshot_dir "$_target_dir")"
run_hook pre suspend
assert_absent "dir symlink: no handoff at override path" "$_link_dir/c640-kbd-backlight.suspend"
assert_absent "dir symlink: no handoff in target dir" "$_target_dir/c640-kbd-backlight.suspend"
assert_no_handoff_publish "dir symlink: no OK record"
assert_snapshot_same "dir symlink: target dir unchanged" "$_target_dir" "$_target_before"
assert_log_matches "dir symlink: fail-closed WARN" "$HOOK_ERR" 'cannot publish .*c640-kbd-backlight\.suspend'
assert_file "dir symlink: root state still saved" "$STATE_DIR/state" "7"
rm -rf "$_link_dir" "$_target_dir"

# 9ac. FAILPOINT `post-swap`: the published entry is replaced immediately
# after rename.  The post-verify inode/owner/mode check must catch it and
# fail closed, instead of emitting an OK record for a file we did not write.
reset_case
HOOK_FAILPOINT=post-swap
run_hook pre suspend
assert_file "post-swap: foreign entry not treated as handoff" "$SUSPEND_FILE" "FOREIGN"
assert_no_handoff_publish "post-swap: no OK record"
assert_log_matches "post-swap: WARN names identity mismatch" "$HOOK_ERR" 'published identity mismatch'
assert_no_handoff_temp "post-swap: no temp left"
assert_file "post-swap: root state still saved" "$STATE_DIR/state" "7"

# 9ad. Root creator: the temp starts owned by uid 0, then must be fchowned to
# the resolved non-root uid.  Verification must use the POST-fchown stat; the
# stale pre-chown stat used to make this fail closed in real root operation.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
HOOK_FAILPOINT='root-creator'
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_file "root-creator: handoff content" "$_user_dir/c640-kbd-backlight.suspend" "7"
assert_owner "root-creator: owner is resolved uid:gid" "$(id -u):$(id -g)" \
    "$_user_dir/c640-kbd-backlight.suspend"
assert_log_matches "root-creator: records OK dev:ino" "$PUBLISH_OUT" '^OK [0-9]+:[0-9]+$'
assert_publish_identity "root-creator: identity matches inode" \
    "$_user_dir/c640-kbd-backlight.suspend"
assert_no_handoff_temp "root-creator: no temp left" "$_user_dir"

# 9ae. FAILPOINT `post-mode`: published entry keeps its inode but its mode is
# changed after rename.  Post-verify must reject it AND clean the same inode.
reset_case
HOOK_FAILPOINT='post-mode'
run_hook pre suspend
assert_absent "post-mode: handoff removed" "$SUSPEND_FILE"
assert_no_handoff_publish "post-mode: no OK record"
assert_log_matches "post-mode: WARN mode mismatch" "$HOOK_ERR" 'published mode/size mismatch'
assert_no_handoff_temp "post-mode: no temp left"
assert_file "post-mode: root state still saved" "$STATE_DIR/state" "7"

# 9af. FAILPOINT `post-owner`: same inode, wrong owner after rename.  An
# unprivileged test cannot really chown away, so the oracle fakes the stat.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=real
HOOK_FAILPOINT='post-owner'
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_absent "post-owner: handoff removed" "$_user_dir/c640-kbd-backlight.suspend"
assert_no_handoff_publish "post-owner: no OK record"
assert_log_matches "post-owner: WARN owner mismatch" "$HOOK_ERR" 'published owner mismatch'
assert_no_handoff_temp "post-owner: no temp left" "$_user_dir"
assert_file "post-owner: root state still saved" "$STATE_DIR/state" "7"

# 9ag. FAILPOINT `post-dir-mode`: the pinned dir's mode changes after rename.
# The second dir-identity recheck must fail closed and remove the handoff.
reset_case
HOOK_FAILPOINT='post-dir-mode'
run_hook pre suspend
assert_absent "post-dir-mode: handoff removed" "$SUSPEND_FILE"
assert_no_handoff_publish "post-dir-mode: no OK record"
assert_log_matches "post-dir-mode: WARN dir identity changed" "$HOOK_ERR" \
    'handoff dir identity changed after rename'
assert_no_handoff_temp "post-dir-mode: no temp left"
assert_file "post-dir-mode: root state still saved" "$STATE_DIR/state" "7"

# 10. No resolvable session user: handoff is skipped, root state still saved.
reset_case
HOOK_HANDOFF_DIR=""
find "$RUN_USER_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
run_hook pre suspend
assert_file "no user: root state still saved" "$STATE_DIR/state" "7"
assert_absent "no user: no suspend handoff" "$SUSPEND_FILE"
assert_absent "no user: no handoff in runtime root" "$RUN_USER_ROOT/$(id -u)/c640-kbd-backlight.suspend"
assert_log_matches "no user: fail-closed WARN" "$HOOK_ERR" 'session selection fail-closed: no active local graphical user session'
run_hook post suspend
assert_absent "no user: no resume handoff" "$RESUME_FILE"
assert_log_matches "no user: post fails closed without cycle uid" "$HOOK_ERR" 'no cycle uid file'
assert_empty_log "no user: no gdbus calls" "$GDBUS_LOG"
assert_empty_log "no user: no sudo calls" "$SUDO_LOG"

# 11. Running post twice overwrites (not appends) the flag; content is atomic
#     and complete, with no leftover temp files.
reset_case
run_hook pre suspend
run_hook post suspend
run_hook post hibernate
lines="$(wc -l < "$RESUME_FILE" 2> /dev/null || echo 0)"
assert_eq "post twice: resume flag has exactly one line" "1" "$lines"
assert_resume_flag "post twice: last action wins" "hibernate"
assert_mode "post twice: resume flag still 0600" "600" "$RESUME_FILE"
if [ -n "$(find "$HANDOFF_DIR" -maxdepth 1 -name '.c640-kbd-handoff.*' -print -quit 2> /dev/null)" ]; then
    bad "post left a temporary handoff file behind"
else
    ok "post left no temporary handoff files"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
    exit 1
fi
