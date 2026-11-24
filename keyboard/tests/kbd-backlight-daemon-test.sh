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
FLOCK_LOG="$TMP_DIR/flock.log"
RECOVER_LOG="$TMP_DIR/recover.log"
# Finding #4: dedicated write lock, guard marker and the reserved Tier-2
# sentinel.  The daemon derives these from STATE_DIR at source time.
WRITE_LOCK_FILE="$D_STATE_DIR/c640-kbd-backlight.write.lock"
GUARD_WRITTEN_GEN_FILE="$D_STATE_DIR/c640-kbd-backlight.guard-written-gen"
SELF_WRITE_SENTINEL_FILE="$D_STATE_DIR/c640-kbd-backlight.self-write"
GUARD_ERR="$TMP_DIR/guard.err"
# These three are derived by the daemon at SOURCE time from STATE_DIR, which
# the test only overrides after sourcing.  Pass them in as env overrides so
# the daemon never touches the real /run/user/<uid> runtime dir.
export C640_KBD_WRITE_LOCK="$WRITE_LOCK_FILE"
export C640_KBD_GUARD_WRITTEN_GEN="$GUARD_WRITTEN_GEN_FILE"
export C640_KBD_SELF_WRITE_SENTINEL="$SELF_WRITE_SENTINEL_FILE"
# Controllable sleep gate: fast (default) keeps every existing case instant;
# gate blocks only the guard delays until STUB_SLEEP_RELEASE is created.
STUB_SLEEP_STARTED="$TMP_DIR/sleep-started"
STUB_SLEEP_RELEASE="$TMP_DIR/sleep-release"
STUB_BUMP_FLAG="$TMP_DIR/bump-on-get"
# Retry/interleaving gates.  The retry gate is deliberately SEPARATE from the
# guard gate so a retry can be held in its sleep without wedging guard tests.
STUB_RETRY_GATE="$TMP_DIR/retry-gate"
STUB_RETRY_RELEASE="$TMP_DIR/retry-release"
STUB_RETRY_STARTED="$TMP_DIR/retry-started"
STUB_WLOCK_HELD="$TMP_DIR/write-lock-held"
STUB_WLOCK_RELEASE="$TMP_DIR/write-lock-release"
# Torn-meta injection: a stub cat alternates between an OLD and a NEW meta
# snapshot for the last-user file only.  Old code (two cats) sees old value +
# new generation; the fixed single-read code always sees one coherent record.
STUB_TORN_META="$TMP_DIR/torn-meta"
STUB_TORN_OLD="$TMP_DIR/torn-meta-old"
STUB_TORN_NEW="$TMP_DIR/torn-meta-new"
STUB_TORN_COUNTER="$TMP_DIR/torn-meta-counter"
# P6-7/P6-8: records STATE_FILE's content at the moment set_brightness 0 runs,
# proving the save happened before the LED was switched off.
ORDER_FILE="$TMP_DIR/blank-order"
# One-shot gate for ordered ScreenSaver answers (N2).  A file is required:
# screensaver_tristate() is called from command substitutions, so an in-process
# counter would be lost in each subshell.
STUB_ACTIVE_SEQ_FILE="$TMP_DIR/active-seq"
HANDOFF_DIR="$TMP_DIR/handoff"
HANDOFF_SUSPEND_FILE="$HANDOFF_DIR/c640-kbd-backlight.suspend"
HANDOFF_RESUME_FILE="$HANDOFF_DIR/c640-kbd-backlight.resume"
# An EXPLICIT C640_KBD_HANDOFF_DIR override is the only hook-side directory
# the daemon diagnoses: a handoff there that differs from the daemon's own
# path is a test/configuration error worth a user-visible WARN.  By default
# it is an empty sandbox dir; the mismatch test is the only case that puts a
# handoff there while the daemon's own path stays empty.
HOOK_HANDOFF_DIR="$TMP_DIR/hook-handoff"
HOOK_SUSPEND_FILE="$HOOK_HANDOFF_DIR/c640-kbd-backlight.suspend"
# Sandboxed /run/user root.  The daemon must NOT scan it: another user's 0700
# runtime dir is unreadable, so a "read-only cross-uid scan" cannot diagnose
# anything.  The directory is kept only as a decoy for the no-warn regression.
HOOK_RUN_USER_ROOT="$TMP_DIR/hook-run-user"
LEGACY_LOG="$TMP_DIR/legacy.log"
mkdir -p "$STUB_DIR" "$D_STATE_DIR" "$FLOCK_DIR" "$HANDOFF_DIR" "$HOOK_HANDOFF_DIR" "$HOOK_RUN_USER_ROOT"

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
assert_present() {
    local label="$1" file="$2"
    if [ -e "$file" ]; then
        ok "$label"
    else
        bad "$label (file missing)"
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
            *org.gnome.ScreenSaver*) _ans="${STUB_GNOME_ACTIVE:-false}" ;;
            *) _ans="${STUB_FDO_ACTIVE:-false}" ;;
        esac
        # true/false are explicit answers; fail (timeout/service missing) and
        # anything unrecognisable must drive screensaver_tristate() to unknown.
        case "$_ans" in
            true) printf '(true,)\n' ;;
            false) printf '(false,)\n' ;;
            fail) exit 1 ;;
            *) printf '(garbled,)\n' ;;
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
        # Independent switch: introspection still advertises gsd-power, but
        # the pct query times out/fails.  This is the real "empty pct" path;
        # STUB_GSD_FAIL=1 instead removes the backend entirely.
        if [ "${STUB_GSD_GET_FAIL:-0}" = "1" ]; then
            exit 1
        fi
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
        # Finding #4 "last check" injection: bump the generation on the FIRST
        # brightness read after STUB_BUMP_FLAG is armed.  A guard that decides
        # to write must notice this inside its WRITE_LOCK critical section.
        if [ -f "${STUB_BUMP_FLAG:-/nonexistent}" ]; then
            rm -f "${STUB_BUMP_FLAG}" 2> /dev/null || true
            g="$(cat "${RESTORE_GEN_FILE:-/nonexistent}" 2> /dev/null || echo 0)"
            case "$g" in
                '' | *[!0-9]*) g=0 ;;
            esac
            printf '%s\n' "$((g + 1))" > "${RESTORE_GEN_FILE:-/nonexistent}" 2> /dev/null || true
            printf 'BUMP-ON-GET %s\n' "$*" >> "$STUB_GDBUS_LOG"
        fi
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
# `sleep` cannot wedge later cases.  `-w N` really polls the lockfile with
# /bin/sleep 0.02 (the no-op stub in STUB_DIR must NOT be used here) and exits
# 1 on timeout, so save_state's bounded wait is exercised end to end.
cat > "$STUB_DIR/flock" << 'STUB'
#!/bin/sh
lock_dir="${STUB_FLOCK_DIR:-/tmp}"
fd=""
op=""
wait_secs=0
while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
        -n) op=n ;;
        -u) op=u ;;
        -w)
            op=w
            if [ "$#" -gt 0 ]; then
                wait_secs="$1"
                shift
            fi
            ;;
        -w*) op=w; wait_secs="${arg#-w}" ;;
        -x | -s) ;;
        [0-9]*) fd="$arg" ;;
    esac
done
case "$wait_secs" in
    '' | *[!0-9]*) wait_secs=0 ;;
esac
# 50 polls per second (0.02s each).
polls=$((wait_secs * 50))
[ -n "$fd" ] || exit 0
# Fault injection: fail the first N flock calls for one fd, modelling a
# transient flock error even in blocking mode.  The counter lives next to the
# lock files so reset_case's `rm -f "$FLOCK_DIR"/flock.*` clears it.  It stays
# BEFORE the lockfile check, so an injected failure never waits.
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
# Optional audit trail (off by default): lets a test assert that a specific
# critical section really took STATE_LOCK (e.g. fd 207 in the resume unknown
# convergence path, or fd 200 with op=w in save_state's bounded wait).
printf 'flock fd=%s target=%s op=%s\n' "$fd" "$target" "$op" >> "${STUB_FLOCK_LOG:-/dev/null}" 2> /dev/null || true
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
    w)
        tries=0
        while [ -f "$lockfile" ]; do
            old="$(cat "$lockfile" 2> /dev/null || echo "")"
            if [ -z "$old" ] || ! kill -0 "$old" 2> /dev/null; then
                break
            fi
            if [ "$tries" -ge "$polls" ]; then
                exit 1
            fi
            /bin/sleep 0.02
            tries=$((tries + 1))
        done
        printf '%s\n' "$PPID" > "$lockfile" 2> /dev/null || true
        exit 0
        ;;
    *)
        printf '%s\n' "$PPID" > "$lockfile" 2> /dev/null || true
        exit 0
        ;;
esac
STUB
# sleep is a no-op by default so retry/guard subshells finish at once.  In
# "gate" mode only the four guard delays (0.25/0.3/0.9/1.0s) block until
# $STUB_SLEEP_RELEASE exists, recording each start in $STUB_SLEEP_STARTED.
# That is what makes the stale-guard-vs-new-restore interleaving testable.
cat > "$STUB_DIR/sleep" << 'STUB'
#!/bin/sh
case "${STUB_SLEEP_MODE:-fast}" in
    gate)
        d="${1:-0}"
        # P1 interleaving gate: retries (0.5/1.5/3s) can be held independently
        # of the guard delays, recorded in STUB_RETRY_STARTED so it cannot
        # inflate the guard-gate count used by start_gated_guard().
        if [ -e "${STUB_RETRY_GATE:-/nonexistent}" ]; then
            case "$d" in
                0.5 | 1.5 | 3)
                    printf '%s\n' "$d" >> "${STUB_RETRY_STARTED:-/dev/null}"
                    n=0
                    while [ ! -e "${STUB_RETRY_RELEASE:-/nonexistent}" ]; do
                        /bin/sleep 0.02
                        n=$((n + 1))
                        [ "$n" -gt 2000 ] && exit 0
                    done
                    exit 0
                    ;;
            esac
        fi
        case "$d" in
            0.25 | 0.3 | 0.9 | 1.0)
                printf '%s\n' "$d" >> "${STUB_SLEEP_STARTED:-/dev/null}"
                # Per-delay release files allow deterministic ordering of the
                # two guards; the common release file still releases both.
                # Re-evaluate on every poll: a per-delay file may be created
                # after this subshell entered the gate.
                n=0
                while :; do
                    release="${STUB_SLEEP_RELEASE}.${d}"
                    [ -e "$release" ] || release="${STUB_SLEEP_RELEASE:-/nonexistent}"
                    [ -e "$release" ] && break
                    /bin/sleep 0.02
                    n=$((n + 1))
                    [ "$n" -gt 2000 ] && exit 0
                done
                exit 0
                ;;
        esac
        exit 0
        ;;
    *) exit 0 ;;
esac
STUB
# P2-3: torn last-user meta read.  Only the exact LAST_USER_META_FILE path is
# intercepted, and only while STUB_TORN_META_ON=1.  Even calls get the OLD
# snapshot, odd calls the NEW one, so a guard that cats the meta twice sees
# "old value + new generation" on BOTH of its two delays.
cat > "$STUB_DIR/cat" << 'STUB'
#!/bin/sh
if [ "${STUB_TORN_META_ON:-0}" = "1" ] && [ "$#" -eq 1 ] &&
   [ "$1" = "${LAST_USER_META_FILE:-/nonexistent}" ]; then
    counter="${STUB_TORN_COUNTER:-/nonexistent}"
    n="$(/bin/cat "$counter" 2> /dev/null || echo 0)"
    case "$n" in '' | *[!0-9]*) n=0 ;; esac
    printf '%s\n' "$((n + 1))" > "$counter" 2> /dev/null || true
    if [ $((n % 2)) -eq 0 ]; then
        exec /bin/cat "${STUB_TORN_OLD:-/nonexistent}"
    fi
    exec /bin/cat "${STUB_TORN_NEW:-/nonexistent}"
fi
exec /bin/cat "$@"
STUB
chmod +x "$STUB_DIR/gdbus" "$STUB_DIR/sudo" "$STUB_DIR/ectool" "$STUB_DIR/flock" "$STUB_DIR/sleep" "$STUB_DIR/cat"

# The stub directory MUST win before any daemon function runs: otherwise the
# real session/system bus would be queried (and the real LED could be written).
export PATH="$STUB_DIR:$PATH"

# Phase 4b: the daemon resolves handoff paths at source time, so these must be
# exported BEFORE sourcing it.  Probe cap 0 makes an unknown ScreenSaver answer
# converge immediately (no real sleeping in unit tests).
export C640_KBD_HANDOFF_SUSPEND="$HANDOFF_SUSPEND_FILE"
export C640_KBD_HANDOFF_RESUME="$HANDOFF_RESUME_FILE"
export C640_KBD_HANDOFF_DIR="$HOOK_HANDOFF_DIR"
# Decoy for P3-1: keep the OLD hook-side runtime-root knob exported so that a
# reintroduced cross-uid scan would actually find the other uid's handoff
# below and produce a false WARN.  The current daemon deliberately ignores it.
export C640_KBD_RUN_USER_ROOT="$HOOK_RUN_USER_ROOT"
export C640_KBD_RESUME_PROBE_MAX=0
export C640_KBD_RESUME_ALLOW_UNKNOWN=0

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
export LAST_USER_META_FILE="$D_STATE_DIR/c640-kbd-backlight.last-user.meta"
export RESTORE_GEN_FILE="$D_STATE_DIR/c640-kbd-backlight.restore-gen"
export RESTORE_PENDING_FILE="$D_STATE_DIR/c640-kbd-backlight.restore-pending"
export HANDOFF_SUSPEND_FILE="$HANDOFF_SUSPEND_FILE"
export HANDOFF_RESUME_FILE="$HANDOFF_RESUME_FILE"
export RESUME_LOCK="$D_STATE_DIR/c640-kbd-backlight.resume.lock"
# Belt-and-braces: override the derived globals too (the env overrides above
# normally make this a no-op, but a future refactor must not write outside the
# sandbox).
export WRITE_LOCK="$WRITE_LOCK_FILE"
export GUARD_WRITTEN_GEN_FILE="$GUARD_WRITTEN_GEN_FILE"
export SELF_WRITE_SENTINEL="$SELF_WRITE_SENTINEL_FILE"
export HAVE_GSD_KBD=""
export HAVE_UPOWER_KBD=""

export STUB_GDBUS_LOG="$GDBUS_LOG"
export STUB_SET_LOG="$SET_LOG"
export STUB_ECTOOL_LOG="$TMP_DIR/ectool.log"
export STUB_FLOCK_DIR="$FLOCK_DIR"
export STUB_FLOCK_LOG=/dev/null
export STUB_RAW_FILE="$RAW_FILE"
export STUB_PCT_FILE="$PCT_FILE"
export STUB_KBD_RAW="42"
export STUB_GSD_FAIL="0"
export STUB_GSD_GET_FAIL="0"
export STUB_UPOWER_FAIL="0"
export STUB_GNOME_ACTIVE="false"
export STUB_FDO_ACTIVE="false"
export STUB_GSD_NOOP="0"
export STUB_ECTOOL_FAIL="0"
# Guard interleaving controls (fast by default: all legacy cases stay instant).
export STUB_SLEEP_MODE=fast
export STUB_SLEEP_STARTED="$STUB_SLEEP_STARTED"
export STUB_SLEEP_RELEASE="$STUB_SLEEP_RELEASE"
export STUB_BUMP_FLAG="$STUB_BUMP_FLAG"
export STUB_RETRY_GATE="$STUB_RETRY_GATE"
export STUB_RETRY_RELEASE="$STUB_RETRY_RELEASE"
export STUB_RETRY_STARTED="$STUB_RETRY_STARTED"
export STUB_TORN_META="$STUB_TORN_META"
export STUB_TORN_OLD="$STUB_TORN_OLD"
export STUB_TORN_NEW="$STUB_TORN_NEW"
export STUB_TORN_COUNTER="$STUB_TORN_COUNTER"
export STUB_TORN_META_ON=0

