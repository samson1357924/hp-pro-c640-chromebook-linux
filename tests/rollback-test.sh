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

# Sandbox helper: run a backup.sh snippet with sandboxed dirs and an
# extended ALLOWED_PREFIXES so targets under the sandbox stay in scope.
run_sandboxed() {
    # $1=sandbox, remaining args passed to bash -c "$1" _ "$REPO_ROOT" "$sandbox" ...
    local sandbox="$1"
    shift
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
# 13. keyboard backlight sync: install and rollback of daemon + udev + user service + sleep hook
# ---------------------------------------------------------------------------
test_kbd_backlight_sync_install() {
    local sandbox="/tmp/rollback-test-kbd-sync"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/backups" "$sandbox/manifest" "$sandbox/stub"
    mkdir -p "$sandbox/etc/udev/rules.d" "$sandbox/etc/systemd/user" "$sandbox/usr/local/bin" "$sandbox/usr/lib/systemd/system-sleep"

    # Stub systemctl to handle --global and --user queries (user service: --global cat succeeds)
    printf '#!/usr/bin/env bash\ncase "$*" in\n  *"--global cat"*) exit 0 ;;\n  *" cat "*) exit 1 ;;\n  *"--global is-enabled"*|*"--global is-active"*) exit 1 ;;\n  *"is-enabled"*|*"is-active"*) exit 1 ;;\n  *) exit 0 ;;\nesac\n' > "$sandbox/stub/systemctl"
    chmod +x "$sandbox/stub/systemctl"
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
    chmod +x "$sandbox/stub/systemctl"
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
    printf '#!/usr/bin/env bash\nexec "$@"\n' > "$sandbox/stub/sudo"

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
    *"is-enabled keyd"*) [ "${STUB_SVC_ENABLED:-1}" = "1" ] && exit 0 || exit 3 ;;
    *"is-active keyd"*) [ "${STUB_SVC_ACTIVE:-1}" = "1" ] && exit 0 || exit 3 ;;
esac
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
    if run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        install_keyd_step
    '; then
        return 0
    fi
    return 1
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

    # Also drive the REAL caller: it must set KEYD_DEPLOYED=0 and omit the
    # "keyd dual-role included" success line, while still finishing install.
    setup_keyd_restart_recoverable_sandbox "$caller_sandbox" "$existing"
    if ! run_sandboxed "$caller_sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_RESTART_FAIL_FIRST=1 STUB_RESTART_RETRY_FLAG="$2/retried" \
            WITH_KEYD=1
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        install_keyboard
        echo "${KEYD_DEPLOYED:-unset}" > "$2/keyd-deployed.txt"
    ' 2> "$caller_sandbox/caller.log"; then
        fail "restart failure: install_keyboard should still finish after a safe revert"
    fi
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
    # branch (only deploy cros.conf, do not enable/restart).
    if ! run_sandboxed "$sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        keyd_bin() { return 1; }
        install_keyd_step
    '; then
        fail "no-keyd: install_keyd_step should still deploy the config"
        return 0
    fi
    assert_eq "VALID_CROS_CONF" "$(cat "$sandbox/etc/keyd/cros.conf")" "no-keyd: cros.conf deployed"
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
        install_keyd_step
    ' 2> "$sandbox/step.log"; then
        fail "dry-run: install_keyd_step should succeed"
    fi
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
    if ! run_sandboxed "$caller_sandbox" '
        export DRY_RUN=1 WITH_KEYD=1 PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log"
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        install_keyboard
        echo "${KEYD_DEPLOYED:-unset}" > "$2/keyd-deployed.txt"
    ' 2> "$caller_sandbox/caller.log"; then
        fail "dry-run: install_keyboard should finish"
    fi
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

    # (b) The real caller (install_keyboard) sets KEYD_DEPLOYED=0 and does not
    # print the "keyd dual-role included" success line, but still completes the
    # non-keyd install steps.
    if ! run_sandboxed "$caller_sandbox" '
        export PATH="$2/stub:$PATH" STUB_SYSTEMCTL_LOG="$2/systemctl.log" \
            STUB_RESTART_FAIL_ALWAYS=1 WITH_KEYD=1
        source "$2/install-keyboard-sandbox.sh"
        get_real_user() { echo ""; }
        install_keyboard
        echo "${KEYD_DEPLOYED:-unset}" > "$2/keyd-deployed.txt"
    ' 2> "$caller_sandbox/caller.log"; then
        fail "unrecoverable restart: install_keyboard should still finish"
    fi
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
    find "$sandbox/snapshots" -mindepth 1 2> /dev/null | wc -l | tr -d '[:space:]'
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

test_uninstall_has_no_post_rollback_keyd_cleanup() {
    if grep -q 'Clean up legacy default.conf symlink' "$REPO_ROOT/keyboard/install-keyboard.sh"; then
        fail "uninstall must not delete default.conf after rollback_component"
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
test_uninstall_has_no_post_rollback_keyd_cleanup

echo ""
echo "rollback tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
