#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# kbd-backlight-daemon-test.sh - unit tests for c640-kbd-backlight-sync.
# The daemon is loaded without starting it; sysfs, state files and all D-Bus
# tools are redirected into a temp dir. No root and no real brightness write.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DAEMON="$REPO_ROOT/keyboard/c640-kbd-backlight-sync"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
STUB_DIR="$TMP_DIR/stubs"
D_STATE_DIR="$TMP_DIR/state"
FAKE_SYSFS="$TMP_DIR/brightness"
FAKE_MAX="$TMP_DIR/max_brightness"
GDBUS_LOG="$TMP_DIR/gdbus.log"
SET_LOG="$TMP_DIR/dbus-set.log"
RAW_FILE="$TMP_DIR/upower-raw"
PCT_FILE="$TMP_DIR/gsd-pct"
DAEMON_ERR="$TMP_DIR/daemon.err"
FLOCK_DIR="$TMP_DIR/flock"
mkdir -p "$STUB_DIR" "$D_STATE_DIR" "$FLOCK_DIR"

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
    local label="$1" file="$2" expected="$3"
    assert_eq "$label" "$expected" "$(cat "$file" 2> /dev/null || echo '<missing>')"
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
# Stateful gdbus: introspection advertises both keyboard backends, a gsd
# Properties.Set updates the simulated UPower raw value (that is what the
# real gsd-power does), and UPower Get/SetBrightness round-trip that value.
cat > "$STUB_DIR/gdbus" << 'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_GDBUS_LOG"

case "$*" in
    *introspect*)
        case "$*" in
            *SettingsDaemon.Power*)
                if [ "${STUB_GSD_FAIL:-0}" = "1" ]; then
                    exit 1
                fi
                printf 'interface org.gnome.SettingsDaemon.Power.Keyboard { readwrite i Brightness = 0; };\n'
                ;;
            *org.freedesktop.UPower*)
                if [ "${STUB_UPOWER_FAIL:-0}" = "1" ]; then
                    exit 1
                fi
                printf 'interface org.freedesktop.UPower.KbdBacklight { method SetBrightness; };\n'
                ;;
            *)
                printf '<node/>\n'
                ;;
        esac
        exit 0
        ;;
esac

case "$*" in
    *GetActive*)
        case "$*" in
            *org.gnome.ScreenSaver*)
                if [ "${STUB_GNOME_ACTIVE:-false}" = "true" ]; then
                    printf '(true,)\n'
                else
                    printf '(false,)\n'
                fi
                ;;
            *)
                if [ "${STUB_FDO_ACTIVE:-false}" = "true" ]; then
                    printf '(true,)\n'
                else
                    printf '(false,)\n'
                fi
                ;;
        esac
        exit 0
        ;;
esac

case "$*" in
    *Properties.Set*)
        printf 'Properties.Set %s\n' "$*" >> "$STUB_SET_LOG"
        if [ "${STUB_GSD_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        pct="$(printf '%s\n' "$*" | sed -n 's/.*int32 \([0-9][0-9]*\).*/\1/p' | head -n1 || true)"
        if [ -n "$pct" ]; then
            printf '%s\n' "$pct" > "$STUB_PCT_FILE"
            # gsd-power drives UPower; max is 100 in this test so pct == raw.
            # STUB_GSD_NOOP models the short-circuit: the cache is updated but
            # the hardware is NOT written because pct did not change.
            if [ "${STUB_GSD_NOOP:-0}" != "1" ]; then
                printf '%s\n' "$pct" > "$STUB_RAW_FILE"
            fi
        fi
        exit 0
        ;;
esac

case "$*" in
    *Properties.Get*)
        if [ "${STUB_GSD_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        pct="$(cat "$STUB_PCT_FILE" 2> /dev/null || true)"
        printf '(<int32 %s>,)\n' "${pct:-0}"
        exit 0
        ;;
esac

case "$*" in
    *SetBrightness*)
        printf 'UPower.SetBrightness %s\n' "$*" >> "$STUB_SET_LOG"
        if [ "${STUB_UPOWER_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        val="$(printf '%s\n' "$*" | grep -o '[0-9][0-9]*' | tail -n1 || true)"
        if [ -n "$val" ]; then
            printf '%s\n' "$val" > "$STUB_RAW_FILE"
        fi
        exit 0
        ;;
esac

case "$*" in
    *GetBrightness*)
        printf '(%s,)\n' "$(cat "$STUB_RAW_FILE" 2> /dev/null || printf '%s' "${STUB_KBD_RAW:-42}")"
        exit 0
        ;;
esac

exit 0
STUB