reset_case() {
    # Open every gate BEFORE retiring retry/guard subshells from the previous
    # case, otherwise a still-gated child would keep `wait` blocked.
    : > "$STUB_SLEEP_RELEASE"
    : > "${STUB_SLEEP_RELEASE}.0.25" "${STUB_SLEEP_RELEASE}.0.3" \
        "${STUB_SLEEP_RELEASE}.0.9" "${STUB_SLEEP_RELEASE}.1.0"
    : > "$STUB_RETRY_RELEASE"
    wait 2> /dev/null || true
    : > "$GDBUS_LOG"
    : > "$SET_LOG"
    : > "$DAEMON_ERR"
    : > "$GUARD_ERR"
    : > "$RECOVER_LOG"
    : > "$STUB_ACTIVE_SEQ_FILE"
    : > "$TMP_DIR/ectool.log"
    : > "$LEGACY_LOG"
    rm -f "$STATE_FILE" "$STATE_LOCK" "$LOCK_FILE" "$LAST_USER_FILE" "$LAST_USER_META_FILE" \
        "$RESTORE_GEN_FILE" "$RESTORE_PENDING_FILE" "$D_STATE_DIR"/*.restore-pending \
        "$D_STATE_DIR"/*.meta "$FAKE_SYSFS" "$FAKE_MAX" "$RAW_FILE" "$PCT_FILE" \
        "$HANDOFF_SUSPEND_FILE" "$HANDOFF_RESUME_FILE" "$HOOK_SUSPEND_FILE" \
        "$HOOK_HANDOFF_DIR"/c640-kbd-backlight.resume "$D_STATE_DIR"/*.resume.lock
    # Finding #4 state: write lock, guard marker, Tier-2 sentinel and the
    # controllable sleep gate.  Without this cleanup a gated guard from a
    # previous case can wedge every later case.
    rm -f "$WRITE_LOCK_FILE" "$GUARD_WRITTEN_GEN_FILE" "$SELF_WRITE_SENTINEL_FILE" \
        "$STUB_SLEEP_STARTED" "$STUB_SLEEP_RELEASE" "$STUB_SLEEP_RELEASE".* \
        "$STUB_BUMP_FLAG" \
        "$STUB_RETRY_GATE" "$STUB_RETRY_RELEASE" "$STUB_RETRY_STARTED" \
        "$STUB_WLOCK_HELD" "$STUB_WLOCK_RELEASE" \
        "$STUB_TORN_META" "$STUB_TORN_OLD" "$STUB_TORN_NEW" "$STUB_TORN_COUNTER"
    export STUB_TORN_META_ON=0
    export STUB_SLEEP_MODE=fast
    rm -f "$HOOK_RUN_USER_ROOT"/[0-9]*/c640-kbd-backlight.* 2> /dev/null || true
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
    export STUB_GSD_GET_FAIL="0"
    export STUB_UPOWER_FAIL="0"
    export STUB_GNOME_ACTIVE="false"
    export STUB_FDO_ACTIVE="false"
    export C640_KBD_FORCE_LEGACY=0
    export STUB_GSD_NOOP=0
    export STUB_ECTOOL_FAIL=0
    export C640_KBD_RESUME_PROBE_MAX=0
    export C640_KBD_RESUME_ALLOW_UNKNOWN=0
    # log_warn_once now uses markers in the state dir so it also rate-limits
    # warnings emitted from subshells; clear them for a clean test case.
    rm -f "$D_STATE_DIR"/.warned.* 2> /dev/null || true
    _C640_ZERO_STREAK=0
    last_user_brightness=""
}

write_state() {
    mkdir -p "$D_STATE_DIR"
    printf '%s\n' "$1" > "$STATE_FILE"
}

# Phase 4b helpers: the hook writes these with a trailing newline and never
# deletes them; only a successful daemon adoption/restore consumes them.
write_handoff_suspend() {
    mkdir -p "$HANDOFF_DIR"
    printf '%s\n' "$1" > "$HANDOFF_SUSPEND_FILE"
}

write_handoff_resume() {
    mkdir -p "$HANDOFF_DIR"
    printf '%s suspend\n' "$(date +%s)" > "$HANDOFF_RESUME_FILE"
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

# Finding #4 helpers.  start_gated_guard forks a guard with the controllable
# sleep stub and waits until BOTH of its subshells have entered the gate, so a
# second restore can complete while the first generation's guards are pending.
# Both delays are recorded in $GUARD_STARTED for an assertion that the gate
# really armed.  Do NOT call this in a command substitution: the background
# job must be a child of the main test shell so release_guards' `wait` sees it.
start_gated_guard() {
    local fn="$1" n=0
    shift
    : > "$STUB_SLEEP_STARTED"
    rm -f "$STUB_SLEEP_RELEASE"
    export STUB_SLEEP_MODE=gate
    # The wrapper's own `wait` makes it exit only after BOTH guard subshells
    # finish, so release_guards' `wait` cannot return before their logs land.
    (
        "$fn" "$@" 2> "$GUARD_ERR"
        wait
    ) &
    while [ "$(sort -u "$STUB_SLEEP_STARTED" 2> /dev/null | wc -l)" -lt 2 ] && [ "$n" -lt 400 ]; do
        # /bin/sleep, NOT the stub: the stub is deliberately blocked here.
        /bin/sleep 0.02
        n=$((n + 1))
    done
    GUARD_STARTED="$(sort -u "$STUB_SLEEP_STARTED" 2> /dev/null | tr '\n' ',' || true)"
}

release_guards() {
    : > "$STUB_SLEEP_RELEASE"
    # Let both guards finish their lock/verify/probe work before asserting.
    /bin/sleep 0.4
    wait 2> /dev/null || true
    export STUB_SLEEP_MODE=fast
}

wait_for_file() {
    local target="$1" n=0
    while [ ! -e "$target" ] && [ "$n" -lt 300 ]; do
        /bin/sleep 0.02
        n=$((n + 1))
    done
    [ -e "$target" ]
}

wait_for_line() {
    local target="$1" line="$2" n=0
    while ! grep -Fqx "$line" "$target" 2> /dev/null && [ "$n" -lt 300 ]; do
        /bin/sleep 0.02
        n=$((n + 1))
    done
    grep -Fqx "$line" "$target" 2> /dev/null
}

# Hold the daemon's WRITE_LOCK (fd 209) from a separate process.  Used to park
# a retry between staging PENDING and acquiring the write lock: the exact
# window in which a newer generation can appear.
hold_write_lock() {
    rm -f "$STUB_WLOCK_HELD" "$STUB_WLOCK_RELEASE"
    (
        exec 209> "$WRITE_LOCK_FILE"
        flock -n 209 || exit 1
        : > "$STUB_WLOCK_HELD"
        while [ ! -e "$STUB_WLOCK_RELEASE" ]; do
            /bin/sleep 0.02
        done
        flock -u 209 2> /dev/null || true
        exec 209>&-
    ) &
    if ! wait_for_file "$STUB_WLOCK_HELD"; then
        bad "test harness: WRITE_LOCK holder failed to start"
    fi
}

release_write_lock_holder() {
    : > "$STUB_WLOCK_RELEASE"
    # Also retires the retry subshell that was blocked on fd 209.
    wait 2> /dev/null || true
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
assert_eq "deferred saved 0: initial restore returns 2 (DEFER)" "2" "$rc"
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

# (b) A user brightness change made after the last sampler tick must not be
#     lost to the 5s-old cache: a valid non-zero live reading wins.
reset_case
write_last_user 8 nonzero
printf '30\n' > "$RAW_FILE"
printf '30\n' > "$PCT_FILE"
run_fn save_state
assert_file "live non-zero wins over a stale sampler cache" "$STATE_FILE" "30"

# (b2) TTL expiry: a manual0 cache suppresses a non-zero live reading only
#      while it is fresh.  The age comes from the sidecar's ts=, NOT the file
#      mtime, so the meta content must be rewritten to really cross the TTL.
reset_case
write_last_user 0 manual0
printf 'source=manual0\nts=%s\n' "$(($(date +%s) - 60))" > "$LAST_USER_META_FILE"
printf '30\n' > "$RAW_FILE"
printf '0\n' > "$PCT_FILE"
run_fn save_state
assert_file "expired manual0 cache no longer suppresses a live reading" "$STATE_FILE" "30"

# (b3) Stage 3 preserved: an explicit manual off (two on-screen zeros) is
#      still saved while gsd-power reports off, even though live is non-zero.
reset_case
write_last_user 0 manual0
printf '30\n' > "$RAW_FILE"
printf '0\n' > "$PCT_FILE"
run_fn save_state
assert_file "fresh manual off beats a non-zero firmware residue" "$STATE_FILE" "0"

# (b4) Once gsd-power reports non-zero the user brightened again, so the
#      manual-off cache must not suppress the live reading.
reset_case
write_last_user 0 manual0
printf '30\n' > "$RAW_FILE"
printf '30\n' > "$PCT_FILE"
run_fn save_state
assert_file "manual off is overridden when gsd reports non-zero" "$STATE_FILE" "30"

# (b5) Blank-side zero: firmware already switched the LED off, so the cached
#      user brightness is saved regardless of the cache's age/source.
reset_case
write_last_user 8 nonzero
printf '0\n' > "$RAW_FILE"
printf '0\n' > "$PCT_FILE"
run_fn save_state
assert_file "blank-side zero falls back to the cached brightness" "$STATE_FILE" "8"

# (b6) A failing gsd pct query is treated as "empty", not as 0: with a
#      non-zero sampler cache the live reading still wins.
reset_case
write_last_user 8 nonzero
printf '30\n' > "$RAW_FILE"
printf '30\n' > "$PCT_FILE"
export STUB_GSD_FAIL=1
run_fn save_state
export STUB_GSD_FAIL=0
assert_file "failed gsd pct query does not suppress the live reading" "$STATE_FILE" "30"

# (b6b) A manual0 cache with a FAILING gsd PROPERTIES.GET: the backend is
#       still present (introspect succeeds), so compute_save_brightness really
#       calls gsd_get_pct and gets "empty" => "cannot confirm", NOT 0.  With
#       `|| echo 0` mutation in the daemon this case must FAIL (state 0).
reset_case
write_last_user 0 manual0
printf '30\n' > "$RAW_FILE"
export STUB_GSD_GET_FAIL=1
run_fn save_state
export STUB_GSD_GET_FAIL=0
assert_file "empty gsd pct does not confirm a manual off" "$STATE_FILE" "30"
if grep -q 'Properties.Get' "$GDBUS_LOG"; then
    ok "b6b: gsd pct query was actually attempted (backend present)"
else
    bad "b6b: no Properties.Get; empty-pct path not covered (log: $(cat "$GDBUS_LOG"))"
fi
# Backend absent: gsd is never queried and the live value still wins.
reset_case
write_last_user 0 manual0
printf '30\n' > "$RAW_FILE"
export STUB_GSD_FAIL=1
run_fn save_state
export STUB_GSD_FAIL=0
assert_file "absent gsd backend does not confirm a manual off" "$STATE_FILE" "30"
if grep -q 'Properties.Get' "$GDBUS_LOG"; then
    bad "backend-absent case must not query gsd pct (log: $(cat "$GDBUS_LOG"))"
else
    ok "backend-absent case performs no gsd pct query"
fi
# Explicit pct 0 still confirms it (the b3/p6-18 behaviour must stay intact).
reset_case
write_last_user 0 manual0
printf '30\n' > "$RAW_FILE"
printf '0\n' > "$PCT_FILE"
run_fn save_state
assert_file "explicit gsd pct 0 still confirms a manual off" "$STATE_FILE" "0"

# (b7) Regression: a restart seed from an already-off light must record an
#      explicit off (manual0), not a plain non-zero source.  Otherwise a later
#      blank with a non-zero firmware residue loses the user's "off" intent.
reset_case
printf '0\n' > "$RAW_FILE"
run_fn seed_last_user_from_current
assert_file "restart seed at 0 writes the cached value 0" "$LAST_USER_FILE" "0"
assert_eq "restart seed at 0 writes manual0 source" "manual0" "$(last_user_cache_source)"
# Blank arrives before the sampler can record a fresh manual off: live shows a
# non-zero firmware residue while gsd still reports off.
printf '30\n' > "$RAW_FILE"
printf '0\n' > "$PCT_FILE"
run_fn save_state
assert_file "restart-seeded off survives a non-zero firmware residue" "$STATE_FILE" "0"

# ==========================================================================
# Phase 4b: tristate ScreenSaver + handoff-driven, daemon-owned restore
# ==========================================================================

# P4b-1. Tristate probe: only explicit answers are trusted; everything else is
#        "unknown" (never "false"), including a missing gdbus/busctl tool.
reset_case
export STUB_GNOME_ACTIVE=true
assert_eq "tristate: explicit true -> active" "active" "$(screensaver_tristate)"
export STUB_GNOME_ACTIVE=false
assert_eq "tristate: explicit false -> inactive" "inactive" "$(screensaver_tristate)"
export STUB_GNOME_ACTIVE=fail STUB_FDO_ACTIVE=fail
assert_eq "tristate: GetActive failures -> unknown" "unknown" "$(screensaver_tristate)"
assert_eq "tristate wrapper keeps unknown->false for sampler" "false" "$(screensaver_is_active)"
export STUB_GNOME_ACTIVE=garbled STUB_FDO_ACTIVE=garbled
assert_eq "tristate: unrecognisable replies -> unknown" "unknown" "$(screensaver_tristate)"
export STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false
assert_eq "tristate: no gdbus/busctl tool -> unknown" "unknown" "$(
    command() {
        if [ "$1" = "-v" ] && { [ "${2:-}" = "gdbus" ] || [ "${2:-}" = "busctl" ]; }; then
            return 1
        fi
        builtin command "$@"
    }
    screensaver_tristate
)"

# P4b-2. adopt_suspend_handoff: trailing newline is trimmed, the handoff wins
#        over a differing daemon state, and it is consumed only on success.
reset_case
write_state 9
write_handoff_suspend 7
run_fn adopt_suspend_handoff
assert_file "adopt: handoff overrides differing daemon state" "$STATE_FILE" "7"
assert_absent "adopt: handoff consumed after successful adoption" "$HANDOFF_SUSPEND_FILE"
if grep -q 'overrides differing daemon state' "$DAEMON_ERR"; then
    ok "adopt: difference from daemon state is logged"
else
    bad "adopt: difference not logged (stderr: $(cat "$DAEMON_ERR"))"
fi
# A staged restore owns STATE_FILE: adoption must skip, not overwrite it.
reset_case
write_state 9
printf '7\n' > "$RESTORE_PENDING_FILE"
write_handoff_suspend 7
run_fn adopt_suspend_handoff
assert_file "adopt(pending): staged value untouched" "$RESTORE_PENDING_FILE" "7"
assert_file "adopt(pending): daemon state untouched" "$STATE_FILE" "9"
assert_present "adopt(pending): handoff retained" "$HANDOFF_SUSPEND_FILE"
# Invalid content: warn, do not write state, do not consume the handoff.
reset_case
write_handoff_suspend "not-a-number"
run_fn adopt_suspend_handoff
assert_absent "adopt(invalid): no state written" "$STATE_FILE"
assert_present "adopt(invalid): handoff not consumed" "$HANDOFF_SUSPEND_FILE"
if grep -q 'suspend handoff invalid' "$DAEMON_ERR"; then
    ok "adopt(invalid): warns about invalid handoff"
else
    bad "adopt(invalid): no warning (stderr: $(cat "$DAEMON_ERR"))"
fi

# P3. An EXPLICIT C640_KBD_HANDOFF_DIR override that disagrees with the
# daemon's own handoff path is a test/configuration error: warn instead of
# silently losing the handoff.  Never cross-adopt the override's file.
reset_case
printf '7\n' > "$HOOK_SUSPEND_FILE"
printf '%s suspend\n' "$(date +%s)" > "$HOOK_HANDOFF_DIR/c640-kbd-backlight.resume"
run_fn adopt_suspend_handoff
assert_absent "handoff mismatch: daemon state not cross-adopted" "$STATE_FILE"
assert_present "handoff mismatch: hook copy left untouched" "$HOOK_SUSPEND_FILE"
if grep -q 'handoff directory mismatch' "$DAEMON_ERR"; then
    ok "handoff mismatch: adoption warns about the directory split"
else
    bad "handoff mismatch: no warning (stderr: $(cat "$DAEMON_ERR"))"
fi
write_state 7
run_fn handle_resume
if grep -q 'handoff directory mismatch.*c640-kbd-backlight.resume' "$DAEMON_ERR"; then
    ok "handoff mismatch: resume flag path warns too"
else
    bad "handoff mismatch: no resume-flag warning (stderr: $(cat "$DAEMON_ERR"))"
fi

# P3-1. A handoff in ANOTHER uid's runtime dir must produce NO mismatch WARN
# and must never be cross-adopted.  A real 0700 (here simulated with 000)
# runtime dir cannot be traversed by this daemon, so the old read-only scan
# silently saw nothing and its promised diagnosis was unreliable.  The hook
# now logs uid/session/path/fail-closed to the ROOT journal instead; the
# authoritative diagnostic no longer depends on cross-uid readability.
reset_case
mkdir -p "$HOOK_RUN_USER_ROOT/1001"
printf '7\n' > "$HOOK_RUN_USER_ROOT/1001/c640-kbd-backlight.suspend"
printf '%s suspend\n' "$(date +%s)" > "$HOOK_RUN_USER_ROOT/1001/c640-kbd-backlight.resume"
chmod 000 "$HOOK_RUN_USER_ROOT/1001"
run_fn adopt_suspend_handoff
assert_absent "cross-uid: no cross-adopt into daemon state" "$STATE_FILE"
if grep -q 'handoff directory mismatch' "$DAEMON_ERR"; then
    bad "cross-uid: false mismatch WARN from unreadable dir (stderr: $(cat "$DAEMON_ERR"))"
else
    ok "cross-uid: unreadable other uid's dir produces no mismatch WARN"
fi
chmod 700 "$HOOK_RUN_USER_ROOT/1001"
assert_present "cross-uid: other uid's handoff untouched" "$HOOK_RUN_USER_ROOT/1001/c640-kbd-backlight.suspend"
# Same decoy, now readable: the OLD numeric /run/user/[0-9]*/ scan (with the
# knob exported above) would warn here, so this is a live regression check,
# not just a tautological "no warn" on an unreachable path.
: > "$DAEMON_ERR"
run_fn adopt_suspend_handoff
assert_absent "cross-uid (readable decoy): no cross-adopt into daemon state" "$STATE_FILE"
if grep -q 'handoff directory mismatch' "$DAEMON_ERR"; then
    bad "cross-uid (readable decoy): false mismatch WARN (stderr: $(cat "$DAEMON_ERR"))"
else
    ok "cross-uid (readable decoy): no mismatch WARN"
fi
write_state 7
run_fn handle_resume
if grep -q 'handoff directory mismatch.*/1001' "$DAEMON_ERR"; then
    bad "cross-uid: resume produced a false mismatch WARN (stderr: $(cat "$DAEMON_ERR"))"
else
    ok "cross-uid: resume flag produces no mismatch WARN"
fi

# P3-1 (static guard): the diagnosis function itself must not contain a
# numeric runtime-dir scan or the removed C640_KBD_RUN_USER_ROOT knob.  This
# catches a reintroduced scan even when a decoy happens to be unreadable.
_warn_body="$(awk '/^_warn_hook_side_handoff\(\)/ { in_fn=1 } in_fn { print } in_fn && /^}/ { exit }' "$DAEMON")"
if [ -z "$_warn_body" ]; then
    bad "static guard: cannot locate _warn_hook_side_handoff body"
else
    ok "static guard: located _warn_hook_side_handoff body"
    if printf '%s\n' "$_warn_body" | grep -Eq 'C640_KBD_RUN_USER_ROOT|HOOK_RUN_USER_ROOT|\[0-9\]'; then
        bad "static guard: cross-uid numeric scan reintroduced in _warn_hook_side_handoff"
    else
        ok "static guard: no cross-uid numeric scan in _warn_hook_side_handoff"
    fi
fi

# P4b-3. resume + active: adopt 7, defer, keep state + flag; no LED write.
reset_case
write_handoff_suspend 7
write_handoff_resume
export STUB_GNOME_ACTIVE=true
run_fn handle_resume
wait 2> /dev/null || true
export STUB_GNOME_ACTIVE=false
assert_file "resume(active): handoff adopted into STATE_FILE" "$STATE_FILE" "7"
assert_file "resume(active): RAW_FILE unchanged" "$RAW_FILE" "42"
assert_eq "resume(active): no gsd Properties.Set" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_absent "resume(active): handoff.suspend consumed by adoption" "$HANDOFF_SUSPEND_FILE"
assert_present "resume(active): resume flag retained" "$HANDOFF_RESUME_FILE"
if grep -q 'resume deferred: ScreenSaver still active' "$DAEMON_ERR"; then
    ok "resume(active): logs 'resume deferred'"
else
    bad "resume(active): missing 'resume deferred' log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P4b-4. resume + inactive: exactly one gsd write; all three handoff files
#        consumed; no UPower/legacy/sysfs fallback write.
reset_case
write_handoff_suspend 7
write_handoff_resume
run_fn handle_resume
assert_eq "resume(inactive): exactly one gsd Properties.Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "resume(inactive): RAW_FILE reaches saved value" "$RAW_FILE" "7"
assert_file "resume(inactive): no direct sysfs write" "$FAKE_SYSFS" "99"
assert_absent "resume(inactive): daemon state consumed" "$STATE_FILE"
assert_absent "resume(inactive): handoff.suspend consumed" "$HANDOFF_SUSPEND_FILE"
assert_absent "resume(inactive): handoff.resume consumed" "$HANDOFF_RESUME_FILE"
assert_eq "resume(inactive): no UPower direct write" "0" "$(grep -c 'UPower.SetBrightness' "$SET_LOG" || true)"
assert_eq "resume(inactive): no ectool write" "0" "$(grep -c 'pwmsetkblight' "$TMP_DIR/ectool.log" || true)"

# P4b-5. resume + unknown, saved != current: no write, state + flag kept, WARN.
reset_case
write_handoff_suspend 7
write_handoff_resume
export STUB_GNOME_ACTIVE=fail STUB_FDO_ACTIVE=fail
run_fn handle_resume
export STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false
assert_eq "resume(unknown): no Properties.Set" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "resume(unknown): state retained" "$STATE_FILE" "7"
assert_file "resume(unknown): RAW_FILE unchanged" "$RAW_FILE" "42"
assert_absent "resume(unknown): handoff.suspend consumed by adoption" "$HANDOFF_SUSPEND_FILE"
assert_present "resume(unknown): resume flag retained" "$HANDOFF_RESUME_FILE"
if grep -q '\[WARN\]' "$DAEMON_ERR"; then
    ok "resume(unknown): emits a WARN"
else
    bad "resume(unknown): no WARN (stderr: $(cat "$DAEMON_ERR"))"
fi

# P4b-6. resume + unknown, saved == current: converge WITHOUT any write.
reset_case
write_handoff_suspend 7
write_handoff_resume
printf '7\n' > "$RAW_FILE"
export STUB_GNOME_ACTIVE=fail STUB_FDO_ACTIVE=fail
run_fn handle_resume
export STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false
assert_eq "resume(unknown,same): SET_LOG empty" "0" "$(grep -c . "$SET_LOG" || true)"
assert_file "resume(unknown,same): RAW_FILE unchanged" "$RAW_FILE" "7"
assert_file "resume(unknown,same): FAKE_SYSFS unchanged" "$FAKE_SYSFS" "99"
assert_absent "resume(unknown,same): state consumed without writing" "$STATE_FILE"
assert_absent "resume(unknown,same): resume flag consumed" "$HANDOFF_RESUME_FILE"

# P4b-7. Explicit opt-in restores even when ScreenSaver is unknown.
reset_case
write_handoff_suspend 7
write_handoff_resume
export C640_KBD_RESUME_ALLOW_UNKNOWN=1
export STUB_GNOME_ACTIVE=fail STUB_FDO_ACTIVE=fail
run_fn handle_resume
export STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false
export C640_KBD_RESUME_ALLOW_UNKNOWN=0
assert_eq "resume(allow-unknown): one gsd Properties.Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "resume(allow-unknown): RAW_FILE reaches saved value" "$RAW_FILE" "7"
assert_absent "resume(allow-unknown): state consumed" "$STATE_FILE"
assert_absent "resume(allow-unknown): resume flag consumed" "$HANDOFF_RESUME_FILE"
if grep -q 'C640_KBD_RESUME_ALLOW_UNKNOWN=1' "$DAEMON_ERR"; then
    ok "resume(allow-unknown): opt-in is logged"
else
    bad "resume(allow-unknown): opt-in not logged (stderr: $(cat "$DAEMON_ERR"))"
fi
if grep -q '\[WARN\]' "$DAEMON_ERR"; then
    ok "resume(allow-unknown): emits a WARN"
else
    bad "resume(allow-unknown): no WARN (stderr: $(cat "$DAEMON_ERR"))"
fi

# P2-a. Wall-clock probe deadline.  The old loop counted only sleep delays and
# ignored the time spent in gdbus, so slow queries could hold RESUME_LOCK for
# ~40s.  Simulate a slow/frozen D-Bus by making `date +%s` advance 3s per call;
# with probe_max=2 the daemon must stop after the first tristate probe.
reset_case
write_handoff_suspend 7
write_handoff_resume
export STUB_GNOME_ACTIVE=fail STUB_FDO_ACTIVE=fail
export C640_KBD_RESUME_PROBE_MAX=2
cat > "$STUB_DIR/date" << 'STUB'
#!/bin/sh
clock="${STUB_CLOCK_FILE:-/dev/null}"
n=0
if [ -f "$clock" ]; then n="$(cat "$clock" 2> /dev/null || echo 0)"; fi
case "$n" in '' | *[!0-9]*) n=0 ;; esac
n=$((n + 3))
printf '%s\n' "$n" > "$clock"
echo $((${STUB_CLOCK_BASE:-0} + n))
STUB
chmod +x "$STUB_DIR/date"
export STUB_CLOCK_FILE="$TMP_DIR/slow-clock"
export STUB_CLOCK_BASE=1000
rm -f "$STUB_CLOCK_FILE"
run_fn handle_resume
rm -f "$STUB_DIR/date"
unset STUB_CLOCK_FILE STUB_CLOCK_BASE
export C640_KBD_RESUME_PROBE_MAX=0
export STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false
assert_eq "resume deadline: only one tristate probe (2 GetActive calls)" "2" "$(grep -c 'GetActive' "$GDBUS_LOG" || true)"
assert_file "resume deadline: state retained" "$STATE_FILE" "7"
assert_file "resume deadline: LED untouched" "$RAW_FILE" "42"
assert_absent "resume deadline: handoff.suspend not consumed" "$HANDOFF_SUSPEND_FILE"
assert_present "resume deadline: resume flag retained" "$HANDOFF_RESUME_FILE"
assert_eq "resume deadline: no gsd write" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'probe deadline' "$DAEMON_ERR"; then
    ok "resume deadline: convergence via deadline is logged"
