#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# tests/rollback-test.sh - Sandboxed tests for lib/backup.sh backup/rollback
# primitives (install plan backup, manifest schema 2.0, service & group
# restoration). Run as root (the manifest lock tests create a root-owned 0600
# lock and call the helpers directly; a non-root shell with passwordless sudo
# is supported by the installers, but not by this direct-helper test suite):
#
#   sudo bash tests/rollback-test.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export LOG_FILE="${LOG_FILE:-/tmp/rollback-test.log}"

PASS=0
FAIL=0

fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}

ok() {
    PASS=$((PASS + 1))
}

assert_eq() {
    # $1=expected $2=actual $3=message
    if [ "$1" = "$2" ]; then
        ok
    else
        fail "$3 (expected: '$1', got: '$2')"
    fi
}

assert_contains() {
    # $1=needle $2=haystack $3=message
    if printf '%s' "$2" | grep -qF -- "$1"; then
        ok
    else
        fail "$3 (missing: '$1')"
    fi
}

assert_not_contains() {
    # $1=needle $2=haystack $3=message
    if printf '%s' "$2" | grep -qF -- "$1"; then
        fail "$3 (unexpected: '$1')"
    else
        ok
    fi
}

assert_neq() {
    if [ "$1" != "$2" ]; then
        ok
    else
        fail "$3 (both were: '$1')"
    fi
}

# Small helpers shared by the re-review #1/#2/#3 regression tests.
file_hex() { python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$1"; }
manifest_count() {
    # $1=manifest path, $2=top-level array key
    python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get(sys.argv[2], [])))' "$1" "$2"
}
manifest_names() {
    # $1=manifest path, $2=array key, $3=name key
    python3 -c 'import json,sys; print(" ".join(str(x[sys.argv[3]]) for x in json.load(open(sys.argv[1])).get(sys.argv[2], [])))' "$1" "$2" "$3"
}
write_demo_services_manifest() {
    # $1=sandbox $2=services JSON $3=records JSON (default [])
    python3 - "$1/manifest/install-manifest.json" "$2" "${3:-[]}" << 'PY'
import json, sys
mp, services, records = sys.argv[1:4]
json.dump({"version": "2.0", "records": json.loads(records),
           "services": json.loads(services), "groups": []},
          open(mp, "w"), indent=2)
PY
}

# ---------------------------------------------------------------------------
# Infrastructure for the re-review #9 finding #1 (cross-process manifest lock)
# concurrency tests. Each case uses its OWN mktemp -d sandbox and FIFO
# rendezvous, so no fixed /tmp path can collide with the legacy cases.
# ---------------------------------------------------------------------------
LOCK_TEST_SANDBOXES=()
# Every make_manifest_lock_sandbox() call runs inside `$( ...)`, so its array
# append only mutates a SUBSHELL array — the EXIT trap never saw those paths
# and /tmp/rollback-test-lock-* accumulated across runs. Tag every sandbox
# with this run's PID and sweep by that exact prefix: nothing left behind, and
# no wildcard that could delete another session's sandboxes.
LOCK_TEST_RUN_TAG="$$"
# PAM sandbox paths (re-review #11 finding #2) use the same per-run tag so the
# EXIT trap below can sweep them even though setup_pam_sandbox() runs inside a
# $(...) subshell whose array append is not visible to the parent.
PAM_TEST_SANDBOXES=()
# T12 publishes its path here so an early failure still releases its bounded
# waiter (the prefix sweep below is the actual removal safety net).
T12_CRASH_SANDBOX=""
cleanup_lock_test_sandboxes() {
    local s
    for s in "${LOCK_TEST_SANDBOXES[@]}"; do
        [ -n "$s" ] || continue
        # Release any bounded crash-simulation waiter before removing its
        # sandbox (T12 polls for this file instead of sleeping for 60s).
        : > "$s/crash.stop" 2> /dev/null || true
        rm -rf -- "$s"
    done
    for s in "${PAM_TEST_SANDBOXES[@]}"; do
        [ -n "$s" ] || continue
        rm -rf -- "$s"
    done
    if [ -n "$T12_CRASH_SANDBOX" ]; then
        : > "$T12_CRASH_SANDBOX/crash.stop" 2> /dev/null || true
    fi
    rm -rf -- /tmp/rollback-test-lock-"$LOCK_TEST_RUN_TAG"-* 2> /dev/null || true
    rm -rf -- /tmp/rollback-test-pam-"$LOCK_TEST_RUN_TAG"-* 2> /dev/null || true
    rm -rf -- /var/tmp/rollback-test-pam-suid-"$LOCK_TEST_RUN_TAG" 2> /dev/null || true
}
trap cleanup_lock_test_sandboxes EXIT

make_manifest_lock_sandbox() {
    # $1=short name; echoes a fresh absolute path. The run-tag sweep in the
    # EXIT trap cleans it even though this function runs in a $(...) subshell.
    local s
    s="$(mktemp -d "/tmp/rollback-test-lock-$LOCK_TEST_RUN_TAG-$1-XXXXXX")"
    mkdir -p "$s/manifest" "$s/backups" "$s/stub" "$s/root" "$s/snapshots"
    # sudo execs directly: PATH / PYTHONPATH / STUB_* reach the python writers,
    # so the Phase 1 sitecustomize os.replace fault stub still works with the
    # lock in place. (No `sudo -u` / `env -i` anywhere in the lock helpers.)
    printf '#!/usr/bin/env bash\n[ "${1:-}" = "-u" ] && shift 2\nexec "$@"\n' > "$s/stub/sudo"
    # Delay ONLY real writers (python argc>=6); validator/probe calls (argc 3/5)
    # pass through. This widens the old stale-snapshot window so the pre-lock
    # code loses a record deterministically, while the locked code merely
    # serialises: the second writer waits, re-reads and keeps both records.
    cat > "$s/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -ge 6 ] && [ -n "${STUB_MANIFEST_WRITE_DELAY:-}" ]; then
    sleep "$STUB_MANIFEST_WRITE_DELAY"
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$s/stub/sudo" "$s/stub/python3"
    LOCK_TEST_SANDBOXES+=("$s")
    printf '%s\n' "$s"
}

manifest_lock_barrier_init() {
    # Two FIFOs opened read-write by workers, so neither open() blocks.
    mkfifo "$1/ready" "$1/go"
}

barrier_release() {
    # $1=sandbox $2=worker count. Bounded reads keep a stuck worker from
    # hanging CI; a timeout simply makes the assertions fail instead.
    local s="$1" n="$2" i
    for ((i = 0; i < n; i++)); do
        if ! read -r -t 20 _ < "$s/ready"; then
            echo "WARN: barrier ready timed out ($i/$n)" >&2
            break
        fi
    done
    for ((i = 0; i < n; i++)); do
        printf 'g\n' > "$s/go" || break
    done
}

worker_wait_pid() {
    # $1=pid — bound `wait` so a deadlocked worker cannot hang the suite.
    local pid="$1" i=0
    while kill -0 "$pid" 2> /dev/null && [ "$i" -lt 300 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$pid" 2> /dev/null; then
        kill -9 "$pid" 2> /dev/null || true
    fi
    wait "$pid" 2> /dev/null || true
}

op_wait_for_file() {
    # $1=file $2=attempts (0.05s each); 0 when it appeared, 1 on timeout.
    local f="$1" n="$2" i=0
    while [ ! -e "$f" ] && [ "$i" -lt "$n" ]; do
        sleep 0.05
        i=$((i + 1))
    done
    [ -e "$f" ]
}

# ---------------------------------------------------------------------------
# Re-review #10 finding #1: an operation-level lock must cover
# "backup/record -> deploy -> finish/rollback" for the SAME target. Only
# `install` is intercepted so A can pause after its manifest record is written
# but before the deployed file appears; `sudo sh` (lock init) and `sudo cp`
# (backup_file) still run for real. Env: STUB_DEPLOY_BARRIER=1,
# STUB_FIRED_FILE, STUB_RELEASE_FILE.
# ---------------------------------------------------------------------------
setup_deploy_barrier_stub() {
    cat > "$1/stub/install" << 'EOF'
#!/usr/bin/env bash
if [ "${STUB_DEPLOY_BARRIER:-0}" = "1" ] && [ "${1:-}" = "-D" ]; then
    : > "${STUB_FIRED_FILE:?}"
    i=0
    while [ ! -e "${STUB_RELEASE_FILE:?}" ] && [ "$i" -lt 400 ]; do
        sleep 0.1
        i=$((i + 1))
    done
fi
exec /usr/bin/install "$@"
EOF
    chmod +x "$1/stub/install"
}

# A: a REAL run_manifest_operation around the install pattern used by every
# installer (unguarded backup gate, then sudo install -D). $3=target $4=comp.
OP_DEPLOY_WORKER='
    export PATH="$2/stub:$PATH"
    SB="$2"
    source "$1/lib/backup.sh"
    deploy_target() {
        local target="$1" comp="$2"
        backup_file_manifest_aware "$target" "$comp" || return $?
        sudo install -D -m 0644 "$SB/deploy.src" "$target"
    }
    exec 3<>"$SB/ready" 4<>"$SB/go"
    printf "r\n" >&3
    read -r _ <&4
    rc=0
    run_manifest_operation deploy_target "$3" "$4" || rc=$?
    printf "%s\n" "$rc" > "$SB/a.rc"
'

# B: rollback of the same component through the SAME operation-level wrapper.
OP_ROLLBACK_WORKER='
    export PATH="$2/stub:$PATH"
    SB="$2"
    source "$1/lib/backup.sh"
    rc=0
    run_manifest_operation rollback_component "$3" || rc=$?
    printf "%s\n" "$rc" > "$SB/b.rc"
'

# Worker body used by T1/T7: synchronise at the barrier, then install one
# target. `$3` is the target/component supplied via run_sandboxed.
LOCK_INSTALL_WORKER='
    export PATH="$2/stub:$PATH"
    source "$1/lib/backup.sh"
    exec 3<>"$2/ready" 4<>"$2/go"
    printf "r\n" >&3
    read -r _ <&4
    rc=0
    backup_file_manifest_aware "$2/root/$3.conf" "$3" || rc=$?
    printf "%s\n" "$rc" > "$2/$3.rc"
    exit 0
'

# Fault injection for the #2 (atomic-replace) regressions: make ONLY the final
# rollback stage->target os.replace() fail. `sudo` is stubbed with exec "$@" so
# it does NOT strip PYTHONPATH; sitecustomize.py patches os.replace keyed on the
# stage marker and destination, so the manifest write-back (whose src is a
# plain *.tmp, not *.cros-rollback-tmp-*) still succeeds and the record is
# retained. Every path stays under /tmp/rollback-test-*.
setup_rollback_replace_fault_stub() {
    local sandbox="$1"
    mkdir -p "$sandbox/stub" "$sandbox/pyfault"
    printf '#!/usr/bin/env bash\nexec "$@"\n' > "$sandbox/stub/sudo"
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
exec /usr/bin/python3 "$@"
EOF
    cat > "$sandbox/pyfault/sitecustomize.py" << 'EOF'
import os
_real_replace = os.replace

def _faulty_replace(src, dst, *args, **kwargs):
    if (os.environ.get("STUB_FAIL_ROLLBACK_REPLACE") == "1"
            and ".cros-rollback-tmp-" in str(src)
            and str(dst) == os.environ.get("STUB_FAIL_REPLACE_TARGET", "")):
        raise OSError(5, "injected EIO on rollback stage replace")
    return _real_replace(src, dst, *args, **kwargs)

os.replace = _faulty_replace
EOF
    chmod +x "$sandbox/stub/sudo" "$sandbox/stub/python3"
}

# Sandbox helper: run a backup.sh snippet with sandboxed dirs and an
# extended ALLOWED_PREFIXES so targets under the sandbox stay in scope.
run_sandboxed() {
    # $1=sandbox, remaining args passed to bash -c "$1" _ "$REPO_ROOT" "$sandbox" ...
    # RB_TEST_TIMEOUT (when > 0) bounds a single snippet; used by the FIFO
    # fail-closed test so a regression to a blocking open cannot hang CI.
    local sandbox="$1"
    shift
    # Provide a sane default snapshot base, but never overwrite a base that a
    # security test deliberately created as world-writable or as a symlink.
    # The production base check now requires EVERY component to be root-owned,
    # so create this base with sudo/root ownership rather than as the (possibly
    # non-root) test user.
    if [ ! -d "$sandbox/snapshots" ] && [ ! -L "$sandbox/snapshots" ]; then
        sudo install -d -m 700 -o 0 -g 0 -- "$sandbox/snapshots"
    fi
    CROS_ENABLEMENT_BACKUP_DIR="$sandbox/backups" \
        CROS_ENABLEMENT_MANIFEST_DIR="$sandbox/manifest" \
        CROS_ENABLEMENT_KEYD_SNAPSHOT_DIR="$sandbox/snapshots" \
        CROS_ENABLEMENT_ALLOWED_PREFIXES="/tmp/rollback-test-* /etc/ /usr/ /lib/ /lib64/ /opt/ /var/lib/fprint/" \
        CROS_ENABLEMENT_INSTALLED_TESTS_PREFIXES="$sandbox/root/usr/libexec/installed-tests/ $sandbox/root/usr/share/installed-tests/" \
        LOG_FILE="$sandbox/log.txt" \
        timeout "${RB_TEST_TIMEOUT:-0}" bash -c "$1" _ "$REPO_ROOT" "$sandbox" "${@:2}"
}

# ---------------------------------------------------------------------------
# 1. install -> uninstall of a pre-existing file restores the original bytes
# ---------------------------------------------------------------------------
test_restore_existing() {
    local sandbox="/tmp/rollback-test-restore"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/etc" "$sandbox/backups" "$sandbox/manifest"
    echo "ORIGINAL" > "$sandbox/etc/demo.conf"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        backup_file_manifest_aware "$2/etc/demo.conf" "demo"
    '

    echo "CUSTOM" > "$sandbox/etc/demo.conf"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rollback_component "demo"
    '

    local content
    content="$(cat "$sandbox/etc/demo.conf")"
    assert_eq "ORIGINAL" "$content" "existing file restored to original after rollback"
}

# ---------------------------------------------------------------------------
# 2. newly-created file is removed on rollback
# ---------------------------------------------------------------------------
test_remove_new_file() {
    local sandbox="/tmp/rollback-test-newfile"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/etc" "$sandbox/backups" "$sandbox/manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        backup_file_manifest_aware "$2/etc/new.conf" "demo"
    '

    echo "NEW" > "$sandbox/etc/new.conf"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rollback_component "demo"
    '

    if [ ! -e "$sandbox/etc/new.conf" ]; then
        ok
    else
        fail "newly-created file should be removed on rollback"
    fi
}

# ---------------------------------------------------------------------------
# 3. double install keeps the FIRST backup; rollback restores the original
# ---------------------------------------------------------------------------
test_double_install() {
    local sandbox="/tmp/rollback-test-double"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/etc" "$sandbox/backups" "$sandbox/manifest"
    echo "ORIGINAL" > "$sandbox/etc/demo.conf"

    for i in 1 2; do
        run_sandboxed "$sandbox" '
            source "$1/lib/backup.sh"
            backup_file_manifest_aware "$2/etc/demo.conf" "demo"
        '
        echo "CUSTOM-$i" > "$sandbox/etc/demo.conf"
    done

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rollback_component "demo"
    '

    assert_eq "ORIGINAL" "$(cat "$sandbox/etc/demo.conf")" "double install restores the original file"
    local backup_count
    backup_count="$(find "$sandbox/backups" -name demo.conf 2> /dev/null | wc -l)"
    assert_eq "1" "$backup_count" "double install keeps a single backup"
}

# ---------------------------------------------------------------------------
# 4. out-of-scope / dangerous targets are skipped and stay in the manifest
# ---------------------------------------------------------------------------
test_scope_protection() {
    local sandbox="/tmp/rollback-test-scope"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/var/log"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        backup_file_manifest_aware "/var/log/foo.log" "demo"
        backup_file_manifest_aware "/usr/share/test-demo.txt" "demo"
    '

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rollback_component "demo"
    '

    local remaining
    remaining="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["records"]))' "$sandbox/manifest/install-manifest.json")"
    assert_eq "1" "$remaining" "out-of-scope targets remain in the manifest"
}

# ---------------------------------------------------------------------------
# 5. symlinks are restored as symlinks
# ---------------------------------------------------------------------------
test_symlink_restore() {
    local sandbox="/tmp/rollback-test-symlink"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/etc" "$sandbox/backups" "$sandbox/manifest"
    echo "TARGET-BODY" > "$sandbox/etc/real-file"
    ln -s real-file "$sandbox/etc/liblink"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        backup_file_manifest_aware "$2/etc/liblink" "demo"
    '

    rm "$sandbox/etc/liblink"
    echo "OTHER" > "$sandbox/etc/liblink"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rollback_component "demo"
    '

    if [ -L "$sandbox/etc/liblink" ] && [ "$(readlink "$sandbox/etc/liblink")" = "real-file" ]; then
        ok
    else
        fail "symlink target should be restored as a symlink"
    fi
}

# ---------------------------------------------------------------------------
# 6. meson install plan backs up every destination, installed-tests filtered
# ---------------------------------------------------------------------------
test_meson_plan() {
    local sandbox="/tmp/rollback-test-plan"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/build/meson-info" "$sandbox/backups" "$sandbox/manifest" \
        "$sandbox/root/usr/lib" "$sandbox/root/usr/share"
    touch "$sandbox/root/usr/lib/libfprint-2.so.2.0.0" \
        "$sandbox/root/usr/share/FPrint-2.0.gir"
    ln -s libfprint-2.so.2.0.0 "$sandbox/root/usr/lib/libfprint-2.so.2"
    ln -s libfprint-2.so.2.0.0 "$sandbox/root/usr/lib/libfprint-2.so"

    cat > "$sandbox/build/meson-info/intro-installed.json" << EOF
{
  "/tmp/root/src1.c": "$sandbox/root/usr/lib/libfprint-2.so.2.0.0",
  "/tmp/root/src2.c": "$sandbox/root/usr/lib/libfprint-2.so.2",
  "/tmp/root/src3.c": "$sandbox/root/usr/lib/libfprint-2.so",
  "/tmp/root/src4.c": "$sandbox/root/usr/lib/pkgconfig/libfprint-2.pc",
  "/tmp/root/src5.c": "$sandbox/root/usr/share/gir-1.0/FPrint-2.0.gir",
  "/tmp/root/src6.c": "$sandbox/root/usr/libexec/installed-tests/libfprint/foo.test",
  "/tmp/root/src7.c": "$sandbox/root/usr/share/installed-tests/libfprint/bar.test"
}
EOF

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        backup_meson_install_plan "$2/build" "demo"
    '

    local records
    records="$(python3 -c 'import json,sys; print(json.dumps([r["target"] for r in json.load(open(sys.argv[1]))["records"]]))' "$sandbox/manifest/install-manifest.json")"
    assert_contains "$sandbox/root/usr/lib/libfprint-2.so.2.0.0" "$records" "plan records the .so.2.0.0"
    assert_contains "$sandbox/root/usr/lib/libfprint-2.so.2" "$records" "plan records the soname symlink"
    assert_contains "$sandbox/root/usr/lib/libfprint-2.so" "$records" "plan records the .so symlink"
    assert_contains "$sandbox/root/usr/lib/pkgconfig/libfprint-2.pc" "$records" "plan records the .pc file"
    assert_contains "$sandbox/root/usr/share/gir-1.0/FPrint-2.0.gir" "$records" "plan records the .gir file"
    if printf '%s' "$records" | grep -q "installed-tests"; then
        fail "installed-tests destinations must be filtered out"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 7. service records are removed from the manifest after rollback
# ---------------------------------------------------------------------------
test_service_manifest() {
    local sandbox="/tmp/rollback-test-service"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc" "$sandbox/stub"
    # rollback now checks every systemctl returncode. Without a stub the real
    # systemctl would return non-zero for the fake unit and make rollback rc 1
    # (which would abort this test under `set -e`). The sudo stub keeps PATH
    # pointing at our systemctl stub inside `sudo python3`, too.
    printf '#!/usr/bin/env bash\n[ "${1:-}" = "-u" ] && shift 2\nexec "$@"\n' > "$sandbox/stub/sudo"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${STUB_SYSTEMCTL_LOG:?}"\nexit 0\n' > "$sandbox/stub/systemctl"
    chmod +x "$sandbox/stub/sudo" "$sandbox/stub/systemctl"
    : > "$sandbox/systemctl.log"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        backup_file_manifest_aware "$2/etc/demo.conf" "demo"
    '

    sudo python3 - "$sandbox/manifest/install-manifest.json" << 'EOF'
import json, sys
mp = sys.argv[1]
d = json.load(open(mp))
d.setdefault("services", []).append({
    "name": "demo.service", "component": "demo",
    "was_enabled": False, "was_active": False
})
json.dump(d, open(mp, "w"), indent=2)
EOF

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    '
    assert_eq "0" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "service manifest rollback: rc 0 with a working systemctl stub"

    local services
    services="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("services", [])))' "$sandbox/manifest/install-manifest.json")"
    assert_eq "0" "$services" "service record removed from manifest after rollback"
    assert_eq "0" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("records", [])))' "$sandbox/manifest/install-manifest.json")" "file record removed after rollback"
}

# ---------------------------------------------------------------------------
# 8. group membership: record is written with was_member and user
# ---------------------------------------------------------------------------
test_group_manifest() {
    local sandbox="/tmp/rollback-test-group"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        manifest_add_group "plugdev" "testuser" "demo"
    '

    local groups
    groups="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("groups", [])))' "$sandbox/manifest/install-manifest.json")"
    assert_contains '"group": "plugdev"' "$groups" "group record written to manifest"
    assert_contains '"user": "testuser"' "$groups" "group record carries the user"
}

# ---------------------------------------------------------------------------
# 9. legacy manifest (1.0) rollback does not crash
# ---------------------------------------------------------------------------
test_legacy_manifest() {
    local sandbox="/tmp/rollback-test-legacy"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    echo '{"version":"1.0","records":[{"target":"/tmp/rollback-test-legacy/etc/legacy.conf","component":"demo","was_existing":true}]}' \
        > "$sandbox/manifest/install-manifest.json"
    echo "LEGACY" > "$sandbox/etc/legacy.conf"
    mkdir -p "$sandbox/backups/20260101_000000000000000/tmp/rollback-test-legacy/etc"
    echo "ORIGINAL" > "$sandbox/backups/20260101_000000000000000/tmp/rollback-test-legacy/etc/legacy.conf"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rollback_component "demo"
    '

    assert_eq "ORIGINAL" "$(cat "$sandbox/etc/legacy.conf")" "legacy manifest restores from backup"
}

# ---------------------------------------------------------------------------
# 10. reinstall: first group record wins (installer-created membership must
#     be removed on uninstall even after a reinstall overwrote the state)
# ---------------------------------------------------------------------------
test_group_reinstall_first_wins() {
    local sandbox="/tmp/rollback-test-group-reinstall"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        manifest_add_group "plugdev" "testuser" "demo"
    '
    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        # reinstall: user is now a member (state WE created) — must NOT
        # overwrite the original was_member=false record
        manifest_add_group "plugdev" "testuser" "demo" "1"
    '

    local was_member
    was_member="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("groups", [])[0]["was_member"])' "$sandbox/manifest/install-manifest.json")"
    assert_eq "False" "$was_member" "first group record wins over reinstall"
    assert_eq "1" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("groups", [])))' "$sandbox/manifest/install-manifest.json")" "only one group record after reinstall"
}

# ---------------------------------------------------------------------------
# 11. reinstall: first service record wins (rollback must not re-enable a
#     unit that was disabled before the original install)
# ---------------------------------------------------------------------------
test_service_reinstall_first_wins() {
    local sandbox="/tmp/rollback-test-svc-reinstall"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/stub"

    printf '#!/usr/bin/env bash\ncase "$*" in\n  *"--global cat"*) exit 1 ;;\n  *" cat "*) exit 0 ;;\n  *"is-enabled"*|*"is-active"*) [ -e "${STUB_UNIT_STATE_FILE:-}" ] && exit 0 || exit 1 ;;\n  *) exit 0 ;;\nesac\n' > "$sandbox/stub/systemctl"
    chmod +x "$sandbox/stub/systemctl"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        manifest_add_service "demo.service" "demo"
    '
    # install enables+starts the unit; a reinstall must not re-record that
    touch "$sandbox/unit-enabled"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_UNIT_STATE_FILE="$2/unit-enabled"
        source "$1/lib/backup.sh"
        manifest_add_service "demo.service" "demo"
    '

    local state
    state="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])).get("services", [])[0]; print(s["was_enabled"], s["was_active"])' "$sandbox/manifest/install-manifest.json")"
    assert_eq "False False" "$state" "first service record wins over reinstall"
    assert_eq "1" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("services", [])))' "$sandbox/manifest/install-manifest.json")" "only one service record after reinstall"
}

# ---------------------------------------------------------------------------
# 12. gpasswd failure keeps the manifest record (so a later uninstall can
#     retry the removal)
# ---------------------------------------------------------------------------
test_group_remove_keeps_record_on_failure() {
    local sandbox="/tmp/rollback-test-grp-fail"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        manifest_add_group "cros-testgrp" "nobody" "demo"
        # nobody is not a member of the (nonexistent) group -> gpasswd fails.
        # The helper now reports that as rc 1 (no fake success); guard the call
        # so `set -e` does not abort the whole suite here (R10).
        rc=0
        remove_group_membership "cros-testgrp" "nobody" "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/remove-rc.txt"
    '
    assert_eq "1" "$(cat "$sandbox/remove-rc.txt" 2> /dev/null || echo MISSING)" \
        "R10: gpasswd failure must return nonzero (no fake success)"

    local groups
    groups="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("groups", [])))' "$sandbox/manifest/install-manifest.json")"
    assert_contains '"group": "cros-testgrp"' "$groups" "group record kept when gpasswd fails"
}

# ---------------------------------------------------------------------------
# Re-review #4 (P2): plugdev membership must be RECORDED before /etc/group is
# changed, and a failed change must undo the fresh record. Shared fault-
# injection stubs: sudo execs directly so usermod/gpasswd/python3 are
# intercepted through PATH. Every write stays inside the sandbox.
# ---------------------------------------------------------------------------
setup_group_fault_stubs() {
    local sandbox="$1"
    mkdir -p "$sandbox/stub"
    # sudo just runs the command (all destinations are sandboxed).
    printf '#!/usr/bin/env bash\n[ "${1:-}" = "-u" ] && shift 2\nexec "$@"\n' > "$sandbox/stub/sudo"
    # getent always reports an existing plugdev so groupadd is skipped.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sandbox/stub/getent"
    # id: -u succeeds for any user; -nG is controlled by STUB_USER_IN_PLUGDEV.
    cat > "$sandbox/stub/id" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then echo 1000; exit 0; fi
if [ "$1" = "-nG" ]; then
    if [ "${STUB_USER_IN_PLUGDEV:-0}" = "1" ]; then echo "audio plugdev"; else echo "audio"; fi
    exit 0
fi
exec /usr/bin/id "$@"
EOF
    # usermod/gpasswd only record calls; rc is injectable.
    cat > "$sandbox/stub/usermod" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_USERMOD_LOG:?}"
exit "${STUB_USERMOD_RC:-0}"
EOF
    cat > "$sandbox/stub/gpasswd" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_GPASSWD_LOG:?}"
exit "${STUB_GPASSWD_RC:-0}"
EOF
    chmod +x "$sandbox/stub/sudo" "$sandbox/stub/getent" "$sandbox/stub/id" \
        "$sandbox/stub/usermod" "$sandbox/stub/gpasswd"
}

# Re-review #11 finding #1: stateful, sandbox-only group stubs. Build on the
# existing fault stubs, then overlay id/usermod/gpasswd with versions that keep
# a fake membership list in STUB_GROUP_STATE and add a grep stub that redirects
# the production udev scan into STUB_UDEV_DIR. When STUB_GROUP_STATE is absent
# the id stub keeps the old static behaviour, so the 1,199 existing cases that
# use setup_group_fault_stubs alone are unaffected. Nothing here writes to the
# host /etc/group, /etc/gshadow or /etc/udev/rules.d.
setup_group_state_stubs() {
    local sandbox="$1"
    setup_group_fault_stubs "$sandbox"
    cat > "$sandbox/stub/id" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then echo 1000; exit 0; fi
if [ "$1" = "-nG" ]; then
    if [ -n "${STUB_GROUP_STATE:-}" ] && [ -f "$STUB_GROUP_STATE" ]; then
        /usr/bin/tr '\n' ' ' < "$STUB_GROUP_STATE"
        echo
        exit 0
    fi
    if [ "${STUB_USER_IN_PLUGDEV:-0}" = "1" ]; then echo "audio plugdev"; else echo "audio"; fi
    exit 0
fi
exec /usr/bin/id "$@"
EOF
    cat > "$sandbox/stub/usermod" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_USERMOD_LOG:?}"
rc="${STUB_USERMOD_RC:-0}"
if [ "$rc" -eq 0 ] && [ "${1:-}" = "-aG" ] && [ -n "${STUB_GROUP_STATE:-}" ]; then
    /usr/bin/grep -qx "$2" "$STUB_GROUP_STATE" 2> /dev/null || \
        printf '%s\n' "$2" >> "$STUB_GROUP_STATE"
fi
exit "$rc"
EOF
    cat > "$sandbox/stub/gpasswd" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_GPASSWD_LOG:?}"
rc="${STUB_GPASSWD_RC:-0}"
# A failed gpasswd must not change the fake membership (retry semantics).
if [ "$rc" -eq 0 ] && [ "${1:-}" = "-d" ] && [ -n "${STUB_GROUP_STATE:-}" ] && \
   [ -f "$STUB_GROUP_STATE" ]; then
    tmp="${STUB_GROUP_STATE}.new"
    /usr/bin/grep -vx "$3" "$STUB_GROUP_STATE" > "$tmp" 2> /dev/null || true
    /bin/mv "$tmp" "$STUB_GROUP_STATE"
fi
exit "$rc"
EOF
    # Intercept ONLY the exact udev scan from lib/backup.sh. Every other grep
    # (validator/id filters/tests) is passed through to the real binary.
    cat > "$sandbox/stub/grep" << 'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-rl" ] && [[ "${2:-}" == GROUP=* ]] && \
   [ "${3:-}" = "/etc/udev/rules.d/" ]; then
    exec /usr/bin/grep -rl -- "$2" "${STUB_UDEV_DIR:-/nonexistent-udev}" 2>/dev/null
fi
exec /usr/bin/grep "$@"
EOF
    chmod +x "$sandbox/stub/id" "$sandbox/stub/usermod" \
        "$sandbox/stub/gpasswd" "$sandbox/stub/grep"
    mkdir -p "$sandbox/stub" "$sandbox/udev"
    : > "$sandbox/group-state" # user is initially in no managed group
    : > "$sandbox/usermod.log"
    : > "$sandbox/gpasswd.log"
}

block_group_manifest_write() {
    # Refuse ONLY the group add writer manifest_add_group (argc=8, script mentions
    # was_member); the clear writer (argc=6) passes. Stub threshold is argc>=7.
    # manifest_remove_group / rollback (argc=6) and validator (argc=3) pass.
    local sandbox="$1"
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -ge 7 ] && printf '%s' "${2:-}" | grep -q 'was_member'; then
    printf 'STUB: group manifest write refused\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/python3"
}

group_count() {
    [ -f "$1" ] || {
        echo 0
        return 0
    }
    manifest_count "$1" groups
}

grp_was_member() {
    python3 -c 'import json,sys; g=json.load(open(sys.argv[1])).get("groups",[]); print(g[0]["was_member"] if g else "none")' "$1"
}

usermod_calls() {
    [ -f "$1" ] || {
        echo 0
        return 0
    }
    wc -l < "$1" | tr -d '[:space:]'
}

# T1 (helper): manifest write fails -> no usermod, no group record, nonzero rc.
test_ensure_group_manifest_write_failure_no_membership_change() {
    local sandbox="/tmp/rollback-test-ensure-grp-manifest-fail"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_fault_stubs "$sandbox"
    block_group_manifest_write "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_USERMOD_LOG="$2/usermod.log" STUB_USER_IN_PLUGDEV=0
        source "$1/lib/backup.sh"
        rc=0
        ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/helper-rc.txt"
        exit 0
    '
    assert_eq "1" "$(cat "$sandbox/helper-rc.txt" 2> /dev/null || echo MISSING)" \
        "T1: helper fails closed when group manifest write fails"
    assert_eq "0" "$(usermod_calls "$sandbox/usermod.log")" \
        "T1: usermod must NOT be called when manifest write failed"
    assert_eq "0" "$(group_count "$mp")" "T1: no group record written"
    assert_contains "Group manifest write failed" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "T1: root cause logged"
    assert_contains "refusing to change membership" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "T1: explicit refusal logged"
    assert_eq "0" "$(find "$sandbox/manifest" -name '*.tmp' | wc -l | tr -d '[:space:]')" \
        "T1: no .tmp residue"
}

# T2 (caller): installer propagates the helper failure instead of swallowing it
# under `install_keyboard || rc=$?` (errexit suppressed in the harness).
test_plugdev_manifest_write_failure_install_fails_without_membership() {
    local sandbox="/tmp/rollback-test-plugdev-manifest-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    setup_group_fault_stubs "$sandbox"
    block_group_manifest_write "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_USERMOD_LOG="$2/usermod.log" STUB_USER_IN_PLUGDEV=0 \
            WITH_KEYD=0
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo "testuser"; }
        install_rc=0
        install_keyboard || install_rc=$?
        printf "%s\n" "$install_rc" > "$2/install-rc.txt"
        exit 0
    '
    assert_eq "1" "$(cat "$sandbox/install-rc.txt" 2> /dev/null || echo MISSING)" \
        "T2: installer propagates the manifest-write helper failure"
    assert_eq "0" "$(usermod_calls "$sandbox/usermod.log")" \
        "T2: usermod must NOT be called when manifest write failed"
    assert_eq "0" "$(group_count "$mp")" "T2: no group record written"
    assert_contains "plugdev membership setup failed for 'testuser'" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "T2: caller logs the membership failure"
    assert_contains "refusing to continue (udev rule" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "T2: explicit refusal logged"
}

# T3 (helper): usermod fails -> the record just written is rolled back.
test_ensure_group_usermod_failure_rolls_back_manifest() {
    local sandbox="/tmp/rollback-test-ensure-grp-usermod-fail"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_fault_stubs "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_USERMOD_RC=1 STUB_USER_IN_PLUGDEV=0
        source "$1/lib/backup.sh"
        rc=0
        ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/helper-rc.txt"
        lrc=0
        manifest_load || lrc=$?
        printf "%s\n" "$lrc" > "$2/load-rc.txt"
        exit 0
    '
    assert_eq "1" "$(cat "$sandbox/helper-rc.txt" 2> /dev/null || echo MISSING)" \
        "T3: helper returns nonzero when usermod fails"
    assert_eq "1" "$(usermod_calls "$sandbox/usermod.log")" "T3: usermod called exactly once"
    assert_contains "-aG plugdev testuser" "$(cat "$sandbox/usermod.log" 2> /dev/null || echo "")" \
        "T3: correct usermod invocation"
    assert_eq "0" "$(group_count "$mp")" "T3: fresh group record rolled back"
    assert_contains "Failed to add 'testuser' to group 'plugdev'" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "T3: failure logged (no false 'Added' message)"
    assert_eq "0" "$(cat "$sandbox/load-rc.txt" 2> /dev/null || echo MISSING)" \
        "T3: manifest still valid after rollback"
    assert_eq "0" "$(find "$sandbox/manifest" -name '*.tmp' | wc -l | tr -d '[:space:]')" \
        "T3: no .tmp residue"
}

# T4 (caller): usermod failure propagates; only the group record we just wrote
# is rolled back. A pre-existing record for a DIFFERENT component (same user,
# same group) and the file records from earlier steps all survive.
test_plugdev_usermod_failure_install_nonzero_no_false_record() {
    local sandbox="/tmp/rollback-test-plugdev-usermod-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    setup_group_fault_stubs "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"
    python3 - "$mp" << 'PY'
import json, sys
json.dump({"version": "2.0", "records": [], "services": [],
           "groups": [{"group": "plugdev", "user": "testuser",
                       "component": "fingerprint", "was_member": False}]},
          open(sys.argv[1], "w"), indent=2)
PY

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_USERMOD_LOG="$2/usermod.log" STUB_USERMOD_RC=1 \
            STUB_USER_IN_PLUGDEV=0 WITH_KEYD=0
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo "testuser"; }
        install_rc=0
        install_keyboard || install_rc=$?
        printf "%s\n" "$install_rc" > "$2/install-rc.txt"
        exit 0
    '
    assert_eq "1" "$(cat "$sandbox/install-rc.txt" 2> /dev/null || echo MISSING)" \
        "T4: installer propagates usermod failure"
    assert_eq "1" "$(usermod_calls "$sandbox/usermod.log")" "T4: usermod called exactly once"
    assert_eq "1" "$(group_count "$mp")" "T4: only the keyboard record was rolled back"
    assert_eq "fingerprint" \
        "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["groups"][0]["component"])' "$mp")" \
        "T4: other component's group record survives the rollback"
    if [ "$(manifest_count "$mp" records)" -ge 2 ]; then
        ok
    else
        fail "T4: rollback of the group record must not touch earlier file records"
    fi
}

# T5: success path plus reinstall first-wins (the original was_member=false is
# never overwritten), and a first install of an existing member is never
# usermod'ed nor later removed by uninstall.
test_plugdev_success_and_reinstall_first_wins() {
    local sandbox="/tmp/rollback-test-plugdev-first-wins"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_fault_stubs "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_USERMOD_LOG="$2/usermod1.log" STUB_USER_IN_PLUGDEV=0
        source "$1/lib/backup.sh"
        rc=0
        ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/helper1-rc.txt"
        exit 0
    '
    assert_eq "0" "$(cat "$sandbox/helper1-rc.txt" 2> /dev/null || echo MISSING)" \
        "T5: first install succeeds"
    assert_eq "1" "$(usermod_calls "$sandbox/usermod1.log")" "T5: usermod called once on first install"
    assert_eq "1" "$(group_count "$mp")" "T5: one group record"
    assert_eq "False" "$(grp_was_member "$mp")" "T5: original non-member state recorded"

    # Reinstall: user is now a member. No usermod, no overwrite of was_member.
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_USERMOD_LOG="$2/usermod2.log" STUB_USER_IN_PLUGDEV=1
        source "$1/lib/backup.sh"
        rc=0
        ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/helper2-rc.txt"
        exit 0
    '
    assert_eq "0" "$(cat "$sandbox/helper2-rc.txt" 2> /dev/null || echo MISSING)" \
        "T5: reinstall succeeds"
    assert_eq "0" "$(usermod_calls "$sandbox/usermod2.log")" "T5: reinstall does not re-add member"
    assert_eq "1" "$(group_count "$mp")" "T5: still one group record after reinstall"
    assert_eq "False" "$(grp_was_member "$mp")" "T5: first-wins was_member preserved"

    # First install of a pre-existing member: no usermod; uninstall must not
    # gpasswd -d them (was_member=true is not our membership).
    local s2="/tmp/rollback-test-plugdev-already-member"
    rm -rf "$s2"
    mkdir -p "$s2/backups" "$s2/manifest"
    setup_group_fault_stubs "$s2"
    local mp2="$s2/manifest/install-manifest.json"
    run_sandboxed "$s2" '
        export PATH="$2/stub:$PATH" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log" STUB_USER_IN_PLUGDEV=1
        source "$1/lib/backup.sh"
        rc=0
        ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/helper-rc.txt"
        # Snapshot the ORIGINAL state right after install: the rc-3 uninstall
        # path may consume all-true records when no udev rule needs the group,
        # so reading the manifest after uninstall is not a stable assertion.
        python3 -c "import json,sys; g=json.load(open(sys.argv[1])).get(\"groups\",[]); print(g[0][\"was_member\"] if g else \"none\")" "$2/manifest/install-manifest.json" > "$2/was-member-before.txt"
        remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/remove-rc.txt"
        exit 0
    '
    assert_eq "0" "$(cat "$s2/helper-rc.txt" 2> /dev/null || echo MISSING)" \
        "T5: pre-existing member install succeeds"
    assert_eq "0" "$(usermod_calls "$s2/usermod.log")" "T5: pre-existing member is not usermod'ed"
    assert_eq "True" "$(cat "$s2/was-member-before.txt" 2> /dev/null || echo MISSING)" \
        "T5: pre-existing member recorded as was_member=true"
    assert_eq "0" "$(usermod_calls "$s2/gpasswd.log")" "T5: uninstall keeps pre-existing membership"
}

# T6: a pre-existing first-wins record must NOT be removed by a later failed
# usermod. Also cover a corrupt manifest (fail closed before any side effect).
test_usermod_failure_with_existing_record_keeps_first_wins_record() {
    local sandbox="/tmp/rollback-test-grp-existing-record"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_fault_stubs "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"
    python3 - "$mp" << 'PY'
import json, sys
json.dump({"version": "2.0", "records": [], "services": [],
           "groups": [{"group": "plugdev", "user": "testuser",
                       "component": "keyboard", "was_member": False}]},
          open(sys.argv[1], "w"), indent=2)
PY
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_USERMOD_RC=1 STUB_USER_IN_PLUGDEV=0
        source "$1/lib/backup.sh"
        rc=0
        ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/helper-rc.txt"
        exit 0
    '
    local log
    log="$(cat "$sandbox/log.txt" 2> /dev/null || echo "")"
    assert_eq "1" "$(cat "$sandbox/helper-rc.txt" 2> /dev/null || echo MISSING)" \
        "T6: usermod failure propagates with an existing record"
    assert_eq "1" "$(group_count "$mp")" "T6: first-wins record not removed by rollback"
    assert_eq "False" "$(grp_was_member "$mp")" "T6: original was_member=false preserved"
    assert_eq "1" "$(usermod_calls "$sandbox/usermod.log")" "T6: usermod attempted once"
    assert_not_contains "Could not roll back" "$log" "T6: no rollback attempted for an existing record"
    assert_not_contains "Could not consume group record" "$log" "T6: no record consumption attempted"

    local s2="/tmp/rollback-test-grp-corrupt-record"
    rm -rf "$s2"
    mkdir -p "$s2/backups" "$s2/manifest"
    setup_group_fault_stubs "$s2"
    local mp2="$s2/manifest/install-manifest.json"
    printf 'this is not json' > "$mp2"
    local before
    before="$(file_hex "$mp2")"
    run_sandboxed "$s2" '
        export PATH="$2/stub:$PATH" STUB_USERMOD_LOG="$2/usermod.log" STUB_USER_IN_PLUGDEV=0
        source "$1/lib/backup.sh"
        rc=0
        ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/helper-rc.txt"
        exit 0
    '
    assert_eq "1" "$(cat "$s2/helper-rc.txt" 2> /dev/null || echo MISSING)" \
        "T6: corrupt manifest fails closed"
    assert_eq "0" "$(usermod_calls "$s2/usermod.log")" "T6: corrupt manifest blocks usermod"
    assert_eq "$before" "$(file_hex "$mp2")" "T6: corrupt manifest bytes unchanged"
}

# ---------------------------------------------------------------------------
# 13. keyboard backlight sync: install and rollback of daemon + udev + user service + sleep hook
# ---------------------------------------------------------------------------
test_kbd_backlight_sync_install() {
    local sandbox="/tmp/rollback-test-kbd-sync"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/stub"
    mkdir -p "$sandbox/etc/udev/rules.d" "$sandbox/etc/systemd/user" "$sandbox/usr/local/bin" "$sandbox/usr/lib/systemd/system-sleep"

    # Stub systemctl to handle --global and --user queries (user service: --global cat succeeds)
    printf '#!/usr/bin/env bash\ncase "$*" in\n  *"--global cat"*) exit 0 ;;\n  *" cat "*) exit 1 ;;\n  *"--global is-enabled"*|*"--global is-active"*) exit 1 ;;\n  *"is-enabled"*|*"is-active"*) exit 1 ;;\n  *) exit 0 ;;\nesac\n' > "$sandbox/stub/systemctl"
    # The rollback python runs under `sudo python3`; a sudo stub is required
    # so its PATH still resolves to this systemctl stub (real sudo resets PATH).
    printf '#!/usr/bin/env bash\n[ "${1:-}" = "-u" ] && shift 2\nexec "$@"\n' > "$sandbox/stub/sudo"
    chmod +x "$sandbox/stub/systemctl" "$sandbox/stub/sudo"
    # Also stub udevadm and systemd-hwdb for completeness
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sandbox/stub/udevadm"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sandbox/stub/systemd-hwdb"
    chmod +x "$sandbox/stub/udevadm" "$sandbox/stub/systemd-hwdb"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        # Simulate keyboard/install-keyboard.sh steps with sandbox paths
        # For new files, backup must be called BEFORE creating file (was_existing=0)
        backup_file_manifest_aware "$2/usr/local/bin/c640-kbd-backlight-sync" "keyboard"
        mkdir -p "$(dirname "$2/usr/local/bin/c640-kbd-backlight-sync")"
        echo "#!/bin/bash" > "$2/usr/local/bin/c640-kbd-backlight-sync"
        backup_file_manifest_aware "$2/etc/udev/rules.d/61-chromeos-kbd-backlight.rules" "keyboard"
        mkdir -p "$(dirname "$2/etc/udev/rules.d/61-chromeos-kbd-backlight.rules")"
        echo "SUBSYSTEM==\"leds\"" > "$2/etc/udev/rules.d/61-chromeos-kbd-backlight.rules"
        backup_file_manifest_aware "$2/etc/systemd/user/c640-kbd-backlight-sync.service" "keyboard"
        mkdir -p "$(dirname "$2/etc/systemd/user/c640-kbd-backlight-sync.service")"
        echo "[Unit]" > "$2/etc/systemd/user/c640-kbd-backlight-sync.service"
        manifest_add_service "c640-kbd-backlight-sync.service" "keyboard"
        backup_file_manifest_aware "$2/usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh" "keyboard"
        mkdir -p "$(dirname "$2/usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh")"
        echo "#!/bin/sh" > "$2/usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh"
    '

    # Verify manifest has 4 records
    local rec_count
    rec_count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("records", [])))' "$sandbox/manifest/install-manifest.json")"
    assert_eq "4" "$rec_count" "kbd sync install records 4 files"
    local svc_count
    svc_count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("services", [])))' "$sandbox/manifest/install-manifest.json")"
    assert_eq "1" "$svc_count" "kbd sync install records user service"

    # Verify service scope is user
    local scope
    scope="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("services", [])[0].get("scope",""))' "$sandbox/manifest/install-manifest.json")"
    assert_eq "user" "$scope" "kbd sync service scope is user"

    # Now rollback and ensure files removed
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        rollback_component "keyboard"
    '

    if [ ! -e "$sandbox/usr/local/bin/c640-kbd-backlight-sync" ] && [ ! -e "$sandbox/etc/udev/rules.d/61-chromeos-kbd-backlight.rules" ] && [ ! -e "$sandbox/etc/systemd/user/c640-kbd-backlight-sync.service" ] && [ ! -e "$sandbox/usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh" ]; then
        ok
    else
        fail "kbd sync rollback should remove all 4 files"
    fi

    local remaining
    remaining="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("records", [])))' "$sandbox/manifest/install-manifest.json")"
    assert_eq "0" "$remaining" "kbd sync records removed after rollback"
    local svc_remaining
    svc_remaining="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("services", [])))' "$sandbox/manifest/install-manifest.json")"
    assert_eq "0" "$svc_remaining" "kbd sync service record removed after rollback"
}

# ---------------------------------------------------------------------------
# 14. keyboard backlight sync: user service first-wins and double install keeps single backup
# ---------------------------------------------------------------------------
test_kbd_backlight_double_install() {
    local sandbox="/tmp/rollback-test-kbd-double"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/stub"
    mkdir -p "$sandbox/etc/systemd/user"
    printf '#!/usr/bin/env bash\ncase "$*" in\n  *"--global cat"*) exit 0 ;;\n  *" cat "*) exit 1 ;;\n  *"is-enabled"*|*"is-active"*) [ -e "${STUB_UNIT_STATE_FILE:-}" ] && exit 0 || exit 1 ;;\n  *) exit 0 ;;\nesac\n' > "$sandbox/stub/systemctl"
    # Keep PATH inside `sudo python3` so rollback's systemctl calls hit the
    # stub instead of the host's real systemd.
    printf '#!/usr/bin/env bash\n[ "${1:-}" = "-u" ] && shift 2\nexec "$@"\n' > "$sandbox/stub/sudo"
    chmod +x "$sandbox/stub/systemctl" "$sandbox/stub/sudo"
    # first install with file not existing
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        echo "ORIGINAL" > "$2/etc/systemd/user/c640-kbd-backlight-sync.service"
        backup_file_manifest_aware "$2/etc/systemd/user/c640-kbd-backlight-sync.service" "keyboard"
        manifest_add_service "c640-kbd-backlight-sync.service" "keyboard"
    '
    # modify file and reinstall (should keep original backup, first service record wins)
    echo "CUSTOM" > "$sandbox/etc/systemd/user/c640-kbd-backlight-sync.service"
    touch "$sandbox/unit-enabled"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_UNIT_STATE_FILE="$2/unit-enabled"
        source "$1/lib/backup.sh"
        backup_file_manifest_aware "$2/etc/systemd/user/c640-kbd-backlight-sync.service" "keyboard"
        manifest_add_service "c640-kbd-backlight-sync.service" "keyboard"
    '
    local svc_state
    svc_state="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])).get("services", [])[0]; print(s["was_enabled"], s.get("scope",""))' "$sandbox/manifest/install-manifest.json")"
    assert_eq "False user" "$svc_state" "kbd sync double install keeps first service record with user scope"
    local backup_count
    backup_count="$(find "$sandbox/backups" -name "c640-kbd-backlight-sync.service" 2> /dev/null | wc -l)"
    assert_eq "1" "$backup_count" "kbd sync double install keeps single backup"
    # rollback should restore original
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        rollback_component "keyboard"
    '
    assert_eq "ORIGINAL" "$(cat "$sandbox/etc/systemd/user/c640-kbd-backlight-sync.service" 2> /dev/null || echo "MISSING")" "kbd double install rollback restores original"
}

# ---------------------------------------------------------------------------
# 15-27. keyd step regression tests
#
# These tests build a sandbox copy of the installer with its CLI entry point
# removed and ALL install destinations (hwdb/udev/daemon/service/sleep/keyd)
# redirected into the sandbox, with PATH stubs for sudo/systemctl/udevadm/
# systemd-hwdb/getent and a get_real_user() override where needed. They exercise
# the real production helpers (is_our_legacy_keyd_link, install_keyd_step,
# install_keyboard/uninstall_keyboard and lib/backup.sh's backup/rollback), not
# a re-implementation. In particular the P1 regression calls the real
# uninstall_keyboard() so a restored post-rollback symlink deletion is caught
# behaviourally; the source-level check below is only an extra guard.
# ---------------------------------------------------------------------------

prepare_keyd_sandbox_script() {
    local sandbox="$1"
    sed \
        -e "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$REPO_ROOT/keyboard\"|" \
        -e "s|^ROOT_DIR=.*|ROOT_DIR=\"$REPO_ROOT\"|" \
        -e "s|^HWDB_DST=.*|HWDB_DST=\"$sandbox/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb\"|" \
        -e "s|^UDEV_DST=.*|UDEV_DST=\"$sandbox/etc/udev/rules.d/61-chromeos-kbd-backlight.rules\"|" \
        -e "s|^DAEMON_DST=.*|DAEMON_DST=\"$sandbox/usr/local/bin/c640-kbd-backlight-sync\"|" \
        -e "s|^SERVICE_DST=.*|SERVICE_DST=\"$sandbox/etc/systemd/user/c640-kbd-backlight-sync.service\"|" \
        -e "s|^SLEEP_DST=.*|SLEEP_DST=\"$sandbox/usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh\"|" \
        -e "s|^KEYD_SRC=.*|KEYD_SRC=\"$sandbox/keyd-src/cros.conf\"|" \
        -e "s|^KEYD_DST=.*|KEYD_DST=\"$sandbox/etc/keyd/cros.conf\"|" \
        -e "s|^KEYD_LINK=.*|KEYD_LINK=\"$sandbox/etc/keyd/default.conf\"|" \
        -e '/^# CLI Argument Parsing/,$d' \
        "$REPO_ROOT/keyboard/install-keyboard.sh" > "$sandbox/install-keyboard-sandbox.sh"
}

setup_keyd_stubs() {
    local sandbox="$1" mode="$2"
    mkdir -p "$sandbox/stub"

    # sudo just runs the command: every destination is inside the sandbox.
    printf '#!/usr/bin/env bash\n[ "${1:-}" = "-u" ] && shift 2\nexec "$@"\n' > "$sandbox/stub/sudo"

    # systemctl records every call and can fail the first (or every) restart
    # on demand.
    cat > "$sandbox/stub/systemctl" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_SYSTEMCTL_LOG:?}"
case "$*" in
    *"restart keyd"*)
        if [ "${STUB_RESTART_FAIL_ALWAYS:-0}" = "1" ]; then
            exit 1
        fi
        if [ "${STUB_RESTART_FAIL_FIRST:-0}" = "1" ] && [ ! -e "${STUB_RESTART_RETRY_FLAG:-}" ]; then
            : > "${STUB_RESTART_RETRY_FLAG:?}"
            exit 1
        fi
        ;;
    # uninstall_keyboard() queries with --quiet; match both spellings so the
    # ownership guard is actually exercised (default: keyd active/enabled).
    *"is-enabled keyd"*|*"is-enabled --quiet keyd"*) [ "${STUB_SVC_ENABLED:-1}" = "1" ] && exit 0 || exit 3 ;;
    *"is-active keyd"*|*"is-active --quiet keyd"*) [ "${STUB_SVC_ACTIVE:-1}" = "1" ] && exit 0 || exit 3 ;;
esac
# Opt-in fault injection for rollback state restoration. Checked AFTER the
# cases above so is-enabled/is-active/restart semantics stay unchanged.
if [ -n "${STUB_SYSTEMCTL_FAIL_CMD:-}" ] && [[ "$*" == *"$STUB_SYSTEMCTL_FAIL_CMD"* ]]; then
    printf 'stub: refusing %s\n' "$*" >&2
    exit "${STUB_SYSTEMCTL_FAIL_RC:-1}"
fi
exit 0
EOF

    # Needed by uninstall_keyboard() (systemd-hwdb / udevadm refresh). getent
    # reports an existing plugdev group so a full install never runs groupadd.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sandbox/stub/udevadm"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sandbox/stub/systemd-hwdb"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sandbox/stub/getent"

    case "$mode" in
        valid)
            cat > "$sandbox/stub/keyd" << 'EOF'
#!/usr/bin/env bash
case "$1" in
    --help) printf 'Usage: keyd [options]\n  check <file>  Check configuration\n' ;;
    --version) printf 'keyd 2.6.0\n' ;;
    check) if grep -q 'overload(' "$2"; then exit 1; fi; exit 0 ;;
    *) exit 0 ;;
esac
EOF
            ;;
        rvaiya)
            # keyd_bin() falls back to keyd.rvaiya when keyd is absent.
            cat > "$sandbox/stub/keyd.rvaiya" << 'EOF'
#!/usr/bin/env bash
case "$1" in
    --help) printf 'Usage: keyd [options]\n  check <file>  Check configuration\n' ;;
    --version) printf 'keyd 2.6.0\n' ;;
    check) if grep -q 'overload(' "$2"; then exit 1; fi; exit 0 ;;
    *) exit 0 ;;
esac
EOF
            ;;
        invalid)
            # Accept the good/bad probe configs from keyd_supports_check(), but
            # reject our INVALID_SRC file.
            cat > "$sandbox/stub/keyd" << 'EOF'
#!/usr/bin/env bash
case "$1" in
    --help) printf 'Usage: keyd [options]\n  check <file>  Check configuration\n' ;;
    --version) printf 'keyd 2.6.0\n' ;;
    check)
        if grep -q 'INVALID_SRC' "$2" || grep -q 'overload(' "$2"; then
            exit 1
        fi
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
            ;;
        legacy25)
            # Real 2.5.x behaviour: --help advertises check, but check only
            # prints usage and always returns 0.
            cat > "$sandbox/stub/keyd" << 'EOF'
#!/usr/bin/env bash
case "$1" in
    --help) printf 'Usage: keyd [options]\n  check <file>  Check configuration\n' ;;
    --version) printf 'keyd 2.5.0\n' ;;
    check) printf 'Usage: keyd [options]\n'; exit 0 ;;
    *) exit 0 ;;
esac
EOF
            ;;
        none)
            # No keyd stub on purpose: tests that need keyd_cmd="" also
            # override keyd_bin() because the host has /usr/bin/keyd.rvaiya.
            ;;
        *)
            # Unknown modes create no keyd binary, like "none".
            ;;
    esac
    chmod +x "$sandbox/stub/sudo" "$sandbox/stub/systemctl" \
        "$sandbox/stub/udevadm" "$sandbox/stub/systemd-hwdb" "$sandbox/stub/getent"
    [ ! -f "$sandbox/stub/keyd" ] || chmod +x "$sandbox/stub/keyd"
    [ ! -f "$sandbox/stub/keyd.rvaiya" ] || chmod +x "$sandbox/stub/keyd.rvaiya"
}

run_keyd_install_step() {
    local sandbox="$1"
    # Propagate the EXACT status (0/1/3): callers distinguish config-only (3)
    # from a real failure (1) or success (0). The sourced installer enables
    # `set -e`, so the step call itself must be guarded to persist its state.
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        step_rc=0
        install_keyd_step || step_rc=$?
        printf "%s\n" "$step_rc" > "$2/step-rc.txt"
        printf "%s\n" "${KEYD_STATE:-unset}" > "$2/step-state.txt"
        exit "$step_rc"
    '
}

# Call the REAL uninstall_keyboard() in the sandbox. get_real_user is stubbed
# to the empty string so user/group/systemd-per-user branches are skipped, and
# udevadm/systemd-hwdb/systemctl are PATH stubs. This is the behavioural guard
# for the "uninstall deletes the symlink rollback just restored" regression.
run_keyd_uninstall() {
    local sandbox="$1"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        uninstall_keyboard
    '
}

# Same as run_keyd_uninstall(), but with DRY_RUN=1 (no systemctl side effects).
run_keyd_uninstall_dryrun() {
    local sandbox="$1"
    run_sandboxed "$sandbox" '
        export DRY_RUN=1 PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        uninstall_keyboard
    '
}

# Fresh sandbox for uninstall-ownership tests: a user-owned cros.conf and an
# active/enabled keyd (stub default) with NO installer deployment performed.
setup_keyd_uninstall_sandbox() {
    local sandbox="$1"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'USER_OWN_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"
}

# Write a manifest with exact control over the services list. When
# with_record=1 a keyboard record for cros.conf (was_existing=true) is included
# so tests can prove that a file record alone does NOT grant service ownership.
write_keyd_manifest() {
    local sandbox="$1" services_json="$2" with_record="${3:-0}"
    python3 - "$sandbox/manifest/install-manifest.json" "$sandbox/etc/keyd/cros.conf" \
        "$services_json" "$with_record" << 'PY'
import json, sys
manifest, target, services, with_record = sys.argv[1:5]
data = {"version": "2.0", "records": [], "services": json.loads(services), "groups": []}
if with_record == "1":
    data["records"].append({"target": target, "component": "keyboard",
                            "was_existing": True, "installed_at": "2026-01-01 00:00:00"})
with open(manifest, "w") as f:
    json.dump(data, f, indent=2)
PY
}

# Drive the REAL install_keyboard() in the sandbox, persisting its rc and keyd
# state so the parent test can assert them precisely. Optional parameters:
# $2=WITH_KEYD (default 1), $3=KEYD_ALLOW_CONFIG_ONLY (default 0),
# $4=DRY_RUN (default 0), $5=force keyd_bin failure (default 0).
run_keyd_caller() {
    local sandbox="$1" with_keyd="${2:-1}" allow="${3:-0}" dry="${4:-0}" no_bin="${5:-0}"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            WITH_KEYD="$3" KEYD_ALLOW_CONFIG_ONLY="$4" DRY_RUN="$5"
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        if [ "$6" = "1" ]; then
            keyd_bin() { return 1; }
        fi
        install_rc=0
        install_keyboard || install_rc=$?
        printf "%s\n" "$install_rc" > "$2/install-rc.txt"
        printf "%s\n" "${KEYD_STATE:-unset}" > "$2/keyd-state.txt"
        printf "%s\n" "${KEYD_DEPLOYED:-unset}" > "$2/keyd-deployed.txt"
        exit "$install_rc"
    ' "$with_keyd" "$allow" "$dry" "$no_bin"
}

# Fresh caller sandbox with a valid cros.conf source and the requested stub mode.
setup_keyd_caller_sandbox() {
    local sandbox="$1" mode="$2"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" "$mode"
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"
}

assert_keyd_link_detection() {
    local sandbox="$1" target="$2" expected="$3"
    ln -sfn "$target" "$sandbox/etc/keyd/default.conf"
    local rc=0
    if run_sandboxed "$sandbox" '
        source "$2/install-keyboard-sandbox.sh"
        KEYD_LINK="$3"
        is_our_legacy_keyd_link
    ' "${sandbox}/etc/keyd/default.conf"; then
        rc=0
    else
        rc=$?
    fi
    assert_eq "$expected" "$rc" "legacy-link helper for target '$target'"
}

test_keyd_legacy_link_helper() {
    local sandbox="/tmp/rollback-test-keyd-helper"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd"
    prepare_keyd_sandbox_script "$sandbox"

    assert_keyd_link_detection "$sandbox" "cros.conf" 0
    assert_keyd_link_detection "$sandbox" "./cros.conf" 0
    assert_keyd_link_detection "$sandbox" "../keyd/cros.conf" 0
    assert_keyd_link_detection "$sandbox" "$sandbox/etc/keyd/cros.conf" 0
    assert_keyd_link_detection "$sandbox" "mylayout.conf" 1
    assert_keyd_link_detection "$sandbox" "../mylayout.conf" 1

    # A regular file is never "our" link.
    rm -f "$sandbox/etc/keyd/default.conf"
    echo "ORIGINAL" > "$sandbox/etc/keyd/default.conf"
    local rc=0
    if run_sandboxed "$sandbox" '
        source "$2/install-keyboard-sandbox.sh"
        is_our_legacy_keyd_link
    '; then
        rc=0
    else
        rc=$?
    fi
    assert_eq "1" "$rc" "regular default.conf is not our legacy link"
}

# $1 = absent | cros_link | other_link
test_keyd_link_backup_and_rollback() {
    local state="$1"
    local sandbox="/tmp/rollback-test-keyd-link-$state"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" legacy25
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"

    case "$state" in
        absent) ;;
        cros_link)
            printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
            ln -s cros.conf "$sandbox/etc/keyd/default.conf"
            ;;
        other_link)
            printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
            printf 'MYLAYOUT\n' > "$sandbox/etc/keyd/mylayout.conf"
            ln -s mylayout.conf "$sandbox/etc/keyd/default.conf"
            ;;
    esac

    if ! run_keyd_install_step "$sandbox"; then
        fail "keyd install step failed for state $state"
        return 0
    fi
    assert_eq "VALID_CROS_CONF" "$(cat "$sandbox/etc/keyd/cros.conf")" "[$state] cros.conf deployed"
    if grep -q 'enable keyd' "$sandbox/systemctl.log" && grep -q 'restart keyd' "$sandbox/systemctl.log"; then
        ok
    else
        fail "[$state] keyd service should be enabled and restarted on the rc=3 (no check) path"
    fi

    local expected_records=1
    case "$state" in
        cros_link)
            expected_records=2
            if [ -L "$sandbox/etc/keyd/default.conf" ]; then
                fail "[$state] installer must remove our legacy default.conf symlink"
            else
                ok
            fi
            ;;
        other_link)
            if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "mylayout.conf" ]; then
                ok
            else
                fail "[$state] installer must keep a foreign default.conf symlink"
            fi
            ;;
    esac
    local records
    records="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("records", [])))' "$sandbox/manifest/install-manifest.json")"
    assert_eq "$expected_records" "$records" "[$state] manifest records only backed-up targets"

    # P1 regression guard: call the REAL uninstall_keyboard() so a restored
    # post-rollback "clean up default.conf" deletion is caught behaviourally,
    # not only via the source-level grep in
    # test_uninstall_has_no_post_rollback_keyd_cleanup.
    run_keyd_uninstall "$sandbox"

    case "$state" in
        absent)
            if [ ! -e "$sandbox/etc/keyd/cros.conf" ] && [ ! -L "$sandbox/etc/keyd/default.conf" ]; then
                ok
            else
                fail "[$state] rollback should remove newly deployed cros.conf and leave no symlink"
            fi
            ;;
        cros_link)
            # The regression: uninstall must not delete the symlink rollback
            # just restored.
            assert_eq "ORIGINAL" "$(cat "$sandbox/etc/keyd/cros.conf")" "[$state] rollback restores original cros.conf"
            if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
                ok
            else
                fail "[$state] rollback must restore original default.conf -> cros.conf symlink"
            fi
            ;;
        other_link)
            assert_eq "ORIGINAL" "$(cat "$sandbox/etc/keyd/cros.conf")" "[$state] rollback restores original cros.conf"
            if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "mylayout.conf" ]; then
                ok
            else
                fail "[$state] rollback must leave foreign default.conf symlink intact"
            fi
            ;;
    esac
}

test_keyd_invalid_config_skips_deploy() {
    local sandbox="/tmp/rollback-test-keyd-invalid"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" invalid
    printf 'INVALID_SRC\n' > "$sandbox/keyd-src/cros.conf"
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"

    if run_keyd_install_step "$sandbox"; then
        fail "keyd install step should reject an invalid config"
    else
        ok
    fi

    assert_eq "ORIGINAL" "$(cat "$sandbox/etc/keyd/cros.conf")" "invalid config: existing cros.conf left untouched"
    if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "invalid config: existing default.conf symlink left untouched"
    fi
    if [ -f "$sandbox/manifest/install-manifest.json" ] && [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("records", [])))' "$sandbox/manifest/install-manifest.json")" != "0" ]; then
        fail "invalid config: no file should be backed up or recorded"
    else
        ok
    fi
    if grep -qE 'enable keyd|restart keyd' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "invalid config: systemctl enable/restart must not be called"
    else
        ok
    fi
}

# $1 = sandbox, $2 = yes | no : whether a previous cros.conf exists to restore
setup_keyd_restart_recoverable_sandbox() {
    local sandbox="$1" existing="$2"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    [ "$existing" = "yes" ] || rm -f "$sandbox/etc/keyd/cros.conf"
    # When a previous config existed, install also removed our legacy symlink;
    # recovery must restore it from the backup, not just cros.conf.
    if [ "$existing" = "yes" ]; then
        ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    fi
}

# $1 = yes | no : whether a previous cros.conf exists to be restored
test_keyd_restart_failure_recovery() {
    local existing="$1"
    local sandbox="/tmp/rollback-test-keyd-restart-$existing"
    local caller_sandbox="/tmp/rollback-test-keyd-restart-caller-$existing"
    setup_keyd_restart_recoverable_sandbox "$sandbox" "$existing"

    # P2: the first restart fails but the retry after recovery succeeds. The
    # dual-role config was reverted, so install_keyd_step MUST report failure
    # (return 1) instead of letting the caller claim dual-role is active.
    # `if` avoids aborting this `set -e` test script when the step returns 1.
    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_RESTART_FAIL_FIRST=1 STUB_RESTART_RETRY_FLAG="$2/retried"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "restart failure: install_keyd_step must return 1 after a safe revert (dual-role NOT active)"
    else
        ok
    fi

    local step_output
    step_output="$(cat "$sandbox/step.log")"
    if grep -qF "keyd dual-role included" "$sandbox/step.log"; then
        fail "restart failure: success line must not be printed after a safe revert"
    else
        ok
    fi
    assert_contains "keyd config reverted after restart failure" "$step_output" "restart failure: truthful revert notice printed"
    assert_contains "dual-role NOT active" "$step_output" "restart failure: dual-role NOT active notice printed"
    if grep -qF "could not be recovered" "$sandbox/step.log"; then
        fail "restart failure: must not claim the config was unrecoverable (the system was safely reverted)"
    else
        ok
    fi

    # Also drive the REAL caller: explicit --with-keyd + a safe revert is a
    # failure (rc 1). The non-keyd install still completes, but the caller must
    # set KEYD_DEPLOYED=0/state=failed and omit the "included" success line.
    setup_keyd_restart_recoverable_sandbox "$caller_sandbox" "$existing"
    if STUB_RESTART_FAIL_FIRST=1 STUB_RESTART_RETRY_FLAG="$caller_sandbox/retried" \
        run_keyd_caller "$caller_sandbox" 1 0 0 0 2> "$caller_sandbox/caller.log"; then
        fail "restart failure: caller must return 1 after a safe revert"
    else
        assert_eq "1" "$(cat "$caller_sandbox/install-rc.txt")" "restart failure: caller returns 1"
    fi
    assert_eq "failed" "$(cat "$caller_sandbox/keyd-state.txt")" "restart failure: caller state is failed"
    assert_eq "0" "$(cat "$caller_sandbox/keyd-deployed.txt")" "restart failure: caller sets KEYD_DEPLOYED=0"
    if grep -qF "keyd dual-role included" "$caller_sandbox/caller.log"; then
        fail "restart failure: caller must not report dual-role as deployed after a safe revert"
    else
        ok
    fi
    local caller_output
    caller_output="$(cat "$caller_sandbox/caller.log")"
    assert_contains "keyd config reverted after restart failure" "$caller_output" "restart failure: caller logs the safe revert"
    assert_contains "dual-role NOT active" "$caller_output" "restart failure: caller logs dual-role NOT active"

    local restarts
    restarts="$(grep -c 'restart keyd' "$sandbox/systemctl.log" 2> /dev/null || true)"
    restarts="${restarts:-0}"
    if [ "$restarts" -ge 2 ]; then
        ok
    else
        fail "restart failure: daemon should be restarted again after recovery (got $restarts calls)"
    fi
    if grep -q 'enable keyd' "$sandbox/systemctl.log"; then
        ok
    else
        fail "valid config (rc=0) path must enable keyd"
    fi
    if [ "$existing" = "yes" ]; then
        assert_eq "ORIGINAL" "$(cat "$sandbox/etc/keyd/cros.conf")" "restart failure: previous cros.conf restored"
        # P2.3c: recovery must also put back the legacy symlink from its backup.
        if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
            ok
        else
            fail "restart failure recovery: legacy default.conf symlink restored from backup"
        fi
    else
        if [ ! -e "$sandbox/etc/keyd/cros.conf" ]; then
            ok
        else
            fail "restart failure: newly deployed cros.conf should be removed when there was no previous config"
        fi
    fi
}

# P3.1: a backup that is itself a symlink (NixOS / symlink farms) must be
# restored as a symlink. install(1) would dereference it into a regular file.
test_keyd_restart_failure_restores_symlink_backup() {
    local sandbox="/tmp/rollback-test-keyd-symlink-backup"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/layout.conf"
    ln -s layout.conf "$sandbox/etc/keyd/cros.conf"

    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_RESTART_FAIL_FIRST=1 STUB_RESTART_RETRY_FLAG="$2/retried"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "symlink backup: install_keyd_step must report failure after a safe revert"
        return 0
    fi
    if [ -L "$sandbox/etc/keyd/cros.conf" ]; then
        assert_eq "layout.conf" "$(readlink "$sandbox/etc/keyd/cros.conf")" "symlink backup: cros.conf restored as a symlink with its original target"
    else
        fail "symlink backup: cros.conf must stay a symlink (backup must not be dereferenced)"
    fi
    assert_eq "ORIGINAL" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" "symlink backup: restored link resolves to the original content"
}

test_keyd_supports_check_probe() {
    local sandbox="/tmp/rollback-test-keyd-check-probe"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    prepare_keyd_sandbox_script "$sandbox"

    setup_keyd_stubs "$sandbox" valid
    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        keyd_supports_check "$2/stub/keyd"
    '; then
        ok
    else
        fail "keyd 2.6-style check should be detected as supported"
    fi

    setup_keyd_stubs "$sandbox" legacy25
    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        keyd_supports_check "$2/stub/keyd"
    '; then
        fail "keyd 2.5.x fake check (usage + rc=0) must not be detected as supported"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 20. dangling symlink (default.conf -> cros.conf, target missing) is still ours
# ---------------------------------------------------------------------------
test_keyd_dangling_symlink_is_ours() {
    local sandbox="/tmp/rollback-test-keyd-dangling"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd"
    prepare_keyd_sandbox_script "$sandbox"
    # cros.conf is deliberately absent: the symlink target does not exist, but
    # canonicalisation is lexical and the helper must still recognise it.
    assert_keyd_link_detection "$sandbox" "cros.conf" 0
}

# ---------------------------------------------------------------------------
# 21. keyd binary absent: deploy config only, no enable/restart, rollback drops it
# ---------------------------------------------------------------------------
test_keyd_no_binary_deploys_config_only() {
    local sandbox="/tmp/rollback-test-keyd-no-binary"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" none
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"

    # The host ships /usr/bin/keyd.rvaiya, so force keyd_bin() to report "no
    # binary" to deterministically exercise install_keyd_step's keyd_cmd=""
    # branch (only deploy cros.conf, do not enable/restart). rc=3 is a distinct
    # "config deployed, no service" outcome, not a generic failure.
    local step_rc=0
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        keyd_bin() { return 1; }
        install_rc=0
        install_keyd_step || install_rc=$?
        printf "%s\n" "$install_rc" > "$2/install-rc.txt"
        printf "%s\n" "${KEYD_STATE:-unset}" > "$2/keyd-state.txt"
        exit "$install_rc"
    ' || step_rc=$?
    assert_eq "3" "$step_rc" "no-keyd: install_keyd_step returns 3 (config-only)"
    assert_eq "config-only" "$(cat "$sandbox/keyd-state.txt")" "no-keyd: step state is config-only"
    assert_eq "VALID_CROS_CONF" "$(cat "$sandbox/etc/keyd/cros.conf")" "no-keyd: cros.conf deployed"
    assert_eq "0" "$(snapshot_entries "$sandbox")" "no-keyd: snapshot cleaned up on config-only exit"
    if grep -qE 'enable keyd|restart keyd' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "no-keyd: no enable/restart should be attempted"
    else
        ok
    fi
    local rec
    rec="$(python3 -c 'import json,sys; rs=json.load(open(sys.argv[1])).get("records",[]); r=[x for x in rs if x.get("target","").endswith("/cros.conf")]; print(len(r), r[0].get("was_existing") if r else "none")' "$sandbox/manifest/install-manifest.json")"
    assert_eq "1 False" "$rec" "no-keyd: new cros.conf recorded as not pre-existing"

    # Rollback removes the newly deployed cros.conf (was_existing=0 branch).
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        _prepare_keyd_link_for_rollback
        rollback_component "keyboard"
    '
    if [ ! -e "$sandbox/etc/keyd/cros.conf" ]; then
        ok
    else
        fail "no-keyd: rollback should remove the newly deployed cros.conf"
    fi
}

# ---------------------------------------------------------------------------
# 22. dry-run: no config deployed, no manifest record, no placeholder
# ---------------------------------------------------------------------------
test_keyd_dry_run_no_side_effects() {
    local sandbox="/tmp/rollback-test-keyd-dry-run"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"

    # (a) install_keyd_step DRY_RUN branch: backup/record/deploy are logged but
    # never executed, and systemctl is not called.
    if ! run_sandboxed "$sandbox" '
        export DRY_RUN=1 PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        step_rc=0
        install_keyd_step || step_rc=$?
        printf "%s\n" "$step_rc" > "$2/step-rc.txt"
        printf "%s\n" "${KEYD_STATE:-unset}" > "$2/step-state.txt"
        exit "$step_rc"
    ' 2> "$sandbox/step.log"; then
        fail "dry-run: install_keyd_step should succeed"
    fi
    assert_eq "0" "$(cat "$sandbox/step-rc.txt")" "dry-run: step returns 0"
    assert_eq "planned" "$(cat "$sandbox/step-state.txt")" "dry-run: step state is planned"
    if grep -qF "Would deploy keyd dual-role config" "$sandbox/step.log"; then
        ok
    else
        fail "dry-run: should announce what would be deployed"
    fi
    if grep -qF "keyd dual-role included" "$sandbox/step.log"; then
        fail "dry-run: must not claim keyd dual-role is deployed"
    else
        ok
    fi
    if [ ! -e "$sandbox/etc/keyd/cros.conf" ]; then
        ok
    else
        fail "dry-run: cros.conf must not be created"
    fi
    if [ -f "$sandbox/manifest/install-manifest.json" ]; then
        local recs
        recs="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("records",[])))' "$sandbox/manifest/install-manifest.json")"
        assert_eq "0" "$recs" "dry-run: no manifest record written"
    else
        ok
    fi
    if grep -qE 'enable keyd|restart keyd' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "dry-run: systemctl must not be called"
    else
        ok
    fi
    assert_eq "0" "$(snapshot_entries "$sandbox")" "dry-run: no snapshot directory created"
    assert_contains "Would create pre-deploy keyd snapshot" "$(cat "$sandbox/step.log" 2> /dev/null || echo "")" \
        "dry-run: snapshot creation is previewed"

    # (b) _prepare_keyd_link_for_rollback DRY_RUN early exit: with a restorable
    # record and backup present, still no placeholder is created.
    python3 - "$sandbox/manifest/install-manifest.json" "$sandbox/etc/keyd/default.conf" << 'EOF'
import json, sys
mp, target = sys.argv[1:3]
d = {"version":"2.0","records":[{"target":target,"component":"keyboard","was_existing":True}],"services":[],"groups":[]}
json.dump(d, open(mp, "w"), indent=2)
EOF
    mkdir -p "$sandbox/backups/20260101_000000000000000$sandbox/etc/keyd"
    ln -s cros.conf "$sandbox/backups/20260101_000000000000000$sandbox/etc/keyd/default.conf"
    run_sandboxed "$sandbox" '
        export DRY_RUN=1 PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        _prepare_keyd_link_for_rollback
    '
    if [ ! -e "$sandbox/etc/keyd/default.conf" ] && [ ! -L "$sandbox/etc/keyd/default.conf" ]; then
        ok
    else
        fail "dry-run: placeholder must not be created"
    fi
    # Sanity check that the same setup DOES create a placeholder when not
    # dry-running (so the assertion above is not vacuous).
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        _prepare_keyd_link_for_rollback
    '
    if [ -f "$sandbox/etc/keyd/default.conf" ] && [ ! -L "$sandbox/etc/keyd/default.conf" ]; then
        ok
    else
        fail "non-dry-run: placeholder should be created for a restorable record"
    fi

    # (c) the full installer in DRY_RUN must not set KEYD_DEPLOYED=1 or print
    # the "keyd dual-role included" success line, even though the dry-run keyd
    # step itself succeeds.
    local caller_sandbox="/tmp/rollback-test-keyd-dry-run-caller"
    rm -rf "$caller_sandbox"
    mkdir -p "$caller_sandbox/backups" "$caller_sandbox/manifest" "$caller_sandbox/etc/keyd" "$caller_sandbox/keyd-src"
    prepare_keyd_sandbox_script "$caller_sandbox"
    setup_keyd_stubs "$caller_sandbox" valid
    printf 'VALID_CROS_CONF\n' > "$caller_sandbox/keyd-src/cros.conf"
    if ! run_keyd_caller "$caller_sandbox" 1 0 1 0 2> "$caller_sandbox/caller.log"; then
        fail "dry-run: install_keyboard should finish"
    fi
    assert_eq "0" "$(cat "$caller_sandbox/install-rc.txt")" "dry-run: caller returns 0"
    assert_eq "planned" "$(cat "$caller_sandbox/keyd-state.txt")" "dry-run: caller state is planned"
    assert_eq "0" "$(cat "$caller_sandbox/keyd-deployed.txt")" "dry-run: caller keeps KEYD_DEPLOYED=0"
    if grep -qF "keyd dual-role included" "$caller_sandbox/caller.log"; then
        fail "dry-run: caller must not report dual-role as deployed"
    else
        ok
    fi
    if grep -qF "Would deploy keyd dual-role config" "$caller_sandbox/caller.log"; then
        ok
    else
        fail "dry-run: caller should preview keyd dual-role deployment"
    fi
}

# ---------------------------------------------------------------------------
# 22a-22g. explicit --with-keyd must not exit 0 unless dual-role took effect.
# The six KEYD_STATE values are exercised through the REAL install_keyboard().
# ---------------------------------------------------------------------------

test_with_keyd_verified_returns_zero() {
    local sandbox="/tmp/rollback-test-keyd-explicit-verified"
    setup_keyd_caller_sandbox "$sandbox" valid
    if ! run_keyd_caller "$sandbox" 1 0 0 0 2> "$sandbox/caller.log"; then
        fail "verified: install_keyboard must return 0"
        return 0
    fi
    assert_eq "0" "$(cat "$sandbox/install-rc.txt")" "verified: rc 0"
    assert_eq "verified" "$(cat "$sandbox/keyd-state.txt")" "verified: state=verified"
    assert_eq "1" "$(cat "$sandbox/keyd-deployed.txt")" "verified: deployed=1"
    assert_contains "keyd dual-role included (verified)" "$(cat "$sandbox/caller.log")" \
        "verified: success line names the verified state"
}

test_with_keyd_active_unverified_returns_zero() {
    local sandbox="/tmp/rollback-test-keyd-explicit-active"
    setup_keyd_caller_sandbox "$sandbox" legacy25
    if ! run_keyd_caller "$sandbox" 1 0 0 0 2> "$sandbox/caller.log"; then
        fail "active: keyd < 2.6 without check must still succeed"
        return 0
    fi
    assert_eq "0" "$(cat "$sandbox/install-rc.txt")" "active: rc 0"
    assert_eq "active" "$(cat "$sandbox/keyd-state.txt")" "active: state=active"
    assert_eq "1" "$(cat "$sandbox/keyd-deployed.txt")" "active: deployed=1"
    assert_contains "keyd dual-role active (check unavailable)" "$(cat "$sandbox/caller.log")" \
        "active: log says check is unavailable"
    if grep -qF "keyd dual-role included" "$sandbox/caller.log"; then
        fail "active: must not claim a verified 'included' deployment"
    else
        ok
    fi
}

test_with_keyd_config_only_returns_nonzero() {
    local sandbox="/tmp/rollback-test-keyd-explicit-config-only"
    setup_keyd_caller_sandbox "$sandbox" none
    if run_keyd_caller "$sandbox" 1 0 0 1 2> "$sandbox/caller.log"; then
        fail "config-only: strict --with-keyd must not return 0"
        return 0
    fi
    assert_eq "3" "$(cat "$sandbox/install-rc.txt")" "config-only: rc 3"
    assert_eq "config-only" "$(cat "$sandbox/keyd-state.txt")" "config-only: state=config-only"
    assert_eq "0" "$(cat "$sandbox/keyd-deployed.txt")" "config-only: deployed=0"
    assert_eq "VALID_CROS_CONF" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "config-only: config was still deployed"
    local caller_log
    caller_log="$(cat "$sandbox/caller.log")"
    assert_contains "no keyd service is active" "$caller_log" "config-only: warning names the missing service"
    if grep -qF "keyd dual-role included" "$sandbox/caller.log"; then
        fail "config-only: must NOT print 'dual-role included'"
    else
        ok
    fi
    if grep -qE 'enable keyd|restart keyd' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "config-only: no enable/restart should be attempted"
    else
        ok
    fi
}

test_with_keyd_config_only_optin() {
    local sandbox="/tmp/rollback-test-keyd-config-only-optin"
    setup_keyd_caller_sandbox "$sandbox" none
    if ! run_keyd_caller "$sandbox" 1 1 0 1 2> "$sandbox/caller.log"; then
        fail "config-only opt-in: --keyd-config-only must return 0"
        return 0
    fi
    assert_eq "0" "$(cat "$sandbox/install-rc.txt")" "config-only opt-in: rc 0"
    assert_eq "config-only" "$(cat "$sandbox/keyd-state.txt")" "config-only opt-in: state stays config-only"
    assert_eq "0" "$(cat "$sandbox/keyd-deployed.txt")" "config-only opt-in: deployed stays 0"
    local caller_log
    caller_log="$(cat "$sandbox/caller.log")"
    assert_contains "no keyd service is active" "$caller_log" "config-only opt-in: log still marks config-only"
    if grep -qF "keyd dual-role included" "$sandbox/caller.log"; then
        fail "config-only opt-in: must NOT print 'dual-role included'"
    else
        ok
    fi
}

test_with_keyd_source_missing_returns_failure() {
    local sandbox="/tmp/rollback-test-keyd-explicit-missing-src"
    setup_keyd_caller_sandbox "$sandbox" valid
    rm -f "$sandbox/keyd-src/cros.conf"
    if run_keyd_caller "$sandbox" 1 0 0 0 2> "$sandbox/caller.log"; then
        fail "source missing: install_keyboard must return 1"
        return 0
    fi
    assert_eq "1" "$(cat "$sandbox/install-rc.txt")" "source missing: rc 1"
    assert_eq "failed" "$(cat "$sandbox/keyd-state.txt")" "source missing: state=failed"
    assert_eq "0" "$(cat "$sandbox/keyd-deployed.txt")" "source missing: deployed=0"
    assert_contains "keyd source not found" "$(cat "$sandbox/caller.log")" "source missing: warning logged"
    if grep -qF "keyd dual-role included" "$sandbox/caller.log"; then
        fail "source missing: must NOT print 'dual-role included'"
    else
        ok
    fi
}

test_without_with_keyd_stays_zero() {
    local sandbox="/tmp/rollback-test-keyd-not-requested"
    setup_keyd_caller_sandbox "$sandbox" none
    # keyd_bin is forced to fail on purpose: without --with-keyd none of it matters.
    if ! run_keyd_caller "$sandbox" 0 0 0 1 2> "$sandbox/caller.log"; then
        fail "not requested: install_keyboard must return 0"
        return 0
    fi
    assert_eq "0" "$(cat "$sandbox/install-rc.txt")" "not requested: rc 0"
    assert_eq "not-requested" "$(cat "$sandbox/keyd-state.txt")" "not requested: state=not-requested"
    assert_eq "0" "$(cat "$sandbox/keyd-deployed.txt")" "not requested: deployed=0"
    if grep -qE 'keyd dual-role|no keyd service is active|keyd step did not complete' "$sandbox/caller.log"; then
        fail "not requested: no keyd success/failure line should be printed"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 23. missing backup: _prepare_keyd_link_for_rollback leaves no placeholder
# ---------------------------------------------------------------------------
test_keyd_prepare_link_without_backup() {
    local sandbox="/tmp/rollback-test-keyd-no-backup"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" legacy25
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"

    run_keyd_install_step "$sandbox" || {
        fail "no-backup: install step failed"
        return 0
    }
    # Install backed up and removed the symlink; simulate a lost backup.
    rm -rf "$sandbox/backups"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        _prepare_keyd_link_for_rollback
    '
    if [ ! -e "$sandbox/etc/keyd/default.conf" ] && [ ! -L "$sandbox/etc/keyd/default.conf" ]; then
        ok
    else
        fail "no-backup: placeholder must not be created when backup is missing"
    fi
    assert_contains "No backup found for" "$(cat "$sandbox/log.txt")" "no-backup: helper should log a warning"
    assert_contains "leaving no placeholder" "$(cat "$sandbox/log.txt")" "no-backup: warning mentions no placeholder"
}

# ---------------------------------------------------------------------------
# 24. unrecoverable restart: step returns 1, caller sets KEYD_DEPLOYED=0 and
#     never prints the keyd success line
# ---------------------------------------------------------------------------
setup_keyd_restart_fatal_sandbox() {
    local sandbox="$1"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
}

test_keyd_restart_unrecoverable_returns_failure() {
    local step_sandbox="/tmp/rollback-test-keyd-fatal-step"
    local caller_sandbox="/tmp/rollback-test-keyd-fatal-caller"
    setup_keyd_restart_fatal_sandbox "$step_sandbox"
    setup_keyd_restart_fatal_sandbox "$caller_sandbox"

    # (a) install_keyd_step itself returns 1 when the retry also fails.
    if run_sandboxed "$step_sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" STUB_RESTART_FAIL_ALWAYS=1
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$step_sandbox/step.log"; then
        fail "unrecoverable restart: install_keyd_step must return 1"
    else
        ok
    fi
    assert_contains "keyd restart could not be recovered" "$(cat "$step_sandbox/step.log")" "unrecoverable restart: fatal error logged"

    # (b) The real caller (install_keyboard) returns 1 for an explicit
    # --with-keyd that could not be activated. It sets KEYD_DEPLOYED=0/state=failed
    # and does not print the "keyd dual-role included" success line, but still
    # completes the non-keyd install steps.
    if STUB_RESTART_FAIL_ALWAYS=1 \
        run_keyd_caller "$caller_sandbox" 1 0 0 0 2> "$caller_sandbox/caller.log"; then
        fail "unrecoverable restart: caller must return 1"
    else
        assert_eq "1" "$(cat "$caller_sandbox/install-rc.txt")" "unrecoverable restart: caller returns 1"
    fi
    assert_eq "failed" "$(cat "$caller_sandbox/keyd-state.txt")" "unrecoverable restart: caller state is failed"
    assert_eq "0" "$(cat "$caller_sandbox/keyd-deployed.txt")" "unrecoverable restart: caller sets KEYD_DEPLOYED=0"
    assert_contains "keyd dual-role NOT deployed" "$(cat "$caller_sandbox/caller.log")" "unrecoverable restart: caller logs non-deployment"
    if grep -qF "keyd dual-role included" "$caller_sandbox/caller.log"; then
        fail "unrecoverable restart: keyd success line must not be printed"
    else
        ok
    fi
    # Recovery still restored the pre-install state.
    assert_eq "ORIGINAL" "$(cat "$caller_sandbox/etc/keyd/cros.conf")" "unrecoverable restart: previous cros.conf restored"
    if [ -L "$caller_sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$caller_sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "unrecoverable restart: legacy symlink restored during recovery"
    fi
    # P2: recovery failed, so the V1 snapshot must be retained with a marker.
    local retained
    retained="$(snapshot_dir "$caller_sandbox")"
    if [ -n "$retained" ] && sudo test -d "$retained"; then
        ok
    else
        fail "unrecoverable restart: snapshot retained after failed recovery"
    fi
    if [ -n "$retained" ] && sudo test -f "$retained/.failed"; then
        ok
    else
        fail "unrecoverable restart: retained snapshot carries a .failed marker"
    fi
    assert_contains "RETAINED at $retained" "$(cat "$caller_sandbox/log.txt" 2> /dev/null || echo "")" \
        "unrecoverable restart: log names the retained snapshot"
}

# ---------------------------------------------------------------------------
# 25. a manifest record with was_existing=false is removed by rollback
# ---------------------------------------------------------------------------
test_keyd_was_existing_false_removes_new_link() {
    local sandbox="/tmp/rollback-test-keyd-new-link"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd"
    prepare_keyd_sandbox_script "$sandbox"
    # A default.conf WE created plus a was_existing=false record: rollback must
    # take the "not pre-existing" branch and delete it; the prepare helper must
    # not create a placeholder for it.
    printf 'CREATED-BY-US\n' > "$sandbox/etc/keyd/default.conf"
    python3 - "$sandbox/manifest/install-manifest.json" "$sandbox/etc/keyd/default.conf" << 'EOF'
import json, sys
mp, target = sys.argv[1:3]
d = {"version":"2.0","records":[{"target":target,"component":"keyboard","was_existing":False}],"services":[],"groups":[]}
json.dump(d, open(mp, "w"), indent=2)
EOF
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        _prepare_keyd_link_for_rollback
        rollback_component "keyboard"
    '
    if [ ! -e "$sandbox/etc/keyd/default.conf" ] && [ ! -L "$sandbox/etc/keyd/default.conf" ]; then
        ok
    else
        fail "was_existing=false: default.conf created by us must be removed on rollback"
    fi
}

# ---------------------------------------------------------------------------
# 26. legacy 1.0 manifest with a KEYD_LINK record but no component field
# ---------------------------------------------------------------------------
test_keyd_legacy_manifest_without_component() {
    # (a) Unit-level guard: the rollback helpers alone do not claim an
    # un-normalized record, so a symlink that was never removed stays intact.
    # Normalization is deliberately an install-time step (see (b)/(c)).
    local sandbox="/tmp/rollback-test-keyd-legacy-upgrade"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd"
    prepare_keyd_sandbox_script "$sandbox"
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    python3 - "$sandbox/manifest/install-manifest.json" "$sandbox/etc/keyd/default.conf" << 'EOF'
import json, sys
mp, target = sys.argv[1:3]
d = {"version":"1.0","records":[{"target":target,"was_existing":True}]}
json.dump(d, open(mp, "w"), indent=2)
EOF
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        _prepare_keyd_link_for_rollback
        rollback_component "keyboard"
    '
    if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "legacy 1.0 record without component: untouched symlink must remain intact"
    fi
    if [ -f "$sandbox/etc/keyd/default.conf" ] && [ ! -L "$sandbox/etc/keyd/default.conf" ]; then
        fail "legacy 1.0 record without component: no placeholder should be created without a backup"
    else
        ok
    fi

    # (b) Full upgrade: simulate an old (1.0) install that left the
    # default.conf -> cros.conf symlink in place, with a legacy backup and a
    # manifest whose KEYD_LINK record has no "component" field. Then run the
    # real new installer and uninstall. The installer must backfill the
    # component so uninstall/rollback restore BOTH the symlink and the
    # original cros.conf.
    local up="/tmp/rollback-test-keyd-legacy-upgrade-full"
    rm -rf "$up"
    mkdir -p "$up/backups" "$up/manifest" "$up/etc/keyd" "$up/keyd-src"
    prepare_keyd_sandbox_script "$up"
    setup_keyd_stubs "$up" valid
    printf 'VALID_CROS_CONF\n' > "$up/keyd-src/cros.conf"
    printf 'ORIGINAL\n' > "$up/etc/keyd/cros.conf"
    ln -s cros.conf "$up/etc/keyd/default.conf"
    # Legacy backups: the old install backed up both original files. The
    # timestamp directory mirrors lib/backup.sh's
    # "$BACKUP_BASE_DIR/$timestamp$target" layout.
    local legacy_ts="20250101_000000000000"
    mkdir -p "$up/backups/$legacy_ts$up/etc/keyd"
    cp -a "$up/etc/keyd/cros.conf" "$up/backups/$legacy_ts$up/etc/keyd/cros.conf"
    cp -a "$up/etc/keyd/default.conf" "$up/backups/$legacy_ts$up/etc/keyd/default.conf"
    # Only the KEYD_LINK record lacks "component"; the cros.conf record is
    # already keyboard-scoped (first-wins keeps both records on re-install).
    python3 - "$up/manifest/install-manifest.json" "$up/etc/keyd/cros.conf" "$up/etc/keyd/default.conf" << 'EOF'
import json, sys
mp, cros, link = sys.argv[1:4]
json.dump({
    "version": "1.0",
    "records": [
        {"target": cros, "component": "keyboard", "was_existing": True},
        {"target": link, "was_existing": True},
    ],
}, open(mp, "w"), indent=2)
EOF

    run_keyd_install_step "$up" || {
        fail "legacy upgrade: install step failed"
        return 0
    }
    if [ -L "$up/etc/keyd/default.conf" ]; then
        fail "legacy upgrade: installer must remove the redundant legacy symlink"
    else
        ok
    fi
    # Normalization keeps first-wins: record count, version, was_existing and
    # the pre-existing cros.conf record must be unchanged; only the missing
    # component is added.
    local normalized
    normalized="$(
        python3 - "$up/manifest/install-manifest.json" << 'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
link = [r for r in d["records"] if r.get("target", "").endswith("/keyd/default.conf")]
print(len(d["records"]), d.get("version"),
      link[0].get("component") if link else "no-record",
      link[0].get("was_existing") if link else "no-record")
EOF
    )"
    assert_eq "2 1.0 keyboard True" "$normalized" "legacy upgrade: component backfilled, first-wins fields preserved"

    run_keyd_uninstall "$up"
    assert_eq "ORIGINAL" "$(cat "$up/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "legacy upgrade: original cros.conf restored on uninstall"
    if [ -L "$up/etc/keyd/default.conf" ] && [ "$(readlink "$up/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "legacy upgrade: uninstall/rollback must restore default.conf -> cros.conf symlink"
    fi
    if [ -e "$up/etc/keyd/default.conf" ] && [ ! -L "$up/etc/keyd/default.conf" ]; then
        fail "legacy upgrade: rollback must replace the placeholder with the original symlink"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 26a. P3 upgrade gap: legacy 1.0 KEYD_LINK record without component, backup
#      present, but the default.conf symlink already removed by an EARLIER
#      install. install_keyd_step() only normalizes while the link is present,
#      so uninstall_keyboard() must normalize on its own before preparing the
#      placeholder and rolling back.
# ---------------------------------------------------------------------------
test_keyd_legacy_upgrade_link_already_removed() {
    local sandbox="/tmp/rollback-test-keyd-legacy-upgrade-link-removed"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"

    # Post-(old-)install state: original cros.conf is present, but the legacy
    # default.conf -> cros.conf symlink was already removed. Its original is
    # still available in an older backup directory.
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    if [ -e "$sandbox/etc/keyd/default.conf" ] || [ -L "$sandbox/etc/keyd/default.conf" ]; then
        fail "legacy link-removed: test setup requires default.conf to be absent"
        return 0
    fi
    local legacy_ts="20250101_000000000000"
    mkdir -p "$sandbox/backups/$legacy_ts$sandbox/etc/keyd"
    cp -a "$sandbox/etc/keyd/cros.conf" "$sandbox/backups/$legacy_ts$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/backups/$legacy_ts$sandbox/etc/keyd/default.conf"

    # Only the KEYD_LINK record lacks "component"; first-wins keeps both
    # records when the new installer records cros.conf again.
    python3 - "$sandbox/manifest/install-manifest.json" "$sandbox/etc/keyd/cros.conf" "$sandbox/etc/keyd/default.conf" << 'EOF'
import json, sys
mp, cros, link = sys.argv[1:4]
json.dump({
    "version": "1.0",
    "records": [
        {"target": cros, "component": "keyboard", "was_existing": True},
        {"target": link, "was_existing": True},
    ],
}, open(mp, "w"), indent=2)
EOF

    # Re-install with the new version: the symlink is absent, so the
    # link-present-only normalization in install_keyd_step() cannot run.
    run_keyd_install_step "$sandbox" || {
        fail "legacy link-removed: install step failed"
        return 0
    }

    # The new unconditional normalization in uninstall_keyboard() runs even in
    # DRY_RUN, but must only log: no manifest write and no placeholder.
    cp "$sandbox/manifest/install-manifest.json" "$sandbox/manifest/before-dryrun.json"
    : > "$sandbox/log.txt"
    run_sandboxed "$sandbox" '
        export DRY_RUN=1 PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        uninstall_keyboard
    '
    if cmp -s "$sandbox/manifest/before-dryrun.json" "$sandbox/manifest/install-manifest.json"; then
        ok
    else
        fail "legacy link-removed: DRY_RUN uninstall must not write the manifest"
    fi
    if [ ! -e "$sandbox/etc/keyd/default.conf" ] && [ ! -L "$sandbox/etc/keyd/default.conf" ]; then
        ok
    else
        fail "legacy link-removed: DRY_RUN uninstall must not create a placeholder"
    fi
    assert_contains "Would backfill component=keyboard" "$(cat "$sandbox/log.txt")" \
        "legacy link-removed: DRY_RUN uninstall logs the normalization"

    local before
    before="$(
        python3 - "$sandbox/manifest/install-manifest.json" "$sandbox/etc/keyd/default.conf" << 'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
link = [r for r in d["records"] if r.get("target") == sys.argv[2]]
print(len(link), link[0].get("component") if link else "no-record")
EOF
    )"
    assert_eq "1 None" "$before" "legacy link-removed: install leaves the un-normalized KEYD_LINK record"

    # The real uninstall must normalize first, then prepare a placeholder and
    # roll it back into the original symlink, cleaning up the record.
    run_keyd_uninstall "$sandbox"

    if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "legacy link-removed: uninstall/rollback must restore default.conf -> cros.conf from backup"
    fi
    if [ -e "$sandbox/etc/keyd/default.conf" ] && [ ! -L "$sandbox/etc/keyd/default.conf" ]; then
        fail "legacy link-removed: no placeholder may be left behind"
    else
        ok
    fi
    local after
    after="$(
        python3 - "$sandbox/manifest/install-manifest.json" "$sandbox/etc/keyd/default.conf" << 'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
link = [r for r in d["records"] if r.get("target") == sys.argv[2]]
print(len(link))
EOF
    )"
    assert_eq "0" "$after" "legacy link-removed: KEYD_LINK record must be cleaned up after rollback"
    assert_eq "ORIGINAL" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "legacy link-removed: original cros.conf restored on uninstall"
}

# ---------------------------------------------------------------------------
# 26b. normalization helper: selective backfill, DRY_RUN and failure handling
# ---------------------------------------------------------------------------
test_keyd_legacy_component_normalization() {
    local sandbox="/tmp/rollback-test-keyd-normalize"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/failbin"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" none
    local link="$sandbox/etc/keyd/default.conf"
    local other="$sandbox/etc/keyd/other.conf"

    python3 - "$sandbox/manifest/install-manifest.json" "$link" "$other" << 'EOF'
import json, sys
mp, link, other = sys.argv[1:4]
json.dump({"version": "1.0", "records": [
    {"target": link, "was_existing": True, "installed_at": "old"},
    {"target": link, "component": "other", "was_existing": True},
    {"target": other, "was_existing": False},
]}, open(mp, "w"), indent=2)
EOF

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        _normalize_keyd_link_manifest_component
    '
    local result
    result="$(
        python3 - "$sandbox/manifest/install-manifest.json" << 'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
rs = d["records"]
print(d["version"], len(rs), rs[0].get("component"), rs[0].get("was_existing"),
      rs[0].get("installed_at"), rs[1].get("component"), rs[2].get("component"))
EOF
    )"
    assert_eq "1.0 3 keyboard True old other None" "$result" \
        "normalization: only missing component on KEYD_LINK is backfilled"

    # DRY_RUN: no manifest write, only a log_dryrun line.
    cp "$sandbox/manifest/install-manifest.json" "$sandbox/manifest/before.json"
    : > "$sandbox/log.txt"
    run_sandboxed "$sandbox" '
        export DRY_RUN=1 PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        _normalize_keyd_link_manifest_component
    '
    if cmp -s "$sandbox/manifest/before.json" "$sandbox/manifest/install-manifest.json"; then
        ok
    else
        fail "normalization dry-run must not write the manifest"
    fi
    assert_contains "Would backfill component=keyboard" "$(cat "$sandbox/log.txt")" \
        "normalization dry-run logs the intended change"

    # Failure path: a failing python3 must only log a warning, never abort.
    printf '#!/usr/bin/env bash\nexit 1\n' > "$sandbox/failbin/python3"
    chmod +x "$sandbox/failbin/python3"
    : > "$sandbox/log.txt"
    if run_sandboxed "$sandbox" '
        export PATH="$2/failbin:$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        _normalize_keyd_link_manifest_component
    '; then
        ok
    else
        fail "normalization: failing python3 must not abort the installer"
    fi
    assert_contains "Failed to backfill component" "$(cat "$sandbox/log.txt")" \
        "normalization: failing python3 logs a warning"
}

# ---------------------------------------------------------------------------
# 27. keyd_bin() falls back to keyd.rvaiya when keyd is not installed
# ---------------------------------------------------------------------------
test_keyd_rvaiya_fallback() {
    local sandbox="/tmp/rollback-test-keyd-rvaiya"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" rvaiya
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"

    local resolved
    resolved="$(run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        keyd_bin
    ')"
    assert_eq "$sandbox/stub/keyd.rvaiya" "$resolved" "keyd_bin falls back to keyd.rvaiya"

    if ! run_keyd_install_step "$sandbox"; then
        fail "rvaiya fallback: install step should succeed"
        return 0
    fi
    assert_eq "VALID_CROS_CONF" "$(cat "$sandbox/etc/keyd/cros.conf")" "rvaiya fallback: cros.conf deployed"
    if grep -q 'enable keyd' "$sandbox/systemctl.log" && grep -q 'restart keyd' "$sandbox/systemctl.log"; then
        ok
    else
        fail "rvaiya fallback: keyd service enabled and restarted"
    fi
}

# ---------------------------------------------------------------------------
# 28-33. per-deploy keyd snapshot: a failed UPGRADE must restore V1, while the
#        first-wins manifest/backups keep serving uninstall.
# ---------------------------------------------------------------------------

# Number of files/dirs left under the sandbox's snapshot base (0 when clean).
snapshot_entries() {
    local sandbox="$1"
    [ -d "$sandbox/snapshots" ] || {
        echo 0
        return 0
    }
    sudo find "$sandbox/snapshots" -mindepth 1 2> /dev/null | wc -l | tr -d '[:space:]'
}

# First snapshot directory under the sandbox base (empty when none). The base
# is root-owned 0700, so all inspection must be privileged.
snapshot_dir() {
    local sandbox="$1"
    [ -d "$sandbox/snapshots" ] || {
        echo ""
        return 0
    }
    sudo find "$sandbox/snapshots" -mindepth 1 -maxdepth 1 -type d 2> /dev/null | head -n 1
}

# Deploy V1 successfully, then stage a different V2 source for the next step.
# $2 = absent | original (whether a pre-V1 cros.conf existed).
setup_keyd_upgrade_sandbox() {
    local sandbox="$1" initial="${2:-absent}"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"
    [ "$initial" != "original" ] || printf 'ORIGINAL_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"

    if ! run_keyd_install_step "$sandbox"; then
        fail "upgrade setup: V1 install step failed"
        return 1
    fi
    printf 'V2_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
}

# Run a V2 deploy whose first restart fails (recovery's retry succeeds).
run_keyd_failing_upgrade() {
    local sandbox="$1"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_RESTART_FAIL_FIRST=1 STUB_RESTART_RETRY_FLAG="$2/retried"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step.log"
}

# Scenario A: no initial conf -> V1 -> V2 restart failure. V1 must survive,
# the snapshot must be cleaned, and uninstall must still remove cros.conf.
test_keyd_upgrade_failure_preserves_v1() {
    local sandbox="/tmp/rollback-test-keyd-upgrade-v1"
    setup_keyd_upgrade_sandbox "$sandbox" absent || return 0

    if run_keyd_failing_upgrade "$sandbox"; then
        fail "upgrade failure: install_keyd_step must return 1 after a safe revert"
        return 0
    fi
    assert_eq "VALID_CROS_CONF" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "upgrade failure: V1 config preserved (not deleted)"
    assert_eq "0" "$(snapshot_entries "$sandbox")" "upgrade failure: snapshot cleaned up"
    local was_existing
    was_existing="$(python3 -c 'import json,sys; rs=json.load(open(sys.argv[1]))["records"]; r=[x for x in rs if x["target"].endswith("/keyd/cros.conf")]; print(r[0]["was_existing"] if r else "none")' "$sandbox/manifest/install-manifest.json")"
    assert_eq "False" "$was_existing" "upgrade failure: manifest keeps first-wins was_existing=false"
    local backup_count
    backup_count="$(find "$sandbox/backups" -name cros.conf 2> /dev/null | wc -l | tr -d '[:space:]')"
    assert_eq "0" "$backup_count" "upgrade failure: no cros.conf backup was created"

    run_keyd_uninstall "$sandbox"
    if [ ! -e "$sandbox/etc/keyd/cros.conf" ] && [ ! -L "$sandbox/etc/keyd/cros.conf" ]; then
        ok
    else
        fail "upgrade failure: uninstall must remove the newly deployed cros.conf"
    fi
}

# Scenario B: initial ORIGINAL -> V1 -> V2 failure. Recovery must restore V1
# (not ORIGINAL), while uninstall must still restore ORIGINAL from backup.
test_keyd_upgrade_failure_preserves_v1_with_original() {
    local sandbox="/tmp/rollback-test-keyd-upgrade-original"
    setup_keyd_upgrade_sandbox "$sandbox" original || return 0

    if run_keyd_failing_upgrade "$sandbox"; then
        fail "upgrade failure (original): install_keyd_step must return 1 after a safe revert"
        return 0
    fi
    assert_eq "VALID_CROS_CONF" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "upgrade failure (original): V1 restored, NOT the oldest ORIGINAL"
    local backup_count backup_file
    backup_count="$(find "$sandbox/backups" -name cros.conf 2> /dev/null | wc -l | tr -d '[:space:]')"
    assert_eq "1" "$backup_count" "upgrade failure (original): first-wins keeps one backup"
    backup_file="$(find "$sandbox/backups" -name cros.conf 2> /dev/null | head -n 1)"
    assert_eq "ORIGINAL_CONFIG" "$(cat "$backup_file" 2> /dev/null || echo MISSING)" \
        "upgrade failure (original): backup still holds ORIGINAL"
    assert_eq "0" "$(snapshot_entries "$sandbox")" "upgrade failure (original): snapshot cleaned up"

    run_keyd_uninstall "$sandbox"
    assert_eq "ORIGINAL_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "upgrade failure (original): uninstall still restores ORIGINAL via first-wins"
}

# Scenario C: a symlink cros.conf must be restored as the same symlink, not
# dereferenced into a regular file by install(1).
test_keyd_upgrade_failure_preserves_symlink_type() {
    local sandbox="/tmp/rollback-test-keyd-upgrade-symlink"
    setup_keyd_upgrade_sandbox "$sandbox" absent || return 0

    rm -f "$sandbox/etc/keyd/cros.conf"
    printf 'ORIGINAL_CONFIG\n' > "$sandbox/etc/keyd/layout.conf"
    ln -s layout.conf "$sandbox/etc/keyd/cros.conf"

    if run_keyd_failing_upgrade "$sandbox"; then
        fail "upgrade failure (symlink): install_keyd_step must return 1 after a safe revert"
        return 0
    fi
    if [ -L "$sandbox/etc/keyd/cros.conf" ]; then
        assert_eq "layout.conf" "$(readlink "$sandbox/etc/keyd/cros.conf")" \
            "upgrade failure (symlink): original symlink target restored"
    else
        fail "upgrade failure (symlink): cros.conf must be restored as a symlink"
    fi
    assert_eq "ORIGINAL_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "upgrade failure (symlink): restored symlink still resolves"
}

# Service state is part of the snapshot: a service that was disabled/inactive
# before the failed upgrade must be disabled/stopped after recovery.
test_keyd_upgrade_failure_restores_service_state() {
    local sandbox="/tmp/rollback-test-keyd-upgrade-svc"
    setup_keyd_upgrade_sandbox "$sandbox" absent || return 0

    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_RESTART_FAIL_FIRST=1 STUB_RESTART_RETRY_FLAG="$2/retried" \
            STUB_SVC_ENABLED=0 STUB_SVC_ACTIVE=0
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "upgrade failure (service): install_keyd_step must return 1 after a safe revert"
        return 0
    fi
    local systemctl_log
    systemctl_log="$(cat "$sandbox/systemctl.log" 2> /dev/null || echo "")"
    assert_contains "disable keyd" "$systemctl_log" "service restore: keyd disabled again (was disabled)"
    assert_contains "stop keyd" "$systemctl_log" "service restore: keyd stopped after health-check (was inactive)"
    assert_eq "VALID_CROS_CONF" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "service restore: V1 config preserved"
}

# A successful deploy must consume its snapshot. A custom systemctl stub
# records SNAP:<n> at restart time so the assertion cannot pass vacuously.
test_keyd_snapshot_cleanup_on_success() {
    local sandbox="/tmp/rollback-test-keyd-snapshot-cleanup"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"

    cat > "$sandbox/stub/systemctl" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${STUB_SYSTEMCTL_LOG:?}"
case "\$*" in
    *"restart keyd"*)
        printf 'SNAP:%s\n' "\$(find '$sandbox/snapshots' -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l)" >> "\${STUB_SYSTEMCTL_LOG:?}"
        ;;
esac
exit 0
EOF
    chmod +x "$sandbox/stub/systemctl"

    if ! run_keyd_install_step "$sandbox"; then
        fail "snapshot cleanup: install step should succeed"
        return 0
    fi
    assert_contains "SNAP:1" "$(cat "$sandbox/systemctl.log" 2> /dev/null || echo "")" \
        "snapshot cleanup: one snapshot existed at restart time (not vacuous)"
    assert_eq "0" "$(snapshot_entries "$sandbox")" "snapshot cleanup: snapshot removed after success"
}

# A snapshot that cannot be created must fail closed: no deploy, no symlink
# removal, no partial snapshot left behind.
test_keyd_snapshot_create_failure_fails_closed() {
    local sandbox="/tmp/rollback-test-keyd-snapshot-fail"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src" "$sandbox/failbin"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"
    printf 'ORIGINAL_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$sandbox/failbin/mktemp"
    chmod +x "$sandbox/failbin/mktemp"

    if run_sandboxed "$sandbox" '
        export PATH="$2/failbin:$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "snapshot failure: install_keyd_step must fail closed (return 1)"
        return 0
    fi
    assert_eq "ORIGINAL_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "snapshot failure: cros.conf left untouched"
    if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "snapshot failure: default.conf symlink must not be removed"
    fi
    assert_contains "refusing to deploy" "$(cat "$sandbox/step.log" 2> /dev/null || echo "")" \
        "snapshot failure: fail-closed error logged"
    assert_eq "0" "$(snapshot_entries "$sandbox")" "snapshot failure: no partial snapshot left behind"
}

# P2: a directory or special file (e.g. FIFO) at a keyd path can be
# snapshotted with cp -a but cannot be restored via install(1). Fail closed:
# return 1, log an explicit unsupported-type error and leave everything else
# (legacy symlink, backups, partial snapshot) untouched. $1 = dir | fifo.
test_keyd_unsupported_path_type_fails_closed() {
    local sandbox="/tmp/rollback-test-keyd-unsupported-$1" kind="$1"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"
    # A pre-existing legacy default.conf symlink must be left untouched.
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"

    case "$kind" in
        dir) mkdir -p "$sandbox/etc/keyd/cros.conf" ;;
        fifo) mkfifo "$sandbox/etc/keyd/cros.conf" ;;
    esac

    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "unsupported path ($kind): install_keyd_step must fail closed (return 1)"
        return 0
    fi

    # _keyd_path_kind reports a FIFO as "other"; a directory as "dir".
    local expected_kind
    case "$kind" in
        dir) expected_kind="dir" ;;
        fifo) expected_kind="other" ;;
    esac
    local log
    log="$(cat "$sandbox/step.log" 2> /dev/null || echo "")"
    assert_contains "Unsupported keyd path type '$expected_kind'" "$log" \
        "unsupported path ($kind): explicit unsupported-type error logged"
    assert_contains "refusing to deploy" "$log" \
        "unsupported path ($kind): fail-closed error logged"
    # The original path type survives: nothing was deployed over it.
    case "$kind" in
        dir)
            if [ -d "$sandbox/etc/keyd/cros.conf" ]; then
                ok
            else
                fail "unsupported path (dir): cros.conf must remain a directory"
            fi
            ;;
        fifo)
            if [ -p "$sandbox/etc/keyd/cros.conf" ]; then
                ok
            else
                fail "unsupported path (fifo): cros.conf must remain a FIFO"
            fi
            ;;
    esac
    if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "unsupported path ($kind): default.conf symlink must be left untouched"
    fi
    assert_eq "0" "$(snapshot_entries "$sandbox")" "unsupported path ($kind): no partial snapshot left behind"
    local backup_count
    backup_count="$(find "$sandbox/backups" -type f 2> /dev/null | wc -l | tr -d '[:space:]')"
    assert_eq "0" "$backup_count" "unsupported path ($kind): no backup created before refusal"
}

# ---------------------------------------------------------------------------
# 32a/32b. P1: a failed backup copy or manifest write must fail closed. The
# pre-deploy cros.conf and legacy symlink stay untouched, no service is
# mutated, no keyd record is claimed in the manifest and the snapshot is
# retained with a .failed marker. $3 = expected number of backup files,
# $4 = expected number of manifest records for the two keyd paths (default 0).
# ---------------------------------------------------------------------------
assert_keyd_backup_failure_fails_closed() {
    local sandbox="$1" label="$2" expected_backups="$3" expected_keyd_records="${4:-0}" reason="${5:-backup failed}"
    assert_eq "1" "$(cat "$sandbox/install-rc.txt" 2> /dev/null || echo MISSING)" \
        "$label: CLI returns 1"
    assert_eq "failed" "$(cat "$sandbox/keyd-state.txt" 2> /dev/null || echo MISSING)" \
        "$label: KEYD_STATE=failed"
    assert_eq "0" "$(cat "$sandbox/keyd-deployed.txt" 2> /dev/null || echo MISSING)" \
        "$label: KEYD_DEPLOYED=0"
    assert_eq "ORIGINAL" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "$label: original cros.conf untouched"
    if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "$label: legacy default.conf symlink must be preserved"
    fi
    if grep -qE 'enable keyd|restart keyd' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "$label: keyd service must not be enabled or restarted"
    else
        ok
    fi
    local retained
    retained="$(snapshot_dir "$sandbox")"
    if [ -n "$retained" ] && sudo test -d "$retained"; then
        ok
    else
        fail "$label: pre-deploy snapshot must be retained"
        retained=""
    fi
    if [ -n "$retained" ] && sudo test -f "$retained/.failed"; then
        ok
    else
        fail "$label: retained snapshot must carry a .failed marker"
    fi
    assert_contains "$reason" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "$label: retain log names the failure reason"
    assert_contains "refusing to deploy keyd config" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "$label: fail-closed error logged"
    local keyd_records
    keyd_records="$(python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print(0)
    raise SystemExit
targets = set(sys.argv[2:])
print(sum(1 for r in data.get("records", []) if r.get("target") in targets))
' "$sandbox/manifest/install-manifest.json" \
        "$sandbox/etc/keyd/cros.conf" "$sandbox/etc/keyd/default.conf" 2> /dev/null || echo MISSING)"
    assert_eq "$expected_keyd_records" "$keyd_records" "$label: keyd manifest record count"
    assert_eq "$expected_backups" "$(find "$sandbox/backups" -type f 2> /dev/null | wc -l | tr -d '[:space:]')" \
        "$label: backup file count"
}

test_keyd_backup_copy_failure_fails_closed() {
    local sandbox="/tmp/rollback-test-keyd-backup-copy-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"

    # Fail only the backup copy under .../backups/*keyd/*, never the snapshot
    # copy -a into .../snapshots/keyd.XXXX/.
    cat > "$sandbox/stub/cp" << 'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        */backups/*keyd/*)
            printf 'STUB: backup cp refused: %s\n' "$*" >&2
            exit 1
            ;;
    esac
done
exec /bin/cp "$@"
EOF
    chmod +x "$sandbox/stub/cp"

    if run_keyd_caller "$sandbox" 1 0 0 0 2> "$sandbox/caller.log"; then
        fail "backup copy failure: CLI must return 1"
    fi
    assert_keyd_backup_failure_fails_closed "$sandbox" "backup copy failure" 0
}

test_keyd_manifest_write_failure_fails_closed() {
    local sandbox="/tmp/rollback-test-keyd-manifest-write-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"

    # manifest_add_entry() calls python3 -c with 7 args; allow the 4/5-arg
    # readers (manifest_has_target, _manifest_was_existing, normalize).
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -ge 6 ]; then
    printf 'STUB: manifest write refused\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/python3"

    if run_keyd_caller "$sandbox" 1 0 0 0 2> "$sandbox/caller.log"; then
        fail "manifest write failure: CLI must return 1"
    fi
    assert_keyd_backup_failure_fails_closed "$sandbox" "manifest write failure" 1
}

# Fail ONLY the legacy symlink backup (cros.conf was already backed up). This
# proves the symlink removal was moved after its own backup guard.
test_keyd_link_backup_failure_fails_closed() {
    local sandbox="/tmp/rollback-test-keyd-link-backup-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"

    cat > "$sandbox/stub/cp" << 'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        */backups/*keyd/*default.conf)
            printf 'STUB: link backup cp refused: %s\n' "$*" >&2
            exit 1
            ;;
    esac
done
exec /bin/cp "$@"
EOF
    chmod +x "$sandbox/stub/cp"

    if run_keyd_caller "$sandbox" 1 0 0 0 2> "$sandbox/caller.log"; then
        fail "link backup failure: CLI must return 1"
    fi
    # cros.conf already had a valid backup/record before the link backup
    # failed; only the legacy link must stay unclaimed.
    assert_keyd_backup_failure_fails_closed "$sandbox" "link backup failure" 1 1
    local link_records
    link_records="$(python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print(0)
    raise SystemExit
print(sum(1 for r in data.get("records", []) if r.get("target") == sys.argv[2]))
' "$sandbox/manifest/install-manifest.json" "$sandbox/etc/keyd/default.conf" 2> /dev/null || echo MISSING)"
    assert_eq "0" "$link_records" "link backup failure: no manifest record for the legacy link"
    assert_contains "failed for $sandbox/etc/keyd/default.conf" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "link backup failure: refusal names the legacy link"
}

# ---------------------------------------------------------------------------
# 32c/32d. P2: the keyd SERVICE manifest write must be checked too. A failed
# file backup is already fail-closed, but an unchecked service-write failure
# would still enable/restart keyd with NO ownership record, so uninstall would
# leave the service running. The narrow python3 stub below refuses only the
# service write (8 args, script mentioning was_enabled): manifest_add_entry
# (7 args) and all readers still succeed, proving the failure point is the
# service manifest and not the earlier file backup/record.
# ---------------------------------------------------------------------------
test_keyd_service_manifest_failure_fails_closed() {
    local sandbox="/tmp/rollback-test-keyd-service-manifest-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"

    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -ge 8 ] && printf '%s' "${2:-}" | grep -q 'was_enabled'; then
    printf 'STUB: service manifest write refused\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/python3"

    local rc=0
    run_keyd_caller "$sandbox" 1 0 0 0 2> "$sandbox/caller.log" || rc=$?
    assert_eq "1" "$rc" "service manifest failure: CLI returns 1"
    # Both file backups/records precede the guard, so both are kept.
    assert_keyd_backup_failure_fails_closed "$sandbox" "service manifest failure" 1 2 "service manifest failed"
    local cros_backups
    cros_backups="$(find "$sandbox/backups" -name cros.conf 2> /dev/null | wc -l | tr -d '[:space:]')"
    assert_eq "1" "$cros_backups" "service manifest failure: cros.conf backup succeeded before the guard"
    local services
    services="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("services", [])))' \
        "$sandbox/manifest/install-manifest.json" 2> /dev/null || echo MISSING)"
    assert_eq "0" "$services" "service manifest failure: no service ownership record was written"
    assert_contains "service manifest write failed" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "service manifest failure: root cause logged"
    assert_contains "refusing to deploy keyd config or enable/restart keyd" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "service manifest failure: explicit refusal logged"

    # No ownership record: uninstall's sole authority would leave keyd alone.
    # Read it without running uninstall, which would consume the manifest
    # records the recovery test below needs to prove first-wins.
    local managed
    managed="$(run_sandboxed "$sandbox" '
        source "$2/install-keyboard-sandbox.sh"
        _keyd_managed_by_us
    ')"
    assert_eq "0" "$managed" "service manifest failure: keyd has no ownership record"
}

# Retry the SAME sandbox without the stub: a later install must succeed, keep
# first-wins backups, and leave the earlier marked snapshot intact.
test_keyd_service_manifest_failure_recovery() {
    local sandbox="/tmp/rollback-test-keyd-service-manifest-fail"
    if [ ! -d "$sandbox/manifest" ]; then
        fail "service manifest recovery: prerequisite failure test did not run"
        return 0
    fi
    local failed_snap
    failed_snap="$(snapshot_dir "$sandbox")"
    if [ -z "$failed_snap" ] || ! sudo test -f "$failed_snap/.failed"; then
        fail "service manifest recovery: prerequisite marked snapshot missing"
        return 0
    fi

    # Make --global cat keyd fail so the service record gets the real system
    # scope (the shared default stub answers every --global cat with success).
    # Also log the snapshot count at restart time so "two snapshots existed"
    # cannot pass vacuously.
    rm -f "$sandbox/stub/python3"
    cat > "$sandbox/stub/systemctl" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${STUB_SYSTEMCTL_LOG:?}"
case "\$*" in
    "--global cat keyd")
        exit 1
        ;;
    *"restart keyd"*)
        printf 'SNAP:%s\n' "\$(find '$sandbox/snapshots' -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l)" >> "\${STUB_SYSTEMCTL_LOG:?}"
        ;;
    *"is-enabled keyd"*|*"is-enabled --quiet keyd"*) [ "\${STUB_SVC_ENABLED:-1}" = "1" ] && exit 0 || exit 3 ;;
    *"is-active keyd"*|*"is-active --quiet keyd"*) [ "\${STUB_SVC_ACTIVE:-1}" = "1" ] && exit 0 || exit 3 ;;
esac
exit 0
EOF
    chmod +x "$sandbox/stub/systemctl"
    : > "$sandbox/systemctl.log"

    local rc=0
    run_keyd_caller "$sandbox" 1 0 0 0 2> "$sandbox/caller-retry.log" || rc=$?
    assert_eq "0" "$rc" "service manifest recovery: retry returns 0"
    assert_eq "0" "$(cat "$sandbox/install-rc.txt" 2> /dev/null || echo MISSING)" \
        "service manifest recovery: install_keyboard rc"
    assert_eq "1" "$(cat "$sandbox/keyd-deployed.txt" 2> /dev/null || echo MISSING)" \
        "service manifest recovery: KEYD_DEPLOYED=1"
    case "$(cat "$sandbox/keyd-state.txt" 2> /dev/null || echo MISSING)" in
        verified | active) ok ;;
        *) fail "service manifest recovery: KEYD_STATE must be verified/active" ;;
    esac
    assert_eq "VALID_CROS_CONF" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "service manifest recovery: valid config deployed"
    local svc
    svc="$(python3 -c '
import json, sys
try:
    s = [x for x in json.load(open(sys.argv[1])).get("services", [])
         if x.get("name") in ("keyd", "keyd.service")]
except Exception:
    print("MISSING")
    raise SystemExit
print(len(s), s[0].get("name", "") if s else "", s[0].get("component", "") if s else "", s[0].get("scope", "") if s else "")
' "$sandbox/manifest/install-manifest.json" 2> /dev/null || echo MISSING)"
    assert_eq "1 keyd keyboard system" "$svc" \
        "service manifest recovery: one system-scoped keyd service record"
    local cros_backups
    cros_backups="$(find "$sandbox/backups" -name cros.conf 2> /dev/null | wc -l | tr -d '[:space:]')"
    assert_eq "1" "$cros_backups" "service manifest recovery: first-wins keeps one cros.conf backup"
    local log
    log="$(cat "$sandbox/systemctl.log" 2> /dev/null || echo "")"
    assert_contains "enable keyd" "$log" "service manifest recovery: keyd enabled"
    assert_contains "restart keyd" "$log" "service manifest recovery: keyd restarted"
    assert_contains "SNAP:2" "$log" \
        "service manifest recovery: second snapshot existed at restart time (failure + new)"
    local snap_dirs
    snap_dirs="$(sudo find "$sandbox/snapshots" -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l | tr -d '[:space:]')"
    assert_eq "1" "$snap_dirs" "service manifest recovery: new snapshot cleaned up after success"
    assert_eq "$failed_snap" "$(snapshot_dir "$sandbox")" \
        "service manifest recovery: the first marked snapshot was retained"
    if sudo test -d "$failed_snap" && sudo test -f "$failed_snap/.failed"; then
        ok
    else
        fail "service manifest recovery: first snapshot still carries its .failed marker"
    fi

    : > "$sandbox/systemctl.log"
    run_keyd_uninstall "$sandbox"
    assert_contains "disable --now keyd" "$(cat "$sandbox/systemctl.log" 2> /dev/null || echo "")" \
        "service manifest recovery: uninstall disables the now-owned keyd service"
}

# The helper itself must propagate the python write failure (otherwise the new
# preflight guard could never see it).
test_manifest_add_service_failure_returns_nonzero() {
    local sandbox="/tmp/rollback-test-manifest-add-service-helper-fail"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/stub"
    setup_keyd_stubs "$sandbox" valid
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -ge 8 ] && printf '%s' "${2:-}" | grep -q 'was_enabled'; then
    printf 'STUB: service manifest write refused\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/python3"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$1/lib/backup.sh"
        manifest_add_service "keyd" "keyboard"
        printf "%s\n" "$?" > "$2/helper-rc.txt"
    '
    assert_eq "1" "$(cat "$sandbox/helper-rc.txt" 2> /dev/null || echo MISSING)" \
        "manifest_add_service: a failed python write returns 1"
}

# Direct helper-level checks: both primitives must propagate a real failure.
test_backup_helper_copy_failure_returns_nonzero() {
    local sandbox="/tmp/rollback-test-backup-helper-copy-fail"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc" "$sandbox/stub"
    setup_keyd_stubs "$sandbox" none
    printf 'ORIGINAL\n' > "$sandbox/etc/demo.conf"
    printf '#!/usr/bin/env bash\nprintf "STUB: cp refused\\n" >&2\nexit 1\n' > "$sandbox/stub/cp"
    chmod +x "$sandbox/stub/cp"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        backup_file "$2/etc/demo.conf"
        printf "%s\n" "$?" > "$2/helper-rc.txt"
    '
    assert_eq "1" "$(cat "$sandbox/helper-rc.txt" 2> /dev/null || echo MISSING)" \
        "backup_file: copy failure returns 1"
    assert_eq "ORIGINAL" "$(cat "$sandbox/etc/demo.conf")" "backup_file: source untouched"
    assert_eq "0" "$(find "$sandbox/backups" -type f 2> /dev/null | wc -l | tr -d '[:space:]')" \
        "backup_file: no partial backup left"
}

test_backup_helper_manifest_failure_returns_nonzero() {
    local sandbox="/tmp/rollback-test-backup-helper-manifest-fail"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc" "$sandbox/stub"
    setup_keyd_stubs "$sandbox" none
    printf 'ORIGINAL\n' > "$sandbox/etc/demo.conf"
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -ge 6 ]; then
    printf 'STUB: manifest write refused\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/python3"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        backup_file_manifest_aware "$2/etc/demo.conf" "demo"
        printf "%s\n" "$?" > "$2/helper-rc.txt"
    '
    assert_eq "1" "$(cat "$sandbox/helper-rc.txt" 2> /dev/null || echo MISSING)" \
        "backup_file_manifest_aware: manifest write failure returns 1"
    assert_eq "1" "$(find "$sandbox/backups" -type f 2> /dev/null | wc -l | tr -d '[:space:]')" \
        "backup_file_manifest_aware: backup kept when manifest write fails"
    local records
    records="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("records", [])))' \
        "$sandbox/manifest/install-manifest.json" 2> /dev/null || echo MISSING)"
    assert_eq "0" "$records" "backup_file_manifest_aware: no unclaimed manifest record"
}

# ---------------------------------------------------------------------------
# 33a. P1 SECURITY: a pre-created world-writable snapshot base must never be
#      accepted (no chown/chmod "repair", no deploy, no backup).
# ---------------------------------------------------------------------------
test_keyd_snapshot_base_world_writable_fails_closed() {
    local sandbox="/tmp/rollback-test-keyd-base-world-writable"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" \
        "$sandbox/keyd-src" "$sandbox/snapshots"
    chmod 777 "$sandbox/snapshots"
    # Keep the base root-owned so the unsafe MODE check (not the uid check)
    # is the one that rejects it, matching the asserted 'unsafe mode' error.
    sudo chown 0:0 "$sandbox/snapshots"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'V2_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
    printf 'V1_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"

    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "world-writable base: install_keyd_step must fail closed (rc=1)"
        return 0
    fi
    local log
    log="$(cat "$sandbox/step.log" 2> /dev/null || echo "")"
    assert_contains "refusing to deploy keyd config" "$log" \
        "world-writable base: fail-closed error logged"
    assert_contains "unsafe mode '777'" "$log" \
        "world-writable base: offending mode is named in the error"
    assert_eq "V1_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "world-writable base: cros.conf untouched"
    if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "world-writable base: legacy symlink must be untouched"
    fi
    assert_eq "0" "$(snapshot_entries "$sandbox")" \
        "world-writable base: no snapshot directory created"
    assert_eq "0" "$(find "$sandbox/backups" -type f 2> /dev/null | wc -l | tr -d '[:space:]')" \
        "world-writable base: no backup recorded"
    if grep -qE 'enable keyd|restart keyd' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "world-writable base: no service mutation allowed"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 33a.1 P2 SECURITY: a private (0700) base owned by a non-root user must be
#      rejected - root's sudo writes into such a directory could be renamed or
#      replaced by that owner. Fails closed with no deploy and no mutation.
# ---------------------------------------------------------------------------
test_keyd_snapshot_base_nonroot_owner_fails_closed() {
    local sandbox="/tmp/rollback-test-keyd-base-nonroot-owner"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    sudo install -d -m 700 -o 0 -g 0 -- "$sandbox/snapshots"
    sudo chown 1000:1000 "$sandbox/snapshots"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    # Simulate a non-root caller. The security check must reject this base by
    # inspecting the *base's* uid against root, never by accepting the caller's
    # uid: a regression to `[ "$uid" != "$my_uid" ]` with `my_uid="$(id -u)"`
    # would otherwise stay invisible while the suite runs as root and deploy.
    printf '#!/usr/bin/env bash\nif [ "$1" = "-u" ]; then echo 1000; else /usr/bin/id "$@"; fi\n' > "$sandbox/stub/id"
    chmod +x "$sandbox/stub/id"
    printf 'V2_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
    printf 'V1_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"

    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "non-root-owned base: install_keyd_step must fail closed (rc=1)"
        return 0
    fi
    local log
    log="$(cat "$sandbox/step.log" 2> /dev/null || echo "")"
    assert_contains "owned by uid '1000'" "$log" \
        "non-root-owned base: offending uid is named in the error"
    assert_contains "must be root-owned" "$log" \
        "non-root-owned base: error states the root-owned requirement"
    assert_contains "refusing to deploy keyd config" "$log" \
        "non-root-owned base: fail-closed error logged"
    assert_eq "V1_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "non-root-owned base: cros.conf untouched"
    if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "non-root-owned base: legacy symlink must be untouched"
    fi
    assert_eq "0" "$(snapshot_entries "$sandbox")" \
        "non-root-owned base: no snapshot directory created"
    assert_eq "0" "$(find "$sandbox/backups" -type f 2> /dev/null | wc -l | tr -d '[:space:]')" \
        "non-root-owned base: no backup recorded"
    if grep -qE 'enable keyd|restart keyd' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "non-root-owned base: no service mutation allowed"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 33a.2 P2 SECURITY: a non-root-owned DIRECT PARENT of a custom snapshot base
#      must be rejected by uid, and the base itself must never be created.
# ---------------------------------------------------------------------------
test_keyd_snapshot_base_nonroot_parent_fails_closed() {
    local sandbox="/tmp/rollback-test-keyd-base-nonroot-parent"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" \
        "$sandbox/keyd-src" "$sandbox/nonroot-parent"
    sudo chown 1000:1000 "$sandbox/nonroot-parent"
    sudo chmod 755 "$sandbox/nonroot-parent"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    # Simulate a non-root caller so a regression that accepts the caller's uid
    # (instead of requiring the parent to be root-owned) changes behaviour here
    # rather than staying green under the root test runner.
    printf '#!/usr/bin/env bash\nif [ "$1" = "-u" ]; then echo 1000; else /usr/bin/id "$@"; fi\n' > "$sandbox/stub/id"
    chmod +x "$sandbox/stub/id"
    printf 'V2_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
    printf 'V1_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"

    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        KEYD_SNAPSHOT_BASE="$2/nonroot-parent/snapshots"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "non-root-owned parent: install_keyd_step must fail closed (rc=1)"
        return 0
    fi
    local log
    log="$(cat "$sandbox/step.log" 2> /dev/null || echo "")"
    assert_contains "nonroot-parent' is owned by uid '1000'" "$log" \
        "non-root-owned parent: parent path and uid are named in the error"
    assert_contains "must be root-owned" "$log" \
        "non-root-owned parent: error states the root-owned requirement"
    assert_contains "refusing to deploy keyd config" "$log" \
        "non-root-owned parent: fail-closed error logged"
    if [ -e "$sandbox/nonroot-parent/snapshots" ]; then
        fail "non-root-owned parent: snapshot base must not be created"
    else
        ok
    fi
    assert_eq "V1_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "non-root-owned parent: cros.conf untouched"
    if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "non-root-owned parent: legacy symlink must be untouched"
    fi
    assert_eq "0" "$(find "$sandbox/backups" -type f 2> /dev/null | wc -l | tr -d '[:space:]')" \
        "non-root-owned parent: no backup recorded"
    if grep -qE 'enable keyd|restart keyd' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "non-root-owned parent: no service mutation allowed"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 33a.2.1 CONTROL: a non-root caller must NOT make a root-owned 0700 base
#      invalid - the rule is about the base's (and parent's) uid, never the
#      caller's uid. Together with 33a.1/33a.2 this pins the contract to
#      "root-owned only": accepting `id -u` is caught by the two fail-closed
#      tests, while checking *only* against `id -u` is caught here.
# ---------------------------------------------------------------------------
test_keyd_snapshot_base_root_owned_nonroot_caller_succeeds() {
    local sandbox="/tmp/rollback-test-keyd-base-root-owned-nonroot-caller"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    sudo install -d -m 700 -o 0 -g 0 -- "$sandbox/snapshots"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf '#!/usr/bin/env bash\nif [ "$1" = "-u" ]; then echo 1000; else /usr/bin/id "$@"; fi\n' > "$sandbox/stub/id"
    chmod +x "$sandbox/stub/id"
    printf 'V2_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
    printf 'V1_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"

    if ! run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "root-owned base + non-root caller: install_keyd_step should succeed"
        return 0
    fi
    assert_eq "V2_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "root-owned base + non-root caller: config deployed"
    assert_eq "0" "$(snapshot_entries "$sandbox")" \
        "root-owned base + non-root caller: snapshot cleaned on success"
}

# ---------------------------------------------------------------------------
# 33a.3 P2 SECURITY: a group/other-writable DIRECT PARENT must be rejected even
#      when it carries a sticky bit (a sticky /tmp ancestor is still allowed).
# ---------------------------------------------------------------------------
test_keyd_snapshot_base_world_parent_rejected() {
    local sandbox="/tmp/rollback-test-keyd-base-world-parent"
    local custom_base="$sandbox/world-parent/snapshots"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" \
        "$sandbox/keyd-src" "$sandbox/world-parent"
    sudo chmod 1777 "$sandbox/world-parent"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'V2_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
    printf 'V1_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"

    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        KEYD_SNAPSHOT_BASE="$2/world-parent/snapshots"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "world-writable parent: install_keyd_step must fail closed (rc=1)"
        return 0
    fi
    local log
    log="$(cat "$sandbox/step.log" 2> /dev/null || echo "")"
    assert_contains "group/other-writable parent directory" "$log" \
        "world-writable parent: error names the parent's group/other-writable mode"
    assert_contains "refusing to deploy keyd config" "$log" \
        "world-writable parent: fail-closed error logged"
    if [ -e "$custom_base" ]; then
        fail "world-writable parent: snapshot base must not be created"
    else
        ok
    fi
    assert_eq "V1_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "world-writable parent: cros.conf untouched"
    if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "world-writable parent: legacy symlink must be untouched"
    fi
    assert_eq "0" "$(find "$sandbox/backups" -type f 2> /dev/null | wc -l | tr -d '[:space:]')" \
        "world-writable parent: no backup recorded"
    if grep -qE 'enable keyd|restart keyd' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "world-writable parent: no service mutation allowed"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 33a.4 P2 SECURITY: a custom base with root-owned ancestors and a root-owned
#      0700 base is accepted; the snapshot is created and cleaned on success.
#      (A home-directory/non-root-owned custom path is rejected above.)
# ---------------------------------------------------------------------------
test_keyd_snapshot_base_custom_root_owned_succeeds() {
    local sandbox="/tmp/rollback-test-keyd-base-custom-root-owned"
    local custom_base="$sandbox/custom-root/snapshots"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" \
        "$sandbox/keyd-src" "$sandbox/custom-root"
    sudo install -d -m 700 -o 0 -g 0 -- "$custom_base"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'VALID_CROS_CONF\n' > "$sandbox/keyd-src/cros.conf"

    # Record the snapshot count at restart time so the cleanup assertion cannot
    # pass vacuously (no snapshot ever created).
    cat > "$sandbox/stub/systemctl" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${STUB_SYSTEMCTL_LOG:?}"
case "\$*" in
    *"restart keyd"*)
        printf 'SNAP:%s\n' "\$(find '$custom_base' -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l)" >> "\${STUB_SYSTEMCTL_LOG:?}"
        ;;
esac
exit 0
EOF
    chmod +x "$sandbox/stub/systemctl"

    if ! run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        KEYD_SNAPSHOT_BASE="$2/custom-root/snapshots"
        install_keyd_step
    '; then
        fail "custom root-owned base: install step should succeed"
        return 0
    fi
    local log
    log="$(cat "$sandbox/systemctl.log" 2> /dev/null || echo "")"
    assert_contains "SNAP:1" "$log" \
        "custom root-owned base: one snapshot existed at restart time (not vacuous)"
    assert_eq "0" "$(sudo find "$custom_base" -mindepth 1 2> /dev/null | wc -l | tr -d '[:space:]')" \
        "custom root-owned base: snapshot removed after success"
    assert_eq "VALID_CROS_CONF" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "custom root-owned base: config deployed successfully"
}

# ---------------------------------------------------------------------------
# 33b. P1 SECURITY: a symlink at the snapshot base must be rejected without
#      following it (dangling on purpose, so a resolved path would fail too).
# ---------------------------------------------------------------------------
test_keyd_snapshot_base_symlink_rejected() {
    local sandbox="/tmp/rollback-test-keyd-base-symlink"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    ln -s "$sandbox/snapshot-target" "$sandbox/snapshots"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'V2_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
    printf 'V1_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"

    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "symlink base: install_keyd_step must fail closed (rc=1)"
        return 0
    fi
    local log
    log="$(cat "$sandbox/step.log" 2> /dev/null || echo "")"
    assert_contains "symlink" "$log" "symlink base: rejection names the symlink"
    assert_contains "refusing to deploy keyd config" "$log" \
        "symlink base: fail-closed error logged"
    assert_eq "V1_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "symlink base: cros.conf untouched"
    if [ -L "$sandbox/snapshots" ]; then
        ok
    else
        fail "symlink base: the attacker-provided symlink must not be replaced"
    fi
    assert_eq "0" "$(snapshot_entries "$sandbox")" "symlink base: no snapshot created"
    assert_eq "0" "$(find "$sandbox/backups" -type f 2> /dev/null | wc -l | tr -d '[:space:]')" \
        "symlink base: no backup recorded"
    if grep -qE 'enable keyd|restart keyd' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "symlink base: no service mutation allowed"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 33c. P2: when recovery fails, the snapshot is the only V1 evidence. It must
#      be kept, marked .failed and named in the log (never silently deleted).
# ---------------------------------------------------------------------------
test_keyd_restore_failure_keeps_snapshot() {
    local sandbox="/tmp/rollback-test-keyd-restore-failure-retain"
    setup_keyd_restart_recoverable_sandbox "$sandbox" absent
    printf 'V1_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"
    printf 'V2_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
    : > "$sandbox/log.txt"

    # Force restoration to fail while the retry restart succeeds: this is the
    # final `return 1` branch of _restore_keyd_after_failed_restart. (The early
    # branch is covered by test_keyd_restart_unrecoverable_returns_failure.)
    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_RESTART_FAIL_FIRST=1 STUB_RESTART_RETRY_FLAG="$2/retried"
        source "$2/install-keyboard-sandbox.sh"
        _keyd_snapshot_restore() { return 1; }
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "restore failure: install_keyd_step must return 1"
        return 0
    fi
    local d log
    d="$(snapshot_dir "$sandbox")"
    if [ -n "$d" ] && sudo test -d "$d"; then
        ok
    else
        fail "restore failure: snapshot must be retained on disk"
        return 0
    fi
    log="$(cat "$sandbox/log.txt" 2> /dev/null || echo "")"
    assert_contains "$d" "$log" "restore failure: log names the retained snapshot path"
    assert_contains "RETAINED" "$log" "restore failure: log marks the snapshot as retained"
    if sudo test -f "$d/.failed"; then
        ok
    else
        fail "restore failure: retained snapshot must carry a .failed marker"
    fi
    assert_eq "failed" "$(sudo cat "$d/.failed" 2> /dev/null || echo MISSING)" \
        "restore failure: .failed marker content"
    assert_eq "file" "$(sudo cat "$d/cros.kind" 2> /dev/null || echo MISSING)" \
        "restore failure: retained snapshot still has cros.kind"
    assert_eq "V1_CONFIG" "$(sudo cat "$d/cros.data" 2> /dev/null || echo MISSING)" \
        "restore failure: retained snapshot still holds the V1 evidence"
    assert_contains "snapshot restore FAILED" "$(cat "$sandbox/step.log" 2> /dev/null || echo "")" \
        "restore failure: explicit restore-failed warning printed"

    # Pruning must never destroy a retained (marked) snapshot, even when old.
    sudo touch -d '8 days ago' "$d" 2> /dev/null || true
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        _keyd_snapshot_prune_old
    '
    if sudo test -d "$d"; then
        ok
    else
        fail "restore failure: prune must skip a snapshot with a .failed marker"
    fi
}

# ---------------------------------------------------------------------------
# 33d. P2 mixed identity: after a sudo run created a 0700 root-owned base, a
#      non-root caller with internal sudo must still be able to snapshot.
#      Privilege wrappers deny non-sudo mutation of snapshot/keyd paths.
# ---------------------------------------------------------------------------
setup_keyd_snapshot_privilege_stubs() {
    local sandbox="$1"
    mkdir -p "$sandbox/snapbin"

    cat > "$sandbox/stub/sudo" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_SUDO_LOG:?}"
export STUB_SUDO_ELEVATED=1
exec "$@"
EOF

    cat > "$sandbox/snapbin/priv-wrapper" << EOF
#!/usr/bin/env bash
name="\$(basename "\$0")"
real=""
for d in /usr/bin /bin /usr/sbin /sbin; do
    if [ -x "\$d/\$name" ]; then real="\$d/\$name"; break; fi
done
[ -n "\$real" ] || exit 1
if [ "\${STUB_SUDO_ELEVATED:-0}" = "1" ]; then
    exec "\$real" "\$@"
fi
for arg in "\$@"; do
    case "\$arg" in
        $sandbox/snapshots* | $sandbox/etc/keyd | $sandbox/etc/keyd/*)
            printf 'DENIED:%s %s\n' "\$name" "\$*" >> "\${STUB_PRIV_LOG:?}"
            exit 1
            ;;
    esac
done
exec "\$real" "\$@"
EOF
    chmod +x "$sandbox/stub/sudo" "$sandbox/snapbin/priv-wrapper"
    local cmd
    for cmd in mkdir mktemp cp tee install stat; do
        ln -s priv-wrapper "$sandbox/snapbin/$cmd"
    done
}

test_keyd_snapshot_mixed_identity() {
    local sandbox="/tmp/rollback-test-keyd-snapshot-mixed-identity"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    setup_keyd_snapshot_privilege_stubs "$sandbox"
    printf 'V1_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
    printf 'V1_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"
    : > "$sandbox/sudo.log"
    : > "$sandbox/priv.log"

    # A fresh base forces the installer to create it through sudo as well;
    # otherwise the harness already provided a 0700 root-owned base.
    if ! run_sandboxed "$sandbox" '
        export PATH="$2/snapbin:$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_SUDO_LOG="$2/sudo.log" STUB_PRIV_LOG="$2/priv.log"
        source "$2/install-keyboard-sandbox.sh"
        KEYD_SNAPSHOT_BASE="$2/snapshots-mixed"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "mixed identity: snapshot I/O through sudo must let the install succeed"
        return 0
    fi
    local sudo_log denied
    sudo_log="$(cat "$sandbox/sudo.log" 2> /dev/null || echo "")"
    denied="$(grep -c 'DENIED:' "$sandbox/priv.log" 2> /dev/null || true)"
    assert_eq "0" "${denied:-0}" \
        "mixed identity: no unprivileged snapshot/keyd mutation"
    assert_contains "install -d -m 700 -o 0 -g 0 -- $sandbox/snapshots-mixed" "$sudo_log" \
        "mixed identity: sudo created the 0700 root-owned base"
    assert_contains "mktemp -d -- $sandbox/snapshots-mixed/keyd." "$sudo_log" \
        "mixed identity: sudo created the per-deploy snapshot directory"
    assert_contains "cp -a -- $sandbox/etc/keyd/cros.conf" "$sudo_log" \
        "mixed identity: sudo copied the config into the snapshot"
    assert_contains "tee $sandbox/snapshots-mixed/keyd." "$sudo_log" \
        "mixed identity: sudo wrote the snapshot metadata"
    assert_eq "V1_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "mixed identity: config deployed successfully"

    # The inverse: an unsafe base still fails closed with an explicit error.
    chmod 777 "$sandbox/snapshots"
    # Keep the base root-owned so the mode check (not the uid check) fires.
    sudo chown 0:0 "$sandbox/snapshots"
    : > "$sandbox/step2.log"
    if run_sandboxed "$sandbox" '
        export PATH="$2/snapbin:$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_SUDO_LOG="$2/sudo.log" STUB_PRIV_LOG="$2/priv.log"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step2.log"; then
        fail "mixed identity: unsafe base must fail closed"
    else
        assert_contains "unsafe mode '777'" "$(cat "$sandbox/step2.log" 2> /dev/null || echo "")" \
            "mixed identity: unsafe base produces an explicit error"
    fi
}

# ---------------------------------------------------------------------------
# 33e. Pruning keeps old snapshots that carry a .failed marker.
# ---------------------------------------------------------------------------
test_keyd_snapshot_prune_skips_failed() {
    local sandbox="/tmp/rollback-test-keyd-snapshot-prune-failed"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/snapshots"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    local marked="$sandbox/snapshots/keyd.marked" plain="$sandbox/snapshots/keyd.plain"
    mkdir -p "$marked" "$plain"
    printf 'failed\n' > "$marked/.failed"
    touch -d '8 days ago' "$marked" "$plain"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        _keyd_snapshot_prune_old
    '
    if [ -d "$marked" ]; then
        ok
    else
        fail "prune: snapshot with a .failed marker must be retained"
    fi
    if [ ! -e "$plain" ]; then
        ok
    else
        fail "prune: old unmarked snapshot must be removed"
    fi
}

# ---------------------------------------------------------------------------
# 34. P2 regression: a non-root user with passwordless sudo must be able to
#     restore a snapshot of root-owned keyd paths. The simulation enforces the
#     privilege boundary without needing a second real uid: the sudo stub logs
#     each call and sets a marker, and shadowing rm/mkdir/ln/install wrappers
#     deny mutations of the (simulated root-owned) keyd dir unless that marker
#     is present. Before the fix the restore mutations were unprivileged, so
#     V1 was lost and a misleading success line was printed.
# ---------------------------------------------------------------------------
setup_keyd_privilege_stubs() {
    local sandbox="$1"
    mkdir -p "$sandbox/privbin"

    # sudo: record the exact command, then "elevate" via a marker that the
    # privilege wrappers check (analogous to passwordless sudo for uid 1000).
    cat > "$sandbox/stub/sudo" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_SUDO_LOG:?}"
export STUB_SUDO_ELEVATED=1
exec "$@"
EOF

    # Shadow the four mutation commands. Non-sudo calls aimed at the keyd dir
    # are denied like EACCES for a non-root user; every other path passes
    # through so snapshot/backup bookkeeping still works.
    cat > "$sandbox/privbin/priv-wrapper" << EOF
#!/usr/bin/env bash
name="\$(basename "\$0")"
real=""
for d in /usr/bin /bin /usr/sbin /sbin; do
    if [ -x "\$d/\$name" ]; then real="\$d/\$name"; break; fi
done
[ -n "\$real" ] || exit 1
if [ "\${STUB_SUDO_ELEVATED:-0}" = "1" ]; then
    exec "\$real" "\$@"
fi
for arg in "\$@"; do
    case "\$arg" in
        $sandbox/etc/keyd | $sandbox/etc/keyd/*)
            printf 'DENIED:%s %s\n' "\$name" "\$*" >> "\${STUB_PRIV_LOG:?}"
            exit 1
            ;;
    esac
done
exec "\$real" "\$@"
EOF
    chmod +x "$sandbox/stub/sudo" "$sandbox/privbin/priv-wrapper"
    local cmd
    for cmd in rm mkdir ln install; do
        ln -s priv-wrapper "$sandbox/privbin/$cmd"
    done
}

test_keyd_restore_uses_sudo_nonroot() {
    # (a) Unit level: cover the sudo rm -rf branch directly with a crafted
    #     snapshot (a directory at KEYD_DST plus a symlink at KEYD_LINK).
    local unit="/tmp/rollback-test-keyd-restore-sudo-unit"
    rm -rf "$unit"
    mkdir -p "$unit/backups" "$unit/manifest" "$unit/etc/keyd" "$unit/snapshots/crafted"
    prepare_keyd_sandbox_script "$unit"
    setup_keyd_stubs "$unit" valid
    setup_keyd_privilege_stubs "$unit"
    printf 'file\n' > "$unit/snapshots/crafted/cros.kind"
    printf '644\n' > "$unit/snapshots/crafted/cros.mode"
    printf 'V1_DATA\n' > "$unit/snapshots/crafted/cros.data"
    printf 'symlink\n' > "$unit/snapshots/crafted/link.kind"
    printf 'cros.conf\n' > "$unit/snapshots/crafted/link.target"
    mkdir -p "$unit/etc/keyd/cros.conf"
    ln -s stale "$unit/etc/keyd/default.conf"
    : > "$unit/sudo.log"
    : > "$unit/priv.log"

    local unit_rc=0
    run_sandboxed "$unit" '
        export PATH="$2/privbin:$2/stub:$PATH" STUB_SUDO_LOG="$2/sudo.log" STUB_PRIV_LOG="$2/priv.log"
        source "$2/install-keyboard-sandbox.sh"
        KEYD_SNAPSHOT_DIR="$3"
        _keyd_restore_one "$KEYD_DST" "cros" && _keyd_restore_one "$KEYD_LINK" "link"
    ' "$unit/snapshots/crafted" || unit_rc=$?
    assert_eq "0" "$unit_rc" "restore-sudo (unit): restore helper succeeded under simulated non-root"
    assert_eq "V1_DATA" "$(cat "$unit/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "restore-sudo (unit): directory at keyd path removed via sudo rm -rf, file restored"
    if [ -L "$unit/etc/keyd/default.conf" ] && [ "$(readlink "$unit/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "restore-sudo (unit): symlink rebuilt via sudo rm -f + sudo ln -s"
    fi
    local unit_sudo_log unit_denied
    unit_sudo_log="$(cat "$unit/sudo.log" 2> /dev/null || echo "")"
    unit_denied="$(grep -c 'DENIED:' "$unit/priv.log" 2> /dev/null || true)"
    assert_eq "0" "${unit_denied:-0}" "restore-sudo (unit): no unprivileged keyd-path mutation"
    assert_contains "rm -rf -- $unit/etc/keyd/cros.conf" "$unit_sudo_log" \
        "restore-sudo (unit): sudo rm -rf used for a directory"
    assert_contains "rm -f -- $unit/etc/keyd/default.conf" "$unit_sudo_log" \
        "restore-sudo (unit): sudo rm -f used for a stale symlink"
    assert_contains "mkdir -p -- $unit/etc/keyd" "$unit_sudo_log" \
        "restore-sudo (unit): sudo mkdir -p used for the parent directory"
    assert_contains "ln -s -- cros.conf $unit/etc/keyd/default.conf" "$unit_sudo_log" \
        "restore-sudo (unit): sudo ln -s used to rebuild the symlink"
    assert_contains "install -D -m 644" "$unit_sudo_log" \
        "restore-sudo (unit): sudo install used to restore file content"
    assert_eq "5" "$(printf '%s\n' "$unit_sudo_log" | grep -cE '^(rm -f|rm -rf|mkdir -p|ln -s|install) --|^install -D' || true)" \
        "restore-sudo (unit): all five mutation kinds logged through sudo"

    # (b) End-to-end reviewer scenario: V1 -> V2 deploy with a failing first
    #     restart. Only a sudo-routed restore can bring V1 back from the
    #     simulated root-owned keyd dir.
    local sandbox="/tmp/rollback-test-keyd-restore-sudo"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/keyd" "$sandbox/keyd-src"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    printf 'V1_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
    printf 'V1_CONFIG\n' > "$sandbox/etc/keyd/cros.conf"
    if ! run_keyd_install_step "$sandbox"; then
        fail "restore-sudo: V1 deploy failed"
        return 0
    fi

    printf 'V2_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    setup_keyd_privilege_stubs "$sandbox"
    : > "$sandbox/sudo.log"
    : > "$sandbox/priv.log"
    : > "$sandbox/systemctl.log"

    if run_sandboxed "$sandbox" '
        export PATH="$2/privbin:$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_SUDO_LOG="$2/sudo.log" STUB_PRIV_LOG="$2/priv.log" \
            STUB_RESTART_FAIL_FIRST=1 STUB_RESTART_RETRY_FLAG="$2/retried"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "restore-sudo: V2 failure with a safe revert must return 1"
        return 0
    fi
    assert_eq "V1_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "restore-sudo: V1 config restored, not the broken V2"
    if [ -L "$sandbox/etc/keyd/default.conf" ] && [ "$(readlink "$sandbox/etc/keyd/default.conf")" = "cros.conf" ]; then
        ok
    else
        fail "restore-sudo: legacy default.conf symlink restored"
    fi
    local denied sudo_log step_log
    denied="$(grep -c 'DENIED:' "$sandbox/priv.log" 2> /dev/null || true)"
    assert_eq "0" "${denied:-0}" "restore-sudo: no unprivileged keyd-path mutation"
    sudo_log="$(cat "$sandbox/sudo.log" 2> /dev/null || echo "")"
    assert_contains "rm -f -- $sandbox/etc/keyd/cros.conf" "$sudo_log" \
        "restore-sudo: sudo rm -f used to clear the current config"
    assert_contains "mkdir -p -- $sandbox/etc/keyd" "$sudo_log" \
        "restore-sudo: sudo mkdir -p used for the parent directory"
    assert_contains "ln -s -- cros.conf $sandbox/etc/keyd/default.conf" "$sudo_log" \
        "restore-sudo: sudo ln -s used to rebuild the symlink"
    assert_contains "install -D -m 644" "$sudo_log" \
        "restore-sudo: sudo install used to restore the file from the snapshot"
    step_log="$(cat "$sandbox/step.log" 2> /dev/null || echo "")"
    assert_contains "keyd restart succeeded after restoring previous config" "$step_log" \
        "restore-sudo: success line printed when restored=1"
    if grep -qF "snapshot restore FAILED" "$sandbox/step.log"; then
        fail "restore-sudo: failure warning must be absent when restored=1"
    else
        ok
    fi

    # (c) Forcing snapshot restoration to fail must produce the explicit
    #     warning instead of the misleading success line (restored=0).
    printf 'V2_CONFIG\n' > "$sandbox/keyd-src/cros.conf"
    rm -f "$sandbox/retried"
    : > "$sandbox/sudo.log"
    : > "$sandbox/priv.log"
    : > "$sandbox/systemctl.log"
    : > "$sandbox/step2.log"
    run_sandboxed "$sandbox" '
        export PATH="$2/privbin:$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_SUDO_LOG="$2/sudo.log" STUB_PRIV_LOG="$2/priv.log" \
            STUB_RESTART_FAIL_FIRST=1 STUB_RESTART_RETRY_FLAG="$2/retried"
        source "$2/install-keyboard-sandbox.sh"
        _keyd_snapshot_restore() { return 1; }
        install_keyd_step
    ' 2> "$sandbox/step2.log" && fail "restore-sudo: forced restore failure must still return 1"
    local step2_log
    step2_log="$(cat "$sandbox/step2.log" 2> /dev/null || echo "")"
    assert_contains "snapshot restore FAILED" "$step2_log" \
        "restore-sudo: explicit warning printed when restored=0"
    if grep -qF "keyd restart succeeded after restoring previous config" "$sandbox/step2.log"; then
        fail "restore-sudo: success line must NOT be printed when restored=0"
    else
        ok
    fi
    # The final `return 1` path also retains and marks the V1 evidence.
    local retained
    retained="$(snapshot_dir "$sandbox")"
    if [ -n "$retained" ] && sudo test -f "$retained/.failed"; then
        ok
    else
        fail "restore-sudo: failed restore retains a marked snapshot"
    fi
}

test_uninstall_has_no_post_rollback_keyd_cleanup() {
    if grep -q 'Clean up legacy default.conf symlink' "$REPO_ROOT/keyboard/install-keyboard.sh"; then
        fail "uninstall must not delete default.conf after rollback_component"
    else
        ok
    fi
}

# --- P1 blocker: uninstall must only manage keyd it actually installed -------
# The stub reports keyd active/enabled, so before the fix every one of these
# tests would have called `systemctl disable --now keyd` based solely on the
# on-disk cros.conf. The manifest service record is now the sole authority.

test_uninstall_leaves_foreign_keyd_alone() {
    local sandbox="/tmp/rollback-test-uninstall-foreign-keyd"
    setup_keyd_uninstall_sandbox "$sandbox"
    # No manifest at all: self-installed keyd with a same-named cros.conf.
    : > "$sandbox/systemctl.log"

    run_keyd_uninstall "$sandbox"

    # Guard against a vacuous pass: the active/enabled query must have happened.
    assert_contains "is-active --quiet keyd" "$(cat "$sandbox/systemctl.log")" \
        "foreign-keyd: uninstall observed keyd as active"
    local log
    log="$(cat "$sandbox/systemctl.log")"
    if grep -qE '(^|[[:space:]])disable([[:space:]]|$).*keyd' <<< "$log"; then
        fail "foreign-keyd: uninstall must not disable an unmanaged keyd service"
    else
        ok
    fi
    assert_eq "USER_OWN_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "foreign-keyd: user-owned cros.conf is unchanged"
    assert_contains "leaving it untouched" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "foreign-keyd: log explains the service was left untouched"
}

test_uninstall_disables_managed_keyd_and_restores_state() {
    local sandbox="/tmp/rollback-test-uninstall-managed-keyd"
    setup_keyd_uninstall_sandbox "$sandbox"
    write_keyd_manifest "$sandbox" \
        '[{"name":"keyd","component":"keyboard","was_enabled":true,"was_active":true,"scope":"system"}]'
    : > "$sandbox/systemctl.log"

    run_keyd_uninstall "$sandbox"

    local log
    log="$(cat "$sandbox/systemctl.log")"
    assert_contains "disable --now keyd" "$log" \
        "managed-keyd: project-managed keyd is disabled before rollback"
    assert_contains "enable keyd" "$log" \
        "managed-keyd: rollback re-enables keyd to its recorded state"
    assert_contains "start keyd" "$log" \
        "managed-keyd: rollback restarts keyd to its recorded state"
    assert_eq "0" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("services", [])))' "$sandbox/manifest/install-manifest.json")" \
        "managed-keyd: service record consumed by rollback"
    assert_contains "Disabled project-managed keyd service" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "managed-keyd: log records the managed disable"
}

test_uninstall_keeps_keyd_without_service_record() {
    local sandbox="/tmp/rollback-test-uninstall-no-svc-record"
    setup_keyd_uninstall_sandbox "$sandbox"
    # A file record for cros.conf is NOT a service record.
    write_keyd_manifest "$sandbox" '[]' 1
    : > "$sandbox/systemctl.log"

    # The file record has was_existing=true but no backup, so the new
    # RECORD_BACKUP_MISSING contract makes rollback (and thus uninstall) return
    # 1. Guard the call or `set -e` would abort the whole suite here.
    uninstall_rc=0
    run_keyd_uninstall "$sandbox" || uninstall_rc=$?
    assert_eq "1" "$uninstall_rc" \
        "no-svc-record: uninstall propagates rollback rc 1 for a missing backup"

    local log
    log="$(cat "$sandbox/systemctl.log")"
    if grep -qE '(^|[[:space:]])disable([[:space:]]|$).*keyd' <<< "$log"; then
        fail "no-svc-record: file record alone must not authorize disabling keyd"
    else
        ok
    fi
    assert_eq "USER_OWN_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "no-svc-record: user-owned cros.conf is unchanged"
    assert_contains "leaving it untouched" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "no-svc-record: log explains the service was left untouched"
}

test_uninstall_manifest_without_services_does_not_disable_keyd() {
    local sandbox="/tmp/rollback-test-uninstall-no-services"
    local manifest
    setup_keyd_uninstall_sandbox "$sandbox"
    manifest="$sandbox/manifest/install-manifest.json"
    # Valid JSON with no services key: rollback itself handles this fine.
    # (Corrupt JSON / services:null are covered by the probe unit test because
    # the pre-existing rollback_component() aborts on those shapes.)
    printf '{"version":"2.0","records":[]}' > "$manifest"
    : > "$sandbox/systemctl.log"

    if ! run_keyd_uninstall "$sandbox"; then
        fail "uninstall must not crash on a manifest without services"
        return 0
    fi
    local log
    log="$(cat "$sandbox/systemctl.log")"
    if grep -qE '(^|[[:space:]])disable([[:space:]]|$).*keyd' <<< "$log"; then
        fail "a manifest without services must not authorize disabling keyd"
    else
        ok
    fi
    assert_eq "USER_OWN_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "no-services-key: user-owned cros.conf is unchanged"
}

# Unit-test the ownership probe: read-only, fail-safe and free of side effects
# even when the manifest is missing or corrupt. (A fully corrupt manifest makes
# the pre-existing rollback_component() abort, so the probe is exercised
# directly here rather than through the whole uninstall.)
test_keyd_managed_by_us_fail_safe() {
    local sandbox="/tmp/rollback-test-keyd-managed-probe"
    local case_name expected manifest before after actual
    for case_name in no_manifest corrupt no_services_key null_services \
        wrong_component keyd_service_name user_scope managed \
        keyd_service_name_missing_flags managed_missing_flags non_bool_flags \
        keyd_service_name_with_flags managed_with_flags; do
        setup_keyd_uninstall_sandbox "$sandbox"
        manifest="$sandbox/manifest/install-manifest.json"
        case "$case_name" in
            no_manifest) expected=0 ;;
            corrupt)
                printf 'this is not json' > "$manifest"
                expected=0
                ;;
            no_services_key)
                printf '{"version":"2.0","records":[]}' > "$manifest"
                expected=0
                ;;
            null_services)
                printf '{"version":"2.0","records":[],"services":null}' > "$manifest"
                expected=0
                ;;
            wrong_component)
                printf '{"version":"2.0","records":[],"services":[{"name":"keyd","component":"other"}]}' > "$manifest"
                expected=0
                ;;
            keyd_service_name)
                # Missing was_* flags means the original state is UNKNOWN:
                # never claim ownership (even for the name alias).
                printf '{"version":"2.0","records":[],"services":[{"name":"keyd.service","component":"keyboard"}]}' > "$manifest"
                expected=0
                ;;
            user_scope)
                # A user-scope record must not authorize disabling system keyd
                # (this is the scope the kbd backlight sync service uses).
                printf '{"version":"2.0","records":[],"services":[{"name":"keyd","component":"keyboard","scope":"user"}]}' > "$manifest"
                expected=0
                ;;
            managed)
                # Minimal record without was_* flags: UNKNOWN -> not managed.
                write_keyd_manifest "$sandbox" '[{"name":"keyd","component":"keyboard"}]'
                expected=0
                ;;
            keyd_service_name_missing_flags)
                printf '{"version":"2.0","records":[],"services":[{"name":"keyd.service","component":"keyboard","scope":"system"}]}' > "$manifest"
                expected=0
                ;;
            managed_missing_flags)
                write_keyd_manifest "$sandbox" '[{"name":"keyd","component":"keyboard","was_enabled":true}]'
                expected=0
                ;;
            non_bool_flags)
                # A string "false" is truthy in Python; the validator must
                # reject it and the probe must fail safe.
                printf '{"version":"2.0","records":[],"services":[{"name":"keyd","component":"keyboard","was_enabled":"false","was_active":true,"scope":"system"}]}' > "$manifest"
                expected=0
                ;;
            keyd_service_name_with_flags)
                printf '{"version":"2.0","records":[],"services":[{"name":"keyd.service","component":"keyboard","was_enabled":false,"was_active":true,"scope":"system"}]}' > "$manifest"
                expected=1
                ;;
            managed_with_flags)
                write_keyd_manifest "$sandbox" '[{"name":"keyd","component":"keyboard","was_enabled":true,"was_active":false,"scope":"system"}]'
                expected=1
                ;;
        esac
        if [ -f "$manifest" ]; then
            before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
        else
            before=ABSENT
        fi

        if ! actual="$(run_sandboxed "$sandbox" '
            source "$2/install-keyboard-sandbox.sh"
            _keyd_managed_by_us
        ')"; then
            fail "[$case_name] _keyd_managed_by_us must not crash"
            continue
        fi
        assert_eq "$expected" "$actual" "[$case_name] _keyd_managed_by_us result"
        if [ -f "$manifest" ]; then
            after="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
        else
            after=ABSENT
        fi
        assert_eq "$before" "$after" "[$case_name] _keyd_managed_by_us is read-only"
    done
}

test_uninstall_dryrun_keyd_ownership_messages() {
    local sandbox="/tmp/rollback-test-uninstall-dryrun-keyd"
    local case_name manifest before
    for case_name in unmanaged managed; do
        setup_keyd_uninstall_sandbox "$sandbox"
        manifest="$sandbox/manifest/install-manifest.json"
        if [ "$case_name" = "managed" ]; then
            write_keyd_manifest "$sandbox" \
                '[{"name":"keyd","component":"keyboard","was_enabled":true,"was_active":true,"scope":"system"}]'
        fi
        before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex() if __import__("os").path.exists(sys.argv[1]) else "ABSENT")' "$manifest")"
        : > "$sandbox/systemctl.log"

        if ! run_keyd_uninstall_dryrun "$sandbox"; then
            fail "[$case_name] dry-run uninstall must not crash"
            continue
        fi
        local log
        log="$(cat "$sandbox/systemctl.log")"
        if grep -qE '(^|[[:space:]])disable([[:space:]]|$).*keyd' <<< "$log"; then
            fail "[$case_name] dry-run must not actually disable keyd"
        else
            ok
        fi
        local after
        after="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex() if __import__("os").path.exists(sys.argv[1]) else "ABSENT")' "$manifest")"
        assert_eq "$before" "$after" "[$case_name] dry-run leaves the manifest byte-identical"
        if [ "$case_name" = "managed" ]; then
            assert_contains "Would disable project-managed keyd service (if active/enabled)" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
                "[$case_name] dry-run logs the managed disable"
        else
            assert_contains "Would leave keyd service untouched (no keyboard service record in manifest)" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
                "[$case_name] dry-run logs that the service is left untouched"
        fi
    done
}

# ---------------------------------------------------------------------------
# 35. P1 DATA SAFETY: a corrupt manifest must never be treated as an empty one
#     and overwritten. Readers/writers fail closed and leave the original bytes
#     untouched, so old backup/service/group records survive and a fresh V1
#     backup can never be mislabelled as the ORIGINAL.
# ---------------------------------------------------------------------------

test_keyd_corrupt_manifest_fails_closed() {
    local sandbox="/tmp/rollback-test-keyd-corrupt-manifest"
    setup_keyd_caller_sandbox "$sandbox" valid
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf '{not json' > "$manifest"
    local before
    before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"

    if run_keyd_caller "$sandbox" 1 0 0 0 2> "$sandbox/caller.log"; then
        fail "corrupt manifest: CLI must return 1"
    fi
    # The gate sits before backup_file(), so the keyd step keeps its snapshot
    # and marks it .failed with the usual "backup failed" reason.
    assert_keyd_backup_failure_fails_closed "$sandbox" "corrupt manifest" 0 0 "backup failed"
    local after
    after="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
    assert_eq "$before" "$after" "corrupt manifest: manifest bytes unchanged"
    local log
    log="$(cat "$sandbox/log.txt" 2> /dev/null || echo "")"
    assert_contains "MANIFEST_INVALID" "$log" "corrupt manifest: invalid manifest logged"
    assert_contains "corrupt/invalid" "$log" "corrupt manifest: log names the corrupt manifest"
}

test_keyd_reinstall_with_corrupt_manifest_keeps_first_backup() {
    local sandbox="/tmp/rollback-test-keyd-corrupt-reinstall"
    setup_keyd_caller_sandbox "$sandbox" valid
    printf 'ORIGINAL\n' > "$sandbox/etc/keyd/cros.conf"
    ln -s cros.conf "$sandbox/etc/keyd/default.conf"
    : > "$sandbox/systemctl.log"
    local manifest="$sandbox/manifest/install-manifest.json"

    if ! run_keyd_caller "$sandbox" 1 0 0 0 2> "$sandbox/caller1.log"; then
        fail "corrupt reinstall: first install must succeed"
        return 0
    fi
    local before after count backup_file
    printf 'V1_MODIFIED\n' > "$sandbox/etc/keyd/cros.conf"
    printf '{not json' > "$manifest"
    before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"

    if run_keyd_caller "$sandbox" 1 0 0 0 2> "$sandbox/caller2.log"; then
        fail "corrupt reinstall: second install must fail closed"
    fi
    assert_eq "1" "$(cat "$sandbox/install-rc.txt" 2> /dev/null || echo MISSING)" \
        "corrupt reinstall: CLI rc 1"
    after="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
    assert_eq "$before" "$after" "corrupt reinstall: corrupt manifest bytes unchanged"
    count="$(find "$sandbox/backups" -name cros.conf 2> /dev/null | wc -l | tr -d '[:space:]')"
    assert_eq "1" "$count" "corrupt reinstall: still exactly one cros.conf backup"
    backup_file="$(find "$sandbox/backups" -name cros.conf 2> /dev/null | head -n 1)"
    assert_eq "ORIGINAL" "$(cat "$backup_file" 2> /dev/null || echo MISSING)" \
        "corrupt reinstall: first backup still holds ORIGINAL"
    assert_eq "V1_MODIFIED" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "corrupt reinstall: live config left untouched"
}

test_corrupt_manifest_payloads_fail_closed() {
    local sandbox="/tmp/rollback-test-corrupt-payloads"
    local case_name payload before after tmp_count
    local manifest="$sandbox/manifest/install-manifest.json"
    for case_name in not_json truncated bad_records top_array bad_element bad_services; do
        rm -rf "$sandbox"
        mkdir -p "$sandbox/backups" "$sandbox/manifest"
        case "$case_name" in
            not_json) payload='{not json' ;;
            truncated) payload='{"records": [' ;;
            bad_records) payload='{"records": "bad"}' ;;
            top_array) payload='[]' ;;
            bad_element) payload='{"version":"2.0","records":[42],"services":[],"groups":[]}' ;;
            bad_services) payload='{"version":"2.0","records":[],"services":"bad","groups":[]}' ;;
        esac
        printf '%s' "$payload" > "$manifest"
        before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"

        run_sandboxed "$sandbox" '
            source "$1/lib/backup.sh"
            rc=0; manifest_has_target "/tmp/probe" || rc=$?; printf "%s\n" "$rc" > "$2/has-rc.txt"
            rc=0; manifest_add_entry "/tmp/probe" "demo" 0 || rc=$?; printf "%s\n" "$rc" > "$2/entry-rc.txt"
            rc=0; manifest_add_service "probe.service" "demo" || rc=$?; printf "%s\n" "$rc" > "$2/svc-rc.txt"
            rc=0; manifest_add_group "plugdev" "testuser" "demo" || rc=$?; printf "%s\n" "$rc" > "$2/grp-rc.txt"
        '
        assert_eq "2" "$(cat "$sandbox/has-rc.txt" 2> /dev/null || echo MISSING)" \
            "[$case_name] manifest_has_target fails closed with rc 2"
        assert_eq "1" "$(cat "$sandbox/entry-rc.txt" 2> /dev/null || echo MISSING)" \
            "[$case_name] manifest_add_entry returns 1"
        assert_eq "1" "$(cat "$sandbox/svc-rc.txt" 2> /dev/null || echo MISSING)" \
            "[$case_name] manifest_add_service returns 1"
        assert_eq "1" "$(cat "$sandbox/grp-rc.txt" 2> /dev/null || echo MISSING)" \
            "[$case_name] manifest_add_group returns 1"
        after="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
        assert_eq "$before" "$after" "[$case_name] corrupt manifest bytes unchanged"
        tmp_count="$(find "$sandbox/manifest" -name '*.tmp' 2> /dev/null | wc -l | tr -d '[:space:]')"
        assert_eq "0" "$tmp_count" "[$case_name] no .tmp file left behind"
    done
}

test_backup_manifest_aware_corrupt_fails_closed() {
    local sandbox="/tmp/rollback-test-corrupt-backup-gate"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    printf 'ORIGINAL\n' > "$sandbox/etc/demo.conf"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf '{not json' > "$manifest"
    local before after
    before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; backup_file_manifest_aware "$2/etc/demo.conf" "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/helper-rc.txt"
    '
    assert_eq "1" "$(cat "$sandbox/helper-rc.txt" 2> /dev/null || echo MISSING)" \
        "backup gate: corrupt manifest returns 1"
    assert_eq "0" "$(find "$sandbox/backups" -type f 2> /dev/null | wc -l | tr -d '[:space:]')" \
        "backup gate: no backup created"
    after="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
    assert_eq "$before" "$after" "backup gate: manifest bytes unchanged"
}

test_missing_manifest_still_creates_data() {
    local case_name sandbox
    for case_name in entry service group; do
        sandbox="/tmp/rollback-test-missing-manifest-$case_name"
        rm -rf "$sandbox"
        mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/stub"
        setup_keyd_stubs "$sandbox" none
        run_sandboxed "$sandbox" '
            export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
            source "$1/lib/backup.sh"
            case "$3" in
                entry) manifest_add_entry "/tmp/probe" "demo" 0 ;;
                service) manifest_add_service "probe.service" "demo" ;;
                group) manifest_add_group "plugdev" "testuser" "demo" ;;
            esac
            printf "%s\n" "$?" > "$2/writer-rc.txt"
            printf "%s\n" "$MANIFEST_CREATED" > "$2/created.txt"
        ' "$case_name"
        assert_eq "0" "$(cat "$sandbox/writer-rc.txt" 2> /dev/null || echo MISSING)" \
            "[$case_name] writer succeeds when the manifest is absent"
        assert_eq "1" "$(cat "$sandbox/created.txt" 2> /dev/null || echo MISSING)" \
            "[$case_name] manifest_load reports CREATED=1"
        local content
        content="$(cat "$sandbox/manifest/install-manifest.json" 2> /dev/null || echo MISSING)"
        case "$case_name" in
            entry) assert_contains '"target": "/tmp/probe"' "$content" "[$case_name] entry written to new manifest" ;;
            service) assert_contains '"name": "probe.service"' "$content" "[$case_name] service written to new manifest" ;;
            group) assert_contains '"group": "plugdev"' "$content" "[$case_name] group written to new manifest" ;;
        esac
    done
}

test_legacy_manifest_missing_optional_fields_is_accepted() {
    local sandbox="/tmp/rollback-test-legacy-optional"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf '%s' '{"version":"1.0","records":[{"target":"/tmp/legacy.conf","component":"demo","was_existing":true}]}' > "$manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; manifest_load || rc=$?; printf "%s\n" "$rc" > "$2/load-rc.txt"
        printf "%s\n" "$MANIFEST_CREATED" > "$2/created.txt"
        printf "%s\n" "$MANIFEST_JSON" > "$2/json.txt"
        rc=0; manifest_add_entry "/tmp/probe" "demo" 0 || rc=$?; printf "%s\n" "$rc" > "$2/write-rc.txt"
    '
    assert_eq "0" "$(cat "$sandbox/load-rc.txt" 2> /dev/null || echo MISSING)" \
        "legacy optional fields: manifest_load accepts v1.0"
    assert_eq "0" "$(cat "$sandbox/created.txt" 2> /dev/null || echo MISSING)" \
        "legacy optional fields: CREATED=0"
    assert_eq "0" "$(cat "$sandbox/write-rc.txt" 2> /dev/null || echo MISSING)" \
        "legacy optional fields: writer succeeds"
    local canonical
    canonical="$(cat "$sandbox/json.txt" 2> /dev/null || echo "")"
    assert_contains '"version":"1.0"' "$canonical" "legacy optional fields: canonical JSON keeps version"
    assert_contains '"services":[]' "$canonical" "legacy optional fields: services defaulted in canonical JSON"
    assert_contains '"groups":[]' "$canonical" "legacy optional fields: groups defaulted in canonical JSON"
    local result
    result="$(
        python3 - "$manifest" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("version"), len(d.get("services", [])), len(d.get("groups", [])), len(d.get("records", [])))
PY
    )"
    assert_eq "1.0 0 0 2" "$result" "legacy optional fields: version preserved, arrays filled, record appended"
}

test_corrupt_manifest_uninstall_does_not_touch_manifest() {
    local sandbox="/tmp/rollback-test-uninstall-corrupt-manifest"
    setup_keyd_uninstall_sandbox "$sandbox"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf '{not json' > "$manifest"
    local before after
    before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
    : > "$sandbox/systemctl.log"

    local rc=0
    run_keyd_uninstall "$sandbox" || rc=$?
    assert_eq "1" "$rc" "corrupt uninstall: rc 1 (no automatic rollback)"
    after="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
    assert_eq "$before" "$after" "corrupt uninstall: manifest bytes unchanged"
    local log
    log="$(cat "$sandbox/systemctl.log" 2> /dev/null || echo "")"
    if grep -qE '(^|[[:space:]])disable([[:space:]]|$).*keyd' <<< "$log"; then
        fail "corrupt uninstall: must not disable keyd without an ownership record"
    else
        ok
    fi
    assert_eq "USER_OWN_CONFIG" "$(cat "$sandbox/etc/keyd/cros.conf" 2> /dev/null || echo MISSING)" \
        "corrupt uninstall: cros.conf left untouched"
}

test_missing_manifest_without_python3_is_untracked() {
    # Regression: minimal/CI containers may have no python3.  With no manifest
    # on disk there is nothing to validate, so manifest_has_target() must return
    # 1 (untracked) without invoking python3.  Previously the probe exited 127
    # and was misread as a corrupt manifest (rc 2), which broke
    # `./setup.sh --all --dry-run` at the very first backup gate.
    local sandbox="/tmp/rollback-test-no-python3-no-manifest"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc" "$sandbox/failbin"
    printf 'ORIGINAL\n' > "$sandbox/etc/demo.conf"
    # Mimic a container without python3: any interpreter call exits 127.
    printf '#!/usr/bin/env bash\nexit 127\n' > "$sandbox/failbin/python3"
    chmod +x "$sandbox/failbin/python3"

    run_sandboxed "$sandbox" '
        export PATH="$2/failbin:$PATH"
        export DRY_RUN=1
        source "$1/lib/backup.sh"
        rc=0; manifest_has_target "$2/etc/demo.conf" || rc=$?
        printf "%s\n" "$rc" > "$2/has-rc.txt"
        printf "%s\n" "$MANIFEST_CREATED" > "$2/created.txt"
        rc=0; backup_file_manifest_aware "$2/etc/demo.conf" "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/aware-rc.txt"
    '
    assert_eq "1" "$(cat "$sandbox/has-rc.txt" 2> /dev/null || echo MISSING)" \
        "no-python3/no-manifest: manifest_has_target returns 1 (untracked)"
    assert_eq "1" "$(cat "$sandbox/created.txt" 2> /dev/null || echo MISSING)" \
        "no-python3/no-manifest: manifest_load reports CREATED=1"
    assert_eq "0" "$(cat "$sandbox/aware-rc.txt" 2> /dev/null || echo MISSING)" \
        "no-python3/no-manifest: dry-run backup gate succeeds"
    local log
    log="$(cat "$sandbox/log.txt" 2> /dev/null || echo "")"
    if grep -q 'corrupt/invalid' <<< "$log"; then
        fail "no-python3/no-manifest: no false corrupt/invalid diagnostic"
    else
        ok
    fi
    if [ -e "$sandbox/manifest/install-manifest.json" ]; then
        fail "no-python3/no-manifest: dry-run must not create a manifest"
    else
        ok
    fi

    # Fail-closed must be preserved: an EXISTING manifest still needs python3
    # for validation, so a failing interpreter must not be treated as "empty".
    local manifest="$sandbox/manifest/install-manifest.json"
    printf '%s' '{"version":"2.0","records":[],"services":[],"groups":[]}' > "$manifest"
    run_sandboxed "$sandbox" '
        export PATH="$2/failbin:$PATH"
        source "$1/lib/backup.sh"
        rc=0; manifest_has_target "$2/etc/demo.conf" || rc=$?
        printf "%s\n" "$rc" > "$2/present-has-rc.txt"
        rc=0; backup_file_manifest_aware "$2/etc/demo.conf" "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/present-aware-rc.txt"
    '
    assert_eq "2" "$(cat "$sandbox/present-has-rc.txt" 2> /dev/null || echo MISSING)" \
        "no-python3/present-manifest: manifest_has_target still fails closed with rc 2"
    assert_eq "1" "$(cat "$sandbox/present-aware-rc.txt" 2> /dev/null || echo MISSING)" \
        "no-python3/present-manifest: backup gate refuses with rc 1"
    assert_eq "0" "$(find "$sandbox/backups" -type f 2> /dev/null | wc -l | tr -d '[:space:]')" \
        "no-python3/present-manifest: no backup created"
}

# ---------------------------------------------------------------------------
# 36. Field-level manifest schema validation: well-formed JSON with a field of
#     the wrong type must fail closed everywhere (never repaired, never
#     treated as empty). Regression for re-review finding #3.
# ---------------------------------------------------------------------------

test_manifest_field_type_payloads_fail_closed() {
    local sandbox="/tmp/rollback-test-field-type-payloads"
    local case_name payload before after manifest
    manifest="$sandbox/manifest/install-manifest.json"
    for case_name in numeric_target relative_target empty_target nul_target \
        string_false_was_existing int_was_existing component_not_string \
        installed_at_not_string version_not_string service_name_not_string \
        service_component_not_string service_was_enabled_not_bool \
        service_scope_not_string group_name_not_string \
        group_was_member_not_bool record_missing_was_existing \
        service_missing_was_enabled service_missing_was_active \
        service_missing_both_was_flags group_missing_was_member; do
        rm -rf "$sandbox"
        mkdir -p "$sandbox/backups" "$sandbox/manifest"
        case "$case_name" in
            numeric_target)
                payload='{"version":"2.0","records":[{"target":12,"component":"keyboard","was_existing":true}],"services":[],"groups":[]}'
                ;;
            relative_target)
                payload='{"version":"2.0","records":[{"target":"etc/demo.conf","component":"keyboard","was_existing":true}],"services":[],"groups":[]}'
                ;;
            empty_target)
                payload='{"version":"2.0","records":[{"target":"","component":"keyboard","was_existing":true}],"services":[],"groups":[]}'
                ;;
            nul_target)
                # os.path.isabs("/tmp/x\x00evil") is True, but the rollback's
                # os.path.realpath() raises ValueError -> mid-rollback crash.
                payload='{"version":"2.0","records":[{"target":"/tmp/x\u0000evil","component":"keyboard","was_existing":true}],"services":[],"groups":[]}'
                ;;
            string_false_was_existing)
                payload='{"version":"2.0","records":[{"target":"/tmp/x","component":"keyboard","was_existing":"false"}],"services":[],"groups":[]}'
                ;;
            int_was_existing)
                payload='{"version":"2.0","records":[{"target":"/tmp/x","component":"keyboard","was_existing":1}],"services":[],"groups":[]}'
                ;;
            component_not_string)
                payload='{"version":"2.0","records":[{"target":"/tmp/x","component":12,"was_existing":true}],"services":[],"groups":[]}'
                ;;
            installed_at_not_string)
                payload='{"version":"2.0","records":[{"target":"/tmp/x","component":"keyboard","was_existing":true,"installed_at":99}],"services":[],"groups":[]}'
                ;;
            version_not_string)
                payload='{"version":2.0,"records":[],"services":[],"groups":[]}'
                ;;
            service_name_not_string)
                payload='{"version":"2.0","records":[],"services":[{"name":12,"component":"keyboard","was_enabled":true,"was_active":true}],"groups":[]}'
                ;;
            service_component_not_string)
                payload='{"version":"2.0","records":[],"services":[{"name":"probe.service","component":[],"was_enabled":true,"was_active":true}],"groups":[]}'
                ;;
            service_was_enabled_not_bool)
                payload='{"version":"2.0","records":[],"services":[{"name":"probe.service","component":"keyboard","was_enabled":"true","was_active":true}],"groups":[]}'
                ;;
            service_scope_not_string)
                payload='{"version":"2.0","records":[],"services":[{"name":"probe.service","component":"keyboard","was_enabled":true,"was_active":true,"scope":7}],"groups":[]}'
                ;;
            group_name_not_string)
                payload='{"version":"2.0","records":[],"services":[],"groups":[{"group":12,"user":"u","component":"demo","was_member":true}]}'
                ;;
            group_was_member_not_bool)
                payload='{"version":"2.0","records":[],"services":[],"groups":[{"group":"plugdev","user":"u","component":"demo","was_member":"false"}]}'
                ;;
            # Safety-decision fields are REQUIRED: omitting one is "unknown",
            # not false. All real writers (v1.0 and v2.0) always emit them.
            record_missing_was_existing)
                payload='{"version":"2.0","records":[{"target":"/tmp/x","component":"keyboard"}],"services":[],"groups":[]}'
                ;;
            service_missing_was_enabled)
                payload='{"version":"2.0","records":[],"services":[{"name":"keyd","component":"keyboard","was_active":true}],"groups":[]}'
                ;;
            service_missing_was_active)
                payload='{"version":"2.0","records":[],"services":[{"name":"keyd","component":"keyboard","was_enabled":true}],"groups":[]}'
                ;;
            service_missing_both_was_flags)
                payload='{"version":"2.0","records":[],"services":[{"name":"keyd","component":"keyboard"}],"groups":[]}'
                ;;
            group_missing_was_member)
                payload='{"version":"2.0","records":[],"services":[],"groups":[{"group":"plugdev","user":"u","component":"demo"}]}'
                ;;
        esac
        printf '%s' "$payload" > "$manifest"
        before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"

        run_sandboxed "$sandbox" '
            source "$1/lib/backup.sh"
            rc=0; manifest_load || rc=$?; printf "%s\n" "$rc" > "$2/load-rc.txt"
            printf "%s\n" "$MANIFEST_CREATED" > "$2/created.txt"
            printf "%s\n" "$MANIFEST_JSON" > "$2/json.txt"
            rc=0; manifest_has_target "/tmp/probe" || rc=$?; printf "%s\n" "$rc" > "$2/has-rc.txt"
            rc=0; manifest_add_entry "/tmp/probe" "demo" 0 || rc=$?; printf "%s\n" "$rc" > "$2/entry-rc.txt"
            rc=0; manifest_add_service "probe.service" "demo" || rc=$?; printf "%s\n" "$rc" > "$2/svc-rc.txt"
            rc=0; manifest_add_group "plugdev" "testuser" "demo" || rc=$?; printf "%s\n" "$rc" > "$2/grp-rc.txt"
        '
        assert_eq "1" "$(cat "$sandbox/load-rc.txt")" "[$case_name] manifest_load rc 1"
        assert_eq "0" "$(cat "$sandbox/created.txt")" "[$case_name] CREATED=0"
        assert_eq "" "$(cat "$sandbox/json.txt")" "[$case_name] MANIFEST_JSON empty"
        assert_eq "2" "$(cat "$sandbox/has-rc.txt")" "[$case_name] has_target rc 2"
        assert_eq "1" "$(cat "$sandbox/entry-rc.txt")" "[$case_name] add_entry rc 1"
        assert_eq "1" "$(cat "$sandbox/svc-rc.txt")" "[$case_name] add_service rc 1"
        assert_eq "1" "$(cat "$sandbox/grp-rc.txt")" "[$case_name] add_group rc 1"
        after="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
        assert_eq "$before" "$after" "[$case_name] manifest bytes unchanged"
        assert_eq "0" "$(find "$sandbox/manifest" -name '*.tmp' | wc -l | tr -d '[:space:]')" \
            "[$case_name] no .tmp"
        assert_contains "MANIFEST_INVALID" "$(tr -d '\000' < "$sandbox/log.txt")" \
            "[$case_name] MANIFEST_INVALID logged"
    done
}

test_schema_invalid_manifest_rollback_has_no_side_effects() {
    local sandbox="/tmp/rollback-test-schema-invalid-rollback"
    setup_keyd_caller_sandbox "$sandbox" valid
    mkdir -p "$sandbox/etc"
    printf 'ORIGINAL\n' > "$sandbox/etc/demo.conf"
    : > "$sandbox/systemctl.log"
    local manifest="$sandbox/manifest/install-manifest.json"
    # A well-formed service record is listed FIRST: the old rollback restored
    # services before files, so without the fail-closed gate it would modify
    # probe.service and then throw TypeError on target=12. Several fields are
    # invalid at once here; the validator rejects target=12 first, so the
    # was_member="false" trap is not exercised independently.
    python3 - "$manifest" << 'PY'
import json, sys
d = {"version": "2.0",
     "services": [{"name": "probe.service", "component": "demo",
                   "was_enabled": True, "was_active": False, "scope": "system"}],
     "records": [{"target": 12, "component": "demo", "was_existing": True}],
     "groups": [{"group": "plugdev", "user": "testuser", "component": "demo",
                 "was_member": "false"}]}
with open(sys.argv[1], "w") as f:
    json.dump(d, f, indent=2)
PY
    local before before_file
    before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
    before_file="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$sandbox/etc/demo.conf")"

    local rc=0
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    rc="$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)"
    assert_eq "1" "$rc" "schema-invalid rollback: rc 1"
    if grep -q 'probe.service' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "schema-invalid rollback: service must NOT be touched before failing"
    else
        ok
    fi
    assert_eq "$before_file" \
        "$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$sandbox/etc/demo.conf")" \
        "schema-invalid rollback: file bytes unchanged"
    assert_eq "$before" \
        "$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")" \
        "schema-invalid rollback: manifest bytes unchanged (no rewrite)"
    assert_contains "MANIFEST_INVALID" "$(cat "$sandbox/rollback.log")" \
        "schema-invalid rollback: MANIFEST_INVALID logged"
    assert_eq "0" "$(find "$sandbox/manifest" -name '*.tmp' | wc -l | tr -d '[:space:]')" \
        "schema-invalid rollback: no .tmp"
}

test_schema_optional_fields_and_roundtrip_accepted() {
    local sandbox="/tmp/rollback-test-schema-optional"
    local case_name payload
    for case_name in legacy_service legacy_record_no_component group_all_required_fields; do
        rm -rf "$sandbox"
        mkdir -p "$sandbox/backups" "$sandbox/manifest"
        case "$case_name" in
            legacy_service)
                # Real v1/v2 writers ALWAYS emit the was_* safety flags; the
                # only genuinely optional service field is `scope` (added
                # later for user-scope services). A service record without
                # was_enabled/was_active is UNKNOWN, not legacy.
                payload='{"version":"1.0","records":[],"services":[{"name":"keyd","component":"keyboard","was_enabled":true,"was_active":false}]}'
                ;;
            legacy_record_no_component)
                payload='{"version":"2.0","records":[{"target":"/tmp/x","was_existing":true}],"services":[],"groups":[]}'
                ;;
            group_all_required_fields)
                # Groups have no optional fields; was_member is a safety flag
                # and must be present. The legacy tolerance here is for the
                # missing top-level arrays, not for missing was_member.
                payload='{"version":"2.0","records":[],"services":[],"groups":[{"group":"plugdev","user":"u","component":"demo","was_member":true}]}'
                ;;
        esac
        printf '%s' "$payload" > "$sandbox/manifest/install-manifest.json"
        run_sandboxed "$sandbox" '
            source "$1/lib/backup.sh"
            rc=0; manifest_load || rc=$?; printf "%s\n" "$rc" > "$2/load-rc.txt"
        '
        assert_eq "0" "$(cat "$sandbox/load-rc.txt")" \
            "[$case_name] optional/absent fields accepted"
    done

    # Round trip: a manifest written by our own writers must pass the very
    # same validator (no "self-invalidating" manifest).
    rm -rf "$sandbox"
    setup_keyd_stubs "$sandbox" none
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    printf 'ORIGINAL\n' > "$sandbox/etc/demo.conf"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$1/lib/backup.sh"
        rc=0; backup_file_manifest_aware "$2/etc/demo.conf" "demo" || rc=$?; printf "%s\n" "$rc" > "$2/aware-rc.txt"
        rc=0; manifest_add_service "probe.service" "demo" || rc=$?; printf "%s\n" "$rc" > "$2/svc-rc.txt"
        rc=0; manifest_add_group "plugdev" "testuser" "demo" || rc=$?; printf "%s\n" "$rc" > "$2/grp-rc.txt"
        rc=0; manifest_load || rc=$?; printf "%s\n" "$rc" > "$2/load-rc.txt"
        printf "%s\n" "$MANIFEST_JSON" > "$2/json.txt"
    '
    assert_eq "0" "$(cat "$sandbox/aware-rc.txt" 2> /dev/null || echo MISSING)" \
        "round-trip: backup_file_manifest_aware succeeds"
    assert_eq "0" "$(cat "$sandbox/svc-rc.txt" 2> /dev/null || echo MISSING)" \
        "round-trip: manifest_add_service succeeds"
    assert_eq "0" "$(cat "$sandbox/grp-rc.txt" 2> /dev/null || echo MISSING)" \
        "round-trip: manifest_add_group succeeds"
    assert_eq "0" "$(cat "$sandbox/load-rc.txt" 2> /dev/null || echo MISSING)" \
        "round-trip: our own manifest validates"
    local canonical
    canonical="$(cat "$sandbox/json.txt" 2> /dev/null || echo "")"
    assert_contains '"version":"2.0"' "$canonical" "round-trip: canonical JSON keeps version"
    local result
    result="$(
        python3 - "$sandbox/manifest/install-manifest.json" "$sandbox/etc/demo.conf" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
target = sys.argv[2]
print(len(d.get("records", [])), len(d.get("services", [])), len(d.get("groups", [])),
      int(any(r.get("target") == target for r in d.get("records", []))),
      int(any(s.get("name") == "probe.service" for s in d.get("services", []))),
      int(any(g.get("group") == "plugdev" for g in d.get("groups", []))))
PY
    )"
    assert_eq "1 1 1 1 1 1" "$result" \
        "round-trip: file/service/group records all present and accepted"
}

test_uninstall_schema_invalid_manifest_does_not_touch_services() {
    local sandbox="/tmp/rollback-test-uninstall-schema-invalid"
    setup_keyd_uninstall_sandbox "$sandbox"
    local manifest="$sandbox/manifest/install-manifest.json"
    # was_enabled as a string is truthy in Python: without the uninstall gate,
    # _keyd_managed_by_us() would still claim ownership and disable keyd before
    # rollback ever sees the invalid manifest.
    printf '%s' '{"version":"2.0","records":[],"services":[{"name":"keyd","component":"keyboard","was_enabled":"false","was_active":true,"scope":"system"}],"groups":[]}' > "$manifest"
    local before
    before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
    : > "$sandbox/systemctl.log"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        rc=0; uninstall_keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/uninstall-rc.txt"
    '
    assert_eq "1" "$(cat "$sandbox/uninstall-rc.txt" 2> /dev/null || echo MISSING)" \
        "schema-invalid uninstall: rc 1"
    if grep -qE '(^|[[:space:]])disable([[:space:]]|$).*keyd' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "schema-invalid uninstall: must not disable keyd"
    else
        ok
    fi
    assert_eq "$before" \
        "$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")" \
        "schema-invalid uninstall: manifest bytes unchanged"
}

# ---------------------------------------------------------------------------
# 37. P0: pseudo-targets (fingerprint's "package:libfprint-crfpmoc" record) must
#     never poison our own manifest. manifest_add_entry skips non-absolute
#     targets so the next load / backup gate / rollback still works.
# ---------------------------------------------------------------------------

test_non_absolute_manifest_entries_are_skipped() {
    local sandbox="/tmp/rollback-test-nonabsolute-entry"
    local manifest="$sandbox/manifest/install-manifest.json"
    local target before after

    # (a) Exact reviewer reproduction: no manifest yet, then fingerprint's
    # prebuilt-package pseudo-target. add_entry succeeds (no consumer depends
    # on the record), writes nothing, and load + backup gate still return 0.
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    printf 'ORIGINAL\n' > "$sandbox/etc/demo.conf"
    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; manifest_add_entry "package:libfprint-crfpmoc" "fingerprint" "0" || rc=$?; printf "%s\n" "$rc" > "$2/entry-rc.txt"
        rc=0; manifest_load || rc=$?; printf "%s\n" "$rc" > "$2/load-rc.txt"
        rc=0; DRY_RUN=1 backup_file_manifest_aware "$2/etc/demo.conf" "demo" || rc=$?; printf "%s\n" "$rc" > "$2/aware-rc.txt"
    '
    assert_eq "0" "$(cat "$sandbox/entry-rc.txt" 2> /dev/null || echo MISSING)" \
        "pseudo-target: add_entry still returns 0"
    assert_eq "0" "$(cat "$sandbox/load-rc.txt" 2> /dev/null || echo MISSING)" \
        "pseudo-target: next manifest_load returns 0"
    assert_eq "0" "$(cat "$sandbox/aware-rc.txt" 2> /dev/null || echo MISSING)" \
        "pseudo-target: backup gate returns 0"
    if [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; then
        ok
    else
        fail "pseudo-target: no manifest should be written for a skipped entry"
    fi
    assert_contains "skipping manifest entry with non-absolute target: package:libfprint-crfpmoc" \
        "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "pseudo-target: skip is logged"

    # (b) An existing valid manifest must stay byte-identical for every kind
    # of non-absolute target (pseudo-target, empty, relative).
    for case_name in pseudo_target empty_target relative_target; do
        rm -rf "$sandbox"
        mkdir -p "$sandbox/backups" "$sandbox/manifest"
        printf '%s' '{"version":"2.0","records":[{"target":"/tmp/keep","component":"demo","was_existing":true}],"services":[],"groups":[]}' > "$manifest"
        before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
        case "$case_name" in
            pseudo_target) target="package:libfprint-crfpmoc" ;;
            empty_target) target="" ;;
            relative_target) target="etc/demo.conf" ;;
        esac
        run_sandboxed "$sandbox" '
            source "$1/lib/backup.sh"
            rc=0; manifest_add_entry "$3" "fingerprint" "0" || rc=$?; printf "%s\n" "$rc" > "$2/entry-rc.txt"
            rc=0; manifest_load || rc=$?; printf "%s\n" "$rc" > "$2/load-rc.txt"
        ' "$target"
        assert_eq "0" "$(cat "$sandbox/entry-rc.txt" 2> /dev/null || echo MISSING)" \
            "[$case_name] add_entry returns 0"
        assert_eq "0" "$(cat "$sandbox/load-rc.txt" 2> /dev/null || echo MISSING)" \
            "[$case_name] manifest still validates"
        after="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
        assert_eq "$before" "$after" "[$case_name] manifest bytes unchanged"
        assert_contains "skipping manifest entry with non-absolute target" \
            "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
            "[$case_name] skip is logged"
    done
}

# ---------------------------------------------------------------------------
# 38. P1: a target with an embedded NUL passes os.path.isabs() but crashes
#     os.path.realpath() in rollback. It must be rejected at the gate, before
#     any service/file mutation.
# ---------------------------------------------------------------------------

test_nul_target_rollback_has_no_service_side_effects() {
    local sandbox="/tmp/rollback-test-nul-rollback"
    setup_keyd_caller_sandbox "$sandbox" valid
    mkdir -p "$sandbox/etc"
    printf 'ORIGINAL\n' > "$sandbox/etc/demo.conf"
    : > "$sandbox/systemctl.log"
    local manifest="$sandbox/manifest/install-manifest.json"
    python3 - "$manifest" << 'PY'
import json, sys
d = {"version": "2.0",
     "records": [{"target": "/tmp/x\u0000evil", "component": "demo", "was_existing": True}],
     "services": [{"name": "probe.service", "component": "demo",
                   "was_enabled": True, "was_active": True, "scope": "system"}],
     "groups": []}
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
    local before before_file
    before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
    before_file="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$sandbox/etc/demo.conf")"

    local rc=0
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "nul rollback: rc 1"
    if grep -q 'probe.service' "$sandbox/systemctl.log" 2> /dev/null; then
        fail "nul rollback: service must NOT be touched before failing"
    else
        ok
    fi
    assert_eq "$before_file" \
        "$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$sandbox/etc/demo.conf")" \
        "nul rollback: file bytes unchanged"
    assert_eq "$before" \
        "$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")" \
        "nul rollback: manifest bytes unchanged"
    assert_contains "MANIFEST_INVALID" "$(tr -d '\000' < "$sandbox/rollback.log")" \
        "nul rollback: MANIFEST_INVALID logged"
    assert_eq "0" "$(find "$sandbox/manifest" -name '*.tmp' | wc -l | tr -d '[:space:]')" \
        "nul rollback: no .tmp"
}

# ---------------------------------------------------------------------------
# 39. P2: the fail-closed manifest gate sits BEFORE the DRY_RUN early exit.
#     With an existing manifest and no python3, rollback must still return 1
#     (never a misleading "would rollback" success).
# ---------------------------------------------------------------------------

test_missing_python3_existing_manifest_dryrun_rollback_fails_closed() {
    local sandbox="/tmp/rollback-test-no-python3-dryrun-rollback"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc" \
        "$sandbox/failbin" "$sandbox/stub"
    printf 'ORIGINAL\n' > "$sandbox/etc/demo.conf"
    printf '#!/usr/bin/env bash\nexit 127\n' > "$sandbox/failbin/python3"
    chmod +x "$sandbox/failbin/python3"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${STUB_SYSTEMCTL_LOG:?}"\nexit 0\n' > "$sandbox/stub/systemctl"
    chmod +x "$sandbox/stub/systemctl"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf '%s' '{"version":"2.0","records":[],"services":[{"name":"probe.service","component":"demo","was_enabled":true,"was_active":true,"scope":"system"}],"groups":[]}' > "$manifest"
    local before
    before="$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")"
    : > "$sandbox/systemctl.log"

    run_sandboxed "$sandbox" '
        export PATH="$2/failbin:$PATH" DRY_RUN=1 STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "no-python3/dry-run rollback: rc 1 (gate before DRY_RUN)"
    if grep -q 'probe.service' "$sandbox/systemctl.log"; then
        fail "no-python3/dry-run rollback: service must not be touched"
    else
        ok
    fi
    assert_eq "$before" \
        "$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().hex())' "$manifest")" \
        "no-python3/dry-run rollback: manifest bytes unchanged"
    assert_contains "MANIFEST_INVALID" "$(cat "$sandbox/rollback.log")" \
        "no-python3/dry-run rollback: MANIFEST_INVALID logged"
}

# ---------------------------------------------------------------------------
# 40. The rollback python pipeline's rc must be propagated: a crash must not
#     be reported as a successful rollback. The validator uses 3 args and the
#     rollback pipeline 6 (stub contract); only the latter is refused here.
# ---------------------------------------------------------------------------

test_rollback_python_failure_returns_nonzero() {
    local sandbox="/tmp/rollback-test-rollback-python-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    local manifest="$sandbox/manifest/install-manifest.json"
    printf '%s' '{"version":"2.0","records":[],"services":[{"name":"probe.service","component":"demo","was_enabled":true,"was_active":true,"scope":"system"}],"groups":[]}' > "$manifest"
    : > "$sandbox/systemctl.log"
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -ge 6 ]; then
    printf 'STUB: rollback python refused\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/python3"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "rollback python failure: rc 1"
    assert_contains "rollback of demo failed" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "rollback python failure: error logged"
    if grep -qF "finished!" "$sandbox/log.txt"; then
        fail "rollback python failure: no success line may be printed"
    else
        ok
    fi
    if grep -q 'probe.service' "$sandbox/systemctl.log"; then
        fail "rollback python failure: service must not be touched"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 41. Finding #1: a missing safety-decision field is UNKNOWN, never false.
#     The validator rejects it before any side effect; the rollback python
#     repeats the check as defence in depth (test 41c).
# ---------------------------------------------------------------------------

test_missing_was_existing_record_never_deletes_file() {
    local sandbox="/tmp/rollback-test-missing-was-existing"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc/udev/hwdb.d"
    local file="$sandbox/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf 'USER_ORIGINAL\n' > "$file"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$file\",\"component\":\"keyboard\"}],\"services\":[],\"groups\":[]}" > "$manifest"
    local before
    before="$(file_hex "$file")"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; rollback_component "keyboard" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"

    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "missing was_existing: rollback rc 1"
    assert_eq "$before" "$(file_hex "$file")" "missing was_existing: file bytes unchanged"
    assert_eq "1" "$(manifest_count "$manifest" records)" "missing was_existing: record retained"
    if [ -f "$file" ]; then ok; else fail "missing was_existing: file must still exist"; fi
    assert_contains "MANIFEST_INVALID" "$(cat "$sandbox/rollback.log")" \
        "missing was_existing: MANIFEST_INVALID logged"
    assert_eq "0" "$(find "$sandbox/manifest" -name '*.tmp' | wc -l | tr -d '[:space:]')" \
        "missing was_existing: no .tmp"
}

test_missing_service_flags_never_disables_or_stops() {
    local sandbox="/tmp/rollback-test-missing-svc-flags"
    setup_keyd_uninstall_sandbox "$sandbox"
    : > "$sandbox/systemctl.log"
    write_keyd_manifest "$sandbox" '[{"name":"keyd","component":"keyboard"}]'
    local manifest="$sandbox/manifest/install-manifest.json"
    local before
    before="$(file_hex "$manifest")"

    # Full uninstall path: the gate at uninstall_keyboard() must fire BEFORE
    # _keyd_managed_by_us()/systemctl disable --now keyd (reviewer example B).
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        rc=0; uninstall_keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/uninstall-rc.txt"
    ' 2> "$sandbox/uninstall.log"
    assert_eq "1" "$(cat "$sandbox/uninstall-rc.txt" 2> /dev/null || echo MISSING)" \
        "missing service flags: uninstall rc 1"
    if grep -qE '(^|[[:space:]])disable([[:space:]]|$).*keyd' "$sandbox/systemctl.log"; then
        fail "missing service flags: uninstall must not disable keyd"
    else
        ok
    fi
    if grep -qE '(^|[[:space:]])stop([[:space:]]|$).*keyd' "$sandbox/systemctl.log"; then
        fail "missing service flags: uninstall must not stop keyd"
    else
        ok
    fi
    assert_eq "$before" "$(file_hex "$manifest")" \
        "missing service flags: uninstall leaves manifest bytes unchanged"

    # Direct rollback path: the validator gate must fire here too.
    : > "$sandbox/systemctl.log"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "keyboard" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "missing service flags: direct rollback rc 1"
    assert_eq "1" "$(manifest_count "$manifest" services)" \
        "missing service flags: service record retained"
    if grep -qE '(^|[[:space:]])disable([[:space:]]|$).*keyd' "$sandbox/systemctl.log"; then
        fail "missing service flags: direct rollback must not disable keyd"
    else
        ok
    fi
    if grep -qE '(^|[[:space:]])stop([[:space:]]|$).*keyd' "$sandbox/systemctl.log"; then
        fail "missing service flags: direct rollback must not stop keyd"
    else
        ok
    fi
}

test_rollback_python_unknown_state_is_fail_closed_without_validator() {
    local sandbox="/tmp/rollback-test-unknown-state-injected"
    setup_keyd_caller_sandbox "$sandbox" valid
    mkdir -p "$sandbox/etc"
    local file="$sandbox/etc/demo.conf"
    local manifest="$sandbox/manifest/install-manifest.json"
    local injected="$sandbox/injected.json"
    printf 'USER_ORIGINAL\n' > "$file"
    # The on-disk manifest passes the validator gate; the python3 stub feeds
    # the rollback python a DIFFERENT document with missing safety fields.
    printf '%s' '{"version":"2.0","records":[],"services":[],"groups":[]}' > "$manifest"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$file\",\"component\":\"demo\"}],\"services\":[{\"name\":\"keyd\",\"component\":\"demo\"}],\"groups\":[]}" > "$injected"
    : > "$sandbox/systemctl.log"
    local before
    before="$(file_hex "$file")"
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
# validator: 3 args; rollback pipeline: 6 args. Only substitute stdin for the
# latter so the fail-closed gate still runs against the real on-disk manifest.
if [ "$1" = "-c" ] && [ "$#" -ge 6 ]; then
    exec /usr/bin/python3 "$@" < "${STUB_INJECT_MANIFEST:?}"
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/python3"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_INJECT_MANIFEST="$2/injected.json"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"

    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "injected unknown state: rollback rc 1"
    assert_eq "$before" "$(file_hex "$file")" \
        "injected unknown state: file bytes unchanged (no delete/restore)"
    if grep -qE '(^|[[:space:]])disable([[:space:]]|$).*keyd' "$sandbox/systemctl.log"; then
        fail "injected unknown state: must not disable keyd"
    else
        ok
    fi
    if grep -qE '(^|[[:space:]])stop([[:space:]]|$).*keyd' "$sandbox/systemctl.log"; then
        fail "injected unknown state: must not stop keyd"
    else
        ok
    fi
    assert_eq "1" "$(manifest_count "$manifest" records)" \
        "injected unknown state: record retained in written-back manifest"
    assert_eq "1" "$(manifest_count "$manifest" services)" \
        "injected unknown state: service record retained in written-back manifest"
    assert_contains "UNKNOWN ORIGINAL STATE" "$(cat "$sandbox/rollback.log")" \
        "injected unknown state: UNKNOWN ORIGINAL STATE warning"
    assert_contains "RECORD_STATE_UNKNOWN" "$(cat "$sandbox/rollback.log")" \
        "injected unknown state: RECORD_STATE_UNKNOWN marker"
    assert_contains "SERVICE_STATE_UNKNOWN" "$(cat "$sandbox/rollback.log")" \
        "injected unknown state: SERVICE_STATE_UNKNOWN marker"
    if grep -qF "finished!" "$sandbox/log.txt"; then
        fail "injected unknown state: no success line may be printed"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 42. Finding #2: restore the original from the FIRST backup even when the
#     installed target has disappeared. Only a confirmed success consumes a
#     record; a missing backup keeps it (but is not an error, as before).
# ---------------------------------------------------------------------------

test_rollback_absent_target_restores_first_backup_file() {
    local sandbox="/tmp/rollback-test-absent-restore"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    local file="$sandbox/etc/demo.conf"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf 'ORIGINAL\n' > "$file"
    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        backup_file_manifest_aware "$2/etc/demo.conf" "demo"
    '
    printf 'CUSTOM\n' > "$file"
    rm -f "$file"
    if [ -e "$file" ] || [ -L "$file" ]; then
        fail "absent target setup: installed file must be gone before rollback"
    else
        ok
    fi

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' > "$sandbox/rollback.log" 2>&1
    assert_eq "0" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "absent target + backup: rollback rc 0"
    assert_eq "ORIGINAL" "$(cat "$file" 2> /dev/null || echo MISSING)" \
        "absent target + backup: ORIGINAL restored"
    assert_eq "0" "$(manifest_count "$manifest" records)" \
        "absent target + backup: record consumed after successful restore"
    assert_contains "[RESTORED PREVIOUS BACKUP]" "$(cat "$sandbox/rollback.log")" \
        "absent target + backup: restore log emitted"
}

test_rollback_absent_target_restores_first_backup_symlink() {
    local sandbox="/tmp/rollback-test-absent-symlink"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    local link="$sandbox/etc/liblink"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf 'TARGET-BODY\n' > "$sandbox/etc/real-file"
    ln -s real-file "$link"
    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        backup_file_manifest_aware "$2/etc/liblink" "demo"
    '
    rm -f "$link"
    if [ -e "$link" ] || [ -L "$link" ]; then
        fail "absent symlink setup: link must be gone before rollback"
    else
        ok
    fi

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "0" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "absent symlink + backup: rollback rc 0"
    if [ -L "$link" ]; then ok; else fail "absent symlink + backup: link restored"; fi
    assert_eq "real-file" "$(readlink "$link" 2> /dev/null || echo MISSING)" \
        "absent symlink + backup: islink checked before isdir/copy"
    assert_eq "0" "$(manifest_count "$manifest" records)" \
        "absent symlink + backup: record consumed"
}

test_rollback_absent_target_no_backup_keeps_record() {
    local sandbox="/tmp/rollback-test-absent-no-backup"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    local file="$sandbox/etc/demo.conf"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$file\",\"component\":\"demo\",\"was_existing\":true}],\"services\":[],\"groups\":[]}" > "$manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "absent target + no backup: rollback rc 1 (missing original is a failure)"
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
        ok
    else
        fail "absent target + no backup: must not invent a file"
    fi
    assert_eq "1" "$(manifest_count "$manifest" records)" \
        "absent target + no backup: record retained"
    assert_contains "[WARN NO BACKUP]" "$(cat "$sandbox/rollback.log")" \
        "absent target + no backup: warning emitted"
    assert_contains "RECORD_BACKUP_MISSING" "$(cat "$sandbox/rollback.log")" \
        "absent target + no backup: problem marker emitted"
    assert_contains "ROLLBACK_INCOMPLETE: 1 item(s) retained" "$(cat "$sandbox/rollback.log")" \
        "absent target + no backup: python reports incomplete"
    assert_contains "rollback of demo failed" "$(cat "$sandbox/log.txt" 2> /dev/null || echo '')" \
        "absent target + no backup: shell log_error emitted"
    assert_not_contains "finished!" "$(cat "$sandbox/log.txt" 2> /dev/null || echo '')" \
        "absent target + no backup: no success line"
    assert_eq "0" "$(find "$sandbox/manifest" -name '*.tmp' | wc -l | tr -d '[:space:]')" \
        "absent target + no backup: no .tmp"
}

test_rollback_mixed_missing_backup_and_success() {
    local sandbox="/tmp/rollback-test-mixed-no-backup"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    local missing="$sandbox/etc/missing.conf"
    local okfile="$sandbox/etc/ok.conf"
    local manifest="$sandbox/manifest/install-manifest.json"
    local ts="20260101_000000000000000"
    # Only the second record has a backup; the first one must be kept for retry.
    mkdir -p "$sandbox/backups/$ts${okfile%/*}"
    printf 'ORIGINAL-OK\n' > "$sandbox/backups/$ts$okfile"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$missing\",\"component\":\"demo\",\"was_existing\":true},{\"target\":\"$okfile\",\"component\":\"demo\",\"was_existing\":true}],\"services\":[],\"groups\":[]}" > "$manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' > "$sandbox/rollback.log" 2>&1

    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "mixed: one missing backup makes the whole rollback non-zero"
    assert_eq "1" "$(manifest_count "$manifest" records)" \
        "mixed: only the missing-backup record is retained"
    assert_contains "$missing" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["records"][0]["target"])' "$manifest")" \
        "mixed: retained record is the missing-backup one"
    assert_eq "ORIGINAL-OK" "$(cat "$okfile" 2> /dev/null || echo MISSING)" \
        "mixed: the backed-up record still restored normally"
    if [ ! -e "$missing" ] && [ ! -L "$missing" ]; then
        ok
    else
        fail "mixed: no file invented for the missing-backup record"
    fi
    local marker_line
    marker_line="$(grep -F 'RECORD_BACKUP_MISSING' "$sandbox/rollback.log" || true)"
    assert_contains "target=$missing" "$marker_line" \
        "mixed: backup-missing marker names the failed record"
    assert_not_contains "target=$okfile" "$marker_line" \
        "mixed: the restored record is not marked as backup-missing"
    assert_contains "RESTORED PREVIOUS BACKUP" "$(cat "$sandbox/rollback.log")" \
        "mixed: successful restore still logged"
    assert_contains "ROLLBACK_INCOMPLETE: 1 item(s) retained" "$(cat "$sandbox/rollback.log")" \
        "mixed: incomplete count is one"
    assert_not_contains "finished!" "$(cat "$sandbox/log.txt" 2> /dev/null || echo '')" \
        "mixed: no success line"
}

test_rollback_absent_target_was_existing_false_is_safe_noop() {
    local sandbox="/tmp/rollback-test-absent-was-false"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    local file="$sandbox/etc/demo.conf"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$file\",\"component\":\"demo\",\"was_existing\":false}],\"services\":[],\"groups\":[]}" > "$manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "0" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "absent target + was_existing=false: rollback rc 0"
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
        ok
    else
        fail "absent target + was_existing=false: no file should be created"
    fi
    assert_eq "0" "$(manifest_count "$manifest" records)" \
        "absent target + was_existing=false: safe no-op consumes record"
}

test_rollback_absent_target_restore_failure_keeps_record() {
    local sandbox="/tmp/rollback-test-absent-restore-fail"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    local file="$sandbox/blocker/etc/demo.conf"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf 'blocker\n' > "$sandbox/blocker"
    # Place a valid first backup at the exact path rollback will glob.
    local ts="20260101_000000000000"
    mkdir -p "$sandbox/backups/$ts${file%/*}"
    printf 'ORIGINAL\n' > "$sandbox/backups/$ts$file"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$file\",\"component\":\"demo\",\"was_existing\":true}],\"services\":[],\"groups\":[]}" > "$manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "restore failure: rollback rc 1"
    assert_eq "1" "$(manifest_count "$manifest" records)" \
        "restore failure: record kept for retry"
    assert_contains "RECORD_RESTORE_FAILED" "$(cat "$sandbox/rollback.log")" \
        "restore failure: warning marker emitted"
    assert_eq "0" "$(find "$sandbox" -name '*.cros-rollback-tmp-*' | wc -l | tr -d '[:space:]')" \
        "restore failure: no staged copy left behind"
}

# ---------------------------------------------------------------------------
# 42b. P2 DATA SAFETY: a failed final swap must never unlink the installed
#      target. Ordinary file/symlink swaps are a single atomic os.replace();
#      directory-involving swaps move the old entry aside and move it back on
#      failure. R1/R2 inject a failure; R3-R6 cover the success paths,
#      including the file<-dir cross-type case that a minimal patch breaks.
# ---------------------------------------------------------------------------

test_rollback_replace_failure_keeps_installed_file() {
    local sandbox="/tmp/rollback-test-replace-fail-file"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    local file="$sandbox/etc/demo.conf"
    local manifest="$sandbox/manifest/install-manifest.json"
    local ts="20260101_000000000000000"
    mkdir -p "$sandbox/backups/$ts${file%/*}"
    printf 'ORIGINAL\n' > "$sandbox/backups/$ts$file"
    printf 'INSTALLED\n' > "$file"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$file\",\"component\":\"demo\",\"was_existing\":true}],\"services\":[],\"groups\":[]}" > "$manifest"
    setup_rollback_replace_fault_stub "$sandbox"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" PYTHONPATH="$2/pyfault" \
               STUB_FAIL_ROLLBACK_REPLACE=1 STUB_FAIL_REPLACE_TARGET="$2/etc/demo.conf"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' > "$sandbox/rollback.log" 2>&1

    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "R1 rc 1"
    assert_eq "INSTALLED" "$(cat "$file" 2> /dev/null || echo MISSING)" \
        "R1 installed config still intact with original bytes"
    assert_eq "ORIGINAL" "$(cat "$sandbox/backups/$ts$file")" \
        "R1 backup intact"
    assert_eq "1" "$(manifest_count "$manifest" records)" \
        "R1 record retained"
    assert_contains "RECORD_RESTORE_FAILED" "$(cat "$sandbox/rollback.log")" \
        "R1 record-restore-failed marker"
    assert_contains "ROLLBACK_INCOMPLETE" "$(cat "$sandbox/rollback.log")" \
        "R1 python incomplete marker"
    assert_contains "rollback of demo failed" "$(cat "$sandbox/log.txt" 2> /dev/null || echo '')" \
        "R1 shell log_error"
    assert_not_contains "finished!" "$(cat "$sandbox/log.txt" 2> /dev/null || echo '')" \
        "R1 no success line"
    assert_eq "0" "$(find "$sandbox" -name '*.cros-rollback-tmp-*' | wc -l | tr -d '[:space:]')" \
        "R1 stage cleaned"
    assert_eq "0" "$(find "$sandbox" -name '*.cros-rollback-old-*' | wc -l | tr -d '[:space:]')" \
        "R1 no old aside residue"
}

test_rollback_replace_failure_keeps_installed_symlink() {
    local sandbox="/tmp/rollback-test-replace-fail-symlink"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    local link="$sandbox/etc/liblink"
    local manifest="$sandbox/manifest/install-manifest.json"
    local ts="20260101_000000000000000"
    printf 'ORIGINAL\n' > "$sandbox/etc/cros.conf"
    printf 'INSTALLED\n' > "$sandbox/etc/installed.conf"
    mkdir -p "$sandbox/backups/$ts${link%/*}"
    ln -s cros.conf "$sandbox/backups/$ts$link"
    ln -s installed.conf "$link"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$link\",\"component\":\"demo\",\"was_existing\":true}],\"services\":[],\"groups\":[]}" > "$manifest"
    setup_rollback_replace_fault_stub "$sandbox"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" PYTHONPATH="$2/pyfault" \
               STUB_FAIL_ROLLBACK_REPLACE=1 STUB_FAIL_REPLACE_TARGET="$2/etc/liblink"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' > "$sandbox/rollback.log" 2>&1

    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "R2 rc 1"
    if [ -L "$link" ]; then ok; else fail "R2 installed symlink still exists"; fi
    assert_eq "installed.conf" "$(readlink "$link" 2> /dev/null || echo MISSING)" \
        "R2 symlink target unchanged"
    assert_eq "INSTALLED" "$(cat "$sandbox/etc/installed.conf" 2> /dev/null || echo MISSING)" \
        "R2 referent bytes untouched"
    assert_eq "1" "$(manifest_count "$manifest" records)" \
        "R2 record retained"
    assert_contains "RECORD_RESTORE_FAILED" "$(cat "$sandbox/rollback.log")" \
        "R2 record-restore-failed marker"
    assert_eq "0" "$(find "$sandbox" -name '*.cros-rollback-tmp-*' | wc -l | tr -d '[:space:]')" \
        "R2 stage cleaned"
}

test_rollback_replace_success_regular_file() {
    local sandbox="/tmp/rollback-test-replace-ok-file"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    local file="$sandbox/etc/demo.conf"
    local manifest="$sandbox/manifest/install-manifest.json"
    local ts="20260101_000000000000000"
    mkdir -p "$sandbox/backups/$ts${file%/*}"
    printf 'ORIGINAL\n' > "$sandbox/backups/$ts$file"
    printf 'INSTALLED\n' > "$file"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$file\",\"component\":\"demo\",\"was_existing\":true}],\"services\":[],\"groups\":[]}" > "$manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' > "$sandbox/rollback.log" 2>&1

    assert_eq "0" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "R3 rc 0"
    assert_eq "ORIGINAL" "$(cat "$file" 2> /dev/null || echo MISSING)" \
        "R3 installed file replaced with original"
    assert_eq "0" "$(manifest_count "$manifest" records)" \
        "R3 record consumed after success"
    assert_contains "[RESTORED PREVIOUS BACKUP]" "$(cat "$sandbox/rollback.log")" \
        "R3 restore log emitted"
    assert_eq "0" "$(find "$sandbox" -name '*.cros-rollback-tmp-*' | wc -l | tr -d '[:space:]')" \
        "R3 stage cleaned"
    assert_eq "0" "$(find "$sandbox" -name '*.cros-rollback-old-*' | wc -l | tr -d '[:space:]')" \
        "R3 no old aside residue"
}

test_rollback_replace_success_directory() {
    local sandbox="/tmp/rollback-test-replace-ok-dir"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    local dir="$sandbox/etc/conf.d"
    local manifest="$sandbox/manifest/install-manifest.json"
    local ts="20260101_000000000000000"
    mkdir -p "$sandbox/backups/$ts$dir" "$dir"
    printf 'ORIGINAL\n' > "$sandbox/backups/$ts$dir/orig.txt"
    printf 'INSTALLED\n' > "$dir/installed.txt"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$dir\",\"component\":\"demo\",\"was_existing\":true}],\"services\":[],\"groups\":[]}" > "$manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' > "$sandbox/rollback.log" 2>&1

    assert_eq "0" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "R4 rc 0"
    if [ -d "$dir" ] && [ ! -L "$dir" ]; then ok; else fail "R4 target still a directory"; fi
    assert_eq "ORIGINAL" "$(cat "$dir/orig.txt" 2> /dev/null || echo MISSING)" \
        "R4 original directory content restored"
    if [ ! -e "$dir/installed.txt" ]; then ok; else fail "R4 installed content removed"; fi
    assert_eq "0" "$(manifest_count "$manifest" records)" \
        "R4 record consumed"
    assert_eq "0" "$(find "$sandbox" -name '*.cros-rollback-old-*' | wc -l | tr -d '[:space:]')" \
        "R4 old aside cleaned"
}

test_rollback_replace_failure_restores_directory() {
    local sandbox="/tmp/rollback-test-replace-fail-dir"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    local dir="$sandbox/etc/conf.d"
    local manifest="$sandbox/manifest/install-manifest.json"
    local ts="20260101_000000000000000"
    mkdir -p "$sandbox/backups/$ts$dir" "$dir"
    printf 'ORIGINAL\n' > "$sandbox/backups/$ts$dir/orig.txt"
    printf 'INSTALLED\n' > "$dir/installed.txt"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$dir\",\"component\":\"demo\",\"was_existing\":true}],\"services\":[],\"groups\":[]}" > "$manifest"
    setup_rollback_replace_fault_stub "$sandbox"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" PYTHONPATH="$2/pyfault" \
               STUB_FAIL_ROLLBACK_REPLACE=1 STUB_FAIL_REPLACE_TARGET="$2/etc/conf.d"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' > "$sandbox/rollback.log" 2>&1

    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "R5 rc 1"
    if [ -d "$dir" ] && [ ! -L "$dir" ]; then ok; else fail "R5 target still a directory"; fi
    assert_eq "INSTALLED" "$(cat "$dir/installed.txt" 2> /dev/null || echo MISSING)" \
        "R5 installed directory content intact"
    if [ ! -e "$dir/orig.txt" ]; then ok; else fail "R5 original content not partially applied"; fi
    assert_eq "1" "$(manifest_count "$manifest" records)" \
        "R5 record retained"
    assert_contains "RECORD_RESTORE_FAILED" "$(cat "$sandbox/rollback.log")" \
        "R5 record-restore-failed marker"
    assert_eq "0" "$(find "$sandbox" -name '*.cros-rollback-old-*' | wc -l | tr -d '[:space:]')" \
        "R5 old aside rolled back"
    assert_eq "0" "$(find "$sandbox" -name '*.cros-rollback-tmp-*' | wc -l | tr -d '[:space:]')" \
        "R5 stage cleaned"
}

test_rollback_replace_directory_backup_over_file() {
    local sandbox="/tmp/rollback-test-replace-dir-over-file"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"
    local file="$sandbox/etc/demo.conf"
    local manifest="$sandbox/manifest/install-manifest.json"
    local ts="20260101_000000000000000"
    mkdir -p "$sandbox/backups/$ts$file"
    printf 'ORIGINAL\n' > "$sandbox/backups/$ts$file/orig.txt"
    printf 'INSTALLED\n' > "$file"
    printf '%s' "{\"version\":\"2.0\",\"records\":[{\"target\":\"$file\",\"component\":\"demo\",\"was_existing\":true}],\"services\":[],\"groups\":[]}" > "$manifest"

    run_sandboxed "$sandbox" '
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' > "$sandbox/rollback.log" 2>&1

    assert_eq "0" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "R6 rc 0"
    if [ -d "$file" ] && [ ! -L "$file" ]; then ok; else fail "R6 target became a directory"; fi
    assert_eq "ORIGINAL" "$(cat "$file/orig.txt" 2> /dev/null || echo MISSING)" \
        "R6 original directory content restored"
    assert_eq "0" "$(manifest_count "$manifest" records)" \
        "R6 record consumed"
    assert_eq "0" "$(find "$sandbox" -name '*.cros-rollback-old-*' | wc -l | tr -d '[:space:]')" \
        "R6 old file aside removed (remove_path, not rmtree)"
    assert_eq "0" "$(find "$sandbox" -name '*.cros-rollback-tmp-*' | wc -l | tr -d '[:space:]')" \
        "R6 stage cleaned"
}

# ---------------------------------------------------------------------------
# 43. Finding #3: every systemctl action is checked. A failed service keeps
#     its record (and is retryable), other services/files still roll back,
#     and the python reports non-zero only AFTER the atomic write-back.
# ---------------------------------------------------------------------------

test_rollback_systemctl_failure_keeps_record() {
    local sandbox="/tmp/rollback-test-systemctl-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    mkdir -p "$sandbox/etc"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf 'NEW\n' > "$sandbox/etc/demo.conf"
    write_demo_services_manifest "$sandbox" \
        '[{"name":"ok.service","component":"demo","was_enabled":true,"was_active":true,"scope":"system"},{"name":"fail.service","component":"demo","was_enabled":true,"was_active":true,"scope":"system"}]' \
        "[{\"target\":\"$sandbox/etc/demo.conf\",\"component\":\"demo\",\"was_existing\":false}]"
    : > "$sandbox/systemctl.log"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_SYSTEMCTL_FAIL_CMD="start fail.service"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"

    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "systemctl failure: rollback rc 1"
    assert_eq "fail.service" "$(manifest_names "$manifest" services name)" \
        "systemctl failure: only the failed service record is retained"
    assert_eq "0" "$(manifest_count "$manifest" records)" \
        "systemctl failure: file records are still processed and consumed"
    if [ ! -e "$sandbox/etc/demo.conf" ]; then ok; else fail "systemctl failure: file still rolled back"; fi
    local calls
    calls="$(cat "$sandbox/systemctl.log")"
    assert_contains "enable ok.service" "$calls" "systemctl failure: ok.service enabled"
    assert_contains "start ok.service" "$calls" "systemctl failure: ok.service started"
    assert_contains "enable fail.service" "$calls" "systemctl failure: fail.service enabled"
    assert_contains "start fail.service" "$calls" "systemctl failure: fail.service start attempted"
    assert_contains "SERVICE_RESTORE_FAILED name=fail.service action=start rc=1" \
        "$(cat "$sandbox/rollback.log")" "systemctl failure: structured warning marker"
    assert_contains "rollback of demo failed" "$(cat "$sandbox/log.txt")" \
        "systemctl failure: error logged"
    if grep -qF "finished!" "$sandbox/log.txt"; then
        fail "systemctl failure: no success line may be printed"
    else
        ok
    fi
    assert_eq "0" "$(find "$sandbox/manifest" -name '*.tmp' | wc -l | tr -d '[:space:]')" \
        "systemctl failure: no .tmp residue"
}

test_rollback_systemctl_failure_retry_consumes_record() {
    local sandbox="/tmp/rollback-test-systemctl-retry"
    setup_keyd_caller_sandbox "$sandbox" valid
    local manifest="$sandbox/manifest/install-manifest.json"
    write_demo_services_manifest "$sandbox" \
        '[{"name":"fail.service","component":"demo","was_enabled":true,"was_active":true,"scope":"system"}]'
    : > "$sandbox/systemctl.log"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_SYSTEMCTL_FAIL_CMD="start fail.service"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "systemctl retry: first run fails"
    assert_eq "1" "$(manifest_count "$manifest" services)" \
        "systemctl retry: record retained after first run"

    : > "$sandbox/systemctl.log"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback2.log"
    assert_eq "0" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "systemctl retry: second run succeeds"
    assert_eq "0" "$(manifest_count "$manifest" services)" \
        "systemctl retry: retained record consumed on success"
    assert_contains "start fail.service" "$(cat "$sandbox/systemctl.log")" \
        "systemctl retry: retained record actually retried"
}

test_rollback_enable_failure_keeps_record() {
    local sandbox="/tmp/rollback-test-systemctl-enable-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    local manifest="$sandbox/manifest/install-manifest.json"
    write_demo_services_manifest "$sandbox" \
        '[{"name":"fail.service","component":"demo","was_enabled":true,"was_active":true,"scope":"system"}]'
    : > "$sandbox/systemctl.log"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_SYSTEMCTL_FAIL_CMD="enable fail.service"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "enable failure: rc 1"
    assert_eq "1" "$(manifest_count "$manifest" services)" "enable failure: record retained"
    assert_contains "SERVICE_RESTORE_FAILED name=fail.service action=enable rc=1" \
        "$(cat "$sandbox/rollback.log")" "enable failure: marker"
    if grep -qE '(^|[[:space:]])start([[:space:]]|$).*fail.service' "$sandbox/systemctl.log"; then
        fail "enable failure: start must be short-circuited"
    else
        ok
    fi
}

test_rollback_disable_failure_keeps_record() {
    local sandbox="/tmp/rollback-test-systemctl-disable-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    local manifest="$sandbox/manifest/install-manifest.json"
    write_demo_services_manifest "$sandbox" \
        '[{"name":"fail.service","component":"demo","was_enabled":false,"was_active":false,"scope":"system"}]'
    : > "$sandbox/systemctl.log"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_SYSTEMCTL_FAIL_CMD="disable fail.service"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "disable failure: rc 1"
    assert_eq "1" "$(manifest_count "$manifest" services)" "disable failure: record retained"
    assert_contains "SERVICE_RESTORE_FAILED name=fail.service action=disable rc=1" \
        "$(cat "$sandbox/rollback.log")" "disable failure: marker"
}

test_rollback_stop_failure_keeps_record() {
    local sandbox="/tmp/rollback-test-systemctl-stop-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    local manifest="$sandbox/manifest/install-manifest.json"
    write_demo_services_manifest "$sandbox" \
        '[{"name":"fail.service","component":"demo","was_enabled":false,"was_active":false,"scope":"system"}]'
    : > "$sandbox/systemctl.log"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_SYSTEMCTL_FAIL_CMD="stop fail.service"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "stop failure: rc 1"
    assert_eq "1" "$(manifest_count "$manifest" services)" "stop failure: record retained"
    assert_contains "SERVICE_RESTORE_FAILED name=fail.service action=stop rc=1" \
        "$(cat "$sandbox/rollback.log")" "stop failure: marker"
}

test_rollback_user_scope_global_failure_keeps_record() {
    local sandbox="/tmp/rollback-test-systemctl-global-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    local manifest="$sandbox/manifest/install-manifest.json"
    write_demo_services_manifest "$sandbox" \
        '[{"name":"fail.service","component":"demo","was_enabled":true,"was_active":false,"scope":"user"}]'
    : > "$sandbox/systemctl.log"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_SYSTEMCTL_FAIL_CMD="--global enable fail.service"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "user scope global failure: rc 1"
    assert_eq "1" "$(manifest_count "$manifest" services)" \
        "user scope global failure: record retained"
    assert_contains "SERVICE_RESTORE_FAILED name=fail.service action=--global enable rc=1" \
        "$(cat "$sandbox/rollback.log")" "user scope global failure: marker"
}

test_rollback_user_scope_no_manager_keeps_record() {
    local sandbox="/tmp/rollback-test-systemctl-no-manager"
    setup_keyd_caller_sandbox "$sandbox" valid
    local manifest="$sandbox/manifest/install-manifest.json"
    write_demo_services_manifest "$sandbox" \
        '[{"name":"fail.service","component":"demo","was_enabled":true,"was_active":true,"scope":"user"}]'
    : > "$sandbox/systemctl.log"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        unset SUDO_USER
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "no user manager with was_active=true: rc 1"
    assert_eq "1" "$(manifest_count "$manifest" services)" \
        "no user manager with was_active=true: record retained"
    assert_contains "SERVICE_RESTORE_FAILED name=fail.service action=--user start rc=unavailable" \
        "$(cat "$sandbox/rollback.log")" "no user manager: marker"
    if grep -qF -- "--user start" "$sandbox/systemctl.log"; then
        fail "no user manager: no --user start should be attempted"
    else
        ok
    fi
}

test_rollback_user_scope_start_failure_keeps_record() {
    local sandbox="/tmp/rollback-test-systemctl-user-start-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    local manifest="$sandbox/manifest/install-manifest.json"
    local uid user
    # Under sudo, SUDO_USER is the real non-root caller; in a root-only CI
    # container it is unset and `id -un` reports root (the production gate
    # then treats this as "no user manager" -- see the assertions below).
    user="${SUDO_USER:-}"
    if [ -z "$user" ] || [ "$user" = "root" ]; then
        user="$(id -un)"
    fi
    uid="$(id -u "$user" 2> /dev/null || echo 0)"
    mkdir -p "$sandbox/run-user/$uid"
    write_demo_services_manifest "$sandbox" \
        '[{"name":"fail.service","component":"demo","was_enabled":true,"was_active":true,"scope":"user"}]'
    : > "$sandbox/systemctl.log"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_SYSTEMCTL_FAIL_CMD="--user start" \
            SUDO_USER="$4" CROS_ENABLEMENT_TEST_XDG_ROOT="$2/run-user"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' "$uid" "$user" 2> "$sandbox/rollback.log"
    local rollback_log systemctl_log
    rollback_log="$(cat "$sandbox/rollback.log")"
    systemctl_log="$(cat "$sandbox/systemctl.log")"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "user scope start failure: rc non-zero"
    assert_eq "1" "$(manifest_count "$manifest" services)" \
        "user scope start failure: record retained"
    # Two legitimate fail-closed paths, depending on the host environment:
    #  * a non-root SUDO_USER with a reachable per-user bus -> --user start is
    #    attempted by the stub and fails with rc=1;
    #  * no user manager (CI container: no SUDO_USER, no /run/user/<uid>) ->
    #    the start is deliberately NOT attempted and rollback reports
    #    rc=unavailable. Both keep the record and emit a warning.
    if printf '%s' "$rollback_log" | grep -qF \
        "SERVICE_RESTORE_FAILED name=fail.service action=--user start rc=1"; then
        ok
        assert_contains "--user start fail.service" "$systemctl_log" \
            "user scope start failure: --user start was attempted"
    elif printf '%s' "$rollback_log" | grep -qF \
        "SERVICE_RESTORE_FAILED name=fail.service action=--user start rc=unavailable"; then
        ok
        assert_not_contains "--user start" "$systemctl_log" \
            "user scope start failure: no --user start should be attempted"
    else
        fail "user scope start failure: marker (expected SERVICE_RESTORE_FAILED ... rc=1 or rc=unavailable)"
        fail "user scope start failure: --user start call record consistent with marker"
    fi
}

test_rollback_systemctl_spawn_failure_keeps_record() {
    local sandbox="/tmp/rollback-test-systemctl-spawn-fail"
    setup_keyd_caller_sandbox "$sandbox" valid
    local manifest="$sandbox/manifest/install-manifest.json"
    write_demo_services_manifest "$sandbox" \
        '[{"name":"fail.service","component":"demo","was_enabled":true,"was_active":true,"scope":"system"}]'
    # No systemctl anywhere on this PATH: subprocess.run raises FileNotFoundError.
    mkdir -p "$sandbox/spawnbin"
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -ge 6 ] && [ -n "${STUB_NO_SYSTEMCTL_PATH:-}" ]; then
    PATH="$STUB_NO_SYSTEMCTL_PATH" exec /usr/bin/python3 "$@"
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/python3"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_NO_SYSTEMCTL_PATH="$2/spawnbin"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "systemctl spawn failure: rc 1"
    assert_eq "1" "$(manifest_count "$manifest" services)" \
        "systemctl spawn failure: record retained"
    assert_contains "SERVICE_RESTORE_FAILED name=fail.service action=enable rc=spawn-error" \
        "$(cat "$sandbox/rollback.log")" "systemctl spawn failure: marker"
}

test_rollback_all_success_consumes_services_and_records() {
    local sandbox="/tmp/rollback-test-systemctl-all-ok"
    setup_keyd_caller_sandbox "$sandbox" valid
    mkdir -p "$sandbox/etc"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf 'NEW\n' > "$sandbox/etc/demo.conf"
    write_demo_services_manifest "$sandbox" \
        '[{"name":"ok.service","component":"demo","was_enabled":true,"was_active":true,"scope":"system"},{"name":"ok2.service","component":"demo","was_enabled":false,"was_active":false,"scope":"system"}]' \
        "[{\"target\":\"$sandbox/etc/demo.conf\",\"component\":\"demo\",\"was_existing\":false}]"
    : > "$sandbox/systemctl.log"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$1/lib/backup.sh"
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback-rc.txt"
    ' 2> "$sandbox/rollback.log"
    assert_eq "0" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "all success: rollback rc 0"
    assert_eq "0" "$(manifest_count "$manifest" services)" "all success: services consumed"
    assert_eq "0" "$(manifest_count "$manifest" records)" "all success: records consumed"
    assert_contains "finished!" "$(cat "$sandbox/log.txt")" "all success: finished line printed"
    assert_contains "enable ok.service" "$(cat "$sandbox/systemctl.log")" "all success: ok.service enabled"
    assert_contains "disable ok2.service" "$(cat "$sandbox/systemctl.log")" "all success: ok2.service disabled"
    assert_contains "stop ok2.service" "$(cat "$sandbox/systemctl.log")" "all success: ok2.service stopped"
}

# ---------------------------------------------------------------------------
# 45. Re-review #9 finding #1: the global manifest is a shared read-modify-write
#     resource. T1/T2/T7/T8 use a FIFO barrier + delayed python writers so the
#     PRE-lock code loses a record deterministically; with the lock the second
#     writer waits, re-reads inside the lock and keeps every record.
# ---------------------------------------------------------------------------

test_lock_concurrent_writers_keep_both_records() {
    local sandbox
    sandbox="$(make_manifest_lock_sandbox t1)"
    manifest_lock_barrier_init "$sandbox"
    printf 'ORIGINAL AUDIO\n' > "$sandbox/root/audio.conf"
    printf 'ORIGINAL KEYBOARD\n' > "$sandbox/root/keyboard.conf"
    local manifest="$sandbox/manifest/install-manifest.json"
    export STUB_MANIFEST_WRITE_DELAY=0.4

    run_sandboxed "$sandbox" "$LOCK_INSTALL_WORKER" audio &
    local pa=$!
    run_sandboxed "$sandbox" "$LOCK_INSTALL_WORKER" keyboard &
    local pk=$!
    barrier_release "$sandbox" 2
    worker_wait_pid "$pa"
    worker_wait_pid "$pk"
    unset STUB_MANIFEST_WRITE_DELAY

    assert_eq "0" "$(cat "$sandbox/audio.rc" 2> /dev/null || echo MISSING)" "LOCK T1: audio rc 0"
    assert_eq "0" "$(cat "$sandbox/keyboard.rc" 2> /dev/null || echo MISSING)" "LOCK T1: keyboard rc 0"
    assert_eq "2" "$(manifest_count "$manifest" records)" "LOCK T1: both records survive"
    assert_eq "audio keyboard" \
        "$(python3 -c 'import json,sys; print(" ".join(sorted(r["component"] for r in json.load(open(sys.argv[1]))["records"])))' "$manifest")" \
        "LOCK T1: both components recorded"
    assert_eq "2" "$(find "$sandbox/backups" -type f | wc -l | tr -d '[:space:]')" \
        "LOCK T1: both first-wins backups kept"
    if grep -rq 'ORIGINAL AUDIO' "$sandbox/backups" && grep -rq 'ORIGINAL KEYBOARD' "$sandbox/backups"; then
        ok
    else
        fail "LOCK T1: both original backups kept byte-for-byte"
    fi
    assert_eq "0" "$(find "$sandbox/manifest" -name '.install-manifest.*.tmp' | wc -l | tr -d '[:space:]')" \
        "LOCK T1: no unique temp residue"
    assert_eq "0" "$(find "$sandbox/manifest" -name '*.tmp' | wc -l | tr -d '[:space:]')" \
        "LOCK T1: no .tmp residue"
    local lock="$sandbox/manifest/.install-manifest.lock"
    assert_eq "root" "$(stat -c '%U' "$lock" 2> /dev/null || echo MISSING)" "LOCK T1: lock root-owned"
    assert_eq "600" "$(stat -c '%a' "$lock" 2> /dev/null || echo MISSING)" "LOCK T1: lock mode 0600 (root-only, no unprivileged flock DoS)"
}

test_lock_concurrent_install_and_rollback_preserves_records() {
    local sandbox
    sandbox="$(make_manifest_lock_sandbox t2)"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf 'ORIGINAL DEMO\n' > "$sandbox/root/demo.conf"
    # Natural first backup + record (no delay active yet).
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        backup_file_manifest_aware "$2/root/demo.conf" demo
    '
    printf 'INSTALLED DEMO\n' > "$sandbox/root/demo.conf"
    printf 'INSTALLED OTHER\n' > "$sandbox/root/other.conf"
    manifest_lock_barrier_init "$sandbox"
    export STUB_MANIFEST_WRITE_DELAY=0.3

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        exec 3<>"$2/ready" 4<>"$2/go"
        printf "r\n" >&3; read -r _ <&4
        rc=0; backup_file_manifest_aware "$2/root/other.conf" other || rc=$?
        printf "%s\n" "$rc" > "$2/install.rc"; exit 0
    ' other &
    local pi=$!
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        exec 3<>"$2/ready" 4<>"$2/go"
        printf "r\n" >&3; read -r _ <&4
        rc=0; rollback_component "demo" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback.rc"; exit 0
    ' demo &
    local pr=$!
    barrier_release "$sandbox" 2
    worker_wait_pid "$pi"
    worker_wait_pid "$pr"
    unset STUB_MANIFEST_WRITE_DELAY

    assert_eq "0" "$(cat "$sandbox/install.rc" 2> /dev/null || echo MISSING)" "LOCK T2: install rc 0"
    assert_eq "0" "$(cat "$sandbox/rollback.rc" 2> /dev/null || echo MISSING)" "LOCK T2: rollback rc 0"
    assert_eq "1" "$(manifest_count "$manifest" records)" "LOCK T2: exactly one record left"
    assert_eq "other" \
        "$(python3 -c 'import json,sys; print(" ".join(r["component"] for r in json.load(open(sys.argv[1]))["records"]))' "$manifest")" \
        "LOCK T2: only the newly installed record remains (demo consumed)"
    assert_eq "ORIGINAL DEMO" "$(cat "$sandbox/root/demo.conf" 2> /dev/null || echo MISSING)" \
        "LOCK T2: demo restored from its original backup"
    assert_eq "INSTALLED OTHER" "$(cat "$sandbox/root/other.conf" 2> /dev/null || echo MISSING)" \
        "LOCK T2: other target not partially restored"
    if grep -rq 'INSTALLED OTHER' "$sandbox/backups"; then
        ok
    else
        fail "LOCK T2: other's backup kept"
    fi
    assert_eq "0" "$(find "$sandbox/manifest" -name '.install-manifest.*.tmp' | wc -l | tr -d '[:space:]')" \
        "LOCK T2: no unique temp residue"
}

test_lock_writers_use_unique_temp() {
    local sandbox
    sandbox="$(make_manifest_lock_sandbox t3)"
    local mp="$sandbox/manifest/install-manifest.json"
    local oldtmp="$sandbox/manifest/install-manifest.json.tmp"
    mkdir -p "$oldtmp"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sandbox/stub/systemctl"
    chmod +x "$sandbox/stub/systemctl"
    printf 'ORIGINAL AUDIO\n' > "$sandbox/root/audio.conf"

    local backup_writer='
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        rc=0
        case "$3" in
            add_entry)    manifest_add_entry "$2/root/audio.conf" audio 0 || rc=$? ;;
            add_service)  manifest_add_service "demo.service" demo || rc=$? ;;
            add_group)    manifest_add_group plugdev testuser demo 0 || rc=$? ;;
            remove_group) manifest_remove_group plugdev testuser demo || rc=$? ;;
            rollback)     rollback_component demo || rc=$? ;;
        esac
        printf "%s\n" "$rc" > "$2/$3.rc"
    '
    local normalize_writer='
        export PATH="$2/stub:$PATH"
        source "$2/install-keyboard-sandbox.sh"
        _normalize_keyd_link_manifest_component
        printf "0\n" > "$2/normalize.rc"
    '
    prepare_keyd_sandbox_script "$sandbox"

    local case_name
    for case_name in add_entry add_service add_group remove_group rollback normalize; do
        python3 - "$mp" << 'PY'
import json, sys
json.dump({"version": "2.0", "records": [], "services": [], "groups": []},
          open(sys.argv[1], "w"), indent=2)
PY
        case "$case_name" in
            remove_group)
                python3 - "$mp" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["groups"].append({"group": "plugdev", "user": "testuser",
                    "component": "demo", "was_member": False})
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
                ;;
            rollback)
                python3 - "$mp" "$sandbox/root/gone.conf" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["records"].append({"target": sys.argv[2], "component": "demo",
                     "was_existing": False})
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
                ;;
            normalize)
                python3 - "$mp" "$sandbox/etc/keyd/default.conf" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["records"].append({"target": sys.argv[2], "was_existing": True})
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
                ;;
        esac
        local rcfile="$sandbox/$case_name.rc"
        if [ "$case_name" = normalize ]; then
            run_sandboxed "$sandbox" "$normalize_writer"
        else
            run_sandboxed "$sandbox" "$backup_writer" "$case_name"
        fi
        assert_eq "0" "$(cat "$rcfile" 2> /dev/null || echo MISSING)" \
            "[LOCK T3] $case_name: rc 0 despite occupied old .tmp path"
        assert_eq "0" "$(find "$sandbox/manifest" -name '.install-manifest.*.tmp' | wc -l | tr -d '[:space:]')" \
            "[LOCK T3] $case_name: no unique temp residue"
        case "$case_name" in
            add_entry) assert_eq "1" "$(manifest_count "$mp" records)" "[LOCK T3] add_entry: record written" ;;
            add_service) assert_eq "1" "$(manifest_count "$mp" services)" "[LOCK T3] add_service: record written" ;;
            add_group) assert_eq "1" "$(manifest_count "$mp" groups)" "[LOCK T3] add_group: record written" ;;
            remove_group) assert_eq "0" "$(manifest_count "$mp" groups)" "[LOCK T3] remove_group: record removed" ;;
            rollback) assert_eq "0" "$(manifest_count "$mp" records)" "[LOCK T3] rollback: record consumed" ;;
            normalize) assert_eq "keyboard" \
                "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["records"][0].get("component",""))' "$mp")" \
                "[LOCK T3] normalize: component backfilled" ;;
        esac
    done
    if [ -d "$oldtmp" ]; then
        ok
    else
        fail "LOCK T3: the old fixed .tmp directory must be left untouched"
    fi
    assert_eq "0" "$(find "$sandbox/manifest" -name '*.install-manifest.*.tmp' | wc -l | tr -d '[:space:]')" \
        "LOCK T3: no unique temp anywhere"
}

test_lock_nested_no_deadlock() {
    local sandbox
    sandbox="$(make_manifest_lock_sandbox t4)"
    printf 'ORIGINAL AUDIO\n' > "$sandbox/root/audio.conf"

    # (a) Direct nesting: depth counts, single fd, fully released at the end.
    run_sandboxed "$sandbox" '
        export CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=2
        source "$1/lib/backup.sh"
        manifest_lock || { printf "lock1-failed\n" > "$2/direct.rc"; exit 0; }
        manifest_lock || { printf "lock2-failed\n" > "$2/direct.rc"; exit 0; }
        printf "depth-inner=%s\n" "$MANIFEST_LOCK_DEPTH" > "$2/depth-inner.txt"
        # Snapshot BEFORE unlocking: release clears the holder variables, so
        # checking them afterwards would be a tautology (both empty -> the
        # write/kill always fail even if release leaked the fd and helper).
        saved_wfd="$MANIFEST_LOCK_HOLDER_WFD"
        saved_pid="$MANIFEST_LOCK_HOLDER_PID"
        manifest_unlock
        manifest_unlock
        # The lock fd now lives in the root holder, not in this shell. A
        # balanced release must have closed the coproc write fd and reaped the
        # helper; writing to the stale WFD must fail and kill -0 must fail.
        if eval ": >&${saved_wfd}" 2> /dev/null; then
            printf "wfd-open\n" > "$2/wfd.txt"
        else
            printf "wfd-closed\n" > "$2/wfd.txt"
        fi
        if kill -0 "$saved_pid" 2> /dev/null; then
            printf "holder-alive\n" > "$2/holder.txt"
        else
            printf "holder-reaped\n" > "$2/holder.txt"
        fi
        printf "depth=%s\n" "$MANIFEST_LOCK_DEPTH" > "$2/depth.txt"
        printf "ok\n" > "$2/direct.rc"
    '
    assert_eq "ok" "$(cat "$sandbox/direct.rc" 2> /dev/null || echo MISSING)" "LOCK T4: direct nested lock rc ok"
    assert_eq "depth-inner=2" "$(cat "$sandbox/depth-inner.txt" 2> /dev/null || echo MISSING)" \
        "LOCK T4: reentrant lock increments depth (no second coproc holder)"
    assert_eq "wfd-closed" "$(cat "$sandbox/wfd.txt" 2> /dev/null || echo MISSING)" \
        "LOCK T4: coproc write fd closed after balanced unlocks"
    assert_eq "holder-reaped" "$(cat "$sandbox/holder.txt" 2> /dev/null || echo MISSING)" \
        "LOCK T4: root holder reaped after balanced unlocks"
    assert_eq "depth=0" "$(cat "$sandbox/depth.txt" 2> /dev/null || echo MISSING)" "LOCK T4: depth back to zero"

    # (b) Public gate -> manifest_add_entry (two levels).
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=2
        source "$1/lib/backup.sh"
        rc=0; backup_file_manifest_aware "$2/root/audio.conf" audio || rc=$?
        printf "%s\n" "$rc" > "$2/gate.rc"
        printf "depth=%s\n" "$MANIFEST_LOCK_DEPTH" > "$2/gate-depth.txt"
    '
    assert_eq "0" "$(cat "$sandbox/gate.rc" 2> /dev/null || echo MISSING)" "LOCK T4: nested gate rc 0"
    assert_eq "depth=0" "$(cat "$sandbox/gate-depth.txt" 2> /dev/null || echo MISSING)" "LOCK T4: nested gate leaves depth 0"

    # (c) ensure_group_membership -> has_group/add_group/remove_group (three
    #     levels) on the usermod-failure cleanup path.
    setup_group_fault_stubs "$sandbox"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log" STUB_USERMOD_RC=1 STUB_USER_IN_PLUGDEV=0 \
            CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=2
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser demo || rc=$?
        printf "%s\n" "$rc" > "$2/group.rc"
        printf "depth=%s\n" "$MANIFEST_LOCK_DEPTH" > "$2/group-depth.txt"
    '
    assert_eq "1" "$(cat "$sandbox/group.rc" 2> /dev/null || echo MISSING)" \
        "LOCK T4: nested group helpers complete (usermod failure rc 1)"
    assert_eq "depth=0" "$(cat "$sandbox/group-depth.txt" 2> /dev/null || echo MISSING)" "LOCK T4: nested group depth 0"
    assert_eq "0" "$(manifest_count "$sandbox/manifest/install-manifest.json" groups)" \
        "LOCK T4: failed group record rolled back"
    assert_not_contains "Manifest lock wait failed" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "LOCK T4: no self-deadlock / lock wait failure"
}

test_lock_timeout_fails_closed() {
    local sandbox
    sandbox="$(make_manifest_lock_sandbox t5)"
    local lock="$sandbox/manifest/.install-manifest.lock"
    local mp="$sandbox/manifest/install-manifest.json"
    : > "$lock"
    printf '%s' '{"version":"2.0","records":[],"services":[],"groups":[]}' > "$mp"
    local before
    before="$(file_hex "$mp")"
    printf 'ORIGINAL AUDIO\n' > "$sandbox/root/audio.conf"

    # A separate process holds the lock; fd 9 is its own, not ours.
    (
        exec 9< "$lock"
        flock -x 9
        : > "$sandbox/held"
        sleep 5
    ) &
    local holder=$!
    local i=0
    while [ ! -e "$sandbox/held" ] && [ "$i" -lt 200 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    if [ -e "$sandbox/held" ]; then ok; else fail "LOCK T5: holder never acquired lock"; fi

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=1
        source "$1/lib/backup.sh"
        rc=0; manifest_add_entry "$2/root/audio.conf" audio 0 || rc=$?
        printf "%s\n" "$rc" > "$2/timeout.rc"
    '
    assert_eq "1" "$(cat "$sandbox/timeout.rc" 2> /dev/null || echo MISSING)" "LOCK T5: timeout rc 1 (fail closed)"
    assert_contains "Manifest lock wait failed" "$(cat "$sandbox/log.txt" 2> /dev/null || echo "")" \
        "LOCK T5: timeout diagnostic logged"
    assert_eq "$before" "$(file_hex "$mp")" "LOCK T5: manifest bytes unchanged"
    assert_eq "0" "$(find "$sandbox/manifest" -name '.install-manifest.*.tmp' | wc -l | tr -d '[:space:]')" \
        "LOCK T5: no temp residue on fail-closed path"
    kill "$holder" 2> /dev/null || true
    worker_wait_pid "$holder"

    # A flock stub that always fails must also fail closed.
    cat > "$sandbox/stub/flock" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$sandbox/stub/flock"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        rc=0; manifest_add_entry "$2/root/audio.conf" audio 0 || rc=$?
        printf "%s\n" "$rc" > "$2/stubflock.rc"
    '
    assert_eq "1" "$(cat "$sandbox/stubflock.rc" 2> /dev/null || echo MISSING)" "LOCK T5: broken flock rc 1"
    assert_eq "$before" "$(file_hex "$mp")" "LOCK T5: broken flock leaves manifest unchanged"
    rm -f "$sandbox/stub/flock"
}

test_lock_dryrun_and_no_python3_untouched() {
    local sandbox
    sandbox="$(make_manifest_lock_sandbox t6)"
    local mp="$sandbox/manifest/install-manifest.json"
    printf '%s' '{"version":"2.0","records":[],"services":[],"groups":[]}' > "$mp"
    printf 'ORIGINAL AUDIO\n' > "$sandbox/root/audio.conf"
    # A real wrapped installer, used below to prove DRY_RUN takes no lock.
    prepare_caller_sandbox_script "$sandbox" power

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" DRY_RUN=1 STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        SB="$2"
        for fn in add_entry add_service add_group remove_group ensure_group remove_group_membership backup_gate rollback; do
            rc=0
            case "$fn" in
                add_entry)            manifest_add_entry "$2/root/audio.conf" audio 0 || rc=$? ;;
                add_service)          manifest_add_service demo.service demo || rc=$? ;;
                add_group)            manifest_add_group plugdev testuser demo 0 || rc=$? ;;
                remove_group)         manifest_remove_group plugdev testuser demo || rc=$? ;;
                ensure_group)         ensure_group_membership plugdev testuser demo || rc=$? ;;
                remove_group_membership) remove_group_membership plugdev testuser demo || rc=$? ;;
                backup_gate)          backup_file_manifest_aware "$2/root/audio.conf" audio || rc=$? ;;
                rollback)             rollback_component demo || rc=$? ;;
            esac
            printf "%s\n" "$rc" > "$2/dry-$fn.rc"
        done
        # The operation wrapper itself must not take/create a lock in DRY_RUN.
        dryrun_probe_body() { : > "$SB/dry-probe-ran"; }
        rc=0
        run_manifest_operation dryrun_probe_body || rc=$?
        printf "%s\n" "$rc" > "$SB/dry-operation.rc"
        # ...and neither may a real wrapped installer (sourced with set -e,
        # hence the subshell so the rest of this snippet is unaffected).
        (
            source "$SB/install-caller-sandbox.sh"
            uninstall_power
        )
        printf "%s\n" "$?" > "$SB/dry-installer.rc"
    '
    local fn
    for fn in add_entry add_service add_group remove_group ensure_group remove_group_membership backup_gate rollback; do
        assert_eq "0" "$(cat "$sandbox/dry-$fn.rc" 2> /dev/null || echo MISSING)" \
            "LOCK T6: dry-run $fn rc 0"
    done
    assert_eq "0" "$(cat "$sandbox/dry-operation.rc" 2> /dev/null || echo MISSING)" \
        "LOCK T6: dry-run run_manifest_operation rc 0"
    assert_eq "0" "$(cat "$sandbox/dry-installer.rc" 2> /dev/null || echo MISSING)" \
        "LOCK T6: dry-run wrapped installer rc 0"
    if [ -e "$sandbox/dry-probe-ran" ]; then
        ok
    else
        fail "LOCK T6: dry-run operation body was not called"
    fi
    if [ -e "$sandbox/manifest/.install-manifest.lock" ]; then
        fail "LOCK T6: dry-run must not create a lock file"
    else
        ok
    fi

    # The lock itself must not depend on python3 at all.
    mkdir -p "$sandbox/failbin"
    printf '#!/usr/bin/env bash\nexit 127\n' > "$sandbox/failbin/python3"
    chmod +x "$sandbox/failbin/python3"
    run_sandboxed "$sandbox" '
        export PATH="$2/failbin:$PATH"
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        if [ "$rc" -eq 0 ]; then manifest_unlock; fi
        printf "%s\n" "$rc" > "$2/lock-nopy.rc"
        printf "depth=%s\n" "$MANIFEST_LOCK_DEPTH" > "$2/lock-nopy-depth.txt"
    '
    assert_eq "0" "$(cat "$sandbox/lock-nopy.rc" 2> /dev/null || echo MISSING)" "LOCK T6: lock works without python3"
    assert_eq "depth=0" "$(cat "$sandbox/lock-nopy-depth.txt" 2> /dev/null || echo MISSING)" "LOCK T6: depth released without python3"
}

test_lock_high_contention_all_records_survive() {
    local sandbox
    sandbox="$(make_manifest_lock_sandbox t7)"
    manifest_lock_barrier_init "$sandbox"
    local manifest="$sandbox/manifest/install-manifest.json"
    local names="t0 t1 t2 t3 t4 t5 t6 t7" name
    for name in $names; do
        printf 'ORIGINAL %s\n' "$name" > "$sandbox/root/$name.conf"
    done
    export STUB_MANIFEST_WRITE_DELAY=0.15
    local pids=()
    for name in $names; do
        run_sandboxed "$sandbox" "$LOCK_INSTALL_WORKER" "$name" &
        pids+=("$!")
    done
    barrier_release "$sandbox" 8
    local pid
    for pid in "${pids[@]}"; do
        worker_wait_pid "$pid"
    done
    unset STUB_MANIFEST_WRITE_DELAY

    assert_eq "8" "$(manifest_count "$manifest" records)" "LOCK T7: all 8 records survive"
    assert_eq "8" "$(find "$sandbox/backups" -type f | wc -l | tr -d '[:space:]')" "LOCK T7: all 8 backups kept"
    assert_eq "8" \
        "$(for name in $names; do cat "$sandbox/$name.rc" 2> /dev/null || echo MISSING; done | grep -c '^0$')" \
        "LOCK T7: all 8 workers rc 0"
    assert_eq "0" "$(find "$sandbox/manifest" -name '.install-manifest.*.tmp' | wc -l | tr -d '[:space:]')" \
        "LOCK T7: no unique temp residue"
}

test_lock_same_target_first_backup_wins() {
    local sandbox
    sandbox="$(make_manifest_lock_sandbox t8)"
    manifest_lock_barrier_init "$sandbox"
    local manifest="$sandbox/manifest/install-manifest.json"
    printf 'ORIGINAL SAME\n' > "$sandbox/root/same.conf"
    export STUB_MANIFEST_WRITE_DELAY=0.3

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        exec 3<>"$2/ready" 4<>"$2/go"
        printf "r\n" >&3; read -r _ <&4
        rc=0; backup_file_manifest_aware "$2/root/same.conf" keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/a.rc"; exit 0
    ' a &
    local paa=$!
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        exec 3<>"$2/ready" 4<>"$2/go"
        printf "r\n" >&3; read -r _ <&4
        rc=0; backup_file_manifest_aware "$2/root/same.conf" keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/b.rc"; exit 0
    ' b &
    local pab=$!
    barrier_release "$sandbox" 2
    worker_wait_pid "$paa"
    worker_wait_pid "$pab"
    unset STUB_MANIFEST_WRITE_DELAY

    assert_eq "0" "$(cat "$sandbox/a.rc" 2> /dev/null || echo MISSING)" "LOCK T8: worker A rc 0"
    assert_eq "0" "$(cat "$sandbox/b.rc" 2> /dev/null || echo MISSING)" "LOCK T8: worker B rc 0"
    assert_eq "1" "$(manifest_count "$manifest" records)" "LOCK T8: exactly one record for the target"
    assert_eq "1" "$(find "$sandbox/backups" -type f | wc -l | tr -d '[:space:]')" \
        "LOCK T8: only the first backup kept (no backup storm)"
    if grep -rq 'ORIGINAL SAME' "$sandbox/backups"; then
        ok
    else
        fail "LOCK T8: the single backup is the original first-wins backup"
    fi
    assert_eq "0" "$(find "$sandbox/manifest" -name '.install-manifest.*.tmp' | wc -l | tr -d '[:space:]')" \
        "LOCK T8: no unique temp residue"
}

# ---------------------------------------------------------------------------
# 46. Re-review #10 findings #2/#3 (fixed together): the lock file must reject
#     symlinks/non-regular paths, verify the fd it actually holds against the
#     path, and be root-only 0600 so an unprivileged account cannot take an
#     exclusive flock and starve every installer. The lock is acquired by a
#     short-lived root holder coproc whose stdin is our lifetime leash.
# ---------------------------------------------------------------------------
_SEC_MANIFEST='{"version":"2.0","records":[],"services":[],"groups":[]}'

_lock_sec_prepare() {
    printf '%s' "$_SEC_MANIFEST" > "$1/manifest/install-manifest.json"
    printf 'ORIGINAL AUDIO\n' > "$1/root/audio.conf"
}

_lock_sec_try() {
    local s="$1"
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/lock.rc"
        if [ -n "$MANIFEST_LOCK_HOLDER_PID" ] && kill -0 "$MANIFEST_LOCK_HOLDER_PID" 2>/dev/null; then
            printf "holder-alive\n" > "$2/holder.txt"
        else
            printf "holder-none\n" > "$2/holder.txt"
        fi
        if eval ": >&${MANIFEST_LOCK_HOLDER_WFD}" 2> /dev/null; then
            printf "wfd-open\n" > "$2/wfd.txt"
        else
            printf "wfd-closed\n" > "$2/wfd.txt"
        fi
        if [ "$rc" -eq 0 ]; then
            g=0; backup_file_manifest_aware "$2/root/audio.conf" audio || g=$?
            printf "%s\n" "$g" > "$2/gate.rc"
            manifest_unlock
        else
            printf "1\n" > "$2/gate.rc"
        fi
    '
}

_lock_sec_fail_asserts() {
    local s="$1" needle="$2"
    assert_eq "1" "$(cat "$s/lock.rc" 2> /dev/null || echo MISSING)" "SEC: manifest_lock fails closed"
    assert_eq "holder-none" "$(cat "$s/holder.txt" 2> /dev/null || echo MISSING)" "SEC: no root holder left alive"
    assert_eq "wfd-closed" "$(cat "$s/wfd.txt" 2> /dev/null || echo MISSING)" "SEC: coproc write fd closed"
    assert_eq "1" "$(cat "$s/gate.rc" 2> /dev/null || echo MISSING)" "SEC: mutation helper blocked"
    assert_contains "$needle" "$(cat "$s/log.txt" 2> /dev/null || echo "")" "SEC: explicit error logged"
    assert_eq "$_SEC_MANIFEST" "$(cat "$s/manifest/install-manifest.json" 2> /dev/null || echo MISSING)" \
        "SEC: manifest bytes unchanged"
    assert_eq "0" "$(find "$s/backups" -type f | wc -l | tr -d '[:space:]')" "SEC: no backup written"
}

# A paused `stat -c %i -- <lock>` stub lets a test mutate the path AFTER the
# root holder has already opened fd 9 but BEFORE it compares fd inode to path.
_lock_sec_stat_stub() {
    local s="$1"
    cat > "$s/stub/stat" << 'EOF'
#!/usr/bin/env bash
if [ "${STUB_STAT_SPOOF:-0}" = 1 ] && [ "${1:-}" = "-c" ] && [ "${2:-}" = "%i" ] &&
   [ "${3:-}" = "--" ] && [ "${4:-}" = "${STUB_LOCK_PATH:-}" ] &&
   [ ! -e "${STUB_STAT_GO:-/nonexistent}" ]; then
    : > "${STUB_STAT_READY:?}"
    i=0
    while [ ! -e "${STUB_STAT_GO:-/nonexistent}" ] && [ "$i" -lt 200 ]; do
        sleep 0.05
        i=$((i + 1))
    done
fi
exec /usr/bin/stat "$@"
EOF
    chmod +x "$s/stub/stat"
}

_lock_sec_wait_stub() {
    local s="$1" i=0
    while [ ! -e "$s/stat.ready" ] && [ "$i" -lt 200 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    if [ -e "$s/stat.ready" ]; then ok; else fail "SEC: helper never reached the inode check"; fi
}

test_sec_lock_rejects_symlink_to_regular() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-s1)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    printf 'ATTACKER\n' > "$s/other"
    chmod 0644 "$s/other"
    ln -s "$s/other" "$lock"
    _lock_sec_try "$s"
    _lock_sec_fail_asserts "$s" "is a symlink"
    assert_eq "644" "$(stat -c '%a' "$s/other")" "SEC S1: symlink target mode untouched (no path chmod)"
    assert_eq "ATTACKER" "$(cat "$s/other")" "SEC S1: symlink target bytes untouched"
}

test_sec_lock_rejects_dangling_symlink() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-s2)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    ln -s "$s/no-such-target" "$lock"
    _lock_sec_try "$s"
    _lock_sec_fail_asserts "$s" "is a symlink"
}

test_sec_lock_rejects_symlink_to_directory() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-s3)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    ln -s "$s/manifest" "$lock"
    _lock_sec_try "$s"
    _lock_sec_fail_asserts "$s" "is a symlink"
}

test_sec_lock_rejects_fifo_without_blocking() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-s4)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    mkfifo "$lock"
    RB_TEST_TIMEOUT=15 _lock_sec_try "$s" || true
    _lock_sec_fail_asserts "$s" "not a regular file"
}

test_sec_lock_rejects_device_node() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-s5)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    if ! mknod "$lock" c 1 3 2> /dev/null; then
        echo "SKIP: SEC S5 (no CAP_MKNOD in this container)"
        return 0
    fi
    RB_TEST_TIMEOUT=15 _lock_sec_try "$s" || true
    _lock_sec_fail_asserts "$s" "not a regular file"
}

test_sec_lock_rejects_world_writable_parent() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-s6)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    chmod 0777 "$s/manifest"
    _lock_sec_try "$s"
    _lock_sec_fail_asserts "$s" "group/other-writable"
    assert_eq "absent" "$([ -e "$lock" ] || [ -L "$lock" ] && echo present || echo absent)" \
        "SEC S6: no lock file created in an untrusted parent"
}

test_sec_lock_rejects_symlinked_parent() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-s7)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    mkdir -p "$s/otherdir"
    cp "$s/manifest/install-manifest.json" "$s/otherdir/install-manifest.json"
    chmod 0777 "$s/otherdir"
    rm -rf "$s/manifest"
    ln -s "$s/otherdir" "$s/manifest"
    _lock_sec_try "$s"
    _lock_sec_fail_asserts "$s" "is a symlink or not a directory"
}

test_sec_lock_rejects_post_open_inode_swap() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-s8)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    _lock_sec_stat_stub "$s"
    export STUB_STAT_SPOOF=1 STUB_LOCK_PATH="$lock" \
        STUB_STAT_READY="$s/stat.ready" STUB_STAT_GO="$s/stat.go"
    _lock_sec_try "$s" &
    local p=$!
    _lock_sec_wait_stub "$s"
    # fd 9 is already open on the old inode; make the path point to a different
    # regular file with identical mode/owner before the holder compares them.
    mv "$lock" "$s/lock.old"
    cp "$s/lock.old" "$lock"
    chmod 0600 "$lock"
    : > "$s/stat.go"
    worker_wait_pid "$p"
    unset STUB_STAT_SPOOF STUB_LOCK_PATH STUB_STAT_READY STUB_STAT_GO
    _lock_sec_fail_asserts "$s" "FAILED:inode"
}

test_sec_lock_rejects_third_party_owner() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-s9)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    : > "$lock"
    chmod 0600 "$lock"
    chown 12345 "$lock"
    _lock_sec_try "$s"
    _lock_sec_fail_asserts "$s" "owned by uid 12345"
}

test_sec_lock_rejects_post_open_owner_swap() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-s9b)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    _lock_sec_stat_stub "$s"
    export STUB_STAT_SPOOF=1 STUB_LOCK_PATH="$lock" \
        STUB_STAT_READY="$s/stat.ready" STUB_STAT_GO="$s/stat.go"
    _lock_sec_try "$s" &
    local p=$!
    _lock_sec_wait_stub "$s"
    # init already accepted root ownership; change the inode's uid while the
    # holder's fd is open so only its fstat() check can catch the swap.
    chown 12345 "$lock"
    : > "$s/stat.go"
    worker_wait_pid "$p"
    unset STUB_STAT_SPOOF STUB_LOCK_PATH STUB_STAT_READY STUB_STAT_GO
    _lock_sec_fail_asserts "$s" "FAILED:inode"
}

test_sec_unprivileged_cannot_flock() {
    local s lock out rc=0
    s="$(make_manifest_lock_sandbox sec-t9)"
    _lock_sec_prepare "$s"
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        if [ "$rc" -eq 0 ]; then manifest_unlock; fi
        printf "%s\n" "$rc" > "$2/admin.rc"
    '
    assert_eq "0" "$(cat "$s/admin.rc" 2> /dev/null || echo MISSING)" \
        "SEC T9: administrator can still acquire and release the lock"
    lock="$s/manifest/.install-manifest.lock"
    assert_eq "600" "$(stat -c '%a' "$lock" 2> /dev/null || echo MISSING)" "SEC T9: lock mode 0600"
    # Let another uid traverse the sandbox; only the lock's 0600 should stop it.
    chmod 0755 "$s" "$s/manifest"
    out="$(sudo -n -u nobody -- bash -c 'export LC_ALL=C; exec 9<"$1" && flock -x -w 1 9' _ "$lock" 2>&1)" || rc=$?
    assert_eq "1" "$rc" "SEC T9: nobody cannot even open the lock (OPEN-DENIED)"
    assert_contains "Permission denied" "$out" "SEC T9: denial is the open() permission check"
}

test_sec_holder_contention_and_recovery() {
    local s
    s="$(make_manifest_lock_sandbox sec-t10)"
    _lock_sec_prepare "$s"
    # A holds the lock until we tell it to let go.
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=5
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/a.rc"
        if [ "$rc" -eq 0 ]; then
            : > "$2/a.held"
            while [ ! -e "$2/a.release" ]; do sleep 0.05; done
            manifest_unlock
            : > "$2/a.done"
        fi
    ' &
    local pa=$! i=0
    while [ ! -e "$s/a.held" ] && [ "$i" -lt 200 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    if [ -e "$s/a.held" ]; then ok; else fail "SEC T10: holder A never acquired the lock"; fi

    # B must time out against A and fail closed.
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=1
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/b.rc"
        if [ "$rc" -eq 0 ]; then manifest_unlock; fi
    '
    assert_eq "1" "$(cat "$s/b.rc" 2> /dev/null || echo MISSING)" "SEC T10: contender times out (rc 1)"

    : > "$s/a.release"
    worker_wait_pid "$pa"
    assert_eq "0" "$(cat "$s/a.rc" 2> /dev/null || echo MISSING)" "SEC T11: holder A rc 0"
    assert_eq "present" "$([ -e "$s/a.done" ] && echo present || echo absent)" \
        "SEC T11: holder A finished its release"

    # Once A is gone, a fresh acquisition succeeds.
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=2
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/c.rc"
        if [ "$rc" -eq 0 ]; then manifest_unlock; fi
    '
    assert_eq "0" "$(cat "$s/c.rc" 2> /dev/null || echo MISSING)" "SEC T11: later contender succeeds"
}

test_sec_crash_releases_lock_without_unlock() {
    local s ms_start ms_end
    s="$(make_manifest_lock_sandbox sec-t12)"
    T12_CRASH_SANDBOX="$s"
    _lock_sec_prepare "$s"
    # A dies with SIGKILL while holding the lock and never calls unlock.
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=5
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/crash.rc"
        if [ "$rc" -eq 0 ]; then
            # Publish the real lock-holder PID before the readiness marker so
            # the test can SIGKILL the bash that actually owns the coproc lock
            # (killing $pc would only kill the `timeout` wrapper layer).
            printf "%s\n" "$$" > "$2/crash.pid"
            : > "$2/crash.held"
            # Bounded poll instead of `sleep 60`: no orphan sleeper even if the
            # test fails early (the EXIT trap also creates crash.stop).
            for i in $(seq 1 100); do
                [ -e "$2/crash.stop" ] && break
                sleep 0.1
            done
        fi
    ' &
    local pc=$! i=0
    while [ ! -e "$s/crash.held" ] && [ "$i" -lt 200 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    if [ -e "$s/crash.held" ]; then ok; else fail "SEC T12: crashing holder never acquired the lock"; fi
    # Kill the real holder (the snippet bash), not the `timeout` wrapper $pc.
    if [ -r "$s/crash.pid" ]; then
        kill -9 "$(cat "$s/crash.pid")" 2> /dev/null || true
    fi
    : > "$s/crash.stop" 2> /dev/null || true
    worker_wait_pid "$pc"
    sleep 0.2

    ms_start="$(date +%s%3N)"
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=2
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/after.rc"
        if [ "$rc" -eq 0 ]; then manifest_unlock; fi
    '
    ms_end="$(date +%s%3N)"
    assert_eq "0" "$(cat "$s/after.rc" 2> /dev/null || echo MISSING)" \
        "SEC T12: no stale lock after SIGKILL (no explicit unlock)"
    if [ "$((ms_end - ms_start))" -lt 3000 ]; then
        ok
    else
        fail "SEC T12: recovery took longer than the 2s wait window"
    fi
}

# ---------------------------------------------------------------------------
# Re-review #11 finding #3 (P2 SECURITY): the lock's parent must be genuinely
# root-controlled. A parent owned by the caller can rename a LIVE lock out of
# the way; a second process then creates a new root-owned 0600 inode at the old
# path and takes a second "exclusive" flock. These cases pin the trust boundary
# to the directory's owner (never EUID/UID), the ancestor chain, and the root
# holder's own fd-8 recheck of the direct parent.
# ---------------------------------------------------------------------------

# Write a script that really runs as uid 1000 (setpriv changes EUID/UID too,
# so a regression to accepting `${EUID}`/`${UID}` is visible even though this
# suite itself runs as root) and reports manifest_lock's rc. The `id` stub is
# also installed so a regression to a bare `id -u` check is caught as well.
_lock_sec_nonroot_id_stub() {
    printf '#!/usr/bin/env bash\nif [ "$1" = "-u" ]; then echo 1000; else /usr/bin/id "$@"; fi\n' > "$1/stub/id"
    chmod +x "$1/stub/id"
}

test_sec_lock_rejects_user_owned_parent() {
    local s lock before
    s="$(make_manifest_lock_sandbox sec-s10)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    before="$(cat "$s/manifest/install-manifest.json")"
    chmod 0755 "$s" # let uid 1000 traverse the sandbox
    chown 1000:1000 "$s/manifest"
    chmod 0700 "$s/manifest"
    _lock_sec_nonroot_id_stub "$s"
    cat > "$s/user-lock.sh" << 'EOF'
#!/usr/bin/env bash
export PATH="$1/stub:$PATH" LOG_FILE="$1/manifest/test.log"
cd /
source "$2/lib/backup.sh"
rc=0; manifest_lock || rc=$?
printf '%s\n' "$rc" > "$1/manifest/lock.rc"
EOF
    chmod 0755 "$s/user-lock.sh"
    run_sandboxed "$s" '
        setpriv --reuid=1000 --regid=1000 --clear-groups \
            bash "$2/user-lock.sh" "$2" "$1"
    '
    assert_eq "1" "$(cat "$s/manifest/lock.rc" 2> /dev/null || echo MISSING)" \
        "SEC S10: caller-owned 0700 parent fails closed"
    assert_contains "must be root-owned" "$(cat "$s/manifest/test.log" 2> /dev/null || echo "")" \
        "SEC S10: root-owned parent requirement is logged"
    assert_eq "absent" "$([ -e "$lock" ] || [ -L "$lock" ] && echo present || echo absent)" \
        "SEC S10: no lock inode created in the untrusted parent"
    assert_eq "$before" "$(cat "$s/manifest/install-manifest.json" 2> /dev/null || echo MISSING)" \
        "SEC S10: manifest bytes unchanged"
}

test_sec_lock_rename_after_acquire_cannot_create_second_holder() {
    local s lock before
    # (i) A user-owned parent cannot host even ONE holder, so rename-and-relock
    #     cannot start. Both attempts must fail with no live holder and no lock.
    s="$(make_manifest_lock_sandbox sec-s10b-user)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    before="$(cat "$s/manifest/install-manifest.json")"
    chmod 0755 "$s"
    chown 1000:1000 "$s/manifest"
    chmod 0700 "$s/manifest"
    _lock_sec_nonroot_id_stub "$s"
    cat > "$s/user-two.sh" << 'EOF'
#!/usr/bin/env bash
export PATH="$1/stub:$PATH" LOG_FILE="$1/manifest/test.log"
cd /
source "$2/lib/backup.sh"
for who in a b; do
    rc=0; manifest_lock || rc=$?
    printf '%s\n' "$rc" > "$1/manifest/$who.rc"
    printf '%s\n' "${MANIFEST_LOCK_HOLDER_PID:-<empty>}" > "$1/manifest/$who.pid"
done
EOF
    chmod 0755 "$s/user-two.sh"
    run_sandboxed "$s" '
        setpriv --reuid=1000 --regid=1000 --clear-groups \
            bash "$2/user-two.sh" "$2" "$1"
    '
    assert_eq "1" "$(cat "$s/manifest/a.rc" 2> /dev/null || echo MISSING)" \
        "SEC S10b(i): first acquisition in user-owned parent fails"
    assert_eq "1" "$(cat "$s/manifest/b.rc" 2> /dev/null || echo MISSING)" \
        "SEC S10b(i): second acquisition in user-owned parent fails"
    assert_eq "<empty>" "$(cat "$s/manifest/a.pid" 2> /dev/null || echo MISSING)" \
        "SEC S10b(i): no holder A left behind"
    assert_eq "<empty>" "$(cat "$s/manifest/b.pid" 2> /dev/null || echo MISSING)" \
        "SEC S10b(i): no holder B left behind"
    assert_eq "absent" "$([ -e "$lock" ] || [ -L "$lock" ] && echo present || echo absent)" \
        "SEC S10b(i): no lock inode created"
    assert_eq "$before" "$(cat "$s/manifest/install-manifest.json" 2> /dev/null || echo MISSING)" \
        "SEC S10b(i): manifest bytes unchanged"

    # (ii) With a root-owned parent, an unprivileged account cannot rename the
    #      live lock aside; a contender times out instead of locking a new inode.
    s="$(make_manifest_lock_sandbox sec-s10b-root)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    before="$(cat "$s/manifest/install-manifest.json")"
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=5
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/a.rc"
        if [ "$rc" -eq 0 ]; then
            printf "%s\n" "$(stat -c %i -- "$MANIFEST_LOCK_FILE")" > "$2/a.ino"
            : > "$2/a.held"
            i=0
            while [ ! -e "$2/a.release" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i+1)); done
            manifest_unlock
        fi
    ' &
    local pa=$! i=0
    while [ ! -e "$s/a.held" ] && [ "$i" -lt 200 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    if [ -e "$s/a.held" ]; then ok; else fail "SEC S10b(ii): A never acquired the lock"; fi
    chmod 0755 "$s" "$s/manifest"
    local rename_rc=0
    # The redirect is intentionally performed by the root shell, not by sudo.
    # Force an English diagnostic: the host locale may render EACCES in any
    # language, but the assertion below checks for "Permission denied".
    # shellcheck disable=SC2024
    sudo -n -u nobody -- env LC_ALL=C mv "$lock" "$s/manifest/moved" > "$s/rename.log" 2>&1 || rename_rc=$?
    assert_eq "1" "$rename_rc" \
        "SEC S10b(ii): nobody cannot rename the live lock in a root-owned parent"
    # A non-zero rc alone is not proof: a broken sudo/user lookup would also
    # return 1. Require the real EACCES diagnostic so this case cannot pass
    # for an unrelated reason.
    assert_contains "Permission denied" "$(cat "$s/rename.log" 2> /dev/null || echo "")" \
        "SEC S10b(ii): rename was denied by permissions (not sudo/user lookup)"
    if [ -s "$s/rename.log" ]; then ok; else fail "SEC S10b(ii): rename denial left no diagnostic"; fi
    assert_eq "$(cat "$s/a.ino" 2> /dev/null || echo MISSING)" \
        "$(stat -c %i -- "$lock" 2> /dev/null || echo MISSING)" \
        "SEC S10b(ii): the locked inode is still at the original path"
    assert_eq "absent" "$([ -e "$s/manifest/moved" ] && echo present || echo absent)" \
        "SEC S10b(ii): no renamed lock file appeared"

    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=1
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/b.rc"
        if [ "$rc" -eq 0 ]; then manifest_unlock; fi
    '
    assert_eq "1" "$(cat "$s/b.rc" 2> /dev/null || echo MISSING)" \
        "SEC S10b(ii): contender B times out instead of holding a second inode"
    : > "$s/a.release"
    worker_wait_pid "$pa"
    assert_eq "0" "$(cat "$s/a.rc" 2> /dev/null || echo MISSING)" "SEC S10b(ii): A released cleanly"
    assert_eq "$before" "$(cat "$s/manifest/install-manifest.json" 2> /dev/null || echo MISSING)" \
        "SEC S10b(ii): manifest bytes unchanged"
    assert_eq "1" "$(find "$s/manifest" -maxdepth 1 -name '.install-manifest.lock*' | wc -l | tr -d '[:space:]')" \
        "SEC S10b(ii): exactly one lock inode exists"
}

test_sec_lock_helper_rechecks_parent_dir() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-s10c)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    chown 1000:1000 "$s/manifest"
    chmod 0700 "$s/manifest"
    # Force the snippet past the parent-shell gate: the ONLY remaining guard is
    # the root holder's fd-8 recheck of the direct parent.
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        _manifest_lock_dir_ok() { return 0; }
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/lock.rc"
        if [ -n "$MANIFEST_LOCK_HOLDER_PID" ] && kill -0 "$MANIFEST_LOCK_HOLDER_PID" 2>/dev/null; then
            printf "holder-alive\n" > "$2/holder.txt"
        else
            printf "holder-none\n" > "$2/holder.txt"
        fi
        if eval ": >&${MANIFEST_LOCK_HOLDER_WFD}" 2> /dev/null; then
            printf "wfd-open\n" > "$2/wfd.txt"
        else
            printf "wfd-closed\n" > "$2/wfd.txt"
        fi
        # No hardcoded rc: actually run the mutation helper and record the
        # rc it returns. With the holder rejecting the parent it must fail
        # closed for real, not just because a test wrote "1" into gate.rc.
        if [ "$rc" -ne 0 ]; then
            g=0; backup_file_manifest_aware "$2/root/audio.conf" audio || g=$?
            printf "%s\n" "$g" > "$2/gate.rc"
        else
            printf "unexpected-lock-success\n" > "$2/gate.rc"
        fi
    '
    _lock_sec_fail_asserts "$s" "FAILED:parentdir"
    # init may leave the 0600 inode behind; what matters is that nobody holds
    # it (asserted above by holder-none / wfd-closed / blocked mutation gate).
    assert_eq "600" "$(stat -c '%a' "$lock" 2> /dev/null || echo MISSING)" \
        "SEC S10c: lock stays root-owned 0600 after the holder rejected the parent"
}

test_sec_lock_nonroot_root_owned_dir_succeeds() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-t13)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"
    chmod 0755 "$s"
    # The rule is about the DIRECTORY's owner, never the caller's. The `id`
    # stub makes a caller-based gate fail visibly even though this suite runs
    # as root (same control pattern as the keyd snapshot-base tests).
    _lock_sec_nonroot_id_stub "$s"
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/lock.rc"
        if [ "$rc" -eq 0 ]; then
            g=0; backup_file_manifest_aware "$2/root/audio.conf" audio || g=$?
            printf "%s\n" "$g" > "$2/gate.rc"
            manifest_unlock
            printf "%s\n" "$?" > "$2/unlock.rc"
        else
            printf "1\n" > "$2/gate.rc"
            printf "1\n" > "$2/unlock.rc"
        fi
    '
    assert_eq "0" "$(cat "$s/lock.rc" 2> /dev/null || echo MISSING)" \
        "SEC T13: root-owned parent accepted despite non-root id -u stub"
    assert_eq "0" "$(cat "$s/gate.rc" 2> /dev/null || echo MISSING)" \
        "SEC T13: mutation helper runs under the lock"
    assert_eq "0" "$(cat "$s/unlock.rc" 2> /dev/null || echo MISSING)" \
        "SEC T13: unlock succeeds"
    assert_eq "600" "$(stat -c '%a' "$lock" 2> /dev/null || echo MISSING)" \
        "SEC T13: lock is still root-owned 0600"
    assert_eq "1" "$(manifest_count "$s/manifest/install-manifest.json" records)" \
        "SEC T13: exactly one record written"
}

# ---------------------------------------------------------------------------
# Phase 3 (ancestor-gate) regression coverage. A sticky world-writable layer
# is only safe when ROOT owns it: a user-owned 1777 ancestor still lets its
# owner rename a live lock pathname and plant a second "exclusive" holder.
# Every case below drives manifest_lock() (or the gate itself), so no-op'ing
# _manifest_lock_ancestors_ok() (mutation M4) makes S10d fail.
# ---------------------------------------------------------------------------
_lock_sec_ancestor_case() {
    # $1=sandbox $2=case name $3=manifest dir $4=expected manifest bytes
    run_sandboxed "$1" '
        export LOG_FILE="$2/$3.log"
        source "$1/lib/backup.sh"
        MANIFEST_DIR="$4"
        MANIFEST_LOCK_FILE="$MANIFEST_DIR/.install-manifest.lock"
        printf "%s" "$5" > "$MANIFEST_DIR/install-manifest.json"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/$3.lock.rc"
        if [ -n "$MANIFEST_LOCK_HOLDER_PID" ] && kill -0 "$MANIFEST_LOCK_HOLDER_PID" 2>/dev/null; then
            printf "holder-alive\n" > "$2/$3.holder.txt"
        else
            printf "holder-none\n" > "$2/$3.holder.txt"
        fi
        if eval ": >&${MANIFEST_LOCK_HOLDER_WFD}" 2>/dev/null; then
            printf "wfd-open\n" > "$2/$3.wfd.txt"
        else
            printf "wfd-closed\n" > "$2/$3.wfd.txt"
        fi
        if [ -e "$MANIFEST_LOCK_FILE" ] || [ -L "$MANIFEST_LOCK_FILE" ]; then
            printf "present\n" > "$2/$3.inode.txt"
        else
            printf "absent\n" > "$2/$3.inode.txt"
        fi
        if [ "$rc" -eq 0 ]; then manifest_unlock; fi
    ' "$2" "$3" "$4"
}

test_sec_lock_ancestor_gate() {
    local s before
    s="$(make_manifest_lock_sandbox sec-s10d)"
    chmod 0755 "$s"
    before="$_SEC_MANIFEST"

    # (i) The bug: a user-owned 01777 ancestor was previously accepted purely
    # because it is sticky. Its owner can still rename the lock pathname.
    mkdir -p "$s/untrusted/manifest"
    chown 0:0 "$s/untrusted" "$s/untrusted/manifest"
    chmod 0755 "$s/untrusted/manifest"
    chown 1000:1000 "$s/untrusted"
    chmod 01777 "$s/untrusted"
    _lock_sec_ancestor_case "$s" u1777 "$s/untrusted/manifest" "$before"
    assert_eq "1" "$(cat "$s/u1777.lock.rc" 2> /dev/null || echo MISSING)" \
        "SEC S10d(i): user-owned 01777 ancestor is rejected"
    assert_contains "not root-controlled" "$(cat "$s/u1777.log" 2> /dev/null || echo "")" \
        "SEC S10d(i): rejection is logged"
    assert_eq "holder-none" "$(cat "$s/u1777.holder.txt" 2> /dev/null || echo MISSING)" \
        "SEC S10d(i): no root holder left alive"
    assert_eq "wfd-closed" "$(cat "$s/u1777.wfd.txt" 2> /dev/null || echo MISSING)" \
        "SEC S10d(i): coproc write fd closed"
    assert_eq "absent" "$(cat "$s/u1777.inode.txt" 2> /dev/null || echo MISSING)" \
        "SEC S10d(i): no lock inode created"
    assert_eq "$before" "$(cat "$s/untrusted/manifest/install-manifest.json" 2> /dev/null || echo MISSING)" \
        "SEC S10d(i): manifest bytes unchanged"

    # (ii) Control: a ROOT-owned sticky world-writable ancestor (/tmp itself)
    # must stay usable, so the fix does not break the legitimate exception.
    mkdir -p "$s/sticky/manifest"
    chown 0:0 "$s/sticky" "$s/sticky/manifest"
    chmod 01777 "$s/sticky"
    chmod 0755 "$s/sticky/manifest"
    _lock_sec_ancestor_case "$s" sticky "$s/sticky/manifest" "$before"
    assert_eq "0" "$(cat "$s/sticky.lock.rc" 2> /dev/null || echo MISSING)" \
        "SEC S10d(ii): root-owned 01777 ancestor is accepted"
    assert_eq "holder-alive" "$(cat "$s/sticky.holder.txt" 2> /dev/null || echo MISSING)" \
        "SEC S10d(ii): holder really acquired the lock"
    assert_eq "wfd-open" "$(cat "$s/sticky.wfd.txt" 2> /dev/null || echo MISSING)" \
        "SEC S10d(ii): coproc write fd still open while held"
    assert_eq "present" "$(cat "$s/sticky.inode.txt" 2> /dev/null || echo MISSING)" \
        "SEC S10d(ii): lock inode created under root-owned sticky ancestor"

    # (iii) A root-owned but group/other-writable NON-sticky ancestor is still
    # rejected: any group member could rename the lock pathname.
    mkdir -p "$s/groupwritable/manifest"
    chown 0:0 "$s/groupwritable" "$s/groupwritable/manifest"
    chmod 0775 "$s/groupwritable"
    chmod 0755 "$s/groupwritable/manifest"
    _lock_sec_ancestor_case "$s" gw "$s/groupwritable/manifest" "$before"
    assert_eq "1" "$(cat "$s/gw.lock.rc" 2> /dev/null || echo MISSING)" \
        "SEC S10d(iii): root-owned group-writable non-sticky ancestor is rejected"
    assert_contains "not root-controlled" "$(cat "$s/gw.log" 2> /dev/null || echo "")" \
        "SEC S10d(iii): rejection is logged"
    assert_eq "absent" "$(cat "$s/gw.inode.txt" 2> /dev/null || echo MISSING)" \
        "SEC S10d(iii): no lock inode created"

    # (iv) An ancestor symlink inside an untrusted containing directory is
    # rejected with the dedicated diagnostic.
    mkdir -p "$s/linktarget/manifest" "$s/linkparent"
    chown 0:0 "$s/linktarget" "$s/linktarget/manifest"
    chmod 0755 "$s/linktarget" "$s/linktarget/manifest"
    chown 1000:1000 "$s/linkparent"
    chmod 0755 "$s/linkparent"
    ln -s "$s/linktarget" "$s/linkparent/link"
    _lock_sec_ancestor_case "$s" symlink "$s/linkparent/link/manifest" "$before"
    assert_eq "1" "$(cat "$s/symlink.lock.rc" 2> /dev/null || echo MISSING)" \
        "SEC S10d(iv): untrusted symlink ancestor is rejected"
    assert_contains "untrusted symlink" "$(cat "$s/symlink.log" 2> /dev/null || echo "")" \
        "SEC S10d(iv): symlink rejection is logged"
    assert_eq "absent" "$(cat "$s/symlink.inode.txt" 2> /dev/null || echo MISSING)" \
        "SEC S10d(iv): no lock inode created behind the symlink"

    # Direct mutation guard: call the gate itself, so an M4 no-op is caught
    # even if a future refactor bypasses manifest_lock()'s normal path.
    run_sandboxed "$s" '
        export LOG_FILE="$2/direct.log"
        source "$1/lib/backup.sh"
        rc=0; _manifest_lock_ancestors_ok "$2/untrusted/manifest" || rc=$?
        printf "%s\n" "$rc" > "$2/direct.rc"
    '
    assert_eq "1" "$(cat "$s/direct.rc" 2> /dev/null || echo MISSING)" \
        "SEC S10d(v): _manifest_lock_ancestors_ok rejects the user-owned ancestor directly"
    assert_contains "not root-controlled" "$(cat "$s/direct.log" 2> /dev/null || echo "")" \
        "SEC S10d(v): direct gate rejection is logged"
}

# ---------------------------------------------------------------------------
# Re-review #12 finding #1 (P2 SECURITY, BLOCKER for a custom manifest path).
# The trust boundary is the CANONICAL (realpath-resolved, symlink-free) parent,
# not the literal pathname. R1 rejects a relative path in a user-owned CWD;
# R2 rejects a root-owned symlink and probes the resolved ancestor directly;
# R2e2e closes the end-to-end gap: with NO literal symlink and a root-owned
# direct parent, production manifest_lock() must still fail on a user-owned
# CANONICAL ancestor (the mut-C guard); R3 proves the holder re-derives the
# canonical path inside its own fd-9 process and rejects a symlink-derived
# lock path (no second-holder/flock contention is claimed there); R4 is the
# no-regression control. All sandboxes live under /tmp (root-owned sticky),
# so the legitimate /tmp exception stays on.
# ---------------------------------------------------------------------------

test_sec_lock_rejects_relative_manifest_dir() {
    local s cwd lock before
    s="$(make_manifest_lock_sandbox sec-r1)"
    chmod 0755 "$s" # let uid 1000 traverse the sandbox
    cwd="$s/relcwd"
    mkdir -p "$cwd/state"
    chown 0:0 "$cwd/state"
    chmod 0755 "$cwd/state" # the literal 'state' is root-owned
    chown 1000:1000 "$cwd"
    chmod 0700 "$cwd" # but the REAL parent (CWD) is not
    lock="$cwd/state/.install-manifest.lock"
    printf '%s' "$_SEC_MANIFEST" > "$cwd/state/install-manifest.json"
    before="$(cat "$cwd/state/install-manifest.json")"
    cat > "$s/user-relative.sh" << 'EOF'
#!/usr/bin/env bash
export PATH="$1/stub:$PATH" LOG_FILE="$1/relcwd/test.log"
cd "$1/relcwd" || exit 99
source "$2/lib/backup.sh"
MANIFEST_DIR="state"
MANIFEST_LOCK_FILE="$MANIFEST_DIR/.install-manifest.lock"
rc=0; manifest_lock || rc=$?
printf '%s\n' "$rc" > "$1/relcwd/lock.rc"
if [ -n "$MANIFEST_LOCK_HOLDER_PID" ] && kill -0 "$MANIFEST_LOCK_HOLDER_PID" 2>/dev/null; then
    printf 'holder-alive\n' > "$1/relcwd/holder.txt"
else
    printf 'holder-none\n' > "$1/relcwd/holder.txt"
fi
if eval ": >&${MANIFEST_LOCK_HOLDER_WFD}" 2>/dev/null; then
    printf 'wfd-open\n' > "$1/relcwd/wfd.txt"
else
    printf 'wfd-closed\n' > "$1/relcwd/wfd.txt"
fi
EOF
    chmod 0755 "$s/user-relative.sh"
    run_sandboxed "$s" '
        setpriv --reuid=1000 --regid=1000 --clear-groups \
            bash "$2/user-relative.sh" "$2" "$1"
    '
    assert_eq "1" "$(cat "$cwd/lock.rc" 2> /dev/null || echo MISSING)" \
        "SEC R1: relative manifest directory fails closed"
    assert_contains "must be an absolute path" "$(cat "$cwd/test.log" 2> /dev/null || echo "")" \
        "SEC R1: absolute-path requirement is logged"
    assert_eq "holder-none" "$(cat "$cwd/holder.txt" 2> /dev/null || echo MISSING)" \
        "SEC R1: no root holder left alive"
    assert_eq "wfd-closed" "$(cat "$cwd/wfd.txt" 2> /dev/null || echo MISSING)" \
        "SEC R1: coproc write fd closed"
    assert_eq "absent" "$([ -e "$lock" ] || [ -L "$lock" ] && echo present || echo absent)" \
        "SEC R1: no lock inode created for the relative path"
    assert_eq "$before" "$(cat "$cwd/state/install-manifest.json" 2> /dev/null || echo MISSING)" \
        "SEC R1: manifest bytes unchanged"
}

test_sec_lock_rejects_trusted_symlink_to_user_target() {
    local s lock before canon
    s="$(make_manifest_lock_sandbox sec-r2)"
    chmod 0755 "$s"
    mkdir -p "$s/sym/store/state" "$s/sym/trusted"
    chown 1000:1000 "$s/sym/store"
    chmod 0700 "$s/sym/store" # the symlink TARGET's parent is user-owned
    chown 0:0 "$s/sym/store/state"
    chmod 0755 "$s/sym/store/state" # the literal 'state' component is root-owned
    chown 0:0 "$s/sym/trusted"
    chmod 0755 "$s/sym/trusted"
    ln -s "$s/sym/store" "$s/sym/trusted/link" # root-owned symlink
    lock="$s/sym/store/state/.install-manifest.lock"
    printf '%s' "$_SEC_MANIFEST" > "$s/sym/store/state/install-manifest.json"
    before="$(cat "$s/sym/store/state/install-manifest.json")"
    canon="$(realpath -e -- "$s/sym/trusted/link/state")"
    cat > "$s/user-symlink.sh" << 'EOF'
#!/usr/bin/env bash
export PATH="$1/stub:$PATH" LOG_FILE="$1/sym/store/test.log"
cd / || exit 99
source "$2/lib/backup.sh"
MANIFEST_DIR="$1/sym/trusted/link/state"
MANIFEST_LOCK_FILE="$MANIFEST_DIR/.install-manifest.lock"
rc=0; manifest_lock || rc=$?
printf '%s\n' "$rc" > "$1/sym/store/lock.rc"
if [ -n "$MANIFEST_LOCK_HOLDER_PID" ] && kill -0 "$MANIFEST_LOCK_HOLDER_PID" 2>/dev/null; then
    printf 'holder-alive\n' > "$1/sym/store/holder.txt"
else
    printf 'holder-none\n' > "$1/sym/store/holder.txt"
fi
if eval ": >&${MANIFEST_LOCK_HOLDER_WFD}" 2>/dev/null; then
    printf 'wfd-open\n' > "$1/sym/store/wfd.txt"
else
    printf 'wfd-closed\n' > "$1/sym/store/wfd.txt"
fi
# Probe the ancestor gate on the RESOLVED path independently of the literal
# symlink rejection: its real parent is uid 1000, so it must also be rejected.
resolved="$(realpath -e -- "$MANIFEST_DIR" 2>/dev/null || echo MISSING)"
printf '%s\n' "$resolved" > "$1/sym/store/canon.txt"
arc=0; _manifest_lock_ancestors_ok "$resolved" || arc=$?
printf '%s\n' "$arc" > "$1/sym/store/ancestor.rc"
EOF
    chmod 0755 "$s/user-symlink.sh"
    run_sandboxed "$s" '
        setpriv --reuid=1000 --regid=1000 --clear-groups \
            bash "$2/user-symlink.sh" "$2" "$1"
    '
    assert_eq "1" "$(cat "$s/sym/store/lock.rc" 2> /dev/null || echo MISSING)" \
        "SEC R2: root-owned symlink to a user-owned target fails closed"
    assert_contains "contains a symlink" "$(cat "$s/sym/store/test.log" 2> /dev/null || echo "")" \
        "SEC R2: literal symlink rejection is logged"
    assert_eq "$canon" "$(cat "$s/sym/store/canon.txt" 2> /dev/null || echo MISSING)" \
        "SEC R2: resolved realpath is the user-owned target"
    assert_eq "1" "$(cat "$s/sym/store/ancestor.rc" 2> /dev/null || echo MISSING)" \
        "SEC R2: ancestor gate rejects the resolved user-owned parent"
    assert_contains "not root-controlled" "$(cat "$s/sym/store/test.log" 2> /dev/null || echo "")" \
        "SEC R2: realpath ancestor rejection is logged"
    assert_eq "holder-none" "$(cat "$s/sym/store/holder.txt" 2> /dev/null || echo MISSING)" \
        "SEC R2: no root holder left alive"
    assert_eq "wfd-closed" "$(cat "$s/sym/store/wfd.txt" 2> /dev/null || echo MISSING)" \
        "SEC R2: coproc write fd closed"
    assert_eq "absent" "$([ -e "$lock" ] || [ -L "$lock" ] && echo present || echo absent)" \
        "SEC R2: no lock inode created behind the symlink"
    assert_eq "$before" "$(cat "$s/sym/store/state/install-manifest.json" 2> /dev/null || echo MISSING)" \
        "SEC R2: manifest bytes unchanged"
}

# R2 only reaches the ancestor gate through a DIRECT _manifest_lock_ancestors_ok()
# probe: its literal path contains a symlink, so manifest_lock() fails earlier
# at the literal-symlink check. No-op'ing the production gate call (mut-C) left
# all R2 assertions green. R2e2e removes that escape hatch: every literal
# component is a real directory, the literal direct parent is root-owned 0755,
# and ONLY the canonical realpath exposes the user-owned layer. The rejection
# therefore has to come from _manifest_lock_canonical_dir() -> ancestor gate.
test_sec_lock_canonical_ancestor_user_dir() {
    local s dir canon canon_expected lock before
    s="$(make_manifest_lock_sandbox sec-r2e2e)"
    chmod 0755 "$s"
    mkdir -p "$s/trusted" "$s/userdir/sub"
    chown 0:0 "$s/trusted" "$s/userdir/sub"
    chmod 0755 "$s/trusted" "$s/userdir/sub"
    chown 1000:1000 "$s/userdir"
    chmod 0700 "$s/userdir"

    # trusted/.. contains no symlink; stat() of the literal path resolves to
    # the root-owned 'sub', but realpath() resolves to the user-owned parent.
    dir="$s/trusted/../userdir/sub"
    canon="$(realpath -e -- "$dir")"
    canon_expected="$(realpath -e -- "$s/userdir/sub")"
    lock="$canon/.install-manifest.lock"
    printf '%s' "$_SEC_MANIFEST" > "$dir/install-manifest.json"
    before="$(cat "$dir/install-manifest.json")"

    # Setup preconditions: prove this is NOT caught by the literal checks.
    assert_eq "no" "$([ -L "$s/trusted" ] || [ -L "$s/userdir" ] || [ -L "$s/userdir/sub" ] && echo yes || echo no)" \
        "SEC R2e2e: the literal path has no symlink component"
    assert_eq "0:755" "$(stat -c '%u:%a' -- "$dir")" \
        "SEC R2e2e: the literal direct parent is root-owned 0755"
    assert_eq "$canon_expected" "$canon" \
        "SEC R2e2e: canonical realpath hides the trusted/.. layer"
    assert_eq "1000:700" "$(stat -c '%u:%a' -- "$s/userdir")" \
        "SEC R2e2e: the canonical ancestor is user-owned 0700"

    _lock_sec_ancestor_case "$s" r2e2e "$dir" "$before"
    assert_eq "1" "$(cat "$s/r2e2e.lock.rc" 2> /dev/null || echo MISSING)" \
        "SEC R2e2e: production manifest_lock fails closed on a user-owned canonical ancestor"
    assert_contains "not root-controlled" "$(cat "$s/r2e2e.log" 2> /dev/null || echo "")" \
        "SEC R2e2e: the ancestor gate logged the user-owned realpath layer"
    assert_contains "untrusted realpath ancestor" "$(cat "$s/r2e2e.log" 2> /dev/null || echo "")" \
        "SEC R2e2e: _manifest_lock_canonical_dir reported the untrusted realpath"
    assert_eq "holder-none" "$(cat "$s/r2e2e.holder.txt" 2> /dev/null || echo MISSING)" \
        "SEC R2e2e: no root holder left alive"
    assert_eq "wfd-closed" "$(cat "$s/r2e2e.wfd.txt" 2> /dev/null || echo MISSING)" \
        "SEC R2e2e: coproc write fd closed"
    assert_eq "absent" "$([ -e "$lock" ] || [ -L "$lock" ] && echo present || echo absent)" \
        "SEC R2e2e: no lock inode created"
    assert_eq "$before" "$(cat "$dir/install-manifest.json" 2> /dev/null || echo MISSING)" \
        "SEC R2e2e: manifest bytes unchanged"
}

test_sec_lock_holder_rejects_symlink_derived_path() {
    local s before pa new_ino
    s="$(make_manifest_lock_sandbox sec-r3)"
    chmod 0755 "$s" # let uid 1000 traverse and rename
    _lock_sec_prepare "$s"
    before="$(cat "$s/manifest/install-manifest.json")"

    # A holds a real lock on its own root-owned sandbox manifest path. It is
    # NOT a contender for B's path below (different inode, no flock sharing):
    # it only proves the ordinary lock machinery works in this sandbox first.
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=5
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/a.rc"
        if [ "$rc" -eq 0 ]; then
            printf "%s\n" "$(stat -c %i -- "$MANIFEST_LOCK_FILE")" > "$2/a.ino"
            : > "$2/a.held"
            i=0
            while [ ! -e "$2/a.release" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i+1)); done
            manifest_unlock
        fi
    ' &
    pa=$!
    if op_wait_for_file "$s/a.held" 200; then ok; else fail "SEC R3: A never acquired the lock"; fi

    # Set up a root-owned symlink in a trusted dir pointing into 'store', which
    # uid 1000 owns. The rename below refreshes the lock inode at the symlink
    # target; B's literal path traverses the symlink, so its canonical realpath
    # differs from the literal pathname the holder was handed.
    mkdir -p "$s/store/state" "$s/trusted"
    chown 1000:1000 "$s/store"
    chmod 0700 "$s/store"
    chown 0:0 "$s/store/state"
    chmod 0755 "$s/store/state"
    chown 0:0 "$s/trusted"
    chmod 0755 "$s/trusted"
    ln -s "$s/store" "$s/trusted/link"
    printf '%s' "$_SEC_MANIFEST" > "$s/store/state/install-manifest.json"
    : > "$s/store/state/.install-manifest.lock"
    chmod 0600 "$s/store/state/.install-manifest.lock"

    cat > "$s/user-rename.sh" << 'EOF'
#!/usr/bin/env bash
mv "$1/store/state" "$1/store/state.moved" || exit 1
mkdir -p "$1/store/state" || exit 1
printf 'ok\n' > "$1/store/rename.rc"
EOF
    chmod 0755 "$s/user-rename.sh"
    run_sandboxed "$s" '
        setpriv --reuid=1000 --regid=1000 --clear-groups \
            bash "$2/user-rename.sh" "$2"
    '
    assert_eq "ok" "$(cat "$s/store/rename.rc" 2> /dev/null || echo MISSING)" \
        "SEC R3: uid 1000 legally renamed the user-owned store/state"
    chown 0:0 "$s/store/state"
    chmod 0755 "$s/store/state"
    printf '%s' "$_SEC_MANIFEST" > "$s/store/state/install-manifest.json"
    : > "$s/store/state/.install-manifest.lock"
    chmod 0600 "$s/store/state/.install-manifest.lock"
    new_ino="$(stat -c %i -- "$s/store/state/.install-manifest.lock")"

    # B bypasses the parent-shell gate (a TOCTOU simulation, as in S10c) so the
    # ONLY guard under test is the holder's canonical re-verification inside the
    # fd-9 process. No second-holder/flock contention with A is implied here.
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=2
        source "$1/lib/backup.sh"
        _manifest_lock_dir_ok() { return 0; }
        MANIFEST_DIR="$2/trusted/link/state"
        MANIFEST_LOCK_FILE="$MANIFEST_DIR/.install-manifest.lock"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/b.rc"
        if [ -n "$MANIFEST_LOCK_HOLDER_PID" ] && kill -0 "$MANIFEST_LOCK_HOLDER_PID" 2>/dev/null; then
            printf "holder-alive\n" > "$2/b.holder.txt"
        else
            printf "holder-none\n" > "$2/b.holder.txt"
        fi
        if eval ": >&${MANIFEST_LOCK_HOLDER_WFD}" 2>/dev/null; then
            printf "wfd-open\n" > "$2/b.wfd.txt"
        else
            printf "wfd-closed\n" > "$2/b.wfd.txt"
        fi
        if [ "$rc" -eq 0 ]; then manifest_unlock; fi
    '
    : > "$s/a.release"
    worker_wait_pid "$pa"
    assert_eq "0" "$(cat "$s/a.rc" 2> /dev/null || echo MISSING)" \
        "SEC R3: A held and released its legitimate lock"
    assert_eq "1" "$(cat "$s/b.rc" 2> /dev/null || echo MISSING)" \
        "SEC R3: B's lock request on the symlink-derived path fails closed"
    assert_eq "holder-none" "$(cat "$s/b.holder.txt" 2> /dev/null || echo MISSING)" \
        "SEC R3: no holder survives for the symlink-derived path"
    assert_eq "wfd-closed" "$(cat "$s/b.wfd.txt" 2> /dev/null || echo MISSING)" \
        "SEC R3: B's coproc write fd closed"
    assert_contains "FAILED:canonical" "$(cat "$s/log.txt" 2> /dev/null || echo "")" \
        "SEC R3: holder re-derived the canonical realpath inside fd 9's process and rejected the symlink-derived path"
    assert_eq "1" "$(find "$s/store/state" -maxdepth 1 -name '.install-manifest.lock*' | wc -l | tr -d '[:space:]')" \
        "SEC R3: exactly one lock inode in the symlink target directory"
    assert_eq "$new_ino" "$(stat -c %i -- "$s/store/state/.install-manifest.lock" 2> /dev/null || echo MISSING)" \
        "SEC R3: the symlink target's lock inode was not replaced"
    assert_eq "$before" "$(cat "$s/manifest/install-manifest.json" 2> /dev/null || echo MISSING)" \
        "SEC R3: A's manifest bytes unchanged"
}

test_sec_lock_absolute_root_owned_dir_control() {
    local s lock
    s="$(make_manifest_lock_sandbox sec-r4)"
    _lock_sec_prepare "$s"
    lock="$s/manifest/.install-manifest.lock"

    # (a) root caller: the canonical path must be published and usable.
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/r4-root-lock.rc"
        printf "%s\n" "$MANIFEST_LOCK_CANON_DIR" > "$2/r4-root-dir.txt"
        printf "%s\n" "$MANIFEST_LOCK_CANON_FILE" > "$2/r4-root-file.txt"
        if [ "$rc" -eq 0 ]; then
            g=0; backup_file_manifest_aware "$2/root/audio.conf" audio || g=$?
            printf "%s\n" "$g" > "$2/r4-root-gate.rc"
            manifest_unlock
        fi
    '
    assert_eq "0" "$(cat "$s/r4-root-lock.rc" 2> /dev/null || echo MISSING)" \
        "SEC R4(a): absolute root-owned path accepted (root caller)"
    assert_eq "$s/manifest" "$(cat "$s/r4-root-dir.txt" 2> /dev/null || echo MISSING)" \
        "SEC R4(a): canonical lock directory published"
    assert_eq "$lock" "$(cat "$s/r4-root-file.txt" 2> /dev/null || echo MISSING)" \
        "SEC R4(a): canonical lock file published"
    assert_eq "0" "$(cat "$s/r4-root-gate.rc" 2> /dev/null || echo MISSING)" \
        "SEC R4(a): mutation helper runs under the lock"
    assert_eq "600" "$(stat -c '%a' "$lock" 2> /dev/null || echo MISSING)" \
        "SEC R4(a): lock stays root-owned 0600"

    # (b) a caller that reports uid 1000 via `id -u` still succeeds, because
    # ownership/permission checks use stat, never the caller's identity.
    _lock_sec_nonroot_id_stub "$s"
    run_sandboxed "$s" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        rc=0; manifest_lock || rc=$?
        printf "%s\n" "$rc" > "$2/r4-stub-lock.rc"
        if [ "$rc" -eq 0 ]; then
            g=0; backup_file_manifest_aware "$2/root/audio.conf" audio || g=$?
            printf "%s\n" "$g" > "$2/r4-stub-gate.rc"
            manifest_unlock
        fi
    '
    assert_eq "0" "$(cat "$s/r4-stub-lock.rc" 2> /dev/null || echo MISSING)" \
        "SEC R4(b): absolute root-owned path accepted (id -u stub = 1000)"
    assert_eq "0" "$(cat "$s/r4-stub-gate.rc" 2> /dev/null || echo MISSING)" \
        "SEC R4(b): mutation helper runs under the lock"
    assert_eq "1" "$(manifest_count "$s/manifest/install-manifest.json" records)" \
        "SEC R4(b): exactly one record written (first-wins preserved)"
    assert_eq "0" "$(manifest_count "$s/manifest/install-manifest.json" services)" \
        "SEC R4: no spurious service records"
}

# ---------------------------------------------------------------------------
# Re-review #10 finding #1: operation-level lock regressions (OP1-OP4).
# OP1/OP2 use a REAL `sudo install -D` barrier: A records the target, pauses
# before writing it, B races with rollback on the SAME target. OP3 proves the
# body is never entered when acquisition fails. OP4 proves the bare call keeps
# `set -e` inside a wrapped installer (no fail-open deployment).
# ---------------------------------------------------------------------------

test_op_deploy_vs_rollback_barrier() {
    # $1=OP id, $2=target key, $3=component, $4=initial content (empty => absent)
    local opid="$1" key="$2" comp="$3" initial="${4:-}"
    local sandbox
    sandbox="$(make_manifest_lock_sandbox "$opid-$key")"
    setup_deploy_barrier_stub "$sandbox"
    manifest_lock_barrier_init "$sandbox"
    local target="$sandbox/root/deployed.conf"
    if [ -n "$initial" ]; then
        printf '%s\n' "$initial" > "$target"
    fi
    printf 'DEPLOYED CONTENT\n' > "$sandbox/deploy.src"
    local manifest="$sandbox/manifest/install-manifest.json"
    export STUB_DEPLOY_BARRIER=1 STUB_FIRED_FILE="$sandbox/fired" \
        STUB_RELEASE_FILE="$sandbox/release"

    run_sandboxed "$sandbox" "$OP_DEPLOY_WORKER" "$target" "$comp" &
    local pa=$!
    barrier_release "$sandbox" 1
    if op_wait_for_file "$sandbox/fired" 200; then
        ok
    else
        fail "OP [$opid $key]: deploy stub never fired"
    fi
    # The record is committed BEFORE the stub fires (backup gate -> record ->
    # install). A's operation lock must still be held at this point.
    assert_eq "1" "$(manifest_count "$manifest" records 2> /dev/null || echo MISSING)" \
        "OP [$opid $key]: deploy record committed before the barrier"

    run_sandboxed "$sandbox" "$OP_ROLLBACK_WORKER" "$comp" &
    local pb=$!
    if op_wait_for_file "$sandbox/b.rc" 30; then
        fail "OP [$opid $key]: rollback finished while deploy still held the operation lock"
    else
        ok
    fi
    : > "$sandbox/release"
    worker_wait_pid "$pa"
    worker_wait_pid "$pb"
    unset STUB_DEPLOY_BARRIER STUB_FIRED_FILE STUB_RELEASE_FILE

    assert_eq "0" "$(cat "$sandbox/a.rc" 2> /dev/null || echo MISSING)" \
        "OP [$opid $key]: deploy rc 0"
    assert_eq "0" "$(cat "$sandbox/b.rc" 2> /dev/null || echo MISSING)" \
        "OP [$opid $key]: rollback rc 0"
    assert_eq "0" "$(manifest_count "$manifest" records)" \
        "OP [$opid $key]: record consumed exactly once"
    if [ -n "$initial" ]; then
        assert_eq "$initial" "$(cat "$target" 2> /dev/null || echo MISSING)" \
            "OP [$opid $key]: ORIGINAL restored, not overwritten by the late deploy"
        if grep -rq "$initial" "$sandbox/backups"; then
            ok
        else
            fail "OP [$opid $key]: first backup retained"
        fi
    else
        if [ -e "$target" ]; then
            fail "OP [$opid $key]: untracked deployed file survived (record consumed too early)"
        else
            ok
        fi
    fi
}

test_op_lock_failure_skips_operation_body() {
    # (a) broken flock stub: acquisition fails before any side effect.
    local sandbox
    sandbox="$(make_manifest_lock_sandbox op3-flock)"
    cat > "$sandbox/stub/flock" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$sandbox/stub/flock"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        SB="$2"
        source "$1/lib/backup.sh"
        probe_body() {
            : > "$SB/body-called"
            printf "DEPLOYED\n" > "$SB/root/deployed.conf"
        }
        rc=0
        run_manifest_operation probe_body || rc=$?
        printf "%s\n" "$rc" > "$SB/op3.rc"
    '
    assert_eq "1" "$(cat "$sandbox/op3.rc" 2> /dev/null || echo MISSING)" \
        "OP3: broken flock -> rc 1"
    if [ -e "$sandbox/body-called" ]; then
        fail "OP3: body ran despite lock acquisition failure"
    else
        ok
    fi
    if [ -e "$sandbox/root/deployed.conf" ]; then
        fail "OP3: target deployed despite lock acquisition failure"
    else
        ok
    fi

    # (b) real external holder -> bounded timeout, same fail-closed guarantee.
    sandbox="$(make_manifest_lock_sandbox op3-timeout)"
    local lock="$sandbox/manifest/.install-manifest.lock"
    : > "$lock"
    chmod 0600 "$lock"
    (
        exec 9< "$lock"
        flock -x 9
        : > "$sandbox/held"
        sleep 5
    ) &
    local holder=$! i=0
    while [ ! -e "$sandbox/held" ] && [ "$i" -lt 200 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    if [ -e "$sandbox/held" ]; then ok; else fail "OP3: external holder never acquired"; fi
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT=1
        SB="$2"
        source "$1/lib/backup.sh"
        probe_body() {
            : > "$SB/body-called"
            printf "DEPLOYED\n" > "$SB/root/deployed.conf"
        }
        rc=0
        run_manifest_operation probe_body || rc=$?
        printf "%s\n" "$rc" > "$SB/op3-timeout.rc"
    '
    assert_eq "1" "$(cat "$sandbox/op3-timeout.rc" 2> /dev/null || echo MISSING)" \
        "OP3: timeout -> rc 1"
    if [ -e "$sandbox/body-called" ]; then
        fail "OP3: body ran despite lock timeout"
    else
        ok
    fi
    if [ -e "$sandbox/root/deployed.conf" ]; then
        fail "OP3: target deployed despite lock timeout"
    else
        ok
    fi
    kill "$holder" 2> /dev/null || true
    worker_wait_pid "$holder"
}

test_op_fail_open_guard_under_errexit() {
    # A failed manifest write must abort a wrapped installer BEFORE its
    # unguarded `sudo install -D`. Using `|| rc=$?` in run_manifest_operation
    # would disable errexit inside the body and deploy anyway (OP4 catches it).
    local sandbox
    sandbox="$(make_manifest_lock_sandbox op4)"
    prepare_keyd_sandbox_script "$sandbox"
    # Fail ONLY real writers (argc>=6); validator/probes stay real.
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "${STUB_FAIL_MANIFEST_WRITE:-0}" = "1" ] && [ "$1" = "-c" ] && [ "$#" -ge 6 ]; then
    printf 'stub: forced manifest write failure\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/python3"
    printf '%s' '{"version":"2.0","records":[],"services":[],"groups":[]}' \
        > "$sandbox/manifest/install-manifest.json"
    local target="$sandbox/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb"
    local rc=0
    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_FAIL_MANIFEST_WRITE=1 WITH_KEYD=0 \
            STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        # BARE call: sourced installer has `set -e`, so a failed gate aborts.
        install_keyboard
    '; then
        rc=0
    else
        rc=$?
    fi
    assert_eq "1" "$rc" \
        "OP4: wrapped installer rc non-zero when the manifest write fails"
    if [ -e "$target" ]; then
        fail "OP4: fail-open deployment (file exists without a manifest record)"
    else
        ok
    fi
    local wrapper_src
    wrapper_src="$(grep -n -A 16 '^run_manifest_operation()' "$REPO_ROOT/lib/backup.sh")"
    assert_contains '"$fn" "$@"' "$wrapper_src" \
        "OP4: wrapper invokes the body with a bare call"
    assert_not_contains '"$fn" "$@" ||' "$wrapper_src" \
        'OP4: wrapper does not swallow the body rc with || rc=$?'
}

test_op_real_installer_barrier() {
    # Same interleave as OP1 but through the REAL wrapped install_keyboard():
    # removing its thin wrapper must reintroduce the untracked deployed file.
    local sandbox
    sandbox="$(make_manifest_lock_sandbox op1-real-installer)"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    setup_deploy_barrier_stub "$sandbox"
    manifest_lock_barrier_init "$sandbox"
    local target="$sandbox/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb"
    local manifest="$sandbox/manifest/install-manifest.json"
    export STUB_DEPLOY_BARRIER=1 STUB_FIRED_FILE="$sandbox/fired" \
        STUB_RELEASE_FILE="$sandbox/release" \
        STUB_SYSTEMCTL_LOG="$sandbox/systemctl.log"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" WITH_KEYD=0 \
            STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        SB="$2"
        source "$SB/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        exec 3<>"$SB/ready" 4<>"$SB/go"
        printf "r\n" >&3
        read -r _ <&4
        install_keyboard
        printf "0\n" > "$SB/a.rc"
    ' &
    local pa=$!
    barrier_release "$sandbox" 1
    if op_wait_for_file "$sandbox/fired" 200; then
        ok
    else
        fail "OP [real installer]: deploy stub never fired"
    fi
    assert_eq "1" "$(manifest_count "$manifest" records 2> /dev/null || echo MISSING)" \
        "OP [real installer]: hwdb record committed before the barrier"

    run_sandboxed "$sandbox" "$OP_ROLLBACK_WORKER" keyboard &
    local pb=$!
    if op_wait_for_file "$sandbox/b.rc" 30; then
        fail "OP [real installer]: rollback finished while install held the operation lock"
    else
        ok
    fi
    : > "$sandbox/release"
    worker_wait_pid "$pa"
    worker_wait_pid "$pb"
    unset STUB_DEPLOY_BARRIER STUB_FIRED_FILE STUB_RELEASE_FILE STUB_SYSTEMCTL_LOG

    assert_eq "0" "$(cat "$sandbox/a.rc" 2> /dev/null || echo MISSING)" \
        "OP [real installer]: install_keyboard rc 0"
    assert_eq "0" "$(cat "$sandbox/b.rc" 2> /dev/null || echo MISSING)" \
        "OP [real installer]: rollback rc 0"
    if [ -e "$target" ]; then
        fail "OP [real installer]: untracked hwdb file survived the race"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# 44. Non-keyboard uninstall callers must not abort on a failed rollback.
#     rollback_component now returns 1 for failed/unknown items; with `set -e`
#     an unguarded call skips the caller's remaining cleanup. These tests run
#     the REAL uninstall functions under `set -e` and prove BOTH that the rc
#     propagates and that post-rollback cleanup still ran.
# ---------------------------------------------------------------------------

# Generate a sandbox copy of an installer: real uninstall function, no CLI
# dispatcher, host-side paths redirected into the sandbox. $3 may point at a
# modified source (used by the pre-fix negative-control test).
prepare_caller_sandbox_script() {
    local sandbox="$1" comp="$2" src
    src="${3:-$REPO_ROOT/$comp/install-$comp.sh}"
    sed \
        -e "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$sandbox/$comp\"|" \
        -e "s|^ROOT_DIR=.*|ROOT_DIR=\"$REPO_ROOT\"|" \
        -e "s|/var/lib/fprint/crfpmoc.key|$sandbox/fp/crfpmoc.key|g" \
        -e "s|/usr/local/bin/c640-ec-control|$sandbox/ec/c640-ec-control|g" \
        -e '/^ACTION=/,$d' \
        "$src" > "$sandbox/install-caller-sandbox.sh"
}

setup_caller_uninstall_sandbox() {
    local sandbox="$1" comp="$2"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/stub"
    # The sudo stub below records but does not execute `install`, so every
    # manifest mutation would fail to create the cross-process lock file.
    # Pre-create it: the lock is a normal precondition of the manifest dir
    # (re-review #9 finding #1), and this keeps the caller-rc tests focused on
    # rollback rc propagation.
    : > "$sandbox/manifest/.install-manifest.lock"
    # The root holder now requires a root-owned 0600 lock. This sudo stub never
    # actually runs chmod (it has no stub for it), so pre-create the final mode.
    chmod 0600 "$sandbox/manifest/.install-manifest.lock"

    # sudo logs each command and only execs commands that have a sandbox stub
    # (python3/udevadm/ldconfig/gpasswd/systemctl), so no host command can be
    # reached through it.
    cat > "$sandbox/stub/sudo" << 'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    python3) ;;
    *) printf '%s\n' "$*" >> "${STUB_CALL_LOG:?}" ;;
esac
[ "${1:-}" = "-u" ] && shift 2
cmd="${1:-}"
# `bash` is the root lock holder started through coproc; it must really run
# (the other commands only need a stub when one exists).
if [ "$cmd" = bash ] || [ -x "${STUB_DIR:?}/$cmd" ]; then
    exec "$@"
fi
exit 0
EOF
    # Fail ONLY the rollback python (its script contains this marker), so the
    # validator/gate and the group-record lookups still run for real.
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -eq 6 ] && [[ "$2" == *"ROLLBACK_INCOMPLETE"* ]] && [ "${STUB_FAIL_ROLLBACK_PY:-0}" = "1" ]; then
    printf 'stub: forced rollback failure\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    local stub
    for stub in udevadm ldconfig gpasswd; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$sandbox/stub/$stub"
    done
    # Direct package probes must report "not installed" so the uninstalls
    # never reach a package-removal branch.
    for stub in dpkg rpm pacman zypper; do
        printf '#!/usr/bin/env bash\nexit 1\n' > "$sandbox/stub/$stub"
    done
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${STUB_CALL_LOG:?}"\nexit 0\n' > "$sandbox/stub/systemctl"
    chmod +x "$sandbox/stub/"*

    prepare_caller_sandbox_script "$sandbox" "$comp"

    python3 - "$sandbox/manifest/install-manifest.json" "$comp" << 'PY'
import json, sys
mp, comp = sys.argv[1:3]
json.dump({"version": "2.0", "records": [], "services": [], "groups": [
    {"group": "plugdev", "user": "testuser", "component": comp,
     "was_member": False}]}, open(mp, "w"), indent=2)
PY
    : > "$sandbox/caller.log"
    : > "$sandbox/log.txt"
}

run_caller_uninstall() {
    # $1=sandbox $2=component $3=uninstall function $4=1 to force rollback rc 1
    local sandbox="$1" fn="$3" rc=0
    # Call the function as a plain command: wrapping it in `|| ...` would
    # disable `set -e` inside it and hide the very bug under test.
    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_CALL_LOG="$2/caller.log" \
            STUB_DIR="$2/stub" STUB_FAIL_ROLLBACK_PY="$5"
        source "$2/install-caller-sandbox.sh"
        get_real_user() { echo "testuser"; }
        "$4"
    ' "$2" "$fn" "$4"; then
        rc=0
    else
        rc=$?
    fi
    printf '%s\n' "$rc" > "$sandbox/uninstall-rc.txt"
}

# Shared wording of the explicit failure line (P3-1): rollback_rc can also
# come from group_rc (gpasswd/manifest) or pam_rc (PAM sidecar/debconf), and
# the log contains FAIL/ERROR as well as WARN, so the message must stay
# generic instead of claiming "manifest records" or "WARN lines" only.
UNINSTALL_INCOMPLETE_MSG='Uninstall incomplete; retained state will be retried (see FAIL/WARN lines above).'

# Keyboard's uninstall body touches keyd paths, so it reuses the dedicated
# install-keyboard-sandbox.sh + keyd stubs instead of the generic caller
# sandbox. Fault injection is the same: fail ONLY the rollback python call
# (marker ROLLBACK_INCOMPLETE) while validator/manifest lookups still run.
setup_keyboard_caller_uninstall_sandbox() {
    local sandbox="$1"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/stub" "$sandbox/etc/keyd"
    prepare_keyd_sandbox_script "$sandbox"
    setup_keyd_stubs "$sandbox" valid
    : > "$sandbox/manifest/.install-manifest.lock"
    chmod 0600 "$sandbox/manifest/.install-manifest.lock"
    # sudo only executes PATH-stubbed commands; rm/rmdir in the uninstall body
    # must never reach host state. python3 is always allowed (validator and
    # manifest reads) and is fault-injected only for the rollback call.
    cat > "$sandbox/stub/sudo" << 'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    python3) ;;
    *) printf '%s\n' "$*" >> "${STUB_CALL_LOG:?}" ;;
esac
[ "${1:-}" = "-u" ] && shift 2
cmd="${1:-}"
if [ "$cmd" = bash ] || [ -x "${STUB_DIR:?}/$cmd" ]; then
    exec "$@"
fi
exit 0
EOF
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -eq 6 ] && [[ "$2" == *"ROLLBACK_INCOMPLETE"* ]] && [ "${STUB_FAIL_ROLLBACK_PY:-0}" = "1" ]; then
    printf 'stub: forced rollback failure\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/sudo" "$sandbox/stub/python3"
    python3 - "$sandbox/manifest/install-manifest.json" << 'PY'
import json, sys
json.dump({"version": "2.0", "records": [], "services": [], "groups": [
    {"group": "plugdev", "user": "testuser", "component": "keyboard",
     "was_member": False}]}, open(sys.argv[1], "w"), indent=2)
PY
    : > "$sandbox/caller.log"
    : > "$sandbox/log.txt"
    : > "$sandbox/systemctl.log"
}

run_keyboard_caller_uninstall() {
    # $1=sandbox $2=1 to force the rollback rc 1 (0 = success path)
    local sandbox="$1" fail="$2" rc=0
    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_CALL_LOG="$2/caller.log" \
            STUB_SYSTEMCTL_LOG="$2/systemctl.log" STUB_DIR="$2/stub" \
            STUB_FAIL_ROLLBACK_PY="$3"
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        rc=0
        _uninstall_keyboard_body || rc=$?
        exit "$rc"
    ' "$fail"; then
        rc=0
    else
        rc=$?
    fi
    printf '%s\n' "$rc" > "$sandbox/uninstall-rc.txt"
}

test_caller_uninstall_rollback_failure() {
    # $1=component $2=uninstall function $3=post-rollback marker
    # $4=log file holding the marker (caller.log or log.txt)
    # $5=the component's original SUCCESS line, which must NOT appear on failure
    local comp="$1" fn="$2" marker="$3" logfile="$4" success_msg="$5"
    local sandbox="/tmp/rollback-test-caller-$comp-fail"
    local log_output
    if [ "$comp" = "keyboard" ]; then
        setup_keyboard_caller_uninstall_sandbox "$sandbox"
        run_keyboard_caller_uninstall "$sandbox" 1
    else
        setup_caller_uninstall_sandbox "$sandbox" "$comp"
        run_caller_uninstall "$sandbox" "$comp" "$fn" 1
    fi
    log_output="$(cat "$sandbox/log.txt" 2> /dev/null || echo "")"

    assert_eq "1" "$(cat "$sandbox/uninstall-rc.txt" 2> /dev/null || echo MISSING)" \
        "[$comp] uninstall propagates rollback rc 1"
    assert_contains "$marker" "$(cat "$sandbox/$logfile" 2> /dev/null || echo "")" \
        "[$comp] post-rollback cleanup still ran"
    if [ "$comp" = "fingerprint" ] || [ "$comp" = "ec" ]; then
        assert_contains "group 'plugdev'" "$log_output" \
            "[$comp] post-rollback group-membership step ran"
    fi
    assert_contains "rollback of $comp failed" "$log_output" \
        "[$comp] rollback failure logged"
    # Regression (gh-human P1 + install-safety P2): a failed rollback retains
    # state for retry, so the final SUCCESS line would contradict the FAIL/WARN
    # lines above it and the docs/UNINSTALL.md promise.
    assert_not_contains "$success_msg" "$log_output" \
        "[$comp] no misleading SUCCESS line after rollback failure"
    assert_contains "$UNINSTALL_INCOMPLETE_MSG" "$log_output" \
        "[$comp] incomplete uninstall is logged explicitly"
    assert_not_contains "finished!" "$log_output" \
        "[$comp] no 'finished!' claim after rollback failure"
    assert_not_contains "removed successfully" "$log_output" \
        "[$comp] no 'removed successfully' claim after rollback failure"
    assert_not_contains "completed" "$log_output" \
        "[$comp] no 'completed' claim after rollback failure"
}

test_caller_uninstall_rollback_success() {
    # Same parameters: a successful rollback must keep rc 0, still clean up,
    # and still print the component's original success message.
    # $5=the component's original SUCCESS line, which must appear on success
    local comp="$1" fn="$2" marker="$3" logfile="$4" success_msg="$5"
    local sandbox="/tmp/rollback-test-caller-$comp-ok"
    local log_output
    if [ "$comp" = "keyboard" ]; then
        setup_keyboard_caller_uninstall_sandbox "$sandbox"
        run_keyboard_caller_uninstall "$sandbox" 0
    else
        setup_caller_uninstall_sandbox "$sandbox" "$comp"
        run_caller_uninstall "$sandbox" "$comp" "$fn" 0
    fi
    log_output="$(cat "$sandbox/log.txt" 2> /dev/null || echo "")"

    assert_eq "0" "$(cat "$sandbox/uninstall-rc.txt" 2> /dev/null || echo MISSING)" \
        "[$comp] successful rollback keeps uninstall rc 0"
    assert_contains "$marker" "$(cat "$sandbox/$logfile" 2> /dev/null || echo "")" \
        "[$comp] cleanup still runs after successful rollback"
    assert_contains "Rollback for component [$comp] finished!" "$log_output" \
        "[$comp] rollback success logged"
    assert_contains "$success_msg" "$log_output" \
        "[$comp] original success message still printed after successful rollback"
}

# Static guard for ALL five uninstall bodies (including keyboard). Verify the
# exact ADJACENT structure inside the body, not loose substring finds that
# could be defeated by deleting `fi`, moving log_error out of the else branch,
# or appending a legacy log_success after the guarded one:
#   if [ "$rollback_rc" -eq 0 ]; then
#       log_success "<original message>"
#   else
#       log_error "<shared incomplete message>"
#   fi
#   return "$rollback_rc"
test_uninstall_success_log_is_rollback_conditional() {
    local comp fn success_msg src
    for comp in audio fingerprint ec keyboard power; do
        case "$comp" in
            audio)
                fn='_uninstall_audio_body'
                success_msg='Audio UCM profiles removed successfully.'
                ;;
            fingerprint)
                fn='_uninstall_fp_body'
                success_msg='Fingerprint driver uninstallation finished.'
                ;;
            ec)
                fn='_uninstall_ec_tools_body'
                success_msg='EC utilities removed.'
                ;;
            keyboard)
                fn='_uninstall_keyboard_body'
                success_msg='Keyboard mapping uninstallation completed.'
                ;;
            power)
                fn='_uninstall_power_body'
                success_msg='Power optimization profiles removed.'
                ;;
        esac
        src="$REPO_ROOT/$comp/install-$comp.sh"
        assert_contains "$success_msg" "$(cat "$src")" \
            "[$comp] original success message preserved in source"
        if python3 - "$src" "$fn" "$success_msg" "$UNINSTALL_INCOMPLETE_MSG" << 'PY'; then
import sys

path, fn, success_msg, err_msg = sys.argv[1:5]
lines = open(path).read().splitlines()
start = next((i for i, line in enumerate(lines)
              if line.startswith(fn + '() {')), -1)
if start < 0:
    sys.exit(1)
end = next((i for i in range(start + 1, len(lines))
            if lines[i] == '}'), len(lines))
# Ignore blank/comment lines so the check compares adjacent CODE statements
# while still rejecting a deleted `fi`, a moved log_error, or an extra legacy
# log_success anywhere in the body.
body = [line.strip() for line in lines[start + 1:end]
        if line.strip() and not line.strip().startswith('#')]

# The whole uninstall body must contain exactly one final log_success.
hits = [i for i, line in enumerate(body) if 'log_success' in line]
if len(hits) != 1:
    sys.exit(1)
i = hits[0]
expected = [
    'if [ "$rollback_rc" -eq 0 ]; then',
    'log_success "' + success_msg + '"',
    'else',
    'log_error "' + err_msg + '"',
    'fi',
    'return "$rollback_rc"',
]
actual = body[i - 1:i + 5]
if len(actual) != len(expected) or any(got != want for got, want in zip(actual, expected)):
    sys.exit(1)
PY
            ok
        else
            fail "[$comp] uninstall body lacks the exact guarded success/error structure"
        fi
    done
}

# Fingerprint must still run ALL cleanup steps (rollback, group removal, PAM
# disable) before choosing the log message; the log change may not introduce
# an early return or alter the pam_rc/group_rc folding order.
test_fingerprint_uninstall_cleanup_order_unchanged() {
    local src="$REPO_ROOT/fingerprint/install-fingerprint.sh"
    if python3 - "$src" << 'PY'; then
import sys

lines = open(sys.argv[1]).read().splitlines()
wanted = [
    'rollback_component "fingerprint" || rollback_rc=$?',
    'remove_group_membership "plugdev" "$(get_real_user)" "fingerprint" || group_rc=$?',
    '[ "$group_rc" -eq 0 ] || rollback_rc="$group_rc"',
    'disable_pam_fingerprint || pam_rc=$?',
    '[ "$pam_rc" -eq 0 ] || rollback_rc="$pam_rc"',
]
pos = []
for needle in wanted:
    idx = next((i for i, line in enumerate(lines) if needle in line), -1)
    if idx < 0:
        sys.exit(1)
    pos.append(idx)
if pos != sorted(pos):
    sys.exit(1)
# Bound the scan to _uninstall_fp_body itself: later functions in the same
# file legitimately have their own returns.
end = next((i for i in range(pos[0], len(lines)) if lines[i] == '}'), len(lines))
body = lines[pos[0]:end]
early = next((line.strip() for line in body
              if line.strip().startswith('return ')
              and '"$rollback_rc"' not in line), None)
if early is not None:
    sys.exit(1)
# The final log choice must come AFTER every cleanup/folding step, not just
# after rollback_component itself.
guard = next((i for i, line in enumerate(body)
              if line.strip() == 'if [ "$rollback_rc" -eq 0 ]; then'), -1)
if guard < 0 or guard < pos[-1] - pos[0]:
    sys.exit(1)
PY
        ok
    else
        fail "fingerprint uninstall cleanup/folding order changed or early return introduced"
    fi
}

test_caller_uninstall_regression_detects_unguarded_rollback() {
    # Negative control: the pre-fix fingerprint caller (unguarded rollback)
    # must show the exact failure mode this regression guards against.
    local sandbox="/tmp/rollback-test-caller-unguarded"
    setup_caller_uninstall_sandbox "$sandbox" fingerprint
    python3 - "$REPO_ROOT/fingerprint/install-fingerprint.sh" "$sandbox/unfixed-source.sh" << 'PY'
import sys
src = open(sys.argv[1]).read()
src = src.replace('rollback_component "fingerprint" || rollback_rc=$?',
                  'rollback_component "fingerprint"')
src = src.replace('    # Propagate a rollback failure only after ALL cleanup above has run.\n'
                  '    return "$rollback_rc"\n', '')
open(sys.argv[2], "w").write(src)
PY
    prepare_caller_sandbox_script "$sandbox" fingerprint "$sandbox/unfixed-source.sh"
    run_caller_uninstall "$sandbox" fingerprint uninstall_fp 1

    assert_eq "1" "$(cat "$sandbox/uninstall-rc.txt" 2> /dev/null || echo MISSING)" \
        "unguarded control: uninstall rc 1"
    if grep -qF 'udevadm control --reload-rules' "$sandbox/caller.log"; then
        fail "unguarded control: cleanup unexpectedly ran (test cannot detect the regression)"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# Re-review #11 finding #1 (P1 BLOCKER): plugdev ownership must be aggregated
# across ALL components sharing a (group,user) pair. A full install records
# keyboard=false then fingerprint=true; a full uninstall must still remove the
# membership after the LAST udev rule disappears, and consume both records.
# Every command with a side effect is a PATH stub inside a /tmp sandbox.
# ---------------------------------------------------------------------------
grp_was_member_at() {
    python3 -c 'import json,sys; g=json.load(open(sys.argv[1]))["groups"]; print(g[int(sys.argv[2])]["was_member"])' "$1" "$2"
}

# Re-review #13 (P2): per-install added_by_project evidence. Missing field
# defaults to False (legacy semantics); present-but-wrong-type is rejected by
# the validator and never reaches a writer.
grp_added_at() {
    python3 -c 'import json,sys; g=json.load(open(sys.argv[1]))["groups"]; print(g[int(sys.argv[2])].get("added_by_project", False))' "$1" "$2"
}

# R1 — the exact reviewer scenario: keyboard first, fingerprint second.
test_plugdev_full_install_uninstall_keyboard_first() {
    local sandbox="/tmp/rollback-test-plugdev-kbd-fp"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"

    # user starts outside plugdev -> keyboard records was_member=false
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i1.rc"
    '
    # id -nG now sees plugdev -> fingerprint records was_member=true
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod2.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser fingerprint || rc=$?
        printf "%s\n" "$rc" > "$2/i2.rc"
    '
    local r1_install_groups r1_was0 r1_was1
    r1_install_groups="$(group_count "$mp")"
    r1_was0="$(grp_was_member_at "$mp" 0)"
    r1_was1="$(grp_was_member_at "$mp" 1)"

    printf 'GROUP="plugdev"\n' > "$sandbox/udev/61-kbd.rules"
    printf 'GROUP="plugdev"\n' > "$sandbox/udev/60-fp.rules"

    # keyboard rule gone, fingerprint rule still present -> keep membership
    rm -f "$sandbox/udev/61-kbd.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd1.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u1.rc"
    '
    local r1_groups_u1 r1_state_u1 r1_gpasswd_u1
    r1_groups_u1="$(group_count "$mp")"
    r1_state_u1="$(cat "$sandbox/group-state")"
    r1_gpasswd_u1="$(usermod_calls "$sandbox/gpasswd1.log")"

    # last rule gone -> aggregate over both records authorizes the removal
    rm -f "$sandbox/udev/60-fp.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd2.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser fingerprint || rc=$?
        printf "%s\n" "$rc" > "$2/u2.rc"
    '

    assert_eq "0" "$(cat "$sandbox/i1.rc")" "R1: keyboard install rc"
    assert_eq "0" "$(cat "$sandbox/i2.rc")" "R1: fingerprint install rc"
    assert_eq "1" "$(usermod_calls "$sandbox/usermod.log")" "R1: only keyboard usermod'ed"
    assert_eq "2" "$r1_install_groups" "R1: two records after install"
    assert_eq "False" "$r1_was0" "R1: keyboard recorded false"
    assert_eq "True" "$r1_was1" "R1: fingerprint recorded true"
    assert_eq "0" "$(cat "$sandbox/u1.rc")" "R1: keyboard uninstall rc"
    assert_eq "0" "$r1_gpasswd_u1" "R1: no gpasswd while fp rule remains"
    assert_eq "2" "$r1_groups_u1" "R1: both records retained while fp rule remains"
    assert_contains "plugdev" "$r1_state_u1" "R1: membership kept while fp rule remains"
    assert_contains "udev rules still reference" "$(cat "$sandbox/log.txt")" "R1: udev gate logged"
    assert_eq "0" "$(cat "$sandbox/u2.rc")" "R1: fingerprint uninstall rc"
    assert_eq "1" "$(usermod_calls "$sandbox/gpasswd2.log")" "R1: gpasswd -d exactly once"
    assert_not_contains "plugdev" "$(cat "$sandbox/group-state")" "R1: membership removed"
    assert_eq "0" "$(group_count "$mp")" "R1: all (group,user) records consumed"
}

# R2 — reverse install/uninstall order: correctness must not depend on it.
test_plugdev_full_install_uninstall_fingerprint_first() {
    local sandbox="/tmp/rollback-test-plugdev-fp-kbd"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser fingerprint || rc=$?
        printf "%s\n" "$rc" > "$2/i1.rc"
    '
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod2.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i2.rc"
    '
    local r2_was0 r2_was1
    r2_was0="$(grp_was_member_at "$mp" 0)"
    r2_was1="$(grp_was_member_at "$mp" 1)"

    printf 'GROUP="plugdev"\n' > "$sandbox/udev/60-fp.rules"
    printf 'GROUP="plugdev"\n' > "$sandbox/udev/61-kbd.rules"

    rm -f "$sandbox/udev/60-fp.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd1.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser fingerprint || rc=$?
        printf "%s\n" "$rc" > "$2/u1.rc"
    '
    rm -f "$sandbox/udev/61-kbd.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd2.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u2.rc"
    '

    assert_eq "0" "$(cat "$sandbox/i1.rc")" "R2: fingerprint install rc"
    assert_eq "0" "$(cat "$sandbox/i2.rc")" "R2: keyboard install rc"
    assert_eq "False" "$r2_was0" "R2: fingerprint recorded false"
    assert_eq "True" "$r2_was1" "R2: keyboard recorded true"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd1.log")" "R2: no gpasswd while kbd rule remains"
    assert_eq "0" "$(cat "$sandbox/u1.rc")" "R2: fingerprint uninstall rc"
    assert_eq "1" "$(usermod_calls "$sandbox/gpasswd2.log")" "R2: gpasswd -d exactly once"
    assert_eq "0" "$(cat "$sandbox/u2.rc")" "R2: keyboard uninstall rc"
    assert_not_contains "plugdev" "$(cat "$sandbox/group-state")" "R2: membership removed"
    assert_eq "0" "$(group_count "$mp")" "R2: all records consumed regardless of order"
}

# R3 — a user who was already in plugdev must never be removed (no usermod, no
# gpasswd, membership preserved). Sibling records are kept while a rule still
# manages the group, then consumed once the LAST component uninstalls; no
# gpasswd is ever involved in consuming those all-true records.
test_plugdev_preexisting_member_kept_across_all_uninstalls() {
    local sandbox="/tmp/rollback-test-plugdev-preexisting"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    printf 'plugdev\n' > "$sandbox/group-state"
    local mp="$sandbox/manifest/install-manifest.json"

    for comp in keyboard fingerprint; do
        run_sandboxed "$sandbox" '
            export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
                STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
                STUB_GPASSWD_LOG="$2/gpasswd.log"
            source "$1/lib/backup.sh"
            rc=0; ensure_group_membership plugdev testuser "$3" || rc=$?
            printf "%s\n" "$rc" > "$2/install-$3.rc"
        ' "$comp"
        printf 'GROUP="plugdev"\n' > "$sandbox/udev/rule-$comp.rules"
    done
    # Snapshot the records BEFORE the final uninstall consumes them.
    # R17: a normal pre-existing member must never gain an added flag.
    local r3_was0 r3_was1 r3_added0 r3_added1
    r3_was0="$(grp_was_member_at "$mp" 0)"
    r3_was1="$(grp_was_member_at "$mp" 1)"
    r3_added0="$(grp_added_at "$mp" 0)"
    r3_added1="$(grp_added_at "$mp" 1)"

    for comp in keyboard fingerprint; do
        rm -f "$sandbox/udev/rule-$comp.rules"
        run_sandboxed "$sandbox" '
            export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
                STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
                STUB_GPASSWD_LOG="$2/gpasswd.log"
            source "$1/lib/backup.sh"
            rc=0; remove_group_membership plugdev testuser "$3" || rc=$?
            printf "%s\n" "$rc" > "$2/uninstall-$3.rc"
        ' "$comp"
        if [ "$comp" = "keyboard" ]; then
            # Check AFTER the keyboard uninstall: the sibling fingerprint rule
            # must keep both true records (no consume, no gpasswd) at this point.
            assert_eq "2" "$(group_count "$mp")" \
                "R3: sibling still managed (fp rule) keeps both true records"
        fi
    done

    assert_eq "0" "$(cat "$sandbox/install-keyboard.rc")" "R3: keyboard install rc"
    assert_eq "0" "$(cat "$sandbox/install-fingerprint.rc")" "R3: fingerprint install rc"
    assert_eq "0" "$(usermod_calls "$sandbox/usermod.log")" "R3: pre-existing member never usermod'ed"
    assert_eq "True" "$r3_was0" "R3: keyboard recorded was_member=true"
    assert_eq "True" "$r3_was1" "R3: fingerprint recorded was_member=true"
    assert_eq "False" "$r3_added0" "R17: keyboard added_by_project stays false for a pre-existing member"
    assert_eq "False" "$r3_added1" "R17: fingerprint added_by_project stays false for a pre-existing member"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd.log")" "R3: never gpasswd a pre-existing member"
    assert_contains "plugdev" "$(cat "$sandbox/group-state")" "R3: membership preserved"
    assert_eq "0" "$(group_count "$mp")" "R3: all-true records consumed once no component needs the group"
    assert_eq "0" "$(cat "$sandbox/uninstall-keyboard.rc")" "R3: keyboard uninstall rc"
    assert_eq "0" "$(cat "$sandbox/uninstall-fingerprint.rc")" "R3: fingerprint uninstall rc"
}

# R4 — a single-component install/uninstall still works for each component.
test_plugdev_single_component_install_uninstall() {
    local comp sandbox mp
    for comp in keyboard fingerprint ec; do
        sandbox="/tmp/rollback-test-plugdev-single-$comp"
        rm -rf "$sandbox"
        mkdir -p "$sandbox/backups" "$sandbox/manifest"
        setup_group_state_stubs "$sandbox"
        mp="$sandbox/manifest/install-manifest.json"

        run_sandboxed "$sandbox" '
            export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
                STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
                STUB_GPASSWD_LOG="$2/gpasswd.log"
            source "$1/lib/backup.sh"
            rc=0; ensure_group_membership plugdev testuser "$3" || rc=$?
            printf "%s\n" "$rc" > "$2/i.rc"
        ' "$comp"
        local single_install_groups
        single_install_groups="$(group_count "$mp")"
        printf 'GROUP="plugdev"\n' > "$sandbox/udev/99-single.rules"
        rm -f "$sandbox/udev/99-single.rules"
        run_sandboxed "$sandbox" '
            export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
                STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
                STUB_GPASSWD_LOG="$2/gpasswd.log"
            source "$1/lib/backup.sh"
            rc=0; remove_group_membership plugdev testuser "$3" || rc=$?
            printf "%s\n" "$rc" > "$2/u.rc"
        ' "$comp"

        assert_eq "1" "$(usermod_calls "$sandbox/usermod.log")" "R4 [$comp]: usermod once"
        assert_eq "1" "$single_install_groups" "R4 [$comp]: one record after install"
        assert_eq "0" "$(cat "$sandbox/u.rc")" "R4 [$comp]: uninstall rc"
        assert_eq "1" "$(usermod_calls "$sandbox/gpasswd.log")" "R4 [$comp]: gpasswd once"
        assert_not_contains "plugdev" "$(cat "$sandbox/group-state")" "R4 [$comp]: membership removed"
        assert_eq "0" "$(group_count "$mp")" "R4 [$comp]: record consumed"
    done
}

# R5 — gpasswd -d failure must be reported (no fake success) and must retain
# the record so a later uninstall can retry.
test_plugdev_gpasswd_failure_returns_nonzero_and_keeps_records() {
    local sandbox="/tmp/rollback-test-plugdev-gpasswd-fail"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i.rc"
    '
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd-fail.log" STUB_GPASSWD_RC=1
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u.rc"
    '

    assert_eq "1" "$(cat "$sandbox/u.rc")" "R5: gpasswd failure returns nonzero"
    assert_eq "1" "$(usermod_calls "$sandbox/gpasswd-fail.log")" "R5: gpasswd attempted once"
    assert_contains "keeping manifest records for retry" "$(cat "$sandbox/log.txt")" "R5: failure logged loudly"
    assert_contains "plugdev" "$(cat "$sandbox/group-state")" "R5: membership unchanged on failure"
    assert_eq "1" "$(group_count "$mp")" "R5: record kept for retry"
}

# R5b — the REAL uninstall body under `set -e`: rc 1 propagates AND the
# post-rollback cleanup still runs (the group rc was captured, not left bare).
test_plugdev_gpasswd_failure_propagates_from_real_uninstaller() {
    local sandbox="/tmp/rollback-test-plugdev-gpasswd-caller"
    setup_caller_uninstall_sandbox "$sandbox" fingerprint
    # The caller sandbox's gpasswd stub succeeds by default; make it fail.
    cat > "$sandbox/stub/gpasswd" << 'EOF'
#!/usr/bin/env bash
exit "${STUB_GPASSWD_RC:-1}"
EOF
    # Redirect the udev scan into an empty sandbox directory: the host may have
    # real cros udev rules referencing plugdev and must never be consulted.
    mkdir -p "$sandbox/udev"
    cat > "$sandbox/stub/grep" << 'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-rl" ] && [[ "${2:-}" == GROUP=* ]] && \
   [ "${3:-}" = "/etc/udev/rules.d/" ]; then
    exec /usr/bin/grep -rl -- "$2" "${STUB_UDEV_DIR:-/nonexistent-udev}" 2>/dev/null
fi
exec /usr/bin/grep "$@"
EOF
    chmod +x "$sandbox/stub/gpasswd" "$sandbox/stub/grep"

    local rc=0
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_CALL_LOG="$2/caller.log" \
            STUB_DIR="$2/stub" STUB_FAIL_ROLLBACK_PY=0 \
            STUB_UDEV_DIR="$2/udev" STUB_GPASSWD_RC=1
        source "$2/install-caller-sandbox.sh"
        get_real_user() { echo "testuser"; }
        uninstall_fp
    ' || rc=$?
    printf '%s\n' "$rc" > "$sandbox/uninstall-rc.txt"

    assert_eq "1" "$(cat "$sandbox/uninstall-rc.txt")" "R5b: real uninstaller propagates rc 1"
    assert_contains "Could not remove 'testuser' from group 'plugdev'" "$(cat "$sandbox/log.txt")" \
        "R5b: gpasswd failure logged by the real uninstaller"
    assert_contains "udevadm control --reload-rules" "$(cat "$sandbox/caller.log")" \
        "R5b: post-rollback cleanup still ran under set -e"
    assert_eq "1" "$(group_count "$sandbox/manifest/install-manifest.json")" \
        "R5b: group record retained for retry"
}

# R6 — any remaining udev rule (even third-party) gates removal; only the
# last rule's disappearance authorizes gpasswd + record consumption.
test_plugdev_udev_rule_gates_removal_until_last_one_disappears() {
    local sandbox="/tmp/rollback-test-plugdev-udev-gate"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i.rc"
    '
    printf 'GROUP="plugdev"\n' > "$sandbox/udev/99-other.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd1.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u1.rc"
    '
    local r6_groups_u1 r6_state_u1
    r6_groups_u1="$(group_count "$mp")"
    r6_state_u1="$(cat "$sandbox/group-state")"
    rm -f "$sandbox/udev/99-other.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd2.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u2.rc"
    '

    assert_eq "0" "$(cat "$sandbox/u1.rc")" "R6: gated uninstall rc"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd1.log")" "R6: no gpasswd while rule remains"
    assert_eq "1" "$r6_groups_u1" "R6: record retained while rule remains"
    assert_contains "plugdev" "$r6_state_u1" "R6: membership kept while rule remains"
    assert_eq "0" "$(cat "$sandbox/u2.rc")" "R6: final uninstall rc"
    assert_eq "1" "$(usermod_calls "$sandbox/gpasswd2.log")" "R6: gpasswd after last rule gone"
    assert_not_contains "plugdev" "$(cat "$sandbox/group-state")" "R6: membership removed"
    assert_eq "0" "$(group_count "$mp")" "R6: record consumed"
}

# R7 — three components including the optional EC all share the same pair.
test_plugdev_three_components_ec_included() {
    local sandbox="/tmp/rollback-test-plugdev-three"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"

    for comp in keyboard fingerprint ec; do
        run_sandboxed "$sandbox" '
            export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
                STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
                STUB_GPASSWD_LOG="$2/gpasswd.log"
            source "$1/lib/backup.sh"
            rc=0; ensure_group_membership plugdev testuser "$3" || rc=$?
            printf "%s\n" "$rc" > "$2/install-$3.rc"
        ' "$comp"
        printf 'GROUP="plugdev"\n' > "$sandbox/udev/rule-$comp.rules"
    done
    local r7_install_groups r7_gpasswd_before_last=0
    r7_install_groups="$(group_count "$mp")"
    for comp in keyboard fingerprint ec; do
        rm -f "$sandbox/udev/rule-$comp.rules"
        run_sandboxed "$sandbox" '
            export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
                STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
                STUB_GPASSWD_LOG="$2/gpasswd.log"
            source "$1/lib/backup.sh"
            rc=0; remove_group_membership plugdev testuser "$3" || rc=$?
            printf "%s\n" "$rc" > "$2/uninstall-$3.rc"
        ' "$comp"
        if [ "$comp" = "fingerprint" ]; then
            r7_gpasswd_before_last="$(usermod_calls "$sandbox/gpasswd.log")"
        fi
    done

    assert_eq "1" "$(usermod_calls "$sandbox/usermod.log")" "R7: only the first component usermod'ed"
    assert_eq "3" "$r7_install_groups" "R7: three records after install"
    assert_eq "0" "$r7_gpasswd_before_last" "R7: no gpasswd until the last rule vanished"
    assert_eq "0" "$(cat "$sandbox/uninstall-keyboard.rc")" "R7: keyboard uninstall rc"
    assert_eq "0" "$(cat "$sandbox/uninstall-fingerprint.rc")" "R7: fingerprint uninstall rc"
    assert_eq "0" "$(cat "$sandbox/uninstall-ec.rc")" "R7: ec uninstall rc"
    assert_eq "1" "$(usermod_calls "$sandbox/gpasswd.log")" "R7: exactly one gpasswd after all rules gone"
    assert_not_contains "plugdev" "$(cat "$sandbox/group-state")" "R7: membership removed"
    assert_eq "0" "$(group_count "$mp")" "R7: all three records consumed"
}

# R8 — schema-invalid / malformed manifests fail closed: no gpasswd, no byte
# change, explicit refusal in the log.
test_plugdev_remove_fails_closed_on_invalid_manifest() {
    local case_name
    for case_name in wrongtype badjson; do
        local sandbox="/tmp/rollback-test-plugdev-invalid-$case_name"
        rm -rf "$sandbox"
        mkdir -p "$sandbox/backups" "$sandbox/manifest"
        setup_group_state_stubs "$sandbox"
        printf 'plugdev\n' > "$sandbox/group-state"
        local mp="$sandbox/manifest/install-manifest.json"
        if [ "$case_name" = wrongtype ]; then
            printf '%s' '{"version":"2.0","records":[],"services":[],"groups":[{"group":"plugdev","user":"testuser","component":"keyboard","was_member":"false"}]}' > "$mp"
        else
            printf '%s' '{"version":"2.0","groups":[' > "$mp"
        fi
        local before
        before="$(file_hex "$mp")"

        run_sandboxed "$sandbox" '
            export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
                STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
                STUB_GPASSWD_LOG="$2/gpasswd.log"
            source "$1/lib/backup.sh"
            rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
            printf "%s\n" "$rc" > "$2/u.rc"
        '
        assert_eq "1" "$(cat "$sandbox/u.rc")" "R8 [$case_name]: fail closed with rc 1"
        assert_eq "0" "$(usermod_calls "$sandbox/gpasswd.log")" "R8 [$case_name]: gpasswd never attempted"
        assert_eq "$before" "$(file_hex "$mp")" "R8 [$case_name]: manifest bytes unchanged"
        assert_contains "refusing to remove group membership" "$(cat "$sandbox/log.txt")" \
            "R8 [$case_name]: refusal logged"
        assert_contains "plugdev" "$(cat "$sandbox/group-state")" "R8 [$case_name]: membership untouched"
    done
}

# R9 — DRY_RUN is side-effect free: no gpasswd, no record consumption, no lock.
test_plugdev_dry_run_remove_no_side_effects() {
    local sandbox="/tmp/rollback-test-plugdev-dryrun"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    printf 'plugdev\n' > "$sandbox/group-state"
    local mp="$sandbox/manifest/install-manifest.json"
    python3 - "$mp" << 'PY'
import json, sys
json.dump({"version": "2.0", "records": [], "services": [], "groups": [
    {"group": "plugdev", "user": "testuser", "component": "keyboard",
     "was_member": False}]}, open(sys.argv[1], "w"), indent=2)
PY
    local before
    before="$(file_hex "$mp")"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" DRY_RUN=1 STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u.rc"
    '

    assert_eq "0" "$(cat "$sandbox/u.rc")" "R9: dry-run remove rc"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd.log")" "R9: gpasswd never called in dry run"
    assert_contains "plugdev" "$(cat "$sandbox/group-state")" "R9: membership untouched"
    assert_eq "1" "$(group_count "$mp")" "R9: record not consumed"
    assert_eq "$before" "$(file_hex "$mp")" "R9: manifest bytes unchanged"
    if [ -e "$sandbox/manifest/.install-manifest.lock" ]; then
        fail "R9: dry run must not create a lock file"
    else
        ok
    fi
}

# Re-review #12 finding #3 — precise fault stub for the all-true consume path.
# Refuse ONLY manifest_remove_group_all()'s python writer: argc=5
# (python3 -c SCRIPT mp group user), script contains atomic_write_json AND the
# # GROUP_CONSUME_ALL marker. The ownership probe (argc=5, no
# atomic_write_json), the validator (argc=3), the group add writer (argc=8, no
# marker) and the clear writer (argc=6, no marker) all pass through to the real
# python3. The add-writer stub threshold is argc>=7.
block_group_consume_stub() {
    local sandbox="$1"
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -ge 5 ] && \
   printf '%s' "${2:-}" | grep -q 'atomic_write_json' && \
   printf '%s' "${2:-}" | grep -q 'GROUP_CONSUME_ALL'; then
    printf 'STUB: group consume refused\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/python3"
}

# R11 — reviewer's exact timing (P2 PERMISSION LIFECYCLE). Round 1: the user is
# already in plugdev, so uninstall creates ONLY all-true records and must not
# gpasswd. An external admin then removes that membership; round 2 install sees
# a fresh "false" snapshot (old true record was consumed), usermod adds the
# user back, and round 2 uninstall MUST remove the membership we just added.
test_plugdev_preexisting_then_admin_removed_reinstall_can_rollback() {
    local sandbox="/tmp/rollback-test-plugdev-lifecycle"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    printf 'plugdev\n' > "$sandbox/group-state" # pre-existing member
    local mp="$sandbox/manifest/install-manifest.json"

    # --- round 1: pre-existing member -> record true, no usermod ---
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod1.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i1.rc"
    '
    printf 'GROUP="plugdev"\n' > "$sandbox/udev/61-kbd.rules"
    rm -f "$sandbox/udev/61-kbd.rules" # rollback_component removed our rule
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod1.log" \
            STUB_GPASSWD_LOG="$2/gpasswd1.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u1.rc"
    '
    local r11_state_u1 r11_groups_u1
    r11_state_u1="$(cat "$sandbox/group-state")"
    r11_groups_u1="$(group_count "$mp")"

    # --- external administrator removes the membership (stub state only) ---
    printf 'audio\n' > "$sandbox/group-state"

    # --- round 2: install again; snapshot must now be false ---
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod2.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i2.rc"
    '
    local r11_was_u2 r11_state_u2
    r11_was_u2="$(grp_was_member_at "$mp" 0)"
    r11_state_u2="$(cat "$sandbox/group-state")"
    printf 'GROUP="plugdev"\n' > "$sandbox/udev/61-kbd.rules"
    rm -f "$sandbox/udev/61-kbd.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod2.log" \
            STUB_GPASSWD_LOG="$2/gpasswd2.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u2.rc"
    '

    # round 1: stale all-true record consumed WITHOUT touching membership
    assert_eq "0" "$(cat "$sandbox/i1.rc")" "R11: round-1 install rc"
    assert_eq "0" "$(usermod_calls "$sandbox/usermod1.log")" "R11: pre-existing member never usermod'ed"
    assert_eq "0" "$(cat "$sandbox/u1.rc")" "R11: round-1 uninstall rc"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd1.log")" "R11: no gpasswd on all-true consume"
    assert_eq "0" "$r11_groups_u1" "R11: stale all-true record consumed"
    assert_contains "plugdev" "$r11_state_u1" "R11: membership kept in round 1"
    assert_contains "consuming stale records" "$(cat "$sandbox/log.txt")" "R11: stale consume logged"
    # round 2: fresh false snapshot -> we add and must be able to remove
    assert_eq "0" "$(cat "$sandbox/i2.rc")" "R11: round-2 install rc"
    assert_eq "False" "$r11_was_u2" "R11: first-wins did NOT reuse the old true snapshot"
    assert_eq "1" "$(usermod_calls "$sandbox/usermod2.log")" "R11: user added back in round 2"
    assert_contains "plugdev" "$r11_state_u2" "R11: membership present after round-2 install"
    assert_eq "0" "$(cat "$sandbox/u2.rc")" "R11: round-2 uninstall rc"
    assert_eq "1" "$(usermod_calls "$sandbox/gpasswd2.log")" "R11: new membership removed by gpasswd"
    assert_not_contains "plugdev" "$(cat "$sandbox/group-state")" "R11: membership removed in round 2"
    assert_eq "0" "$(group_count "$mp")" "R11: round-2 record consumed"
}

# R12 — three all-true components: sibling rules keep EVERY record, and only
# the last uninstall (no rule left) consumes the whole set, never gpasswd.
test_plugdev_preexisting_three_components_consume_only_after_last() {
    local sandbox="/tmp/rollback-test-plugdev-three-preexisting"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    printf 'plugdev\n' > "$sandbox/group-state"
    local mp="$sandbox/manifest/install-manifest.json"

    local comp
    for comp in keyboard fingerprint ec; do
        run_sandboxed "$sandbox" '
            export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
                STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
                STUB_GPASSWD_LOG="$2/gpasswd.log"
            source "$1/lib/backup.sh"
            rc=0; ensure_group_membership plugdev testuser "$3" || rc=$?
            printf "%s\n" "$rc" > "$2/install-$3.rc"
        ' "$comp"
        printf 'GROUP="plugdev"\n' > "$sandbox/udev/rule-$comp.rules"
    done
    local r12_install_groups
    r12_install_groups="$(group_count "$mp")"
    local r12_after_kbd="" r12_after_fp=""
    for comp in keyboard fingerprint ec; do
        rm -f "$sandbox/udev/rule-$comp.rules"
        run_sandboxed "$sandbox" '
            export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
                STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
                STUB_GPASSWD_LOG="$2/gpasswd.log"
            source "$1/lib/backup.sh"
            rc=0; remove_group_membership plugdev testuser "$3" || rc=$?
            printf "%s\n" "$rc" > "$2/uninstall-$3.rc"
        ' "$comp"
        if [ "$comp" = "keyboard" ]; then
            r12_after_kbd="$(group_count "$mp")"
        elif [ "$comp" = "fingerprint" ]; then
            r12_after_fp="$(group_count "$mp")"
        fi
    done

    assert_eq "3" "$r12_install_groups" "R12: three all-true records after install"
    assert_eq "3" "$r12_after_kbd" "R12: fp+ec rules still managed -> all three kept"
    assert_eq "3" "$r12_after_fp" "R12: ec rule still managed -> all three kept (consume ALL only at the end)"
    assert_eq "0" "$(group_count "$mp")" "R12: all consumed after the last uninstall"
    assert_eq "0" "$(usermod_calls "$sandbox/usermod.log")" "R12: pre-existing member never usermod'ed"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd.log")" "R12: all-true path never gpasswd"
    assert_contains "plugdev" "$(cat "$sandbox/group-state")" "R12: membership preserved throughout"
    assert_eq "0" "$(cat "$sandbox/uninstall-keyboard.rc")" "R12: keyboard uninstall rc"
    assert_eq "0" "$(cat "$sandbox/uninstall-fingerprint.rc")" "R12: fingerprint uninstall rc"
    assert_eq "0" "$(cat "$sandbox/uninstall-ec.rc")" "R12: ec uninstall rc"
}

# R13 — the udev gate also applies to the all-true (rc 3) path: a surviving
# third-party rule keeps the record; once it disappears the record is consumed.
test_plugdev_preexisting_member_udev_rule_keeps_record_then_consumes() {
    local sandbox="/tmp/rollback-test-plugdev-preexisting-udev-gate"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    printf 'plugdev\n' > "$sandbox/group-state"
    local mp="$sandbox/manifest/install-manifest.json"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i.rc"
    '
    printf 'GROUP="plugdev"\n' > "$sandbox/udev/99-third-party.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd1.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u1.rc"
    '
    local r13_groups_u1
    r13_groups_u1="$(group_count "$mp")"
    assert_contains "udev rules still reference" "$(cat "$sandbox/log.txt")" "R13: rc3 udev gate logged"

    rm -f "$sandbox/udev/99-third-party.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd2.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u2.rc"
    '

    assert_eq "0" "$(cat "$sandbox/u1.rc")" "R13: gated uninstall rc"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd1.log")" "R13: no gpasswd while rule remains"
    assert_eq "1" "$r13_groups_u1" "R13: all-true record kept while rule remains"
    assert_eq "0" "$(cat "$sandbox/u2.rc")" "R13: final uninstall rc"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd2.log")" "R13: no gpasswd after last rule gone"
    assert_eq "0" "$(group_count "$mp")" "R13: all-true record consumed after last rule gone"
    assert_contains "plugdev" "$(cat "$sandbox/group-state")" "R13: pre-existing membership never touched"
}

# R14 — all-true consume failure must fail closed: rc 1, record kept for
# retry, no gpasswd, no leftover temp file.
test_plugdev_preexisting_consume_failure_keeps_record() {
    local sandbox="/tmp/rollback-test-plugdev-consume-fail"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    block_group_consume_stub "$sandbox"
    printf 'plugdev\n' > "$sandbox/group-state"
    local mp="$sandbox/manifest/install-manifest.json"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i.rc"
    '
    printf 'GROUP="plugdev"\n' > "$sandbox/udev/99-single.rules"
    rm -f "$sandbox/udev/99-single.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u.rc"
    '
    local r14_tmp
    r14_tmp="$(find "$sandbox/manifest" -name '*.tmp' | wc -l | tr -d '[:space:]')"

    assert_eq "0" "$(cat "$sandbox/i.rc")" "R14: install rc (stub passes add_group)"
    assert_eq "1" "$(cat "$sandbox/u.rc")" "R14: consume failure returns rc 1"
    assert_eq "1" "$(group_count "$mp")" "R14: record kept for retry"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd.log")" "R14: no gpasswd on all-true path"
    assert_contains "plugdev" "$(cat "$sandbox/group-state")" "R14: membership untouched"
    assert_contains "keeping them for retry" "$(cat "$sandbox/log.txt")" "R14: failure logged loudly"
    assert_eq "0" "$r14_tmp" "R14: no leftover temp file"
}

# R9b — DRY_RUN on an all-true record is side-effect free (rc 3 branch must
# never consume or touch membership before the wrapper's early return).
test_plugdev_dry_run_all_true_no_side_effects() {
    local sandbox="/tmp/rollback-test-plugdev-dryrun-alltrue"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    printf 'plugdev\n' > "$sandbox/group-state"
    local mp="$sandbox/manifest/install-manifest.json"
    python3 - "$mp" << 'PY'
import json, sys
json.dump({"version": "2.0", "records": [], "services": [], "groups": [
    {"group": "plugdev", "user": "testuser", "component": "keyboard",
     "was_member": True}]}, open(sys.argv[1], "w"), indent=2)
PY
    local before
    before="$(file_hex "$mp")"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" DRY_RUN=1 STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u.rc"
    '

    assert_eq "0" "$(cat "$sandbox/u.rc")" "R9b: dry-run remove rc"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd.log")" "R9b: gpasswd never called in dry run"
    assert_contains "plugdev" "$(cat "$sandbox/group-state")" "R9b: membership untouched"
    assert_eq "1" "$(group_count "$mp")" "R9b: all-true record not consumed"
    assert_eq "$before" "$(file_hex "$mp")" "R9b: manifest bytes unchanged"
    if [ -e "$sandbox/manifest/.install-manifest.lock" ]; then
        fail "R9b: dry run must not create a lock file"
    else
        ok
    fi
}

# ---------------------------------------------------------------------------
# Re-review #13 (P2 CONDITIONAL PERMISSION LIFECYCLE): per-install
# added_by_project evidence. The original was_member snapshot stays first-wins
# forever; a reinstall that re-adds an admin-removed membership leaves a bool
# flag which the ownership probe folds into its rc-0 "we added it" evidence.
# Every side effect stays inside the /tmp sandbox via setup_group_state_stubs.
# ---------------------------------------------------------------------------

# R15 — core regression: pre-existing true -> admin removes WHILE INSTALLED ->
# reinstall (first-wins keeps true, flag is set) -> uninstall must revoke the
# membership we just re-added.
test_plugdev_admin_removed_while_installed_reinstall_can_rollback() {
    local sandbox="/tmp/rollback-test-plugdev-lifecycle-added"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    printf 'plugdev\n' > "$sandbox/group-state" # pre-existing member
    local mp="$sandbox/manifest/install-manifest.json"

    # round 1: pre-existing member -> true snapshot, no usermod, no flag
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod1.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i1.rc"
    '
    printf 'GROUP="plugdev"\n' > "$sandbox/udev/61-kbd.rules" # still installed

    # external admin removes the membership while the component is installed
    printf 'audio\n' > "$sandbox/group-state"

    # round 2: current membership false, first-wins snapshot true -> flag set
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod2.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i2.rc"
    '
    local r15_was r15_added r15_state
    r15_was="$(grp_was_member_at "$mp" 0)"
    r15_added="$(grp_added_at "$mp" 0)"
    r15_state="$(cat "$sandbox/group-state")"

    rm -f "$sandbox/udev/61-kbd.rules" # our rule gone; no third-party rule
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod2.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u.rc"
    '

    assert_eq "0" "$(cat "$sandbox/i1.rc")" "R15: round-1 install rc"
    assert_eq "0" "$(usermod_calls "$sandbox/usermod1.log")" "R15: pre-existing member never usermod'ed"
    assert_eq "0" "$(cat "$sandbox/i2.rc")" "R15: round-2 install rc"
    assert_eq "1" "$(usermod_calls "$sandbox/usermod2.log")" "R15: user re-added after admin removal"
    assert_contains "plugdev" "$r15_state" "R15: membership present after reinstall"
    assert_eq "True" "$r15_was" "R15: first-wins was_member=true never overwritten"
    assert_eq "True" "$r15_added" "R15: per-install added flag persisted"
    assert_eq "0" "$(cat "$sandbox/u.rc")" "R15: uninstall rc"
    assert_eq "1" "$(usermod_calls "$sandbox/gpasswd.log")" "R15: gpasswd -d exactly once"
    assert_not_contains "plugdev" "$(cat "$sandbox/group-state")" "R15: new membership revoked"
    assert_eq "0" "$(group_count "$mp")" "R15: all group records consumed"
}

# R16 — third-party udev rule variant: the flag authorises removal but the
# udev gate keeps membership (and the flag) until EVERY rule disappears.
test_plugdev_reinstall_added_kept_while_third_party_rule() {
    local sandbox="/tmp/rollback-test-plugdev-lifecycle-added-udev"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    printf 'plugdev\n' > "$sandbox/group-state"
    local mp="$sandbox/manifest/install-manifest.json"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod1.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i1.rc"
    '
    printf 'GROUP="plugdev"\n' > "$sandbox/udev/61-kbd.rules"
    printf 'audio\n' > "$sandbox/group-state"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod2.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i2.rc"
    '

    # our rule is gone, but a third-party rule still references plugdev
    rm -f "$sandbox/udev/61-kbd.rules"
    printf 'GROUP="plugdev"\n' > "$sandbox/udev/99-third-party.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod2.log" \
            STUB_GPASSWD_LOG="$2/gpasswd1.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u1.rc"
    '
    local r16_added
    r16_added="$(grp_added_at "$mp" 0)"

    assert_contains "udev rules still reference" "$(cat "$sandbox/log.txt")" "R16: udev gate logged"
    assert_eq "0" "$(cat "$sandbox/u1.rc")" "R16: gated uninstall rc"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd1.log")" "R16: no gpasswd while third-party rule remains"
    assert_contains "plugdev" "$(cat "$sandbox/group-state")" "R16: membership kept while third-party rule remains"
    assert_eq "1" "$(group_count "$mp")" "R16: record (with flag) kept while rule remains"
    assert_eq "True" "$r16_added" "R16: added flag survives the gated uninstall"

    rm -f "$sandbox/udev/99-third-party.rules"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod2.log" \
            STUB_GPASSWD_LOG="$2/gpasswd2.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u2.rc"
    '
    assert_eq "0" "$(cat "$sandbox/u2.rc")" "R16: final uninstall rc"
    assert_eq "1" "$(usermod_calls "$sandbox/gpasswd2.log")" "R16: gpasswd once after last rule gone"
    assert_not_contains "plugdev" "$(cat "$sandbox/group-state")" "R16: membership removed"
    assert_eq "0" "$(group_count "$mp")" "R16: record consumed"
}

# Fault injection for R18b: refuse ONLY the new added-flag clear writer.
# argc=6 (python3 -c SCRIPT mp group user comp), script contains
# atomic_write_json AND the unique GROUP_ADDED_FLAG_CLEAR marker; it mentions
# neither was_member (add writer, argc=8) nor GROUP_CONSUME_ALL (consume, argc=5).
block_group_added_clear_stub() {
    local sandbox="$1"
    cat > "$sandbox/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$#" -ge 6 ] && \
   printf '%s' "${2:-}" | grep -q 'atomic_write_json' && \
   printf '%s' "${2:-}" | grep -q 'GROUP_ADDED_FLAG_CLEAR'; then
    printf 'STUB: group added-flag clear refused\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$sandbox/stub/python3"
}

# R18 — a failed usermod must clear ONLY the flag, never the first-wins record.
test_plugdev_reinstall_usermod_failure_clears_added_flag() {
    local sandbox="/tmp/rollback-test-plugdev-added-usermod-fail"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    printf 'plugdev\n' > "$sandbox/group-state"
    local mp="$sandbox/manifest/install-manifest.json"

    # round 1: normal pre-existing install -> true snapshot, no flag
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod1.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i1.rc"
    '
    printf 'audio\n' > "$sandbox/group-state"

    # round 2: re-add FAILS -> flag must be cleared, original record kept (T6)
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod2.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log" STUB_USERMOD_RC=1
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i2.rc"
    '
    local r18_was r18_added
    r18_was="$(grp_was_member_at "$mp" 0)"
    r18_added="$(grp_added_at "$mp" 0)"

    assert_eq "0" "$(cat "$sandbox/i1.rc")" "R18: round-1 install rc"
    assert_eq "1" "$(cat "$sandbox/i2.rc")" "R18: usermod failure propagates"
    assert_eq "1" "$(usermod_calls "$sandbox/usermod2.log")" "R18: usermod attempted once"
    assert_eq "True" "$r18_was" "R18: original was_member=true preserved"
    assert_eq "False" "$r18_added" "R18: added flag cleared after failed usermod"
    assert_eq "1" "$(group_count "$mp")" "R18: original record not removed (T6)"
    assert_not_contains "plugdev" "$(cat "$sandbox/group-state")" "R18: no membership granted"
    assert_not_contains "Could not clear added-by-project evidence" "$(cat "$sandbox/log.txt")" "R18: clear succeeded"

    # R18b (optional fault injection): clear writer fails -> flag kept for
    # manual cleanup (fail closed) and the failure is logged loudly.
    local s2="/tmp/rollback-test-plugdev-added-clear-fail"
    rm -rf "$s2"
    mkdir -p "$s2/backups" "$s2/manifest"
    setup_group_state_stubs "$s2"
    printf 'plugdev\n' > "$s2/group-state"
    block_group_added_clear_stub "$s2"
    local mp2="$s2/manifest/install-manifest.json"
    run_sandboxed "$s2" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod1.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i1.rc"
    '
    printf 'audio\n' > "$s2/group-state"
    run_sandboxed "$s2" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod2.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log" STUB_USERMOD_RC=1
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i2.rc"
    '
    local r18b_added
    r18b_added="$(grp_added_at "$mp2" 0)"
    assert_eq "1" "$(cat "$s2/i2.rc")" "R18b: usermod failure still propagates"
    assert_eq "True" "$r18b_added" "R18b: flag kept when clear writer fails (fail closed)"
    assert_contains "Could not clear added-by-project evidence" "$(cat "$s2/log.txt")" "R18b: failure logged loudly"
}

# R19 — wrong type fails closed; a legacy manifest with no flag is accepted.
test_plugdev_added_flag_wrong_type_fails_closed_legacy_accepted() {
    local sandbox="/tmp/rollback-test-plugdev-added-wrongtype"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    printf 'plugdev\n' > "$sandbox/group-state"
    local mp="$sandbox/manifest/install-manifest.json"
    printf '%s' '{"version":"2.0","records":[],"services":[],"groups":[{"group":"plugdev","user":"testuser","component":"keyboard","was_member":true,"added_by_project":"true"}]}' > "$mp"
    local before
    before="$(file_hex "$mp")"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i.rc"
    '
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u.rc"
    '

    assert_eq "1" "$(cat "$sandbox/i.rc")" "R19: wrong-type manifest blocks install"
    assert_eq "1" "$(cat "$sandbox/u.rc")" "R19: wrong-type manifest blocks uninstall"
    assert_eq "0" "$(usermod_calls "$sandbox/usermod.log")" "R19: no usermod on invalid manifest"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd.log")" "R19: no gpasswd on invalid manifest"
    assert_eq "$before" "$(file_hex "$mp")" "R19: invalid manifest bytes unchanged"
    assert_contains "plugdev" "$(cat "$sandbox/group-state")" "R19: membership untouched"
    assert_contains "added_by_project must be a boolean" "$(cat "$sandbox/log.txt")" "R19: type error diagnosed"

    # legacy manifest with no added_by_project: default false, old semantics
    local s2="/tmp/rollback-test-plugdev-added-legacy"
    rm -rf "$s2"
    mkdir -p "$s2/backups" "$s2/manifest"
    setup_group_state_stubs "$s2"
    printf 'plugdev\n' > "$s2/group-state"
    local mp2="$s2/manifest/install-manifest.json"
    printf '%s' '{"version":"2.0","records":[],"services":[],"groups":[{"group":"plugdev","user":"testuser","component":"keyboard","was_member":true}]}' > "$mp2"

    run_sandboxed "$s2" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i.rc"
    '
    local r19_was r19_added r19_install_groups
    r19_was="$(grp_was_member_at "$mp2" 0)"
    r19_added="$(grp_added_at "$mp2" 0)"
    r19_install_groups="$(group_count "$mp2")"
    run_sandboxed "$s2" '
        export PATH="$2/stub:$PATH" STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u.rc"
    '

    assert_eq "0" "$(cat "$s2/i.rc")" "R19: legacy manifest accepted"
    assert_eq "True" "$r19_was" "R19: legacy was_member preserved"
    assert_eq "False" "$r19_added" "R19: missing field defaults to false"
    assert_eq "1" "$r19_install_groups" "R19: legacy record survives first-wins install"
    assert_eq "0" "$(usermod_calls "$s2/usermod.log")" "R19: no usermod for legacy pre-existing member"
    assert_eq "0" "$(cat "$s2/u.rc")" "R19: legacy uninstall rc"
    assert_eq "0" "$(usermod_calls "$s2/gpasswd.log")" "R19: legacy all-true path never gpasswd"
    assert_eq "0" "$(group_count "$mp2")" "R19: legacy record consumed via rc3"
    assert_contains "plugdev" "$(cat "$s2/group-state")" "R19: legacy membership preserved"
}

# R20 — DRY_RUN with an added flag is side-effect free for BOTH directions.
test_plugdev_dry_run_added_flag_no_side_effects() {
    local sandbox="/tmp/rollback-test-plugdev-dryrun-added"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    printf 'audio\n' > "$sandbox/group-state" # admin removed; reinstall would re-add
    local mp="$sandbox/manifest/install-manifest.json"
    printf '%s' '{"version":"2.0","records":[],"services":[],"groups":[{"group":"plugdev","user":"testuser","component":"keyboard","was_member":true,"added_by_project":true}]}' > "$mp"
    local before
    before="$(file_hex "$mp")"

    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" DRY_RUN=1 STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/u.rc"
    '
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" DRY_RUN=1 STUB_GROUP_STATE="$2/group-state" \
            STUB_UDEV_DIR="$2/udev" STUB_USERMOD_LOG="$2/usermod.log" \
            STUB_GPASSWD_LOG="$2/gpasswd.log"
        source "$1/lib/backup.sh"
        rc=0; ensure_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/i.rc"
    '

    assert_eq "0" "$(cat "$sandbox/u.rc")" "R20: dry-run remove rc"
    assert_eq "0" "$(cat "$sandbox/i.rc")" "R20: dry-run install rc"
    assert_eq "0" "$(usermod_calls "$sandbox/gpasswd.log")" "R20: no gpasswd in dry run"
    assert_eq "0" "$(usermod_calls "$sandbox/usermod.log")" "R20: no usermod in dry run"
    assert_eq "1" "$(group_count "$mp")" "R20: record not consumed"
    assert_eq "$before" "$(file_hex "$mp")" "R20: manifest bytes unchanged"
    if [ -e "$sandbox/manifest/.install-manifest.lock" ]; then
        fail "R20: dry run must not create a lock file"
    else
        ok
    fi
}

# Stub-contract regression: the new clear writer (argc=6, unique marker, no
# was_member / GROUP_CONSUME_ALL) passes both existing writer stubs, while the
# add writer (argc=8 + was_member) is still refused by block_group_manifest_write.
test_plugdev_added_writer_stub_contract() {
    local sandbox="/tmp/rollback-test-plugdev-added-stub-contract"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest"
    setup_group_state_stubs "$sandbox"
    local mp="$sandbox/manifest/install-manifest.json"
    printf '%s' '{"version":"2.0","records":[],"services":[],"groups":[{"group":"plugdev","user":"testuser","component":"keyboard","was_member":true,"added_by_project":true}]}' > "$mp"

    # the consume-all stub must NOT intercept the new clear writer
    block_group_consume_stub "$sandbox"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH"
        source "$1/lib/backup.sh"
        rc=0; manifest_clear_group_added plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/clear.rc"
    '
    assert_eq "0" "$(cat "$sandbox/clear.rc")" "stub-contract: clear writer passes consume-all stub"
    assert_eq "False" "$(grp_added_at "$mp" 0)" "stub-contract: flag cleared"

    # the add-write stub must NOT intercept the clear writer but MUST block add
    block_group_manifest_write "$sandbox"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_USERMOD_LOG="$2/usermod.log"
        source "$1/lib/backup.sh"
        rc=0; manifest_clear_group_added plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/clear2.rc"
        rc=0; manifest_add_group plugdev testuser keyboard 1 1 || rc=$?
        printf "%s\n" "$rc" > "$2/add.rc"
    '
    assert_eq "0" "$(cat "$sandbox/clear2.rc")" "stub-contract: clear writer passes add-write stub"
    assert_eq "1" "$(cat "$sandbox/add.rc")" "stub-contract: add writer still refused"
}

# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
test_restore_existing
test_remove_new_file
test_double_install
test_scope_protection
test_symlink_restore
test_meson_plan
test_service_manifest
test_group_manifest
test_legacy_manifest
test_group_reinstall_first_wins
test_service_reinstall_first_wins
test_group_remove_keeps_record_on_failure
# Finding #4: record membership before changing /etc/group; roll back on failure
test_ensure_group_manifest_write_failure_no_membership_change
test_plugdev_manifest_write_failure_install_fails_without_membership
test_ensure_group_usermod_failure_rolls_back_manifest
test_plugdev_usermod_failure_install_nonzero_no_false_record
test_plugdev_success_and_reinstall_first_wins
test_usermod_failure_with_existing_record_keeps_first_wins_record
test_kbd_backlight_sync_install
test_kbd_backlight_double_install
test_keyd_legacy_link_helper
test_keyd_link_backup_and_rollback absent
test_keyd_link_backup_and_rollback cros_link
test_keyd_link_backup_and_rollback other_link
test_keyd_invalid_config_skips_deploy
test_keyd_supports_check_probe
test_keyd_restart_failure_recovery yes
test_keyd_restart_failure_recovery no
test_keyd_restart_failure_restores_symlink_backup
test_keyd_dangling_symlink_is_ours
test_keyd_no_binary_deploys_config_only
test_keyd_dry_run_no_side_effects
test_with_keyd_verified_returns_zero
test_with_keyd_active_unverified_returns_zero
test_with_keyd_config_only_returns_nonzero
test_with_keyd_config_only_optin
test_with_keyd_source_missing_returns_failure
test_without_with_keyd_stays_zero
test_keyd_prepare_link_without_backup
test_keyd_restart_unrecoverable_returns_failure
test_keyd_was_existing_false_removes_new_link
test_keyd_legacy_manifest_without_component
test_keyd_legacy_upgrade_link_already_removed
test_keyd_legacy_component_normalization
test_keyd_rvaiya_fallback
test_keyd_upgrade_failure_preserves_v1
test_keyd_upgrade_failure_preserves_v1_with_original
test_keyd_upgrade_failure_preserves_symlink_type
test_keyd_upgrade_failure_restores_service_state
test_keyd_snapshot_cleanup_on_success
test_keyd_snapshot_create_failure_fails_closed
test_keyd_unsupported_path_type_fails_closed dir
test_keyd_unsupported_path_type_fails_closed fifo
test_keyd_backup_copy_failure_fails_closed
test_keyd_manifest_write_failure_fails_closed
test_keyd_link_backup_failure_fails_closed
test_keyd_service_manifest_failure_fails_closed
test_keyd_service_manifest_failure_recovery
test_manifest_add_service_failure_returns_nonzero
test_backup_helper_copy_failure_returns_nonzero
test_backup_helper_manifest_failure_returns_nonzero
test_keyd_snapshot_base_world_writable_fails_closed
test_keyd_snapshot_base_nonroot_owner_fails_closed
test_keyd_snapshot_base_nonroot_parent_fails_closed
test_keyd_snapshot_base_root_owned_nonroot_caller_succeeds
test_keyd_snapshot_base_world_parent_rejected
test_keyd_snapshot_base_custom_root_owned_succeeds
test_keyd_snapshot_base_symlink_rejected
test_keyd_restore_failure_keeps_snapshot
test_keyd_snapshot_mixed_identity
test_keyd_snapshot_prune_skips_failed
test_keyd_restore_uses_sudo_nonroot
test_uninstall_has_no_post_rollback_keyd_cleanup
test_uninstall_leaves_foreign_keyd_alone
test_uninstall_disables_managed_keyd_and_restores_state
test_uninstall_keeps_keyd_without_service_record
test_uninstall_manifest_without_services_does_not_disable_keyd
test_keyd_managed_by_us_fail_safe
test_uninstall_dryrun_keyd_ownership_messages
test_keyd_corrupt_manifest_fails_closed
test_keyd_reinstall_with_corrupt_manifest_keeps_first_backup
test_corrupt_manifest_payloads_fail_closed
test_backup_manifest_aware_corrupt_fails_closed
test_missing_manifest_still_creates_data
test_legacy_manifest_missing_optional_fields_is_accepted
test_corrupt_manifest_uninstall_does_not_touch_manifest
test_missing_manifest_without_python3_is_untracked
test_manifest_field_type_payloads_fail_closed
test_schema_invalid_manifest_rollback_has_no_side_effects
test_schema_optional_fields_and_roundtrip_accepted
test_uninstall_schema_invalid_manifest_does_not_touch_services
test_non_absolute_manifest_entries_are_skipped
test_nul_target_rollback_has_no_service_side_effects
test_missing_python3_existing_manifest_dryrun_rollback_fails_closed
test_rollback_python_failure_returns_nonzero
# Finding #1: missing safety fields are unknown (fail closed)
test_missing_was_existing_record_never_deletes_file
test_missing_service_flags_never_disables_or_stops
test_rollback_python_unknown_state_is_fail_closed_without_validator
# Finding #2: restore the original even when the target is absent
test_rollback_absent_target_restores_first_backup_file
test_rollback_absent_target_restores_first_backup_symlink
test_rollback_absent_target_no_backup_keeps_record
test_rollback_mixed_missing_backup_and_success
test_rollback_absent_target_was_existing_false_is_safe_noop
test_rollback_absent_target_restore_failure_keeps_record
# P2 DATA SAFETY: failed final swap must not unlink the installed target
test_rollback_replace_failure_keeps_installed_file
test_rollback_replace_failure_keeps_installed_symlink
test_rollback_replace_success_regular_file
test_rollback_replace_success_directory
test_rollback_replace_failure_restores_directory
test_rollback_replace_directory_backup_over_file
# Finding #3: systemctl failures keep records and report non-zero
test_rollback_systemctl_failure_keeps_record
test_rollback_systemctl_failure_retry_consumes_record
test_rollback_enable_failure_keeps_record
test_rollback_disable_failure_keeps_record
test_rollback_stop_failure_keeps_record
test_rollback_user_scope_global_failure_keeps_record
test_rollback_user_scope_no_manager_keeps_record
test_rollback_user_scope_start_failure_keeps_record
test_rollback_systemctl_spawn_failure_keeps_record
test_rollback_all_success_consumes_services_and_records
# Non-keyboard uninstall callers: propagate rollback rc without skipping cleanup
test_caller_uninstall_rollback_failure fingerprint uninstall_fp "udevadm control --reload-rules" caller.log "Fingerprint driver uninstallation finished."
test_caller_uninstall_rollback_failure ec uninstall_ec_tools "systemctl daemon-reload" caller.log "EC utilities removed."
test_caller_uninstall_rollback_failure audio uninstall_audio "rmdir /usr/share/alsa/ucm2/conf.d/sof-rt5682" caller.log "Audio UCM profiles removed successfully."
test_caller_uninstall_rollback_failure power uninstall_power "Reboot (or log out and back in)" log.txt "Power optimization profiles removed."
# Keyboard uses the dedicated keyd sandbox: `daemon-reload` is logged only
# AFTER rollback_component(), so it doubles as the post-rollback cleanup marker.
test_caller_uninstall_rollback_failure keyboard _uninstall_keyboard_body "daemon-reload" caller.log "Keyboard mapping uninstallation completed."
test_caller_uninstall_rollback_success fingerprint uninstall_fp "udevadm control --reload-rules" caller.log "Fingerprint driver uninstallation finished."
test_caller_uninstall_rollback_success ec uninstall_ec_tools "systemctl daemon-reload" caller.log "EC utilities removed."
test_caller_uninstall_rollback_success audio uninstall_audio "rmdir /usr/share/alsa/ucm2/conf.d/sof-rt5682" caller.log "Audio UCM profiles removed successfully."
test_caller_uninstall_rollback_success power uninstall_power "Reboot (or log out and back in)" log.txt "Power optimization profiles removed."
test_caller_uninstall_rollback_success keyboard _uninstall_keyboard_body "daemon-reload" caller.log "Keyboard mapping uninstallation completed."
test_uninstall_success_log_is_rollback_conditional
test_fingerprint_uninstall_cleanup_order_unchanged
test_caller_uninstall_regression_detects_unguarded_rollback
# Re-review #9 finding #1: cross-process manifest transaction lock
test_lock_concurrent_writers_keep_both_records
test_lock_concurrent_install_and_rollback_preserves_records
test_lock_writers_use_unique_temp
test_lock_nested_no_deadlock
test_lock_timeout_fails_closed
test_lock_dryrun_and_no_python3_untouched
test_lock_high_contention_all_records_survive
test_lock_same_target_first_backup_wins
# Re-review #10 findings #2/#3: lock inode/symlink hardening and root holder
test_sec_lock_rejects_symlink_to_regular
test_sec_lock_rejects_dangling_symlink
test_sec_lock_rejects_symlink_to_directory
test_sec_lock_rejects_fifo_without_blocking
test_sec_lock_rejects_device_node
test_sec_lock_rejects_world_writable_parent
test_sec_lock_rejects_symlinked_parent
test_sec_lock_rejects_post_open_inode_swap
test_sec_lock_rejects_third_party_owner
test_sec_lock_rejects_post_open_owner_swap
test_sec_unprivileged_cannot_flock
test_sec_holder_contention_and_recovery
test_sec_crash_releases_lock_without_unlock
# Re-review #11 finding #3: lock parent trust boundary / rename double-holder
test_sec_lock_rejects_user_owned_parent
test_sec_lock_rename_after_acquire_cannot_create_second_holder
test_sec_lock_helper_rechecks_parent_dir
test_sec_lock_nonroot_root_owned_dir_succeeds
# Phase 3: ancestor gate must require root ownership even for a sticky layer
test_sec_lock_ancestor_gate
# Re-review #12 finding #1: canonical realpath trust boundary / holder recheck
test_sec_lock_rejects_relative_manifest_dir
test_sec_lock_rejects_trusted_symlink_to_user_target
test_sec_lock_canonical_ancestor_user_dir
test_sec_lock_holder_rejects_symlink_derived_path
test_sec_lock_absolute_root_owned_dir_control
# Re-review #10 finding #1: operation-level (backup -> deploy -> rollback) lock
test_op_deploy_vs_rollback_barrier OP1 keyboard-hwdb keyboard
test_op_deploy_vs_rollback_barrier OP1 audio-ucm audio
test_op_deploy_vs_rollback_barrier OP2 keyboard-hwdb keyboard ORIGINAL
test_op_deploy_vs_rollback_barrier OP2 audio-ucm audio ORIGINAL
test_op_lock_failure_skips_operation_body
test_op_fail_open_guard_under_errexit
test_op_real_installer_barrier
# Re-review #11 finding #1: cross-component plugdev ownership aggregation
test_plugdev_full_install_uninstall_keyboard_first
test_plugdev_full_install_uninstall_fingerprint_first
test_plugdev_preexisting_member_kept_across_all_uninstalls
test_plugdev_single_component_install_uninstall
test_plugdev_gpasswd_failure_returns_nonzero_and_keeps_records
test_plugdev_gpasswd_failure_propagates_from_real_uninstaller
test_plugdev_udev_rule_gates_removal_until_last_one_disappears
test_plugdev_three_components_ec_included
test_plugdev_remove_fails_closed_on_invalid_manifest
test_plugdev_dry_run_remove_no_side_effects
# Re-review #12 finding #3: all-true (stale) record lifecycle
test_plugdev_preexisting_then_admin_removed_reinstall_can_rollback
test_plugdev_preexisting_three_components_consume_only_after_last
test_plugdev_preexisting_member_udev_rule_keeps_record_then_consumes
test_plugdev_preexisting_consume_failure_keeps_record
test_plugdev_dry_run_all_true_no_side_effects
# Re-review #13 (P2 CONDITIONAL): per-install added_by_project lifecycle
test_plugdev_admin_removed_while_installed_reinstall_can_rollback
test_plugdev_reinstall_added_kept_while_third_party_rule
test_plugdev_reinstall_usermod_failure_clears_added_flag
test_plugdev_added_flag_wrong_type_fails_closed_legacy_accepted
test_plugdev_dry_run_added_flag_no_side_effects
test_plugdev_added_writer_stub_contract

# ---------------------------------------------------------------------------
# Re-review #11/#12 finding #2 (P2 DATA SAFETY / STATE RESTORATION, PAM-1..12):
# uninstall must not delete a pre-existing pam_fprintd line from /etc/pam.d/sudo
# after rollback, and the Debian profile selection must survive install+uninstall.
# The ONLY writer of those bytes is rollback_component(); disable_pam_fingerprint()
# is read-only apart from distro-tool state messages.
#
# Every case uses a fresh /tmp/rollback-test-pam-* sandbox. BOTH path seams are
# redirected and every tool is stubbed inside the sandbox; the stubs refuse any
# argument under /etc/pam.d, so a misconfigured seam fails the case instead of
# touching the host's PAM files. Nothing here writes real sysfs/service/D-Bus.
# ---------------------------------------------------------------------------
setup_pam_sandbox() {
    # $1=short case name; echoes the fresh sandbox path.
    local s
    s="$(mktemp -d "/tmp/rollback-test-pam-$LOCK_TEST_RUN_TAG-$1-XXXXXX")"
    mkdir -p "$s/pam" "$s/backups" "$s/manifest" "$s/stub" "$s/debconf" "$s/savedir"
    : > "$s/tool.log"
    : > "$s/sed.log"
    # A readable debconf selection is part of a valid Debian fixture: the
    # snapshot gate now fails closed when the key is absent (PAM-24c/27c/28).
    # Cases that need "key absent" must call pam_unset_selection() explicitly.
    printf 'unix, fprintd\n' > "$s/debconf/profiles"

    # sudo: pass through, but never let a /etc/pam.d path escape the sandbox.
    cat > "$s/stub/sudo" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        /etc/pam.d/*|*/etc/pam.d/*)
            printf 'STUB ESCAPE: sudo asked to touch host PAM: %s\n' "$_a" >&2
            exit 99
            ;;
    esac
done
exec "$@"
EOF

    # sed: log every mutation call (uninstall must add ZERO entries) and refuse
    # host PAM paths before delegating to the real sed on sandbox files only.
    cat > "$s/stub/sed" << 'EOF'
#!/usr/bin/env bash
# Only MUTATIONS (sed -i) are counted; read-only sed used to parse debconf
# output must not inflate the project's own sed-call assertions.
_mutation=0
for _a in "$@"; do
    [ "$_a" = "-i" ] && _mutation=1
done
[ "$_mutation" = "1" ] && printf '%s\n' "$*" >> "${STUB_SED_LOG:?PAM sed stub missing log}"
# Phase A mutation seam: corrupt a line-deleting sed by appending ONE extra
# deletion, so T2 must detect the lost non-fp line.
if [ "${STUB_SED_CORRUPT:-0}" = "1" ] && [ "$_mutation" = "1" ]; then
    _has_d=0
    for _a in "$@"; do
        case "$_a" in *d) _has_d=1 ;; esac
    done
    if [ "$_has_d" = "1" ]; then
        # sed's LAST argument is the target file; insert one extra deletion.
        _n=$#
        _m=$((_n - 1))
        _file="${!_n}"
        set -- "${@:1:_m}" -e '2d' "$_file"
    fi
fi
for _a in "$@"; do
    case "$_a" in
        /etc/pam.d/*|*/etc/pam.d/*)
            printf 'STUB ESCAPE: sed asked to touch host PAM: %s\n' "$_a" >&2
            exit 99
            ;;
    esac
done
exec /usr/bin/sed "$@"
EOF

    # pam-auth-update: model the real tool's reconciliation. `--package`
    # DERIVES the enabled profile list from the current common-* files plus the
    # /var/lib/pam saved module snapshots (the fprintd dimension of the real
    # diff_profiles()), then persists that list into debconf and converges BOTH
    # file sets — so a second --package is a no-op. It never just copies the old
    # selection. `--remove fprintd` and `--regenerate` stay as legacy controls
    # used by PAM-12 and PAM-10 respectively.
    cat > "$s/stub/pam-auth-update" << 'EOF'
#!/usr/bin/env bash
_sel="${STUB_DEBCONF_PROFILES:?PAM debconf seam missing}"
_dir="${CROS_ENABLEMENT_PAM_DIR:?PAM dir seam missing}"
_saved="${CROS_ENABLEMENT_PAM_SAVED_DIR:?PAM savedir seam missing}"
_types=(auth account password session session-noninteractive)

case "${1:-}" in
    --regenerate)
        printf 'pam-auth-update %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
        # TEST-ONLY mode: rebuild common-auth from the current selection.
        {
            printf '%s\n' 'auth [success=1 default=ignore] pam_unix.so nullok'
            if [ -f "$_sel" ] && grep -qF 'fprintd' "$_sel"; then
                printf '%s\n' 'auth sufficient pam_fprintd.so'
            fi
            printf '%s\n' 'auth requisite pam_deny.so'
        } > "$_dir/common-auth"
        exit 0
        ;;
    --remove)
        printf 'pam-auth-update %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
        if [ "${2:-}" = "fprintd" ]; then
            # Real --remove side effect: drop the profile from debconf, THEN
            # rewrite generated files. Use /usr/bin/sed so this is not counted
            # as one of the project's own sed calls in sed.log.
            if [ -f "$_sel" ]; then
                _new="$(/usr/bin/sed -e 's/[[:space:]]*fprintd[[:space:]]*//g' \
                    -e 's/,,*/,/g' -e 's/^,//' -e 's/,$//' \
                    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$_sel")"
                printf '%s\n' "$_new" > "$_sel"
            fi
            for _f in "$_dir"/common-*; do
                [ -f "$_f" ] || continue
                /usr/bin/sed -i '/pam_fprintd\.so/d' "$_f"
            done
        fi
        exit 0
        ;;
    --package) ;;
    *)
        printf 'pam-auth-update %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
        exit 0
        ;;
esac

# Profiles declared by the saved snapshots (what the tool knows about).
_saved_names() {
    local _t
    for _t in "${_types[@]}"; do
        [ -f "$_saved/$_t" ] || continue
        sed -n 's/^Module:[[:space:]]*//p' "$_saved/$_t"
    done
}

# Enabled profiles: declared in the saved snapshot AND still present in the
# matching common-* file. This is exactly the dimension in which the real
# diff_profiles() loses fprintd after the project's direct sed.
_enabled_names() {
    local _t _name _line _so
    for _t in "${_types[@]}"; do
        [ -f "$_saved/$_t" ] || continue
        _name=""
        while IFS= read -r _line; do
            case "$_line" in
                Module:*)
                    _name="${_line#Module:}"
                    _name="${_name#"${_name%%[![:space:]]*}"}"
                    ;;
                *.so*)
                    [ -n "$_name" ] || continue
                    _so="$(printf '%s\n' "$_line" | awk '{for (i=1;i<=NF;i++) if ($i ~ /\.so$/) {print $i; exit}}')"
                    [ -n "$_so" ] || continue
                    if grep -qF -- "$_so" "$_dir/common-$_t" 2> /dev/null; then
                        printf '%s\n' "$_name"
                    fi
                    _name=""
                    ;;
            esac
        done < "$_saved/$_t"
    done
}

_reconcile() {
    local _t _so _name _enabled _old _new _item _append _tmp
    local -a _items
    # An extra .so in a managed common-* file is a local modification: the real
    # diff_profiles() fails and the tool refuses to touch the selection.
    for _t in "${_types[@]}"; do
        [ -f "$_saved/$_t" ] || continue
        while IFS= read -r _so; do
            [ -n "$_so" ] || continue
            if ! grep -qF -- "$_so" "$_saved/$_t"; then
                # Observable in the sandbox tool log so a test can prove the
                # CONTENT-driven diff-fail path really ran (no env shortcut).
                printf 'pam-auth-update: local modification in common-%s, not updating (stub)\n' "$_t" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
                printf 'pam-auth-update: local modification in common-%s, not updating (stub)\n' "$_t" >&2
                return 0
            fi
        done < <(awk '{for (i=1;i<=NF;i++) if ($i ~ /\.so$/) print $i}' "$_dir/common-$_t" 2> /dev/null)
    done

    _enabled="$(_enabled_names | awk '!seen[$0]++')"
    _old="$(cat "$_sel" 2> /dev/null)"
    _new=""
    IFS=', ' read -r -a _items <<< "$_old"
    for _item in "${_items[@]}"; do
        [ -n "$_item" ] || continue
        if printf '%s\n' "$_enabled" | grep -qxF -- "$_item"; then
            _append=1
        elif printf '%s\n' "$(_saved_names)" | grep -qxF -- "$_item"; then
            _append=0 # saved profile whose module lines are gone
        else
            _append=1 # not managed by our savedir fixtures: preserve verbatim
        fi
        if [ "$_append" = "1" ]; then
            if [ -z "$_new" ]; then _new="$_item"; else _new="$_new, $_item"; fi
        fi
    done
    printf '%s\n' "$_new" > "$_sel"

    # Converge the saved snapshots and common-* files: drop the module blocks of
    # every saved profile that is no longer enabled (a later call is a no-op).
    for _t in "${_types[@]}"; do
        [ -f "$_saved/$_t" ] || continue
        while IFS= read -r _name; do
            [ -n "$_name" ] || continue
            printf '%s\n' "$_enabled" | grep -qxF -- "$_name" && continue
            while IFS= read -r _so; do
                [ -n "$_so" ] || continue
                /usr/bin/sed -i "\\|$_so|d" "$_saved/$_t" "$_dir/common-$_t" 2> /dev/null || true
            done < <(awk -v n="$_name" '$1 == "Module:" && $2 == n {f=1; next} /^Module:/ {f=0} f {for (i=1;i<=NF;i++) if ($i ~ /\.so$/) print $i}' "$_saved/$_t")
            _tmp="${_saved}/$_t.stub.$$"
            awk -v n="$_name" '/^Module:/ { keep = ($2 != n) } keep { print }' < "$_saved/$_t" > "$_tmp"
            mv "$_tmp" "$_saved/$_t"
        done < <(sed -n 's/^Module:[[:space:]]*//p' "$_saved/$_t")
    done

    if [ -n "${STUB_PAM_STATE_DIGEST:-}" ]; then
        { cat "$_sel"; for _t in "${_types[@]}"; do
            cat "$_saved/$_t" "$_dir/common-$_t" 2> /dev/null
          done; } | cksum >> "$STUB_PAM_STATE_DIGEST"
    fi
}

# STUB_PAM_REWRITE_COMMON models the REAL tool's write_profiles(): canonicalise
# whitespace and publish through a .pam-new rename with umask 0022, which
# silently turns a 0600 original into 0644. Opt-in so all older cases keep the
# no-rewrite stub (PAM-43 uses it as a sensitivity control).
if [ "${STUB_PAM_REWRITE_COMMON:-0}" = "1" ]; then
    for _f in "$_dir"/common-*; do
        [ -f "$_f" ] || continue
        _tmp="${_f}.pam-new.$$"
        (umask 0022; /usr/bin/sed -e 's/[[:space:]][[:space:]]*/ /g' "$_f" > "$_tmp")
        /bin/mv -f -- "$_tmp" "$_f"
    done
fi

# STUB_PAM_PACKAGE_REPEAT models extra --package invocations (package upgrade
# plus an administrator rerun) arriving in the same install window.
_repeats="${STUB_PAM_PACKAGE_REPEAT:-1}"
_n=1
while [ "$_n" -le "$_repeats" ]; do
    printf 'pam-auth-update %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
    _reconcile || exit $?
    _n=$((_n + 1))
done

# STUB_PAM_REINJECT_FP models an external actor (or a misbehaving tool)
# re-adding an ACTIVE pam_fprintd.so module AFTER the product's direct strip.
# The installed-state postcondition must reject that (PAM-59); the debconf
# selection is deliberately NOT the oracle here.
if [ "${STUB_PAM_REINJECT_FP:-0}" = "1" ] && [ -f "$_dir/common-auth" ]; then
    printf '%s\n' 'auth sufficient pam_fprintd.so' >> "$_dir/common-auth"
fi
exit 0
EOF

    # debconf tools: log EVERY call so a test can prove the installer and
    # uninstaller never touch the profile selection. set-selections really
    # writes the selection file, so any mutation is observable.
    #
    # State files (the INDEPENDENT oracle reads these raw, never lib/pam.sh):
    #   STUB_DEBCONF_PROFILES  raw value; ABSENT => the question does not exist
    #   STUB_DEBCONF_SEEN      true|false; absent => the seen field is unavailable
    cat > "$s/stub/debconf-show" << 'EOF'
#!/usr/bin/env bash
printf 'debconf-show %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
[ "${1:-}" = "libpam-runtime" ] || exit 0
_sel="${STUB_DEBCONF_PROFILES:?PAM debconf seam missing}"
_seen="${STUB_DEBCONF_SEEN:-}"
[ -f "$_sel" ] || exit 0 # key absent: debconf-show prints NO line at all
_prefix='  '
if [ -n "$_seen" ] && [ -f "$_seen" ] && [ "$(cat "$_seen")" = "true" ]; then
    _prefix='* '
fi
printf '%slibpam-runtime/profiles: %s\n' "$_prefix" "$(cat "$_sel")"
EOF

    # debconf-communicate protocol model. A REAL tool exits with the NUMERIC
    # STATUS OF THE LAST command (GET of a missing key prints "10 ..." and
    # exits 10), so this stub MUST mirror that: the product has to check the
    # process rc and the reply status, not silently fall back (P2-1).
    # An existing question ALWAYS has a seen flag (true or false); the only
    # way to model "legacy" is a sidecar WITHOUT metadata (P3), never a
    # "10 seen field unavailable" reply the real tool could not produce.
    cat > "$s/stub/debconf-communicate" << 'EOF'
#!/usr/bin/env bash
printf 'debconf-communicate %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
_sel="${STUB_DEBCONF_PROFILES:?PAM debconf seam missing}"
_seen="${STUB_DEBCONF_SEEN:-}"
_last_status=0
while IFS= read -r _cmd; do
    [ -n "$_cmd" ] || continue
    printf 'debconf-communicate cmd: %s\n' "$_cmd" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
    _last_status=0
    case "$_cmd" in
        GET\ libpam-runtime/profiles*)
            if [ -f "$_sel" ]; then
                printf '0 %s\n' "$(cat "$_sel")"
            else
                printf '10 libpam-runtime/profiles does not exist\n'
                _last_status=10
            fi
            ;;
        FGET\ libpam-runtime/profiles\ seen*)
            if [ -f "$_sel" ]; then
                # Question exists => the seen field exists. An unset sidecar
                # file means "unseen" (false), which is what debconf reports.
                _flag=false
                if [ -n "$_seen" ] && [ -f "$_seen" ]; then
                    _flag="$(cat "$_seen")"
                fi
                printf '0 %s\n' "$_flag"
            else
                printf '10 libpam-runtime/profiles does not exist\n'
                _last_status=10
            fi
            ;;
        FSET\ libpam-runtime/profiles\ seen\ *)
            _val="${_cmd##* }"
            if [ ! -f "$_sel" ]; then
                printf '10 libpam-runtime/profiles does not exist\n'
                _last_status=10
            else
                case "$_val" in
                    true|false)
                        if [ -n "$_seen" ]; then
                            printf '%s\n' "$_val" > "$_seen"
                            printf '0\n'
                        else
                            # Harness seam missing (not a tool state): report
                            # a protocol failure so the product fails closed.
                            printf '12 no seen seam\n'
                            _last_status=12
                        fi
                        ;;
                    *) printf '12 invalid seen value\n'; _last_status=12 ;;
                esac
            fi
            ;;
        *) printf '10 unknown command\n'; _last_status=10 ;;
    esac
done
exit "$_last_status"
EOF

    cat > "$s/stub/debconf-set-selections" << 'EOF'
#!/usr/bin/env bash
printf 'debconf-set-selections %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
# Accept the real template form `libpam-runtime libpam-runtime/profiles
# multiselect <value>` emitted by lib/pam.sh, while keeping the legacy raw-value
# form (used by older tests) observable as well.
_in="$(cat)"
case "$_in" in
    libpam-runtime\ libpam-runtime/profiles\ multiselect*)
        _val="${_in#libpam-runtime libpam-runtime/profiles multiselect}"
        _val="${_val#"${_val%%[![:space:]]*}"}"
        ;;
    *) _val="$_in" ;;
esac
printf '%s\n' "$_val" > "${STUB_DEBCONF_PROFILES:?PAM debconf seam missing}"
# Real debconf-set-selections marks the question seen; FSET must undo that.
_seen="${STUB_DEBCONF_SEEN:-}"
[ -z "$_seen" ] || printf 'true\n' > "$_seen"
EOF

    # authselect / pam-config: log only, never call real distro tooling.
    cat > "$s/stub/authselect" << 'EOF'
#!/usr/bin/env bash
printf 'authselect %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
exit 0
EOF
    cat > "$s/stub/pam-config" << 'EOF'
#!/usr/bin/env bash
printf 'pam-config %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
exit 0
EOF

    # Rollback fault injection. argc=6 plus the target_comp marker identifies
    # the rollback writer; the manifest add-entry writer (argc=7) still works,
    # so the record survives exactly as on a real failed rollback.
    cat > "$s/stub/python3" << 'EOF'
#!/usr/bin/env bash
if [ "${STUB_FAIL_ROLLBACK_PY:-0}" = "1" ] && [ "$1" = "-c" ] && [ "$#" -eq 6 ] \
        && printf '%s' "$2" | grep -q 'target_comp = sys.argv\[2\]'; then
    printf 'STUB: rollback python refused\n' >&2
    exit 1
fi
exec /usr/bin/python3 "$@"
EOF

    # Phase A P2 (T2 parse->snapshot drift): the strip helper captures the
    # dev:inode with `stat -c %d:%i` immediately before snapshotting. Mutate the
    # LIVE file at that exact point so the byte-compare must notice the drift.
    cat > "$s/stub/stat" << 'EOF'
#!/usr/bin/env bash
if [ "${STUB_STAT_DRIFT:-0}" = "1" ] && [ ! -e "${STUB_STAT_DRIFT_MARK:?}" ]; then
    for _a in "$@"; do
        if [ "$_a" = '%d:%i' ]; then
            for _p in "$@"; do
                case "$_p" in
                    */common-auth)
                        printf '%s\n' "$_p" > "$STUB_STAT_DRIFT_MARK"
                        printf 'auth required pam_drift.so\n' >> "$_p"
                        ;;
                esac
            done
        fi
    done
fi
exec /usr/bin/stat "$@"
EOF
    chmod +x "$s/stub/"*
    PAM_TEST_SANDBOXES+=("$s")
    printf '%s\n' "$s"
}

# Model debconf's libpam-runtime/profiles value — the persistent state that
# review12 #2 says `pam-auth-update --remove` destroys. The file holds the raw
# comma-separated value; debconf-show formats it on output and
# debconf-set-selections writes it back. pam_selection() reads it directly so
# tests compare the EXACT string (no normalisation).
pam_write_selection() { # $1=sandbox  $2="unix, systemd, fprintd"
    mkdir -p "$1/debconf"
    printf '%s\n' "$2" > "$1/debconf/profiles"
}
pam_selection() { cat "$1/debconf/profiles"; }

# --- INDEPENDENT oracles for the re-review P1 #2 regressions -----------------
# These read the stub's RAW state files directly. They deliberately do NOT call
# lib/pam.sh's _pam_read_selection() (that would be a self-proving test).
pam_write_selection_seen() { # $1=sandbox  $2=true|false
    mkdir -p "$1/debconf"
    printf '%s\n' "$2" > "$1/debconf/seen"
}
pam_selection_seen() { cat "$1/debconf/seen" 2> /dev/null; }
pam_unset_selection() { # key absent: no profiles file, no seen file
    rm -f "$1/debconf/profiles" "$1/debconf/seen"
}

# Write a Debian-style sudo PAM file (and optionally common-auth) into the
# sandbox. $2 = sudo content: exact | other | none. $3 = common-auth: none | fp.
pam_write_initial_files() {
    local s="$1" sudo_mode="$2" common_mode="$3"
    case "$sudo_mode" in
        exact)
            cat > "$s/pam/sudo" << 'EOF'
# sudo PAM - pre-existing EXACT project line
auth sufficient pam_fprintd.so max-tries=1 timeout=10
@include common-auth
@include common-account
EOF
            ;;
        other)
            cat > "$s/pam/sudo" << 'EOF'
# sudo PAM - pre-existing OTHER fingerprint rules
auth sufficient pam_fprintd.so
auth sufficient rust_fp.so
@include common-auth
@include common-account
EOF
            ;;
        none)
            cat > "$s/pam/sudo" << 'EOF'
# sudo PAM - no fingerprint line
@include common-auth
@include common-account
EOF
            ;;
    esac
    case "$common_mode" in
        fp)
            # Phase A P1: fp is BEFORE the jump source, so the `success=1`
            # landing (pam_permit.so) is identical with and without fp.
            cat > "$s/pam/common-auth" << 'EOF'
auth sufficient pam_fprintd.so
auth [success=1 default=ignore] pam_unix.so nullok
auth requisite pam_deny.so
auth required pam_permit.so
EOF
            ;;
        *) ;; # no common-auth file in the sandbox
    esac
}

# Full Debian PAM stack fixture for the fidelity-driven --package stub:
# every module declared in savedir has a matching line in the corresponding
# common-* file, so diff_profiles() succeeds. fprintd is enabled in auth only.
# The savedir files use the real `Module: <name>` + module-line format.
pam_write_full_stack() {
    local s="$1" t
    mkdir -p "$s/savedir" "$s/pam"
    # Phase A P1: the standard Debian shape puts the fp profile BEFORE the
    # `[success=1 default=ignore]` pam_unix jump source. The landing is the
    # non-fp pam_permit.so both before and after removing fp, so this fixture
    # exercises the intended strip/convergence behaviour without changing
    # authentication control flow. Every module in common-auth is declared in
    # savedir/auth so the tool's diff_profiles() model still succeeds.
    printf 'Module: unix\n[success=1 default=ignore]\tpam_unix.so nullok\nauth requisite pam_deny.so\nauth required pam_permit.so\nModule: fprintd\n[success=end default=ignore]\tpam_fprintd.so max-tries=1 timeout=10\n' \
        > "$s/savedir/auth"
    printf 'auth sufficient pam_fprintd.so\nauth [success=1 default=ignore] pam_unix.so nullok\nauth requisite pam_deny.so\nauth required pam_permit.so\n' \
        > "$s/pam/common-auth"
    printf '# sudo PAM - no fingerprint line\n@include common-auth\n@include common-account\n' \
        > "$s/pam/sudo"
    for t in account password session session-noninteractive; do
        printf 'Module: unix\n[success=ok default=ignore]\tpam_unix.so\n' > "$s/savedir/$t"
        printf '%s required pam_unix.so\n' "$t" > "$s/pam/common-$t"
    done
}

# Hex digest of every file the real pam-auth-update can rewrite, plus sudo and
# the debconf selection. Used by PAM-14..18 for byte-exact round-trip checks.
pam_stack_fingerprint() {
    local s="$1" t
    for f in "$s/pam/sudo" "$s/debconf/profiles"; do
        [ -f "$f" ] && file_hex "$f"
    done
    for t in auth account password session session-noninteractive; do
        [ -f "$s/pam/common-$t" ] && file_hex "$s/pam/common-$t"
        [ -f "$s/savedir/$t" ] && file_hex "$s/savedir/$t"
    done
}

# Same as pam_stack_fingerprint but WITHOUT the debconf selection bytes — used
# when a test deliberately canonicalizes that value and only PAM files must
# round-trip byte-for-byte.
pam_files_fingerprint() {
    local s="$1" t
    [ -f "$s/pam/sudo" ] && file_hex "$s/pam/sudo"
    for t in auth account password session session-noninteractive; do
        [ -f "$s/pam/common-$t" ] && file_hex "$s/pam/common-$t"
        [ -f "$s/savedir/$t" ] && file_hex "$s/savedir/$t"
    done
}

pam_record_count() {
    local mp="$1/manifest/install-manifest.json"
    [ -f "$mp" ] || {
        printf '0\n'
        return 0
    }
    manifest_count "$mp" records
}

# Install step: exactly what the fingerprint installer calls, with the seam
# env vars inherited from the caller's prefix assignment.
#
# $3 = per-call rollback fault injection flag (default 0). It is passed as an
# explicit argument into the sandbox and exported THERE, never from the parent
# shell: exporting it in the parent would let a fail=1 call leak into every
# later install/uninstall in the same shell (the CI PAM-8 failure).
# $4 = per-call STUB_PAM_REWRITE_COMMON flag (default 0), same isolation reason
# as PAM-9: do not rely on a prefix assignment that a future `export` could
# leak into later cases.
# $5 = per-call STUB_PAM_REINJECT_FP flag (default 0, PAM-59); set ONLY inside
# the sandbox snippet so a re-inject fault cannot leak into later cases.
run_pam_install() {
    local sandbox="$1" distro="$2" fail_rollback="${3:-0}" rewrite_common="${4:-0}" reinject_fp="${5:-0}"
    local sed_corrupt="${6:-0}" stat_drift="${7:-0}"
    export CROS_ENABLEMENT_PAM_SUDO_PATH CROS_ENABLEMENT_PAM_DIR
    export CROS_ENABLEMENT_PAM_SAVED_DIR="$sandbox/savedir"
    export CROS_ENABLEMENT_PAM_SELECTION_FILE="$sandbox/manifest/pam-selection"
    run_sandboxed "$sandbox" '
        # /usr/sbin is deliberately EXCLUDED: when a test removes the
        # pam-auth-update stub, `command -v` must NOT find the real tool and
        # rewrite the host /var/lib/pam/seen + debconf DB (reviewer P0).
        export PATH="$2/stub:/usr/bin:/bin"
        export STUB_SED_LOG="$2/sed.log" STUB_TOOL_LOG="$2/tool.log"
        export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
        export STUB_DEBCONF_SEEN="$2/debconf/seen"
        export STUB_FAIL_ROLLBACK_PY="$4" STUB_PAM_REWRITE_COMMON="$5" STUB_PAM_REINJECT_FP="$6"
        export STUB_SED_CORRUPT="$7" STUB_STAT_DRIFT="$8"
        export STUB_STAT_DRIFT_MARK="$2/stat-drift.mark"
        source "$1/lib/pam.sh"
        DISTRO_FAMILY="$3" DISTRO_ID="$3"
        configure_pam_fingerprint
        printf "%s\n" "$?" > "$2/install.rc"
    ' "$distro" "$fail_rollback" "$rewrite_common" "$reinject_fp" "$sed_corrupt" "$stat_drift"
}

# Uninstall step: mirror _uninstall_fp_body() ordering — rollback FIRST, then
# disable_pam_fingerprint(). No sed or tool call may be injected in between.
# $3 is the per-call fault flag; see run_pam_install() for why it is scoped to
# the sandbox snippet instead of the parent environment.
# $5 is the per-call STUB_PAM_REWRITE_COMMON flag ($4 remains the hook).
run_pam_uninstall() {
    local sandbox="$1" distro="$2" fail_rollback="${3:-0}" hook="${4:-}" rewrite_common="${5:-0}"
    export CROS_ENABLEMENT_PAM_SUDO_PATH CROS_ENABLEMENT_PAM_DIR
    export CROS_ENABLEMENT_PAM_SAVED_DIR="$sandbox/savedir"
    export CROS_ENABLEMENT_PAM_SELECTION_FILE="$sandbox/manifest/pam-selection"
    run_sandboxed "$sandbox" '
        # No /usr/sbin: an absent pam-auth-update stub must resolve to
        # "not found", never to the real tool (reviewer P0).
        export PATH="$2/stub:/usr/bin:/bin"
        export STUB_SED_LOG="$2/sed.log" STUB_TOOL_LOG="$2/tool.log"
        export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
        export STUB_DEBCONF_SEEN="$2/debconf/seen"
        export STUB_FAIL_ROLLBACK_PY="$4" STUB_PAM_REWRITE_COMMON="$6"
        source "$1/lib/pam.sh"
        DISTRO_FAMILY="$3" DISTRO_ID="$3"
        rc=0
        rollback_component "fingerprint" || rc=$?
        printf "%s\n" "$rc" > "$2/rollback.rc"
        if [ -n "${5:-}" ]; then
            bash "$5" "$2"
        fi
        disable_pam_fingerprint
        printf "%s\n" "$?" > "$2/disable.rc"
    ' "$distro" "$fail_rollback" "$hook" "$rewrite_common"
}

# --- PAM-19: a REAL non-root caller with passwordless sudo -------------------
# The default PAM sudo stub only passes commands through, which cannot model a
# non-root user reading a root:0700 snapshot. This stub escalates with setpriv
# ONLY when the caller is unprivileged; every privileged file operation in
# lib/pam.sh therefore really runs as root, while the surrounding shell is
# genuinely uid 1000. The seam guards against touching host PAM are preserved.
_pam_nonroot_sudo_stub() {
    local s="$1"
    cat > "$s/stub/sudo" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        /etc/pam.d/*|*/etc/pam.d/*)
            printf 'STUB ESCAPE: sudo asked to touch host PAM: %s\n' "$_a" >&2
            exit 99
            ;;
    esac
done
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    exec "$@"
fi
# setpriv cannot re-gain uid 0 after dropping it (capabilities are lost), so
# use a tiny setuid-root exec helper: that is exactly how real passwordless
# sudo escalates.
exec "${PAM_NONROOT_SUID:?PAM non-root sudo model missing}" "$@"
EOF
    chmod +x "$s/stub/sudo"
}

# Prepare a sandbox so uid 1000 can traverse it and write the rc/log files,
# while the manifest directory remains root-owned 0755 (lock gate requirement).
_pam_nonroot_prepare() {
    local s="$1" helper_dir
    _pam_nonroot_sudo_stub "$s"
    # /tmp is commonly mounted nosuid, which would silently ignore the setuid
    # bit. /var/tmp is on the root filesystem in CI and locally.
    helper_dir="/var/tmp/rollback-test-pam-suid-$LOCK_TEST_RUN_TAG"
    sudo install -d -m 755 -- "$helper_dir"
    PAM_NONROOT_SUID="$helper_dir/suid-exec"
    export PAM_NONROOT_SUID
    cat > "$helper_dir/suid-exec.c" << 'EOF'
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) return 127;
    if (setgid(0) != 0) return 126;
    if (setuid(0) != 0) return 125;
    execvp(argv[1], &argv[1]);
    return 127;
}
EOF
    gcc -O2 -o "$PAM_NONROOT_SUID" "$helper_dir/suid-exec.c" || {
        fail "PAM-19: could not build the setuid-root sudo model (gcc required)"
        return 1
    }
    chown 0:0 "$PAM_NONROOT_SUID"
    chmod 4755 "$PAM_NONROOT_SUID"
    mkdir -p "$s/userout"
    # The sandbox root is an ANCESTOR of the manifest dir: making it group/
    # other-writable would trip manifest_lock's root-controlled ancestor gate.
    # 0755 gives uid 1000 traverse only; writable state lives in userout/.
    chmod 0755 "$s"
    chmod 0777 "$s/userout"
    : > "$s/log.txt"
    chmod 0666 "$s/log.txt" "$s/tool.log" "$s/sed.log"
}

_pam_nonroot_script() {
    local s="$1" mode="$2"
    if [ "$mode" = install ]; then
        cat > "$s/user-install.sh" << 'EOF'
#!/usr/bin/env bash
export PATH="$1/stub:/usr/bin:/bin"
export STUB_SED_LOG="$1/sed.log" STUB_TOOL_LOG="$1/tool.log"
export STUB_DEBCONF_PROFILES="$1/debconf/profiles"
export STUB_DEBCONF_SEEN="$1/debconf/seen"
# PAM_NONROOT_SUID is inherited from the parent (set by _pam_nonroot_prepare).
source "$2/lib/pam.sh"
DISTRO_FAMILY="$3" DISTRO_ID="$3"
configure_pam_fingerprint
printf '%s\n' "$?" > "$1/userout/install.rc"
EOF
        chmod 0755 "$s/user-install.sh"
    else
        cat > "$s/user-uninstall.sh" << 'EOF'
#!/usr/bin/env bash
export PATH="$1/stub:/usr/bin:/bin"
export STUB_SED_LOG="$1/sed.log" STUB_TOOL_LOG="$1/tool.log"
export STUB_DEBCONF_PROFILES="$1/debconf/profiles"
export STUB_DEBCONF_SEEN="$1/debconf/seen"
# PAM_NONROOT_SUID is inherited from the parent (set by _pam_nonroot_prepare).
source "$2/lib/pam.sh"
DISTRO_FAMILY="$3" DISTRO_ID="$3"
rc=0
rollback_component "fingerprint" || rc=$?
printf '%s\n' "$rc" > "$1/userout/rollback.rc"
disable_pam_fingerprint
printf '%s\n' "$?" > "$1/userout/disable.rc"
EOF
        chmod 0755 "$s/user-uninstall.sh"
    fi
}

run_pam_install_nonroot() {
    local sandbox="$1" distro="$2"
    export CROS_ENABLEMENT_PAM_SUDO_PATH CROS_ENABLEMENT_PAM_DIR
    export CROS_ENABLEMENT_PAM_SAVED_DIR="$sandbox/savedir"
    export CROS_ENABLEMENT_PAM_SELECTION_FILE="$sandbox/manifest/pam-selection"
    run_sandboxed "$sandbox" '
        setpriv --reuid=1000 --regid=1000 --clear-groups \
            bash "$2/user-install.sh" "$2" "$1" "$3"
    ' "$distro"
}

run_pam_uninstall_nonroot() {
    local sandbox="$1" distro="$2"
    export CROS_ENABLEMENT_PAM_SUDO_PATH CROS_ENABLEMENT_PAM_DIR
    export CROS_ENABLEMENT_PAM_SAVED_DIR="$sandbox/savedir"
    export CROS_ENABLEMENT_PAM_SELECTION_FILE="$sandbox/manifest/pam-selection"
    run_sandboxed "$sandbox" '
        setpriv --reuid=1000 --regid=1000 --clear-groups \
            bash "$2/user-uninstall.sh" "$2" "$1" "$3"
    ' "$distro"
}

# PAM-1: original sudo PAM already has the EXACT project line. Install skips
# backup; uninstall must leave every byte untouched (no sed, no record).
test_pam_1_preexisting_exact_line_survives() {
    local s before
    s="$(setup_pam_sandbox exact-line)"
    pam_write_initial_files "$s" exact none
    before="$(file_hex "$s/pam/sudo")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian

    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" "PAM-1: install rc 0"
    assert_eq "0" "$(cat "$s/rollback.rc" 2> /dev/null || echo MISSING)" "PAM-1: rollback rc 0"
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" "PAM-1: disable rc 0"
    assert_eq "$before" "$(file_hex "$s/pam/sudo")" "PAM-1: original sudo PAM bytes identical"
    assert_eq "0" "$(pam_record_count "$s")" "PAM-1: no manifest record was created"
    assert_eq "" "$(cat "$s/sed.log")" "PAM-1: uninstall ran no sed"
    assert_not_contains "Manifest still records" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-1: no stale-record warning"
}

# PAM-2: original sudo PAM has OTHER fprintd/rust_fp lines. Install backs up
# and rewrites (2 sed calls); rollback restores the original bytes, and the
# post-rollback sed must NOT delete them again.
test_pam_2_preexisting_other_fp_lines_survive() {
    local s before sed_after_install
    s="$(setup_pam_sandbox other-lines)"
    pam_write_initial_files "$s" other none
    before="$(file_hex "$s/pam/sudo")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    sed_after_install="$(wc -l < "$s/sed.log")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian

    assert_eq "0" "$(cat "$s/rollback.rc" 2> /dev/null || echo MISSING)" "PAM-2: rollback rc 0"
    assert_eq "2" "$sed_after_install" "PAM-2: install used exactly two sed calls"
    assert_eq "$sed_after_install" "$(wc -l < "$s/sed.log")" "PAM-2: uninstall added no sed call"
    assert_eq "$before" "$(file_hex "$s/pam/sudo")" "PAM-2: original sudo PAM bytes identical"
    assert_eq "0" "$(pam_record_count "$s")" "PAM-2: manifest record consumed"
}

# PAM-3: original sudo PAM has no fp line at all. Install adds one; rollback
# must restore the original file byte-for-byte with no extra sed.
test_pam_3_no_fp_line_roundtrip() {
    local s before sed_after_install
    s="$(setup_pam_sandbox no-fp-line)"
    pam_write_initial_files "$s" none none
    before="$(file_hex "$s/pam/sudo")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    sed_after_install="$(wc -l < "$s/sed.log")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian

    assert_eq "0" "$(cat "$s/rollback.rc" 2> /dev/null || echo MISSING)" "PAM-3: rollback rc 0"
    assert_eq "$before" "$(file_hex "$s/pam/sudo")" "PAM-3: original sudo PAM bytes identical"
    assert_eq "0" "$(pam_record_count "$s")" "PAM-3: manifest record consumed"
    assert_eq "$sed_after_install" "$(wc -l < "$s/sed.log")" "PAM-3: uninstall added no sed call"
}

# PAM-4: rollback FAILS. The record must stay, the file must be left exactly as
# the failed rollback left it (uninstall adds no mutation), and the user must
# be warned that the manifest still records the file.
test_pam_4_failed_rollback_keeps_record_and_warns() {
    local s after_install sed_after_install
    s="$(setup_pam_sandbox rollback-fail)"
    pam_write_initial_files "$s" none none

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    after_install="$(file_hex "$s/pam/sudo")"
    sed_after_install="$(wc -l < "$s/sed.log")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian 1

    assert_eq "1" "$(cat "$s/rollback.rc" 2> /dev/null || echo MISSING)" "PAM-4: rollback rc 1"
    # Re-review #15 finding #3: a surviving record now propagates as a real
    # failure, not a warning-only rc 0.
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" "PAM-4: disable rc 1"
    assert_eq "1" "$(pam_record_count "$s")" "PAM-4: manifest record retained"
    assert_eq "$after_install" "$(file_hex "$s/pam/sudo")" \
        "PAM-4: uninstall did not change the file after failed rollback"
    assert_contains "Manifest still records" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-4: stale record warning logged"
    assert_eq "$sed_after_install" "$(wc -l < "$s/sed.log")" "PAM-4: uninstall added no sed call"
}

# PAM-5: an unsupported distro never claims or edits the sudo PAM file.
test_pam_5_unsupported_distro_no_sed() {
    local s before
    s="$(setup_pam_sandbox unsupported-distro)"
    pam_write_initial_files "$s" exact none
    before="$(file_hex "$s/pam/sudo")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" plan9
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" plan9

    assert_eq "$before" "$(file_hex "$s/pam/sudo")" "PAM-5: sudo PAM bytes unchanged"
    assert_eq "0" "$(pam_record_count "$s")" "PAM-5: no manifest record"
    assert_eq "" "$(cat "$s/sed.log")" "PAM-5: no sed call in either direction"
}

# PAM-6: DRY_RUN must create no record, no lock file and no sed side effect.
test_pam_6_dry_run_no_side_effects() {
    local s before
    s="$(setup_pam_sandbox dry-run)"
    pam_write_initial_files "$s" exact none
    before="$(file_hex "$s/pam/sudo")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        DRY_RUN=1 run_pam_install "$s" debian
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        DRY_RUN=1 run_pam_uninstall "$s" debian

    assert_eq "$before" "$(file_hex "$s/pam/sudo")" "PAM-6: sudo PAM bytes unchanged"
    assert_eq "0" "$(pam_record_count "$s")" "PAM-6: no manifest record"
    assert_eq "" "$(cat "$s/sed.log")" "PAM-6: no sed call"
    if [ -e "$s/manifest/.install-manifest.lock" ]; then
        fail "PAM-6: no lock file may be created in dry-run"
    else
        ok
    fi
}

# PAM-7: static source guard. The disable function body must contain no sed at
# all, and the stubs must refuse a host PAM path if a seam is misconfigured.
test_pam_7_disable_body_has_no_sed() {
    local s body install_body converge_body restore_body rc=0
    body="$(sed -n '/^disable_pam_fingerprint()/,/^}/p' "$REPO_ROOT/lib/pam.sh")"
    assert_not_contains "pam_fprintd.so/d" "$body" \
        "PAM-7: disable_pam_fingerprint has no unconditional pam_fprintd sed"
    assert_not_contains "sed -i" "$body" "PAM-7: disable_pam_fingerprint has no sed call"
    assert_contains "_pam_sudo_post_rollback_check" "$body" \
        "PAM-7: post-rollback check is called inside disable_pam_fingerprint"

    # Re-review #12 #2 + #13 #1: the install body must use the direct strip
    # helper and MAY call `pam-auth-update --package` to converge state, but
    # must NEVER call `--remove` (which deletes the debconf selection).
    install_body="$(sed -n '/^_configure_pam_fingerprint_body()/,/^}/p' "$REPO_ROOT/lib/pam.sh")"
    assert_not_contains "pam-auth-update --remove" "$install_body" \
        "PAM-7: install body never calls pam-auth-update --remove"
    assert_contains "_pam_converge_profiles" "$install_body" \
        "PAM-7: install body converges state after the strip"
    converge_body="$(sed -n '/^_pam_converge_profiles()/,/^}/p' "$REPO_ROOT/lib/pam.sh")"
    assert_contains "pam-auth-update --package" "$converge_body" \
        "PAM-7: convergence helper uses --package (never --remove)"
    assert_contains "_pam_strip_fprintd_from_common_files" "$install_body" \
        "PAM-7: install body uses the direct strip helper"
    assert_contains "_pam_snapshot_selection" "$install_body" \
        "PAM-7: install body snapshots the selection before mutating files"

    # Re-review #15: the post-tool common-state restore must never sed.
    restore_body="$(sed -n '/^_pam_restore_common_state_from_snapshot()/,/^}/p' "$REPO_ROOT/lib/pam.sh")"
    assert_not_contains "sed -i" "$restore_body" \
        "PAM-7: final common-state restore uses no sed"

    s="$(setup_pam_sandbox seam-guard)"
    PATH="$s/stub:$PATH" STUB_SED_LOG="$s/sed.log" \
        sed -n 'p' /etc/pam.d/sudo > /dev/null 2>&1 || rc=$?
    assert_eq "99" "$rc" "PAM-7: sed stub refuses a host PAM path (seam guard)"
}

# PAM-8 (Tier 2): every existing Debian common-* file is backed up (because
# --package can rewrite all of them), fp lines are stripped by a DIRECT sed,
# the tool is called once to converge state, and rollback restores all bytes.
test_pam_8_all_common_files_tracked_and_converged() {
    local s stack_before sed_after_install
    s="$(setup_pam_sandbox common-auth)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, fprintd'
    stack_before="$(pam_stack_fingerprint "$s")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    sed_after_install="$(wc -l < "$s/sed.log")"

    assert_eq "1" "$(grep -cF -- 'pam-auth-update --package' "$s/tool.log")" \
        "PAM-8: exactly one --package convergence call on install"
    assert_eq "0" "$(grep -cF -- 'pam-auth-update --remove' "$s/tool.log")" \
        "PAM-8: --remove is never called"
    assert_eq "1" "$(grep -cE '^-i -e [0-9]+(,[0-9]+)?d ' "$s/sed.log")" \
        "PAM-8: one direct, line-numbered fp strip on common-auth"
    assert_eq "3" "$sed_after_install" \
        "PAM-8: three install sed calls (1 common strip + 2 sudo)"
    assert_eq "6" "$(pam_record_count "$s")" \
        "PAM-8: sudo + all five common-* files tracked for rollback"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian

    assert_eq "0" "$(cat "$s/rollback.rc" 2> /dev/null || echo MISSING)" "PAM-8: rollback rc 0"
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" "PAM-8: disable rc 0"
    assert_eq "$stack_before" "$(pam_stack_fingerprint "$s")" \
        "PAM-8: sudo/common-*/savedir bytes restored by rollback and selection restore"
    assert_eq "2" "$(grep -cF -- 'pam-auth-update --package' "$s/tool.log")" \
        "PAM-8: uninstall converged once with --package"
    assert_contains "debconf-set-selections" "$(cat "$s/tool.log")" \
        "PAM-8: uninstall wrote the snapshotted selection back"
    assert_eq "$sed_after_install" "$(wc -l < "$s/sed.log")" \
        "PAM-8: uninstall added no sed call"
    assert_eq "0" "$(pam_record_count "$s")" "PAM-8: manifest records consumed"
}

# PAM-9 (fault-injection isolation regression): the CI bug was PAM-4's
# STUB_FAIL_ROLLBACK_PY=1 leaking through the parent shell into PAM-8. The flag
# is now a per-call argument exported INSIDE the sandbox, so a later fail=0
# uninstall rolls back cleanly even when the parent environment holds a 1.
# Two independent sandboxes in one shell mirror the PAM-4 -> PAM-8 sequence.
test_pam_9_fault_injection_does_not_leak_to_later_uninstall() {
    local s_fail s_ok sudo_before common_before saved_flag had_flag
    s_fail="$(setup_pam_sandbox fault-first)"
    pam_write_initial_files "$s_fail" none fp
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s_fail/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s_fail/pam" \
        run_pam_install "$s_fail" debian
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s_fail/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s_fail/pam" \
        run_pam_uninstall "$s_fail" debian 1
    assert_eq "1" "$(cat "$s_fail/rollback.rc" 2> /dev/null || echo MISSING)" \
        "PAM-9: first uninstall's injected rollback failure rc 1"

    s_ok="$(setup_pam_sandbox fault-cleared)"
    pam_write_initial_files "$s_ok" none fp
    sudo_before="$(file_hex "$s_ok/pam/sudo")"
    common_before="$(file_hex "$s_ok/pam/common-auth")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s_ok/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s_ok/pam" \
        run_pam_install "$s_ok" debian

    # Deliberately poison the PARENT environment. The per-call default (0) must
    # override it inside the sandbox; the inherited value must never win.
    had_flag="${STUB_FAIL_ROLLBACK_PY+x}"
    saved_flag="${STUB_FAIL_ROLLBACK_PY-}"
    export STUB_FAIL_ROLLBACK_PY=1
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s_ok/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s_ok/pam" \
        run_pam_uninstall "$s_ok" debian
    if [ -n "$had_flag" ]; then
        export STUB_FAIL_ROLLBACK_PY="$saved_flag"
    else
        unset STUB_FAIL_ROLLBACK_PY
    fi

    assert_eq "0" "$(cat "$s_ok/rollback.rc" 2> /dev/null || echo MISSING)" \
        "PAM-9: second uninstall rollback rc 0 (flag not inherited)"
    assert_eq "$sudo_before" "$(file_hex "$s_ok/pam/sudo")" \
        "PAM-9: sudo PAM bytes restored by second uninstall"
    assert_eq "$common_before" "$(file_hex "$s_ok/pam/common-auth")" \
        "PAM-9: common-auth bytes restored by second uninstall"
    assert_eq "0" "$(pam_record_count "$s_ok")" \
        "PAM-9: manifest records consumed by second uninstall"
}

# PAM-10 (STATE RESTORATION, review12 #2): after Debian install -> uninstall,
# BOTH the common-* bytes AND the debconf profile selection must match the
# original, so re-running pam-auth-update regenerates the ORIGINAL stack.
test_pam_10_debian_selection_and_stack_restored() {
    local s sudo_before common_before sel_before generated_before pristine stack_before
    s="$(setup_pam_sandbox debian-state)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    sudo_before="$(file_hex "$s/pam/sudo")"
    common_before="$(file_hex "$s/pam/common-auth")"
    sel_before="$(pam_selection "$s")"
    stack_before="$(pam_stack_fingerprint "$s")"

    # What the tool WOULD generate from the original selection, captured before
    # anything is touched. --regenerate writes only common-auth in the sandbox.
    pristine="$s/common.pristine"
    cp "$s/pam/common-auth" "$pristine"
    PATH="$s/stub:$PATH" STUB_TOOL_LOG="$s/regen.log" \
        STUB_DEBCONF_PROFILES="$s/debconf/profiles" \
        CROS_ENABLEMENT_PAM_DIR="$s/pam" "$s/stub/pam-auth-update" --regenerate
    generated_before="$(file_hex "$s/pam/common-auth")"
    cp "$pristine" "$s/pam/common-auth"
    : > "$s/tool.log"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_not_contains 'fprintd' "$(pam_selection "$s")" \
        "PAM-10: install converged the selection to no-fprintd"
    assert_eq "1" "$(grep -cF -- 'pam-auth-update --package' "$s/tool.log")" \
        "PAM-10: install called --package once"
    assert_not_contains 'pam_fprintd.so' "$(cat "$s/pam/common-auth")" \
        "PAM-10: fp line removed from common-auth after install"
    assert_eq "6" "$(pam_record_count "$s")" "PAM-10: sudo + all common-* tracked"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/rollback.rc" 2> /dev/null || echo MISSING)" "PAM-10: rollback rc 0"
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" "PAM-10: disable rc 0"
    assert_eq "$common_before" "$(file_hex "$s/pam/common-auth")" \
        "PAM-10: common-auth bytes restored"
    assert_eq "$sudo_before" "$(file_hex "$s/pam/sudo")" "PAM-10: sudo bytes restored"
    assert_eq "$stack_before" "$(pam_stack_fingerprint "$s")" \
        "PAM-10: sudo/common-*/savedir bytes restored"
    assert_eq "$sel_before" "$(pam_selection "$s")" \
        "PAM-10: selection preserved after uninstall"
    assert_contains 'pam-auth-update --package' "$(cat "$s/tool.log")" \
        "PAM-10: uninstall converged with --package"
    assert_contains 'debconf-set-selections' "$(cat "$s/tool.log")" \
        "PAM-10: uninstall wrote the snapshotted selection back"
    assert_eq "0" "$(pam_record_count "$s")" "PAM-10: all records consumed"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-10: sidecar consumed after successful restore"

    # THE key regression assertion: re-run the tool from the preserved selection.
    PATH="$s/stub:$PATH" STUB_TOOL_LOG="$s/regen.log" \
        STUB_DEBCONF_PROFILES="$s/debconf/profiles" \
        CROS_ENABLEMENT_PAM_DIR="$s/pam" "$s/stub/pam-auth-update" --regenerate
    assert_eq "$generated_before" "$(file_hex "$s/pam/common-auth")" \
        "PAM-10: re-running pam-auth-update yields the ORIGINAL stack"
}

# PAM-11: an EXPLICIT pre-existing fprintd selection must survive untouched
# (exact string, no normalisation). With no saved profiles to reconcile, the
# install --package is a no-op and the uninstall's direct debconf write restores
# exactly the original string; --remove is never used.
test_pam_11_explicit_selection_survives() {
    local s sel_before
    s="$(setup_pam_sandbox explicit-selection)"
    pam_write_initial_files "$s" none fp
    pam_write_selection "$s" 'unix, fprintd, systemd'
    sel_before="$(pam_selection "$s")"
    assert_contains 'fprintd' "$sel_before" "PAM-11: initial selection contains fprintd"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "$sel_before" "$(pam_selection "$s")" \
        "PAM-11: exact explicit selection string preserved"
    assert_eq "0" "$(grep -cF -- 'pam-auth-update --remove' "$s/tool.log")" \
        "PAM-11: --remove is never called"
    assert_contains 'debconf-set-selections' "$(cat "$s/tool.log")" \
        "PAM-11: uninstall restored the explicit selection from the snapshot"
    assert_eq "0" "$(cat "$s/rollback.rc" 2> /dev/null || echo MISSING)" "PAM-11: rollback rc 0"
}

# PAM-12: STUB FIDELITY CONTROL — prove the harness really models the bug from
# review12 #2. Calling the OLD tool path MUST mutate the selection; otherwise
# PAM-10/11 would be vacuous assertions.
test_pam_12_stub_removes_selection_control() {
    local s sel_before
    s="$(setup_pam_sandbox fidelity-control)"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    sel_before="$(pam_selection "$s")"
    assert_contains 'fprintd' "$sel_before" "PAM-12: initial selection contains fprintd"

    PATH="$s/stub:$PATH" STUB_TOOL_LOG="$s/tool.log" \
        STUB_DEBCONF_PROFILES="$s/debconf/profiles" \
        CROS_ENABLEMENT_PAM_DIR="$s/pam" "$s/stub/pam-auth-update" --remove fprintd
    assert_contains 'pam-auth-update --remove fprintd' "$(cat "$s/tool.log")" \
        "PAM-12: old tool call is logged"
    assert_not_contains 'fprintd' "$(pam_selection "$s")" \
        "PAM-12: stub --remove really drops fprintd from selection (fidelity)"
    assert_eq "0" "$(printf '%s' "$(pam_selection "$s")" | grep -cF fprintd || true)" \
        "PAM-12: selection actually changed (control is sensitive)"
}

# Invoke the upgraded --package stub directly with the same seams the installer
# uses. $1=sandbox $2=tool log $3..=tool args.
pam_tool() {
    local s="$1" log="$2"
    shift 2
    PATH="$s/stub:$PATH" STUB_TOOL_LOG="$log" \
        STUB_DEBCONF_PROFILES="$s/debconf/profiles" \
        CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        CROS_ENABLEMENT_PAM_SAVED_DIR="$s/savedir" \
        "$s/stub/pam-auth-update" "$@"
}

# PAM-13 (stub fidelity, re-review #13 #1): --package must DERIVE the enabled
# selection from common-* + savedir, not copy the old debconf value. Removing
# the fp line must make the tool drop fprintd — otherwise every later test would
# be a vacuous self-proof.
test_pam_13_package_tool_derives_selection() {
    local s sel_before
    s="$(setup_pam_sandbox package-fidelity)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    sel_before="$(pam_selection "$s")"
    assert_contains 'fprintd' "$sel_before" "PAM-13: initial selection contains fprintd"

    pam_tool "$s" "$s/tool.log" --package
    assert_eq "$sel_before" "$(pam_selection "$s")" \
        "PAM-13: --package keeps fprintd while common-*/savedir still have it"
    assert_contains 'pam_fprintd.so' "$(cat "$s/pam/common-auth")" \
        "PAM-13: stub did not rewrite an already-converged common-auth"
    assert_contains 'Module: fprintd' "$(cat "$s/savedir/auth")" \
        "PAM-13: stub did not rewrite an already-converged savedir"

    # Simulate the installer's direct line removal, then let the tool reconcile.
    /usr/bin/sed -i '/pam_fprintd\.so/d' "$s/pam/common-auth"
    pam_tool "$s" "$s/tool.log" --package
    assert_not_contains 'fprintd' "$(pam_selection "$s")" \
        "PAM-13: --package drops fprintd after its line is removed (real derivation)"
    assert_not_contains 'Module: fprintd' "$(cat "$s/savedir/auth")" \
        "PAM-13: savedir converged to the no-fprintd state too"
    assert_eq "2" "$(grep -cF -- 'pam-auth-update --package' "$s/tool.log")" \
        "PAM-13: both --package calls logged"
}

# PAM-14 (the exact re-review #13 #1 timeline): install -> EXTERNAL
# --package -> uninstall must restore selection, common-*, /var/lib/pam and sudo
# byte-for-byte. The external call must be a no-op after our own convergence.
test_pam_14_install_external_package_uninstall() {
    local s before after_install
    s="$(setup_pam_sandbox package-roundtrip)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    before="$(pam_stack_fingerprint "$s")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-14: install rc 0"
    assert_not_contains 'fprintd' "$(pam_selection "$s")" \
        "PAM-14: install converged the selection to no-fprintd"
    assert_not_contains 'pam_fprintd.so' "$(cat "$s/pam/common-auth")" \
        "PAM-14: fp line gone from common-auth after install"
    assert_not_contains 'Module: fprintd' "$(cat "$s/savedir/auth")" \
        "PAM-14: saved module snapshot converged after install"
    [ -f "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-14: first-wins selection sidecar exists"
    [ -f "$s/manifest/pam-selection.saved/auth" ] \
        && ok || fail "PAM-14: saved profile files snapshotted in the sidecar"
    after_install="$(pam_stack_fingerprint "$s")"

    pam_tool "$s" "$s/tool.log" --package
    assert_eq "$after_install" "$(pam_stack_fingerprint "$s")" \
        "PAM-14: an external --package after our convergence is a true no-op"
    assert_eq "2" "$(grep -cF -- 'pam-auth-update --package' "$s/tool.log")" \
        "PAM-14: install call + external call both logged"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/rollback.rc" 2> /dev/null || echo MISSING)" \
        "PAM-14: rollback rc 0"
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-14: disable rc 0"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-14: selection + sudo + all common-*/savedir bytes restored exactly"
    assert_contains 'debconf-set-selections' "$(cat "$s/tool.log")" \
        "PAM-14: uninstall wrote the snapshotted selection back"
    assert_eq "3" "$(grep -cF -- 'pam-auth-update --package' "$s/tool.log")" \
        "PAM-14: uninstall converged once more"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-14: sidecar consumed after successful restore"
}

# PAM-15: two --package invocations in the same install window (package upgrade
# + admin rerun). The second must be a byte-for-byte no-op and uninstall must
# still restore everything.
test_pam_15_repeated_package_calls_are_noop() {
    local s before d1 d2
    s="$(setup_pam_sandbox package-repeat)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    before="$(pam_stack_fingerprint "$s")"
    : > "$s/pkg-state"

    STUB_PAM_STATE_DIGEST="$s/pkg-state" STUB_PAM_PACKAGE_REPEAT=2 \
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "2" "$(wc -l < "$s/pkg-state")" \
        "PAM-15: the tool's reconcile body ran twice"
    d1="$(sed -n '1p' "$s/pkg-state")"
    d2="$(sed -n '2p' "$s/pkg-state")"
    assert_eq "$d1" "$d2" "PAM-15: the second --package was a no-op"
    assert_eq "2" "$(grep -cF -- 'pam-auth-update --package' "$s/tool.log")" \
        "PAM-15: both in-window calls logged"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-15: disable rc 0"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-15: full stack restored after repeated in-window tool calls"
}

# PAM-16: missing tool and a failing tool must not block install; the snapshot
# survives and uninstall restores the selection directly from debconf.
test_pam_16_missing_or_failing_tool_does_not_block() {
    local s_no s_fail before
    # (a) pam-auth-update absent from PATH
    s_no="$(setup_pam_sandbox package-missing)"
    pam_write_full_stack "$s_no"
    pam_write_selection "$s_no" 'unix, systemd, fprintd'
    before="$(pam_stack_fingerprint "$s_no")"
    mv "$s_no/stub/pam-auth-update" "$s_no/stub/pam-auth-update.off"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s_no/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s_no/pam" \
        run_pam_install "$s_no" debian
    assert_eq "0" "$(cat "$s_no/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-16: install rc 0 without the tool"
    assert_contains 'pam_fprintd.so' "$(cat "$s_no/pam/sudo")" \
        "PAM-16: sudo fingerprint line still installed without the tool"
    [ -f "$s_no/manifest/pam-selection" ] \
        && ok || fail "PAM-16: snapshot kept when the tool is missing"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s_no/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s_no/pam" \
        run_pam_uninstall "$s_no" debian
    assert_eq "0" "$(cat "$s_no/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-16: disable rc 0 without the tool"
    assert_eq "$before" "$(pam_stack_fingerprint "$s_no")" \
        "PAM-16: all bytes and selection restored without the tool"

    # (b) tool present but failing
    s_fail="$(setup_pam_sandbox package-failing)"
    pam_write_full_stack "$s_fail"
    pam_write_selection "$s_fail" 'unix, systemd, fprintd'
    before="$(pam_stack_fingerprint "$s_fail")"
    cat > "$s_fail/stub/pam-auth-update" << 'EOF'
#!/usr/bin/env bash
printf 'pam-auth-update %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
exit 1
EOF
    chmod +x "$s_fail/stub/pam-auth-update"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s_fail/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s_fail/pam" \
        run_pam_install "$s_fail" debian
    assert_eq "0" "$(cat "$s_fail/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-16: install rc 0 when the tool fails"
    [ -f "$s_fail/manifest/pam-selection" ] \
        && ok || fail "PAM-16: snapshot kept when the tool fails"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s_fail/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s_fail/pam" \
        run_pam_uninstall "$s_fail" debian
    assert_eq "0" "$(cat "$s_fail/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-16: disable rc 0 when the tool fails"
    assert_eq "$before" "$(pam_stack_fingerprint "$s_fail")" \
        "PAM-16: all bytes and selection restored despite a failing tool"
}

# PAM-17: the tool cannot reconcile (simulated diff failure / local edit), but
# the direct debconf write from the snapshot still restores the original value.
test_pam_17_diff_failure_still_restores_selection() {
    local s before sel_before
    s="$(setup_pam_sandbox package-diff-fail)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    sel_before="$(pam_selection "$s")"
    before="$(pam_stack_fingerprint "$s")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    # The administrator's local edit must be applied AFTER rollbackComponent:
    # rollback restores common-auth from its backup and would erase an earlier
    # edit, making the stub's content-driven diff-fail unreachable. An env
    # switch is deliberately NOT used (reviewer P2).
    cat > "$s/admin-edit.sh" << 'EOF'
printf 'auth sufficient pam_admin_custom.so\n' >> "$1/pam/common-auth"
EOF
    chmod +x "$s/admin-edit.sh"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian 0 "$s/admin-edit.sh"
    assert_contains "local modification" "$(cat "$s/tool.log" 2> /dev/null || echo '')" \
        "PAM-17: content-driven diff-fail really fired (not an env shortcut)"
    # Re-review #15: the admin edit is EXTERNAL state. The new final common-*
    # verification must not silently overwrite it: fail closed and retain the
    # three snapshots for manual recovery instead of claiming success.
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-17: disable rc 1 on an admin's semantic edit"
    [ -e "$s/manifest/pam-selection" ] && [ -e "$s/manifest/pam-selection.saved" ] \
        && [ -e "$s/manifest/pam-selection.common" ] \
        && ok || fail "PAM-17: all three snapshots retained after fail-closed restore"
    assert_eq "$sel_before" "$(pam_selection "$s")" \
        "PAM-17: selection was restored before the common-state guard fired"
    assert_contains "External content change detected" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-17: explicit reason for refusing to overwrite the admin edit"
    assert_contains "keeping $s/manifest/pam-selection" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-17: retry data explicitly retained"
    # Saved profiles + selection were restored before the common-state guard
    # fired, so removing ONLY the admin edit yields the original stack bytes.
    /usr/bin/sed -i '/pam_admin_custom\.so/d' "$s/pam/common-auth"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-17: rollback restored every managed byte (minus the admin edit)"
}

# PAM-18: first-wins snapshot. An external selection change followed by a
# reinstall must NOT replace the original snapshot used at uninstall.
test_pam_18_first_wins_snapshot() {
    local s before first
    s="$(setup_pam_sandbox package-first-wins)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    before="$(pam_stack_fingerprint "$s")"
    first="$(pam_selection "$s")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    pam_write_selection "$s" 'unix, systemd' # admin changes selection externally
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "$first" "$(sed '/^#/d' "$s/manifest/pam-selection" | tail -n 1)" \
        "PAM-18: second install kept the FIRST snapshot"
    assert_eq 'unix, systemd' "$(pam_selection "$s")" \
        "PAM-18: current selection reflects the external change"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-18: disable rc 0"
    assert_eq "$first" "$(pam_selection "$s")" \
        "PAM-18: uninstall restored the FIRST snapshot, not the later value"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-18: all bytes restored"
}

# PAM-19 (reviewer P0/P1): a REAL uid-1000 caller with passwordless sudo must
# be able to consume the root:0700 saved-dir snapshot AND the selection
# sidecar. A passthrough-sudo, all-root E2E cannot see either permission bug.
test_pam_19_nonroot_uninstall_reads_snapshots() {
    local s before saved_auth_before sed_after_install sidecar_mode saved_mode
    s="$(setup_pam_sandbox nonroot-roundtrip)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    before="$(pam_stack_fingerprint "$s")"
    saved_auth_before="$(file_hex "$s/savedir/auth")"

    _pam_nonroot_prepare "$s"
    _pam_nonroot_script "$s" install
    _pam_nonroot_script "$s" uninstall

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install_nonroot "$s" debian
    assert_eq "0" "$(cat "$s/userout/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-19: non-root install rc 0"
    sed_after_install="$(wc -l < "$s/sed.log")"

    # Prove the scenario really is privileged-root state read by a non-root
    # caller: the sidecar is world-readable but the saved snapshot is 0700.
    sidecar_mode="$(stat -c '%u:%a' -- "$s/manifest/pam-selection" 2> /dev/null || echo MISSING)"
    saved_mode="$(stat -c '%u:%a' -- "$s/manifest/pam-selection.saved" 2> /dev/null || echo MISSING)"
    assert_eq "0:644" "$sidecar_mode" "PAM-19: sidecar is root-owned 0644 (readable by uid 1000)"
    assert_eq "0:700" "$saved_mode" "PAM-19: saved snapshot is root-only 0700"
    assert_eq "$saved_auth_before" "$(file_hex "$s/manifest/pam-selection.saved/auth" 2> /dev/null || echo MISSING)" \
        "PAM-19: root-only snapshot holds the ORIGINAL savedir bytes"
    assert_not_contains 'fprintd' "$(pam_selection "$s")" \
        "PAM-19: install converged the live selection"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall_nonroot "$s" debian
    assert_eq "0" "$(cat "$s/userout/rollback.rc" 2> /dev/null || echo MISSING)" \
        "PAM-19: non-root rollback rc 0"
    assert_eq "0" "$(cat "$s/userout/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-19: non-root disable rc 0"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-19: sudo/common-*/savedir/selection restored from the root-only snapshot"
    assert_contains 'fprintd' "$(pam_selection "$s")" \
        "PAM-19: selection restored for the non-root caller"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-19: non-root uninstall consumed the sidecar"
    [ ! -e "$s/manifest/pam-selection.saved" ] \
        && ok || fail "PAM-19: non-root uninstall consumed the saved snapshot"
    assert_eq "$sed_after_install" "$(wc -l < "$s/sed.log")" \
        "PAM-19: non-root uninstall added no sed call"
}

# PAM-20 (reviewer P2): the real tool persists the multiselect in canonical
# "a, b, c" order. An administrator's raw order/spacing may differ, so exact
# string inequality must NOT keep the sidecar forever — but a different SET
# must still fail closed.
test_pam_20_canonicalized_selection_consumes_sidecar() {
    local s before canonical
    s="$(setup_pam_sandbox canonicalized-selection)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    before="$(pam_files_fingerprint "$s")"

    # Model the tool's canonical persistence: sort the items on every write.
    cat > "$s/stub/debconf-set-selections" << 'EOF'
#!/usr/bin/env bash
printf 'debconf-set-selections %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
_in="$(cat)"
case "$_in" in
    libpam-runtime\ libpam-runtime/profiles\ multiselect*)
        _val="${_in#libpam-runtime libpam-runtime/profiles multiselect}"
        _val="${_val#"${_val%%[![:space:]]*}"}"
        _val="$(printf '%s\n' "$_val" | tr ',' '\n' \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF' | sort \
            | awk 'BEGIN { out="" } { if (NR > 1) out = out ", "; out = out $0 } END { print out }')"
        ;;
    *) _val="$_in" ;;
esac
printf '%s\n' "$_val" > "${STUB_DEBCONF_PROFILES:?PAM debconf seam missing}"
EOF
    chmod +x "$s/stub/debconf-set-selections"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian

    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-20: disable rc 0 with a canonicalized selection"
    canonical="$(pam_selection "$s")"
    assert_neq 'unix, systemd, fprintd' "$canonical" \
        "PAM-20: selection really is in a different (canonical) order"
    assert_eq 'fprintd, systemd, unix' "$canonical" \
        "PAM-20: canonical value is the same SET with different order"
    assert_eq "$before" "$(pam_files_fingerprint "$s")" \
        "PAM-20: all PAM bytes restored"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-20: sidecar consumed on a set-equal canonical value"
    assert_eq "0" "$(pam_record_count "$s")" "PAM-20: all records consumed"
}

# Fail-closed control: a genuinely different profile set must NOT consume the
# sidecar, even though both strings are valid comma-separated lists.
test_pam_21_different_selection_set_fails_closed() {
    local s
    s="$(setup_pam_sandbox different-selection-set)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    # Force the post-restore tool call to leave a DIFFERENT set in debconf.
    cat > "$s/stub/debconf-set-selections" << 'EOF'
#!/usr/bin/env bash
printf 'libpam-runtime libpam-runtime/profiles multiselect unix, systemd\n' \
    > "${STUB_DEBCONF_PROFILES:?PAM debconf seam missing}"
EOF
    chmod +x "$s/stub/debconf-set-selections"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian

    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-21: a different set is a restore failure (rc 1)"
    [ -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-21: sidecar retained for retry on a different set"
}

# ---------------------------------------------------------------------------
# Re-review P1 blocker #2: debconf seen=true/false parsing + seen reversibility.
# Every EXPECTED value below comes from the stub's RAW state files
# (pam_selection / pam_selection_seen), never from lib/pam.sh's own parser.
# ---------------------------------------------------------------------------

# PAM-22: a seen=true non-empty selection must round-trip value AND seen.
test_pam_22_seen_true_selection_roundtrip() {
    local s sel_before seen_before before
    s="$(setup_pam_sandbox seen-true-roundtrip)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    pam_write_selection_seen "$s" true
    sel_before="$(pam_selection "$s")"
    seen_before="$(pam_selection_seen "$s")"
    before="$(pam_stack_fingerprint "$s")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-22: install rc 0 with a seen=true selection"
    assert_contains '# cros-enablement: selection-seen=true' \
        "$(cat "$s/manifest/pam-selection" 2> /dev/null || echo MISSING)" \
        "PAM-22: sidecar records the seen=true metadata line"
    assert_eq "$sel_before" "$(sed '/^#/d' "$s/manifest/pam-selection" | tail -n 1)" \
        "PAM-22: sidecar stores the exact NON-EMPTY value (not an empty string)"

    # Make FSET genuinely REVERSIBLE, not merely "called". Force the raw flag
    # to false AND make restore's debconf-set-selections VALUE-ONLY: the stock
    # stub marks the question seen, which would flip it back to true BEFORE
    # FSET and turn the product's call into a no-op. Two observation wrappers
    # record the raw flag at set-selections time and immediately after FSET,
    # so the false -> true change is attributable to the product's FSET alone.
    pam_write_selection_seen "$s" false
    assert_eq "false" "$(pam_selection_seen "$s" 2> /dev/null || echo MISSING)" \
        "PAM-22: pre-uninstall raw seen baseline is false"
    pam_set_selections_value_only "$s"
    mv "$s/stub/debconf-set-selections" "$s/stub/debconf-set-selections.value-only"
    cat > "$s/stub/debconf-set-selections" << 'EOF'
#!/usr/bin/env bash
_s="${STUB_DEBCONF_PROFILES:?PAM debconf seam missing}"
_s="${_s%/debconf/profiles}"
cat "${STUB_DEBCONF_SEEN:?}" > "$_s/seen.at-set-selections" 2> /dev/null || true
exec "$0.value-only" "$@"
EOF
    mv "$s/stub/debconf-communicate" "$s/stub/debconf-communicate.real"
    cat > "$s/stub/debconf-communicate" << 'EOF'
#!/usr/bin/env bash
_cmds="$(cat)"
printf '%s\n' "$_cmds" | "$0.real" "$@"
_rc=$?
case "$_cmds" in
    FSET\ libpam-runtime/profiles\ seen\ true)
        _s="${STUB_DEBCONF_PROFILES:?PAM debconf seam missing}"
        _s="${_s%/debconf/profiles}"
        cat "${STUB_DEBCONF_SEEN:?}" > "$_s/seen.after-fset" 2> /dev/null || true
        ;;
esac
exit "$_rc"
EOF
    chmod +x "$s/stub/debconf-set-selections" "$s/stub/debconf-communicate"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/rollback.rc" 2> /dev/null || echo MISSING)" \
        "PAM-22: rollback rc 0"
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-22: disable rc 0"
    assert_eq "$sel_before" "$(pam_selection "$s")" \
        "PAM-22: value restored (independent raw-state oracle)"
    assert_eq "$seen_before" "$(pam_selection_seen "$s")" \
        "PAM-22: seen flag restored (independent raw-state oracle)"
    assert_contains 'debconf-communicate cmd: FSET libpam-runtime/profiles seen true' \
        "$(cat "$s/tool.log" 2> /dev/null || echo MISSING)" \
        "PAM-22: uninstall FSET the seen flag back to true"
    assert_eq "false" "$(cat "$s/seen.at-set-selections" 2> /dev/null || echo MISSING)" \
        "PAM-22: raw seen was STILL false at set-selections time (not pre-flipped)"
    assert_eq "true" "$(cat "$s/seen.after-fset" 2> /dev/null || echo MISSING)" \
        "PAM-22: raw seen flipped false->true immediately after the product's FSET"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-22: sudo/common-*/savedir bytes also restored"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-22: sidecar consumed after the round-trip"
}

# PAM-23: same round-trip with seen=false (the prefix the old parser accepted).
test_pam_23_seen_false_selection_roundtrip() {
    local s sel_before before show_out
    s="$(setup_pam_sandbox seen-false-roundtrip)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    pam_write_selection_seen "$s" false
    sel_before="$(pam_selection "$s")"
    before="$(pam_stack_fingerprint "$s")"

    show_out="$(run_sandboxed "$s" '
        export PATH="$2/stub:/usr/bin:/bin" STUB_TOOL_LOG="$2/tool.log"
        export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
        export STUB_DEBCONF_SEEN="$2/debconf/seen"
        "$2/stub/debconf-show" libpam-runtime
    ')"
    assert_contains '  libpam-runtime/profiles:' "$show_out" \
        "PAM-23: stub emits the seen=false two-space prefix"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_contains '# cros-enablement: selection-seen=false' \
        "$(cat "$s/manifest/pam-selection" 2> /dev/null || echo MISSING)" \
        "PAM-23: sidecar records the seen=false metadata line"
    assert_eq "$sel_before" "$(sed '/^#/d' "$s/manifest/pam-selection" | tail -n 1)" \
        "PAM-23: exact non-empty value snapshotted for seen=false"

    : > "$s/tool.log"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/rollback.rc" 2> /dev/null || echo MISSING)" \
        "PAM-23: rollback rc 0"
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-23: disable rc 0"
    assert_eq "$sel_before" "$(pam_selection "$s")" \
        "PAM-23: value restored (independent raw-state oracle)"
    assert_eq "false" "$(pam_selection_seen "$s")" \
        "PAM-23: seen restored to false after set-selections marked it true"
    assert_contains 'debconf-communicate cmd: FSET libpam-runtime/profiles seen false' \
        "$(cat "$s/tool.log" 2> /dev/null || echo MISSING)" \
        "PAM-23: uninstall FSET the seen flag back to false"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-23: sudo/common-*/savedir bytes also restored"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-23: sidecar consumed after the round-trip"
}

# Probe the product helpers directly, but compare against RAW stub state only.
pam_helper_probe() { # $1=sandbox -> read.rc/read.out/seen.rc/seen.out/snap.rc
    run_sandboxed "$1" '
        export PATH="$2/stub:/usr/bin:/bin"
        export STUB_SED_LOG="$2/sed.log" STUB_TOOL_LOG="$2/tool.log"
        export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
        export STUB_DEBCONF_SEEN="$2/debconf/seen"
        # Must override the seams exported by earlier run_pam_* calls: those
        # point at a previous sandbox, which would make the sidecar assertions
        # read a stale path instead of the path used by this probe.
        export CROS_ENABLEMENT_PAM_SUDO_PATH="$2/pam/sudo"
        export CROS_ENABLEMENT_PAM_DIR="$2/pam"
        export CROS_ENABLEMENT_PAM_SAVED_DIR="$2/savedir"
        export CROS_ENABLEMENT_PAM_SELECTION_FILE="$2/manifest/pam-selection"
        source "$1/lib/pam.sh"
        out="$(_pam_read_selection)"; rc=$?
        printf "%s\n" "$rc" > "$2/read.rc"
        printf "%s" "$out" > "$2/read.out"
        seen="$(_pam_read_selection_seen)"; rc=$?
        printf "%s\n" "$rc" > "$2/seen.rc"
        printf "%s" "$seen" > "$2/seen.out"
        _pam_snapshot_selection
        printf "%s\n" "$?" > "$2/snap.rc"
    '
}

# PAM-24: distinguish seen=true non-empty / legal empty / key absent.
test_pam_24_empty_vs_absent_vs_seen_true() {
    local s raw show_out
    # (a) seen=true + non-empty: the exact string must survive the parser.
    s="$(setup_pam_sandbox oracle-seen-true)"
    pam_write_selection "$s" 'unix, fprintd'
    pam_write_selection_seen "$s" true
    raw="$(pam_selection "$s")"
    show_out="$(run_sandboxed "$s" '
        export PATH="$2/stub:/usr/bin:/bin" STUB_TOOL_LOG="$2/tool.log"
        export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
        export STUB_DEBCONF_SEEN="$2/debconf/seen"
        "$2/stub/debconf-show" libpam-runtime
    ')"
    assert_contains '* libpam-runtime/profiles:' "$show_out" \
        "PAM-24a: seen=true uses the '* ' prefix (the old parser's blind spot)"
    pam_helper_probe "$s"
    assert_eq "0" "$(cat "$s/read.rc" 2> /dev/null || echo MISSING)" \
        "PAM-24a: read rc 0 for a non-empty selection"
    assert_eq "$raw" "$(cat "$s/read.out" 2> /dev/null || echo MISSING)" \
        "PAM-24a: parsed value equals the raw non-empty selection"
    assert_eq "true" "$(cat "$s/seen.out" 2> /dev/null || echo MISSING)" \
        "PAM-24a: seen flag read as true"
    assert_eq "0" "$(cat "$s/snap.rc" 2> /dev/null || echo MISSING)" \
        "PAM-24a: snapshot succeeds with a non-empty selection"
    assert_eq "$raw" "$(sed '/^#/d' "$s/manifest/pam-selection" | tail -n 1)" \
        "PAM-24a: sidecar kept the non-empty value"

    # (b) legal EMPTY value: rc 0 + empty stdout, and it is restorable.
    s="$(setup_pam_sandbox oracle-empty)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" ''
    pam_write_selection_seen "$s" true
    pam_helper_probe "$s"
    assert_eq "0" "$(cat "$s/read.rc" 2> /dev/null || echo MISSING)" \
        "PAM-24b: a legal empty value is a SUCCESS (rc 0)"
    assert_eq "" "$(cat "$s/read.out" 2> /dev/null || echo MISSING)" \
        "PAM-24b: legal empty value is an empty string"
    assert_eq "0" "$(cat "$s/snap.rc" 2> /dev/null || echo MISSING)" \
        "PAM-24b: snapshot succeeds for a legal empty value"
    assert_contains '# cros-enablement: selection-seen=true' \
        "$(cat "$s/manifest/pam-selection" 2> /dev/null || echo MISSING)" \
        "PAM-24b: seen metadata still snapshotted for an empty value"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-24b: uninstall rc 0 with an empty snapshot"
    assert_eq "" "$(pam_selection "$s" 2> /dev/null || echo MISSING)" \
        "PAM-24b: legal empty value restored (not skipped as 'nothing to do')"
    assert_eq "true" "$(pam_selection_seen "$s" 2> /dev/null || echo MISSING)" \
        "PAM-24b: seen restored for the empty value too"

    # (c) key ABSENT: rc 1, no snapshot, never mistaken for a legal empty.
    s="$(setup_pam_sandbox oracle-absent)"
    pam_unset_selection "$s"
    pam_helper_probe "$s"
    assert_eq "1" "$(cat "$s/read.rc" 2> /dev/null || echo MISSING)" \
        "PAM-24c: missing key returns a DISTINCT failure status (rc 1)"
    assert_eq "1" "$(cat "$s/seen.rc" 2> /dev/null || echo MISSING)" \
        "PAM-24c: seen field of a missing key is also unreadable"
    assert_eq "1" "$(cat "$s/snap.rc" 2> /dev/null || echo MISSING)" \
        "PAM-24c: snapshot FAILS when the key is absent"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-24c: no sidecar may be published for an unreadable key"
    assert_contains "refusing to snapshot an unreadable selection" \
        "$(cat "$s/log.txt" 2> /dev/null || echo MISSING)" \
        "PAM-24c: failure is explicit, not silent"
}

# PAM-25: a legacy sidecar (no seen metadata) restores the value only and never
# drives the seen flag itself — the set-selections stub here deliberately leaves
# seen alone so any FSET would be attributable to the product.
test_pam_25_legacy_sidecar_restores_value_only() {
    local s sel_before
    s="$(setup_pam_sandbox legacy-seen-sidecar)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    sel_before="$(pam_selection "$s")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    # A real tool always exposes the seen flag, so "legacy" is modelled ONLY
    # by a sidecar that lacks the metadata line (P3). Strip it after install
    # instead of pretending the flag was unreadable at snapshot time.
    sed '/^# cros-enablement: selection-seen=/d' "$s/manifest/pam-selection" \
        > "$s/manifest/pam-selection.legacy"
    cat "$s/manifest/pam-selection.legacy" > "$s/manifest/pam-selection"
    rm -f "$s/manifest/pam-selection.legacy"
    assert_not_contains 'selection-seen=' \
        "$(cat "$s/manifest/pam-selection" 2> /dev/null || echo MISSING)" \
        "PAM-25: legacy sidecar has no seen metadata line"

    # The pre-existing seen state at uninstall time must be left untouched.
    pam_write_selection_seen "$s" false
    cat > "$s/stub/debconf-set-selections" << 'EOF'
#!/usr/bin/env bash
printf 'debconf-set-selections %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
_in="$(cat)"
case "$_in" in
    libpam-runtime\ libpam-runtime/profiles\ multiselect*)
        _val="${_in#libpam-runtime libpam-runtime/profiles multiselect}"
        _val="${_val#"${_val%%[![:space:]]*}"}"
        ;;
    *) _val="$_in" ;;
esac
printf '%s\n' "$_val" > "${STUB_DEBCONF_PROFILES:?PAM debconf seam missing}"
EOF
    chmod +x "$s/stub/debconf-set-selections"
    : > "$s/tool.log"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-25: legacy restore rc 0"
    assert_eq "$sel_before" "$(pam_selection "$s")" \
        "PAM-25: legacy sidecar still restores the exact value"
    assert_eq "false" "$(pam_selection_seen "$s" 2> /dev/null || echo MISSING)" \
        "PAM-25: legacy sidecar does NOT change the existing seen flag"
    assert_not_contains 'debconf-communicate cmd: FSET' \
        "$(cat "$s/tool.log" 2> /dev/null || echo MISSING)" \
        "PAM-25: no FSET call at all for a legacy sidecar"
}

# PAM-26: if the seen flag cannot be restored, keep the sidecar and fail closed.
test_pam_26_fset_failure_keeps_sidecar() {
    local s
    s="$(setup_pam_sandbox seen-fset-failure)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    pam_write_selection_seen "$s" false
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian

    mv "$s/stub/debconf-communicate" "$s/stub/debconf-communicate.real"
    cat > "$s/stub/debconf-communicate" << 'EOF'
#!/usr/bin/env bash
_cmds="$(cat)"
if printf '%s\n' "$_cmds" | grep -q '^FSET '; then
    printf '12 injected FSET failure\n'
    exit 0
fi
printf '%s\n' "$_cmds" | "$0.real" "$@"
exit $?
EOF
    chmod +x "$s/stub/debconf-communicate"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-26: a failed seen restore is a hard failure (rc 1)"
    [ -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-26: sidecar retained for retry when FSET fails"
    assert_contains "Could not restore the debconf seen flag" \
        "$(cat "$s/log.txt" 2> /dev/null || echo MISSING)" \
        "PAM-26: the failure is explicit"
}

# --- P2-2: debconf-show fallback (no debconf-communicate at all) ------------
# The real tool lives in /usr/bin, so simply dropping /usr/sbin from PATH is
# NOT enough to exercise the fallback. Build a PATH directory containing every
# host executable EXCEPT debconf-communicate; stubs still win (stub dir comes
# first), and every command lib/pam.sh needs (sudo/sed/awk/tee/timeout/...)
# resolves normally.
pam_make_fallback_bin() { # $1=sandbox
    local d="$1/fbbin" f name
    mkdir -p "$d"
    for f in /usr/bin/* /bin/* /usr/sbin/* /sbin/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        name="${f##*/}"
        [ "$name" = "debconf-communicate" ] && continue
        ln -sf "$f" "$d/$name" 2> /dev/null || true
    done
    [ ! -e "$d/debconf-communicate" ] || {
        echo "fallback bin accidentally contains debconf-communicate" >&2
        return 1
    }
}

# Legacy restore: value only. Like PAM-25, the set-selections stub deliberately
# leaves the raw seen flag untouched, so any seen mutation must come from FSET.
pam_set_selections_value_only() { # $1=sandbox
    cat > "$1/stub/debconf-set-selections" << 'EOF'
#!/usr/bin/env bash
printf 'debconf-set-selections %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
_in="$(cat)"
case "$_in" in
    libpam-runtime\ libpam-runtime/profiles\ multiselect*)
        _val="${_in#libpam-runtime libpam-runtime/profiles multiselect}"
        _val="${_val#"${_val%%[![:space:]]*}"}"
        ;;
    *) _val="$_in" ;;
esac
printf '%s\n' "$_val" > "${STUB_DEBCONF_PROFILES:?PAM debconf seam missing}"
EOF
    chmod +x "$1/stub/debconf-set-selections"
}

# Drive the product's own snapshot + restore with the fallback PATH. The guard
# makes the test INVALID (rc 99) if debconf-communicate leaks onto PATH.
pam_fallback_probe() { # $1=sandbox -> read.rc/read.out/snap.rc/restore.rc
    cat > "$1/fallback-probe.sh" << 'EOF'
#!/usr/bin/env bash
export PATH="$1/stub:$1/fbbin"
if command -v debconf-communicate > /dev/null 2>&1; then
    printf 'FALLBACK PROBE INVALID: debconf-communicate at %s\n' \
        "$(command -v debconf-communicate)" >&2
    exit 99
fi
export STUB_SED_LOG="$1/sed.log" STUB_TOOL_LOG="$1/tool.log"
export STUB_DEBCONF_PROFILES="$1/debconf/profiles"
export STUB_DEBCONF_SEEN="$1/debconf/seen"
export CROS_ENABLEMENT_PAM_SUDO_PATH="$1/pam/sudo"
export CROS_ENABLEMENT_PAM_DIR="$1/pam"
export CROS_ENABLEMENT_PAM_SAVED_DIR="$1/savedir"
export CROS_ENABLEMENT_PAM_SELECTION_FILE="$1/manifest/pam-selection"
source "$2/lib/pam.sh"
out="$(_pam_read_selection)"; rc=$?
printf '%s' "$out" > "$1/read.out"
printf '%s\n' "$rc" > "$1/read.rc"
_pam_snapshot_selection
printf '%s\n' "$?" > "$1/snap.rc"
# Preserve the sidecar BEFORE restore consumes it on success.
cp "$1/manifest/pam-selection" "$1/sidecar.snapshot" 2> /dev/null || true
_pam_restore_debian_selection
printf '%s\n' "$?" > "$1/restore.rc"
EOF
    chmod +x "$1/fallback-probe.sh"
    run_sandboxed "$1" 'bash "$2/fallback-probe.sh" "$2" "$1"'
}

# PAM-27: exercise the debconf-show fallback end-to-end. Both display prefixes
# must yield the VALUE (the P1 regression), but since the seen flag cannot be
# written back without the protocol tool the snapshot stays legacy: no seen
# metadata, value-only restore, no FSET. A missing line is a hard failure.
test_pam_27_debconf_show_fallback() {
    local s raw show_out
    # (a) seen=false -> debconf-show prints the two-space prefix
    s="$(setup_pam_sandbox fallback-unseen)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    pam_write_selection_seen "$s" false
    raw="$(pam_selection "$s")"
    rm -f "$s/stub/debconf-communicate"
    pam_make_fallback_bin "$s"
    pam_set_selections_value_only "$s"
    show_out="$(run_sandboxed "$s" '
        export PATH="$2/stub:$2/fbbin" STUB_TOOL_LOG="$2/tool.log"
        export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
        export STUB_DEBCONF_SEEN="$2/debconf/seen"
        "$2/stub/debconf-show" libpam-runtime
    ')"
    assert_contains '  libpam-runtime/profiles:' "$show_out" \
        "PAM-27a: unseen value uses debconf-show's two-space prefix"
    pam_fallback_probe "$s"
    assert_eq "1" "$(run_sandboxed "$s" '
        export PATH="$2/stub:$2/fbbin"
        command -v debconf-communicate > /dev/null 2>&1 && echo 0 || echo 1
    ')" "PAM-27: control — debconf-communicate is NOT discoverable in fallback PATH"
    assert_eq "0" "$(cat "$s/read.rc" 2> /dev/null || echo MISSING)" \
        "PAM-27a: fallback read of a non-empty value succeeds"
    assert_eq "$raw" "$(cat "$s/read.out" 2> /dev/null || echo MISSING)" \
        "PAM-27a: two-space prefix parsed to the exact raw value"
    assert_eq "0" "$(cat "$s/snap.rc" 2> /dev/null || echo MISSING)" \
        "PAM-27a: fallback snapshot succeeds"
    assert_eq "$raw" "$(sed '/^#/d' "$s/sidecar.snapshot" | tail -n 1)" \
        "PAM-27a: sidecar keeps the exact value from debconf-show"
    assert_not_contains 'selection-seen=' \
        "$(cat "$s/sidecar.snapshot" 2> /dev/null || echo MISSING)" \
        "PAM-27a: fallback snapshot is legacy (no seen metadata)"
    assert_eq "0" "$(cat "$s/restore.rc" 2> /dev/null || echo MISSING)" \
        "PAM-27a: legacy restore succeeds"
    assert_eq "$raw" "$(pam_selection "$s")" \
        "PAM-27a: value restored via debconf-set-selections (raw-state oracle)"
    assert_eq "false" "$(pam_selection_seen "$s" 2> /dev/null || echo MISSING)" \
        "PAM-27a: raw seen untouched (value-only restore, no FSET)"
    assert_not_contains 'FSET' "$(cat "$s/tool.log" 2> /dev/null || echo MISSING)" \
        "PAM-27a: no FSET call in fallback mode"
    assert_not_contains 'debconf-communicate' \
        "$(cat "$s/tool.log" 2> /dev/null || echo MISSING)" \
        "PAM-27a: the product never attempted a communicate call"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-27a: legacy sidecar consumed after restore"

    # (b) seen=true -> the '* ' prefix the OLD parser could not read at all
    s="$(setup_pam_sandbox fallback-seen)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, fprintd'
    pam_write_selection_seen "$s" true
    raw="$(pam_selection "$s")"
    rm -f "$s/stub/debconf-communicate"
    pam_make_fallback_bin "$s"
    pam_set_selections_value_only "$s"
    show_out="$(run_sandboxed "$s" '
        export PATH="$2/stub:$2/fbbin" STUB_TOOL_LOG="$2/tool.log"
        export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
        export STUB_DEBCONF_SEEN="$2/debconf/seen"
        "$2/stub/debconf-show" libpam-runtime
    ')"
    assert_contains '* libpam-runtime/profiles:' "$show_out" \
        "PAM-27b: seen value uses debconf-show's '* ' prefix"
    pam_fallback_probe "$s"
    assert_eq "0" "$(cat "$s/read.rc" 2> /dev/null || echo MISSING)" \
        "PAM-27b: fallback read of a '* '-prefixed value succeeds"
    assert_eq "$raw" "$(cat "$s/read.out" 2> /dev/null || echo MISSING)" \
        "PAM-27b: '* ' prefix parsed to the exact raw value (P1 regression)"
    assert_eq "0" "$(cat "$s/snap.rc" 2> /dev/null || echo MISSING)" \
        "PAM-27b: fallback snapshot succeeds for a seen value"
    assert_eq "$raw" "$(sed '/^#/d' "$s/sidecar.snapshot" | tail -n 1)" \
        "PAM-27b: '* '-prefixed value snapshotted exactly"
    assert_eq "0" "$(cat "$s/restore.rc" 2> /dev/null || echo MISSING)" \
        "PAM-27b: legacy restore succeeds for a seen value"
    assert_eq "$raw" "$(pam_selection "$s")" \
        "PAM-27b: value restored (raw-state oracle)"
    assert_eq "true" "$(pam_selection_seen "$s" 2> /dev/null || echo MISSING)" \
        "PAM-27b: raw seen untouched (legacy value-only restore)"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-27b: legacy sidecar consumed after restore"

    # (c) key absent: debconf-show prints NO line => hard failure, no snapshot
    s="$(setup_pam_sandbox fallback-absent)"
    pam_unset_selection "$s"
    rm -f "$s/stub/debconf-communicate"
    pam_make_fallback_bin "$s"
    pam_fallback_probe "$s"
    assert_eq "1" "$(cat "$s/read.rc" 2> /dev/null || echo MISSING)" \
        "PAM-27c: absent key is rc 1 in the fallback, not an empty value"
    assert_eq "1" "$(cat "$s/snap.rc" 2> /dev/null || echo MISSING)" \
        "PAM-27c: snapshot fails closed when the key is absent"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-27c: no sidecar may be published for an absent key"
    assert_contains "refusing to snapshot an unreadable selection" \
        "$(cat "$s/log.txt" 2> /dev/null || echo MISSING)" \
        "PAM-27c: fallback failure is explicit"
}

# PAM-28: the PROCESS rc is the status of the last command on a real tool.
# A non-zero rc must hard-fail even when a (hostile/buggy) debconf-show still
# prints a legal-looking value — otherwise a missing key would fail OPEN.
test_pam_28_process_rc_never_fails_open() {
    local s
    # (a) real-tool behaviour: reply status 10 AND process rc 10.
    s="$(setup_pam_sandbox process-rc-status)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    pam_write_selection_seen "$s" true
    cat > "$s/stub/debconf-communicate" << 'EOF'
#!/usr/bin/env bash
_cmds="$(cat)"
printf 'debconf-communicate %s\n' "$*" >> "${STUB_TOOL_LOG:?}"
printf 'debconf-communicate cmd: %s\n' "$_cmds" >> "${STUB_TOOL_LOG:?}"
printf '10 libpam-runtime/profiles does not exist\n'
exit 10
EOF
    cat > "$s/stub/debconf-show" << 'EOF'
#!/usr/bin/env bash
printf 'debconf-show %s\n' "$*" >> "${STUB_TOOL_LOG:?}"
printf '* libpam-runtime/profiles: unix, systemd, fprintd\n'
EOF
    chmod +x "$s/stub/debconf-communicate" "$s/stub/debconf-show"
    : > "$s/tool.log"
    pam_helper_probe "$s"
    assert_eq "1" "$(cat "$s/read.rc" 2> /dev/null || echo MISSING)" \
        "PAM-28a: non-zero process rc is a hard failure, not a fallback cue"
    assert_eq "1" "$(cat "$s/seen.rc" 2> /dev/null || echo MISSING)" \
        "PAM-28a: seen read also fails on a non-zero process rc"
    assert_eq "" "$(cat "$s/read.out" 2> /dev/null || echo MISSING)" \
        "PAM-28a: no legal-looking value leaked from debconf-show"
    assert_eq "1" "$(cat "$s/snap.rc" 2> /dev/null || echo MISSING)" \
        "PAM-28a: snapshot fails closed"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-28a: no sidecar from a failed GET"
    assert_not_contains 'debconf-show' \
        "$(cat "$s/tool.log" 2> /dev/null || echo MISSING)" \
        "PAM-28a: debconf-show fallback was NOT used"

    # (b) defensive: protocol status 0 but a non-zero PROCESS rc. A real tool
    # cannot produce this, but trusting the rc keeps the parser fail-closed.
    s="$(setup_pam_sandbox process-rc-only)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, fprintd'
    pam_write_selection_seen "$s" true
    cat > "$s/stub/debconf-communicate" << 'EOF'
#!/usr/bin/env bash
_cmds="$(cat)"
printf 'debconf-communicate %s\n' "$*" >> "${STUB_TOOL_LOG:?}"
printf 'debconf-communicate cmd: %s\n' "$_cmds" >> "${STUB_TOOL_LOG:?}"
printf '0 unix, fprintd\n'
exit 10
EOF
    cat > "$s/stub/debconf-show" << 'EOF'
#!/usr/bin/env bash
printf 'debconf-show %s\n' "$*" >> "${STUB_TOOL_LOG:?}"
printf '* libpam-runtime/profiles: unix, fprintd\n'
EOF
    chmod +x "$s/stub/debconf-communicate" "$s/stub/debconf-show"
    : > "$s/tool.log"
    pam_helper_probe "$s"
    assert_eq "1" "$(cat "$s/read.rc" 2> /dev/null || echo MISSING)" \
        "PAM-28b: a non-zero process rc wins over a 0 status token"
    assert_eq "" "$(cat "$s/read.out" 2> /dev/null || echo MISSING)" \
        "PAM-28b: no value returned when the process failed"
    assert_eq "1" "$(cat "$s/snap.rc" 2> /dev/null || echo MISSING)" \
        "PAM-28b: snapshot fails closed on a contradictory reply"
    assert_not_contains 'debconf-show' \
        "$(cat "$s/tool.log" 2> /dev/null || echo MISSING)" \
        "PAM-28b: no debconf-show fallback"
}

# ---------------------------------------------------------------------------
# PAM-29..42 (Phase 3): the Debian snapshot/restore must be one durable,
# verifiable transaction. Every fault path below must fail closed (or verify
# EVERY managed state before tolerating a tool failure) and never consume the
# only surviving copy of the original bytes.
# ---------------------------------------------------------------------------

# Install a narrowly-scoped PATH fault stub. Fixtures are written BEFORE the
# stub, and the snapshot gate fails before any backup/sed/converge is reached.
pam_snapshot_fault_stub() {
    local s="$1" fault="$2"
    case "$fault" in
        tee)
            cat > "$s/stub/tee" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        *pam-selection.tmp.*) printf 'STUB: tee refused\n' >&2; exit 1 ;;
    esac
done
exec /usr/bin/tee "$@"
EOF
            ;;
        chmod)
            cat > "$s/stub/chmod" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        *pam-selection.tmp.*) printf 'STUB: chmod refused\n' >&2; exit 1 ;;
    esac
done
exec /usr/bin/chmod "$@"
EOF
            ;;
        find)
            cat > "$s/stub/find" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        "$CROS_ENABLEMENT_PAM_SAVED_DIR")
            printf 'STUB: find refused\n' >&2; exit 1 ;;
    esac
done
exec /usr/bin/find "$@"
EOF
            ;;
        cp)
            cat > "$s/stub/cp" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        "$CROS_ENABLEMENT_PAM_SAVED_DIR"/*)
            printf 'STUB: saved-profile cp refused\n' >&2; exit 1 ;;
    esac
done
exec /bin/cp "$@"
EOF
            ;;
        ln)
            cat > "$s/stub/ln" << 'EOF'
#!/usr/bin/env bash
_last="${@: -1}"
if [ "$_last" = "$CROS_ENABLEMENT_PAM_SELECTION_FILE" ]; then
    printf 'STUB: sidecar ln refused\n' >&2
    exit 1
fi
exec /bin/ln "$@"
EOF
            ;;
        mv)
            cat > "$s/stub/mv" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        *pam-selection.saved.stage.*)
            printf 'STUB: saved-snapshot mv refused\n' >&2; exit 1 ;;
    esac
done
exec /bin/mv "$@"
EOF
            ;;
    esac
    chmod +x "$s/stub/$fault"
}

# PAM-29: tee / chmod / find / cp / ln / mv failures must make install return
# non-zero BEFORE any PAM file or debconf value is touched, with no valid
# sidecar (and no staging residue) left behind.
test_pam_29_snapshot_faults_fail_closed() {
    # Parallel-suite false-positive fix: snapshot temps go to a PRIVATE TMPDIR
    # per sandbox (lib/pam.sh's _pam_tmp_file honours TMPDIR). A mktemp stub
    # records every requested template, so a regression to a hard-coded /tmp
    # is still caught without globbing the shared /tmp namespace (final review
    # P3). Detection of real leaks is unchanged: every temp this case creates
    # must live in $s/tmp and none may survive.
    local fault s before
    for fault in tee chmod find cp ln mv; do
        s="$(setup_pam_sandbox "snapshot-fault-$fault")"
        mkdir -p "$s/tmp"
        : > "$s/tmp-templates.log"
        cat > "$s/stub/mktemp" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${PAM_TMP_TEMPLATE_LOG:?}"
exec /usr/bin/mktemp "$@"
EOF
        chmod +x "$s/stub/mktemp"
        pam_write_full_stack "$s"
        pam_write_selection "$s" 'unix, systemd, fprintd'
        before="$(pam_stack_fingerprint "$s")"
        pam_snapshot_fault_stub "$s" "$fault"

        PAM_TMP_TEMPLATE_LOG="$s/tmp-templates.log" TMPDIR="$s/tmp" \
            CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_install "$s" debian
        assert_eq "1" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
            "PAM-29/$fault: install rc 1 (snapshot is a mandatory gate)"
        assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
            "PAM-29/$fault: PAM files, savedir and debconf untouched"
        if [ -e "$s/manifest/pam-selection" ]; then
            fail "PAM-29/$fault: no sidecar may be published"
        else
            ok
        fi
        assert_eq "0" "$(find "$s/manifest" -maxdepth 1 -name 'pam-selection.saved*' 2> /dev/null | wc -l | tr -d '[:space:]')" \
            "PAM-29/$fault: no saved snapshot or stage residue"
        assert_eq "0" "$(find "$s/tmp" -maxdepth 1 -name 'cros-pam-snapshot.*' 2> /dev/null | wc -l | tr -d '[:space:]')" \
            "PAM-29/$fault: no leaked snapshot temp in the private TMPDIR"
        assert_eq "0" "$(grep -vcF "$s/tmp/" "$s/tmp-templates.log" 2> /dev/null || true)" \
            "PAM-29/$fault: every mktemp template used the private TMPDIR"
        assert_contains "refusing to continue" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
            "PAM-29/$fault: fail-closed reason logged"
    done
}

# PAM-30: an EXISTING sidecar is authoritative only when complete and valid.
# Magic-only / bad data / unknown metadata / inconsistent saved state must all
# fail closed; a complete legacy sidecar stays compatible on a best-effort basis.
test_pam_30_existing_sidecar_validation() {
    local case_name s before sidecar saved_hex_before
    for case_name in magic_only duplicate_data unknown_metadata bad_value \
        saved_complete_missing_dir saved_absent_but_dir_present; do
        s="$(setup_pam_sandbox "sidecar-invalid-$case_name")"
        sidecar="$s/manifest/pam-selection"
        pam_write_full_stack "$s"
        pam_write_selection "$s" 'unix, systemd, fprintd'
        before="$(pam_stack_fingerprint "$s")"
        case "$case_name" in
            magic_only)
                printf '%s\n' '# cros-enablement: PAM profile selection snapshot (first-wins; do not edit)' \
                    > "$sidecar"
                ;;
            duplicate_data)
                printf '%s\n' '# cros-enablement: PAM profile selection snapshot (first-wins; do not edit)' \
                    '# cros-enablement: saved-snapshot=complete' \
                    'unix, systemd, fprintd' 'unix, systemd, fprintd' > "$sidecar"
                ;;
            unknown_metadata)
                printf '%s\n' '# cros-enablement: PAM profile selection snapshot (first-wins; do not edit)' \
                    '# cros-enablement: saved-snapshot=complete' '# cros-enablement: mystery=1' \
                    'unix, systemd, fprintd' > "$sidecar"
                ;;
            bad_value)
                printf '%s\n' '# cros-enablement: PAM profile selection snapshot (first-wins; do not edit)' \
                    '# cros-enablement: saved-snapshot=complete' \
                    'unix, systemd, fprintd; rm -rf /' > "$sidecar"
                ;;
            saved_complete_missing_dir)
                printf '%s\n' '# cros-enablement: PAM profile selection snapshot (first-wins; do not edit)' \
                    '# cros-enablement: saved-snapshot=complete' \
                    'unix, systemd, fprintd' > "$sidecar"
                # .saved deliberately absent
                ;;
            saved_absent_but_dir_present)
                printf '%s\n' '# cros-enablement: PAM profile selection snapshot (first-wins; do not edit)' \
                    '# cros-enablement: saved-snapshot=absent' \
                    'unix, systemd, fprintd' > "$sidecar"
                mkdir -p "$s/manifest/pam-selection.saved"
                printf 'orphan\n' > "$s/manifest/pam-selection.saved/auth"
                ;;
        esac
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_install "$s" debian
        assert_eq "1" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
            "PAM-30/$case_name: invalid/partial sidecar is a hard failure"
        assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
            "PAM-30/$case_name: no PAM/debconf mutation after failed first-wins"
        [ -e "$sidecar" ] && ok || fail "PAM-30/$case_name: invalid sidecar was destroyed"
        if printf '%s' "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
            | grep -qE 'partial/corrupt|failing closed'; then
            ok
        else
            fail "PAM-30/$case_name: fail-closed reason logged"
        fi
    done

    # Legacy sidecar (no saved-snapshot line): best-effort compatibility.
    s="$(setup_pam_sandbox sidecar-legacy-valid)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-30/legacy: first install publishes a complete snapshot"
    before="$(pam_stack_fingerprint "$s")"
    sed -e '/^# cros-enablement: saved-snapshot=/d' \
        -e '/^# cros-enablement: selection-seen=/d' "$s/manifest/pam-selection" \
        > "$s/manifest/pam-selection.legacy"
    cat "$s/manifest/pam-selection.legacy" > "$s/manifest/pam-selection"
    rm -f "$s/manifest/pam-selection.legacy"
    assert_not_contains 'saved-snapshot=' "$(cat "$s/manifest/pam-selection")" \
        "PAM-30/legacy: saved metadata removed to model an older sidecar"
    assert_not_contains 'selection-seen=' "$(cat "$s/manifest/pam-selection")" \
        "PAM-30/legacy: seen metadata removed to model an older sidecar"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-30/legacy: legacy sidecar remains compatible (first-wins)"
    assert_contains "best-effort compatibility" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-30/legacy: backward-compat note logged"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-30/legacy: keeping a sidecar never mutates the live stack"

    # Re-review #15 finding #3: a legacy sidecar with a MISSING .saved must
    # never be "repaired" from a possibly already-modified live savedir.
    s="$(setup_pam_sandbox sidecar-legacy-repair)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    sed -e '/^# cros-enablement: saved-snapshot=/d' \
        -e '/^# cros-enablement: selection-seen=/d' "$s/manifest/pam-selection" \
        > "$s/manifest/pam-selection.legacy"
    cat "$s/manifest/pam-selection.legacy" > "$s/manifest/pam-selection"
    rm -f "$s/manifest/pam-selection.legacy"
    saved_hex_before="$(pam_saved_snapshot_hex "$s")"
    # Model a crash immediately after publish: .saved is lost, but the LIVE
    # savedir still holds (possibly tool-modified) profile files. Re-snapshotting
    # them would silently bless modified bytes, so install MUST fail closed.
    cp -a "$s/manifest/pam-selection.saved"/. "$s/savedir"/
    rm -rf "$s/manifest/pam-selection.saved"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "1" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-30/legacy-repair: install fails closed on a missing .saved"
    if [ -e "$s/manifest/pam-selection.saved" ]; then
        fail "PAM-30/legacy-repair: no .saved may be re-published from live state"
    else
        ok
    fi
    assert_contains "manual recovery required" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-30/legacy-repair: manual-recovery reason logged"
    [ -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-30/legacy-repair: legacy sidecar preserved"
    # Live savedir files were copied there from the snapshot before install;
    # they must still hold those exact bytes (never re-snapshotted, never lost).
    local live_hex=""
    for t in auth account password session session-noninteractive; do
        live_hex="$live_hex $(file_hex "$s/savedir/$t")"
    done
    assert_eq "$saved_hex_before" "$live_hex" \
        "PAM-30/legacy-repair: live savedir bytes untouched, no snapshot invented"
}

# Hex of all snapshotted saved-profile files (independent of lib/pam.sh).
pam_saved_snapshot_hex() {
    local s="$1" t out=""
    for t in auth account password session session-noninteractive; do
        [ -f "$s/manifest/pam-selection.saved/$t" ] \
            && out="$out $(file_hex "$s/manifest/pam-selection.saved/$t")"
    done
    printf '%s\n' "$out"
}

# Install a complete stack; fail the caller's assertion if the snapshot gate
# itself fails (the fault cases below are all about the RESTORE half).
pam_install_for_restore_test() {
    local s="$1"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "restore fixture: install rc 0 for $s"
}

# PAM-31: a broken saved-dir restore (copy failure, byte mismatch, or a copy
# that only LOOKS successful) must keep rc 1 and BOTH halves of the snapshot.
test_pam_31_saved_dir_restore_failures_keep_snapshot() {
    local case_name s before snapshot_hex
    for case_name in cp_fail cmp_mismatch wrong_bytes; do
        s="$(setup_pam_sandbox "restore-saved-$case_name")"
        pam_install_for_restore_test "$s"
        before="$(pam_stack_fingerprint "$s")"
        snapshot_hex="$(pam_saved_snapshot_hex "$s")"
        case "$case_name" in
            cp_fail)
                cat > "$s/stub/cp" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        *pam-selection.saved/*) printf 'STUB: restore cp refused\n' >&2; exit 1 ;;
    esac
done
exec /bin/cp "$@"
EOF
                ;;
            cmp_mismatch)
                cat > "$s/stub/cmp" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        *savedir*|*pam-selection.saved*) exit 1 ;;
    esac
done
exec /usr/bin/cmp "$@"
EOF
                ;;
            wrong_bytes)
                # cp exits 0 but writes DIFFERENT bytes: selection equality
                # must never be enough to consume the sidecar.
                cat > "$s/stub/cp" << 'EOF'
#!/usr/bin/env bash
_args=("$@")
_src=""
for _a in "${_args[@]}"; do
    case "$_a" in
        *pam-selection.saved/*) _src="$_a" ;;
    esac
done
if [ -n "$_src" ]; then
    /bin/cp "$@" || exit $?
    printf 'WRONG-BYTES\n' > "${_args[${#_args[@]}-1]}"
    exit 0
fi
exec /bin/cp "$@"
EOF
                # The live selection is ALREADY equal to the snapshot, so the
                # only failing managed state is the saved-file bytes.
                pam_write_selection "$s" 'unix, systemd, fprintd'
                ;;
        esac
        chmod +x "$s/stub/cp" 2> /dev/null || true
        chmod +x "$s/stub/cmp" 2> /dev/null || true

        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_uninstall "$s" debian
        assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
            "PAM-31/$case_name: disable rc 1 when saved files are not byte-identical"
        [ -e "$s/manifest/pam-selection" ] \
            && ok || fail "PAM-31/$case_name: sidecar must be retained"
        [ -d "$s/manifest/pam-selection.saved" ] \
            && ok || fail "PAM-31/$case_name: .saved must be retained"
        assert_eq "$snapshot_hex" "$(pam_saved_snapshot_hex "$s")" \
            "PAM-31/$case_name: snapshot bytes unchanged (never destroy the only copy)"
        assert_contains "keeping $s/manifest/pam-selection" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
            "PAM-31/$case_name: retry data explicitly retained in the log"
        if [ "$case_name" = wrong_bytes ]; then
            assert_eq 'unix, systemd, fprintd' "$(pam_selection "$s")" \
                "PAM-31/wrong_bytes: selection WAS equal yet rc must still be 1"
        fi
    done
}

# PAM-32: a failing debconf-set-selections (or --package) is tolerated ONLY
# when every managed state verifies identical; PAM-16/17 must not regress.
test_pam_32_tool_failure_with_verified_state_succeeds() {
    local s snapshot_value
    s="$(setup_pam_sandbox tool-failure-verified)"
    pam_install_for_restore_test "$s"
    snapshot_value="$(sed '/^#/d' "$s/manifest/pam-selection" | tail -n 1)"
    # Put the live selection into the EXACT snapshotted state first; the tool
    # then fails without writing anything, so verification is the only thing
    # that can justify consuming the snapshot.
    pam_write_selection "$s" "$snapshot_value"
    cat > "$s/stub/debconf-set-selections" << 'EOF'
#!/usr/bin/env bash
printf 'STUB: debconf-set-selections refused\n' >&2
exit 1
EOF
    cat > "$s/stub/pam-auth-update" << 'EOF'
#!/usr/bin/env bash
printf 'pam-auth-update %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
exit 1
EOF
    chmod +x "$s/stub/debconf-set-selections" "$s/stub/pam-auth-update"
    : > "$s/tool.log"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-32: tool failures tolerated when ALL managed state verifies equal"
    assert_eq "$snapshot_value" "$(pam_selection "$s")" \
        "PAM-32: live selection equals the snapshot"
    [ ! -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-32: sidecar consumed after full verification"
    [ ! -e "$s/manifest/pam-selection.saved" ] \
        && ok || fail "PAM-32: .saved consumed after full verification"
    [ ! -e "$s/manifest/pam-selection.common" ] \
        && ok || fail "PAM-32: .common consumed after full verification"
    assert_contains "every managed state was verified identical" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-32: tool-failure tolerance is explicit in the log"
}

# PAM-33: after a failed restore, a retry with the fault removed must restore
# EVERYTHING and only then consume the retained snapshot.
test_pam_33_retry_after_failed_restore_consumes_only_on_success() {
    local s before snapshot_hex
    s="$(setup_pam_sandbox restore-retry)"
    # Capture the ORIGINAL bytes before install so the final assertion proves
    # the retry actually restored them (not merely the installed state).
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    before="$(pam_stack_fingerprint "$s")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-33: install fixture rc 0"
    snapshot_hex="$(pam_saved_snapshot_hex "$s")"

    cat > "$s/stub/cp" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        *pam-selection.saved/*) printf 'STUB: restore cp refused (first try)\n' >&2; exit 1 ;;
    esac
done
exec /bin/cp "$@"
EOF
    chmod +x "$s/stub/cp"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-33: first restore attempt fails"
    [ -e "$s/manifest/pam-selection" ] && [ -d "$s/manifest/pam-selection.saved" ] \
        && ok || fail "PAM-33: retry data retained after the failed attempt"
    assert_eq "$snapshot_hex" "$(pam_saved_snapshot_hex "$s")" \
        "PAM-33: retained snapshot is still byte-identical"

    rm -f "$s/stub/cp"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-33: retry succeeds"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-33: everything restored before the snapshot is consumed"
    [ ! -e "$s/manifest/pam-selection" ] && [ ! -e "$s/manifest/pam-selection.saved" ] \
        && ok || fail "PAM-33: snapshot consumed only after a fully verified restore"
}

# PAM-34: restore's OWN defensive rollback gate (not just disable's gate).
test_pam_34_restore_checks_rollback_completeness() {
    local s before
    s="$(setup_pam_sandbox restore-rollback-gate)"
    pam_install_for_restore_test "$s"
    before="$(pam_stack_fingerprint "$s")"
    # Simulate an incomplete rollback by keeping a manifest record for sudo.
    python3 - "$s/manifest/install-manifest.json" "$s/pam/sudo" << 'PY'
import json, sys
mp, target = sys.argv[1:3]
json.dump({"version": "2.0", "records": [
    {"target": target, "component": "fingerprint", "was_existing": True}],
    "services": [], "groups": []}, open(mp, "w"), indent=2)
PY
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_sandboxed "$s" '
            export PATH="$2/stub:/usr/bin:/bin"
            export STUB_SED_LOG="$2/sed.log" STUB_TOOL_LOG="$2/tool.log"
            export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
            export STUB_DEBCONF_SEEN="$2/debconf/seen"
            source "$1/lib/pam.sh"
            _pam_restore_debian_selection
            printf "%s\n" "$?" > "$2/restore.rc"
        '
    assert_eq "1" "$(cat "$s/restore.rc" 2> /dev/null || echo MISSING)" \
        "PAM-34: restore itself refuses an incomplete rollback"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-34: no debconf/savedir mutation while a record survives"
    [ -e "$s/manifest/pam-selection" ] && [ -d "$s/manifest/pam-selection.saved" ] \
        && ok || fail "PAM-34: snapshot retained when rollback is incomplete"
}

# ---------------------------------------------------------------------------
# Reviewer A follow-up (P1-1/P1-2/P2/P3): recoverable consume, orphan safety,
# strict sidecar classification, FGET hard failure and bidirectional savedir
# verification.
# ---------------------------------------------------------------------------

pam_consume_fault_stub() {
    local s="$1" fault="$2"
    case "$fault" in
        rm_saved_fail)
            cat > "$s/stub/rm" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        *pam-selection.saved*) printf 'STUB: rm .saved refused\n' >&2; exit 1 ;;
    esac
done
exec /bin/rm "$@"
EOF
            ;;
        rm_sidecar_fail)
            cat > "$s/stub/rm" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    if [ "$_a" = "$CROS_ENABLEMENT_PAM_SELECTION_FILE" ]; then
        printf 'STUB: rm sidecar refused\n' >&2
        exit 1
    fi
done
exec /bin/rm "$@"
EOF
            ;;
    esac
    chmod +x "$s/stub/rm"
}

# PAM-35: consume is recoverable. Injecting a failure on either removal must
# leave BOTH halves present and retryable; only a later full success consumes.
test_pam_35_consume_failure_is_recoverable() {
    local fault s before sidecar_hex snapshot_hex
    for fault in rm_saved_fail rm_sidecar_fail; do
        s="$(setup_pam_sandbox "consume-fault-$fault")"
        pam_write_full_stack "$s"
        pam_write_selection "$s" 'unix, systemd, fprintd'
        before="$(pam_stack_fingerprint "$s")"
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_install "$s" debian
        assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
            "PAM-35/$fault: install fixture rc 0"
        sidecar_hex="$(file_hex "$s/manifest/pam-selection")"
        snapshot_hex="$(pam_saved_snapshot_hex "$s")"
        pam_consume_fault_stub "$s" "$fault"

        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_uninstall "$s" debian
        assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
            "PAM-35/$fault: failed consume returns rc 1"
        [ -e "$s/manifest/pam-selection" ] && [ -d "$s/manifest/pam-selection.saved" ] \
            && ok || fail "PAM-35/$fault: both halves must remain present/retryable"
        assert_eq "$sidecar_hex" "$(file_hex "$s/manifest/pam-selection" 2> /dev/null || echo MISSING)" \
            "PAM-35/$fault: sidecar bytes unchanged (rebuilt exactly if needed)"
        assert_eq "$snapshot_hex" "$(pam_saved_snapshot_hex "$s")" \
            "PAM-35/$fault: .saved bytes unchanged"
        assert_not_contains "sidecar consumed" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
            "PAM-35/$fault: no false success after a partial consume"

        rm -f "$s/stub/rm"
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_uninstall "$s" debian
        assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
            "PAM-35/$fault: retry after removing the fault succeeds"
        assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
            "PAM-35/$fault: retry restores every byte before consuming"
        [ ! -e "$s/manifest/pam-selection" ] && [ ! -e "$s/manifest/pam-selection.saved" ] \
            && ok || fail "PAM-35/$fault: both halves consumed only after full success"
    done
}

# PAM-36: an orphaned .saved (no sidecar) is a unique original copy. Neither a
# fresh install nor a failed-publication rollback may delete or overwrite it.
test_pam_36_orphan_saved_snapshot_is_preserved() {
    local s before orphan
    s="$(setup_pam_sandbox orphan-at-install)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    before="$(pam_stack_fingerprint "$s")"
    mkdir -p "$s/manifest/pam-selection.saved"
    printf 'ORIGINAL-SENTINEL\n' > "$s/manifest/pam-selection.saved/orphan"
    orphan="$(file_hex "$s/manifest/pam-selection.saved/orphan")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "1" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-36: install fails closed when .saved exists without a sidecar"
    assert_eq "$orphan" "$(file_hex "$s/manifest/pam-selection.saved/orphan" 2> /dev/null || echo MISSING)" \
        "PAM-36: orphan bytes untouched"
    [ -d "$s/manifest/pam-selection.saved" ] && ok || fail "PAM-36: orphan directory not deleted"
    if [ -e "$s/manifest/pam-selection" ]; then
        fail "PAM-36: no sidecar may be published for an orphan-only snapshot"
    else
        ok
    fi
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-36: PAM files and debconf untouched"

    # Unit-level guard for the rollback helper: flag 0 must never touch .saved.
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_sandboxed "$s" '
            export PATH="$2/stub:/usr/bin:/bin"
            source "$1/lib/pam.sh"
            _pam_rollback_own_snapshot 0
        '
    assert_eq "$orphan" "$(file_hex "$s/manifest/pam-selection.saved/orphan" 2> /dev/null || echo MISSING)" \
        "PAM-36: _pam_rollback_own_snapshot 0 preserves the orphan"
    assert_contains "Orphaned saved PAM profile snapshot" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-36: orphan refusal is explicit in the log"
}

# PAM-37: seen metadata WITHOUT saved metadata is truncation, not legacy.
test_pam_37_seen_only_sidecar_fails_closed() {
    local s before
    s="$(setup_pam_sandbox seen-only-sidecar)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    before="$(pam_stack_fingerprint "$s")"
    printf '%s\n' '# cros-enablement: PAM profile selection snapshot (first-wins; do not edit)' \
        '# cros-enablement: selection-seen=true' \
        'unix, systemd, fprintd' > "$s/manifest/pam-selection"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "1" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-37/install: seen-only sidecar is a hard failure"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-37/install: no PAM/debconf mutation"
    assert_contains "no saved-snapshot metadata" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-37/install: truncation reason logged"

    # The same classification must hold on the restore side.
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_sandboxed "$s" '
            export PATH="$2/stub:/usr/bin:/bin"
            export STUB_SED_LOG="$2/sed.log" STUB_TOOL_LOG="$2/tool.log"
            export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
            export STUB_DEBCONF_SEEN="$2/debconf/seen"
            source "$1/lib/pam.sh"
            _pam_restore_debian_selection
            printf "%s\n" "$?" > "$2/restore.rc"
        '
    assert_eq "1" "$(cat "$s/restore.rc" 2> /dev/null || echo MISSING)" \
        "PAM-37/restore: seen-only sidecar fails closed"
    [ -e "$s/manifest/pam-selection" ] && ok || fail "PAM-37/restore: sidecar retained"
}

# PAM-38: a PRESENT debconf-communicate that fails FGET (or returns a value
# other than true/false) is a hard snapshot failure, not a legacy downgrade.
test_pam_38_fget_failure_is_hard_failure() {
    local case_name s before
    for case_name in fget_status fget_invalid; do
        s="$(setup_pam_sandbox "fget-$case_name")"
        pam_write_full_stack "$s"
        pam_write_selection "$s" 'unix, systemd, fprintd'
        before="$(pam_stack_fingerprint "$s")"
        if [ "$case_name" = fget_status ]; then
            cat > "$s/stub/debconf-communicate" << 'EOF'
#!/usr/bin/env bash
_cmds="$(cat)"
printf 'debconf-communicate cmd: %s\n' "$_cmds" >> "${STUB_TOOL_LOG:?}"
case "$_cmds" in
    *FGET*) printf '12 injected FGET failure\n'; exit 12 ;;
    *) printf '0 unix, systemd, fprintd\n'; exit 0 ;;
esac
EOF
        else
            cat > "$s/stub/debconf-communicate" << 'EOF'
#!/usr/bin/env bash
_cmds="$(cat)"
printf 'debconf-communicate cmd: %s\n' "$_cmds" >> "${STUB_TOOL_LOG:?}"
case "$_cmds" in
    *FGET*) printf '0 maybe\n'; exit 0 ;;
    *) printf '0 unix, systemd, fprintd\n'; exit 0 ;;
esac
EOF
        fi
        chmod +x "$s/stub/debconf-communicate"

        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_install "$s" debian
        assert_eq "1" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
            "PAM-38/$case_name: FGET failure is a hard snapshot failure"
        assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
            "PAM-38/$case_name: no PAM/debconf mutation"
        if [ -e "$s/manifest/pam-selection" ]; then
            fail "PAM-38/$case_name: no legacy sidecar from a failing FGET"
        else
            ok
        fi
        assert_contains "reading the seen flag failed" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
            "PAM-38/$case_name: hard-failure reason logged"
    done
}

# PAM-39: savedir verification is bidirectional and rejects an empty snapshot;
# a genuinely empty live savedir is recorded as "absent" instead.
test_pam_39_savedir_bidirectional_and_empty_checks() {
    local s log
    # (a) extra LIVE saved file must be detected even when every snapshotted
    #     file is byte-identical.
    s="$(setup_pam_sandbox savedir-extra-live)"
    pam_install_for_restore_test "$s"
    printf 'EXTRA-LIVE\n' > "$s/savedir/extra.conf"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-39a: extra live saved profile fails the restore"
    [ -e "$s/manifest/pam-selection" ] && ok || fail "PAM-39a: sidecar retained"
    # The entry-set gate now names the divergence first; the byte comparator's
    # older "has no counterpart" reason may still appear on other paths. Both
    # prove the same fail-closed decision.
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    if printf '%s' "$log" | grep -qE 'has no counterpart|entry-set mismatch'; then
        ok
    else
        fail "PAM-39a: extra live file named in the log"
    fi

    # (b) sidecar says complete but .saved was emptied: fail closed.
    s="$(setup_pam_sandbox savedir-empty-snapshot)"
    pam_install_for_restore_test "$s"
    rm -f "$s/manifest/pam-selection.saved"/*
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-39b: empty .saved cannot satisfy saved-snapshot=complete"
    [ -e "$s/manifest/pam-selection" ] && ok || fail "PAM-39b: sidecar retained"
    assert_contains "empty" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-39b: empty snapshot reason logged"

    # (c) an EMPTY live savedir is not "complete": install records absent and
    #     uninstall still succeeds without a .saved half.
    s="$(setup_pam_sandbox savedir-truly-empty)"
    pam_write_initial_files "$s" none none
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-39c: install succeeds with an empty savedir"
    assert_contains '# cros-enablement: saved-snapshot=absent' \
        "$(cat "$s/manifest/pam-selection" 2> /dev/null || echo MISSING)" \
        "PAM-39c: empty savedir is recorded as absent"
    if [ -e "$s/manifest/pam-selection.saved" ]; then
        fail "PAM-39c: no .saved published for an empty savedir"
    else
        ok
    fi
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-39c: uninstall succeeds when the snapshot was absent"
}

# PAM-40: if BOTH .saved removal and the subsequent sidecar rebuild fail, the
# original bytes still exist but the sidecar cannot be restored automatically.
# That must be an explicit CRITICAL log (never a silent success or a false
# "nothing to restore" on the next uninstall).
test_pam_40_rebuild_failure_logs_critical() {
    local s snapshot_hex
    s="$(setup_pam_sandbox consume-rebuild-critical)"
    pam_install_for_restore_test "$s"
    snapshot_hex="$(pam_saved_snapshot_hex "$s")"
    pam_consume_fault_stub "$s" rm_saved_fail
    cat > "$s/stub/ln" << 'EOF'
#!/usr/bin/env bash
_last="${@: -1}"
if [ "$_last" = "$CROS_ENABLEMENT_PAM_SELECTION_FILE" ]; then
    printf 'STUB: sidecar rebuild ln refused\n' >&2
    exit 1
fi
exec /bin/ln "$@"
EOF
    chmod +x "$s/stub/ln"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-40: rc 1 when consume and rebuild both fail"
    if [ ! -e "$s/manifest/pam-selection" ] && [ -d "$s/manifest/pam-selection.saved" ]; then
        ok
    else
        fail "PAM-40: unexpectedly recoverable state (sidecar present or .saved lost)"
    fi
    assert_eq "$snapshot_hex" "$(pam_saved_snapshot_hex "$s")" \
        "PAM-40: original saved bytes remain intact"
    assert_contains "CRITICAL" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-40: CRITICAL log emitted"
    assert_contains "manual recovery is REQUIRED" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-40: log explicitly demands manual recovery"

    # A retry in the SAME broken state must NOT claim success: restore must
    # recognise the orphaned .saved and demand manual recovery (P2).
    : > "$s/log.txt"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_neq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-40/retry: orphaned .saved must not produce a false success"
    assert_contains "Orphaned PAM snapshot half" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-40/retry: orphan is explicitly reported"
    assert_eq "$snapshot_hex" "$(pam_saved_snapshot_hex "$s")" \
        "PAM-40/retry: orphan bytes still intact"
}

# With no (or an empty) savedir snapshot there is no authoritative profile
# state for --package to re-derive from; model it as a no-op tool.
pam_noop_package_tool() {
    cat > "$1/stub/pam-auth-update" << 'EOF'
#!/usr/bin/env bash
printf 'pam-auth-update %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
exit 0
EOF
    chmod +x "$1/stub/pam-auth-update"
}

# PAM-41: a REAL previous-release sidecar (magic + value only, NO optional
# metadata) published together with .saved must still install AND uninstall.
# Restore infers complete/absent from .saved state and stays value-only.
test_pam_41_legacy_sidecar_roundtrip() {
    local case_name s before sel_before
    for case_name in with_saved without_saved empty_saved empty_repair no_savedir; do
        s="$(setup_pam_sandbox "legacy-roundtrip-$case_name")"
        pam_write_full_stack "$s"
        pam_write_selection "$s" 'unix, systemd, fprintd'
        before="$(pam_stack_fingerprint "$s")"
        sel_before="$(pam_selection "$s")"
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_install "$s" debian
        assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
            "PAM-41/$case_name: install rc 0"

        # Downgrade the published sidecar to the exact legacy shape.
        sed -e '/^# cros-enablement: selection-seen=/d' \
            -e '/^# cros-enablement: saved-snapshot=/d' \
            "$s/manifest/pam-selection" > "$s/manifest/pam-selection.legacy"
        cat "$s/manifest/pam-selection.legacy" > "$s/manifest/pam-selection"
        rm -f "$s/manifest/pam-selection.legacy"
        assert_not_contains 'selection-seen=' "$(cat "$s/manifest/pam-selection")" \
            "PAM-41/$case_name: no seen metadata (legacy)"
        assert_not_contains 'saved-snapshot=' "$(cat "$s/manifest/pam-selection")" \
            "PAM-41/$case_name: no saved metadata (legacy)"

        case "$case_name" in
            without_saved)
                # A missing legacy .saved may ONLY be classified as absent when
                # the live savedir is empty; populated live state requires
                # manual recovery (re-review #15 finding #3).
                rm -rf "$s/manifest/pam-selection.saved"
                rm -f "$s/savedir"/*
                pam_noop_package_tool "$s"
                ;;
            empty_saved)
                # The OLD installer published an EMPTY .saved when /var/lib/pam
                # existed but held no profiles. A NEW install must accept it.
                rm -f "$s/manifest/pam-selection.saved"/*
                CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
                    run_pam_install "$s" debian
                assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
                    "PAM-41/empty_saved: install rc 0 with a legacy empty .saved"
                pam_noop_package_tool "$s"
                ;;
            empty_repair)
                # Missing .saved + an empty live savedir: a new install must
                # classify it as absent WITHOUT publishing an empty .saved.
                rm -rf "$s/manifest/pam-selection.saved"
                rm -f "$s/savedir"/*
                CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
                    run_pam_install "$s" debian
                assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
                    "PAM-41/empty_repair: install rc 0 with an empty live savedir"
                if [ -e "$s/manifest/pam-selection.saved" ]; then
                    fail "PAM-41/empty_repair: absent classification must not publish an empty .saved"
                else
                    ok
                fi
                pam_noop_package_tool "$s"
                ;;
            no_savedir)
                # Reviewer P2-1: a legacy sidecar with no .saved AND no live
                # savedir directory must also classify as absent. `sudo find`
                # on a missing dir returns rc 1; that must not hard-fail install.
                rm -rf "$s/manifest/pam-selection.saved"
                rm -rf "$s/savedir"
                : > "$s/log.txt"
                CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
                    run_pam_install "$s" debian
                assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
                    "PAM-41/no_savedir: install rc 0 with no live savedir directory"
                assert_contains "does not exist; treating it as saved-snapshot=absent" \
                    "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
                    "PAM-41/no_savedir: missing live dir classified as absent"
                assert_not_contains "Could not inspect $s/savedir" \
                    "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
                    "PAM-41/no_savedir: no find failure escalated to hard failure"
                if [ -e "$s/manifest/pam-selection.saved" ]; then
                    fail "PAM-41/no_savedir: absent classification must not publish an empty .saved"
                else
                    ok
                fi
                pam_noop_package_tool "$s"
                ;;
        esac
        : > "$s/tool.log"

        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_uninstall "$s" debian
        assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
            "PAM-41/$case_name: legacy sidecar can be uninstalled"
        assert_eq "$sel_before" "$(pam_selection "$s")" \
            "PAM-41/$case_name: original selection restored"
        [ ! -e "$s/manifest/pam-selection" ] \
            && ok || fail "PAM-41/$case_name: legacy sidecar consumed"
        assert_not_contains 'FSET' "$(cat "$s/tool.log" 2> /dev/null || echo '')" \
            "PAM-41/$case_name: legacy restore stays value-only (no FSET)"
        if [ "$case_name" = with_saved ]; then
            assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
                "PAM-41/with_saved: every byte restored from the legacy .saved"
            if [ ! -e "$s/manifest/pam-selection.saved" ]; then
                ok
            else
                fail "PAM-41/with_saved: .saved consumed after verification"
            fi
            assert_contains "inferring saved-snapshot=complete" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
                "PAM-41/with_saved: inference logged"
        else
            assert_contains "inferring saved-snapshot=absent" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
                "PAM-41/$case_name: absent inference logged"
        fi
        if [ "$case_name" = empty_saved ]; then
            assert_contains "is empty; treating it as saved-snapshot=absent" \
                "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
                "PAM-41/empty_saved: empty legacy .saved treated as absent on install"
            assert_contains "Legacy PAM sidecar has an empty" \
                "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
                "PAM-41/empty_saved: empty legacy .saved treated as absent on restore"
        fi
    done
}

# PAM-42: restore must not report "nothing to restore" (rc 0) when .saved is
# orphaned by a deleted sidecar; that is a manual-recovery state.
test_pam_42_orphan_saved_at_restore_fails() {
    local s snapshot_hex
    s="$(setup_pam_sandbox orphan-at-restore)"
    pam_install_for_restore_test "$s"
    snapshot_hex="$(pam_saved_snapshot_hex "$s")"
    rm -f "$s/manifest/pam-selection"
    : > "$s/log.txt"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_neq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-42: orphaned .saved without a sidecar is rc != 0"
    assert_contains "Orphaned PAM snapshot half" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-42: orphan is explicitly reported, not a silent no-op"
    assert_eq "$snapshot_hex" "$(pam_saved_snapshot_hex "$s")" \
        "PAM-42: orphan bytes untouched"
}

# ---------------------------------------------------------------------------
# Re-review #15 findings #2/#3 (PAM-43..52): final common-*/sudo state must be
# verified from an independent .common snapshot AFTER every external tool call;
# rollback's gate must not skip missing files with surviving records.
# ---------------------------------------------------------------------------

# Independent oracle for every managed common/sudo target. For regular files
# sha256 covers bytes; for symlinks it covers the readlink() target string,
# matching the .common snapshot format. mode/owner come from lstat.
pam_common_state() { # $1=sandbox -> one tab-separated line per canonical target
    local s="$1" base f type mode owner link sha
    for base in sudo common-auth common-account common-session common-session-noninteractive common-password; do
        f="$s/pam/$base"
        if [ -L "$f" ]; then
            type='link'
            link="$(readlink -- "$f")"
            sha="$(printf '%s' "$link" | sha256sum | awk '{print $1}')"
        elif [ -f "$f" ]; then
            type='file'
            link='-'
            sha="$(sha256sum -- "$f" | awk '{print $1}')"
        else
            printf '%s\tabsent\t-\t-\t-\t-\n' "$base"
            continue
        fi
        mode="$(stat -c '%a' -- "$f")"
        owner="$(stat -c '%u:%g' -- "$f")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$type" "$mode" "$owner" "$link" "$sha"
    done
}

# Hex of every file in all three snapshot halves (independent of lib/pam.sh).
pam_all_halves_hex() { # $1=sandbox
    local s="$1" f out=""
    for f in "$s/manifest/pam-selection" \
        "$s/manifest/pam-selection.saved"/* \
        "$s/manifest/pam-selection.common/state" \
        "$s/manifest/pam-selection.common/savedir.entries" \
        "$s/manifest/pam-selection.common/files"/*; do
        [ -f "$f" ] || continue
        out="$out ${f##*/}=$(sha256sum -- "$f" | awk '{print $1}')"
    done
    printf '%s\n' "$out"
}

# PAM-43: the exact re-review #2 reproduction at stub fidelity. A baseline
# common-auth with equivalent-but-different spacing and mode 0600 must come
# back BYTE- and MODE-identical even when the tool rewrites it after uninstall.
# The sensitivity control proves the stub really performs that rewrite.
test_pam_43_tool_rewrite_restores_original_bytes_and_mode() {
    local s before control_before control_after state_before state_after
    local s_iso iso_before had_rewrite saved_rewrite
    s="$(setup_pam_sandbox tool-rewrite-bytes)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    /usr/bin/sed -i 's/pam_unix\.so nullok/pam_unix.so    nullok/' "$s/pam/common-auth"
    chmod 0600 "$s/pam/common-auth"
    cp -a "$s/pam/common-auth" "$s/common.baseline"
    before="$(pam_stack_fingerprint "$s")"
    state_before="$(pam_common_state "$s")"

    # CONTROL: the faithful tool stub really normalises whitespace and changes
    # 0600 -> 0644 by writing through .pam-new with umask 0022.
    control_before="$(stat -c '%a' -- "$s/pam/common-auth")-$(sha256sum "$s/pam/common-auth" | awk '{print $1}')"
    STUB_PAM_REWRITE_COMMON=1 PATH="$s/stub:$PATH" \
        STUB_TOOL_LOG="$s/control.log" STUB_DEBCONF_PROFILES="$s/debconf/profiles" \
        CROS_ENABLEMENT_PAM_DIR="$s/pam" CROS_ENABLEMENT_PAM_SAVED_DIR="$s/savedir" \
        "$s/stub/pam-auth-update" --package
    control_after="$(stat -c '%a' -- "$s/pam/common-auth")-$(sha256sum "$s/pam/common-auth" | awk '{print $1}')"
    assert_neq "$control_before" "$control_after" \
        "PAM-43/control: tool really rewrites common-auth bytes+mode (sensitivity)"
    assert_eq "644" "$(stat -c '%a' -- "$s/pam/common-auth")" \
        "PAM-43/control: real-tool model turns 0600 into 0644"
    cp -a "$s/common.baseline" "$s/pam/common-auth"
    : > "$s/tool.log"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" \
        CROS_ENABLEMENT_PAM_DIR="$s/pam" run_pam_install "$s" debian 0 1
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" "PAM-43: install rc 0"
    # External package operation after install, THEN uninstall: the tool must
    # rewrite the files once more before the product's final restore.
    STUB_PAM_REWRITE_COMMON=1 PATH="$s/stub:$PATH" STUB_TOOL_LOG="$s/tool.log" \
        STUB_DEBCONF_PROFILES="$s/debconf/profiles" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        CROS_ENABLEMENT_PAM_SAVED_DIR="$s/savedir" "$s/stub/pam-auth-update" --package
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" \
        CROS_ENABLEMENT_PAM_DIR="$s/pam" run_pam_uninstall "$s" debian 0 "" 1
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-43: uninstall rc 0 after the tool rewrote the restored files"
    state_after="$(pam_common_state "$s")"
    assert_eq "$state_before" "$state_after" \
        "PAM-43: common/sudo bytes, mode, owner, type and link targets identical to baseline"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-43: full stack + selection byte-identical to baseline"
    assert_contains "Verified final common-*/sudo state" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-43: final verification ran after the tool calls"

    # P3-2: the rewrite flag is a per-call argument exported INSIDE the sandbox.
    # Poison the parent env and call with the default 0, PAM-9 style: a later
    # case must not inherit the previous case's rewrite behaviour.
    s_iso="$(setup_pam_sandbox rewrite-flag-isolation)"
    pam_write_initial_files "$s_iso" none none
    printf 'auth required pam_unix.so\n' > "$s_iso/pam/common-auth"
    chmod 0600 "$s_iso/pam/common-auth"
    iso_before="$(file_hex "$s_iso/pam/common-auth")"
    had_rewrite="${STUB_PAM_REWRITE_COMMON+x}"
    saved_rewrite="${STUB_PAM_REWRITE_COMMON-}"
    export STUB_PAM_REWRITE_COMMON=1
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s_iso/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s_iso/pam" \
        run_pam_install "$s_iso" debian
    if [ -n "$had_rewrite" ]; then
        export STUB_PAM_REWRITE_COMMON="$saved_rewrite"
    else
        unset STUB_PAM_REWRITE_COMMON
    fi
    assert_eq "0" "$(cat "$s_iso/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-43/rewrite-isolation: install rc 0 with a poisoned parent env"
    assert_eq "$iso_before" "$(file_hex "$s_iso/pam/common-auth")" \
        "PAM-43/rewrite-isolation: per-call default 0 overrides the inherited flag"
    assert_eq "600" "$(stat -c '%a' -- "$s_iso/pam/common-auth")" \
        "PAM-43/rewrite-isolation: mode was not rewritten to 0644"
}

# PAM-44: absent / symlink / ownership variants must all be restored exactly.
test_pam_44_type_and_absence_variants() {
    local s before state_before state_after
    s="$(setup_pam_sandbox type-variants)"
    pam_write_full_stack "$s"
    # This test is ONLY the plain type/absence variant. The full-stack fixture
    # declares an enabled fprintd profile; keeping it would make --package
    # legitimately rewrite the savedir/selection on uninstall and turn this
    # into a second fp-symlink case (owned by PAM-58). Make the fixture
    # self-consistent: no active fp module anywhere and no fprintd selection.
    pam_write_selection "$s" 'unix, systemd'
    /usr/bin/sed -i -e '/pam_fprintd\.so/d' -e '/^Module: fprintd$/d' "$s/savedir/auth"
    # common-auth becomes a symlink to a regular file with the ORIGINAL bytes.
    # Use /usr/bin/sed so the harness's sed.log stays a record of the product's
    # mutations only.
    cp -a "$s/pam/common-auth" "$s/common-auth.target"
    /usr/bin/sed -i '/pam_fprintd\.so/d' "$s/common-auth.target"
    ln -sfn "$s/common-auth.target" "$s/pam/common-auth"
    # common-session becomes a DANGLING symlink (covered again in PAM-52).
    ln -sfn "$s/no-such-target" "$s/pam/common-session"
    # sudo was never present (was_existing=0) and must stay absent.
    rm -f "$s/pam/sudo"
    state_before="$(pam_common_state "$s")"
    before="$(pam_stack_fingerprint "$s")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" "PAM-44: install rc 0"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" "PAM-44: disable rc 0"
    state_after="$(pam_common_state "$s")"
    assert_eq "$state_before" "$state_after" \
        "PAM-44: symlink, dangling link, regular file and sudo absence all restored"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" "PAM-44: savedir/selection bytes restored"
    [ ! -e "$s/pam/sudo" ] && [ ! -L "$s/pam/sudo" ] \
        && ok || fail "PAM-44: sudo must stay absent (was_existing=0)"
}

# PAM-45: an injected .common restore failure must never be reported as success.
test_pam_45_common_restore_failure_keeps_all_halves() {
    local s halves
    s="$(setup_pam_sandbox common-restore-fail)"
    pam_install_for_restore_test "$s"
    halves="$(pam_all_halves_hex "$s")"
    cat > "$s/stub/mv" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        *cros-common-restore*) printf 'STUB: common restore mv refused\n' >&2; exit 1 ;;
    esac
done
exec /bin/mv "$@"
EOF
    chmod +x "$s/stub/mv"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-45: common restore failure returns rc 1"
    assert_contains "Could not atomically restore PAM file" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-45: restore failure explicitly logged"
    assert_not_contains "snapshot consumed" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-45: no false success after a partial restore"
    [ -e "$s/manifest/pam-selection" ] && [ -d "$s/manifest/pam-selection.saved" ] \
        && [ -d "$s/manifest/pam-selection.common" ] \
        && ok || fail "PAM-45: all three halves retained"
    assert_eq "$halves" "$(pam_all_halves_hex "$s")" \
        "PAM-45: every snapshot byte preserved for retry"

    rm -f "$s/stub/mv"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-45: retry after removing the fault succeeds"
    if [ ! -e "$s/manifest/pam-selection" ] && [ ! -e "$s/manifest/pam-selection.saved" ] \
        && [ ! -e "$s/manifest/pam-selection.common" ]; then
        ok
    else
        fail "PAM-45: all three halves consumed only after success"
    fi
}

# PAM-46: finding #3's exact timeline - an ORIGINALLY present common-auth is
# missing, its first backup was lost, so rollback keeps the record. The old
# live-file `[ -f ] || continue` gate skipped it and consumed the sidecar.
test_pam_46_missing_common_auth_surviving_record_fails_closed() {
    local s halves backup keep
    s="$(setup_pam_sandbox missing-common-surviving)"
    pam_install_for_restore_test "$s"
    halves="$(pam_all_halves_hex "$s")"
    backup="$(find "$s/backups" -path '*/pam/common-auth' -type f | head -n 1)"
    keep="$s/common-auth.first-backup"
    cp -a "$backup" "$keep"
    # Live file gone AND first backup unusable: rollback MUST retain the record.
    rm -f "$s/pam/common-auth" "$backup"
    cat > "$s/stub/mv" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        *cros-common-restore*) printf 'STUB: common restore mv refused\n' >&2; exit 1 ;;
    esac
done
exec /bin/mv "$@"
EOF
    chmod +x "$s/stub/mv"
    : > "$s/tool.log"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "1" "$(cat "$s/rollback.rc" 2> /dev/null || echo MISSING)" \
        "PAM-46: rollback rc 1 (missing backup keeps the record)"
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-46: disable rc 1 (surviving record is not skipped)"
    assert_eq "1" "$(python3 -c 'import json,sys; print(int(any(r.get("target")==sys.argv[2] for r in json.load(open(sys.argv[1])).get("records",[]))))' \
        "$s/manifest/install-manifest.json" "$s/pam/common-auth")" \
        "PAM-46: common-auth record still present in the manifest"
    assert_eq "0" "$(grep -cF 'debconf-set-selections' "$s/tool.log" || true)" \
        "PAM-46: zero debconf-set-selections calls while a record survives"
    assert_eq "0" "$(grep -cF -- '--package' "$s/tool.log" || true)" \
        "PAM-46: zero --package calls while a record survives"
    assert_eq "$halves" "$(pam_all_halves_hex "$s")" \
        "PAM-46: all three snapshots intact for retry"
    assert_contains "Manifest still records $s/pam/common-auth" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-46: surviving missing-file record is explicitly named"

    # Repair the original backup and remove the injected fault; only NOW may
    # the retry consume the snapshots.
    mkdir -p "$(dirname "$backup")"
    cp -a "$keep" "$backup"
    rm -f "$s/stub/mv"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-46: retry succeeds after the backup is repaired"
    assert_eq "0" "$(pam_record_count "$s")" "PAM-46: all records consumed on retry"
    if [ ! -e "$s/manifest/pam-selection" ] && [ ! -e "$s/manifest/pam-selection.saved" ] \
        && [ ! -e "$s/manifest/pam-selection.common" ]; then
        ok
    else
        fail "PAM-46: snapshots consumed only after the fully verified retry"
    fi
}

# PAM-47: disable_pam_fingerprint propagates the probe rc (1 = surviving
# record, 2 = untrustworthy manifest) instead of downgrading to a warning.
test_pam_47_disable_propagates_probe_rc() {
    local s
    s="$(setup_pam_sandbox disable-probe-rc)"
    pam_install_for_restore_test "$s"
    python3 - "$s/manifest/install-manifest.json" "$s/pam/common-auth" << 'PY'
import json, sys
mp, target = sys.argv[1:3]
d = json.load(open(mp))
d["records"].append({"target": target, "component": "fingerprint",
                     "was_existing": True})
json.dump(d, open(mp, "w"), indent=2)
PY
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_sandboxed "$s" '
            export PATH="$2/stub:/usr/bin:/bin"
            export STUB_SED_LOG="$2/sed.log" STUB_TOOL_LOG="$2/tool.log"
            export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
            export STUB_DEBCONF_SEEN="$2/debconf/seen"
            source "$1/lib/pam.sh"
            disable_pam_fingerprint
            printf "%s\n" "$?" > "$2/rc"
        '
    assert_eq "1" "$(cat "$s/rc" 2> /dev/null || echo MISSING)" \
        "PAM-47: surviving common-auth record -> disable rc 1"

    s="$(setup_pam_sandbox disable-corrupt-manifest)"
    printf '{not-json' > "$s/manifest/install-manifest.json"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_sandboxed "$s" '
            export PATH="$2/stub:/usr/bin:/bin"
            source "$1/lib/pam.sh"
            disable_pam_fingerprint
            printf "%s\n" "$?" > "$2/rc"
        '
    assert_eq "2" "$(cat "$s/rc" 2> /dev/null || echo MISSING)" \
        "PAM-47: manifest corrupt -> disable rc 2 (not 0/1)"
    assert_eq "" "$(cat "$s/tool.log" 2> /dev/null || echo '')" \
        "PAM-47: corrupt manifest never triggers a tool call"
}

# PAM-48: a legacy sidecar with a missing .saved may NOT be repaired from a
# populated (possibly modified) live savedir; an EMPTY live savedir remains a
# legal absent case (PAM-41 compatibility).
test_pam_48_legacy_missing_saved_fail_closed() {
    local s modified_before auth_hex
    s="$(setup_pam_sandbox legacy-missing-saved-modified)"
    pam_install_for_restore_test "$s"
    sed -e '/^# cros-enablement: selection-seen=/d' \
        -e '/^# cros-enablement: saved-snapshot=/d' \
        "$s/manifest/pam-selection" > "$s/manifest/pam-selection.legacy"
    cat "$s/manifest/pam-selection.legacy" > "$s/manifest/pam-selection"
    rm -f "$s/manifest/pam-selection.legacy"
    rm -rf "$s/manifest/pam-selection.saved"
    printf 'ADMIN-MODIFIED\n' >> "$s/savedir/auth"
    auth_hex="$(file_hex "$s/savedir/auth")"
    modified_before="$(pam_common_state "$s")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "1" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-48: populated live savedir without .saved is a hard failure"
    assert_eq "$auth_hex" "$(file_hex "$s/savedir/auth")" \
        "PAM-48: modified live savedir file untouched"
    assert_eq "$modified_before" "$(pam_common_state "$s")" \
        "PAM-48: no PAM file mutation after failed first-wins"
    [ -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-48: sidecar retained on fail-closed repair"
    if [ -e "$s/manifest/pam-selection.saved" ]; then
        fail "PAM-48: no .saved may be invented from live state"
    else
        ok
    fi
    assert_contains "manual recovery required" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-48: fail-closed reason logged"

    # Empty live savedir is explicitly compatible (the old empty .saved case).
    s="$(setup_pam_sandbox legacy-missing-saved-empty)"
    pam_install_for_restore_test "$s"
    sed -e '/^# cros-enablement: selection-seen=/d' \
        -e '/^# cros-enablement: saved-snapshot=/d' \
        "$s/manifest/pam-selection" > "$s/manifest/pam-selection.legacy"
    cat "$s/manifest/pam-selection.legacy" > "$s/manifest/pam-selection"
    rm -f "$s/manifest/pam-selection.legacy"
    rm -rf "$s/manifest/pam-selection.saved"
    rm -f "$s/savedir"/*
    pam_noop_package_tool "$s"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-48/empty: empty live savedir keeps legacy compatibility"
    assert_contains "treating it as saved-snapshot=absent" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-48/empty: absent classification logged"
}

# PAM-49: a REAL uid-1000 caller must probe a root-only live savedir through
# sudo (plain `[ -f ]` silently misses it), and still reject extra live files.
test_pam_49_root_only_savedir_nonroot() {
    local s before
    s="$(setup_pam_sandbox root-only-savedir)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    before="$(pam_stack_fingerprint "$s")"
    _pam_nonroot_prepare "$s"
    _pam_nonroot_script "$s" install
    _pam_nonroot_script "$s" uninstall
    chmod 0700 "$s/savedir"
    chmod 0600 "$s/savedir"/*

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install_nonroot "$s" debian
    assert_eq "0" "$(cat "$s/userout/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-49: non-root install with a root-only savedir rc 0"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall_nonroot "$s" debian
    assert_eq "0" "$(cat "$s/userout/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-49: non-root uninstall probes the root-only savedir via sudo"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-49: root-only savedir and PAM files restored byte-for-byte"

    # A file the snapshot never saw must still be rejected from the non-root
    # caller (the live-side existence probe must be privileged too).
    s="$(setup_pam_sandbox root-only-extra-live)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    _pam_nonroot_prepare "$s"
    _pam_nonroot_script "$s" install
    _pam_nonroot_script "$s" uninstall
    chmod 0700 "$s/savedir"
    chmod 0600 "$s/savedir"/*
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install_nonroot "$s" debian
    printf 'EXTRA\n' > "$s/savedir/extra.conf"
    chmod 0600 "$s/savedir/extra.conf"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall_nonroot "$s" debian
    assert_eq "1" "$(cat "$s/userout/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-49/extra: extra live saved file fails the non-root restore"
    [ -e "$s/manifest/pam-selection" ] \
        && ok || fail "PAM-49/extra: snapshots retained for retry"
}

# PAM-50: prove the exact ordering --package -> .common restore -> final
# verification -> consume with ONE shared marker log.
test_pam_50_tool_order_markers() {
    local s log
    s="$(setup_pam_sandbox tool-order-markers)"
    pam_install_for_restore_test "$s"
    cp "$s/stub/pam-auth-update" "$s/stub/pam-auth-update.orig"
    cat > "$s/stub/pam-auth-update" << 'EOF'
#!/usr/bin/env bash
"$(dirname "$0")/pam-auth-update.orig" "$@"
_rc=$?
printf 'MARK_EXTERNAL_PACKAGE_DONE %s\n' "$*" >> "${LOG_FILE:?}"
exit "$_rc"
EOF
    cat > "$s/stub/rm" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    if [ "$_a" = "${CROS_ENABLEMENT_PAM_SELECTION_FILE:-}" ]; then
        printf 'MARK_CONSUME_SIDECAR\n' >> "${LOG_FILE:?}"
    fi
done
exec /bin/rm "$@"
EOF
    chmod +x "$s/stub/pam-auth-update" "$s/stub/rm"
    : > "$s/log.txt"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-50: uninstall rc 0 with ordering markers"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "MARK_EXTERNAL_PACKAGE_DONE --package" "$log" \
        "PAM-50: external --package really ran and was marked"
    assert_contains "re-applying the original common/sudo state" "$log" \
        "PAM-50: .common restore marker present"
    assert_contains "Verified final common-*/sudo state" "$log" \
        "PAM-50: final verification marker present"
    assert_contains "MARK_CONSUME_SIDECAR" "$log" \
        "PAM-50: sidecar consume marker present"
    marker_line() {
        printf '%s\n' "$log" | grep -nF -- "$1" | head -n 1 | cut -d: -f1 \
            | tr -cd '0-9'
    }
    local l_package l_restore l_verify l_consume
    l_package="$(marker_line 'MARK_EXTERNAL_PACKAGE_DONE --package')"
    l_restore="$(marker_line 're-applying the original common/sudo state')"
    l_verify="$(marker_line 'Verified final common-*/sudo state')"
    l_consume="$(marker_line 'MARK_CONSUME_SIDECAR')"
    if [ -n "$l_package" ] && [ -n "$l_restore" ] && [ -n "$l_verify" ] \
        && [ -n "$l_consume" ] \
        && [ "$l_package" -lt "$l_restore" ] && [ "$l_restore" -lt "$l_verify" ] \
        && [ "$l_verify" -lt "$l_consume" ]; then
        ok
    else
        fail "PAM-50: --package($l_package) -> restore($l_restore) -> verify($l_verify) -> consume($l_consume) ordering violated"
    fi
}

# PAM-51: savedir directory metadata (0700) must survive restore; the old
# unconditional `install -d -m 755` destroyed it on every uninstall.
test_pam_51_savedir_mode_restored() {
    local s hook
    s="$(setup_pam_sandbox savedir-mode-0700)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    chmod 0700 "$s/savedir"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" "PAM-51: install rc 0"
    assert_contains 'savedir-mode=700' "$(cat "$s/manifest/pam-selection.common/state" 2> /dev/null || echo '')" \
        "PAM-51: .common records savedir mode 0700"

    # After manifest rollback, mutate the savedir mode before PAM disable.
    hook="$s/savedir-mode-hook.sh"
    printf '#!/usr/bin/env bash\nchmod 0755 "$1/savedir"\n' > "$hook"
    chmod +x "$hook"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian 0 "$hook"
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-51: disable rc 0 after savedir mode was tampered"
    assert_eq "700" "$(stat -c '%a' -- "$s/savedir")" \
        "PAM-51: savedir 0700 restored (not 0755)"
    assert_contains "Verified final common-*/sudo state" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-51: final metadata verification passed"
}

# PAM-52: a DANGLING common-* symlink must be rollback-tracked and restored as
# a symlink (the old `[ -f ]` backup gate skipped it entirely).
test_pam_52_dangling_common_symlink_tracked_and_restored() {
    local s target
    s="$(setup_pam_sandbox dangling-common-link)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    target="$s/pam/common-session-noninteractive.target-does-not-exist"
    rm -f "$s/pam/common-session-noninteractive"
    ln -s "$target" "$s/pam/common-session-noninteractive"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" "PAM-52: install rc 0"
    assert_eq "6" "$(pam_record_count "$s")" \
        "PAM-52: dangling symlink is rollback-tracked with the other five targets"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" "PAM-52: disable rc 0"
    [ -L "$s/pam/common-session-noninteractive" ] \
        && ok || fail "PAM-52: restored target is a symlink, not a regular file"
    assert_eq "$target" "$(readlink -- "$s/pam/common-session-noninteractive")" \
        "PAM-52: dangling symlink target preserved"
    assert_eq "0" "$(pam_record_count "$s")" "PAM-52: all records consumed"
}

# PAM-53: a whitespace-insensitive digest MUST still be order-sensitive. The
# real tool may canonicalise spacing (PAM-43), but swapping two MODULE lines is
# an admin edit: fail closed, keep all three halves, and name the reason.
test_pam_53_common_line_reorder_fails_closed() {
    local s halves hook
    s="$(setup_pam_sandbox common-auth-reorder)"
    pam_write_full_stack "$s"
    # Two fprintd-free lines survive install's direct strip; a line swap is
    # therefore a pure reorder, not an added/removed line.
    printf 'auth [success=1 default=ignore] pam_unix.so nullok\nauth requisite pam_deny.so\n' \
        > "$s/pam/common-auth"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-53: install rc 0"
    halves="$(pam_all_halves_hex "$s")"

    # Inject AFTER rollback: rollback_component would otherwise restore the
    # original bytes and erase the edit (same seam as PAM-17).
    cat > "$s/reorder.sh" << 'EOF'
#!/usr/bin/env bash
/usr/bin/python3 - "$1/pam/common-auth" <<'PY'
import sys
p = sys.argv[1]
with open(p) as fh:
    lines = fh.readlines()
if len(lines) >= 2:
    lines[0], lines[1] = lines[1], lines[0]
with open(p, 'w') as fh:
    fh.writelines(lines)
PY
EOF
    chmod +x "$s/reorder.sh"
    : > "$s/log.txt"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian 0 "$s/reorder.sh"
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-53: reordered common-auth fails closed (rc 1)"
    assert_eq "auth requisite pam_deny.so" "$(head -n 1 "$s/pam/common-auth")" \
        "PAM-53: the two MODULE lines really were swapped"
    assert_eq "$halves" "$(pam_all_halves_hex "$s")" \
        "PAM-53: all three halves retained byte-identically for manual recovery"
    assert_contains "External content change detected" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-53: external content change explicitly logged"
    assert_contains "reordered MODULE line" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-53: reorder named as the fail-closed reason"
}

# PAM-54: first-wins for the THIRD half. A foreign installer publishing
# .common while our stage exists must keep its bytes even though our mv loses
# the race and install fails. Existence is not ownership (reviewer P2-3).
test_pam_54_foreign_common_survives_failed_publish() {
    local s
    s="$(setup_pam_sandbox common-first-wins-race-regression)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    cat > "$s/stub/mv" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        *.common.stage.*)
            mkdir -p "${CROS_ENABLEMENT_PAM_SELECTION_FILE}.common/files"
            printf 'FOREIGN FIRST-WINS COPY\n' > "${CROS_ENABLEMENT_PAM_SELECTION_FILE}.common/state"
            printf 'STUB: a foreign installer published .common first\n' >&2
            exit 1
            ;;
    esac
done
exec /bin/mv "$@"
EOF
    chmod +x "$s/stub/mv"
    : > "$s/log.txt"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "1" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-54: install fails when our .common publish loses the race"
    assert_eq "FOREIGN FIRST-WINS COPY" \
        "$(cat "$s/manifest/pam-selection.common/state" 2> /dev/null || echo MISSING)" \
        "PAM-54: foreign .common/state bytes untouched"
    if [ -e "$s/manifest/pam-selection" ]; then
        fail "PAM-54: our failing install must still consume its own sidecar"
    else
        ok
    fi
    assert_contains "Could not publish the PAM common/sudo state snapshot" \
        "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-54: failed publish is explicit in the log"
}

# PAM-55: the PUBLISHED .common directory itself must be root:0700 -- the CI
# smoke gate stats the directory, not just files/ (0700) and state (0600).
# `install -d -m 700 -- "$stage/files"` used to leave the implicit $stage
# parent at the caller's umask (0755 under CI's umask 0022), so the mv -T
# published a 0755 .common (final re-review P1). Force umask 0022 to model CI.
test_pam_55_common_snapshot_dir_is_root_only_0700() {
    local s common
    s="$(setup_pam_sandbox common-dir-mode-0700)"
    common="$s/manifest/pam-selection.common"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    (
        umask 0022
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" \
            CROS_ENABLEMENT_PAM_DIR="$s/pam" run_pam_install "$s" debian
    )
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-55: install rc 0"
    assert_eq "700:0:0" "$(stat -c '%a:%u:%g' -- "$common" 2> /dev/null || echo MISSING)" \
        "PAM-55: published .common directory is root:0700 (CI stat contract)"
    assert_eq "700:0:0" "$(stat -c '%a:%u:%g' -- "$common/files" 2> /dev/null || echo MISSING)" \
        "PAM-55: .common/files is root:0700"
    assert_eq "600:0:0" "$(stat -c '%a:%u:%g' -- "$common/state" 2> /dev/null || echo MISSING)" \
        "PAM-55: .common/state is root:0600"
    assert_eq "600:0:0" "$(stat -c '%a:%u:%g' -- "$common/savedir.entries" 2> /dev/null || echo MISSING)" \
        "PAM-55: .common/savedir.entries is root:0600"
}

# PAM-56: a failure removing the THIRD half (.common) happens AFTER .saved was
# consumed, so it is NOT retryable -- the sidecar cannot bring back the saved
# bytes. The log must demand manual recovery instead of falsely claiming that
# all three halves stay retryable (final re-review P2). A retry must fail
# closed, never report a false success.
test_pam_56_common_consume_failure_is_manual_recovery() {
    local s state_hex log
    s="$(setup_pam_sandbox common-consume-fail)"
    pam_install_for_restore_test "$s"
    state_hex="$(file_hex "$s/manifest/pam-selection.common/state")"
    cat > "$s/stub/rm" << 'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    case "$_a" in
        *pam-selection.common*) printf 'STUB: rm .common refused\n' >&2; exit 1 ;;
    esac
done
exec /bin/rm "$@"
EOF
    chmod +x "$s/stub/rm"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-56: .common consume failure returns rc 1"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "manual recovery is REQUIRED" "$log" \
        "PAM-56: manual recovery is explicitly required"
    assert_contains "NOT retryable" "$log" \
        "PAM-56: log states this state is not retryable"
    assert_not_contains "stay retryable" "$log" \
        "PAM-56: no false claim that all halves stay retryable"
    assert_not_contains "snapshot consumed" "$log" \
        "PAM-56: no false success after a partial consume"
    if [ -e "$s/manifest/pam-selection" ] && [ -d "$s/manifest/pam-selection.common" ] \
        && [ ! -e "$s/manifest/pam-selection.saved" ]; then
        ok
    else
        fail "PAM-56: rebuilt sidecar + .common retained, .saved already consumed"
    fi
    assert_eq "$state_hex" "$(file_hex "$s/manifest/pam-selection.common/state")" \
        "PAM-56: original .common state bytes preserved"

    # With the fault removed, the rebuilt sidecar still says
    # saved-snapshot=complete while .saved is gone: this MUST fail closed.
    rm -f "$s/stub/rm"
    : > "$s/log.txt"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_neq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-56/retry: consumed .saved makes this state non-retryable"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "but it is missing; failing closed" "$log" \
        "PAM-56/retry: fail-closed reason is explicit"
    assert_eq "$state_hex" "$(file_hex "$s/manifest/pam-selection.common/state")" \
        "PAM-56/retry: .common bytes intact for manual recovery"
}

# PAM-57: behavioural NEGATIVE test for the final fail-closed gate itself.
# The existing PAM-43/50/51 cases only assert the SUCCESS log; a stealth
# mutation that keeps every probe and log_error but overwrites rc=0 just before
# the final `[ "$rc" -eq 0 ] || return 1` would still pass them. Call the
# verifier directly and demand rc=1 for bytes / mode / owner / link / absence /
# savedir metadata mismatches (final review P2).
test_pam_57_final_verify_rejects_common_and_savedir_mismatches() {
    local case_name s needle log
    for case_name in bytes mode owner link absent savedir_mode savedir_missing savedir_entries; do
        s="$(setup_pam_sandbox "final-verify-$case_name")"
        pam_write_full_stack "$s"
        pam_write_selection "$s" 'unix, systemd, fprintd'
        # Snapshot the CURRENT live state: install itself rewrites common-*, so
        # an install-time snapshot would legitimately mismatch before any
        # injected fault and make the control meaningless.
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            CROS_ENABLEMENT_PAM_SELECTION_FILE="$s/manifest/pam-selection" \
            CROS_ENABLEMENT_PAM_SAVED_DIR="$s/savedir" \
            run_sandboxed "$s" '
                export PATH="$2/stub:/usr/bin:/bin"
                export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
                source "$1/lib/pam.sh"
                rc=0
                _pam_snapshot_common_state || rc=$?
                printf "%s\n" "$rc" > "$2/snapshot.rc"
            '
        assert_eq "0" "$(cat "$s/snapshot.rc" 2> /dev/null || echo MISSING)" \
            "PAM-57/$case_name: live-state snapshot rc 0"

        # Control: the same call MUST pass on the untouched snapshot.
        : > "$s/log.txt"
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            CROS_ENABLEMENT_PAM_SELECTION_FILE="$s/manifest/pam-selection" \
            CROS_ENABLEMENT_PAM_SAVED_DIR="$s/savedir" \
            run_sandboxed "$s" '
                export PATH="$2/stub:/usr/bin:/bin"
                export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
                source "$1/lib/pam.sh"
                rc=0
                _pam_verify_common_targets_against_snapshot || rc=$?
                printf "%s\n" "$rc" > "$2/verify.rc"
            '
        assert_eq "0" "$(cat "$s/verify.rc" 2> /dev/null || echo MISSING)" \
            "PAM-57/$case_name: baseline verification rc 0"

        case "$case_name" in
            bytes) printf 'auth optional pam_permit.so\n' >> "$s/pam/common-auth" ;;
            mode) chmod 0600 "$s/pam/common-auth" ;;
            owner) chown 1000:1000 "$s/pam/common-auth" ;;
            link)
                rm -f "$s/pam/common-session"
                ln -s "$s/no-such-target" "$s/pam/common-session"
                ;;
            absent) rm -f "$s/pam/common-password" ;;
            savedir_mode) chmod 0700 "$s/savedir" ;;
            savedir_missing) rm -rf "$s/savedir" ;;
            savedir_entries) ln -s /tmp/pam-57-entry "$s/savedir/new-link" ;;
        esac
        case "$case_name" in
            savedir_entries) needle="Final savedir entry-set mismatch" ;;
            savedir_*) needle="Final savedir" ;;
            *) needle="Final PAM state mismatch" ;;
        esac

        : > "$s/log.txt"
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            CROS_ENABLEMENT_PAM_SELECTION_FILE="$s/manifest/pam-selection" \
            CROS_ENABLEMENT_PAM_SAVED_DIR="$s/savedir" \
            run_sandboxed "$s" '
                export PATH="$2/stub:/usr/bin:/bin"
                export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
                source "$1/lib/pam.sh"
                rc=0
                _pam_verify_common_targets_against_snapshot || rc=$?
                printf "%s\n" "$rc" > "$2/verify.rc"
            '
        assert_eq "1" "$(cat "$s/verify.rc" 2> /dev/null || echo MISSING)" \
            "PAM-57/$case_name: final verification fails closed (rc 1)"
        log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
        assert_contains "$needle" "$log" \
            "PAM-57/$case_name: mismatch reason logged"
        assert_not_contains "Verified final common-*/sudo state" "$log" \
            "PAM-57/$case_name: no success log after a mismatch"
    done
}

# Independent root-side oracle. tests/pam_rule_oracle.py is a standalone Python
# parser: it NEVER sources lib/pam.sh, so a fail-open mutation of the product's
# awk parser/sed cannot make the assertion vacuous. active-fp rc 0 = an active
# fp MODULE exists, 1 = none, 2 = unreadable/uncertain (never "safe").
_PAM_ORACLE="$REPO_ROOT/tests/pam_rule_oracle.py"
_pam_common_active_fp() {
    python3 "$_PAM_ORACLE" active-fp "$1"
}
_pam_oracle_nonfp() {
    python3 "$_PAM_ORACLE" nonfp "$1"
}
_pam_oracle_fp_lines() {
    python3 "$_PAM_ORACLE" fp-lines "$1"
}
_pam_oracle_expected() {
    python3 "$_PAM_ORACLE" strip "$1"
}
_pam_oracle_uncertain() {
    python3 "$_PAM_ORACLE" uncertain "$1"
}
_pam_oracle_landings() {
    python3 "$_PAM_ORACLE" landings "$1"
}

# PAM-58 (re-review #16 finding #2): a symlinked common-* with an ACTIVE
# pam_fprintd.so module must fail closed BEFORE any publication/mutation.
# The control uses identical bytes in a regular file and installs rc 0.
test_pam_58_symlinked_active_fp_fails_closed() {
    local s control before stack_before state_before log

    # Control: same content, regular file -> strip succeeds, install rc 0.
    control="$(setup_pam_sandbox symlink-fp-control)"
    pam_write_full_stack "$control"
    pam_write_selection "$control" 'unix, systemd, fprintd'
    CROS_ENABLEMENT_PAM_SUDO_PATH="$control/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$control/pam" \
        run_pam_install "$control" debian
    assert_eq "0" "$(cat "$control/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-58/control: identical bytes in a regular file install rc 0"
    if _pam_common_active_fp "$control/pam/common-auth"; then
        fail "PAM-58/control: no active fp module may remain after install"
    else
        ok
    fi

    # Symlink to a regular file WITH an active fp module: preflight must abort.
    s="$(setup_pam_sandbox symlink-fp-active)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    cp -a "$s/pam/common-auth" "$s/common-auth.target"
    ln -sfn "$s/common-auth.target" "$s/pam/common-auth"
    before="$(pam_stack_fingerprint "$s")"
    state_before="$(pam_common_state "$s")"
    # Independent oracle: the seam really is a symlink and its target really
    # holds an active module (a vacuous test would pass without the bug).
    [ -L "$s/pam/common-auth" ] && ok || fail "PAM-58: fixture must be a symlink"
    if _pam_common_active_fp "$s/common-auth.target"; then
        ok
    else
        fail "PAM-58: fixture target must hold an active fp module"
    fi

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-58: symlinked active fp install fails closed"
    assert_eq "$state_before" "$(pam_common_state "$s")" \
        "PAM-58: PAM/common bytes, type, link target and mode unchanged"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-58: savedir and debconf selection bytes unchanged"
    assert_eq "0" "$(pam_record_count "$s")" \
        "PAM-58: no manifest record (no backup was taken)"
    assert_eq "" "$(cat "$s/sed.log" 2> /dev/null || echo MISSING)" \
        "PAM-58: no sed mutation"
    assert_eq "" "$(cat "$s/tool.log" 2> /dev/null || echo MISSING)" \
        "PAM-58: no pam-auth-update/debconf tool call"
    [ ! -e "$s/manifest/pam-selection" ] && ok \
        || fail "PAM-58: no first-wins sidecar may be published"
    [ ! -e "$s/manifest/pam-selection.saved" ] && ok \
        || fail "PAM-58: no saved-profile snapshot may be published"
    [ ! -e "$s/manifest/pam-selection.common" ] && ok \
        || fail "PAM-58: no common-state snapshot may be published"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "Symlinked" "$log" \
        "PAM-58: the symlink is named in the fail-closed reason"
    assert_contains "active pam_fprintd.so module line" "$log" \
        "PAM-58: the active-module reason is explicit"

    # Root-only common-* from a REAL uid-1000 caller: a non-privileged grep
    # would return rc 2 and (in the old code) be read as "no fp". The install
    # must still strip through sudo, and the root-side oracle proves it.
    s="$(setup_pam_sandbox root-only-common-fp)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    _pam_nonroot_prepare "$s"
    _pam_nonroot_script "$s" install
    _pam_nonroot_script "$s" uninstall
    chown 0:0 "$s/pam/common-auth"
    chmod 0600 "$s/pam/common-auth"
    before="$(pam_stack_fingerprint "$s")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install_nonroot "$s" debian
    assert_eq "0" "$(cat "$s/userout/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-58/root-only: a non-root caller strips root-only common-auth"
    if _pam_common_active_fp "$s/pam/common-auth"; then
        fail "PAM-58/root-only: active fp survived a non-privileged grep (fail-open)"
    else
        ok
    fi
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall_nonroot "$s" debian
    assert_eq "0" "$(cat "$s/userout/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-58/root-only: uninstall still restores the root-only file"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-58/root-only: full stack restored byte-for-byte"
}

# PAM-59: the installed-state postcondition is about the ACTUAL common-* files,
# not the sed return code and not the debconf selection string. A tool that
# re-injects an active module after our strip must make install non-zero while
# leaving every snapshot half intact for uninstall.
test_pam_59_installed_state_postcondition() {
    local s control log

    control="$(setup_pam_sandbox postcondition-control)"
    pam_write_full_stack "$control"
    pam_write_selection "$control" 'unix, systemd, fprintd'
    CROS_ENABLEMENT_PAM_SUDO_PATH="$control/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$control/pam" \
        run_pam_install "$control" debian 0 0 0
    assert_eq "0" "$(cat "$control/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-59/control: no re-injection -> install rc 0"
    if _pam_common_active_fp "$control/pam/common-auth"; then
        fail "PAM-59/control: no active fp module may remain"
    else
        ok
    fi

    s="$(setup_pam_sandbox postcondition-reinject)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian 0 0 1
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-59: re-injected fp module makes install non-zero"
    if _pam_common_active_fp "$s/pam/common-auth"; then
        ok
    else
        fail "PAM-59: the stub must really have re-injected the module"
    fi
    [ -f "$s/manifest/pam-selection" ] && ok \
        || fail "PAM-59: selection snapshot retained"
    [ -d "$s/manifest/pam-selection.saved" ] && ok \
        || fail "PAM-59: saved-profile snapshot retained"
    [ -f "$s/manifest/pam-selection.common/state" ] && ok \
        || fail "PAM-59: common-state snapshot retained"
    assert_contains "fprintd" "$(cat "$s/manifest/pam-selection" 2> /dev/null || echo MISSING)" \
        "PAM-59: the snapshot still records fprintd for uninstall restore"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "Post-install verification failed" "$log" \
        "PAM-59: postcondition failure is explicit"
    assert_contains "active pam_fprintd.so module remains" "$log" \
        "PAM-59: the offending actual file state is named"
}

# Call one lib/pam.sh function directly inside the PAM sandbox with every seam
# exported (used by the finding #4 unit tests, PAM-57 style).
run_pam_direct_fn() {
    local sandbox="$1" fn="$2"
    export CROS_ENABLEMENT_PAM_SUDO_PATH="$sandbox/pam/sudo"
    export CROS_ENABLEMENT_PAM_DIR="$sandbox/pam"
    export CROS_ENABLEMENT_PAM_SAVED_DIR="$sandbox/savedir"
    export CROS_ENABLEMENT_PAM_SELECTION_FILE="$sandbox/manifest/pam-selection"
    run_sandboxed "$sandbox" '
        export PATH="$2/stub:/usr/bin:/bin"
        export STUB_DEBCONF_PROFILES="$2/debconf/profiles"
        export STUB_DEBCONF_SEEN="$2/debconf/seen"
        source "$1/lib/pam.sh"
        rc=0
        "$3" || rc=$?
        printf "%s\n" "$rc" > "$2/direct.rc"
    ' "$fn"
}

# PAM-60 (re-review #16 finding #4): .common records a symlink's LSTAT owner.
# The old `rm + sudo ln -sfn` rebuilt the link root-owned, so the final owner
# probe failed closed for every non-root original link. Both a live target and
# a DANGLING link must come back byte-, type- and owner-identical, with no
# leftover .cros-common-restore.* stage file.
test_pam_60_symlink_owner_restored() {
    local variant s hook before state_before state_after target target_hex link_before
    for variant in valid dangling; do
        s="$(setup_pam_sandbox "symlink-owner-$variant")"
        pam_write_full_stack "$s"
        pam_write_selection "$s" 'unix, systemd'
        # A symlinked common-* with an ACTIVE fp module is rejected preflight
        # (PAM-58); make the fixture self-consistent first (PAM-44 style).
        /usr/bin/sed -i -e '/pam_fprintd\.so/d' -e '/^Module: fprintd$/d' "$s/savedir/auth"
        target="$s/common-auth.target"
        cp -a "$s/pam/common-auth" "$target"
        /usr/bin/sed -i '/pam_fprintd\.so/d' "$target"
        ln -sfn "$target" "$s/pam/common-auth"
        chown -h 65534:65534 "$s/pam/common-auth"
        if [ "$variant" = dangling ]; then
            ln -sfn "$s/no-such-target" "$s/pam/common-session"
            chown -h 65534:65534 "$s/pam/common-session"
        fi
        state_before="$(pam_common_state "$s")"
        target_hex="$(file_hex "$target")"
        link_before="$(readlink -- "$s/pam/common-auth")"

        # Replace the live link AFTER rollback so the restore really has to
        # rebuild it rather than taking the already-identical skip path.
        hook="$s/tamper-link.sh"
        if [ "$variant" = valid ]; then
            cat > "$hook" << 'EOF'
#!/usr/bin/env bash
rm -f "$1/pam/common-auth"
printf 'tampered by external actor\n' > "$1/pam/common-auth"
EOF
        else
            cat > "$hook" << 'EOF'
#!/usr/bin/env bash
rm -f "$1/pam/common-session"
ln -s "$1/wrong-target" "$1/pam/common-session"
chown -h 0:0 "$1/pam/common-session"
EOF
        fi
        chmod +x "$hook"

        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_install "$s" debian
        assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
            "PAM-60/$variant: install rc 0"
        assert_eq "65534:65534" \
            "$(awk -F '\t' '$1 == "common-auth" { print $6 }' \
                "$s/manifest/pam-selection.common/state" 2> /dev/null | tail -n 1)" \
            "PAM-60/$variant: .common records the LSTAT owner (not the target's)"
        assert_eq "$target_hex" "$(file_hex "$target")" \
            "PAM-60/$variant: symlink target bytes unchanged by install"

        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_uninstall "$s" debian 0 "$hook"
        assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
            "PAM-60/$variant: uninstall rc 0 with a non-root original owner"
        state_after="$(pam_common_state "$s")"
        assert_eq "$state_before" "$state_after" \
            "PAM-60/$variant: full lstat state (type/mode/owner/link/sha) restored"
        assert_eq "$link_before" "$(readlink -- "$s/pam/common-auth")" \
            "PAM-60/$variant: link target string unchanged"
        assert_eq "$target_hex" "$(file_hex "$target")" \
            "PAM-60/$variant: symlink target bytes unchanged by restore"
        assert_eq "65534:65534" "$(stat -c '%u:%g' -- "$s/pam/common-auth")" \
            "PAM-60/$variant: restored link itself is owned by 65534:65534"
        if [ "$variant" = dangling ]; then
            assert_eq "65534:65534" "$(stat -c '%u:%g' -- "$s/pam/common-session")" \
                "PAM-60/dangling: dangling link owner restored with chown -h"
        fi
        assert_eq "" "$(find "$s/pam" -name '*cros-common-restore*' -print)" \
            "PAM-60/$variant: no restore stage file left behind"
    done
}

# PAM-61 (finding #4): the savedir ENTRY SET is part of the snapshot. A tool
# that adds a file/dir/symlink to an originally EMPTY savedir (or changes a
# populated one) must fail closed and keep all three halves. A legacy .common
# without savedir-entries stays warn-only (PAM-25/41/48 compatibility).
test_pam_61_savedir_entry_set_fail_closed() {
    local s state halves hook log

    # (a) originally empty savedir + tool-added DIRECTORY and SYMLINK.
    s="$(setup_pam_sandbox savedir-entries-empty-add)"
    pam_write_initial_files "$s" none none
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-61/empty: install rc 0"
    state="$(cat "$s/manifest/pam-selection.common/state" 2> /dev/null || echo MISSING)"
    assert_contains 'savedir-entries=empty:0:' "$state" \
        "PAM-61/empty: empty entry set is recorded in .common/state"
    assert_eq "600:0:0" \
        "$(stat -c '%a:%u:%g' -- "$s/manifest/pam-selection.common/savedir.entries" 2> /dev/null || echo MISSING)" \
        "PAM-61/empty: .common/savedir.entries is root:0600"
    halves="$(pam_all_halves_hex "$s")"
    hook="$s/add-entries.sh"
    printf '#!/usr/bin/env bash\nmkdir -p "$1/savedir/newdir"\nln -s /tmp/pam-61-entry "$1/savedir/newlink"\n' > "$hook"
    chmod +x "$hook"
    : > "$s/log.txt"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian 0 "$hook"
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-61/empty: added dir+symlink fail closed (rc 1)"
    assert_eq "$halves" "$(pam_all_halves_hex "$s")" \
        "PAM-61/empty: all three halves retained byte-identically"
    assert_contains "Final savedir entry-set mismatch" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-61/empty: entry-set mismatch is named in the log"

    # (b) populated savedir + tool-added entry.
    s="$(setup_pam_sandbox savedir-entries-nonempty-add)"
    pam_install_for_restore_test "$s"
    state="$(cat "$s/manifest/pam-selection.common/state" 2> /dev/null || echo MISSING)"
    assert_contains 'savedir-entries=nonempty:5:' "$state" \
        "PAM-61/nonempty: all five saved profiles are recorded as entries"
    halves="$(pam_all_halves_hex "$s")"
    hook="$s/add-entry.sh"
    printf '#!/usr/bin/env bash\nmkdir -p "$1/savedir/extra.d"\nln -s /tmp/pam-61-extra "$1/savedir/extra.link"\n' > "$hook"
    chmod +x "$hook"
    : > "$s/log.txt"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian 0 "$hook"
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-61/nonempty-add: extra entry fails closed (rc 1)"
    assert_eq "$halves" "$(pam_all_halves_hex "$s")" \
        "PAM-61/nonempty-add: all three halves retained"
    assert_contains "Final savedir entry-set mismatch" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-61/nonempty-add: entry-set mismatch logged"

    # (c) populated savedir + tool-REMOVED entry (also caught before the byte
    # comparison so the fail is visible even for a non-profile entry).
    s="$(setup_pam_sandbox savedir-entries-nonempty-remove)"
    pam_install_for_restore_test "$s"
    halves="$(pam_all_halves_hex "$s")"
    # Remove the entry from INSIDE the restore's --package call: a removal
    # before disable would simply be repaired by _pam_restore_saved_dir_snapshot.
    cp -a "$s/stub/pam-auth-update" "$s/stub/pam-auth-update.orig"
    cat > "$s/stub/pam-auth-update" << EOF
#!/usr/bin/env bash
"$s/stub/pam-auth-update.orig" "\$@"
rm -f "\$CROS_ENABLEMENT_PAM_SAVED_DIR/auth"
EOF
    chmod +x "$s/stub/pam-auth-update"
    : > "$s/log.txt"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "1" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-61/nonempty-remove: removed entry fails closed (rc 1)"
    assert_eq "$halves" "$(pam_all_halves_hex "$s")" \
        "PAM-61/nonempty-remove: all three halves retained"
    assert_contains "Final savedir entry-set mismatch" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-61/nonempty-remove: entry-set mismatch logged"

    # (d) legacy .common (no savedir-entries line/file): WARN only, rc 0.
    s="$(setup_pam_sandbox savedir-entries-legacy)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    run_pam_direct_fn "$s" _pam_snapshot_common_state
    assert_eq "0" "$(cat "$s/direct.rc" 2> /dev/null || echo MISSING)" \
        "PAM-61/legacy: live-state snapshot rc 0"
    /usr/bin/sed -i '/savedir-entries=/d' "$s/manifest/pam-selection.common/state"
    rm -f "$s/manifest/pam-selection.common/savedir.entries"
    : > "$s/log.txt"
    run_pam_direct_fn "$s" _pam_verify_common_targets_against_snapshot
    assert_eq "0" "$(cat "$s/direct.rc" 2> /dev/null || echo MISSING)" \
        "PAM-61/legacy: missing entry-set manifest is warn-only"
    assert_contains "no savedir entry-set manifest" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-61/legacy: legacy degradation is explicit"

    # (e) a non-regular entry at SNAPSHOT time is refused: only -type f is
    # copied into .saved, so silently ignoring a symlink would be asymmetric.
    s="$(setup_pam_sandbox savedir-entries-install-nonregular)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    ln -s /tmp/pam-61-install-entry "$s/savedir/extra.link"
    : > "$s/log.txt"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "1" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-61/install-nonregular: symlink entry fails the snapshot gate"
    assert_contains "non-regular saved profile entry" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-61/install-nonregular: reason logged"
    [ ! -e "$s/manifest/pam-selection" ] && ok \
        || fail "PAM-61/install-nonregular: no sidecar published"
}

# PAM-63 (finding #4): a link restore must rename the stage with `mv -T`.
# With plain `mv -f`, a symlink-to-DIRECTORY destination makes mv follow the
# link and deposit the stage INSIDE that directory, leaving the original link
# untouched. Exercise _pam_restore_common_state_from_snapshot() directly so the
# symlink-to-dir case is not masked by an earlier manifest rollback.
test_pam_63_symlink_to_dir_restore_uses_mv_T() {
    local s dir target before
    s="$(setup_pam_sandbox symlink-to-dir-restore)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    dir="$s/pam/auth-target-dir"
    mkdir -p "$dir" "$s/pam/other-dir"
    printf 'inside the target directory\n' > "$dir/inside"
    rm -f "$s/pam/common-auth"
    ln -s "$dir" "$s/pam/common-auth"
    run_pam_direct_fn "$s" _pam_snapshot_common_state
    assert_eq "0" "$(cat "$s/direct.rc" 2> /dev/null || echo MISSING)" \
        "PAM-63: live symlink-to-dir snapshot rc 0"
    assert_contains $'common-auth\t' "$(grep 'common-auth' "$s/manifest/pam-selection.common/state" 2> /dev/null || echo MISSING)" \
        "PAM-63: common-auth recorded as a link target row"
    assert_contains $'\tlink\t' "$(grep 'common-auth' "$s/manifest/pam-selection.common/state" 2> /dev/null || echo MISSING)" \
        "PAM-63: snapshot type is 'link', not 'file'"

    # Point the live link somewhere else: the restore must replace the LINK.
    rm -f "$s/pam/common-auth"
    ln -s "$s/pam/other-dir" "$s/pam/common-auth"
    before="$(find "$dir" -mindepth 1 -maxdepth 1 -name '*cros-common-restore*' -print)"
    : > "$s/log.txt"
    run_pam_direct_fn "$s" _pam_restore_common_state_from_snapshot
    assert_eq "0" "$(cat "$s/direct.rc" 2> /dev/null || echo MISSING)" \
        "PAM-63: symlink-to-dir restore rc 0"
    assert_eq "$dir" "$(readlink -- "$s/pam/common-auth")" \
        "PAM-63: the symlink itself was replaced (not the directory contents)"
    assert_eq "$before" "$(find "$dir" -mindepth 1 -maxdepth 1 -name '*cros-common-restore*' -print)" \
        "PAM-63: no stage file created inside the symlink's target directory"
    assert_eq "" "$(find "$s/pam/other-dir" -mindepth 1 -maxdepth 1 -name '*cros-common-restore*' -print)" \
        "PAM-63: no stage file left in the replaced link's former target"
}

# PAM-62: a missing/failing pam-auth-update is still only a warning (rc 2/1).
# After a successful strip the install returns 0 even though the debconf
# selection still records fprintd, and uninstall still restores everything.
test_pam_62_converge_rc_compatibility() {
    local s mode before

    for mode in missing failing; do
        s="$(setup_pam_sandbox converge-$mode)"
        pam_write_full_stack "$s"
        pam_write_selection "$s" 'unix, systemd, fprintd'
        before="$(pam_stack_fingerprint "$s")"
        if [ "$mode" = missing ]; then
            mv "$s/stub/pam-auth-update" "$s/stub/pam-auth-update.off"
        else
            cat > "$s/stub/pam-auth-update" << 'EOF'
#!/usr/bin/env bash
printf 'pam-auth-update %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
exit 1
EOF
            chmod +x "$s/stub/pam-auth-update"
        fi
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_install "$s" debian
        assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
            "PAM-62/$mode: install rc 0 despite convergence rc"
        if _pam_common_active_fp "$s/pam/common-auth"; then
            fail "PAM-62/$mode: active fp must be stripped even without a working tool"
        else
            ok
        fi
        assert_contains "fprintd" "$(cat "$s/debconf/profiles" 2> /dev/null || echo MISSING)" \
            "PAM-62/$mode: a disabled-but-recorded selection is legal"
        [ -f "$s/manifest/pam-selection" ] && ok \
            || fail "PAM-62/$mode: snapshot kept for uninstall convergence"
        assert_contains "convergence returned rc" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
            "PAM-62/$mode: the convergence rc is classified and warned"
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_uninstall "$s" debian
        assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
            "PAM-62/$mode: uninstall rc 0"
        assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
            "PAM-62/$mode: full stack restored byte-for-byte"
    done
}

# PAM-64 (final re-review P1): a genuinely fresh install with NO live savedir
# and NO sidecar must publish all three halves with an ABSENT entry set. With
# allow_absent=1, find on a missing directory returns a valid zero-record
# buffer; classifying that as empty:0 used to break the 0:absent | 1:empty |
# 1:nonempty invariant, abort the snapshot and strand the whole install.
# PAM-41/no_savedir only reached this state AFTER a first install, whose
# sidecar short-circuits the second run before _pam_snapshot_common_state().
test_pam_64_fresh_install_without_savedir() {
    local s state log

    s="$(setup_pam_sandbox fresh-no-savedir)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    local before sel_before
    sel_before="$(pam_selection "$s")"
    # Fresh state: remove the whole directory and any pre-existing sidecar /
    # snapshots. Nothing may short-circuit the first-wins publication path.
    rm -rf "$s/savedir" "$s/manifest"/pam-selection*
    # Capture the oracle AFTER removing savedir: an absent savedir must stay
    # absent after uninstall (there are no profile bytes to restore).
    # pam_stack_fingerprint ends with a `-f` probe whose last iteration is
    # false for a missing savedir; `|| true` keeps the captured bytes valid.
    before="$(pam_stack_fingerprint "$s" || true)"
    [ ! -e "$s/savedir" ] && ok \
        || fail "PAM-64: the live savedir fixture was really removed"
    [ ! -e "$s/manifest/pam-selection" ] && ok \
        || fail "PAM-64: no sidecar before the fresh install"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-64: fresh install with no savedir/sidecar rc 0"
    [ -f "$s/manifest/pam-selection.common/state" ] && ok \
        || fail "PAM-64: .common/state published"

    # Independent oracle: read the manifest state DIRECTLY from the sandbox
    # (never through lib/pam.sh) and require the authoritative triplet.
    state="$(cat "$s/manifest/pam-selection.common/state" 2> /dev/null || echo MISSING)"
    assert_contains 'savedir-present=0' "$state" \
        "PAM-64: state records the absent live savedir"
    assert_contains 'savedir-entries=absent:0:-' "$state" \
        "PAM-64: state records absent:0:- (not empty:0)"
    assert_not_contains 'savedir-entries=empty:0' "$state" \
        "PAM-64: no empty entry-set classification"
    assert_eq "600:0:0" \
        "$(stat -c '%a:%u:%g' -- "$s/manifest/pam-selection.common/savedir.entries" 2> /dev/null || echo MISSING)" \
        "PAM-64: absent entry-set manifest is published root:0600"
    assert_eq "0" \
        "$(wc -c < "$s/manifest/pam-selection.common/savedir.entries" 2> /dev/null || echo MISSING)" \
        "PAM-64: absent entry-set manifest is empty"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_not_contains 'Inconsistent savedir snapshot' "$log" \
        "PAM-64: no inconsistent-snapshot refusal"

    : > "$s/tool.log"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-64: uninstall rc 0 with an absent savedir"
    assert_eq "$sel_before" "$(pam_selection "$s")" \
        "PAM-64: original selection restored"
    assert_eq "$before" "$(pam_stack_fingerprint "$s")" \
        "PAM-64: full stack restored byte-for-byte"
    [ ! -e "$s/manifest/pam-selection" ] && ok \
        || fail "PAM-64: sidecar consumed"
    [ ! -e "$s/manifest/pam-selection.common" ] && ok \
        || fail "PAM-64: .common consumed"
}

# ---------------------------------------------------------------------------
# Re-review #17 finding #1: PAM-aware parser regressions (PAM-65..76).
# Every case uses the INDEPENDENT Python oracle (never lib/pam.sh) both to prove
# positive detection (a real fp module exists / is gone) and negative byte
# preservation (unrelated auth rules survive byte-for-byte).
# ---------------------------------------------------------------------------

# PAM-65: a trailing inline comment mentioning pam_fprintd.so must NOT make a
# pam_unix.so rule a fingerprint rule (the original P1 blocker).
test_pam_65_inline_comment_is_not_a_module() {
    local s before expected actual log
    s="$(setup_pam_sandbox inline-comment)"
    pam_write_full_stack "$s"
    cat > "$s/pam/common-auth" << 'EOF'
auth sufficient pam_fprintd.so
auth required pam_unix.so nullok # fallback when pam_fprintd.so unavailable
EOF
    python3 "$_PAM_ORACLE" active-fp "$s/pam/common-auth" && ok \
        || fail "PAM-65: the fixture really has one active fp module"
    cp -a "$s/pam/common-auth" "$s/before"
    before="$(cat "$s/pam/common-auth")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-65: install rc 0 with an inline fp comment"
    if _pam_common_active_fp "$s/pam/common-auth"; then
        fail "PAM-65: the real fp module survived"
    else
        ok
    fi
    expected="$(_pam_oracle_expected "$s/before")"
    actual="$(cat "$s/pam/common-auth")"
    assert_eq "$expected" "$actual" \
        "PAM-65: the pam_unix rule with its inline comment is byte-identical"
    assert_contains "fallback when pam_fprintd.so unavailable" "$actual" \
        "PAM-65: the unrelated rule was not deleted"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "non-fp bytes verified byte-identical" "$log" \
        "PAM-65: T2 preservation is logged"
    assert_eq "$before" "$(cat "$s/before")" "PAM-65: fixture copy untouched"
}

# PAM-66: module ARGUMENTS that mention pam_fprintd.so are not a module path.
test_pam_66_module_args_are_not_a_module() {
    local s expected actual
    s="$(setup_pam_sandbox module-args)"
    pam_write_full_stack "$s"
    cat > "$s/pam/common-auth" << 'EOF'
auth sufficient pam_fprintd.so
auth required pam_unix.so use_first_pass pam_fprintd.so fallback
EOF
    cp -a "$s/pam/common-auth" "$s/before"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-66: install rc 0"
    expected="$(_pam_oracle_expected "$s/before")"
    actual="$(cat "$s/pam/common-auth")"
    assert_eq "$expected" "$actual" \
        "PAM-66: the argument-only mention survives byte-for-byte"
    assert_contains "use_first_pass pam_fprintd.so fallback" "$actual" \
        "PAM-66: module args were preserved"
    if _pam_common_active_fp "$s/pam/common-auth"; then
        fail "PAM-66: the real fp module survived"
    else
        ok
    fi
}

# PAM-67: absolute module path is a real fp rule; pure comments and inline
# comments on other rules are preserved in the same file.
test_pam_67_absolute_path_and_mixed_comments() {
    local s expected actual
    s="$(setup_pam_sandbox absolute-path)"
    pam_write_full_stack "$s"
    cat > "$s/pam/common-auth" << 'EOF'
# pam_fprintd.so is documented in this comment
auth [success=end default=ignore] /lib/security/pam_fprintd.so max-tries=1 timeout=10
auth required pam_unix.so nullok # pam_fprintd.so fallback
EOF
    cp -a "$s/pam/common-auth" "$s/before"
    assert_eq "2" "$(_pam_oracle_fp_lines "$s/before")" \
        "PAM-67: oracle locates the absolute-path fp rule at line 2"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-67: install rc 0"
    expected="$(_pam_oracle_expected "$s/before")"
    actual="$(cat "$s/pam/common-auth")"
    assert_eq "$expected" "$actual" \
        "PAM-67: only the absolute fp rule was removed"
    assert_contains "is documented in this comment" "$actual" \
        "PAM-67: the pure comment survived"
    assert_contains "pam_fprintd.so fallback" "$actual" \
        "PAM-67: the inline comment on pam_unix survived"
    if _pam_common_active_fp "$s/pam/common-auth"; then
        fail "PAM-67: absolute-path fp module survived"
    else
        ok
    fi
}

# PAM-68: bracketed control with multiple spaces/tabs is parsed as ONE field.
test_pam_68_extended_control_and_spaces() {
    local s expected actual
    s="$(setup_pam_sandbox extended-control)"
    pam_write_full_stack "$s"
    printf 'auth    [success=end   default=ignore]    pam_fprintd.so\n' \
        > "$s/pam/common-auth"
    printf 'auth\trequired\tpam_unix.so\t# pam_fprintd.so\n' \
        >> "$s/pam/common-auth"
    cp -a "$s/pam/common-auth" "$s/before"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-68: install rc 0"
    expected="$(_pam_oracle_expected "$s/before")"
    actual="$(cat "$s/pam/common-auth")"
    assert_eq "$expected" "$actual" \
        "PAM-68: bracketed control rule removed, spaced pam_unix rule preserved"
    assert_eq "$(printf 'auth\trequired\tpam_unix.so\t# pam_fprintd.so')" "$actual" \
        "PAM-68: tabs and inline comment are byte-identical"
}

# PAM-69: a backslash-continued fp rule is one logical rule; BOTH physical
# lines are removed by the single per-file sed call.
test_pam_69_continuation_rule() {
    local s expected actual
    s="$(setup_pam_sandbox continuation)"
    pam_write_full_stack "$s"
    cat > "$s/pam/common-auth" << 'EOF'
auth [success=end \
    default=ignore] pam_fprintd.so
auth required pam_unix.so nullok # pam_fprintd.so
EOF
    cp -a "$s/pam/common-auth" "$s/before"
    assert_eq "1" "$(_pam_oracle_fp_lines "$s/before")" \
        "PAM-69: oracle reports the continued rule at line 1"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-69: install rc 0"
    expected="$(_pam_oracle_expected "$s/before")"
    actual="$(cat "$s/pam/common-auth")"
    assert_eq "$expected" "$actual" \
        "PAM-69: exactly the two continued physical lines were removed"
    assert_eq "auth required pam_unix.so nullok # pam_fprintd.so" "$actual" \
        "PAM-69: the non-fp line survives byte-for-byte"
    assert_eq "1" "$(grep -cE '^-i -e 1,2d ' "$s/sed.log")" \
        "PAM-69: one sed -i call with the exact 1,2d range"
}

# PAM-70: uncertain syntax fails closed BEFORE any write (zero mutations).
test_pam_70_uncertain_fails_closed() {
    local s before sed_before log
    s="$(setup_pam_sandbox uncertain-fail-closed)"
    pam_write_full_stack "$s"
    cat > "$s/pam/common-auth" << 'EOF'
auth [success=1 default=ignore pam_fprintd.so
auth required pam_unix.so
EOF
    _pam_oracle_uncertain "$s/pam/common-auth" && ok \
        || fail "PAM-70: oracle must classify this fixture as uncertain"
    before="$(file_hex "$s/pam/common-auth")"
    sed_before="$(wc -l < "$s/sed.log")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-70: uncertain syntax makes install non-zero"
    assert_eq "$before" "$(file_hex "$s/pam/common-auth")" \
        "PAM-70: common-auth is byte-identical (zero writes)"
    assert_eq "$sed_before" "$(wc -l < "$s/sed.log")" \
        "PAM-70: no sed mutation at all"
    [ ! -e "$s/manifest/pam-selection" ] && ok \
        || fail "PAM-70: no sidecar may be published"
    [ ! -e "$s/manifest/pam-selection.saved" ] && ok \
        || fail "PAM-70: no saved-profile snapshot may be published"
    [ ! -e "$s/manifest/pam-selection.common" ] && ok \
        || fail "PAM-70: no common-state snapshot may be published"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "Uncertain PAM rule syntax" "$log" \
        "PAM-70: fail-closed reason is explicit"
}

# PAM-71: a custom (unmanaged) numeric-jump stack whose jump target would
# change identity after fp removal is rejected before any write. The control
# with the pam-auth-update marker is accepted (the tool rewrites its jumps).
test_pam_71_custom_jump_fails_closed() {
    local s control before sed_before log
    s="$(setup_pam_sandbox custom-jump)"
    pam_write_full_stack "$s"
    cat > "$s/pam/common-auth" << 'EOF'
auth [success=1 default=ignore] pam_unix.so nullok
auth sufficient pam_fprintd.so
auth required pam_deny.so
auth required pam_permit.so
EOF
    _pam_oracle_uncertain "$s/pam/common-auth" && ok \
        || fail "PAM-71: oracle must classify the custom jump stack as unsafe"
    before="$(file_hex "$s/pam/common-auth")"
    sed_before="$(wc -l < "$s/sed.log")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-71: custom jump stack fails closed"
    assert_eq "$before" "$(file_hex "$s/pam/common-auth")" \
        "PAM-71: original stack is byte-identical (recoverable, zero writes)"
    assert_eq "$sed_before" "$(wc -l < "$s/sed.log")" \
        "PAM-71: no sed mutation"
    [ ! -e "$s/manifest/pam-selection" ] && ok \
        || fail "PAM-71: no sidecar published for a custom stack"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "Uncertain PAM rule syntax" "$log" \
        "PAM-71: jump-target refusal is explicit"

    control="$(setup_pam_sandbox custom-jump-managed-control)"
    pam_write_full_stack "$control"
    # Phase A: use the standard Debian shape whose landing is stable. The
    # marker is present but NO LONGER disables the jump check.
    cat > "$control/pam/common-auth" << 'EOF'
auth sufficient pam_fprintd.so
auth [success=1 default=ignore] pam_unix.so nullok
auth required pam_deny.so
auth required pam_permit.so
# end of pam-auth-update config
EOF
    _pam_oracle_uncertain "$control/pam/common-auth" \
        && fail "PAM-71/control: managed stack must not be classified uncertain" \
        || ok
    assert_contains "auth:pam_permit.so" \
        "$(python3 "$_PAM_ORACLE" landings "$control/pam/common-auth")" \
        "PAM-71/control: baseline jump lands on pam_permit, not END"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$control/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$control/pam" \
        run_pam_install "$control" debian
    assert_eq "0" "$(cat "$control/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-71/control: managed stack installs rc 0"
    # Phase A P2: rc 0 alone is not enough -- the jump endpoint must still be
    # correct AFTER convergence.
    assert_contains "auth:pam_permit.so" \
        "$(python3 "$_PAM_ORACLE" landings "$control/pam/common-auth")" \
        "PAM-71/control: convergence kept the jump landing on pam_permit"
    assert_not_contains "END" \
        "$(python3 "$_PAM_ORACLE" landings "$control/pam/common-auth")" \
        "PAM-71/control: no jump drifted to END"
    assert_contains "jump endpoint is unchanged" \
        "$(cat "$control/log.txt" 2> /dev/null || echo '')" \
        "PAM-71/control: verified jump endpoints are claimed explicitly"
}

# PAM-72: with no fp rule at all, install must preserve every common-* byte.
test_pam_72_no_fp_bytes_preserved() {
    local s before after sed_after
    s="$(setup_pam_sandbox no-fp-preserve)"
    pam_write_initial_files "$s" none none
    pam_write_selection "$s" 'unix'
    cat > "$s/pam/common-auth" << 'EOF'
auth required pam_unix.so nullok
auth required pam_deny.so # pam_fprintd.so fallback documented
EOF
    before="$(file_hex "$s/pam/common-auth")"
    if _pam_common_active_fp "$s/pam/common-auth"; then
        fail "PAM-72: fixture must have no active fp module"
    else
        ok
    fi

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-72: install rc 0"
    after="$(file_hex "$s/pam/common-auth")"
    assert_eq "$before" "$after" "PAM-72: common-auth bytes are unchanged"
    sed_after="$(wc -l < "$s/sed.log")"
    assert_eq "2" "$sed_after" "PAM-72: only the two sudo sed calls ran"
    assert_eq "0" "$(grep -cE '^-i -e [0-9]+(,[0-9]+)?d ' "$s/sed.log")" \
        "PAM-72: no common-* line-deletion sed call"
    assert_contains "No pam_fprintd line" "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-72: nothing-to-strip path is logged"
}

# PAM-73: a symlinked common-* whose target has only an inline fp comment is
# allowed and left byte-identical (PAM-58 still rejects a real fp module).
test_pam_73_symlink_with_inline_comment_allowed() {
    local s target state_before target_hex log
    s="$(setup_pam_sandbox symlink-comment-ok)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, systemd, fprintd'
    cp -a "$s/pam/common-auth" "$s/target"
    python3 "$_PAM_ORACLE" strip "$s/target" > "$s/target.stripped"
    mv "$s/target.stripped" "$s/target"
    printf 'auth required pam_unix.so nullok # pam_fprintd.so fallback\n' \
        >> "$s/target"
    ln -sfn "$s/target" "$s/pam/common-auth"
    if _pam_common_active_fp "$s/target"; then
        fail "PAM-73: target must have no active fp module"
    else
        ok
    fi
    [ -L "$s/pam/common-auth" ] && ok || fail "PAM-73: fixture is a symlink"
    state_before="$(pam_common_state "$s")"
    target_hex="$(file_hex "$s/target")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-73: symlink with only a comment installs rc 0"
    assert_eq "$target_hex" "$(file_hex "$s/target")" \
        "PAM-73: symlink target bytes unchanged"
    [ -L "$s/pam/common-auth" ] && ok || fail "PAM-73: symlink was preserved"
    # sudo bytes legitimately change (the project line is installed); compare
    # the symlink row only.
    assert_eq "$(printf '%s\n' "$state_before" | grep '^common-auth')" \
        "$(pam_common_state "$s" | grep '^common-auth')" \
        "PAM-73: common-auth symlink lstat state unchanged"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_not_contains "Symlinked" "$log" \
        "PAM-73: no symlink refusal for a comment-only file"
}

# PAM-74: "immediately no fp" is NOT the same as "convergence verified". A
# failing tool keeps install rc 0 (PAM-16/62) but must log NOT verified and must
# not claim a later --package is a no-op.
test_pam_74_immediate_vs_converged() {
    local s control log
    s="$(setup_pam_sandbox immediate-not-verified)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, fprintd'
    cat > "$s/stub/pam-auth-update" << 'EOF'
#!/usr/bin/env bash
printf 'pam-auth-update %s\n' "$*" >> "${STUB_TOOL_LOG:?PAM tool stub missing log}"
exit 1
EOF
    chmod +x "$s/stub/pam-auth-update"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-74: failing convergence still returns install rc 0"
    if _pam_common_active_fp "$s/pam/common-auth"; then
        fail "PAM-74: immediate strip must still have removed the fp module"
    else
        ok
    fi
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "Immediate state check" "$log" \
        "PAM-74: immediate no-fp state is logged separately"
    assert_contains "NOT verified" "$log" \
        "PAM-74: convergence is explicitly NOT verified"
    assert_contains "convergence returned rc" "$log" \
        "PAM-74: the real rc is still classified/warned (PAM-62)"
    assert_not_contains "convergence verified (rc 0)" "$log" \
        "PAM-74: no false convergence claim"
    assert_not_contains "is a no-op" "$log" \
        "PAM-74: no claim that a later --package must be a no-op"

    control="$(setup_pam_sandbox immediate-converged)"
    pam_write_full_stack "$control"
    pam_write_selection "$control" 'unix, fprintd'
    CROS_ENABLEMENT_PAM_SUDO_PATH="$control/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$control/pam" \
        run_pam_install "$control" debian
    assert_eq "0" "$(cat "$control/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-74/control: working tool install rc 0"
    log="$(cat "$control/log.txt" 2> /dev/null || echo '')"
    assert_contains "convergence verified (rc 0)" "$log" \
        "PAM-74/control: successful convergence is logged as verified"
}

# PAM-75: the postcondition uses the module path, not the substring. Re-inject
# a comment-only mention -> pass; re-inject an absolute-path module -> fail.
test_pam_75_postcondition_module_path() {
    local s control log
    s="$(setup_pam_sandbox postcondition-comment-only)"
    pam_write_full_stack "$s"
    pam_write_selection "$s" 'unix, fprintd'
    cp -a "$s/stub/pam-auth-update" "$s/stub/pam-auth-update.orig"
    cat > "$s/stub/pam-auth-update" << EOF
#!/usr/bin/env bash
"$s/stub/pam-auth-update.orig" "\$@"
printf '%s\\n' 'auth required pam_unix.so nullok # pam_fprintd.so fallback' \\
    >> "\$CROS_ENABLEMENT_PAM_DIR/common-auth"
EOF
    chmod +x "$s/stub/pam-auth-update"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-75/comment: a comment-only re-injection must not fail the claim"
    if _pam_common_active_fp "$s/pam/common-auth"; then
        fail "PAM-75/comment: oracle must still report no active fp module"
    else
        ok
    fi
    assert_contains "Verified no active pam_fprintd.so" \
        "$(cat "$s/log.txt" 2> /dev/null || echo '')" \
        "PAM-75/comment: postcondition passed"

    control="$(setup_pam_sandbox postcondition-abs-fp)"
    pam_write_full_stack "$control"
    pam_write_selection "$control" 'unix, fprintd'
    cp -a "$control/stub/pam-auth-update" "$control/stub/pam-auth-update.orig"
    cat > "$control/stub/pam-auth-update" << EOF
#!/usr/bin/env bash
"$control/stub/pam-auth-update.orig" "\$@"
printf '%s\\n' 'auth sufficient /lib/security/pam_fprintd.so' \\
    >> "\$CROS_ENABLEMENT_PAM_DIR/common-auth"
EOF
    chmod +x "$control/stub/pam-auth-update"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$control/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$control/pam" \
        run_pam_install "$control" debian
    assert_neq "0" "$(cat "$control/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-75/absolute: re-injected absolute-path fp module fails the claim"
    if _pam_common_active_fp "$control/pam/common-auth"; then
        ok
    else
        fail "PAM-75/absolute: oracle must detect the re-injected module"
    fi
    log="$(cat "$control/log.txt" 2> /dev/null || echo '')"
    assert_contains "Post-install verification failed" "$log" \
        "PAM-75/absolute: postcondition failure is explicit"
    [ -f "$control/manifest/pam-selection" ] && ok \
        || fail "PAM-75/absolute: snapshots retained for uninstall"
}

# PAM-76: the sudo half has the same inline-comment false positive. Comment
# lines mentioning fprintd/rust_fp must survive; only real module lines go.
test_pam_76_sudo_inline_comment_survives() {
    local s before sed_after after
    s="$(setup_pam_sandbox sudo-inline-comment)"
    pam_write_initial_files "$s" none none
    cat > "$s/pam/sudo" << 'EOF'
# sudo PAM - comments mentioning modules are documentation
auth required pam_unix.so # pam_fprintd.so fallback
auth required pam_unix.so # legacy rust_fp.so module documented
auth sufficient pam_fprintd.so
@include common-auth
EOF
    before="$(file_hex "$s/pam/sudo")"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-76: install rc 0"
    sed_after="$(wc -l < "$s/sed.log")"
    assert_eq "2" "$sed_after" \
        "PAM-76: sudo still uses exactly 2 sed calls (PAM-2)"
    after="$(cat "$s/pam/sudo")"
    assert_contains "auth required pam_unix.so # pam_fprintd.so fallback" "$after" \
        "PAM-76: pam_unix rule with inline comment survived"
    assert_contains "auth required pam_unix.so # legacy rust_fp.so module documented" "$after" \
        "PAM-76: rust_fp inline comment survived"
    assert_eq "0" "$(grep -cFx -- 'auth sufficient pam_fprintd.so' "$s/pam/sudo")" \
        "PAM-76: the real fp module line was removed"
    assert_contains "auth sufficient pam_fprintd.so max-tries=1 timeout=10" "$after" \
        "PAM-76: the project line was inserted"

    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "0" "$(cat "$s/disable.rc" 2> /dev/null || echo MISSING)" \
        "PAM-76: uninstall rc 0"
    assert_eq "$before" "$(file_hex "$s/pam/sudo")" \
        "PAM-76: original sudo bytes restored byte-for-byte"
}

# PAM-77 (CI only, real pam-auth-update): see .github/workflows/install-smoke.yml
# "PAM-77 real-tool custom-stack guard".

# ---------------------------------------------------------------------------
# Re-review #17 Phase A: P1 control-flow fail-closed, P2 T2/T3/sudo/convergence
# regressions. Every assertion uses the independent oracle or raw sandbox
# bytes, never lib/pam.sh's own parser.
# ---------------------------------------------------------------------------

# PAM-78 (P1): a jump whose landing becomes END after fp removal must fail
# closed BEFORE any write, even on a pam-auth-update-managed stack.
test_pam_78_jump_to_end_fails_closed() {
    local s before sed_before log
    s="$(setup_pam_sandbox jump-to-end)"
    pam_write_full_stack "$s"
    # success=1 skips pam_deny.so and lands on pam_fprintd.so; removing fp
    # moves the landing to END -- control flow changes.
    cat > "$s/pam/common-auth" << 'EOF'
auth [success=1 default=ignore] pam_unix.so nullok
auth requisite pam_deny.so
auth sufficient pam_fprintd.so
# end of pam-auth-update config
EOF
    _pam_oracle_uncertain "$s/pam/common-auth" && ok \
        || fail "PAM-78: oracle must classify module->END as unsafe"
    before="$(file_hex "$s/pam/common-auth")"
    sed_before="$(wc -l < "$s/sed.log")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-78: landing->END fails closed on a managed stack"
    assert_eq "$before" "$(file_hex "$s/pam/common-auth")" \
        "PAM-78: stack bytes unchanged (zero writes)"
    assert_eq "$sed_before" "$(wc -l < "$s/sed.log")" \
        "PAM-78: no sed mutation"
    [ ! -e "$s/manifest/pam-selection" ] && ok \
        || fail "PAM-78: no sidecar published"
    [ ! -e "$s/manifest/pam-selection.common" ] && ok \
        || fail "PAM-78: no common-state snapshot published"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "numeric jump target identity changes" "$log" \
        "PAM-78: fail-closed reason is explicit"
}

# PAM-79 (P2/T2 sensitivity): corrupt sed must be caught by the byte-compare.
test_pam_79_t2_catches_corrupt_sed() {
    local s before log
    s="$(setup_pam_sandbox t2-corrupt-sed)"
    pam_write_full_stack "$s"
    before="$(file_hex "$s/pam/common-auth")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian 0 0 0 1 0
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-79: corrupt sed makes install non-zero"
    assert_eq "$before" "$(file_hex "$s/pam/common-auth")" \
        "PAM-79: original stack restored byte-for-byte"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "Non-fingerprint PAM bytes changed" "$log" \
        "PAM-79: T2 byte-compare named the reason"
    assert_contains "original bytes restored" "$log" \
        "PAM-79: safe restore is logged"
}

# PAM-80 (P2/T2): a change between parse and snapshot must fail closed BEFORE
# sed (drift guard), leaving the original file byte-identical.
test_pam_80_parse_snapshot_drift_fails_closed() {
    local s before sed_before log
    s="$(setup_pam_sandbox t2-drift)"
    pam_write_full_stack "$s"
    before="$(file_hex "$s/pam/common-auth")"
    sed_before="$(wc -l < "$s/sed.log")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian 0 0 0 0 1
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-80: parse->snapshot drift fails closed"
    # The injected drift line is external, so the file is NOT byte-identical;
    # what matters is that the product performed no strip and left the fp rule.
    assert_eq "1" "$(grep -cFx -- 'auth sufficient pam_fprintd.so' "$s/pam/common-auth")" \
        "PAM-80: the active fp rule was not stripped"
    assert_eq "$sed_before" "$(wc -l < "$s/sed.log")" \
        "PAM-80: no sed mutation at all"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "changed between PAM parse and snapshot" "$log" \
        "PAM-80: drift reason is explicit"
}

# PAM-81 (P2/T3): a non-fp rule removed and replaced by a rule with a different
# control/path can no longer hide behind the old `type:basename` key. The tool
# stub performs the rewrite during convergence so the postcondition sees it.
test_pam_81_t3_keyed_multiset() {
    local s log
    s="$(setup_pam_sandbox t3-keyed)"
    pam_write_full_stack "$s"
    cp -a "$s/stub/pam-auth-update" "$s/stub/pam-auth-update.orig"
    cat > "$s/stub/pam-auth-update" << EOF
#!/usr/bin/env bash
"$s/stub/pam-auth-update.orig" "\$@"
/usr/bin/python3 - "\$CROS_ENABLEMENT_PAM_DIR/common-auth" <<'PY'
import sys
p = sys.argv[1]
with open(p) as fh:
    lines = fh.readlines()
# Remove the baseline jump rule; insert a same-basename rule with a
# DIFFERENT control/path. The old subsequence check accepted this.
lines = [ln for ln in lines if 'pam_unix.so' not in ln]
lines.insert(0, 'auth required pam_unix.so\n')
with open(p, 'w') as fh:
    fh.writelines(lines)
PY
EOF
    chmod +x "$s/stub/pam-auth-update"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-81: modified non-fp rule is rejected"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "changed during convergence" "$log" \
        "PAM-81: T3 failure is explicit"
    [ -f "$s/manifest/pam-selection" ] && ok \
        || fail "PAM-81: snapshots retained for manual recovery"
}

# PAM-82 (P2/sudo): a continued fp module line in sudo is removed by the SAME
# parser (both physical lines), with exactly two sed calls and no residue.
test_pam_82_sudo_continuation_stripped() {
    local s before sed_after after
    s="$(setup_pam_sandbox sudo-continuation)"
    pam_write_initial_files "$s" none none
    cat > "$s/pam/sudo" << 'EOF'
# sudo PAM - continued stale fp module
auth sufficient pam_fprintd.so \
   max-tries=1
auth required pam_unix.so
@include common-auth
EOF
    before="$(file_hex "$s/pam/sudo")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-82: install rc 0"
    sed_after="$(wc -l < "$s/sed.log")"
    assert_eq "2" "$sed_after" "PAM-82: exactly two sudo sed calls (PAM-2)"
    after="$(cat "$s/pam/sudo")"
    assert_eq "0" "$(grep -cFx -- '   max-tries=1' "$s/pam/sudo")" \
        "PAM-82: orphan continuation argument line was removed too"
    assert_eq "0" "$(grep -cFx -- 'auth sufficient pam_fprintd.so' "$s/pam/sudo")" \
        "PAM-82: no stale fp module left in sudo"
    assert_contains "auth required pam_unix.so" "$after" \
        "PAM-82: unrelated sudo rule survived"
    assert_contains "auth sufficient pam_fprintd.so max-tries=1 timeout=10" "$after" \
        "PAM-82: project line inserted"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_uninstall "$s" debian
    assert_eq "$before" "$(file_hex "$s/pam/sudo")" \
        "PAM-82: original sudo bytes restored"
}

# PAM-83 (P2/sudo diagnostic): uncertain sudo syntax fails closed with zero
# writes; no orphan argument line may be left behind.
test_pam_83_sudo_uncertain_fails_closed() {
    local s before sed_before log
    s="$(setup_pam_sandbox sudo-uncertain)"
    pam_write_initial_files "$s" none none
    printf '# sudo PAM - unterminated continuation is uncertain\nauth sufficient pam_fprintd.so \\\n' \
        > "$s/pam/sudo"
    before="$(file_hex "$s/pam/sudo")"
    sed_before="$(wc -l < "$s/sed.log")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-83: uncertain sudo syntax fails closed"
    assert_eq "$before" "$(file_hex "$s/pam/sudo")" \
        "PAM-83: sudo bytes unchanged"
    assert_eq "$sed_before" "$(wc -l < "$s/sed.log")" \
        "PAM-83: no sudo sed mutation"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "Uncertain PAM rule syntax" "$log" \
        "PAM-83: fail-closed reason is explicit"
}

# PAM-84 (P2/T2, independent oracle): product strip output equals the oracle's
# byte-exact strip for a file with no trailing newline (P3 syntax alignment).
test_pam_84_no_trailing_newline_parity() {
    local s expected actual
    s="$(setup_pam_sandbox no-trailing-newline)"
    pam_write_full_stack "$s"
    printf 'auth sufficient pam_fprintd.so\nauth required pam_unix.so nullok' \
        > "$s/pam/common-auth"
    cp -a "$s/pam/common-auth" "$s/before"
    expected="$(python3 "$_PAM_ORACLE" strip "$s/before")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-84: install rc 0 without trailing newline"
    actual="$(cat "$s/pam/common-auth")"
    assert_eq "$expected" "$actual" \
        "PAM-84: product strip matches the independent oracle byte-for-byte"
}

# PAM-85 (P3): man7-legal -auth/-session type prefixes are parsed identically.
test_pam_85_negative_type_prefix_parity() {
    local s
    s="$(setup_pam_sandbox negative-type)"
    pam_write_full_stack "$s"
    cat > "$s/pam/common-auth" << 'EOF'
auth sufficient pam_fprintd.so
-auth required pam_unix.so nullok
-session optional pam_permit.so
auth requisite pam_deny.so
EOF
    cp -a "$s/pam/common-auth" "$s/before"
    _pam_oracle_uncertain "$s/pam/common-auth" \
        && fail "PAM-85: -auth/-session types must not be uncertain" || ok
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-85: install rc 0 with -auth/-session prefixes"
    assert_eq "$(python3 "$_PAM_ORACLE" strip "$s/before")" \
        "$(cat "$s/pam/common-auth")" \
        "PAM-85: only the fp line was removed"
}

# PAM-86 (P3): @include entries count as stack entries for jump arithmetic in
# both parsers; product and oracle must strip the same bytes.
test_pam_86_include_counts_in_jumps() {
    local s expected actual
    s="$(setup_pam_sandbox include-jump)"
    pam_write_full_stack "$s"
    cat > "$s/pam/common-auth" << 'EOF'
auth sufficient pam_fprintd.so
@include common-auth-extra
auth [success=1 default=ignore] pam_unix.so nullok
auth requisite pam_deny.so
auth required pam_permit.so
EOF
    cp -a "$s/pam/common-auth" "$s/before"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-86: install rc 0 with @include in the stack"
    expected="$(python3 "$_PAM_ORACLE" strip "$s/before")"
    actual="$(cat "$s/pam/common-auth")"
    assert_eq "$expected" "$actual" \
        "PAM-86: product and oracle agree on the stripped bytes"
}

# PAM-87 (P2/PAM-70/71 visibility): uncertain syntax and an unsafe jump both
# leave zero manifest records and an empty tool log.
test_pam_87_zero_write_visibility() {
    local s
    for mode in uncertain unsafe-jump; do
        s="$(setup_pam_sandbox "zero-write-$mode")"
        pam_write_full_stack "$s"
        if [ "$mode" = uncertain ]; then
            printf 'auth [success=1 default=ignore pam_fprintd.so\n' \
                > "$s/pam/common-auth"
        else
            printf 'auth [success=1 default=ignore] pam_unix.so nullok\nauth requisite pam_deny.so\nauth sufficient pam_fprintd.so\n' \
                > "$s/pam/common-auth"
        fi
        CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
            run_pam_install "$s" debian
        assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
            "PAM-87/$mode: install non-zero"
        assert_eq "0" "$(pam_record_count "$s")" \
            "PAM-87/$mode: zero manifest records"
        assert_eq "" "$(cat "$s/tool.log" 2> /dev/null || echo MISSING)" \
            "PAM-87/$mode: tool log stays empty"
    done
}

test_pam_1_preexisting_exact_line_survives
test_pam_2_preexisting_other_fp_lines_survive
test_pam_3_no_fp_line_roundtrip
test_pam_4_failed_rollback_keeps_record_and_warns
test_pam_5_unsupported_distro_no_sed
test_pam_6_dry_run_no_side_effects
test_pam_7_disable_body_has_no_sed
test_pam_8_all_common_files_tracked_and_converged
test_pam_9_fault_injection_does_not_leak_to_later_uninstall
test_pam_10_debian_selection_and_stack_restored
test_pam_11_explicit_selection_survives
test_pam_12_stub_removes_selection_control
test_pam_13_package_tool_derives_selection
test_pam_14_install_external_package_uninstall
test_pam_15_repeated_package_calls_are_noop
test_pam_16_missing_or_failing_tool_does_not_block
test_pam_17_diff_failure_still_restores_selection
test_pam_18_first_wins_snapshot
test_pam_19_nonroot_uninstall_reads_snapshots
test_pam_20_canonicalized_selection_consumes_sidecar
test_pam_21_different_selection_set_fails_closed
test_pam_22_seen_true_selection_roundtrip
test_pam_23_seen_false_selection_roundtrip
test_pam_24_empty_vs_absent_vs_seen_true
test_pam_25_legacy_sidecar_restores_value_only
test_pam_26_fset_failure_keeps_sidecar
test_pam_27_debconf_show_fallback
test_pam_28_process_rc_never_fails_open
test_pam_29_snapshot_faults_fail_closed
test_pam_30_existing_sidecar_validation
test_pam_31_saved_dir_restore_failures_keep_snapshot
test_pam_32_tool_failure_with_verified_state_succeeds
test_pam_33_retry_after_failed_restore_consumes_only_on_success
test_pam_34_restore_checks_rollback_completeness
test_pam_35_consume_failure_is_recoverable
test_pam_36_orphan_saved_snapshot_is_preserved
test_pam_37_seen_only_sidecar_fails_closed
test_pam_38_fget_failure_is_hard_failure
test_pam_39_savedir_bidirectional_and_empty_checks
test_pam_40_rebuild_failure_logs_critical
test_pam_41_legacy_sidecar_roundtrip
test_pam_42_orphan_saved_at_restore_fails
test_pam_43_tool_rewrite_restores_original_bytes_and_mode
test_pam_44_type_and_absence_variants
test_pam_45_common_restore_failure_keeps_all_halves
test_pam_46_missing_common_auth_surviving_record_fails_closed
test_pam_47_disable_propagates_probe_rc
test_pam_48_legacy_missing_saved_fail_closed
test_pam_49_root_only_savedir_nonroot
test_pam_50_tool_order_markers
test_pam_51_savedir_mode_restored
test_pam_52_dangling_common_symlink_tracked_and_restored
test_pam_53_common_line_reorder_fails_closed
test_pam_54_foreign_common_survives_failed_publish
test_pam_55_common_snapshot_dir_is_root_only_0700
test_pam_56_common_consume_failure_is_manual_recovery
test_pam_57_final_verify_rejects_common_and_savedir_mismatches
test_pam_58_symlinked_active_fp_fails_closed
test_pam_59_installed_state_postcondition
test_pam_60_symlink_owner_restored
test_pam_61_savedir_entry_set_fail_closed
test_pam_63_symlink_to_dir_restore_uses_mv_T
test_pam_62_converge_rc_compatibility
test_pam_64_fresh_install_without_savedir
test_pam_65_inline_comment_is_not_a_module
test_pam_66_module_args_are_not_a_module
test_pam_67_absolute_path_and_mixed_comments
test_pam_68_extended_control_and_spaces
test_pam_69_continuation_rule
test_pam_70_uncertain_fails_closed
test_pam_71_custom_jump_fails_closed
test_pam_72_no_fp_bytes_preserved
test_pam_73_symlink_with_inline_comment_allowed
test_pam_74_immediate_vs_converged
test_pam_75_postcondition_module_path
test_pam_76_sudo_inline_comment_survives
test_pam_78_jump_to_end_fails_closed
test_pam_79_t2_catches_corrupt_sed
test_pam_80_parse_snapshot_drift_fails_closed
test_pam_81_t3_keyed_multiset
test_pam_82_sudo_continuation_stripped
test_pam_83_sudo_uncertain_fails_closed
test_pam_84_no_trailing_newline_parity
test_pam_85_negative_type_prefix_parity
test_pam_86_include_counts_in_jumps
# PAM-88 (P2): a tool that shifts a numeric jump's landing AFTER the direct
# strip must fail the postcondition even though it only ADDED a non-fp rule
# (all baseline keys remain present). This pins the jump endpoint field of T3.
test_pam_88_convergence_jump_drift_fails_closed() {
    local s log before_landing after_landing
    s="$(setup_pam_sandbox convergence-jump-drift)"
    pam_write_full_stack "$s"
    before_landing="$(python3 "$_PAM_ORACLE" landings "$s/pam/common-auth")"
    assert_contains "auth:pam_permit.so" "$before_landing" \
        "PAM-88: baseline landing is pam_permit"
    cp -a "$s/stub/pam-auth-update" "$s/stub/pam-auth-update.orig"
    cat > "$s/stub/pam-auth-update" << EOF
#!/usr/bin/env bash
"$s/stub/pam-auth-update.orig" "\$@"
# The tool adds an innocent-looking rule BEFORE the jump source: success=1
# now skips pam_deny instead of reaching pam_permit.
/usr/bin/sed -i '2i auth required pam_admin_shift.so' "\$CROS_ENABLEMENT_PAM_DIR/common-auth"
EOF
    chmod +x "$s/stub/pam-auth-update"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-88: convergence jump drift fails closed"
    after_landing="$(python3 "$_PAM_ORACLE" landings "$s/pam/common-auth")"
    assert_contains "auth:pam_deny.so" "$after_landing" \
        "PAM-88: the tool really shifted the landing"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "jump endpoint changed" "$log" \
        "PAM-88: stale jump endpoint is named as the reason"
    [ -f "$s/manifest/pam-selection" ] && ok \
        || fail "PAM-88: snapshots retained for manual recovery"
}

# PAM-89 (P2/T3): a pure ORDER swap of two non-fp rules during convergence.
# Both swapped rules are after the numeric-jump landing, carry no jump of their
# own, and keep identical keyed descriptors, so the multiset (comm) check still
# passes. Only a monotonic cursor can reject the reorder. Mutation: removing
# the cursor (restoring the old used[] arbitrary pairing) makes this case fail.
test_pam_89_t3_order_matters() {
    local s log
    s="$(setup_pam_sandbox t3-order)"
    pam_write_full_stack "$s"
    # After the direct strip the stack is:
    #   unix(jump src) / deny(landing) / permit / echo / wheel
    # Swapping the last two changes no landing, so no descriptor changes.
    cat >> "$s/pam/common-auth" << 'EOF'
auth optional pam_echo.so
auth optional pam_wheel.so
EOF
    cp -a "$s/stub/pam-auth-update" "$s/stub/pam-auth-update.orig"
    cat > "$s/stub/pam-auth-update" << EOF
#!/usr/bin/env bash
"$s/stub/pam-auth-update.orig" "\$@"
/usr/bin/python3 - "\$CROS_ENABLEMENT_PAM_DIR/common-auth" <<'PY'
import sys
p = sys.argv[1]
with open(p) as fh:
    lines = fh.readlines()
i = next(i for i, ln in enumerate(lines) if 'pam_echo.so' in ln)
j = next(i for i, ln in enumerate(lines) if 'pam_wheel.so' in ln)
assert i != j
lines[i], lines[j] = lines[j], lines[i]
with open(p, 'w') as fh:
    fh.writelines(lines)
PY
EOF
    chmod +x "$s/stub/pam-auth-update"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-89: a pure non-fp rule reorder fails closed"
    # Raw-byte proof that the tool really swapped, without dropping a rule.
    assert_eq "auth optional pam_wheel.so" \
        "$(grep -F 'pam_wheel.so' "$s/pam/common-auth" | head -n 1)" \
        "PAM-89: the tool really moved pam_wheel ahead of pam_echo"
    assert_eq "auth optional pam_echo.so" \
        "$(grep -F 'pam_echo.so' "$s/pam/common-auth" | head -n 1)" \
        "PAM-89: pam_echo survived, so only the order changed"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "non-fp rule order changed" "$log" \
        "PAM-89: the order failure is named explicitly"
    [ -f "$s/manifest/pam-selection" ] && ok \
        || fail "PAM-89: snapshots retained for manual recovery"
}

# PAM-90 (P2/sudo fail-open): a pre-existing canonical project line must NOT
# skip the stale-fp verification. With a second, real pam_fprintd.so line in
# sudo, install must fail closed and leave the file untouched. Mutation:
# keeping _pam_verify_sudo_no_fp inside the else branch only -> rc 0 and this
# case fails.
test_pam_90_sudo_canonical_stale_fp_fails_closed() {
    local s c before sed_before log
    # Control: canonical line alone is still a valid, no-op install.
    c="$(setup_pam_sandbox sudo-canonical-control)"
    pam_write_initial_files "$c" exact none
    CROS_ENABLEMENT_PAM_SUDO_PATH="$c/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$c/pam" \
        run_pam_install "$c" debian
    assert_eq "0" "$(cat "$c/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-90/control: canonical-only sudo installs rc 0"
    assert_eq "0" "$(wc -l < "$c/sed.log")" \
        "PAM-90/control: no sudo sed mutation needed"

    s="$(setup_pam_sandbox sudo-canonical-stale-fp)"
    pam_write_initial_files "$s" none none
    cat > "$s/pam/sudo" << 'EOF'
# sudo PAM - canonical project line plus a stale fp module
auth sufficient pam_fprintd.so max-tries=1 timeout=10
auth sufficient pam_fprintd.so
@include common-auth
@include common-account
EOF
    before="$(file_hex "$s/pam/sudo")"
    sed_before="$(wc -l < "$s/sed.log")"
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_neq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-90: canonical line must not mask a stale fp module"
    assert_eq "$before" "$(file_hex "$s/pam/sudo")" \
        "PAM-90: sudo bytes unchanged (fail closed, no silent edit)"
    assert_eq "$sed_before" "$(wc -l < "$s/sed.log")" \
        "PAM-90: no sudo sed mutation"
    assert_eq "1" "$(grep -cFx -- 'auth sufficient pam_fprintd.so max-tries=1 timeout=10' "$s/pam/sudo")" \
        "PAM-90: canonical line survived"
    assert_eq "1" "$(grep -cFx -- 'auth sufficient pam_fprintd.so' "$s/pam/sudo")" \
        "PAM-90: stale fp line was NOT silently accepted"
    log="$(cat "$s/log.txt" 2> /dev/null || echo '')"
    assert_contains "already configured" "$log" \
        "PAM-90: the already-configured branch really ran"
    assert_contains "an active fingerprint module remains" "$log" \
        "PAM-90: the stale fp fail-closed reason is explicit"
}

test_pam_87_zero_write_visibility
test_pam_88_convergence_jump_drift_fails_closed
test_pam_89_t3_order_matters
test_pam_90_sudo_canonical_stale_fp_fails_closed

# PAM-91 (P3): END -> END is NOT a landing change. A stack whose numeric jump
# already lands on END both before and after fp removal must still install rc 0
# (P1 must not over-correct into rejecting a safe no-op).
test_pam_91_end_to_end_landing_accepted() {
    local s
    s="$(setup_pam_sandbox end-to-end-landing)"
    pam_write_initial_files "$s" none none
    cat > "$s/pam/common-auth" << 'EOF'
auth [success=1 default=ignore] pam_unix.so nullok
auth sufficient pam_fprintd.so
EOF
    _pam_oracle_uncertain "$s/pam/common-auth" \
        && fail "PAM-91: oracle must classify END->END as safe" || ok
    CROS_ENABLEMENT_PAM_SUDO_PATH="$s/pam/sudo" CROS_ENABLEMENT_PAM_DIR="$s/pam" \
        run_pam_install "$s" debian
    assert_eq "0" "$(cat "$s/install.rc" 2> /dev/null || echo MISSING)" \
        "PAM-91: an unchanged END landing installs rc 0"
    assert_eq "auth [success=1 default=ignore] pam_unix.so nullok" \
        "$(cat "$s/pam/common-auth")" \
        "PAM-91: only the fp line was removed"
    assert_eq "0" "$(grep -cF 'pam_fprintd.so' "$s/pam/common-auth")" \
        "PAM-91: no active fp module remains"
}
test_pam_91_end_to_end_landing_accepted

echo ""
echo "rollback tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
