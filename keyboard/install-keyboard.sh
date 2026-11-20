#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# keyboard/install-keyboard.sh - Independent Keyboard Top-Row Mapping & Backlight Sync Installer
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logger.sh
source "$ROOT_DIR/lib/logger.sh"
# shellcheck source=lib/distro.sh
source "$ROOT_DIR/lib/distro.sh"
# shellcheck source=lib/backup.sh
source "$ROOT_DIR/lib/backup.sh"
# shellcheck source=lib/syscheck.sh
source "$ROOT_DIR/lib/syscheck.sh"

HWDB_SRC="$SCRIPT_DIR/90-chromebook-keyboard.hwdb"
HWDB_DST="/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb"
UDEV_SRC="$SCRIPT_DIR/udev/61-chromeos-kbd-backlight.rules"
UDEV_DST="/etc/udev/rules.d/61-chromeos-kbd-backlight.rules"
DAEMON_SRC="$SCRIPT_DIR/c640-kbd-backlight-sync"
DAEMON_DST="/usr/local/bin/c640-kbd-backlight-sync"
SERVICE_SRC="$SCRIPT_DIR/systemd/c640-kbd-backlight-sync.service"
SERVICE_DST="/etc/systemd/user/c640-kbd-backlight-sync.service"
SLEEP_SRC="$SCRIPT_DIR/systemd/c640-kbd-backlight-sleep.sh"
SLEEP_DST="/usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh"
KEYD_SRC="$SCRIPT_DIR/keyd/cros.conf"
KEYD_DST="/etc/keyd/cros.conf"
KEYD_LINK="/etc/keyd/default.conf"

# Echo 1 when the manifest records $2 (optionally restricted to component $3)
# as a pre-existing target, otherwise 0. Centralises the JSON probing used by
# both install-time recovery and uninstall-time rollback preparation.
_manifest_was_existing() {
    local manifest="$1" target="$2" component="${3:-}"
    [ -f "$manifest" ] || { echo 0; return 0; }
    python3 - "$manifest" "$target" "$component" <<'PY' 2> /dev/null || echo 0
import json, sys

manifest, target, component = sys.argv[1:4]
try:
    for record in json.load(open(manifest)).get("records", []):
        if record.get("target") != target:
            continue
        if component and record.get("component") != component:
            continue
        print(1 if record.get("was_existing") else 0)
        break
except Exception:
    pass
PY
}

# Mirror lib/backup.sh rollback's lookup: the oldest backup matching
# "$BACKUP_BASE_DIR/*/<target without leading slash>". Used before creating
# any placeholder so we never leave behind a file that rollback cannot
# replace. Prints the backup path, or nothing when no backup exists.
_find_rollback_backup() {
    local target="$1"
    [ -n "$target" ] || return 0
    # shellcheck disable=SC2154 # BACKUP_BASE_DIR is defined in lib/backup.sh
    find "$BACKUP_BASE_DIR" -path "$BACKUP_BASE_DIR/*/${target#/}" -print 2> /dev/null \
        | LC_ALL=C sort | head -n 1 || true
}

