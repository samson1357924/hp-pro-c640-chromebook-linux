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
SUSPEND_FILE="$HANDOFF_DIR/c640-kbd-backlight.suspend"
RESUME_FILE="$HANDOFF_DIR/c640-kbd-backlight.resume"
mkdir -p "$STUB_DIR" "$STATE_DIR" "$HANDOFF_DIR" "$RUN_USER_ROOT"

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

# `loginctl list-sessions --no-legend` with the REAL column layout:
# SESSION UID USER SEAT LEADER CLASS TTY IDLE SINCE (USER is field 3).
cat > "$STUB_DIR/loginctl" << 'STUB'
#!/bin/sh
printf 'loginctl %s\n' "$*" >> "${STUB_LOGINCTL_LOG:-/dev/null}"
# SESSION UID USER SEAT LEADER CLASS TTY IDLE SINCE.  The first row is always
# "nobody" so a wrong resolution is visible in the handoff directory.
case "${STUB_LOGINCTL_MODE:-none}" in
    multi | prefer-idle | prefer-class)
        _class=user
        _idle=no
        case "${STUB_LOGINCTL_MODE}" in
            prefer-idle) _idle=yes ;;
            prefer-class) _class=active ;;
        esac
        printf '1 %s nobody seat0 100 user tty2 no 2026-11-22 08:00\n' "$(id -u nobody)"
        printf '2 %s %s seat0 101 %s tty7 %s 2026-11-22 09:00\n' \
            "${STUB_LOGINCTL_UID:-0}" "${STUB_LOGINCTL_USER:-root}" "$_class" "$_idle"
        ;;
esac
if [ "${STUB_LOGINCTL_OUTPUT:-none}" = "real" ]; then
    printf '3 %s %s seat0 4242 user tty2 no 2026-11-22 09:00\n' \
        "${STUB_LOGINCTL_UID:-0}" "${STUB_LOGINCTL_USER:-root}"
fi
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
# The hook calls `chmod 600` / `chown <uid>:<gid>` by bare command name in
# _atomic_write. These stubs log the arguments, then exec the real binaries so
# the mode/owner assertions still see the real effect.  They only record what
# this sandboxed unit test observes: a real system-sleep hook runs as root and
# chowns the handoff to the session user resolved by loginctl.
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
chmod +x "$STUB_DIR/gdbus" "$STUB_DIR/sudo" "$STUB_DIR/ectool" "$STUB_DIR/loginctl" \
    "$STUB_DIR/chmod" "$STUB_DIR/chown"

# --- harness ----------------------------------------------------------------
# Empty HOOK_HANDOFF_DIR means "unset": the hook must resolve /run/user/<uid>
# itself (used by the loginctl-resolution and no-user cases).
HOOK_HANDOFF_DIR="$HANDOFF_DIR"
STUB_FROZEN=0
STUB_GNOME_ACTIVE=false
STUB_FDO_ACTIVE=false
STUB_LOGINCTL_OUTPUT=none
STUB_LOGINCTL_MODE=none
STUB_LOGINCTL_USER="$(id -nu)"
STUB_LOGINCTL_UID="$(id -u)"

