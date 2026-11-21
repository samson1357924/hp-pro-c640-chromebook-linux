#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# kbd-backlight-sleep-hook-test.sh - unit tests for the system-sleep hook.
# No root, no real sysfs, no real D-Bus: everything lives in a temp dir and
# gdbus/sudo/ectool are stubbed via PATH.
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
GDBUS_LOG="$TMP_DIR/gdbus.log"
ECTOOL_LOG="$TMP_DIR/ectool.log"
SUDO_LOG="$TMP_DIR/sudo.log"
LOGINCTL_LOG="$TMP_DIR/loginctl.log"
mkdir -p "$STUB_DIR" "$STATE_DIR"

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

# --- stubs -----------------------------------------------------------------
cat > "$STUB_DIR/gdbus" << 'STUB'
#!/bin/sh
printf 'gdbus %s | XDG=%s BUS=%s\n' "$*" "${XDG_RUNTIME_DIR:-}" "${DBUS_SESSION_BUS_ADDRESS:-}" >> "$STUB_GDBUS_LOG"
case "$*" in
    *org.gnome.ScreenSaver*GetActive*)
        if [ "${STUB_GNOME_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        if [ "${STUB_GNOME_ACTIVE:-false}" = "true" ]; then
            printf '(true,)\n'
        else
            printf '(false,)\n'
        fi
        ;;
    *org.freedesktop.ScreenSaver*GetActive*)
        if [ "${STUB_FDO_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        if [ "${STUB_FDO_ACTIVE:-false}" = "true" ]; then
            printf '(true,)\n'
        else
            printf '(false,)\n'
        fi
        ;;
    *)
        exit 0
        ;;
esac
exit 0
STUB

# Drop "-u <user>" and run the rest as the current (unprivileged) test user.
# The full command line is logged so tests can assert which user was chosen.
cat > "$STUB_DIR/sudo" << 'STUB'
#!/bin/sh
if [ -n "${STUB_SUDO_LOG:-}" ]; then
    printf 'sudo %s\n' "$*" >> "$STUB_SUDO_LOG"
fi
if [ "${1:-}" = "-u" ]; then
    shift 2
fi
exec "$@"
STUB

# Optional stub for `loginctl list-sessions --no-legend`. STUB_LOGINCTL_OUTPUT
# =real emits the real column layout: SESSION UID USER SEAT LEADER CLASS TTY
# IDLE SINCE (USER is field 3, never the literal "active").
cat > "$STUB_DIR/loginctl" << 'STUB'
#!/bin/sh
printf 'loginctl %s\n' "$*" >> "${STUB_LOGINCTL_LOG:-/dev/null}"
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
chmod +x "$STUB_DIR/gdbus" "$STUB_DIR/sudo" "$STUB_DIR/ectool" "$STUB_DIR/loginctl"

# --- harness ----------------------------------------------------------------

# Session-user knobs default to a synthetic user; per-case overrides are set
# through HOOK_USER / HOOK_UID below.
HOOK_USER="c640-test-user"
HOOK_UID="1000"
STUB_GNOME_ACTIVE="false"
STUB_GNOME_FAIL="0"
STUB_FDO_ACTIVE="false"
STUB_FDO_FAIL="0"

reset_case() {
    : > "$GDBUS_LOG"
    : > "$ECTOOL_LOG"
    : > "$SUDO_LOG"
    : > "$LOGINCTL_LOG"
    rm -f "$STATE_DIR/state" "$FAKE_SYSFS" "$FAKE_MAX"
    printf '7\n' > "$FAKE_SYSFS"
    printf '100\n' > "$FAKE_MAX"
    HOOK_USER="c640-test-user"
    HOOK_UID="1000"
    STUB_GNOME_ACTIVE="false"
    STUB_GNOME_FAIL="0"
    STUB_FDO_ACTIVE="false"
    STUB_FDO_FAIL="0"
    STUB_LOGINCTL_OUTPUT="none"
    STUB_LOGINCTL_USER="root"
    STUB_LOGINCTL_UID="0"
}

run_hook() {
    local -a env_args=(
        "PATH=$STUB_DIR:$PATH"
        "STUB_GDBUS_LOG=$GDBUS_LOG"
        "STUB_ECTOOL_LOG=$ECTOOL_LOG"
        "STUB_SUDO_LOG=$SUDO_LOG"
        "STUB_LOGINCTL_LOG=$LOGINCTL_LOG"
        "STUB_LOGINCTL_OUTPUT=$STUB_LOGINCTL_OUTPUT"
        "STUB_LOGINCTL_USER=$STUB_LOGINCTL_USER"
        "STUB_LOGINCTL_UID=$STUB_LOGINCTL_UID"
        "STUB_GNOME_ACTIVE=$STUB_GNOME_ACTIVE"
        "STUB_GNOME_FAIL=$STUB_GNOME_FAIL"
        "STUB_FDO_ACTIVE=$STUB_FDO_ACTIVE"
        "STUB_FDO_FAIL=$STUB_FDO_FAIL"
        "C640_KBD_SLEEP_SYSFS=$FAKE_SYSFS"
        "C640_KBD_SLEEP_STATE_DIR=$STATE_DIR"
        "C640_KBD_SLEEP_DELAY=0"
    )
    # An empty HOOK_USER / HOOK_UID means "unset", so the hook must resolve
    # the session user itself (e.g. via the stubbed loginctl).
    [ -z "$HOOK_USER" ] || env_args+=("C640_KBD_SLEEP_USER=$HOOK_USER")
    [ -z "$HOOK_UID" ] || env_args+=("C640_KBD_SLEEP_UID=$HOOK_UID")
    env -u C640_KBD_SLEEP_USER -u C640_KBD_SLEEP_UID \
        "${env_args[@]}" "$HOOK" "$@"
}