else
    bad "resume deadline: no deadline log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P2-a (b). The deadline is checked AFTER a probe, not as a hard interrupt.
# With a 3s-per-call clock and probe_max=7, two probes run (wall 3 then 6) and
# the second one's post-check trips at wall=9.  This documents the honest
# worst case: ~probe_max + one tristate query (<=6s with two backends).
reset_case
write_handoff_suspend 7
write_handoff_resume
export STUB_GNOME_ACTIVE=fail STUB_FDO_ACTIVE=fail
export C640_KBD_RESUME_PROBE_MAX=7
cat > "$STUB_DIR/date" << 'STUB'
#!/bin/sh
clock="${STUB_CLOCK_FILE:-/dev/null}"
n=0
if [ -f "$clock" ]; then n="$(cat "$clock" 2> /dev/null || echo 0)"; fi
case "$n" in '' | *[!0-9]*) n=0 ;; esac
n=$((n + 3))
printf '%s\n' "$n" > "$clock"
echo $((${STUB_CLOCK_BASE:-0} + n))
STUB
chmod +x "$STUB_DIR/date"
export STUB_CLOCK_FILE="$TMP_DIR/slow-clock-2"
export STUB_CLOCK_BASE=1000
rm -f "$STUB_CLOCK_FILE"
run_fn handle_resume
rm -f "$STUB_DIR/date"
unset STUB_CLOCK_FILE STUB_CLOCK_BASE
export C640_KBD_RESUME_PROBE_MAX=0
export STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false
assert_eq "resume deadline(b): two probes before the post-probe deadline" "4" "$(grep -c 'GetActive' "$GDBUS_LOG" || true)"
assert_file "resume deadline(b): state retained" "$STATE_FILE" "7"
if grep -q 'probe deadline.*after slow query' "$DAEMON_ERR"; then
    ok "resume deadline(b): post-probe expiry is logged"
else
    bad "resume deadline(b): no post-probe deadline log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P4b-8. A handoff value of 0 is real state, not "no state": it is adopted and
#        written through gsd, and consumed like any other value.
reset_case
write_handoff_suspend 0
write_handoff_resume
printf '30\n' > "$RAW_FILE"
printf '30\n' > "$PCT_FILE"
run_fn handle_resume
assert_file "handoff 0: LED written off" "$RAW_FILE" "0"
assert_absent "handoff 0: state consumed" "$STATE_FILE"
assert_absent "handoff 0: handoff.suspend consumed" "$HANDOFF_SUSPEND_FILE"
assert_absent "handoff 0: resume flag consumed" "$HANDOFF_RESUME_FILE"
if grep -q 'Properties.Set' "$SET_LOG"; then
    ok "handoff 0: performed a real writer call"
else
    bad "handoff 0: no writer call (SET_LOG: $(cat "$SET_LOG"))"
fi
# With an active screen the adopted 0 must be visible in STATE_FILE.
reset_case
write_handoff_suspend 0
write_handoff_resume
export STUB_GNOME_ACTIVE=true
run_fn handle_resume
wait 2> /dev/null || true
export STUB_GNOME_ACTIVE=false
assert_file "handoff 0 active: adopted state is 0" "$STATE_FILE" "0"
assert_file "handoff 0 active: LED untouched" "$RAW_FILE" "42"

# P4b-8a (real S3 Branch A).  The screen was already blank at suspend time, so
# the hook's 0 is the blanked LED hardware value, not the user's intent.  The
# daemon's saved 30 must survive, the stale handoff must still be consumed,
# and the active screen must defer any brightness write.
reset_case
write_state 30
write_handoff_suspend 0
write_handoff_resume
export STUB_GNOME_ACTIVE=true
run_fn handle_resume
wait 2> /dev/null || true
export STUB_GNOME_ACTIVE=false
assert_file "blank-side handoff 0: saved user brightness 30 retained" "$STATE_FILE" "30"
assert_absent "blank-side handoff 0: stale handoff consumed" "$HANDOFF_SUSPEND_FILE"
assert_present "blank-side handoff 0: resume flag retained while deferred" "$HANDOFF_RESUME_FILE"
assert_file "blank-side handoff 0: LED untouched" "$RAW_FILE" "42"
assert_eq "blank-side handoff 0: no gsd write" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'ignoring blank-side suspend handoff 0; keeping saved user brightness 30' "$DAEMON_ERR"; then
    ok "blank-side handoff 0: override is logged and explained"
else
    bad "blank-side handoff 0: no ignore log (stderr: $(cat "$DAEMON_ERR"))"
fi
if grep -q 'resume deferred: ScreenSaver still active (saved=30)' "$DAEMON_ERR"; then
    ok "blank-side handoff 0: resume defers with the saved value 30"
else
    bad "blank-side handoff 0: no deferred-resume log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P4b-8b.  A handoff 0 with a valid saved 0 (or with no usable saved state) is
# still a real "user switched it off" and must be adopted as before.
reset_case
write_state 0
write_handoff_suspend 0
run_fn adopt_suspend_handoff
assert_file "handoff 0 + saved 0: adopted 0 is retained" "$STATE_FILE" "0"
assert_absent "handoff 0 + saved 0: handoff consumed" "$HANDOFF_SUSPEND_FILE"
if grep -q 'ignoring blank-side' "$DAEMON_ERR"; then
    bad "handoff 0 + saved 0: incorrectly treated as blank-side (stderr: $(cat "$DAEMON_ERR"))"
else
    ok "handoff 0 + saved 0: not treated as a blank-side handoff"