cat > "$STUB_DIR/sudo" << 'STUB'
#!/bin/sh
while [ "${1:-}" = "-n" ] || [ "${1:-}" = "-u" ]; do
    if [ "$1" = "-u" ]; then
        shift 2
    else
        shift
    fi
done
exec "$@"
STUB

cat > "$STUB_DIR/ectool" << 'STUB'
#!/bin/sh
printf 'ectool %s\n' "$*" >> "$STUB_ECTOOL_LOG"
if [ "${1:-}" = "pwmgetkblight" ]; then
    printf '100\n'
fi
exit 0
STUB

# Minimal real-ish flock: lock identity is the file opened on the fd (read
# from /proc/self/fd), so fd 200/201/202 all contend on the same state lock.
# The recorded PID lets a dead subshell's stale lock be reclaimed, so a no-op
# `sleep` cannot wedge later cases.
cat > "$STUB_DIR/flock" << 'STUB'
#!/bin/sh
lock_dir="${STUB_FLOCK_DIR:-/tmp}"
fd=""
op=""
for arg in "$@"; do
    case "$arg" in
        -n) op=n ;;
        -u) op=u ;;
        -w*) op=w ;;
        -x | -s) ;;
        [0-9]*) fd="$arg" ;;
    esac
done
[ -n "$fd" ] || exit 0
target="$(readlink "/proc/self/fd/$fd" 2> /dev/null || true)"
[ -n "$target" ] || target="fd$fd"
key="$(printf '%s\n' "$target" | cksum | cut -d' ' -f1)"
lockfile="$lock_dir/flock.$key"
case "$op" in
    u)
        rm -f "$lockfile" 2> /dev/null || true
        exit 0
        ;;
    n)
        if [ -f "$lockfile" ]; then
            old="$(cat "$lockfile" 2> /dev/null || echo "")"
            if [ -n "$old" ] && kill -0 "$old" 2> /dev/null; then
                exit 1
            fi
        fi
        printf '%s\n' "$PPID" > "$lockfile" 2> /dev/null || true
        exit 0
        ;;
    *)
        printf '%s\n' "$PPID" > "$lockfile" 2> /dev/null || true
        exit 0
        ;;
esac
STUB
# sleep is a no-op so retry/guard subshells finish at once.
printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/sleep"
chmod +x "$STUB_DIR/gdbus" "$STUB_DIR/sudo" "$STUB_DIR/ectool" "$STUB_DIR/flock" "$STUB_DIR/sleep"

# The stub directory MUST win before any daemon function runs: otherwise the
# real session/system bus would be queried (and the real LED could be written).
export PATH="$STUB_DIR:$PATH"

# --- load the daemon --------------------------------------------------------
if [ ! -f "$DAEMON" ]; then
    printf 'FAIL: daemon not found at %s\n' "$DAEMON" >&2
    exit 1
fi

if grep -q 'BASH_SOURCE\|FUNCNAME\|C640_KBD_TEST_SOURCE' "$DAEMON"; then
    # Partner design: a source guard keeps main() from running when sourced.
    # shellcheck disable=SC1090
    source "$DAEMON"
else
    # Pre-partner daemon: load only function definitions, stopping before the
    # CLI/main dispatch so sourcing can never start the real daemon.
    # shellcheck disable=SC1090
    source <(awk '/^# Handle CLI/{exit} {print}' "$DAEMON")
fi

# Redirect every global the daemon may use for sysfs/state into the sandbox.
# Overriding AFTER sourcing works regardless of which env var name the daemon
# used to initialise those globals.
export SYSFS_BRIGHTNESS="$FAKE_SYSFS"
export SYSFS_MAX="$FAKE_MAX"
export SYSFS="$FAKE_SYSFS"
export STATE_DIR="$D_STATE_DIR"
export STATE_FILE="$D_STATE_DIR/c640-kbd-backlight.state"
export STATE_LOCK="$D_STATE_DIR/c640-kbd-backlight.state.lock"
export LOCK_FILE="$D_STATE_DIR/c640-kbd-backlight.lock"
export LAST_USER_FILE="$D_STATE_DIR/c640-kbd-backlight.last-user"
export RESTORE_GEN_FILE="$D_STATE_DIR/c640-kbd-backlight.restore-gen"
export HAVE_GSD_KBD=""
export HAVE_UPOWER_KBD=""

export STUB_GDBUS_LOG="$GDBUS_LOG"
export STUB_SET_LOG="$SET_LOG"
export STUB_ECTOOL_LOG="$TMP_DIR/ectool.log"
export STUB_FLOCK_DIR="$FLOCK_DIR"
export STUB_RAW_FILE="$RAW_FILE"
export STUB_PCT_FILE="$PCT_FILE"
export STUB_KBD_RAW="42"
export STUB_GSD_FAIL="0"
export STUB_UPOWER_FAIL="0"
export STUB_GNOME_ACTIVE="false"
export STUB_FDO_ACTIVE="false"
export STUB_GSD_NOOP="0"

