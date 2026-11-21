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
RECOVER_LOG="$TMP_DIR/recover.log"
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
if [ "${1:-}" = "pwmsetkblight" ] && [ "${STUB_ECTOOL_FAIL:-0}" = "1" ]; then
    exit 1
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
# Fault injection: fail the first N flock calls for one fd, modelling a
# transient flock error even in blocking mode.  The counter lives next to the
# lock files so reset_case's `rm -f "$FLOCK_DIR"/flock.*` clears it.
fail_fd="${STUB_FLOCK_FAIL_FD:-}"
fail_n="${STUB_FLOCK_FAIL_COUNT:-0}"
if [ -n "$fail_fd" ] && [ "$fd" = "$fail_fd" ] && [ "$fail_n" -gt 0 ]; then
    counter="$lock_dir/flock.fail.$fail_fd"
    used="$(cat "$counter" 2> /dev/null || echo 0)"
    case "$used" in
        '' | *[!0-9]*) used=0 ;;
    esac
    if [ "$used" -lt "$fail_n" ]; then
        printf '%s\n' "$((used + 1))" > "$counter" 2> /dev/null || true
        exit 1
    fi
fi
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
export RESTORE_PENDING_FILE="$D_STATE_DIR/c640-kbd-backlight.restore-pending"
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
export STUB_ECTOOL_FAIL="0"