fi
reset_case
printf 'garbage\n' > "$STATE_FILE"
write_handoff_suspend 0
run_fn adopt_suspend_handoff
assert_file "handoff 0 + invalid saved state: adopted 0" "$STATE_FILE" "0"
assert_absent "handoff 0 + invalid saved state: handoff consumed" "$HANDOFF_SUSPEND_FILE"

# P4b-8c.  A non-zero handoff keeps unconditional priority over daemon state.
reset_case
write_state 8
write_handoff_suspend 30
run_fn adopt_suspend_handoff
assert_file "handoff 30: overrides daemon state 8" "$STATE_FILE" "30"
assert_absent "handoff 30: handoff consumed" "$HANDOFF_SUSPEND_FILE"
if grep -q 'suspend handoff 30 overrides differing daemon state 8' "$DAEMON_ERR"; then
    ok "handoff 30: override is logged"
else
    bad "handoff 30: override not logged (stderr: $(cat "$DAEMON_ERR"))"
fi

# P2-b. STATE_FILE holds 30 (a DEFER left it there), but the user then switched
# the light off: the cache is 0/source=manual0 and fresh.  The hook's handoff 0
# is genuine user intent now, so it must be adopted instead of re-lighting 30.
reset_case
write_state 30
write_last_user 0 manual0
write_handoff_suspend 0
write_handoff_resume
printf '30\n' > "$RAW_FILE"
# P2-3: the adopt path now demands an EXPLICIT gsd 0 as confirmation too.
printf '0\n' > "$PCT_FILE"
run_fn handle_resume
assert_file "P2-b: fresh manual0 adopts handoff 0 over saved 30" "$RAW_FILE" "0"
assert_absent "P2-b: saved state consumed after adopting 0" "$STATE_FILE"
assert_absent "P2-b: handoff 0 consumed" "$HANDOFF_SUSPEND_FILE"
assert_absent "P2-b: resume flag consumed" "$HANDOFF_RESUME_FILE"
if grep -q 'fresh manual off' "$DAEMON_ERR"; then
    ok "P2-b: manual0 adoption is explained in the log"
else
    bad "P2-b: no manual0 adoption log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P2-b (negative).  An EXPIRED manual0 cache is no evidence of current intent,
# so the blank-side 0 must still be ignored (the original Branch A behaviour).
reset_case
write_state 30
write_last_user 0 manual0
printf 'source=manual0\nts=%s\n' "$(($(date +%s) - 60))" > "$LAST_USER_META_FILE"
printf '0\n' > "$PCT_FILE"
write_handoff_suspend 0
write_handoff_resume
export STUB_GNOME_ACTIVE=true
run_fn handle_resume
wait 2> /dev/null || true
export STUB_GNOME_ACTIVE=false
assert_file "P2-b: stale manual0 still ignores blank-side handoff 0" "$STATE_FILE" "30"
assert_file "P2-b: stale case leaves LED untouched" "$RAW_FILE" "42"
if grep -q 'ignoring blank-side suspend handoff 0' "$DAEMON_ERR"; then
    ok "P2-b: stale manual0 case logs the blank-side override"
else
    bad "P2-b: no blank-side override log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P2-b (negative).  A cache that records a non-zero user brightness is also
# blank-side evidence, not a fresh manual off.
reset_case
write_state 30
write_last_user 30 nonzero
printf '0\n' > "$PCT_FILE"
write_handoff_suspend 0
run_fn adopt_suspend_handoff
assert_file "P2-b: nonzero cache keeps saved 30 against handoff 0" "$STATE_FILE" "30"
assert_absent "P2-b: nonzero cache case consumes the stale handoff" "$HANDOFF_SUSPEND_FILE"

# Reviewer B P3. The `lu = 0` condition must be isolated: a FRESH manual0
# source with LU=30 is not an explicit off even when gsd reports 0.  Removing
# `[ "$lu" = "0" ]` from the daemon makes this case adopt 0 and fail.
reset_case
write_state 30
write_last_user 30 manual0
printf '0\n' > "$PCT_FILE"
write_handoff_suspend 0
run_fn adopt_suspend_handoff
assert_file "P2-b: manual0 source with lu=30 still keeps saved 30" "$STATE_FILE" "30"
assert_absent "P2-b: lu=30 case consumes the stale handoff" "$HANDOFF_SUSPEND_FILE"

# P2-3. gsd query failure (backend PRESENT, Properties.Get fails) yields empty,
# which is "cannot confirm" -- a fresh manual0 cache must NOT turn the hook's
# blank-side 0 into user intent.  Saved 30 must survive.
reset_case
write_state 30
write_last_user 0 manual0
printf '30\n' > "$RAW_FILE"
export STUB_GSD_GET_FAIL=1
write_handoff_suspend 0
# Adoption only: a full handle_resume() with an inactive screen would restore
# the saved value and consume STATE_FILE, obscuring the adopt decision.
run_fn adopt_suspend_handoff
export STUB_GSD_GET_FAIL=0
assert_file "P2-3: empty gsd pct keeps saved 30 against handoff 0" "$STATE_FILE" "30"
assert_file "P2-3: LED untouched" "$RAW_FILE" "30"
assert_absent "P2-3: unconfirmed handoff 0 consumed without adopting" "$HANDOFF_SUSPEND_FILE"
if grep -q 'manual off not confirmed by gsd pct' "$DAEMON_ERR"; then
    ok "P2-3: unconfirmed manual-off adoption is explained"
else
    bad "P2-3: no unconfirmed log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P2-3 (sampler). Two on-screen zeros with a FAILING gsd pct query must not be
# promoted to manual0; only an explicit pct 0 may do that.
reset_case
printf '0\n' > "$RAW_FILE"
export STUB_GSD_GET_FAIL=1
run_fn sample_brightness_once
run_fn sample_brightness_once
export STUB_GSD_GET_FAIL=0
assert_absent "P2-3: no manual0 cache from unconfirmed zeros" "$LAST_USER_FILE"
if [ -f "$LAST_USER_META_FILE" ] && grep -q 'source=manual0' "$LAST_USER_META_FILE"; then
    bad "P2-3: unconfirmed zeros were recorded as manual0"
else
    ok "P2-3: unconfirmed zeros are not recorded as manual0"
fi
reset_case
printf '0\n' > "$RAW_FILE"
printf '0\n' > "$PCT_FILE"
run_fn sample_brightness_once
run_fn sample_brightness_once
assert_file "P2-3: explicit pct 0 still records manual0" "$LAST_USER_FILE" "0"
assert_eq "P2-3: explicit pct 0 records source manual0" "manual0" "$(last_user_cache_source)"

# P4b-9. Legacy/sysfs/ectool writers must never be called by the resume path.
reset_case
write_handoff_suspend 7
write_handoff_resume
_orig_legacy="$(declare -f legacy_set_brightness)"
legacy_set_brightness() {
    printf 'legacy %s\n' "$*" >> "$LEGACY_LOG"
    return 0
}
run_fn handle_resume
eval "$_orig_legacy"
assert_eq "resume: legacy_set_brightness never called" "0" "$(grep -c . "$LEGACY_LOG" || true)"
assert_file "resume: gsd wrote the saved value" "$RAW_FILE" "7"
assert_file "resume: no direct sysfs write" "$FAKE_SYSFS" "99"

# P4b-10. Retry path is fail-closed too: valid generation + active/unknown ->
#         no write; inactive -> one gsd write (state consumed after staging).
reset_case
write_state 7
bump_restore_gen
export STUB_GNOME_ACTIVE=true
# shellcheck disable=SC2154  # restore_gen is a global set by bump_restore_gen
schedule_restore_retries "$restore_gen" 0.5 1.5 3
wait 2> /dev/null || true
export STUB_GNOME_ACTIVE=false
assert_eq "retry(active): no Properties.Set" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "retry(active): state retained" "$STATE_FILE" "7"
assert_file "retry(active): RAW_FILE unchanged" "$RAW_FILE" "42"
reset_case
write_state 7
bump_restore_gen
export STUB_GNOME_ACTIVE=fail STUB_FDO_ACTIVE=fail
# shellcheck disable=SC2154  # restore_gen is a global set by bump_restore_gen
schedule_restore_retries "$restore_gen" 0.5 1.5 3
wait 2> /dev/null || true
export STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false
assert_eq "retry(unknown): no Properties.Set" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "retry(unknown): state retained" "$STATE_FILE" "7"
assert_file "retry(unknown): RAW_FILE unchanged" "$RAW_FILE" "42"
reset_case
write_state 7
bump_restore_gen
# shellcheck disable=SC2154  # restore_gen is a global set by bump_restore_gen
schedule_restore_retries "$restore_gen" 0.5 1.5 3
wait 2> /dev/null || true
assert_eq "retry(inactive): exactly one gsd Properties.Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "retry(inactive): RAW_FILE reaches saved value" "$RAW_FILE" "7"
assert_absent "retry(inactive): state consumed" "$STATE_FILE"

# P4b-11. Startup recovery catches a resume flag left behind by a daemon
#         restart / dead dbus-monitor; without a flag it is a no-op.
reset_case
write_handoff_suspend 7
write_handoff_resume
run_fn startup_resume_handoff
assert_eq "startup handoff: one gsd Properties.Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "startup handoff: RAW_FILE reaches saved value" "$RAW_FILE" "7"
assert_absent "startup handoff: handoff.suspend consumed" "$HANDOFF_SUSPEND_FILE"
assert_absent "startup handoff: resume flag consumed" "$HANDOFF_RESUME_FILE"
assert_absent "startup handoff: state consumed" "$STATE_FILE"
reset_case
write_state 7
run_fn startup_resume_handoff
assert_eq "startup without flag: no restore write" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "startup without flag: state untouched" "$STATE_FILE" "7"

# P4b-12. gsd Set failure in the resume scenario: state + flag kept, WARN.
reset_case
write_handoff_suspend 7
write_handoff_resume
export STUB_GSD_FAIL=1 STUB_UPOWER_FAIL=1 STUB_ECTOOL_FAIL=1
rm -f "$FAKE_SYSFS"
run_fn handle_resume
wait 2> /dev/null || true
export STUB_GSD_FAIL=0 STUB_UPOWER_FAIL=0 STUB_ECTOOL_FAIL=0
assert_file "resume(gsd fail): state preserved" "$STATE_FILE" "7"
assert_present "resume(gsd fail): resume flag retained" "$HANDOFF_RESUME_FILE"
assert_file "resume(gsd fail): RAW_FILE unchanged" "$RAW_FILE" "42"
if grep -q 'restore failed' "$DAEMON_ERR"; then
    ok "resume(gsd fail): logs 'restore failed'"
else
    bad "resume(gsd fail): no 'restore failed' log (stderr: $(cat "$DAEMON_ERR"))"
fi
if grep -q '\[WARN\]' "$DAEMON_ERR"; then
    ok "resume(gsd fail): emits a WARN"
else
    bad "resume(gsd fail): no WARN (stderr: $(cat "$DAEMON_ERR"))"
fi

# P4b-13. No state and no handoff: clear the flag, write nothing.
reset_case
write_handoff_resume
run_fn handle_resume
assert_absent "resume(no state): resume flag cleared" "$HANDOFF_RESUME_FILE"
assert_eq "resume(no state): no gsd write" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "resume(no state): RAW_FILE unchanged" "$RAW_FILE" "42"

# P4b-14 (P1 reentry).  An unblank that arrives before login1's resume signal
# must not race handle_resume: with a resume flag present it is routed through
# handle_resume (RESUME_LOCK), which writes once and consumes the handoff.  A
# later handle_resume (login1 false) then sees no state/flag and is a no-op.
reset_case
write_state 7
write_handoff_suspend 7
write_handoff_resume
run_fn handle_unblank
assert_eq "P1 reentry: handle_unblank issues exactly one gsd Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "P1 reentry: handoff value written once" "$RAW_FILE" "7"
assert_absent "P1 reentry: state consumed" "$STATE_FILE"
assert_absent "P1 reentry: handoff.suspend consumed" "$HANDOFF_SUSPEND_FILE"
assert_absent "P1 reentry: resume flag consumed" "$HANDOFF_RESUME_FILE"
if grep -q 'routing through handle_resume' "$DAEMON_ERR"; then
    ok "P1 reentry: unblank logged the resume routing"
else
    bad "P1 reentry: unblank did not log resume routing (stderr: $(cat "$DAEMON_ERR"))"
fi
: > "$SET_LOG"
run_fn handle_resume
assert_eq "P1 reentry: late handle_resume issues no gsd Set" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "P1 reentry: late handle_resume leaves brightness alone" "$RAW_FILE" "7"

# P4b-15 (P1 stale handoff).  If the user changes the brightness to 9 between
# the unblank and the late handle_resume, the stale handoff 7 must not be
# adopted/written a second time.
reset_case
write_state 7
write_handoff_suspend 7
write_handoff_resume
run_fn handle_unblank
assert_eq "P1 stale: routed unblank issued exactly one gsd Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
printf '9\n' > "$RAW_FILE"
: > "$SET_LOG"
run_fn handle_resume
assert_eq "P1 stale: late handle_resume issues no gsd Set" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "P1 stale: user brightness 9 not overwritten by old handoff 7" "$RAW_FILE" "9"
assert_absent "P1 stale: state consumed" "$STATE_FILE"
assert_absent "P1 stale: handoff.suspend consumed" "$HANDOFF_SUSPEND_FILE"
assert_absent "P1 stale: resume flag consumed" "$HANDOFF_RESUME_FILE"

# P4b-16 (P2-1 deferred handoff).  While a staged restore owns STATE_FILE the
# adoption must defer loudly: flag + handoff + staged value all stay, no write.
# Once PENDING disappears the next handle_resume adopts and restores normally.
reset_case
# STATE_FILE was staged into PENDING by an in-flight restore: only PENDING
# holds the staged value.  A naive handle_resume would see "no saved state"
# and clear the flag while the restore is still flying (P2-1).
printf '9\n' > "$RESTORE_PENDING_FILE"
write_handoff_suspend 7
write_handoff_resume
run_fn handle_resume
assert_present "P2-1: resume flag retained while PENDING exists" "$HANDOFF_RESUME_FILE"
assert_present "P2-1: handoff.suspend retained while PENDING exists" "$HANDOFF_SUSPEND_FILE"
assert_file "P2-1: staged value untouched" "$RESTORE_PENDING_FILE" "9"
assert_absent "P2-1: no daemon state written while staged" "$STATE_FILE"
assert_eq "P2-1: no gsd Set while deferred" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'handoff adoption deferred' "$DAEMON_ERR"; then
    ok "P2-1: deferral is logged"
else
    bad "P2-1: deferral not logged (stderr: $(cat "$DAEMON_ERR"))"
fi
rm -f "$RESTORE_PENDING_FILE"
: > "$SET_LOG"
run_fn handle_resume
assert_eq "P2-1: retry after PENDING vanished issues one gsd Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "P2-1: retry writes adopted handoff 7" "$RAW_FILE" "7"
assert_absent "P2-1: retry consumes state" "$STATE_FILE"
assert_absent "P2-1: retry consumes handoff.suspend" "$HANDOFF_SUSPEND_FILE"
assert_absent "P2-1: retry consumes resume flag" "$HANDOFF_RESUME_FILE"

# P4b-17 (P2-2 locked convergence).  Simulate a blank arriving while the
# unknown-brightness probe is in flight: it writes a NEW state (9) to
# STATE_FILE.  The daemon must re-read under STATE_LOCK and keep that value
# instead of deleting it.  The flock stub audit also proves the critical
# section really acquired STATE_LOCK (fd 207).
reset_case
write_state 7
write_handoff_suspend 7
write_handoff_resume
printf '7\n' > "$RAW_FILE"
export STUB_GNOME_ACTIVE=fail STUB_FDO_ACTIVE=fail
export STUB_FLOCK_LOG="$FLOCK_LOG"
: > "$FLOCK_LOG"
_orig_get_brightness="$(declare -f get_brightness)"
get_brightness() {
    printf '9\n' > "$STATE_FILE" # a concurrent blank saves a newer value
    printf '7\n'                 # hardware still shows the saved 7
}
run_fn handle_resume
eval "$_orig_get_brightness"
export STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false
export STUB_FLOCK_LOG=/dev/null
assert_eq "P2-2: no gsd Set on unknown convergence" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "P2-2: concurrent blank state 9 survives" "$STATE_FILE" "9"
assert_file "P2-2: raw unchanged" "$RAW_FILE" "7"
assert_present "P2-2: resume flag retained (no convergence)" "$HANDOFF_RESUME_FILE"
if grep -q 'state changed to 9 during probe' "$DAEMON_ERR"; then
    ok "P2-2: changed state is detected and logged"