if [ ! -f "$HOOK" ]; then
    printf 'FAIL: sleep hook not found at %s\n' "$HOOK" >&2
    exit 1
fi

# 1. pre stores, post restores (and consumes the state file).
reset_case
run_hook pre suspend
assert_file "pre saves current brightness" "$STATE_DIR/state" "7"
printf '0\n' > "$FAKE_SYSFS"
run_hook post suspend
assert_file "post restores saved brightness" "$FAKE_SYSFS" "7"
assert_absent "post removes the state file" "$STATE_DIR/state"
if grep -q 'XDG=/run/user/1000 BUS=unix:path=/run/user/1000/bus' "$GDBUS_LOG"; then
    ok "gdbus probe runs as the session user with XDG_RUNTIME_DIR + bus address"
else
    bad "gdbus probe did not carry the session bus environment"
fi

# 2. ScreenSaver still active -> defer and keep state; later inactive -> restore.
reset_case
run_hook pre suspend
printf '0\n' > "$FAKE_SYSFS"
STUB_GNOME_ACTIVE="true"
run_hook post suspend
assert_file "active ScreenSaver: brightness left off" "$FAKE_SYSFS" "0"
assert_file "active ScreenSaver: state retained" "$STATE_DIR/state" "7"
STUB_GNOME_ACTIVE="false"
run_hook post suspend
assert_file "inactive ScreenSaver: restore now happens" "$FAKE_SYSFS" "7"
assert_absent "inactive ScreenSaver: state consumed" "$STATE_DIR/state"

# 3. freedesktop fallback when GNOME is unavailable.
reset_case
run_hook pre suspend
printf '0\n' > "$FAKE_SYSFS"
STUB_GNOME_FAIL="1"
STUB_FDO_ACTIVE="true"
run_hook post suspend
assert_file "freedesktop fallback active: no restore" "$FAKE_SYSFS" "0"
assert_file "freedesktop fallback active: state retained" "$STATE_DIR/state" "7"

# 4. no resolvable session user / bus -> fail-open restore.
reset_case
run_hook pre suspend
printf '0\n' > "$FAKE_SYSFS"
HOOK_USER="__c640_no_such_user__"
HOOK_UID=""
run_hook post suspend
assert_file "no session bus: fail-open restore" "$FAKE_SYSFS" "7"
assert_absent "no session bus: state consumed" "$STATE_DIR/state"

# 5. gdbus/timeout failure -> fail-open restore.
reset_case
run_hook pre suspend
printf '0\n' > "$FAKE_SYSFS"
STUB_GNOME_FAIL="1"
STUB_FDO_FAIL="1"
run_hook post suspend
assert_file "gdbus failure: fail-open restore" "$FAKE_SYSFS" "7"

# 6. 0 is saved, and the saved value overrides a non-zero current value.
reset_case
printf '0\n' > "$FAKE_SYSFS"
run_hook pre suspend
assert_file "pre stores 0 as a valid saved value" "$STATE_DIR/state" "0"
printf '5\n' > "$FAKE_SYSFS"
run_hook post suspend
assert_file "saved 0 overrides non-zero current" "$FAKE_SYSFS" "0"
assert_absent "saved 0: state consumed" "$STATE_DIR/state"

# 7. no state file -> never touch the brightness (manual change preserved).
reset_case
printf '9\n' > "$FAKE_SYSFS"
run_hook post suspend
assert_file "no state file: manual brightness untouched" "$FAKE_SYSFS" "9"

# 8. saved value is clamped when max_brightness shrinks across resume.
reset_case
printf '70\n' > "$FAKE_SYSFS"
run_hook pre suspend
printf '0\n' > "$FAKE_SYSFS"
printf '50\n' > "$FAKE_MAX"
run_hook post suspend
assert_file "saved value clamped to current max" "$FAKE_SYSFS" "50"

# 9. no sysfs -> ectool fallback is used.
reset_case
run_hook pre suspend
rm -f "$FAKE_SYSFS"
run_hook post suspend
if grep -q 'pwmsetkblight 7' "$ECTOOL_LOG"; then
    ok "ectool fallback used when sysfs is absent"
else
    bad "ectool fallback was not invoked (log: $(cat "$ECTOOL_LOG"))"
fi
assert_absent "ectool fallback: state consumed" "$STATE_DIR/state"

# 10. No C640_KBD_SLEEP_USER: the USER column (field 3) of
#     `loginctl list-sessions --no-legend` supplies the sudo -u username.
#     The stub deliberately names a user that is NOT the /run/user fallback,
#     so a broken parser cannot accidentally pass via the fallback.
reset_case
run_hook pre suspend
printf '0\n' > "$FAKE_SYSFS"
HOOK_USER=""
HOOK_UID=""
STUB_LOGINCTL_OUTPUT="real"
STUB_LOGINCTL_USER="root"
STUB_LOGINCTL_UID="0"
run_hook post suspend
assert_file "loginctl user resolution: brightness restored" "$FAKE_SYSFS" "7"
assert_absent "loginctl user resolution: state consumed" "$STATE_DIR/state"
if grep -q -- '-u root ' "$SUDO_LOG"; then
    ok "sudo -u uses the loginctl USER column (field 3)"
else
    bad "sudo -u did not use the loginctl USER column: $(cat "$SUDO_LOG")"
fi
if grep -q 'list-sessions --no-legend' "$LOGINCTL_LOG"; then
    ok "loginctl list-sessions --no-legend was consulted"
else
    bad "loginctl was not consulted: $(cat "$LOGINCTL_LOG")"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
    exit 1
fi