reset_case() {
    # Retire retry subshells from the previous case before removing their files.
    wait 2> /dev/null || true
    : > "$GDBUS_LOG"
    : > "$SET_LOG"
    : > "$DAEMON_ERR"
    : > "$RECOVER_LOG"
    : > "$TMP_DIR/ectool.log"
    rm -f "$STATE_FILE" "$STATE_LOCK" "$LOCK_FILE" "$LAST_USER_FILE" "$RESTORE_GEN_FILE" \
        "$RESTORE_PENDING_FILE" "$D_STATE_DIR"/*.restore-pending "$D_STATE_DIR"/*.meta \
        "$FAKE_SYSFS" "$FAKE_MAX" "$RAW_FILE" "$PCT_FILE"
    rm -f "$FLOCK_DIR"/flock.* 2> /dev/null || true
    printf '99\n' > "$FAKE_SYSFS"
    printf '100\n' > "$FAKE_MAX"
    printf '%s\n' "$STUB_KBD_RAW" > "$RAW_FILE"
    : > "$PCT_FILE"
    export HAVE_GSD_KBD=""
    export HAVE_UPOWER_KBD=""
    _BACKENDS_LOGGED=0
    export STUB_KBD_RAW="42"
    export STUB_GSD_FAIL="0"
    export STUB_UPOWER_FAIL="0"
    export STUB_GNOME_ACTIVE="false"
    export STUB_FDO_ACTIVE="false"
    export C640_KBD_FORCE_LEGACY=0
    export STUB_GSD_NOOP=0
    export STUB_ECTOOL_FAIL=0
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

run_fn_rc() {
    # Same as run_fn but prints the function's rc on stdout, so failure paths
    # can be asserted without tripping `set -e` in the harness.
    local rc=0
    "$@" 2> "$DAEMON_ERR" || rc=$?
    printf '%s' "$rc"
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
if grep -q 'introspect' "$GDBUS_LOG"; then
    bad "forced legacy mode must not probe D-Bus: $(cat "$GDBUS_LOG")"
else
    ok "forced legacy mode performs no D-Bus introspection (early return preserved)"
fi
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
assert_absent "manual 0: restore consumes state after writing 0" "$STATE_FILE"

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

# 14. Backend recovery in the SAME process: a gsd-power name that was absent
#     at startup must be re-probed on a later call, not cached as dead forever.
#     Phase 1: gsd unavailable -> UPower direct writer.
reset_case
export STUB_GSD_FAIL=1
run_fn set_brightness 30
export STUB_GSD_FAIL=0
set_count="$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_eq "gsd-absent phase makes no Properties.Set" "0" "$set_count"
if grep -q 'UPower.SetBrightness' "$SET_LOG"; then
    ok "gsd-absent phase falls back to a direct UPower write"
else
    bad "gsd-absent phase did not write UPower directly: $(cat "$SET_LOG")"
fi
assert_eq "gsd-absent phase caches HAVE_GSD_KBD=0" "0" "$HAVE_GSD_KBD"
if grep -qiE 'warn|fallback|degrad' "$DAEMON_ERR"; then
    ok "gsd-absent phase emits a WARN on stderr"
else
    bad "gsd-absent phase did not log a WARN (stderr: $(cat "$DAEMON_ERR"))"
fi

# Phase 2: same process, HAVE_* deliberately NOT cleared, gsd back on D-Bus.
: > "$SET_LOG"
run_fn set_brightness 40
set_count="$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_eq "recovered phase writes exactly one Properties.Set" "1" "$set_count"
direct_count="$(grep -c 'UPower.SetBrightness' "$SET_LOG" || true)"
assert_eq "recovered phase makes no direct UPower write" "0" "$direct_count"
assert_file "recovered phase reaches the LED via gsd-power" "$RAW_FILE" "40"
assert_eq "recovered phase caches HAVE_GSD_KBD=1" "1" "$HAVE_GSD_KBD"
probes="$(grep -c 'introspect.*SettingsDaemon.Power' "$GDBUS_LOG" || true)"
assert_eq "gsd was introspected once per set_brightness call" "2" "$probes"
if grep -q 'RECOVERED' "$DAEMON_ERR"; then
    ok "recovery is logged as a transition to single writer"
else
    bad "recovery transition not logged (stderr: $(cat "$DAEMON_ERR"))"
fi

# 15. A backend that was available, failed at runtime, then comes back must
#     return to the single-writer path within one long-lived process.
reset_case
run_fn set_brightness 20
assert_eq "backend starts available" "1" "$HAVE_GSD_KBD"
assert_file "initial write uses gsd-power" "$RAW_FILE" "20"

export STUB_GSD_FAIL=1
run_fn set_brightness 21
export STUB_GSD_FAIL=0
assert_eq "runtime gsd failure invalidates the cached 1" "0" "$HAVE_GSD_KBD"
assert_file "runtime failure falls back to direct UPower" "$RAW_FILE" "21"
if grep -q 'UPower.SetBrightness' "$SET_LOG"; then
    ok "runtime failure writes UPower directly"
else
    bad "runtime failure did not write UPower directly: $(cat "$SET_LOG")"
fi

: > "$SET_LOG"
run_fn set_brightness 22
set_count="$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_eq "runtime recovery restores exactly one Properties.Set" "1" "$set_count"
assert_eq "runtime recovery re-caches HAVE_GSD_KBD=1" "1" "$HAVE_GSD_KBD"
assert_file "runtime recovery reaches the LED via gsd-power" "$RAW_FILE" "22"

# set_brightness rc contract: a non-numeric input is a failure, and a write
# with no readback path at all is reported as "no verifier" (rc 2) so callers
# can accept it as authoritative.
reset_case
rc="$(run_fn_rc set_brightness not-a-number)"
assert_eq "set_brightness rejects non-numeric input with rc 1" "1" "$rc"
reset_case
rm -f "$FAKE_SYSFS"
export C640_KBD_FORCE_LEGACY=1
rc="$(run_fn_rc verify_brightness 7)"
assert_eq "verify_brightness reports no readback path as rc 2" "2" "$rc"

# (a) A saved 0 is a real value: the restore must write it instead of
#     discarding it, otherwise a non-zero residual brightness survives.
reset_case
write_state 0
printf '30\n' > "$RAW_FILE"
printf '30\n' > "$PCT_FILE"
rc="$(run_fn_rc restore_state)"
assert_eq "saved 0: restore returns 0" "0" "$rc"
assert_file "saved 0: LED is written off" "$RAW_FILE" "0"
assert_absent "saved 0: state consumed after verified write" "$STATE_FILE"
assert_absent "saved 0: pending consumed after verified write" "$RESTORE_PENDING_FILE"
if grep -q 'Properties.Set' "$SET_LOG"; then
    ok "saved 0: restore performs a real writer call"
else
    bad "saved 0: no writer call in SET_LOG: $(cat "$SET_LOG")"
fi

# (a2) The same valid 0 is deferred while the screen is still active.
reset_case
write_state 0
printf '30\n' > "$RAW_FILE"
export STUB_GNOME_ACTIVE=true
rc="$(run_fn_rc restore_state)"
export STUB_GNOME_ACTIVE=false
assert_eq "deferred saved 0: initial restore returns 0" "0" "$rc"
assert_file "deferred saved 0: LED stays at 30 while ScreenSaver active" "$RAW_FILE" "30"
assert_file "deferred saved 0: state retained while deferred" "$STATE_FILE" "0"
rc="$(run_fn_rc restore_state)"
assert_eq "deferred saved 0: later restore returns 0" "0" "$rc"
assert_file "deferred saved 0: LED written off after unlock" "$RAW_FILE" "0"
assert_absent "deferred saved 0: state consumed after unlock" "$STATE_FILE"
assert_absent "deferred saved 0: pending consumed after unlock" "$RESTORE_PENDING_FILE"

# (c) Every writer fails: the restore must report failure and keep the state.
reset_case
write_state 7
export STUB_GSD_FAIL=1 STUB_UPOWER_FAIL=1 STUB_ECTOOL_FAIL=1
rm -f "$FAKE_SYSFS"
rc="$(run_fn_rc restore_state)"
if [ "$rc" -ne 0 ]; then
    ok "all writers fail: restore returns non-zero (rc=$rc)"
else
    bad "all writers fail: restore incorrectly returned 0"
fi
assert_file "all writers fail: state value preserved" "$STATE_FILE" "7"
assert_absent "all writers fail: pending rolled back" "$RESTORE_PENDING_FILE"
if grep -q 'restore failed' "$DAEMON_ERR"; then
    ok "all writers fail: logs 'restore failed'"
else
    bad "all writers fail: no 'restore failed' log (stderr: $(cat "$DAEMON_ERR"))"
fi

# (c2) gsd-power reports success but never touches the hardware ("fake
#      success"); a readback mismatch must NOT consume the saved state.
reset_case
write_state 7
export STUB_GSD_NOOP=1 STUB_UPOWER_FAIL=1 STUB_ECTOOL_FAIL=1
rm -f "$FAKE_SYSFS"
rc="$(run_fn_rc restore_state)"
if grep -q 'Properties.Set' "$SET_LOG"; then
    ok "gsd fake success: Properties.Set was accepted"
else
    bad "gsd fake success: no Properties.Set in SET_LOG: $(cat "$SET_LOG")"
fi
assert_file "gsd fake success: UPower raw stayed stale" "$RAW_FILE" "42"
if [ "$rc" -ne 0 ]; then
    ok "gsd fake success: restore returns non-zero (rc=$rc)"
else
    bad "gsd fake success: gsd's Set rc=0 was mistaken for a completed restore"
fi
assert_file "gsd fake success: state value preserved" "$STATE_FILE" "7"
assert_absent "gsd fake success: pending rolled back" "$RESTORE_PENDING_FILE"

# (d) A verified write consumes both the staged and the live state file.
reset_case
write_state 7
printf '9\n' > "$FAKE_SYSFS"
rc="$(run_fn_rc restore_state)"
assert_eq "write success: restore returns 0" "0" "$rc"
assert_file "write success: UPower raw reaches the saved value" "$RAW_FILE" "7"
assert_absent "write success: state consumed" "$STATE_FILE"
assert_absent "write success: pending consumed" "$RESTORE_PENDING_FILE"

# (f) A failed restore leaves the state for a later, successful retry.
reset_case
write_state 7
export STUB_GSD_FAIL=1 STUB_UPOWER_FAIL=1 STUB_ECTOOL_FAIL=1
rm -f "$FAKE_SYSFS"
rc="$(run_fn_rc restore_state)"
if [ "$rc" -ne 0 ]; then
    ok "retry scenario: first attempt fails (rc=$rc)"
else
    bad "retry scenario: first attempt unexpectedly succeeded"
fi
assert_file "retry scenario: state kept after failure" "$STATE_FILE" "7"
export STUB_GSD_FAIL=0 STUB_UPOWER_FAIL=0 STUB_ECTOOL_FAIL=0
printf '99\n' > "$FAKE_SYSFS"
rc="$(run_fn_rc restore_state)"
assert_eq "retry scenario: second attempt returns 0" "0" "$rc"
assert_file "retry scenario: second attempt reaches the LED" "$RAW_FILE" "7"
assert_absent "retry scenario: state consumed after success" "$STATE_FILE"
assert_absent "retry scenario: pending consumed after success" "$RESTORE_PENDING_FILE"

# (g) The CLI --test-unblank entry point must propagate the restore failure
#     (run in a child process so `exit 1` cannot kill the test harness).
reset_case
write_state 7
cli_rc=0
cli_out="$(
    XDG_RUNTIME_DIR="$D_STATE_DIR" \
        C640_KBD_SYSFS_BRIGHTNESS="$TMP_DIR/no-sysfs-brightness" \
        C640_KBD_SYSFS_MAX="$FAKE_MAX" \
        C640_KBD_FORCE_LEGACY=0 \
        STUB_GSD_FAIL=1 STUB_UPOWER_FAIL=1 STUB_ECTOOL_FAIL=1 STUB_GSD_NOOP=0 \
        STUB_GDBUS_LOG="$GDBUS_LOG" STUB_SET_LOG="$SET_LOG" \
        STUB_ECTOOL_LOG="$TMP_DIR/ectool.log" STUB_FLOCK_DIR="$FLOCK_DIR" \
        STUB_RAW_FILE="$RAW_FILE" STUB_PCT_FILE="$PCT_FILE" \
        STUB_KBD_RAW=42 STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false \
        "$DAEMON" --test-unblank 2> "$DAEMON_ERR"
)" || cli_rc=$?
if [ "$cli_rc" -ne 0 ]; then
    ok "CLI --test-unblank propagates restore failure (rc=$cli_rc)"
else
    bad "CLI --test-unblank returned 0 despite a failed restore: $cli_out"
fi
assert_file "CLI --test-unblank failure: state preserved" "$STATE_FILE" "7"
assert_absent "CLI --test-unblank failure: pending rolled back" "$RESTORE_PENDING_FILE"
if grep -q 'restore failed' "$DAEMON_ERR"; then
    ok "CLI --test-unblank failure: logs 'restore failed'"
else
    bad "CLI --test-unblank failure: no 'restore failed' log (stderr: $(cat "$DAEMON_ERR"))"
fi

# 16. recover_pending_state may only run at daemon startup, never from
#     restore_state (it would mv a value another restore is mid-write on).
reset_case
write_state 7
_orig_recover="$(declare -f recover_pending_state)"
recover_pending_state() {
    printf 'called\n' >> "$RECOVER_LOG"
}
run_fn restore_state
eval "$_orig_recover"
assert_eq "restore_state never calls recover_pending_state" "0" "$(grep -c . "$RECOVER_LOG" || true)"
assert_file "restore_state (no recover) still wrote the saved value" "$RAW_FILE" "7"
assert_absent "restore_state (no recover) still consumed the state" "$STATE_FILE"

# 17. A second restore_state entering during A's slow write must not steal or
#     delete A's staged PENDING value.  This is the concrete race that used to
#     lose state permanently; the nested call is a real restore_state(), not a
#     text/source comparison.
reset_case
write_state 7
_orig_set_brightness_17="$(declare -f set_brightness)"
declare -f set_brightness | sed '1s/^set_brightness ()/real_set_brightness_17 ()/' > "$TMP_DIR/real_set_brightness_17.def"
# shellcheck disable=SC1090
source "$TMP_DIR/real_set_brightness_17.def"
nested_done_17=0
staged_stolen_17=0
set_brightness() {
    if [ "$nested_done_17" -eq 0 ]; then
        nested_done_17=1
        # A has staged PENDING and released STATE_LOCK for the write.
        local staged_before state_before staged_after state_after
        staged_before="$(cat "$RESTORE_PENDING_FILE" 2> /dev/null || echo '<missing>')"
        state_before="$(cat "$STATE_FILE" 2> /dev/null || echo '<missing>')"
        run_fn restore_state
        staged_after="$(cat "$RESTORE_PENDING_FILE" 2> /dev/null || echo '<missing>')"
        state_after="$(cat "$STATE_FILE" 2> /dev/null || echo '<missing>')"
        if [ "$staged_after" != "$staged_before" ] || [ "$state_after" != "$state_before" ]; then
            staged_stolen_17=1
        fi
    fi
    real_set_brightness_17 "$@"
}
run_fn restore_state
eval "$_orig_set_brightness_17"
assert_eq "concurrent restore leaves the staged PENDING untouched" "0" "$staged_stolen_17"
assert_file "concurrent restore writes the saved brightness" "$RAW_FILE" "7"
assert_absent "concurrent restore consumes state" "$STATE_FILE"
assert_absent "concurrent restore consumes pending" "$RESTORE_PENDING_FILE"

# 18. A transient state-lock failure in finalize_restore must NOT orphan
#     PENDING.  The old `flock -n 203` returned 1 on contention while PENDING
#     held the only copy of the saved value (STATE_FILE was already staged
#     away); the "another restore is in progress" guard then blocked every
#     later restore_state/cleanup until a daemon restart.
reset_case
write_state 7
printf '9\n' > "$RAW_FILE"
export STUB_FLOCK_FAIL_FD=203 STUB_FLOCK_FAIL_COUNT=1
rc="$(run_fn_rc restore_state)"
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
assert_eq "finalize flock failure: restore still returns 0" "0" "$rc"
assert_file "finalize flock failure: brightness still written" "$RAW_FILE" "7"
assert_absent "finalize flock failure: PENDING consumed" "$RESTORE_PENDING_FILE"
assert_absent "finalize flock failure: STATE consumed" "$STATE_FILE"
if grep -q 'resolving PENDING without the lock' "$DAEMON_ERR"; then
    ok "finalize flock failure: degraded path logged"
else
    bad "finalize flock failure: no degraded-path log (stderr: $(cat "$DAEMON_ERR"))"
fi
# A later unblank with a fresh state must still be able to restore, i.e. must
# not be skipped by the stale-PENDING guard.
write_state 8
rc="$(run_fn_rc restore_state)"
assert_eq "finalize flock failure: later restore returns 0" "0" "$rc"
assert_file "finalize flock failure: later restore writes its value" "$RAW_FILE" "8"
assert_absent "finalize flock failure: later restore consumes PENDING" "$RESTORE_PENDING_FILE"
if grep -q 'another restore is in progress' "$DAEMON_ERR"; then
    bad "finalize flock failure: stale-PENDING guard blocked the later restore"
else
    ok "finalize flock failure: stale-PENDING guard not tripped"
fi

# 19. Same transient finalize failure on a FAILED write: PENDING must be
#     rolled back to STATE_FILE instead of being orphaned, so a later
#     unblank can still retry the write.
reset_case
write_state 7
export STUB_GSD_FAIL=1 STUB_UPOWER_FAIL=1 STUB_ECTOOL_FAIL=1
rm -f "$FAKE_SYSFS"
export STUB_FLOCK_FAIL_FD=203 STUB_FLOCK_FAIL_COUNT=1
rc="$(run_fn_rc restore_state)"
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
wait 2> /dev/null || true
if [ "$rc" -ne 0 ]; then
    ok "finalize flock failure (failed write): restore reports failure"
else
    bad "finalize flock failure (failed write): restore wrongly returned 0"
fi
assert_file "finalize flock failure (failed write): PENDING rolled back to STATE" "$STATE_FILE" "7"
assert_absent "finalize flock failure (failed write): PENDING not orphaned" "$RESTORE_PENDING_FILE"
export STUB_GSD_FAIL=0 STUB_UPOWER_FAIL=0 STUB_ECTOOL_FAIL=0
printf '99\n' > "$FAKE_SYSFS"
rc="$(run_fn_rc restore_state)"
assert_eq "finalize flock failure (failed write): retry returns 0" "0" "$rc"
assert_file "finalize flock failure (failed write): retry reaches LED" "$RAW_FILE" "7"
assert_absent "finalize flock failure (failed write): retry consumes PENDING" "$RESTORE_PENDING_FILE"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
    exit 1
fi