else
    bad "P2-2: changed state not logged (stderr: $(cat "$DAEMON_ERR"))"
fi
if grep -q 'flock fd=207 .* op=n' "$FLOCK_LOG"; then
    ok "P2-2: STATE_LOCK acquired around the convergence critical section"
else
    bad "P2-2: STATE_LOCK not acquired (flock log: $(cat "$FLOCK_LOG"))"
fi

# ==========================================================================
# Phase 1 (sixth re-review, P1): result-code contract
# RC_DONE=0 is the ONLY code that may delete the resume flag / saved state.
# RC_DEFER=2 (retryable) and RC_FAIL=1 (invalid/I/O) must keep it.
# ==========================================================================

# Retry subshells scheduled by earlier cases can outlive their parent
# handle_resume() subshell (reset_case's `wait` only reaps this shell's jobs).
# Push the generation far ahead of every earlier case so any stale retry sees
# a generation mismatch and exits before touching this case's state.
isolate_retry_generation() {
    local n=20
    while [ "$n" -gt 0 ]; do
        bump_restore_gen
        n=$((n - 1))
    done
}

# N1. adopt_suspend_handoff() lock contention must DEFER rather than silently
# succeed (the old `exit 0` made handle_resume delete the flag forever).
reset_case
isolate_retry_generation
write_state 30
write_handoff_suspend 30
write_handoff_resume
export STUB_FLOCK_FAIL_FD=205 STUB_FLOCK_FAIL_COUNT=1
rc="$(run_fn_rc handle_resume)"
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
wait 2> /dev/null || true
assert_eq "N1: adopt lock contention returns DEFER (2)" "2" "$rc"
assert_present "N1: resume flag retained" "$HANDOFF_RESUME_FILE"
assert_present "N1: suspend handoff retained" "$HANDOFF_SUSPEND_FILE"
assert_file "N1: saved state retained" "$STATE_FILE" "30"
assert_file "N1: LED untouched while deferred" "$RAW_FILE" "42"
assert_eq "N1: no gsd write while deferred" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'handoff adoption deferred: state lock busy' "$DAEMON_ERR"; then
    ok "N1: lock contention is logged as a deferral"
else
    bad "N1: no deferral log (stderr: $(cat "$DAEMON_ERR"))"
fi
: > "$SET_LOG"
run_fn sample_brightness_once
assert_eq "N1: sampler retry issues exactly one gsd Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "N1: sampler retry writes adopted 30" "$RAW_FILE" "30"
assert_absent "N1: state consumed after retry" "$STATE_FILE"
assert_absent "N1: suspend handoff consumed after retry" "$HANDOFF_SUSPEND_FILE"
assert_absent "N1: resume flag consumed after retry" "$HANDOFF_RESUME_FILE"

# N2. Deferred restore: outer ScreenSaver probe sees inactive, but the
# fail-closed probe inside restore_state() sees active.  Nothing is written and
# the flag must survive; clearing the gate lets the next attempt converge.
reset_case
isolate_retry_generation
write_state 7
write_handoff_suspend 7
write_handoff_resume
_orig_tristate_n2="$(declare -f screensaver_tristate)"
declare -f screensaver_tristate | sed '1s/^screensaver_tristate ()/real_screensaver_tristate_n2 ()/' > "$TMP_DIR/real_tristate_n2.def"
# shellcheck disable=SC1090
source "$TMP_DIR/real_tristate_n2.def"
_n2_gate=1
screensaver_tristate() {
    if [ "$_n2_gate" -eq 1 ]; then
        local n
        n="$(cat "$STUB_ACTIVE_SEQ_FILE" 2> /dev/null || echo 0)"
        case "$n" in
            '' | *[!0-9]*) n=0 ;;
        esac
        n=$((n + 1))
        printf '%s\n' "$n" > "$STUB_ACTIVE_SEQ_FILE"
        if [ "$n" -ge 2 ]; then
            echo "active"
            return 0
        fi
    fi
    real_screensaver_tristate_n2
}
# The deferral normally schedules retries; suppressing them here keeps the
# assertions below a pure observation of the first attempt.  Retry behaviour
# is exercised by the explicit second handle_resume() call.
_orig_schedule_n2="$(declare -f schedule_restore_retries)"
schedule_restore_retries() { :; }
rc="$(run_fn_rc handle_resume)"
eval "$_orig_schedule_n2"
eval "$_orig_tristate_n2"
wait 2> /dev/null || true
assert_eq "N2: inner active restore returns DEFER (2)" "2" "$rc"
assert_present "N2: resume flag retained" "$HANDOFF_RESUME_FILE"
assert_file "N2: state retained" "$STATE_FILE" "7"
assert_file "N2: LED untouched" "$RAW_FILE" "42"
assert_eq "N2: no gsd write while inner screen active" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'resume: restore deferred (rc=2)' "$DAEMON_ERR"; then
    ok "N2: deferral is logged by the resume handler"
else
    bad "N2: no resume deferral log (stderr: $(cat "$DAEMON_ERR"))"
fi
: > "$SET_LOG"
rc="$(run_fn_rc handle_resume)"
assert_eq "N2: retry after the gate cleared returns DONE" "0" "$rc"
assert_eq "N2: retry issues one gsd Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "N2: retry writes 7" "$RAW_FILE" "7"
assert_absent "N2: state consumed after retry" "$STATE_FILE"
assert_absent "N2: resume flag consumed after retry" "$HANDOFF_RESUME_FILE"

# N3. An invalid suspend handoff is a FAILURE (1), not a success: the resume
# flag and the handoff are kept so a corrected handoff can be adopted later.
reset_case
isolate_retry_generation
write_handoff_suspend "not-a-number"
write_handoff_resume
rc="$(run_fn_rc handle_resume)"
assert_eq "N3: invalid handoff returns FAIL (1)" "1" "$rc"
assert_present "N3: resume flag retained" "$HANDOFF_RESUME_FILE"
assert_present "N3: invalid handoff retained" "$HANDOFF_SUSPEND_FILE"
assert_absent "N3: no state written" "$STATE_FILE"
assert_eq "N3: no gsd write" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'suspend handoff invalid' "$DAEMON_ERR"; then
    ok "N3: invalid handoff warns"
else
    bad "N3: no invalid-handoff warning (stderr: $(cat "$DAEMON_ERR"))"
fi
write_handoff_suspend 7
rc="$(run_fn_rc handle_resume)"
assert_eq "N3: retry with a corrected handoff returns DONE" "0" "$rc"
assert_eq "N3: retry issues one gsd Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "N3: retry writes 7" "$RAW_FILE" "7"
assert_absent "N3: handoff consumed after retry" "$HANDOFF_SUSPEND_FILE"
assert_absent "N3: resume flag consumed after retry" "$HANDOFF_RESUME_FILE"

# N4. restore_state()'s own lock contention must DEFER, never return success.
reset_case
isolate_retry_generation
write_state 7
write_handoff_suspend 7
write_handoff_resume
export STUB_FLOCK_FAIL_FD=201 STUB_FLOCK_FAIL_COUNT=1
rc="$(run_fn_rc handle_resume)"
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
wait 2> /dev/null || true
assert_eq "N4: restore lock contention returns DEFER (2)" "2" "$rc"
assert_present "N4: resume flag retained" "$HANDOFF_RESUME_FILE"
assert_file "N4: state retained" "$STATE_FILE" "7"
assert_file "N4: LED untouched" "$RAW_FILE" "42"
assert_eq "N4: no gsd write while locked out" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'restore deferred: state lock busy' "$DAEMON_ERR"; then
    ok "N4: restore lock contention is logged as deferred"
else
    bad "N4: no restore deferral log (stderr: $(cat "$DAEMON_ERR"))"
fi
: > "$SET_LOG"
rc="$(run_fn_rc handle_resume)"
assert_eq "N4: retry once the lock is free returns DONE" "0" "$rc"
assert_eq "N4: retry issues one gsd Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "N4: retry writes 7" "$RAW_FILE" "7"
assert_absent "N4: state consumed after retry" "$STATE_FILE"
assert_absent "N4: resume flag consumed after retry" "$HANDOFF_RESUME_FILE"

# N5. A zero write/finalize rc is not proof of completion.  Simulate a blank
# writing a NEW state right after finalize: verify must detect STATE_FILE and
# return DEFER instead of letting handle_resume consume the flag.
reset_case
isolate_retry_generation
write_state 7
write_handoff_suspend 7
write_handoff_resume
_orig_finalize_n5="$(declare -f finalize_restore)"
declare -f finalize_restore | sed '1s/^finalize_restore ()/real_finalize_n5 ()/' > "$TMP_DIR/real_finalize_n5.def"
# shellcheck disable=SC1090
source "$TMP_DIR/real_finalize_n5.def"
_orig_schedule_n5="$(declare -f schedule_restore_retries)"
# Keep the injected state in place for the assertions; retry scheduling itself
# is covered by the other cases.
schedule_restore_retries() { :; }
finalize_restore() {
    real_finalize_n5 "$@"
    local frc=$?
    printf '9\n' > "$STATE_FILE" # a blank saves a newer value after finalize
    return "$frc"
}
rc="$(run_fn_rc handle_resume)"
eval "$_orig_finalize_n5"
eval "$_orig_schedule_n5"
assert_eq "N5: lingering STATE after a zero-rc write returns DEFER (2)" "2" "$rc"
assert_file "N5: newer state 9 is not consumed" "$STATE_FILE" "9"
assert_present "N5: resume flag retained" "$HANDOFF_RESUME_FILE"
assert_eq "N5: gsd did write the saved 7" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'STATE/PENDING still exists; not completed' "$DAEMON_ERR"; then
    ok "N5: incomplete restore is logged"
else
    bad "N5: no 'not completed' log (stderr: $(cat "$DAEMON_ERR"))"
fi

# N6. A zero write rc with a mismatching readback is a FAILURE, not success;
# the state must NOT be re-seeded (the mismatch may be user intent).
reset_case
isolate_retry_generation
write_handoff_suspend 7
write_handoff_resume
_orig_set_brightness_n6="$(declare -f set_brightness)"
declare -f set_brightness | sed '1s/^set_brightness ()/real_set_brightness_n6 ()/' > "$TMP_DIR/real_set_brightness_n6.def"
# shellcheck disable=SC1090
source "$TMP_DIR/real_set_brightness_n6.def"
set_brightness() {
    real_set_brightness_n6 "$@"
    local brc=$?
    printf '42\n' > "$RAW_FILE" # hardware never applied the write
    return "$brc"
}
rc="$(run_fn_rc handle_resume)"
eval "$_orig_set_brightness_n6"
wait 2> /dev/null || true
assert_eq "N6: readback mismatch returns FAIL (1)" "1" "$rc"
assert_present "N6: resume flag retained" "$HANDOFF_RESUME_FILE"
assert_absent "N6: state not re-seeded after a mismatch" "$STATE_FILE"
assert_absent "N6: pending absent" "$RESTORE_PENDING_FILE"
if grep -q 'brightness readback 42 != 7; not completed' "$DAEMON_ERR"; then
    ok "N6: readback mismatch warns"
else
    bad "N6: no readback warning (stderr: $(cat "$DAEMON_ERR"))"
fi

# N7. handle_unblank() routes through handle_resume(), normalises DEFER to 0
# (so dbus-monitor's `|| log_warn` does not print a false failure), and the
# login1 monitor applies the same normalisation.
reset_case
isolate_retry_generation
write_state 30
write_handoff_suspend 30
write_handoff_resume
export STUB_FLOCK_FAIL_FD=205 STUB_FLOCK_FAIL_COUNT=3
rc="$(run_fn_rc handle_unblank)"
assert_eq "N7: handle_unblank normalises DEFER to 0" "0" "$rc"
assert_present "N7: resume flag retained on deferral" "$HANDOFF_RESUME_FILE"
assert_eq "N7: no gsd write while adoption is deferred" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'routing through handle_resume' "$DAEMON_ERR"; then
    ok "N7: unblank routed through handle_resume"
else
    bad "N7: unblank did not route through handle_resume"
fi
: > "$DAEMON_ERR"
if handle_unblank 2> /dev/null; then
    ok "N7: \`handle_unblank || log_warn\` sees no false failure on DEFER"
else
    bad "N7: handle_unblank still reports a false failure on DEFER"
fi
# Same rc=2 path through monitor_login1's PrepareForSleep(false) branch.
cat > "$STUB_DIR/dbus-monitor" << 'STUB'
#!/bin/sh
printf 'signal 6 sender=:1.0 -> destination=:1.1 path=/org/freedesktop/login1\n'
printf '   boolean false\n'
STUB
chmod +x "$STUB_DIR/dbus-monitor"
: > "$DAEMON_ERR"
run_fn monitor_login1
if grep -q 'login1: resume handler failed' "$DAEMON_ERR"; then
    bad "N7: login1 monitor logged a false resume failure on DEFER"
else
    ok "N7: login1 monitor does not log DEFER as a failure"
fi
rm -f "$STUB_DIR/dbus-monitor"
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
wait 2> /dev/null || true
: > "$SET_LOG"
rc="$(run_fn_rc handle_unblank)"
assert_eq "N7: retry once the lock is free returns DONE" "0" "$rc"
assert_eq "N7: retry issues one gsd Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "N7: retry writes 30" "$RAW_FILE" "30"
assert_absent "N7: resume flag consumed after retry" "$HANDOFF_RESUME_FILE"

# N8. CLI and cleanup compatibility: a deferral is reported, keeps state,
# keeps the CLI's non-zero exit contract, and cleanup still exits 0.
reset_case
isolate_retry_generation
write_state 7
cli_rc=0
cli_out="$(
    XDG_RUNTIME_DIR="$D_STATE_DIR" \
        C640_KBD_SYSFS_BRIGHTNESS="$TMP_DIR/no-sysfs-brightness" \
        C640_KBD_SYSFS_MAX="$FAKE_MAX" \
        C640_KBD_FORCE_LEGACY=0 \
        STUB_FLOCK_FAIL_FD=201 STUB_FLOCK_FAIL_COUNT=1 \
        STUB_GDBUS_LOG="$GDBUS_LOG" STUB_SET_LOG="$SET_LOG" \
        STUB_ECTOOL_LOG="$TMP_DIR/ectool.log" STUB_FLOCK_DIR="$FLOCK_DIR" \
        STUB_RAW_FILE="$RAW_FILE" STUB_PCT_FILE="$PCT_FILE" \
        STUB_KBD_RAW=42 STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false \
        "$DAEMON" --test-unblank 2> "$DAEMON_ERR"
)" || cli_rc=$?
assert_eq "N8: CLI --test-unblank keeps a non-zero exit on DEFER" "1" "$cli_rc"
if grep -q 'simulated unblank: restore deferred (rc=2); state kept for retry' "$DAEMON_ERR"; then
    ok "N8: CLI prints the deferred message"
else
    bad "N8: CLI did not print a deferred message (stderr: $(cat "$DAEMON_ERR"))"
fi
assert_file "N8: CLI deferral preserves state" "$STATE_FILE" "7"
assert_file "N8: CLI deferral writes nothing" "$RAW_FILE" "42"

reset_case
isolate_retry_generation
write_state 7
export STUB_FLOCK_FAIL_FD=201 STUB_FLOCK_FAIL_COUNT=1
cleanup_rc=0
(cleanup) 2> "$DAEMON_ERR" || cleanup_rc=$?
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
wait 2> /dev/null || true
assert_eq "N8: cleanup still exits 0 on DEFER" "0" "$cleanup_rc"
if grep -q 'cleanup restore not completed (rc=2); state kept for retry' "$DAEMON_ERR"; then
    ok "N8: cleanup logs 'not completed' for a deferral"
else
    bad "N8: cleanup did not log 'not completed' (stderr: $(cat "$DAEMON_ERR"))"
fi
assert_file "N8: cleanup deferral preserves state" "$STATE_FILE" "7"