# True when $1 (default: $KEYD_LINK) is a symlink pointing at keyd's cros.conf.
# Accepts relative spellings such as "cros.conf", "./cros.conf" and
# "../keyd/cros.conf" as well as absolute paths. Used by status check,
# uninstall service detection and install cleanup so the readlink comparison
# lives in exactly one place.
is_our_legacy_keyd_link() {
    local link="${1:-$KEYD_LINK}"
    [ -L "$link" ] || return 1
    local target target_abs expected resolved link_dir
    target="$(readlink "$link" 2> /dev/null || echo "")"
    [ -n "$target" ] || return 1
    case "$target" in
        /*) target_abs="$target" ;;
        *)
            link_dir="$(cd -P "$(dirname "$link")" 2> /dev/null && pwd)" || link_dir="$(dirname "$link")"
            target_abs="$link_dir/$target"
            ;;
    esac
    if ! resolved="$(readlink -m "$target_abs" 2> /dev/null)"; then
        log_warn "Could not canonicalize keyd symlink target '$target_abs'; legacy-link detection may be inaccurate"
        resolved="$target_abs"
    fi
    if ! expected="$(readlink -m "$KEYD_DST" 2> /dev/null)"; then
        log_warn "Could not canonicalize $KEYD_DST; legacy-link detection may be inaccurate"
        expected="$KEYD_DST"
    fi
    [ "$resolved" = "$expected" ]
}

# Restore our legacy default.conf symlink from its backup after a failed keyd
# restart, so the system is reverted to its full pre-install state (not just
# cros.conf). Uses the same manifest + backup semantics as rollback_component.
# Returns 0 when restored or when there was nothing to restore, 1 when a
# record existed but restoration could not be completed.
_restore_our_keyd_link_after_failed_restart() {
    local link_existed backup
    # shellcheck disable=SC2154 # MANIFEST_FILE is defined in lib/backup.sh
    link_existed="$(_manifest_was_existing "$MANIFEST_FILE" "$KEYD_LINK" "keyboard")"
    [ "$link_existed" = "1" ] || return 0

    if [ -e "$KEYD_LINK" ] || [ -L "$KEYD_LINK" ]; then
        log_warn "$KEYD_LINK already exists after failed restart; not overwriting it"
        return 0
    fi

    backup="$(_find_rollback_backup "$KEYD_LINK")"
    if [ -z "$backup" ] || { [ ! -e "$backup" ] && [ ! -L "$backup" ]; }; then
        log_warn "No backup found for $KEYD_LINK; legacy symlink will be restored (if possible) by uninstall rollback"
        return 1
    fi
    if sudo cp -a "$backup" "$KEYD_LINK" 2> /dev/null && [ -L "$KEYD_LINK" ]; then
        log_info "Restored legacy symlink $KEYD_LINK -> $(readlink "$KEYD_LINK" 2> /dev/null || echo '?') after failed restart"
        return 0
    fi
    # do not leave a partial/regular file behind
    sudo rm -f "$KEYD_LINK" 2> /dev/null || true
    log_warn "Could not restore legacy symlink $KEYD_LINK from $backup; uninstall rollback will retry"
    return 1
}

# Undo a failed keyd restart: put back the previous cros.conf (or remove the
# file we just created if there was none), recreate the legacy default.conf
# symlink when applicable, and try to restart the daemon once more so a
# running keyd is not left talking to an unvalidated config.
# Returns 2 when the pre-install state was fully restored AND the final restart
# succeeded (safe revert: the new dual-role config is NOT active), 1 when the
# recovery could not be completed, and 0 when no revert was needed (the new
# config is running normally). Callers MUST treat 2 like a failure: dual-role
# must never be reported as active after a revert.
_restore_keyd_after_failed_restart() {
    local existed=0 restored=0
    # shellcheck disable=SC2154 # MANIFEST_FILE is defined in lib/backup.sh
    existed="$(_manifest_was_existing "$MANIFEST_FILE" "$KEYD_DST")"

    if [ "$existed" = "1" ]; then
        local backup
        backup="$(_find_rollback_backup "$KEYD_DST")"
        if [ -n "$backup" ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
            if [ -L "$backup" ]; then
                # install(1) dereferences its source, so a backup that is a
                # symlink (e.g. NixOS / symlink farms) must be copied with
                # cp -a to preserve the link instead of leaving a regular file.
                if sudo cp -a "$backup" "$KEYD_DST" 2> /dev/null; then
                    restored=1
                    log_info "Restored previous keyd config symlink from $backup after failed restart"
                else
                    log_warn "Could not restore previous keyd config symlink from $backup after failed restart"
                fi
            elif sudo install -D -m 0644 "$backup" "$KEYD_DST" 2> /dev/null; then
                restored=1
                log_info "Restored previous keyd config from $backup after failed restart"
            else
                log_warn "Could not restore previous keyd config from $backup after failed restart"
            fi
        else
            log_warn "No backup found for $KEYD_DST; cannot restore previous keyd config"
        fi
    else
        if sudo rm -f "$KEYD_DST" 2> /dev/null; then
            restored=1
            log_info "Removed newly deployed $KEYD_DST after failed restart (no previous config)"
        else
            log_warn "Could not remove newly deployed $KEYD_DST after failed restart"
        fi
    fi

    if ! _restore_our_keyd_link_after_failed_restart; then
        restored=0
    fi

    if sudo systemctl restart keyd 2> /dev/null; then
        log_success "keyd restart succeeded after restoring previous config"
    else
        log_warn "keyd still failed to restart after restoring previous config; check 'journalctl -u keyd' manually"
        return 1
    fi
    if [ "$restored" -eq 1 ]; then
        # The system is back on its pre-install config, so the dual-role
        # config we just deployed is NOT active even though keyd now runs.
        return 2
    fi
    # A record existed but its restoration could not be completed.
    return 1
}

# lib/backup.sh only restores a pre-existing target when it still exists at
# rollback time. The installer removes our legacy default.conf symlink, so
# recreate a placeholder for that manifest record before rollback: rollback
# still performs the actual restoration, replacing the placeholder with the
# original symlink. A placeholder is created ONLY when a matching backup is
# actually present; otherwise rollback would keep the record ([NOTE] Left
# intact) and permanently leave a 0-byte regular file where the symlink was.
_prepare_keyd_link_for_rollback() {
    [ "${DRY_RUN:-0}" != "1" ] || return 0
    [ ! -e "$KEYD_LINK" ] && [ ! -L "$KEYD_LINK" ] || return 0
    # shellcheck disable=SC2154 # MANIFEST_FILE is defined in lib/backup.sh
    [ -f "$MANIFEST_FILE" ] || return 0
    local was_existing backup
    was_existing="$(_manifest_was_existing "$MANIFEST_FILE" "$KEYD_LINK" "keyboard")"
    [ "$was_existing" = "1" ] || return 0

    backup="$(_find_rollback_backup "$KEYD_LINK")"
    if [ -z "$backup" ] || { [ ! -e "$backup" ] && [ ! -L "$backup" ]; }; then
        log_warn "No backup found for $KEYD_LINK; cannot restore the original symlink on rollback, leaving no placeholder"
        return 0
    fi

    if sudo install -D -m 0644 /dev/null "$KEYD_LINK" 2> /dev/null; then
        log_info "Prepared placeholder at $KEYD_LINK so rollback can restore the original symlink"
    else
        log_warn "Could not prepare placeholder at $KEYD_LINK; rollback may not be able to restore the original symlink"
    fi
}

# Older (version 1.0) manifests can contain a record for $KEYD_LINK with no
# "component" field. backup_file_manifest_aware() keeps such a record on
# re-install (first-wins), so neither _prepare_keyd_link_for_rollback() nor
# rollback_component("keyboard") claims it and the symlink removed by the
# installer is never restored. Backfill the component BEFORE that call: the
# original backup and was_existing flag are left untouched, so first-wins
# semantics are preserved while the record becomes visible to the
# keyboard-scoped rollback helpers. Only records for $KEYD_LINK that have no
# (truthy) component are changed; every other record and field is preserved.
_normalize_keyd_link_manifest_component() {
    # The manifest path comes from lib/backup.sh.
    [ -f "$MANIFEST_FILE" ] || return 0

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Would backfill component=keyboard on legacy $KEYD_LINK manifest record (if present)"
        return 0
    fi
    if ! command -v python3 > /dev/null 2>&1; then
        log_warn "python3 not found; cannot backfill component on legacy $KEYD_LINK manifest record; rollback may not restore the original symlink"
        return 0
    fi

    local updated
    if ! updated="$(sudo python3 -c '
import json, sys, os

manifest_path, target, component = sys.argv[1:4]
try:
    with open(manifest_path) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

changed = 0
for record in data.get("records", []):
    if record.get("target") != target or record.get("component"):
        continue
    record["component"] = component
    changed += 1

if changed:
    tmp = manifest_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, manifest_path)
print(changed)
' "$MANIFEST_FILE" "$KEYD_LINK" "keyboard" 2> /dev/null)"; then
        log_warn "Failed to backfill component on legacy $KEYD_LINK manifest record; rollback may not restore the original symlink"
        return 0
    fi
    if [ "${updated:-0}" != "0" ]; then
        log_info "Backfilled component=keyboard on $updated legacy manifest record(s) for $KEYD_LINK"
    fi
}

# Single authority for the optional keyd step. Validation runs against the
# source file *before* any deployment so an invalid config can never break a
# running keyd daemon. Returns 1 when deployment was skipped, when deployment
# itself failed, or when the restart failed and recovery had to revert to the
# pre-install config (dual-role is not active in all of those cases).
install_keyd_step() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        backup_file_manifest_aware "$KEYD_DST" "keyboard"
        if is_our_legacy_keyd_link; then
            _normalize_keyd_link_manifest_component
            backup_file_manifest_aware "$KEYD_LINK" "keyboard"
            log_dryrun "Would remove redundant symlink $KEYD_LINK -> $(readlink "$KEYD_LINK" 2> /dev/null || echo "?")"
        fi
        log_dryrun "Would deploy keyd dual-role config"
        log_dryrun "Install -D -m 0644 $KEYD_SRC -> $KEYD_DST"
        log_dryrun "Would record service state: keyd (keyboard)"
        log_dryrun "keyd check (only >= 2.6) then systemctl enable keyd && systemctl restart keyd (if keyd installed)"
        return 0
    fi

    if [ ! -f "$KEYD_SRC" ]; then
        log_warn "keyd source not found at $KEYD_SRC, skipping"
        return 1
    fi

    local rc=0 keyd_cmd=""
    keyd_cmd="$(keyd_bin 2> /dev/null || true)"
    if [ -n "$keyd_cmd" ]; then
        keyd_check_config "$KEYD_SRC" || rc=$?
        # keyd_check_config() also returns 2 (keyd binary not found), but this
        # branch is only reached when $keyd_cmd is non-empty, so rc=2 is
        # unreachable here. It is kept in the failure group defensively; do
        # not read its presence as "the binary can disappear mid-check".
        case "$rc" in
            0) log_success "keyd config syntax valid ($KEYD_SRC)" ;;
            1 | 2)
                log_error "keyd config validation failed for $KEYD_SRC (rc=$rc): skipping deployment of $KEYD_DST and leaving the keyd service untouched. Fix the config and re-run with --with-keyd."
                return 1
                ;;
            3) log_info "keyd < 2.6 has no 'check' subcommand; relying on daemon reload" ;;
            *)
                log_error "keyd config check returned unexpected rc=$rc for $KEYD_SRC: skipping deployment of $KEYD_DST and leaving the keyd service untouched."
                return 1
                ;;
        esac
    else
        log_warn "keyd binary not found; cannot validate $KEYD_SRC. Deploying config only (no enable/restart). Install keyd for dual-role: sudo apt install keyd (Ubuntu>=25.04) or see keyboard/README.md"
    fi

    # Backups must be taken before the symlink is removed or cros.conf replaced.
    backup_file_manifest_aware "$KEYD_DST" "keyboard"
    if is_our_legacy_keyd_link; then
        local link_target
        link_target="$(readlink "$KEYD_LINK" 2> /dev/null || echo "")"
        _normalize_keyd_link_manifest_component
        backup_file_manifest_aware "$KEYD_LINK" "keyboard"
        sudo rm -f "$KEYD_LINK" 2> /dev/null || true
        log_info "Removed redundant symlink $KEYD_LINK -> $link_target"
    fi

    # Guard the deployment: under `set -e` an unguarded failure would abort
    # the installer before the pre-install keyd state could be restored.
    if ! sudo install -D -m 0644 "$KEYD_SRC" "$KEYD_DST"; then
        log_error "Failed to deploy $KEYD_DST; restoring previous keyd state"
        local recovery_rc=0
        _restore_keyd_after_failed_restart || recovery_rc=$?
        if [ "$recovery_rc" -eq 1 ]; then
            log_error "keyd config could not be restored after the install failure"
        else
            log_warn "keyd config reverted after install failure; dual-role NOT active"
        fi
        return 1
    fi
    manifest_add_service "keyd" "keyboard"

    if [ -z "$keyd_cmd" ]; then
        return 0
    fi

    if ! sudo systemctl enable keyd 2> /dev/null; then
        log_warn "Failed to enable keyd (try: sudo systemctl enable keyd)"
    fi
    if ! sudo systemctl restart keyd 2> /dev/null; then
        log_warn "Failed to restart keyd after deploying $KEYD_DST; restoring previous config and retrying"
        local recovery_rc=0
        # `|| rc=$?` records the real status: `if ! cmd` would only expose the
        # negated status (0) inside its then-branch. `set -e` is not triggered
        # by the left-hand side of `||`.
        _restore_keyd_after_failed_restart || recovery_rc=$?
        case "$recovery_rc" in
            0)
                # Defensive: the new config is running normally; no revert.
                ;;
            2)
                # The daemon was restarted, but on the ORIGINAL config. The
                # system is safe, yet dual-role is NOT deployed: the caller
                # runs us inside `if install_keyd_step` and sets
                # KEYD_DEPLOYED=0 from our failure status.
                log_warn "keyd config reverted after restart failure; dual-role NOT active"
                return 1
                ;;
            *)
                log_error "keyd restart could not be recovered; dual-role config is not active"
                return 1
                ;;
        esac
    fi

    # Recommend libinput quirk for GNOME Wayland
    if [ ! -f /etc/libinput/local-overrides.quirks ] || ! grep -q "keyd" /etc/libinput/local-overrides.quirks 2> /dev/null; then
        log_info "Tip: for GNOME Wayland trackpad, consider adding /etc/libinput/local-overrides.quirks (see keyboard/README.md)"
    fi
    return 0
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --install, -i      Install Chromebook top-row udev hwdb mapping + kbd backlight sync (default)"
    echo "  --with-keyd        Also install keyd advanced dual-role config (Search tap= CapsLock, hold=Super, Search+TopRow=F1-F10)"
    echo "  --keyd             Alias for --with-keyd"
    echo "  --check, -c        Check current keyboard hwdb and backlight sync status"
    echo "  --uninstall, -u    Uninstall top-row hwdb mapping and backlight sync (and keyd config if present)"
    echo "  --dry-run, -n      Preview changes without modifying files"
    echo "  --help, -h         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                              # hwdb + backlight"
    echo "  $0 --with-keyd                  # hwdb + backlight + keyd dual-role"
    echo "  $0 --with-keyd --dry-run        # preview all"
}

check_keyboard_status() {
    log_section "HP Pro c640 Keyboard Hardware & hwdb Status"
    check_dmi_board || true

    if [ -f "$HWDB_DST" ]; then
        log_success "Keyboard hwdb mapping is installed at $HWDB_DST."
    else
        log_warn "Keyboard hwdb mapping is NOT installed in /etc/udev/hwdb.d/."
    fi

    log_info "=== Keyboard Backlight Sync Status ==="
    if [ -f "$DAEMON_DST" ]; then
        log_success "Backlight daemon installed at $DAEMON_DST"
        if [ -x "$DAEMON_DST" ]; then
            "$DAEMON_DST" --check 2> /dev/null | sed 's/^/  /' || true
        fi
    else
        log_warn "Backlight daemon NOT installed at $DAEMON_DST"
    fi
    if [ -f "$UDEV_DST" ]; then
        log_success "Backlight udev rule installed at $UDEV_DST"
    else
        log_warn "Backlight udev rule NOT installed"
    fi
    if [ -f "$SERVICE_DST" ]; then
        log_success "Backlight user service installed at $SERVICE_DST"
        if systemctl --global is-enabled c640-kbd-backlight-sync.service > /dev/null 2>&1; then
            log_success "  User service is enabled (global)"
        else
            log_warn "  User service is NOT enabled (global)"
        fi
        local real_user
        real_user="$(get_real_user)"
        if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
            local uid
            uid="$(id -u "$real_user" 2> /dev/null || echo "")"
            if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
                if sudo -u "$real_user" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user is-active c640-kbd-backlight-sync.service > /dev/null 2>&1; then
                    log_success "  User service is active for $real_user"
                else
                    log_info "  User service not active for $real_user (will start on next graphical login)"
                fi
            fi
        fi
    else
        log_warn "Backlight user service NOT installed"
    fi
    if [ -f "$SLEEP_DST" ]; then
        log_success "Backlight sleep hook installed at $SLEEP_DST"
    else
        log_warn "Backlight sleep hook NOT installed"
    fi
    if [ -f "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
        local curr max
        curr="$(cat /sys/class/leds/chromeos::kbd_backlight/brightness 2> /dev/null || echo "?")"
        max="$(cat /sys/class/leds/chromeos::kbd_backlight/max_brightness 2> /dev/null || echo "?")"
        log_info "Current kbd backlight: $curr / $max"
        local led="/sys/class/leds/chromeos::kbd_backlight/brightness"
        local led_mode led_group
        led_mode="$(stat -c '%a' "$led" 2> /dev/null || echo "?")"
        led_group="$(stat -c '%G' "$led" 2> /dev/null || echo "?")"
        case "$led_mode" in
            66[04] | 66[26]) log_success "  backlight node writable by group $led_group (mode $led_mode)" ;;
            *) log_warn "  backlight node is $led_mode $led_group - udev chmod not applied yet (run: sudo udevadm trigger --subsystem-match=leds)" ;;
        esac
    else
        log_warn "No kbd backlight sysfs found (/sys/class/leds/chromeos::kbd_backlight)"
    fi

    log_info "=== keyd Advanced Dual-Role Status ==="
    if [ -f "$KEYD_DST" ] || [ -f "$KEYD_LINK" ] || [ -L "$KEYD_LINK" ]; then
        if [ -f "$KEYD_DST" ]; then
            log_success "keyd config installed at $KEYD_DST"
        fi
        if [ -L "$KEYD_LINK" ]; then
            local link_target
            link_target="$(readlink "$KEYD_LINK" 2> /dev/null || echo "?")"
            if is_our_legacy_keyd_link; then
                log_warn "  default.conf -> $link_target (redundant symlink; keyd loads all *.conf automatically)"
            else
                log_info "  default.conf -> $link_target"
            fi
            if [ ! -e "$KEYD_LINK" ]; then
                log_warn "  default.conf is dangling symlink (target missing)"
            fi
        elif [ -f "$KEYD_LINK" ]; then
            log_info "keyd default.conf exists at $KEYD_LINK"
        fi
        local keyd_cmd=""
        keyd_cmd="$(keyd_bin 2> /dev/null || true)"
        if [ -n "$keyd_cmd" ]; then
            log_info "  keyd binary: $keyd_cmd"
            log_info "  keyd version: $("$keyd_cmd" --version 2> /dev/null | head -n1 || echo "unknown")"
        else
            log_warn "  keyd binary not found (install with: sudo apt install keyd or see keyboard/README.md)"
        fi
        if systemctl is-active --quiet keyd 2> /dev/null; then
            log_success "  keyd service is active"
        elif systemctl is-enabled --quiet keyd 2> /dev/null; then
            log_warn "  keyd service is enabled but not active"
        else
            log_info "  keyd service not active (run: sudo systemctl enable --now keyd)"
        fi
        if [ -n "$keyd_cmd" ]; then
            local check_target="$KEYD_DST"
            [ -f "$check_target" ] || check_target="$KEYD_SRC"
            [ -f "$check_target" ] || check_target=""
            if [ -n "$check_target" ]; then
                local rc=0
                keyd_check_config "$check_target" || rc=$?
                case "$rc" in
                    0) log_success "  keyd config syntax valid ($check_target)" ;;
                    3) log_info "  keyd < 2.6 has no 'check' subcommand; syntax validated on daemon reload" ;;
                    *) log_warn "  keyd config syntax check failed for $check_target" ;;
                esac
            fi
        fi
    else
        log_info "keyd config not installed (optional, use --with-keyd to enable Search tap=CapsLock hold=Super)"
    fi
}

uninstall_keyboard() {
    log_section "Uninstalling Keyboard Top-Row hwdb Mapping & Backlight Sync"

    # Backfill the component on legacy (v1.0) KEYD_LINK records BEFORE any
    # rollback/placeholder decision. install_keyd_step() only normalizes while
    # the symlink is still present; an earlier install may already have removed
    # it, leaving a component-less record that neither
    # _prepare_keyd_link_for_rollback() nor rollback_component("keyboard") can
    # see. Doing it here is a no-op when no such record exists, and DRY_RUN
    # only logs, so no existing uninstall behaviour changes.
    _normalize_keyd_link_manifest_component

    # Disable user service before rollback (so manifest can capture state, but we also proactively disable)
    if [ "${DRY_RUN:-0}" != "1" ]; then
        local real_user
        real_user="$(get_real_user)"
        if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
            local uid
            uid="$(id -u "$real_user" 2> /dev/null || echo "")"
            if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
                sudo -u "$real_user" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user disable --now c640-kbd-backlight-sync.service 2> /dev/null || true
            fi
        fi
        sudo systemctl --global disable c640-kbd-backlight-sync.service 2> /dev/null || true
        # Also try system scope disable for backwards compat
        sudo systemctl disable c640-kbd-backlight-sync.service 2> /dev/null || true
        # Disable keyd if we installed it (system service) - handle legacy symlink too
        if systemctl is-active --quiet keyd 2> /dev/null || systemctl is-enabled --quiet keyd 2> /dev/null; then
            local keyd_ours=0
            if [ -f "$KEYD_DST" ]; then
                keyd_ours=1
            elif is_our_legacy_keyd_link; then
                keyd_ours=1
            fi
            if [ "$keyd_ours" = "1" ]; then
                sudo systemctl disable --now keyd 2> /dev/null || true
                log_info "Disabled keyd service (was managing Search dual-role)"
            fi
        fi
    else
        log_dryrun "Would disable user service: c640-kbd-backlight-sync.service (global + user)"
        log_dryrun "Would disable keyd if active and config present"
    fi

    # The installer deletes our legacy default.conf symlink; prepare the
    # manifest target so rollback can restore the original symlink. There is
    # deliberately no post-rollback deletion of default.conf here.
    _prepare_keyd_link_for_rollback
    rollback_component "keyboard"
    remove_group_membership "plugdev" "$(get_real_user)" "keyboard"

    if [ "${DRY_RUN:-0}" != "1" ]; then
        sudo systemd-hwdb update 2> /dev/null || true
        sudo udevadm control --reload-rules 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=input 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=leds 2> /dev/null || true
        sudo systemctl daemon-reload 2> /dev/null || true
        local real_user2
        real_user2="$(get_real_user)"
        if [ -n "$real_user2" ] && [ "$real_user2" != "root" ]; then
            local uid2
            uid2="$(id -u "$real_user2" 2> /dev/null || echo "")"
            if [ -n "$uid2" ] && [ -d "/run/user/$uid2" ]; then
                sudo -u "$real_user2" XDG_RUNTIME_DIR="/run/user/$uid2" systemctl --user daemon-reload 2> /dev/null || true
            fi
        fi
        log_info "Updated systemd-hwdb, udev and daemon-reload."

        # Restore kbd backlight if left at 0 (avoid dark after uninstall)
        if [ -f "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
            local curr max val
            curr="$(cat /sys/class/leds/chromeos::kbd_backlight/brightness 2> /dev/null || echo "?")"
            if [ "$curr" = "0" ]; then
                max="$(cat /sys/class/leds/chromeos::kbd_backlight/max_brightness 2> /dev/null || echo 100)"
                if ! [[ "$max" =~ ^[0-9]+$ ]] || [ "$max" -eq 0 ]; then
                    max=100
                fi
                val=$((max / 2))
                if [ -w "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
                    echo "$val" > /sys/class/leds/chromeos::kbd_backlight/brightness 2> /dev/null || true
                else
                    echo "$val" | sudo tee /sys/class/leds/chromeos::kbd_backlight/brightness > /dev/null 2>&1 || true
                fi
                log_info "Restored kbd backlight to $val/$max after uninstall."
            fi
        fi
        # Clean up state files
        sudo rm -f /run/c640-kbd-backlight/state 2> /dev/null || true
        sudo rmdir /run/c640-kbd-backlight 2> /dev/null || true
        local ru
        ru="$(get_real_user)"
        if [ -n "$ru" ] && [ "$ru" != "root" ]; then
            local ruid
            ruid="$(id -u "$ru" 2> /dev/null || echo "")"
            if [ -n "$ruid" ]; then
                sudo rm -f "/run/user/$ruid/c640-kbd-backlight.state" 2> /dev/null || true
                sudo rm -f "/run/user/$ruid/c640-kbd-backlight.lock" 2> /dev/null || true
                sudo rm -f "/run/user/$ruid/c640-kbd-backlight.state.lock" 2> /dev/null || true
                local kbd_tmpdir
                kbd_tmpdir="${TMPDIR:-/tmp}/c640-kbd-$ruid"
                if [ -n "$kbd_tmpdir" ] && [ "$kbd_tmpdir" != "/" ] && [ "$kbd_tmpdir" != "/tmp" ]; then
                    sudo rm -rf -- "$kbd_tmpdir" 2> /dev/null || true
                fi
            fi
        fi
        # Also clean fallback tmp for root
        local root_fallback
        root_fallback="/tmp/c640-kbd-0"
        if [ -n "$root_fallback" ] && [ "$root_fallback" != "/" ] && [ "$root_fallback" != "/tmp" ]; then
            sudo rm -rf -- "$root_fallback" 2> /dev/null || true
        fi
        local root_tmpdir
        root_tmpdir="${TMPDIR:-/tmp}/c640-kbd-$(id -u 2> /dev/null || echo 0)"
        if [ -n "$root_tmpdir" ] && [ "$root_tmpdir" != "/" ] && [ "$root_tmpdir" != "/tmp" ]; then
            sudo rm -rf -- "$root_tmpdir" 2> /dev/null || true
        fi
    else
        log_dryrun "Would run: systemd-hwdb update, udevadm trigger, daemon-reload, restore brightness, clean state"
        log_dryrun "Would clean: /run/c640-kbd-backlight/state, /run/user/\$UID/c640-kbd-backlight.state*, TMPDIR fallback"
    fi
    log_success "Keyboard mapping uninstallation completed."
}

install_keyboard() {
    log_section "Installing Chromebook Top-Row Function Keys Mapping & Backlight Sync"
    check_dmi_board || true

    local total_steps=5
    if [ "${WITH_KEYD:-0}" = "1" ]; then
        total_steps=6
    fi

    log_step 1 $total_steps "Installing hwdb mapping to $HWDB_DST..."
    backup_file_manifest_aware "$HWDB_DST" "keyboard"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0644 $HWDB_SRC -> $HWDB_DST"
    else
        sudo install -D -m 0644 "$HWDB_SRC" "$HWDB_DST"
    fi

    log_step 2 $total_steps "Installing kbd backlight udev rule to $UDEV_DST..."
    backup_file_manifest_aware "$UDEV_DST" "keyboard"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0644 $UDEV_SRC -> $UDEV_DST"
    else
        sudo install -D -m 0644 "$UDEV_SRC" "$UDEV_DST"
        # Ensure plugdev group exists and add user if rule references it
        if grep -q 'GROUP="plugdev"' "$UDEV_SRC" 2> /dev/null; then
            if ! getent group plugdev > /dev/null 2>&1; then
                sudo groupadd plugdev 2> /dev/null || true
            fi
            local real_user
            real_user="$(get_real_user)"
            if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
                if id -u "$real_user" > /dev/null 2>&1; then
                    local was_member=0
                    id -nG "$real_user" 2> /dev/null | tr ' ' '\n' | grep -qx "plugdev" && was_member=1 || was_member=0
                    # Only add if not already member
                    if [ "$was_member" = "0" ]; then
                        sudo usermod -aG plugdev "$real_user" 2> /dev/null || true
                        log_info "Added $real_user to plugdev group for kbd backlight access (re-login required)"
                    fi
                    manifest_add_group "plugdev" "$real_user" "keyboard" "$was_member"
                fi
            fi
        fi
    fi

    log_step 3 $total_steps "Installing kbd backlight sync daemon to $DAEMON_DST..."
    backup_file_manifest_aware "$DAEMON_DST" "keyboard"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0755 $DAEMON_SRC -> $DAEMON_DST"
    else
        sudo install -D -m 0755 "$DAEMON_SRC" "$DAEMON_DST"
    fi

    log_step 4 $total_steps "Installing kbd backlight user service to $SERVICE_DST..."
    backup_file_manifest_aware "$SERVICE_DST" "keyboard"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0644 $SERVICE_SRC -> $SERVICE_DST"
        log_dryrun "systemctl --global enable c640-kbd-backlight-sync.service"
        log_dryrun "systemctl --user daemon-reload (as $(get_real_user))"
    else
        sudo install -D -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
        # Record service state before enabling (first-wins)
        manifest_add_service "c640-kbd-backlight-sync.service" "keyboard"
        sudo systemctl daemon-reload 2> /dev/null || true
        # Reload user manager and enable globally
        local real_user3
        real_user3="$(get_real_user)"
        if [ -n "$real_user3" ] && [ "$real_user3" != "root" ]; then
            local uid3
            uid3="$(id -u "$real_user3" 2> /dev/null || echo "")"
            if [ -n "$uid3" ] && [ -d "/run/user/$uid3" ]; then
                sudo -u "$real_user3" XDG_RUNTIME_DIR="/run/user/$uid3" systemctl --user daemon-reload 2> /dev/null || true
            fi
        fi
        sudo systemctl --global enable c640-kbd-backlight-sync.service 2> /dev/null || true
        # Try to start for current user if graphical session is active
        if [ -n "${real_user3:-}" ] && [ "$real_user3" != "root" ]; then
            local uid4
            uid4="$(id -u "$real_user3" 2> /dev/null || echo "")"
            if [ -n "$uid4" ] && [ -d "/run/user/$uid4" ]; then
                sudo -u "$real_user3" XDG_RUNTIME_DIR="/run/user/$uid4" systemctl --user start c640-kbd-backlight-sync.service 2> /dev/null || true
            fi
        fi
        log_success "User service enabled (global) and started where possible"
    fi

    log_step 5 $total_steps "Installing kbd backlight sleep hook to $SLEEP_DST..."
    backup_file_manifest_aware "$SLEEP_DST" "keyboard"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install -D -m 0755 $SLEEP_SRC -> $SLEEP_DST"
        log_dryrun "sudo systemd-hwdb update"
        log_dryrun "sudo udevadm trigger --subsystem-match=input"
        log_dryrun "sudo udevadm trigger --subsystem-match=leds"
        log_dryrun "sudo systemctl daemon-reload"
    else
        sudo install -D -m 0755 "$SLEEP_SRC" "$SLEEP_DST"

        log_info "Updating systemd-hwdb and udev..."
        sudo systemd-hwdb update 2> /dev/null || true
        sudo udevadm control --reload-rules 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=input 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=leds 2> /dev/null || true
        sudo systemctl daemon-reload 2> /dev/null || true
        local real_user4
        real_user4="$(get_real_user)"
        if [ -n "$real_user4" ] && [ "$real_user4" != "root" ]; then
            local uid5
            uid5="$(id -u "$real_user4" 2> /dev/null || echo "")"
            if [ -n "$uid5" ] && [ -d "/run/user/$uid5" ]; then
                sudo -u "$real_user4" XDG_RUNTIME_DIR="/run/user/$uid5" systemctl --user daemon-reload 2> /dev/null || true
            fi
        fi
    fi

    # Optional keyd dual-role step
    KEYD_DEPLOYED=0
    if [ "${WITH_KEYD:-0}" = "1" ]; then
        log_step 6 $total_steps "Installing keyd dual-role config to $KEYD_DST..."
        if install_keyd_step; then
            # A dry run only previews the keyd step; never claim deployment.
            if [ "${DRY_RUN:-0}" != "1" ]; then
                KEYD_DEPLOYED=1
            fi
        else
            KEYD_DEPLOYED=0
            log_error "keyd step did not complete (config rejected, install failed or restart failed/reverted); keyboard hwdb/backlight changes are still installed"
        fi
    fi

    log_success "Chromebook top-row keyboard mapping and backlight sync installed! ⌨️"
    # In a dry run install_keyd_step already printed "Would deploy keyd
    # dual-role config"; do not claim deployment (or a real failure) here.
    if [ "${WITH_KEYD:-0}" = "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
        if [ "${KEYD_DEPLOYED:-0}" = "1" ]; then
            log_success "keyd dual-role included (Search tap=CapsLock hold=Super, Search+TopRow=F1-F10)"
        else
            log_error "keyd dual-role NOT deployed (restart failed or config rejected; see errors above)"
        fi
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_info "Dry-run: no system files were changed. Run without --dry-run to apply."
    else
        log_info "Tip: re-login or run 'systemctl --user start c640-kbd-backlight-sync.service' to start the daemon immediately."
        log_info "Test blank: c640-kbd-backlight-sync --test-blank  && c640-kbd-backlight-sync --test-unblank"
        if [ "${WITH_KEYD:-0}" = "1" ]; then
            log_info "Test keyd: sudo python3 $SCRIPT_DIR/tests/capture-keyd-output.py  # tap Search -> capslock, hold -> meta"
            log_info "Automated check: sudo python3 $SCRIPT_DIR/tests/keyd-dualrole-uinput.py"
        fi
    fi
}

# CLI Argument Parsing
ACTION="install"
WITH_KEYD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --install | -i)
            ACTION="install"
            shift
            ;;
        --with-keyd | --keyd | --enable-keyd)
            WITH_KEYD=1
            export WITH_KEYD
            shift
            ;;
        --check | -c)
            ACTION="check"
            shift
            ;;
        --uninstall | -u)
            ACTION="uninstall"
            shift
            ;;
        --dry-run | -n)
            export DRY_RUN=1
            shift
            ;;
        --help | -h)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

case "$ACTION" in
    install)
        install_keyboard
        ;;
    check)
        check_keyboard_status
        ;;
    uninstall)
        uninstall_keyboard
        ;;
esac