reset_case() {
    : > "$GDBUS_LOG"
    : > "$SET_LOG"
    : > "$DAEMON_ERR"
    : > "$TMP_DIR/ectool.log"
    rm -f "$STATE_FILE" "$STATE_LOCK" "$LOCK_FILE" "$LAST_USER_FILE" "$RESTORE_GEN_FILE" \
        "$FAKE_SYSFS" "$FAKE_MAX" "$RAW_FILE" "$PCT_FILE"
    rm -f "$FLOCK_DIR"/flock.* 2> /dev/null || true
    printf '99\n' > "$FAKE_SYSFS"
    printf '100\n' > "$FAKE_MAX"
    printf '%s\n' "$STUB_KBD_RAW" > "$RAW_FILE"
    : > "$PCT_FILE"
    export HAVE_GSD_KBD=""
    export HAVE_UPOWER_KBD=""
    export STUB_KBD_RAW="42"
    export STUB_GSD_FAIL="0"
    export STUB_UPOWER_FAIL="0"
    export STUB_GNOME_ACTIVE="false"
    export STUB_FDO_ACTIVE="false"
    export C640_KBD_FORCE_LEGACY=0
    export STUB_GSD_NOOP=0
    _C640_WARNED=()
    _C640_ZERO_STREAK=0
    last_user_brightness=""
}

write_state() {
    mkdir -p "$D_STATE_DIR"
    printf '%s\n' "$1" > "$STATE_FILE"
}

run_fn() {
    # Function call with stderr captured; never let an internal `return 1`
    # abort the test harness.
    "$@" 2> "$DAEMON_ERR" || true
}

# --- tests -----------------------------------------------------------------

# 1. get_brightness reads UPower over gdbus (stub raw = 42, sysfs = 99).
reset_case
val="$(get_brightness 2> "$DAEMON_ERR" || true)"
assert_eq "get_brightness reads the UPower raw value" "42" "$val"
if grep -q 'GetBrightness' "$GDBUS_LOG"; then
    ok "get_brightness queried UPower GetBrightness over gdbus"
else
    bad "get_brightness did not query UPower (gdbus log: $(cat "$GDBUS_LOG"))"
fi

# 2. set_brightness performs exactly one gsd-power Properties.Set (single writer).
reset_case
run_fn set_brightness 30
set_count="$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_eq "set_brightness writes exactly one Properties.Set" "1" "$set_count"
if grep -q 'org.gnome.SettingsDaemon.Power' "$SET_LOG"; then
    ok "the single Properties.Set targets gsd-power"
else
    bad "Properties.Set did not target gsd-power: $(cat "$SET_LOG")"
fi
assert_file "gsd-power property write reaches the UPower raw value" "$RAW_FILE" "30"

# 3. gsd-power unavailable -> UPower fallback plus a WARN on stderr.
reset_case
export STUB_GSD_FAIL=1
run_fn set_brightness 31
export STUB_GSD_FAIL=0
if grep -q 'UPower.SetBrightness' "$SET_LOG"; then
    ok "fallback writes the UPower property directly"
else
    bad "no UPower SetBrightness after gsd-power failed: $(cat "$SET_LOG")"
fi
if grep -qiE 'warn|fallback|degrad' "$DAEMON_ERR"; then
    ok "fallback emits a WARN on stderr"
else
    bad "fallback did not log a WARN (stderr: $(cat "$DAEMON_ERR"))"
fi

# 4. C640_KBD_FORCE_LEGACY=1 bypasses D-Bus and writes sysfs directly.
reset_case
export C640_KBD_FORCE_LEGACY=1
run_fn set_brightness 33
export C640_KBD_FORCE_LEGACY=0
set_count="$(grep -c . "$SET_LOG" || true)"
assert_eq "forced legacy mode makes no D-Bus write" "0" "$set_count"
assert_file "forced legacy mode writes sysfs" "$FAKE_SYSFS" "33"

# 5. save_state stores 0 as a valid value (not "no saved state").
export STUB_KBD_RAW=0
reset_case
run_fn save_state
assert_file "save_state stores 0" "$STATE_FILE" "0"

# 6. restore_state overrides a non-zero current value when state exists.
reset_case
write_state 7
printf '9\n' > "$FAKE_SYSFS"
run_fn restore_state
assert_file "restore overrides non-zero current with saved value" "$RAW_FILE" "7"
if [ -f "$STATE_FILE" ]; then
    bad "restore did not consume the state file"