# N9 (P2). handle_unblank()'s no-flag path must treat restore_state()'s
# RC_DEFER as a retryable outcome: log "restore deferred" (INFO), never
# "restore failed".  An active ScreenSaver is a normal source of DEFER.
reset_case
isolate_retry_generation
write_state 7
export STUB_GNOME_ACTIVE=true
# Suppress scheduled retries so this case observes only the first attempt.
_orig_schedule_n9="$(declare -f schedule_restore_retries)"
schedule_restore_retries() { :; }
run_fn handle_unblank
eval "$_orig_schedule_n9"
export STUB_GNOME_ACTIVE=false
wait 2> /dev/null || true
assert_file "N9: no-flag DEFER keeps state for retry" "$STATE_FILE" "7"
assert_eq "N9: no-flag DEFER writes nothing" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'unblank: restore failed' "$DAEMON_ERR"; then
    bad "N9: no-flag DEFER logged a false 'restore failed'"
else
    ok "N9: no-flag DEFER does not log 'restore failed'"
fi
if grep -q 'unblank: restore deferred (rc=2); state kept for retry' "$DAEMON_ERR"; then
    ok "N9: no-flag DEFER logs 'restore deferred'"
else
    bad "N9: no-flag DEFER missing 'restore deferred' log (stderr: $(cat "$DAEMON_ERR"))"
fi

# N10 (P3.1). log_warn_once must work from subshells: the sampler re-enters
# handle_resume every 5s, so a stale invalid handoff must warn once, not on
# every poll.  An in-process array cannot do this (subshell changes are lost).
reset_case
isolate_retry_generation
write_handoff_suspend "not-a-number"
write_handoff_resume
rc1="$(run_fn_rc handle_resume)"
cp "$DAEMON_ERR" "$TMP_DIR/n10-first.err"
rc2="$(run_fn_rc handle_resume)"
assert_eq "N10: first invalid-handoff poll returns FAIL" "1" "$rc1"
assert_eq "N10: second invalid-handoff poll returns FAIL" "1" "$rc2"
assert_eq "N10: invalid-handoff warning emitted exactly once across subshells" "1" "$(grep -c 'suspend handoff invalid' "$TMP_DIR/n10-first.err" || true)"
assert_eq "N10: no repeat warning on the next poll" "0" "$(grep -c 'suspend handoff invalid' "$DAEMON_ERR" || true)"

# ==========================================================================
# Phase 3 (6th re-review #3).  save_state now has an explicit rc and a bounded
# lock wait; handle_blank must not switch the LED off unless a copy of the new
# brightness was persisted.  These cases exercise both the rc contract and the
# two-process contention that used to be silently skipped.
# ==========================================================================

# P6-1. Successful save: rc=0 and the value is on disk.
reset_case
printf '30\n' > "$RAW_FILE"
rc="$(run_fn_rc save_state)"
assert_eq "P6-1: save_state success rc=0" "0" "$rc"
assert_file "P6-1: saved value is 30" "$STATE_FILE" "30"

# P6-2. flock failure: rc=1 (NOT a silent success) and no state is written.
reset_case
printf '30\n' > "$RAW_FILE"
export STUB_FLOCK_FAIL_FD=200 STUB_FLOCK_FAIL_COUNT=1
rc="$(run_fn_rc save_state)"
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
assert_eq "P6-2: lock failure rc=1" "1" "$rc"
assert_absent "P6-2: no state written on lock failure" "$STATE_FILE"

# P6-3. Value selection failure: rc=2 (distinct from lock failure).
reset_case
_orig_get_brightness_p63="$(declare -f get_brightness)"
get_brightness() { printf 'garbage\n'; }
rc="$(run_fn_rc save_state)"
eval "$_orig_get_brightness_p63"
assert_eq "P6-3: selection failure rc=2" "2" "$rc"
assert_absent "P6-3: no state written on selection failure" "$STATE_FILE"

# P6-4. Bounded wait really waits: a background holder owns STATE_LOCK for
# 0.3s; save_state must use flock -w on fd 200 and succeed after it leaves.
reset_case
printf '30\n' > "$RAW_FILE"
export STUB_FLOCK_LOG="$FLOCK_LOG"
: > "$FLOCK_LOG"
P64_HOLDER_MARKER="$TMP_DIR/p64-holder"
rm -f "$P64_HOLDER_MARKER"
(
    exec 200> "$STATE_LOCK" || exit 1
    flock -n 200 || exit 1
    : > "$P64_HOLDER_MARKER"
    /bin/sleep 0.3
) &
holder=$!
for ((i = 0; i < 100; i++)); do
    [ -f "$P64_HOLDER_MARKER" ] && break
    /bin/sleep 0.01
done
assert_present "P6-4: background holder owns the lock" "$P64_HOLDER_MARKER"
rc="$(run_fn_rc save_state)"
wait "$holder" 2> /dev/null || true
assert_eq "P6-4: save_state waited and succeeded" "0" "$rc"
assert_file "P6-4: value saved after wait" "$STATE_FILE" "30"
if grep -q 'flock fd=200 .* op=w' "$FLOCK_LOG"; then
    ok "P6-4: save_state used flock -w on fd 200"
else
    bad "P6-4: no bounded-wait flock record: $(cat "$FLOCK_LOG")"
fi
export STUB_FLOCK_LOG=/dev/null

# P6-5. Bounded wait timeout: lock stays busy past the limit -> rc=1, no write.
reset_case
printf '30\n' > "$RAW_FILE"
export C640_KBD_SAVE_LOCK_WAIT=1
P65_HOLDER_MARKER="$TMP_DIR/p65-holder"
rm -f "$P65_HOLDER_MARKER"
(
    exec 200> "$STATE_LOCK" || exit 1
    flock -n 200 || exit 1
    : > "$P65_HOLDER_MARKER"
    /bin/sleep 3
) &
holder=$!
for ((i = 0; i < 100; i++)); do
    [ -f "$P65_HOLDER_MARKER" ] && break
    /bin/sleep 0.01
done
assert_present "P6-5: background holder owns the lock" "$P65_HOLDER_MARKER"
rc="$(run_fn_rc save_state)"
export C640_KBD_SAVE_LOCK_WAIT=2
wait "$holder" 2> /dev/null || true
assert_eq "P6-5: lock timeout rc=1" "1" "$rc"
assert_absent "P6-5: no state written on timeout" "$STATE_FILE"

# P6-6. The core regression: when EVERY save attempt fails, handle_blank must
# leave the LED on (RAW unchanged), write no state, emit no gsd Set 0, and WARN.
reset_case
printf '30\n' > "$RAW_FILE"
: > "$SET_LOG"
export STUB_FLOCK_FAIL_FD=200 STUB_FLOCK_FAIL_COUNT=9
rc="$(run_fn_rc handle_blank)"
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
assert_eq "P6-6: handle_blank propagates save failure" "1" "$rc"
assert_file "P6-6: LED left ON (raw still 30)" "$RAW_FILE" "30"
assert_absent "P6-6: no state file" "$STATE_FILE"
assert_eq "P6-6: no gsd Set 0" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'brightness NOT saved' "$DAEMON_ERR"; then
    ok "P6-6: WARN explains why the LED stayed on"
else
    bad "P6-6: missing NOT-saved WARN (stderr: $(cat "$DAEMON_ERR"))"
fi
assert_file "P6-6: captured value kept in last-user cache" "$LAST_USER_FILE" "30"

# P6-7. Positive timing proof: the first save fails, the retry with the
# pre-blank snapshot succeeds, and only then is set_brightness 0 called.
reset_case
printf '30\n' > "$RAW_FILE"
: > "$ORDER_FILE"
export STUB_FLOCK_FAIL_FD=200 STUB_FLOCK_FAIL_COUNT=1
_orig_set_p67="$(declare -f set_brightness)"
declare -f set_brightness | sed '1s/^set_brightness ()/real_set_brightness_p67 ()/' > "$TMP_DIR/real_set_brightness_p67.def"
# shellcheck disable=SC1090
source "$TMP_DIR/real_set_brightness_p67.def"
set_brightness() {
    if [ "${1:-}" = "0" ]; then
        cat "$STATE_FILE" > "$ORDER_FILE" 2> /dev/null || true
    fi
    real_set_brightness_p67 "$@"
}
run_fn handle_blank
eval "$_orig_set_p67"
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
assert_file "P6-7: state held 30 when LED went off" "$ORDER_FILE" "30"
assert_file "P6-7: saved value is 30" "$STATE_FILE" "30"
assert_file "P6-7: LED finally off" "$RAW_FILE" "0"

# P6-8. Two processes: a restore holds STATE_LOCK while probing ScreenSaver;
# a blank arrives and must wait for the lock, save its new value, and only
# then switch the LED off.  PENDING must be consumed by the restore's finalize.
reset_case
write_state 7
printf '30\n' > "$RAW_FILE"
: > "$ORDER_FILE"
: > "$SET_LOG"
isolate_retry_generation
P68_PROBE_MARKER="$TMP_DIR/p68-in-probe"
P68_RESTORE_WRITTEN_MARKER="$TMP_DIR/p68-restore-written"
rm -f "$P68_PROBE_MARKER" "$P68_RESTORE_WRITTEN_MARKER"
_orig_sched_p68="$(declare -f schedule_restore_retries)"
schedule_restore_retries() { :; }
_orig_tristate_p68="$(declare -f screensaver_tristate)"
screensaver_tristate() {
    : > "$P68_PROBE_MARKER"
    /bin/sleep 0.3
    printf 'inactive\n'
}
_orig_set_p68="$(declare -f set_brightness)"
declare -f set_brightness | sed '1s/^set_brightness ()/real_set_brightness_p68 ()/' > "$TMP_DIR/real_set_brightness_p68.def"
# shellcheck disable=SC1090
source "$TMP_DIR/real_set_brightness_p68.def"
set_brightness() {
    if [ "${1:-}" = "0" ]; then
        # Deterministic gate: the blank's off must be the last writer, as in a
        # real re-blank race.  Wait for the in-flight restore's write of 7 to
        # actually land instead of a fixed sleep that a loaded CI can outrun.
        local waited=0
        while [ ! -e "$P68_RESTORE_WRITTEN_MARKER" ]; do
            if [ "$waited" -ge 100 ]; then
                bad "P6-8: restore write of 7 never landed within 1s; blank off would race"
                break
            fi
            /bin/sleep 0.01
            waited=$((waited + 1))
        done
        cat "$STATE_FILE" > "$ORDER_FILE" 2> /dev/null || true
    fi
    real_set_brightness_p68 "$@"
    if [ "${1:-}" = "7" ]; then
        # The restore's write completed; release the blank's gate only after
        # the real writer has returned (not merely after it was called).
        : > "$P68_RESTORE_WRITTEN_MARKER"
    fi
}
(
    restore_state
) 2> "$TMP_DIR/p68-restore.err" &
restore_pid=$!
for ((i = 0; i < 100; i++)); do
    [ -f "$P68_PROBE_MARKER" ] && break
    /bin/sleep 0.01
done
assert_present "P6-8: restore entered its slow ScreenSaver probe" "$P68_PROBE_MARKER"
rc="$(run_fn_rc handle_blank)"
wait "$restore_pid" 2> /dev/null || true
eval "$_orig_set_p68"
eval "$_orig_tristate_p68"
eval "$_orig_sched_p68"
assert_eq "P6-8: blank's save succeeded" "0" "$rc"
assert_file "P6-8: new value 30 persisted" "$STATE_FILE" "30"
assert_absent "P6-8: PENDING consumed by restore finalize" "$RESTORE_PENDING_FILE"
assert_file "P6-8: LED finally off (raw 0)" "$RAW_FILE" "0"
assert_file "P6-8: save happened before off" "$ORDER_FILE" "30"
if grep -q 'keeping newer blank-time state 30' "$TMP_DIR/p68-restore.err"; then
    ok "P6-8: restore kept the newer blank-time state"
else
    bad "P6-8: restore did not report keeping newer state ($(cat "$TMP_DIR/p68-restore.err"))"
fi

# P6-9. Pure contention variant: the lock is held on fd 201 (restore's fd),
# and save_state's fd 200 must still wait for it and persist the value.
reset_case
printf '22\n' > "$RAW_FILE"
export STUB_FLOCK_LOG="$FLOCK_LOG"
: > "$FLOCK_LOG"
P69_HOLDER_MARKER="$TMP_DIR/p69-holder"
rm -f "$P69_HOLDER_MARKER"
(
    exec 201> "$STATE_LOCK" || exit 1
    flock -n 201 || exit 1
    : > "$P69_HOLDER_MARKER"
    /bin/sleep 0.25
) &
holder=$!
for ((i = 0; i < 100; i++)); do
    [ -f "$P69_HOLDER_MARKER" ] && break
    /bin/sleep 0.01
done
assert_present "P6-9: background holder owns the lock" "$P69_HOLDER_MARKER"
rc="$(run_fn_rc save_state)"
wait "$holder" 2> /dev/null || true
assert_eq "P6-9: save under fd201 contention rc=0" "0" "$rc"
assert_file "P6-9: value saved after waiting" "$STATE_FILE" "22"
if grep -q 'flock fd=200 .* op=w' "$FLOCK_LOG"; then
    ok "P6-9: contending save used bounded wait on fd 200"
else
    bad "P6-9: no fd200 bounded-wait record: $(cat "$FLOCK_LOG")"
fi
export STUB_FLOCK_LOG=/dev/null

# P6-10. All retries failed, but the last-user cache (with metadata) keeps the
# captured value usable: a later blank with the lock free saves it correctly.
reset_case
write_last_user 0 manual0
printf '30\n' > "$RAW_FILE"
printf '0\n' > "$PCT_FILE"
export STUB_FLOCK_FAIL_FD=200 STUB_FLOCK_FAIL_COUNT=9
rc="$(run_fn_rc handle_blank)"
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
assert_eq "P6-10: first blank cannot save" "1" "$rc"
assert_file "P6-10: LED left on after failed save" "$RAW_FILE" "30"
assert_absent "P6-10: no state after failed save" "$STATE_FILE"
assert_file "P6-10: captured 0 kept in cache" "$LAST_USER_FILE" "0"
if grep -q 'source=manual0' "$LAST_USER_META_FILE"; then
    ok "P6-10: cache metadata records manual0"
else
    bad "P6-10: cache metadata lost source: $(cat "$LAST_USER_META_FILE")"
fi
rc="$(run_fn_rc handle_blank)"
assert_eq "P6-10: later blank saves from cache" "0" "$rc"
assert_file "P6-10: rescued value 0 persisted" "$STATE_FILE" "0"
assert_file "P6-10: LED finally off" "$RAW_FILE" "0"

# P6-11. The CLI --test-blank entry point must propagate a save failure.
reset_case
printf '30\n' > "$RAW_FILE"
cli_rc=0
cli_out="$(
    XDG_RUNTIME_DIR="$D_STATE_DIR" \
        C640_KBD_SYSFS_BRIGHTNESS="$FAKE_SYSFS" \
        C640_KBD_SYSFS_MAX="$FAKE_MAX" \
        STUB_FLOCK_DIR="$FLOCK_DIR" STUB_FLOCK_FAIL_FD=200 STUB_FLOCK_FAIL_COUNT=1 \
        STUB_FLOCK_LOG=/dev/null \
        STUB_GDBUS_LOG="$GDBUS_LOG" STUB_SET_LOG="$SET_LOG" \
        STUB_ECTOOL_LOG="$TMP_DIR/ectool.log" \
        STUB_RAW_FILE="$RAW_FILE" STUB_PCT_FILE="$PCT_FILE" \
        STUB_KBD_RAW=42 STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false \
        "$DAEMON" --test-blank 2> "$DAEMON_ERR"
)" || cli_rc=$?
assert_eq "P6-11: CLI --test-blank propagates save failure" "1" "$cli_rc"
assert_file "P6-11: LED unchanged on CLI failure" "$RAW_FILE" "30"
assert_absent "P6-11: no state on CLI failure" "$STATE_FILE"
if grep -q 'simulated blank: save failed' "$DAEMON_ERR"; then
    ok "P6-11: CLI reports the save failure"
else
    bad "P6-11: CLI error message missing: $(cat "$DAEMON_ERR")"
fi

