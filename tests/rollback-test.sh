#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
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

# Sandbox helper: run a backup.sh snippet with sandboxed dirs and an
# extended ALLOWED_PREFIXES so targets under the sandbox stay in scope.
run_sandboxed() {
    # $1=sandbox, remaining args passed to bash -c "$1" _ "$REPO_ROOT" "$sandbox" ...
    local sandbox="$1"
    shift
    CROS_ENABLEMENT_BACKUP_DIR="$sandbox/backups" \
        CROS_ENABLEMENT_MANIFEST_DIR="$sandbox/manifest" \
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
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/etc"

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
        source "$1/lib/backup.sh"
        rollback_component "demo"
    '

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

    printf '#!/usr/bin/env bash\ncase "$1" in\n  cat) exit 0 ;;\n  is-enabled|is-active) [ -e "${STUB_UNIT_STATE_FILE:-}" ] && exit 0 || exit 1 ;;\n  *) exit 0 ;;\nesac\n' > "$sandbox/stub/systemctl"
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

echo ""
echo "rollback tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