reset_case() {
    : > "$HOOK_ERR"
    : > "$GDBUS_LOG"
    : > "$ECTOOL_LOG"
    : > "$SUDO_LOG"
    : > "$LOGINCTL_LOG"
    : > "$CHMOD_LOG"
    : > "$CHOWN_LOG"
    rm -f "$STATE_DIR/state" "$STATE_DIR"/.state.* "$FAKE_SYSFS" "$FAKE_MAX"
    rm -f "$SUSPEND_FILE" "$RESUME_FILE" "$HANDOFF_DIR"/.c640-kbd-handoff.*
    rm -rf "$RUN_USER_ROOT"
    mkdir -p "$RUN_USER_ROOT/$(id -u)"
    chmod 700 "$RUN_USER_ROOT/$(id -u)"
    printf '7\n' > "$FAKE_SYSFS"
    printf '100\n' > "$FAKE_MAX"
    HOOK_HANDOFF_DIR="$HANDOFF_DIR"
    STUB_FROZEN=0
    STUB_GNOME_ACTIVE=false
    STUB_FDO_ACTIVE=false
    STUB_LOGINCTL_OUTPUT=none
    STUB_LOGINCTL_MODE=none
    STUB_LOGINCTL_USER="$(id -nu)"
    STUB_LOGINCTL_UID="$(id -u)"
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
        "STUB_LOGINCTL_OUTPUT=$STUB_LOGINCTL_OUTPUT"
        "STUB_LOGINCTL_MODE=$STUB_LOGINCTL_MODE"
        "STUB_LOGINCTL_USER=$STUB_LOGINCTL_USER"
        "STUB_LOGINCTL_UID=$STUB_LOGINCTL_UID"
        "STUB_GNOME_ACTIVE=$STUB_GNOME_ACTIVE"
        "STUB_FDO_ACTIVE=$STUB_FDO_ACTIVE"
        "STUB_FROZEN=$STUB_FROZEN"
        "C640_KBD_SLEEP_SYSFS=$FAKE_SYSFS"
        "C640_KBD_SLEEP_STATE_DIR=$STATE_DIR"
        "C640_KBD_HANDOFF_DIR=$HOOK_HANDOFF_DIR"
        "C640_KBD_RUN_USER_ROOT=$RUN_USER_ROOT"
    )
    # SUDO_USER and the old D-Bus knobs are removed so resolution is
    # deterministic and we can prove they are no longer consulted.
    env -u SUDO_USER -u C640_KBD_SLEEP_USER -u C640_KBD_SLEEP_UID \
        -u C640_KBD_SLEEP_BUS -u C640_KBD_SLEEP_DELAY \
        "${env_args[@]}" "$HOOK" "$@" 2>> "$HOOK_ERR"
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

# 9. Without C640_KBD_HANDOFF_DIR, loginctl's USER column (field 3) supplies
#    the uid: the handoff lands in $RUN_USER_ROOT/<uid>, 0600 and chowned.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_OUTPUT=real
STUB_LOGINCTL_USER="$(id -nu)"
STUB_LOGINCTL_UID="$(id -u)"
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_file "loginctl: suspend handoff in uid runtime dir" "$_user_dir/c640-kbd-backlight.suspend" "7"
assert_mode "loginctl: suspend handoff 0600" "600" "$_user_dir/c640-kbd-backlight.suspend"
assert_owner "loginctl: suspend handoff chowned to session user" "$(id -u):$(id -g)" "$_user_dir/c640-kbd-backlight.suspend"
# The stat checks above alone are a false pass (mktemp already yields 0600
# owned by us): assert the hook actually invoked chmod/chown on the handoff
# temp file. The ".c640-kbd-handoff." filter excludes save_state's own chmod
# calls, so removing _atomic_write's chmod 600 / chown is detectable.
assert_log_matches "loginctl: suspend chmod 600 on handoff recorded" "$CHMOD_LOG" '^chmod 600 .*\.c640-kbd-handoff\.'
assert_log_matches "loginctl: suspend chown uid:gid recorded" "$CHOWN_LOG" "^chown $(id -u):$(id -g) .*\.c640-kbd-handoff\."
printf '0\n' > "$FAKE_SYSFS"
: > "$CHMOD_LOG"
: > "$CHOWN_LOG"
run_hook post suspend
assert_file "loginctl: post leaves sysfs alone" "$FAKE_SYSFS" "0"
assert_file "loginctl: state retained" "$STATE_DIR/state" "7"
assert_mode "loginctl: resume handoff 0600" "600" "$_user_dir/c640-kbd-backlight.resume"
assert_owner "loginctl: resume handoff chowned to session user" "$(id -u):$(id -g)" "$_user_dir/c640-kbd-backlight.resume"
assert_log_matches "loginctl: resume chmod 600 on handoff recorded" "$CHMOD_LOG" '^chmod 600 .*\.c640-kbd-handoff\.'
assert_log_matches "loginctl: resume chown uid:gid recorded" "$CHOWN_LOG" "^chown $(id -u):$(id -g) .*\.c640-kbd-handoff\."
if grep -q 'list-sessions --no-legend' "$LOGINCTL_LOG"; then
    ok "loginctl list-sessions --no-legend consulted"