# P6-12. Regression: the existing mid-restore blank (test #12) and the
# PENDING guard still behave identically with the rc-bearing save_state.
reset_case
write_state 7
isolate_retry_generation
_orig_set_p612="$(declare -f set_brightness)"
declare -f set_brightness | sed '1s/^set_brightness ()/real_set_brightness_p612 ()/' > "$TMP_DIR/real_set_brightness_p612.def"
# shellcheck disable=SC1090
source "$TMP_DIR/real_set_brightness_p612.def"
set_brightness() {
    printf '5\n' > "$LAST_USER_FILE"
    save_state
    real_set_brightness_p612 "$@"
}
run_fn restore_state
eval "$_orig_set_p612"
assert_file "P6-12: mid-restore blank still saved 5" "$STATE_FILE" "5"
assert_file "P6-12: restore still wrote 7" "$RAW_FILE" "7"

reset_case
write_state 7
printf '9\n' > "$RESTORE_PENDING_FILE"
rc="$(run_fn_rc restore_state)"
assert_eq "P6-12: PENDING guard still defers restore" "2" "$rc"
assert_file "P6-12: staged PENDING value preserved" "$RESTORE_PENDING_FILE" "9"
assert_file "P6-12: guarded restore writes nothing" "$RAW_FILE" "42"

# P7-1. Finding #1 regression: handle_blank must save the PRE-BLANK snapshot on
# its FIRST attempt.  GNOME/firmware may drop the LED to 0 between the first
# sample and a second, un-parameterised save_state(): that second sample would
# see a blank-side 0 and fall back to the stale cache (8), losing the freshly
# set 30.  A file-backed counter is mandatory because compute_save_brightness
# calls get_brightness inside command substitutions (a shell variable would be
# lost in each subshell).
reset_case
printf '30\n' > "$RAW_FILE"
printf '30\n' > "$PCT_FILE"
write_last_user 8 nonzero
: > "$SET_LOG"
: > "$ORDER_FILE"
P7_GET_LOG="$TMP_DIR/p7-get-log"
: > "$P7_GET_LOG"
_orig_get_p71="$(declare -f get_brightness)"
get_brightness() {
    local n
    n="$(grep -c . "$P7_GET_LOG" 2> /dev/null || true)"
    n="${n:-0}"
    n=$((n + 1))
    printf '%s\n' "$n" >> "$P7_GET_LOG"
    if [ "$n" -eq 1 ]; then
        printf '30\n'
    else
        printf '0\n'
    fi
}
_orig_set_p71="$(declare -f set_brightness)"
declare -f set_brightness | sed '1s/^set_brightness ()/real_set_brightness_p71 ()/' > "$TMP_DIR/real_set_brightness_p71.def"
# shellcheck disable=SC1090
source "$TMP_DIR/real_set_brightness_p71.def"
set_brightness() {
    if [ "${1:-}" = "0" ]; then
        cat "$STATE_FILE" > "$ORDER_FILE" 2> /dev/null || true
    fi
    real_set_brightness_p71 "$@"
}
rc="$(run_fn_rc handle_blank)"
eval "$_orig_set_p71"
eval "$_orig_get_p71"
wait 2> /dev/null || true
assert_eq "P7-1: handle_blank rc=0" "0" "$rc"
assert_file "P7-1: pre-blank 30 saved, not stale cache 8" "$STATE_FILE" "30"
assert_file "P7-1: state held 30 when LED went off" "$ORDER_FILE" "30"
assert_file "P7-1: LED finally off" "$RAW_FILE" "0"
assert_eq "P7-1: exactly one gsd Properties.Set" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'int32 0' "$SET_LOG"; then
    ok "P7-1: the single gsd write is int32 0"
else
    bad "P7-1: gsd write is not int32 0: $(cat "$SET_LOG")"
fi
assert_eq "P7-1: no UPower direct write (single writer)" "0" "$(grep -c 'UPower.SetBrightness' "$SET_LOG" || true)"
assert_eq "P7-1: brightness sampled exactly once" "1" "$(grep -c . "$P7_GET_LOG" || true)"

# P6-13. Finding #2: an EMPTY STATE_FILE is not a valid copy.  save_state must
# self-heal it before handle_blank switches the LED off.
reset_case
printf '30\n' > "$RAW_FILE"
: > "$STATE_FILE"
: > "$SET_LOG"
rc="$(run_fn_rc handle_blank)"
wait 2> /dev/null || true
assert_eq "P6-13: empty state self-healed, rc=0" "0" "$rc"
assert_file "P6-13: saved brightness 30" "$STATE_FILE" "30"
assert_file "P6-13: LED off" "$RAW_FILE" "0"

# P6-14. Non-numeric state is likewise invalid and gets atomically replaced.
reset_case
printf '30\n' > "$RAW_FILE"
write_state not-an-integer
: > "$SET_LOG"
rc="$(run_fn_rc handle_blank)"
wait 2> /dev/null || true
assert_eq "P6-14: non-numeric state self-healed, rc=0" "0" "$rc"
assert_file "P6-14: saved brightness 30" "$STATE_FILE" "30"
assert_file "P6-14: LED off" "$RAW_FILE" "0"
if grep -q 'replacing invalid saved brightness' "$DAEMON_ERR"; then
    ok "P6-14: WARN explains the replacement"
else
    bad "P6-14: missing replacement WARN: $(cat "$DAEMON_ERR")"
fi

# P6-15. Multi-line JSON is not a brightness value.
reset_case
printf '30\n' > "$RAW_FILE"
printf '{"brightness":30}\n{"brightness":8}\n' > "$STATE_FILE"
rc="$(run_fn_rc handle_blank)"
wait 2> /dev/null || true
assert_eq "P6-15: multi-line state self-healed, rc=0" "0" "$rc"
assert_file "P6-15: saved brightness 30" "$STATE_FILE" "30"

# P6-15b. Binary bytes after a valid prefix must not be accepted either.
reset_case
printf '30\n' > "$RAW_FILE"
printf '30\377\376\n' > "$STATE_FILE"
rc="$(run_fn_rc handle_blank)"
wait 2> /dev/null || true
assert_eq "P6-15b: binary state self-healed, rc=0" "0" "$rc"
assert_file "P6-15b: saved brightness 30" "$STATE_FILE" "30"

# P6-16. First-wins still protects a VALID existing copy (8), both for a direct
# save and for the blank path.
reset_case
printf '30\n' > "$RAW_FILE"
write_state 8
rc="$(run_fn_rc save_state)"
assert_eq "P6-16: first-wins save rc=0" "0" "$rc"
assert_file "P6-16: valid state 8 not overwritten" "$STATE_FILE" "8"
rc="$(run_fn_rc handle_blank)"
wait 2> /dev/null || true
assert_eq "P6-16: handle_blank rc=0 with valid state" "0" "$rc"
assert_file "P6-16: state still 8 after blank" "$STATE_FILE" "8"
assert_file "P6-16: LED off" "$RAW_FILE" "0"

# P6-17. A genuine write failure (mktemp fails) must NOT be mistaken for a
# valid copy: save_state returns 2 through all retries, so handle_blank keeps
# the LED on and leaves the corrupt state untouched.
reset_case
printf '30\n' > "$RAW_FILE"
write_state not-an-integer
printf '#!/bin/sh\nexit 1\n' > "$STUB_DIR/mktemp"
chmod +x "$STUB_DIR/mktemp"
rc="$(run_fn_rc handle_blank)"
rm -f "$STUB_DIR/mktemp"
wait 2> /dev/null || true
assert_eq "P6-17: write failure propagates rc=2" "2" "$rc"
assert_file "P6-17: invalid state left untouched" "$STATE_FILE" "not-an-integer"
assert_file "P6-17: LED left ON (raw still 30)" "$RAW_FILE" "30"

# P6-18. captured=0 is a real value, not an empty sampling failure: self-heal
# must publish exactly "0" (the manual0 cache plus gsd pct 0 makes live 30 a
# transient blank-side residue).
reset_case
printf '30\n' > "$RAW_FILE"
printf '0\n' > "$PCT_FILE"
write_state garbage
write_last_user 0 manual0
rc="$(run_fn_rc handle_blank)"
wait 2> /dev/null || true
assert_eq "P6-18: captured 0 saved, rc=0" "0" "$rc"
assert_file "P6-18: state exactly 0" "$STATE_FILE" "0"
assert_file "P6-18: LED off" "$RAW_FILE" "0"

# P6-19. Backstop: restore_state still discards an externally corrupted value
# (the self-healing writer never produces one, but recovery must stay safe).
reset_case
write_state garbage
rc="$(run_fn_rc restore_state)"
assert_eq "P6-19: restore of invalid state is a safe no-op" "0" "$rc"
assert_absent "P6-19: invalid state removed" "$STATE_FILE"

# P2-c. The unblank guard is a THIRD writer outside RESUME_LOCK/STATE_LOCK.
# It must not re-apply the restored value after a POST-restore user change.
# Set up a real successful restore first so the last-user record can carry the
# matching restore generation (that stamp is what makes it post-restore).
reset_case
write_state 30
printf '30\n' > "$RAW_FILE"
run_fn restore_state
write_last_user 50 nonzero
printf '50\n' > "$RAW_FILE"
printf '50\n' > "$PCT_FILE"
: > "$SET_LOG" # discard the setup restore's write
run_fn guard_unblank 30
wait 2> /dev/null || true
assert_file "P2-c: guard keeps the user's post-restore brightness 50" "$RAW_FILE" "50"
assert_eq "P2-c: guard issued no gsd write" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'post-restore cache agree' "$DAEMON_ERR"; then
    ok "P2-c: guard logs that it deferred to user intent"
else
    bad "P2-c: no user-choice log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P2-c (b). A stamped last-user record is sufficient even when the LED currently
# disagrees with gsd (backend glitch); no write may follow.
reset_case
write_state 30
printf '30\n' > "$RAW_FILE"
run_fn restore_state
write_last_user 50 nonzero
printf '42\n' > "$RAW_FILE"
printf '50\n' > "$PCT_FILE"
: > "$SET_LOG"
run_fn guard_unblank 30
wait 2> /dev/null || true
assert_file "P2-c: post-restore cache alone blocks a re-set" "$RAW_FILE" "42"
assert_eq "P2-c: no write from the stamped-cache case" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'recorded after restore' "$DAEMON_ERR"; then
    ok "P2-c: stamped cache is logged as user intent"
else
    bad "P2-c: no stamped-cache log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P2-c (c) -- EXPECTATION REVERSED BY FINDING #4.  gsd/LED moved to 50 while
# the last-user cache (stamped with THIS restore's generation) still holds 30.
# Inside the 5s sampler window that is genuinely AMBIGUOUS: it may be a user
# change whose cache record has not landed yet.  Re-applying 30 would override
# user intent, so the guard must leave the LED alone and only log.
reset_case
write_state 30
printf '30\n' > "$RAW_FILE"
run_fn restore_state
write_last_user 30 nonzero
printf '50\n' > "$RAW_FILE"
printf '50\n' > "$PCT_FILE"
: > "$SET_LOG"
run_fn guard_unblank 30
wait 2> /dev/null || true
assert_file "P2-c: ambiguous change keeps the user's brightness 50" "$RAW_FILE" "50"
assert_eq "P2-c: ambiguous change issues no gsd write" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'ambiguous' "$DAEMON_ERR" && grep -q 'no write' "$DAEMON_ERR"; then
    ok "P2-c: ambiguous change is logged as no-write"
else
    bad "P2-c: no ambiguous/no-write log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P2-c (c2). Same 5s ambiguity with NO last-user record at all: with no gsd
# positive evidence (gsd moved to 50), the guard must fail closed as well.
reset_case
write_state 30
printf '30\n' > "$RAW_FILE"
run_fn restore_state
printf '50\n' > "$RAW_FILE"
printf '50\n' > "$PCT_FILE"
: > "$SET_LOG"
run_fn guard_unblank 30
wait 2> /dev/null || true
assert_file "P2-c: no-cache ambiguous change keeps brightness 50" "$RAW_FILE" "50"
assert_eq "P2-c: no-cache ambiguous change issues no write" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"

# P2-1 (reviewer A). A 6->8 change made <5s before blank leaves the sampler
# cache at 6 while STATE_FILE holds 8.  That stale cache must NOT be mistaken
# for a new post-restore user choice: a lost restore is still repaired.
reset_case
write_last_user 6 nonzero
write_state 8
printf '8\n' > "$RAW_FILE"
run_fn restore_state
printf '6\n' > "$RAW_FILE"
printf '8\n' > "$PCT_FILE"
run_fn guard_unblank 8
wait 2> /dev/null || true
assert_file "P2-1: stale 6 cache cannot block repair of lost restore 8" "$RAW_FILE" "8"
if grep -q 're-setting' "$DAEMON_ERR"; then
    ok "P2-1: stale-cache case re-sets the restored value"
else
    bad "P2-1: no re-set log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P2-c (d). A genuine lost restore (cache still 30, gsd still wants 30, but
# the LED is 10) is still repaired by the guard.
reset_case
write_last_user 30 nonzero
printf '30\n' > "$PCT_FILE"
printf '10\n' > "$RAW_FILE"
run_fn guard_unblank 30
wait 2> /dev/null || true
assert_file "P2-c: guard still repairs a genuinely lost restore" "$RAW_FILE" "30"
if grep -q 'Properties.Set' "$SET_LOG"; then
    ok "P2-c: genuine mismatch still triggers a guard write"
else
    bad "P2-c: guard no longer repairs a lost restore (SET_LOG: $(cat "$SET_LOG"))"
fi

# --- Finding #4: generation is a real writer gate ---------------------------

# F4-1. G1 unblank guard is pending in the controllable sleep gate; a second
# blank/unblank cycle completes a G2 restore of 70.  When G1 wakes it must do
# ZERO writes and leave the newer restore intact.
reset_case
write_state 30
printf '30\n' > "$RAW_FILE"
run_fn restore_state
g1="$(cat "$RESTORE_GEN_FILE" 2> /dev/null || echo '')"
assert_eq "F4-1: first restore established G1" "1" "$g1"
start_gated_guard guard_unblank 30
assert_eq "F4-1: both unblank guard delays gated" "0.3,0.9," "$GUARD_STARTED"
write_state 70
printf '70\n' > "$RAW_FILE"
run_fn restore_state
g2="$(cat "$RESTORE_GEN_FILE" 2> /dev/null || echo '')"
assert_eq "F4-1: second restore advanced G1 to G2" "2" "$g2"
: > "$SET_LOG"
release_guards
assert_file "F4-1: G2 value survives stale G1 guard" "$RAW_FILE" "70"
assert_eq "F4-1: stale G1 guard issued zero writes" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'generation superseded' "$GUARD_ERR"; then
    ok "F4-1: superseded generation is logged"
else
    bad "F4-1: no generation-superseded log (stderr: $(cat "$GUARD_ERR"))"
fi

# F4-2. Same interleaving, but the 5s sampler has already recorded the G2
# value with a G2 stamp.  The G1 guard must not overwrite either the G2 cache
# or the G2 restore, even though lu != saved would normally look like intent.
reset_case
write_state 30
printf '30\n' > "$RAW_FILE"
run_fn restore_state
g1="$(cat "$RESTORE_GEN_FILE" 2> /dev/null || echo '')"
assert_eq "F4-2: first restore established G1" "1" "$g1"
start_gated_guard guard_unblank 30
assert_eq "F4-2: both unblank guard delays gated" "0.3,0.9," "$GUARD_STARTED"
write_state 70
printf '70\n' > "$RAW_FILE"
run_fn restore_state
write_last_user 70 nonzero
g2="$(cat "$RESTORE_GEN_FILE" 2> /dev/null || echo '')"
assert_eq "F4-2: sampler cache stamped with G2" "2" "$(last_user_restore_gen)"
: > "$SET_LOG"
release_guards
assert_file "F4-2: G2 cache value survives stale G1 guard" "$RAW_FILE" "70"
assert_eq "F4-2: stale G1 guard issued zero writes" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_eq "F4-2: G1 guard did not touch the G2 cache" "70" "$(read_last_user_brightness)"
if grep -q 'generation superseded' "$GUARD_ERR"; then
    ok "F4-2: superseded generation is logged"
else
    bad "F4-2: no generation-superseded log (stderr: $(cat "$GUARD_ERR"))"
fi