else
    ok "restore consumed the state file"
fi

# 7. ScreenSaver still active -> defer and keep state; inactive -> restore.
reset_case
write_state 7
export STUB_GNOME_ACTIVE=true
run_fn restore_state
export STUB_GNOME_ACTIVE=false
assert_file "ScreenSaver active: raw brightness stays unchanged" "$RAW_FILE" "42"
assert_file "ScreenSaver active: state retained" "$STATE_FILE" "7"
run_fn restore_state
assert_file "ScreenSaver inactive: restore proceeds" "$RAW_FILE" "7"
if [ -f "$STATE_FILE" ]; then
    bad "ScreenSaver inactive: state file was not consumed"
else
    ok "ScreenSaver inactive: state file consumed"
fi

# 8. log() output must reach stderr (not swallowed by `2> /dev/null`).
reset_case
printf '5\n' > "$FAKE_SYSFS"
run_fn save_state
if grep -q 'saved brightness' "$DAEMON_ERR"; then
    ok "save_state log line is visible on stderr"
else
    bad "save_state log was swallowed (stderr: $(cat "$DAEMON_ERR"))"
fi

# 9. Two consecutive on-screen zeros (with gsd pct also 0) mean the user
#    deliberately switched the light off; a single zero is only a transient.
reset_case
export STUB_KBD_RAW=0
reset_case
printf '0\n' > "$PCT_FILE"
sample_brightness_once
assert_absent "single on-screen 0 is not recorded as user intent" "$LAST_USER_FILE"
sample_brightness_once
assert_file "two consecutive on-screen zeros record 0 in last-user" "$LAST_USER_FILE" "0"
assert_eq "in-process last_user_brightness is 0 after manual off" "0" "$last_user_brightness"
run_fn save_state
assert_file "save_state keeps the manual 0" "$STATE_FILE" "0"
run_fn restore_state
assert_file "unblank after manual 0 leaves the light off" "$RAW_FILE" "0"
assert_absent "manual 0: restore consumes state without writing" "$STATE_FILE"

# 10. A zero while gsd still reports a non-zero percentage is a transient,
#     not user intent, even if seen twice.
reset_case
export STUB_KBD_RAW=0
reset_case
printf '60\n' > "$PCT_FILE"
sample_brightness_once
sample_brightness_once
assert_absent "zeros with non-zero gsd pct are transient" "$LAST_USER_FILE"
export STUB_KBD_RAW=42

# 11. gsd-power short-circuit: the cache is already at target, so only the
#     hardware (UPower) needs forcing; the property is not pointlessly reset.
reset_case
printf '30\n' > "$PCT_FILE"
printf '42\n' > "$RAW_FILE"
export STUB_GSD_NOOP=1
run_fn set_brightness 30
export STUB_GSD_NOOP=0
set_count="$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_eq "short-circuit makes exactly one Properties.Set" "1" "$set_count"
assert_file "short-circuit forces hardware via UPower" "$RAW_FILE" "30"
if grep -q 'gsd cache already at pct' "$DAEMON_ERR"; then
    ok "short-circuit warning states the cache is already at target"
else
    bad "short-circuit warning missing/inaccurate: $(cat "$DAEMON_ERR")"
fi

# 12. restore_state releases the state lock before the D-Bus write, so a
#     blank arriving mid-restore can still save_state() its new value.
reset_case
write_state 7
_orig_set_brightness="$(declare -f set_brightness)"
declare -f set_brightness | sed '1s/^set_brightness ()/real_set_brightness ()/' > "$TMP_DIR/real_set_brightness.def"
# shellcheck disable=SC1090
source "$TMP_DIR/real_set_brightness.def"
set_brightness() {
    # Simulate a blank during the (slow) restore write: a new user value must
    # be captured by save_state even though restore started first.
    printf '5\n' > "$LAST_USER_FILE"
    save_state
    real_set_brightness "$@"
}
run_fn restore_state
eval "$_orig_set_brightness"
assert_file "blank during restore still saves the new state" "$STATE_FILE" "5"
assert_file "restore still wrote the saved brightness" "$RAW_FILE" "7"

# 13. A stale LAST_USER_FILE from a previous daemon run is re-seeded from the
#     brightness the user currently sees.
reset_case
printf '55\n' > "$RAW_FILE"
printf '3\n' > "$LAST_USER_FILE"
run_fn seed_last_user_from_current
assert_file "startup re-seeds last-user from current brightness" "$LAST_USER_FILE" "55"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
    exit 1
fi
