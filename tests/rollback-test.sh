#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# tests/rollback-test.sh - Sandboxed tests for lib/backup.sh backup/rollback
# primitives (install plan backup, manifest schema 2.0, service & group
# restoration). Run as root or with passwordless sudo:
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

# Sandbox helper: run a backup.sh snippet with sandboxed dirs and an
# extended ALLOWED_PREFIXES so targets under the sandbox stay in scope.
run_sandboxed() {
    # $1=sandbox, remaining args passed to bash -c "$1" _ "$REPO_ROOT" "$sandbox" ...
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
        bash -c "$1" _ "$REPO_ROOT" "$sandbox" "${@:2}"
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
        # nobody is not a member of the (nonexistent) group -> gpasswd fails
        remove_group_membership "cros-testgrp" "nobody" "demo"
    '

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

block_group_manifest_write() {
    # Refuse ONLY manifest_add_group (argc=7, script mentions was_member).
    # argc=6 (manifest_remove_group / rollback) and argc=3 (validator) pass.
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
        remove_group_membership plugdev testuser keyboard || rc=$?
        printf "%s\n" "$rc" > "$2/remove-rc.txt"
        exit 0
    '
    assert_eq "0" "$(cat "$s2/helper-rc.txt" 2> /dev/null || echo MISSING)" \
        "T5: pre-existing member install succeeds"
    assert_eq "0" "$(usermod_calls "$s2/usermod.log")" "T5: pre-existing member is not usermod'ed"
    assert_eq "True" "$(grp_was_member "$mp2")" "T5: pre-existing member recorded as was_member=true"
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

    run_keyd_uninstall "$sandbox"

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
    assert_eq "0" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "absent target + no backup: rollback rc 0 (historical semantics)"
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
        ok
    else
        fail "absent target + no backup: must not invent a file"
    fi
    assert_eq "1" "$(manifest_count "$manifest" records)" \
        "absent target + no backup: record retained"
    assert_contains "[WARN NO BACKUP]" "$(cat "$sandbox/rollback.log")" \
        "absent target + no backup: warning emitted"
    assert_eq "0" "$(find "$sandbox/manifest" -name '*.tmp' | wc -l | tr -d '[:space:]')" \
        "absent target + no backup: no .tmp"
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
    # The suite runs under sudo: SUDO_USER is the real non-root caller, while
    # `id -un` would report root (which the production gate rejects).
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
    assert_eq "1" "$(cat "$sandbox/rollback-rc.txt" 2> /dev/null || echo MISSING)" \
        "user scope start failure: rc 1"
    assert_eq "1" "$(manifest_count "$manifest" services)" \
        "user scope start failure: record retained"
    assert_contains "SERVICE_RESTORE_FAILED name=fail.service action=--user start rc=1" \
        "$(cat "$sandbox/rollback.log")" "user scope start failure: marker"
    assert_contains "--user start fail.service" "$(cat "$sandbox/systemctl.log")" \
        "user scope start failure: --user start was attempted"
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
if [ -x "${STUB_DIR:?}/$cmd" ]; then
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

test_caller_uninstall_rollback_failure() {
    # $1=component $2=uninstall function $3=post-rollback marker
    # $4=log file holding the marker (caller.log or log.txt)
    local comp="$1" fn="$2" marker="$3" logfile="$4"
    local sandbox="/tmp/rollback-test-caller-$comp-fail"
    setup_caller_uninstall_sandbox "$sandbox" "$comp"
    run_caller_uninstall "$sandbox" "$comp" "$fn" 1

    assert_eq "1" "$(cat "$sandbox/uninstall-rc.txt" 2> /dev/null || echo MISSING)" \
        "[$comp] uninstall propagates rollback rc 1"
    assert_contains "$marker" "$(cat "$sandbox/$logfile" 2> /dev/null || echo "")" \
        "[$comp] post-rollback cleanup still ran"
    if [ "$comp" = "fingerprint" ] || [ "$comp" = "ec" ]; then
        assert_contains "group 'plugdev'" "$(cat "$sandbox/log.txt")" \
            "[$comp] post-rollback group-membership step ran"
    fi
    assert_contains "rollback of $comp failed" "$(cat "$sandbox/log.txt")" \
        "[$comp] rollback failure logged"
}

test_caller_uninstall_rollback_success() {
    # Same parameters: a successful rollback must keep rc 0 and still clean up.
    local comp="$1" fn="$2" marker="$3" logfile="$4"
    local sandbox="/tmp/rollback-test-caller-$comp-ok"
    setup_caller_uninstall_sandbox "$sandbox" "$comp"
    run_caller_uninstall "$sandbox" "$comp" "$fn" 0

    assert_eq "0" "$(cat "$sandbox/uninstall-rc.txt" 2> /dev/null || echo MISSING)" \
        "[$comp] successful rollback keeps uninstall rc 0"
    assert_contains "$marker" "$(cat "$sandbox/$logfile" 2> /dev/null || echo "")" \
        "[$comp] cleanup still runs after successful rollback"
    assert_contains "Rollback for component [$comp] finished!" "$(cat "$sandbox/log.txt")" \
        "[$comp] rollback success logged"
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
test_rollback_absent_target_was_existing_false_is_safe_noop
test_rollback_absent_target_restore_failure_keeps_record
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
test_caller_uninstall_rollback_failure fingerprint uninstall_fp "udevadm control --reload-rules" caller.log
test_caller_uninstall_rollback_failure ec uninstall_ec_tools "systemctl daemon-reload" caller.log
test_caller_uninstall_rollback_failure audio uninstall_audio "rmdir /usr/share/alsa/ucm2/conf.d/sof-rt5682" caller.log
test_caller_uninstall_rollback_failure power uninstall_power "Reboot (or log out and back in)" log.txt
test_caller_uninstall_rollback_success fingerprint uninstall_fp "udevadm control --reload-rules" caller.log
test_caller_uninstall_rollback_success ec uninstall_ec_tools "systemctl daemon-reload" caller.log
test_caller_uninstall_rollback_success audio uninstall_audio "rmdir /usr/share/alsa/ucm2/conf.d/sof-rt5682" caller.log
test_caller_uninstall_rollback_success power uninstall_power "Reboot (or log out and back in)" log.txt
test_caller_uninstall_regression_detects_unguarded_rollback

echo ""
echo "rollback tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