# F4-3. Final in-lock check: arm the gdbus stub so the FIRST brightness read
# after the guard wakes bumps the generation (before it reaches WRITE_LOCK).
# The guard's last check inside the lock must still cancel the write.
reset_case
write_state 30
printf '30\n' > "$RAW_FILE"
run_fn restore_state
printf '10\n' > "$RAW_FILE"
printf '30\n' > "$PCT_FILE"
: > "$SET_LOG"
: > "$STUB_BUMP_FLAG"
start_gated_guard guard_unblank 30
assert_eq "F4-3: both unblank guard delays gated" "0.3,0.9," "$GUARD_STARTED"
release_guards
assert_file "F4-3: in-lock generation bump blocks the write" "$RAW_FILE" "10"
assert_eq "F4-3: no write after in-lock bump" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_eq "F4-3: generation actually advanced" "2" "$(cat "$RESTORE_GEN_FILE" 2> /dev/null || echo '')"
if grep -q 'superseded inside WRITE_LOCK' "$GUARD_ERR"; then
    ok "F4-3: in-lock cancellation is logged"
else
    bad "F4-3: no in-lock cancellation log (stderr: $(cat "$GUARD_ERR"))"
fi

# F4-4. G1 BLANK guard pending; a G2 restore completes while the screen is
# still reported active (explicit RESUME_ALLOW_UNKNOWN opt-in).  The stale
# blank guard must not force 0 over the newly restored 70.
reset_case
write_state 30
printf '30\n' > "$RAW_FILE"
run_fn restore_state
g1="$(cat "$RESTORE_GEN_FILE" 2> /dev/null || echo '')"
assert_eq "F4-4: first restore established G1" "1" "$g1"
export STUB_GNOME_ACTIVE=true STUB_FDO_ACTIVE=true
export C640_KBD_RESUME_ALLOW_UNKNOWN=1
start_gated_guard guard_blank
assert_eq "F4-4: both blank guard delays gated" "0.25,1.0," "$GUARD_STARTED"
write_state 70
printf '70\n' > "$RAW_FILE"
run_fn restore_state 1
: > "$SET_LOG"
release_guards
export STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false
export C640_KBD_RESUME_ALLOW_UNKNOWN=0
assert_file "F4-4: G2 restore survives stale G1 blank guard" "$RAW_FILE" "70"
assert_eq "F4-4: stale blank guard issued zero writes" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
# Exact post-sleep string: a generic 'generation superseded' would also match
# the in-WRITE_LOCK log and could not detect removal of the post-sleep recheck.
if grep -Fq 'blank guard +0.25s: generation superseded (1 -> 2); guard cancelled' "$GUARD_ERR"; then
    ok "F4-4: stale blank guard cancellation is logged after sleep"
else
    bad "F4-4: no post-sleep blank-guard cancellation log (stderr: $(cat "$GUARD_ERR"))"
fi

# F4-5. bump_restore_gen() atomically publishes the generation and clears the
# guard's "already wrote" marker so the NEW generation's guards can write.
reset_case
printf '1\n' > "$GUARD_WRITTEN_GEN_FILE"
printf 'sentinel\n' > "$SELF_WRITE_SENTINEL_FILE"
bump_restore_gen
assert_file "F4-5: generation published atomically" "$RESTORE_GEN_FILE" "1"
assert_absent "F4-5: bump clears the guard-written marker" "$GUARD_WRITTEN_GEN_FILE"
assert_absent "F4-5: bump clears the Tier-2 sentinel" "$SELF_WRITE_SENTINEL_FILE"
if _acquire_write_lock; then
    _release_write_lock
    ok "F4-5: WRITE_LOCK re-acquirable after bump (no stale lock)"
else
    bad "F4-5: WRITE_LOCK left stale after bump"
fi

# F4-6. A guard marker for the CURRENT generation suppresses a duplicate write
# even when the LED still disagrees (the second 0.9s guard / a second event).
reset_case
write_state 30
printf '30\n' > "$RAW_FILE"
run_fn restore_state
printf '1\n' > "$GUARD_WRITTEN_GEN_FILE"
printf '10\n' > "$RAW_FILE"
printf '30\n' > "$PCT_FILE"
: > "$SET_LOG"
run_fn guard_unblank 30
wait 2> /dev/null || true
assert_file "F4-6: marker suppresses the duplicate re-set" "$RAW_FILE" "10"
assert_eq "F4-6: marker case issued zero writes" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'already re-set' "$DAEMON_ERR"; then
    ok "F4-6: duplicate suppression is logged"
else
    bad "F4-6: no duplicate-suppression log (stderr: $(cat "$DAEMON_ERR"))"
fi

# --- Phase D re-review fixes: generation gate, lock failures, torn cache ----

# F4-X (P1). A G1 retry wakes, stages PENDING, then waits for WRITE_LOCK while
# another cycle advances the generation to G2 (DONE with no write).  Acquiring
# the lock must re-check the gate and roll PENDING back instead of writing the
# stale G1 value over the user's current LED (10).
reset_case
printf '1\n' > "$RESTORE_GEN_FILE"
write_state 30
printf '10\n' > "$RAW_FILE"
: > "$STUB_RETRY_STARTED"
: > "$STUB_RETRY_GATE"
: > "$SET_LOG"
export STUB_SLEEP_MODE=gate
hold_write_lock
run_fn schedule_restore_retries 1 0.5
if wait_for_line "$STUB_RETRY_STARTED" "0.5"; then
    ok "F4-X: retry +0.5s reached the controllable sleep gate"
else
    bad "F4-X: retry never reached the sleep gate"
fi
: > "$STUB_RETRY_RELEASE"
if wait_for_file "$RESTORE_PENDING_FILE"; then
    ok "F4-X: retry staged PENDING before waiting for WRITE_LOCK"
else
    bad "F4-X: retry did not stage PENDING"
fi
# The other resume publishes G2 while the retry is blocked on fd 209.
printf '2\n' > "$RESTORE_GEN_FILE"
: > "$SET_LOG"
release_write_lock_holder
assert_file "F4-X: expired retry left the LED at 10" "$RAW_FILE" "10"
assert_eq "F4-X: expired retry issued zero writes" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
assert_file "F4-X: staged value rolled back to STATE_FILE" "$STATE_FILE" "30"
assert_absent "F4-X: no PENDING orphan after rollback" "$RESTORE_PENDING_FILE"
if grep -Fq 'restore retry +0.5s (gen=1): generation superseded inside WRITE_LOCK (2); rolling staged value back' "$DAEMON_ERR"; then
    ok "F4-X: in-lock generation recheck is logged"
else
    bad "F4-X: no in-lock generation recheck log (stderr: $(cat "$DAEMON_ERR"))"
fi

# F4-7 (P3-1). Functional counterpart of F4-4 for the unblank guard: when the
# stale G1 guard wakes, gsd still asks for the G1 value (positive evidence).
# The post-sleep generation gate must cancel it before that evidence is used.
reset_case
write_state 30
printf '30\n' > "$RAW_FILE"
run_fn restore_state
assert_eq "F4-7: first restore established G1" "1" "$(cat "$RESTORE_GEN_FILE" 2> /dev/null || echo '')"
start_gated_guard guard_unblank 30
assert_eq "F4-7: both unblank guard delays gated" "0.3,0.9," "$GUARD_STARTED"
write_state 70
printf '70\n' > "$RAW_FILE"
run_fn restore_state
assert_eq "F4-7: second restore established G2" "2" "$(cat "$RESTORE_GEN_FILE" 2> /dev/null || echo '')"
printf '30\n' > "$PCT_FILE"
: > "$SET_LOG"
release_guards
assert_file "F4-7: G2 value survives with gsd still wanting G1" "$RAW_FILE" "70"
assert_eq "F4-7: stale G1 guard issued zero writes" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -Fq 'unblank guard +0.3s: generation superseded (1 -> 2); guard cancelled' "$GUARD_ERR"; then
    ok "F4-7: stale unblank guard cancellation is logged after sleep"
else
    bad "F4-7: no post-sleep unblank cancellation log (stderr: $(cat "$GUARD_ERR"))"
fi

# F4-8 (P2-1). A bump waiting on WRITE_LOCK must read the generation AFTER it
# acquires the lock.  G1 is published while the waiting bump is parked; the
# bump must then publish G3, not re-stamp G2 from a pre-lock read.
reset_case
printf '1\n' > "$RESTORE_GEN_FILE"
printf '9\n' > "$GUARD_WRITTEN_GEN_FILE"
: > "$TMP_DIR/bump-start"
hold_write_lock
(
    : > "$TMP_DIR/bump-start"
    bump_restore_gen
) 2> "$TMP_DIR/bump.err" &
if wait_for_file "$TMP_DIR/bump-start"; then
    ok "F4-8: bump is waiting for WRITE_LOCK"
else
    bad "F4-8: bump did not start"
fi
/bin/sleep 0.2
# Another cycle publishes G2 while the bump is blocked (the test-side holder
# stands in for that writer, which publishes under the same lock).
printf '2\n' > "$RESTORE_GEN_FILE"
release_write_lock_holder
assert_file "F4-8: generation read inside the lock is 3" "$RESTORE_GEN_FILE" "3"
assert_absent "F4-8: guard marker cleared by the bump" "$GUARD_WRITTEN_GEN_FILE"

# P2-1 (fail-closed). A WRITE_LOCK failure must not publish the generation or
# clear the guard markers outside the lock.
reset_case
printf '5\n' > "$RESTORE_GEN_FILE"
printf '9\n' > "$GUARD_WRITTEN_GEN_FILE"
export STUB_FLOCK_FAIL_FD=209 STUB_FLOCK_FAIL_COUNT=1
bump_rc="$(run_fn_rc bump_restore_gen)"
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
assert_eq "P2-1: bump refuses to publish without WRITE_LOCK" "1" "$bump_rc"
assert_file "P2-1: generation unchanged after lock failure" "$RESTORE_GEN_FILE" "5"
assert_file "P2-1: guard marker kept after lock failure" "$GUARD_WRITTEN_GEN_FILE" "9"
if grep -q 'not publishing' "$DAEMON_ERR"; then
    ok "P2-1: degraded publishing is not used"
else
    bad "P2-1: no fail-closed bump log (stderr: $(cat "$DAEMON_ERR"))"
fi

# P2-1 (callers). restore_state and handle_unblank must turn a bump failure
# into DEFER with no write and no spawned guard, keeping state for later.
reset_case
write_state 30
printf '10\n' > "$RAW_FILE"
: > "$SET_LOG"
export STUB_FLOCK_FAIL_FD=209 STUB_FLOCK_FAIL_COUNT=1
restore_rc="$(run_fn_rc restore_state)"
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
assert_eq "P2-1: restore defers on generation-lock failure" "2" "$restore_rc"
assert_file "P2-1: restore wrote nothing" "$RAW_FILE" "10"
assert_file "P2-1: state kept for retry" "$STATE_FILE" "30"
assert_absent "P2-1: no generation published on failure" "$RESTORE_GEN_FILE"
assert_absent "P2-1: no PENDING staged on failure" "$RESTORE_PENDING_FILE"
assert_eq "P2-1: no D-Bus write on generation-lock failure" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"

reset_case
write_state 30
printf '10\n' > "$RAW_FILE"
: > "$SET_LOG"
export STUB_FLOCK_FAIL_FD=209 STUB_FLOCK_FAIL_COUNT=1
run_fn handle_unblank
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
wait 2> /dev/null || true
assert_file "P2-1: handle_unblank left LED alone" "$RAW_FILE" "10"
assert_file "P2-1: handle_unblank kept state" "$STATE_FILE" "30"
assert_eq "P2-1: handle_unblank spawned no guard write" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'unblank guard' "$DAEMON_ERR"; then
    bad "P2-1: a guard was armed despite the failed generation bump"
else
    ok "P2-1: no guard armed after failed generation bump"
fi

# P3-3. WRITE_LOCK failure paths of the remaining call sites: handle_blank
# keeps the LED on, and the CLI --test-blank reports failure (state is saved).
reset_case
printf '30\n' > "$RAW_FILE"
: > "$SET_LOG"
export STUB_FLOCK_FAIL_FD=209 STUB_FLOCK_FAIL_COUNT=1
run_fn handle_blank
unset STUB_FLOCK_FAIL_FD STUB_FLOCK_FAIL_COUNT
wait 2> /dev/null || true
assert_file "P3-3: handle_blank left LED on" "$RAW_FILE" "30"
assert_eq "P3-3: handle_blank issued no write" "0" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"
if grep -q 'blank: WRITE_LOCK unavailable; leaving LED on' "$DAEMON_ERR"; then
    ok "P3-3: blank lock failure is logged"
else
    bad "P3-3: blank lock failure not logged (stderr: $(cat "$DAEMON_ERR"))"
fi

reset_case
printf '30\n' > "$RAW_FILE"
cli_rc=0
cli_out="$(
    XDG_RUNTIME_DIR="$D_STATE_DIR" \
        C640_KBD_SYSFS_BRIGHTNESS="$FAKE_SYSFS" \
        C640_KBD_SYSFS_MAX="$FAKE_MAX" \
        STUB_FLOCK_DIR="$FLOCK_DIR" STUB_FLOCK_FAIL_FD=209 STUB_FLOCK_FAIL_COUNT=1 \
        STUB_FLOCK_LOG=/dev/null \
        STUB_GDBUS_LOG="$GDBUS_LOG" STUB_SET_LOG="$SET_LOG" \
        STUB_ECTOOL_LOG="$TMP_DIR/ectool.log" \
        STUB_RAW_FILE="$RAW_FILE" STUB_PCT_FILE="$PCT_FILE" \
        STUB_KBD_RAW=42 STUB_GNOME_ACTIVE=false STUB_FDO_ACTIVE=false \
        "$DAEMON" --test-blank 2> "$DAEMON_ERR"
)" || cli_rc=$?
assert_eq "P3-3: CLI --test-blank reports WRITE_LOCK failure" "1" "$cli_rc"
assert_file "P3-3: CLI left LED on" "$RAW_FILE" "30"
assert_file "P3-3: CLI still saved brightness first" "$STATE_FILE" "30"
if grep -q 'simulated blank: failed to set 0' "$DAEMON_ERR"; then
    ok "P3-3: CLI error message names the write failure"
else
    bad "P3-3: CLI error message missing: $(cat "$DAEMON_ERR"))"
fi

# P2-3 (torn read). The meta file is replaced between two cats: an old value
# (30) stamped G1 followed by a new value (70) stamped G2.  A single-read
# guard sees one coherent snapshot and repairs the lost G2 restore; a guard
# that cats twice would mistake "30@G2" for post-restore user intent.
reset_case
write_state 30
printf '30\n' > "$RAW_FILE"
run_fn restore_state
write_state 70
printf '70\n' > "$RAW_FILE"
run_fn restore_state
assert_eq "P2-3: G2 established" "2" "$(cat "$RESTORE_GEN_FILE" 2> /dev/null || echo '')"
printf 'value=30\nsource=nonzero\nts=1\nrestore=1\n' > "$STUB_TORN_OLD"
printf 'value=70\nsource=nonzero\nts=2\nrestore=2\n' > "$STUB_TORN_NEW"
: > "$STUB_TORN_COUNTER"
export STUB_TORN_META_ON=1
printf '70\n' > "$PCT_FILE"
printf '10\n' > "$RAW_FILE"
: > "$SET_LOG"
# Release the guards one at a time so the marker is published before the
# second guard checks it (the flock stub is not an atomic kernel lock).
start_gated_guard guard_unblank 70
assert_eq "P2-3: both unblank guard delays gated" "0.3,0.9," "$GUARD_STARTED"
: > "${STUB_SLEEP_RELEASE}.0.3"
if wait_for_file "$GUARD_WRITTEN_GEN_FILE"; then
    ok "P2-3: first guard published its written-generation marker"
else
    bad "P2-3: no guard marker after first guard"
fi
: > "${STUB_SLEEP_RELEASE}.0.9"
wait 2> /dev/null || true
export STUB_TORN_META_ON=0
export STUB_SLEEP_MODE=fast
assert_file "P2-3: coherent meta read repairs G2" "$RAW_FILE" "70"
assert_eq "P2-3: exactly one re-set (second guard suppressed)" "1" "$(grep -c 'Properties.Set' "$SET_LOG" || true)"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
    exit 1
fi