else
    bad "loginctl was not consulted: $(cat "$LOGINCTL_LOG")"
fi
assert_empty_log "no gdbus calls (loginctl case)" "$GDBUS_LOG"
assert_empty_log "no sudo calls (loginctl case)" "$SUDO_LOG"
assert_empty_log "no ectool calls (loginctl case)" "$ECTOOL_LOG"

# 9b. Multiple loginctl rows without a preferred one: the FIRST real session
# row is used and the ambiguity is logged as a WARN.  `nobody` is the first
# row, so a wrong branch is immediately visible in the handoff directory.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=multi
_nobody_uid="$(id -u nobody)"
run_hook pre suspend
assert_file "multi-session: first candidate's handoff written" "$RUN_USER_ROOT/$_nobody_uid/c640-kbd-backlight.suspend" "7"
if grep -q 'multiple login sessions (2)' "$HOOK_ERR"; then
    ok "multi-session: ambiguity is logged as a WARN"
else
    bad "multi-session: no WARN (stderr: $(cat "$HOOK_ERR"))"
fi
if grep -q "using handoff dir $RUN_USER_ROOT/$_nobody_uid" "$HOOK_ERR"; then
    ok "multi-session: WARN names the chosen handoff directory"
else
    bad "multi-session: WARN lacks the chosen path (stderr: $(cat "$HOOK_ERR"))"
fi
assert_empty_log "multi-session: no gdbus calls" "$GDBUS_LOG"

# 9c. IDLE=yes wins over an earlier (non-idle) candidate.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=prefer-idle
_user_dir="$RUN_USER_ROOT/$(id -u)"
run_hook pre suspend
assert_file "prefer-idle: handoff in the IDLE=yes session dir" "$_user_dir/c640-kbd-backlight.suspend" "7"
assert_absent "prefer-idle: no handoff in the skipped session dir" "$RUN_USER_ROOT/$_nobody_uid/c640-kbd-backlight.suspend"
if grep -q 'multiple login sessions (2)' "$HOOK_ERR"; then
    ok "prefer-idle: multiple-session WARN still emitted"
else
    bad "prefer-idle: no WARN (stderr: $(cat "$HOOK_ERR"))"
fi
if grep -q "using handoff dir $_user_dir" "$HOOK_ERR"; then
    ok "prefer-idle: WARN names the preferred session's directory"
else
    bad "prefer-idle: WARN lacks the chosen path (stderr: $(cat "$HOOK_ERR"))"
fi

# 9d. CLASS=active wins even though IDLE=no.
reset_case
HOOK_HANDOFF_DIR=""
STUB_LOGINCTL_MODE=prefer-class
run_hook pre suspend
assert_file "prefer-class: handoff in the CLASS=active session dir" "$_user_dir/c640-kbd-backlight.suspend" "7"
assert_absent "prefer-class: no handoff in the skipped session dir" "$RUN_USER_ROOT/$_nobody_uid/c640-kbd-backlight.suspend"
if grep -q "using handoff dir $_user_dir" "$HOOK_ERR"; then
    ok "prefer-class: WARN names the active session's directory"
else
    bad "prefer-class: WARN lacks the chosen path (stderr: $(cat "$HOOK_ERR"))"
fi

# 10. No resolvable session user: handoff is skipped, root state still saved.
reset_case
HOOK_HANDOFF_DIR=""
find "$RUN_USER_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
run_hook pre suspend
assert_file "no user: root state still saved" "$STATE_DIR/state" "7"
assert_absent "no user: no suspend handoff" "$SUSPEND_FILE"
run_hook post suspend
assert_absent "no user: no resume handoff" "$RESUME_FILE"
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
