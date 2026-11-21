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
# Per-deploy keyd state snapshot. This lives OUTSIDE BACKUP_BASE_DIR and
# MANIFEST_DIR on purpose: lib/backup.sh's rollback helpers glob those trees
# and would otherwise treat a snapshot as the oldest backup, breaking the
# first-wins semantics that uninstall relies on. The default base is a
# root-owned sibling of MANIFEST_DIR under /var/lib, NOT a predictable path in
# a world-writable temporary directory (see _keyd_snapshot_base_prepare).
KEYD_SNAPSHOT_BASE="${CROS_ENABLEMENT_KEYD_SNAPSHOT_DIR:-/var/lib/cros-enablement-keyd-snapshots}"
KEYD_SNAPSHOT_DIR=""

# Echo 1 when the manifest records $2 (optionally restricted to component $3)
# as a pre-existing target, otherwise 0. Centralises the JSON probing used by
# both install-time recovery and uninstall-time rollback preparation.
_manifest_was_existing() {
    local manifest="$1" target="$2" component="${3:-}"
    [ -f "$manifest" ] || {
        echo 0
        return 0
    }
    python3 - "$manifest" "$target" "$component" << 'PY' 2> /dev/null || echo 0
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

# Echo 1 when the manifest explicitly tracks a keyboard-scoped, system-scope
# keyd service, otherwise 0. A user-scope record (the kbd backlight sync
# service uses that scope) must never authorize disabling the system keyd.
# This is the SOLE authority for deciding whether uninstall may
# disable/stop keyd: manifest_add_service("keyd", "keyboard") writes that
# record and lib/backup.sh's rollback reads it. A mere on-disk cros.conf is
# NOT evidence of ownership (a user may have installed keyd and used the same
# filename), so it is deliberately not consulted here. Read-only, DRY_RUN-safe
# and fail-safe: any missing/unreadable/malformed manifest yields 0.
_keyd_managed_by_us() {
    # shellcheck disable=SC2154 # MANIFEST_FILE is defined in lib/backup.sh
    [ -f "$MANIFEST_FILE" ] || {
        echo 0
        return 0
    }
    # shellcheck disable=SC2154 # MANIFEST_FILE is defined in lib/backup.sh
    python3 - "$MANIFEST_FILE" << 'PY' 2> /dev/null || echo 0
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for svc in data.get("services", []) or []:
        if (svc.get("name") in ("keyd", "keyd.service")
                and svc.get("component") == "keyboard"
                and svc.get("scope", "system") != "user"):
            print(1)
            break
    else:
        print(0)
except Exception:
    print(0)
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
# "../keyd/cros.conf" as well as absolute paths. Used by status check and
# install/upgrade cleanup so the readlink comparison lives in exactly one
# place. It is deliberately NOT used to decide service ownership on uninstall
# (see _keyd_managed_by_us).
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

# Print the on-disk kind of $1: absent, symlink, file, dir or other. The
# symlink flag is tested FIRST so a dangling symlink is still reported as a
# symlink; -e/-f/-d follow the link and would misclassify it.
_keyd_path_kind() {
    local path="$1"
    if [ -L "$path" ]; then
        echo symlink
    elif [ -d "$path" ]; then
        echo dir
    elif [ -f "$path" ]; then
        echo file
    elif [ -e "$path" ]; then
        echo other
    else
        echo absent
    fi
}

# Fail-closed validation of the snapshot base. A predictable, world-writable
# base would let an unprivileged user pre-create (or symlink) the directory and
# later swap snapshot children, feeding arbitrary .kind/.data to the privileged
# restore path. EVERY component (including the base and any custom path) must be
# root-owned: a caller-owned directory is NOT acceptable because root's sudo
# writes into it could be renamed/replaced by that directory's owner. Every
# component is checked WITHOUT following symlinks, and an existing base is never
# "repaired" (no chown/chmod): an unsafe one is rejected so the installer
# refuses to hand a poisoned snapshot to a root restore. The default base under
# /var/lib is root-owned and unaffected; custom paths are held to the same bar.
_keyd_snapshot_base_prepare() {
    local base="$1" p="" part="" uid="" mode="" m=""
    local -a parts=()

    case "$base" in
        /*) ;;
        *)
            log_error "Keyd snapshot base '$base' is not an absolute path; refusing to deploy keyd config"
            return 1
            ;;
    esac
    IFS='/' read -r -a parts <<< "${base#/}"
    if [ "${#parts[@]}" -eq 0 ]; then
        log_error "Keyd snapshot base '$base' is empty; refusing to deploy keyd config"
        return 1
    fi

    local idx=0 last=$((${#parts[@]} - 1))
    for part in "${parts[@]}"; do
        case "$part" in
            "" | . | ..)
                log_error "Keyd snapshot base '$base' has an unsafe path component '$part'; refusing to deploy keyd config"
                return 1
                ;;
        esac
        p="$p/$part"
        if [ -L "$p" ]; then
            log_error "Keyd snapshot base '$base' traverses a symlink at '$p'; refusing to deploy keyd config"
            return 1
        fi
        if ! uid="$(sudo stat -c '%u' -- "$p" 2> /dev/null)"; then
            if [ "$idx" -eq "$last" ] && [ "$p" = "$base" ]; then
                # Absent base: create it atomically with the right owner/mode.
                if ! sudo install -d -m 700 -o 0 -g 0 -- "$base" 2> /dev/null; then
                    log_error "Could not create keyd snapshot base '$base'; refusing to deploy keyd config"
                    return 1
                fi
                return 0
            fi
            log_error "Keyd snapshot base '$base' has a missing or unreadable parent '$p'; refusing to deploy keyd config"
            return 1
        fi
        if [ "$uid" != "0" ]; then
            log_error "Keyd snapshot base '$base' component '$p' is owned by uid '$uid' (must be root-owned); refusing to deploy keyd config"
            return 1
        fi
        if ! mode="$(sudo stat -c '%a' -- "$p" 2> /dev/null)"; then
            log_error "Could not read the mode of '$p' in keyd snapshot base '$base'; refusing to deploy keyd config"
            return 1
        fi
        case "$mode" in
            "" | *[!0-7]*)
                log_error "Invalid mode '$mode' on '$p' in keyd snapshot base '$base'; refusing to deploy keyd config"
                return 1
                ;;
        esac
        m=$((8#$mode))
        if [ "$idx" -eq "$last" ]; then
            # The base itself must be private (strict 0700; no special/sticky bits).
            if (((m & 07777) != 0700)); then
                log_error "Keyd snapshot base '$base' has unsafe mode '$mode' (must be 0700); refusing to deploy keyd config"
                return 1
            fi
        else
            # A sticky intermediate ancestor (e.g. /tmp) is tolerated, but the
            # DIRECT parent must never be group/other-writable: even with a
            # sticky bit, its owner could rename/replace the base's children.
            if (((m & 022) != 0)); then
                if [ "$idx" -eq "$((last - 1))" ]; then
                    log_error "Keyd snapshot base '$base' has a group/other-writable parent directory '$p' (mode $mode); refusing to deploy keyd config"
                    return 1
                fi
                if (((m & 01000) == 0)); then
                    log_error "Keyd snapshot base '$base' traverses group/other-writable directory '$p' (mode $mode) without a sticky bit; refusing to deploy keyd config"
                    return 1
                fi
            fi
        fi
        idx=$((idx + 1))
    done
    return 0
}

# Best-effort housekeeping: drop snapshot directories older than seven days.
# Stale-snapshot cleanup must never fail a deployment. A .failed marker means
# the snapshot is the only remaining V1 evidence after a failed restore, so it
# is retained for manual recovery.
_keyd_snapshot_prune_old() {
    [ -d "$KEYD_SNAPSHOT_BASE" ] || return 0
    sudo find "$KEYD_SNAPSHOT_BASE" -mindepth 1 -maxdepth 1 -type d -mtime +7 -print 2> /dev/null \
        | while IFS= read -r old; do
            [ -n "$old" ] || continue
            if sudo test -f "$old/.failed"; then
                continue
            fi
            sudo rm -rf -- "$old" 2> /dev/null || true
        done
    return 0
}

# Forget and remove the active snapshot. The path is guarded so an unexpected
# empty or base path can never turn into a destructive rm -rf.
_keyd_snapshot_cleanup() {
    local d="${KEYD_SNAPSHOT_DIR:-}"
    KEYD_SNAPSHOT_DIR=""
    case "$d" in
        "" | "/" | "$KEYD_SNAPSHOT_BASE") return 0 ;;
    esac
    sudo rm -rf -- "$d" 2> /dev/null || true
}

# Write one snapshot field through sudo. All snapshot I/O must stay on the
# privileged side: a non-root caller may own the installer process but not the
# root-owned snapshot base created by an earlier sudo run.
_keyd_snapshot_write() {
    local file="$1" content="$2"
    printf '%s\n' "$content" | sudo tee "$file" > /dev/null 2>&1
}

# Create an isolated, per-deploy snapshot of the keyd paths and service state.
# The first-wins manifest exists only for uninstall; this snapshot always
# captures the state RIGHT NOW, so a failed upgrade restores V1 rather than
# the original pre-V1 file (or nothing at all). Fail closed: if anything
# cannot be recorded, nothing is deployed.
_keyd_snapshot_create() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Would create pre-deploy keyd snapshot"
        KEYD_SNAPSHOT_DIR=""
        return 0
    fi

    local d="" prefix="" path="" kind="" target="" mode="" failed=0
    if ! _keyd_snapshot_base_prepare "$KEYD_SNAPSHOT_BASE"; then
        KEYD_SNAPSHOT_DIR=""
        return 1
    fi
    _keyd_snapshot_prune_old || true
    if ! d="$(sudo mktemp -d -- "$KEYD_SNAPSHOT_BASE/keyd.XXXXXXXX" 2> /dev/null)"; then
        log_error "Could not create a keyd snapshot directory under $KEYD_SNAPSHOT_BASE; refusing to deploy keyd config"
        KEYD_SNAPSHOT_DIR=""
        return 1
    fi
    KEYD_SNAPSHOT_DIR="$d"

    for prefix in cros link; do
        if [ "$prefix" = "cros" ]; then
            path="$KEYD_DST"
        else
            path="$KEYD_LINK"
        fi
        kind="$(_keyd_path_kind "$path")"
        # Fail closed on path types we cannot round-trip safely. cp -a would
        # snapshot a directory as a directory .data and a special file (e.g. a
        # FIFO) as that special file, but _keyd_restore_one puts paths back via
        # install(1), which cannot restore directories or special files. A
        # snapshot that "succeeded" but could not be restored would leave a
        # failed deploy unrecoverable. Real keyd paths are always a regular
        # file or symlink, so this only guards against unusual on-disk states.
        case "$kind" in
            dir | other)
                _keyd_snapshot_cleanup
                log_error "Unsupported keyd path type '$kind' at $path; keyd paths must be a regular file, symlink or absent; refusing to deploy keyd config"
                return 1
                ;;
        esac
        if ! _keyd_snapshot_write "$d/$prefix.kind" "$kind"; then
            failed=1
            break
        fi
        case "$kind" in
            symlink)
                # One field per file, always quoted: no eval/source of targets.
                if ! target="$(readlink "$path" 2> /dev/null)"; then
                    failed=1
                    break
                fi
                if ! _keyd_snapshot_write "$d/$prefix.target" "$target"; then
                    failed=1
                    break
                fi
                ;;
            absent) ;;
            *)
                if ! mode="$(sudo stat -c '%a' "$path" 2> /dev/null)"; then
                    failed=1
                    break
                fi
                if ! _keyd_snapshot_write "$d/$prefix.mode" "$mode"; then
                    failed=1
                    break
                fi
                if ! sudo cp -a -- "$path" "$d/$prefix.data" 2> /dev/null; then
                    failed=1
                    break
                fi
                ;;
        esac
    done

    if [ "$failed" -eq 0 ]; then
        local svc_enabled=0 svc_active=0
        # A non-zero is-enabled/is-active is a legitimate "not enabled/active"
        # state, not a snapshot failure.
        if systemctl is-enabled keyd > /dev/null 2>&1; then
            svc_enabled=1
        fi
        if systemctl is-active keyd > /dev/null 2>&1; then
            svc_active=1
        fi
        if ! _keyd_snapshot_write "$d/svc.enabled" "$svc_enabled"; then
            failed=1
        elif ! _keyd_snapshot_write "$d/svc.active" "$svc_active"; then
            failed=1
        fi
    fi

    if [ "$failed" -ne 0 ]; then
        _keyd_snapshot_cleanup
        log_error "Keyd pre-deploy snapshot is incomplete; refusing to deploy keyd config"
        return 1
    fi
    log_info "Created pre-deploy keyd snapshot at $d"
    return 0
}

# Restore one keyd path from snapshot prefix <prefix>. Symlinks are rebuilt
# from .target with ln -s; we deliberately do NOT restore them from .data
# (cp -a of a dangling link would leave a dangling link in the snapshot dir).
_keyd_restore_one() {
    local dst="$1" prefix="$2" d="${KEYD_SNAPSHOT_DIR:-}" kind="" target="" mode=""
    local kind_file="$d/$prefix.kind"
    if ! sudo test -f "$kind_file"; then
        log_warn "Keyd snapshot has no $prefix.kind; cannot restore $dst"
        return 1
    fi
    if ! kind="$(sudo cat "$kind_file" 2> /dev/null)"; then
        log_warn "Could not read $kind_file; cannot restore $dst"
        return 1
    fi
    case "$kind" in
        absent | symlink | file | dir) ;;
        *)
            log_warn "Keyd snapshot has unknown kind '$kind' for $dst"
            return 1
            ;;
    esac

    # Clear the current state first, symlink flag first (a dangling link is
    # still a link), then directories, then everything else. The keyd paths
    # are root-owned, so every mutation must go through sudo just like the
    # deployment and service operations do. Snapshot metadata lives in the
    # root-owned 0700 base, so its reads are privileged too; only the read of
    # the destination path type (-L/-d/-e) stays unprivileged.
    if [ -L "$dst" ]; then
        if ! sudo rm -f -- "$dst" 2> /dev/null; then
            log_warn "Could not remove $dst symlink while restoring keyd snapshot"
            return 1
        fi
    elif [ -d "$dst" ]; then
        if ! sudo rm -rf -- "$dst" 2> /dev/null; then
            log_warn "Could not remove $dst directory while restoring keyd snapshot"
            return 1
        fi
    elif [ -e "$dst" ]; then
        if ! sudo rm -f -- "$dst" 2> /dev/null; then
            log_warn "Could not remove $dst while restoring keyd snapshot"
            return 1
        fi
    fi

    case "$kind" in
        absent)
            return 0
            ;;
        symlink)
            if ! target="$(sudo cat "$d/$prefix.target" 2> /dev/null)"; then
                log_warn "Could not read $d/$prefix.target; cannot restore $dst"
                return 1
            fi
            if ! sudo mkdir -p -- "$(dirname "$dst")" 2> /dev/null; then
                log_warn "Could not create parent directory for $dst"
                return 1
            fi
            if ! sudo ln -s -- "$target" "$dst" 2> /dev/null; then
                log_warn "Could not recreate $dst as a symlink to $target"
                return 1
            fi
            ;;
        file | dir)
            if ! mode="$(sudo cat "$d/$prefix.mode" 2> /dev/null)"; then
                log_warn "Could not read $d/$prefix.mode; cannot restore $dst"
                return 1
            fi
            if ! sudo test -f "$d/$prefix.data"; then
                log_warn "Keyd snapshot has no $prefix.data; cannot restore $dst"
                return 1
            fi
            if ! sudo install -D -m "$mode" "$d/$prefix.data" "$dst" 2> /dev/null; then
                log_warn "Could not restore $dst from keyd snapshot"
                return 1
            fi
            ;;
    esac
    return 0
}

# Restore the per-deploy snapshot: both keyd paths (including their symlink
# types) and the service's enabled state. The active state is recorded in
# .active_wanted for the caller, which stops keyd after the health-check
# restart if it was inactive before deployment.
_keyd_snapshot_restore() {
    local d="${KEYD_SNAPSHOT_DIR:-}" enabled="" active="" rc=0
    if [ -z "$d" ] || ! sudo test -f "$d/cros.kind"; then
        log_warn "No pre-deploy keyd snapshot available; cannot restore previous keyd state"
        return 1
    fi
    if ! _keyd_restore_one "$KEYD_DST" "cros"; then
        rc=1
    fi
    if ! _keyd_restore_one "$KEYD_LINK" "link"; then
        rc=1
    fi

    if ! sudo test -f "$d/svc.enabled" || ! enabled="$(sudo cat "$d/svc.enabled" 2> /dev/null)"; then
        log_warn "Keyd snapshot has no readable svc.enabled; service enablement left unchanged"
        rc=1
    else
        case "$enabled" in
            1)
                if ! sudo systemctl enable keyd > /dev/null 2>&1; then
                    log_warn "Could not re-enable keyd while restoring the pre-deploy snapshot"
                    rc=1
                fi
                ;;
            0)
                if ! sudo systemctl disable keyd > /dev/null 2>&1; then
                    log_warn "Could not disable keyd while restoring the pre-deploy snapshot"
                    rc=1
                fi
                ;;
            *)
                log_warn "Keyd snapshot has an invalid svc.enabled value '$enabled'"
                rc=1
                ;;
        esac
    fi

    if ! sudo test -f "$d/svc.active" || ! active="$(sudo cat "$d/svc.active" 2> /dev/null)"; then
        log_warn "Keyd snapshot has no readable svc.active"
        rc=1
    elif ! _keyd_snapshot_write "$d/.active_wanted" "$active"; then
        log_warn "Could not record the pre-deploy keyd active state"
        rc=1
    fi
    return "$rc"
}

# After an unrecoverable restore the snapshot is the ONLY remaining evidence
# of the pre-deploy (V1) keyd state. Mark it so pruning keeps it, and print an
# absolute path so an operator can still recover manually.
_keyd_snapshot_retain_notice() {
    local reason="${1:-restore failed}"
    local d="${KEYD_SNAPSHOT_DIR:-}"
    case "$d" in
        "" | "/" | "$KEYD_SNAPSHOT_BASE") return 0 ;;
    esac
    if ! sudo test -d "$d"; then
        return 0
    fi
    printf 'failed\n' | sudo tee "$d/.failed" > /dev/null 2>&1 || true
    log_warn "Keyd snapshot RETAINED at $d ($reason); manual recovery preserved"
}

# Undo a failed keyd deployment by restoring the PER-DEPLOY snapshot (V1,
# not the first-ever backup that only serves uninstall), then run a final
# health-check restart. If keyd was inactive before deployment it is stopped
# again afterwards: the brief health-check start is acceptable, the final
# state is not.
# Returns 2 when the snapshot was fully restored AND the final restart
# succeeded (safe revert: the new dual-role config is NOT active), and 1 when
# recovery (or the final stop of a previously inactive service) could not be
# completed. This helper is only called after a restart has already failed, so
# there is no "no revert needed" case in practice: 0 is reserved purely as a
# defensive/future-compatible value and is never returned on the current paths.
# Callers MUST treat 2 like a failure: dual-role must never be reported as
# active after a revert.
_restore_keyd_after_failed_restart() {
    local restored=0 wanted_active=""
    if _keyd_snapshot_restore; then
        restored=1
        log_info "Restored pre-deploy keyd state from snapshot after failed restart"
    else
        log_warn "Could not fully restore the pre-deploy keyd state from snapshot after failed restart"
    fi

    if ! sudo systemctl restart keyd 2> /dev/null; then
        log_warn "keyd still failed to restart after restoring previous config; check 'journalctl -u keyd' manually"
        _keyd_snapshot_retain_notice
        return 1
    fi
    if [ "$restored" -eq 1 ]; then
        log_success "keyd restart succeeded after restoring previous config"
    else
        # Never claim a successful restore here: the running config may still
        # be the new (broken) one that failed the health-check restart.
        log_warn "keyd restarted, but snapshot restore FAILED — the active config may be the new (broken) one"
    fi

    if [ "$restored" -eq 1 ] && sudo test -f "${KEYD_SNAPSHOT_DIR:-}/.active_wanted"; then
        if ! wanted_active="$(sudo cat "${KEYD_SNAPSHOT_DIR:-}/.active_wanted" 2> /dev/null)"; then
            wanted_active=""
            log_warn "Could not read the recorded pre-deploy keyd active state"
        fi
        if [ "$wanted_active" = "0" ]; then
            if ! sudo systemctl stop keyd 2> /dev/null; then
                log_warn "Could not stop keyd after recovery; service was inactive before deployment"
                restored=0
            else
                log_info "Stopped keyd after recovery: service was inactive before deployment (brief health-check start only)"
            fi
        fi
    fi

    if [ "$restored" -eq 1 ]; then
        # The system is back on its pre-deploy config, so the config we just
        # deployed is NOT active even though keyd now runs.
        return 2
    fi
    # Snapshot restoration (or the final stop) could not be completed.
    _keyd_snapshot_retain_notice
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
        log_dryrun "Would create pre-deploy keyd snapshot"
        log_dryrun "Would deploy keyd dual-role config"
        log_dryrun "Install -D -m 0644 $KEYD_SRC -> $KEYD_DST"
        log_dryrun "Would record service state: keyd (keyboard)"
        log_dryrun "keyd check (only >= 2.6) then systemctl enable keyd && systemctl restart keyd (if keyd installed)"
        KEYD_STATE="planned"
        return 0
    fi

    if [ ! -f "$KEYD_SRC" ]; then
        log_warn "keyd source not found at $KEYD_SRC, skipping"
        KEYD_STATE="failed"
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
                KEYD_STATE="failed"
                return 1
                ;;
            # No state change: rc=3 still allows an active service (the daemon
            # reload validates the config on keyd < 2.6).
            3) log_info "keyd < 2.6 has no 'check' subcommand; relying on daemon reload" ;;
            *)
                log_error "keyd config check returned unexpected rc=$rc for $KEYD_SRC: skipping deployment of $KEYD_DST and leaving the keyd service untouched."
                KEYD_STATE="failed"
                return 1
                ;;
        esac
    else
        log_warn "keyd binary not found; cannot validate $KEYD_SRC. Deploying config only (no enable/restart). Install keyd for dual-role: sudo apt install keyd (Ubuntu>=25.04) or see keyboard/README.md"
    fi

    # Capture the state we are about to replace. This is independent of the
    # first-wins manifest/uninstall backups: a failed upgrade must restore the
    # version that was live just before THIS deploy (V1), not the original.
    if ! _keyd_snapshot_create; then
        KEYD_STATE="failed"
        return 1
    fi

    # Backups must be taken before the symlink is removed or cros.conf replaced.
    # A failed backup or manifest write must abort BEFORE either original is
    # touched: without a claimed backup, rollback cannot restore it. The
    # snapshot is kept (and marked) because it is the only V1 evidence left.
    if ! backup_file_manifest_aware "$KEYD_DST" "keyboard"; then
        log_error "Keyd pre-deploy backup/manifest failed for $KEYD_DST; refusing to deploy keyd config"
        _keyd_snapshot_retain_notice "backup failed"
        KEYD_STATE="failed"
        return 1
    fi
    if is_our_legacy_keyd_link; then
        local link_target
        link_target="$(readlink "$KEYD_LINK" 2> /dev/null || echo "")"
        _normalize_keyd_link_manifest_component
        # Keep the snapshot and the symlink intact on any backup failure: the
        # cros.conf backup above may already exist, but removing the link now
        # would make the original unrecoverable.
        if ! backup_file_manifest_aware "$KEYD_LINK" "keyboard"; then
            log_error "Keyd pre-deploy backup/manifest failed for $KEYD_LINK; refusing to deploy keyd config"
            _keyd_snapshot_retain_notice "backup failed"
            KEYD_STATE="failed"
            return 1
        fi
        sudo rm -f "$KEYD_LINK" 2> /dev/null || true
        log_info "Removed redundant symlink $KEYD_LINK -> $link_target"
    fi

    # Guard the deployment: under `set -e` an unguarded failure would abort
    # the installer before the pre-install keyd state could be restored.
    if ! sudo install -D -m 0644 "$KEYD_SRC" "$KEYD_DST"; then
        log_error "Failed to deploy $KEYD_DST; restoring previous keyd state"
        local recovery_rc=0
        _restore_keyd_after_failed_restart || recovery_rc=$?
        if [ "$recovery_rc" -eq 2 ]; then
            # Only a FULL revert consumes the snapshot: V1 is live again.
            _keyd_snapshot_cleanup
            log_warn "keyd config reverted after install failure; dual-role NOT active"
        else
            log_error "keyd config could not be restored after the install failure; snapshot kept at ${KEYD_SNAPSHOT_DIR:-<none>} for manual recovery"
        fi
        KEYD_STATE="failed"
        return 1
    fi
    manifest_add_service "keyd" "keyboard"

    if [ -z "$keyd_cmd" ]; then
        # Config was deployed, but there is no keyd service to validate or
        # activate it. This is a distinct, non-success state: the caller must
        # not report dual-role as included unless it explicitly opted in.
        KEYD_STATE="config-only"
        _keyd_snapshot_cleanup
        return 3
    fi

    if ! sudo systemctl enable keyd 2> /dev/null; then
        log_warn "Failed to enable keyd (try: sudo systemctl enable keyd)"
    fi
    if ! sudo systemctl restart keyd 2> /dev/null; then
        KEYD_STATE="failed"
        log_warn "Failed to restart keyd after deploying $KEYD_DST; restoring previous config and retrying"
        local recovery_rc=0
        # `|| rc=$?` records the real status: `if ! cmd` would only expose the
        # negated status (0) inside its then-branch. `set -e` is not triggered
        # by the left-hand side of `||`.
        _restore_keyd_after_failed_restart || recovery_rc=$?
        case "$recovery_rc" in
            2)
                # The daemon was restarted, but on the ORIGINAL config. The
                # system is safe, yet dual-role is NOT deployed: the caller
                # captures our rc via `|| keyd_rc=$?` and keeps
                # KEYD_DEPLOYED=0 from our failure status. Only this fully
                # reverted path consumes (cleans) the snapshot.
                _keyd_snapshot_cleanup
                log_warn "keyd config reverted after restart failure; dual-role NOT active"
                return 1
                ;;
            0 | 1 | *)
                # Recovery did NOT finish, so the snapshot is the only V1
                # evidence left. Keep it (with its .failed marker) instead of
                # destroying the evidence. The restart failed, so dual-role
                # must never be reported as active on any of these paths.
                log_error "keyd restart could not be recovered; dual-role config is not active"
                log_warn "Keyd snapshot kept at ${KEYD_SNAPSHOT_DIR:-<none>} for manual recovery; snapshot not consumed"
                return 1
                ;;
        esac
    fi

    # Recommend libinput quirk for GNOME Wayland
    if [ ! -f /etc/libinput/local-overrides.quirks ] || ! grep -q "keyd" /etc/libinput/local-overrides.quirks 2> /dev/null; then
        log_info "Tip: for GNOME Wayland trackpad, consider adding /etc/libinput/local-overrides.quirks (see keyboard/README.md)"
    fi
    # rc=0 means keyd check verified the config; rc=3 means the old daemon
    # (no check subcommand) is running the config without a usable verifier.
    if [ "$rc" -eq 0 ]; then
        KEYD_STATE="verified"
    else
        KEYD_STATE="active"
    fi
    _keyd_snapshot_cleanup
    return 0
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --install, -i      Install Chromebook top-row udev hwdb mapping + kbd backlight sync (default)"
    echo "  --with-keyd        Also install keyd advanced dual-role config (Search tap= CapsLock, hold=Super, Search+TopRow=F1-F10)"
    echo "                     Fails if the keyd service cannot be activated (rc 1/3)"
    echo "  --keyd             Alias for --with-keyd"
    echo "  --keyd-config-only Also install the keyd config but accept that no keyd service is active (implies --with-keyd)"
    echo "  --check, -c        Check current keyboard hwdb and backlight sync status"
    echo "  --uninstall, -u    Uninstall top-row hwdb mapping and backlight sync (and keyd config if present)"
    echo "  --dry-run, -n      Preview changes without modifying files"
    echo "  --help, -h         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                              # hwdb + backlight"
    echo "  $0 --with-keyd                  # hwdb + backlight + keyd dual-role"
    echo "  $0 --with-keyd --dry-run        # preview all"
    echo "  $0 --keyd-config-only           # deploy keyd config only (no keyd service)"
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
        # Only disable keyd when the manifest explicitly records it as a
        # keyboard service installed by this project. File/symlink existence
        # is NOT ownership: a user-installed keyd with an identically named
        # cros.conf must be left running. This check must stay BEFORE
        # _prepare_keyd_link_for_rollback()/rollback_component("keyboard"):
        # rollback_component("keyboard") is what consumes (and clears) the
        # service record, while _prepare_keyd_link_for_rollback() only touches
        # the file record / placeholder.
        if systemctl is-active --quiet keyd 2> /dev/null || systemctl is-enabled --quiet keyd 2> /dev/null; then
            local keyd_managed
            keyd_managed="$(_keyd_managed_by_us)"
            if [ "$keyd_managed" = "1" ]; then
                sudo systemctl disable --now keyd 2> /dev/null || true
                log_info "Disabled project-managed keyd service (rollback will restore its original state)"
            else
                log_info "keyd is active/enabled but has no keyboard service record in the manifest; leaving it untouched (not managed by this project)"
            fi
        fi
    else
        log_dryrun "Would disable user service: c640-kbd-backlight-sync.service (global + user)"
        # Keep DRY_RUN consistent with the real path without touching
        # systemctl: the manifest service record is the only ownership proof.
        local keyd_managed_dryrun
        keyd_managed_dryrun="$(_keyd_managed_by_us)"
        if [ "$keyd_managed_dryrun" = "1" ]; then
            log_dryrun "Would disable project-managed keyd service (if active/enabled)"
        else
            log_dryrun "Would leave keyd service untouched (no keyboard service record in manifest)"
        fi
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

    # Always reset: an earlier call in the same shell (or an inherited
    # environment) must not leak a keyd result into this run. Do NOT reset
    # KEYD_ALLOW_CONFIG_ONLY here: it is a CLI opt-in set before this function
    # runs, and resetting it would silently discard `--keyd-config-only`.
    KEYD_STATE="not-requested"
    KEYD_DEPLOYED=0

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
    if [ "${WITH_KEYD:-0}" = "1" ]; then
        log_step 6 $total_steps "Installing keyd dual-role config to $KEYD_DST..."
        # Guard with || under set -e so the step's real status can be handled.
        local keyd_rc=0
        install_keyd_step || keyd_rc=$?
        case "$keyd_rc" in
            0)
                # A dry run only previews the keyd step; never claim deployment.
                if [ "${DRY_RUN:-0}" != "1" ]; then
                    # shellcheck disable=SC2034 # consumed by callers/tests after install_keyboard returns
                    KEYD_DEPLOYED=1
                fi
                ;;
            3)
                log_warn "keyd config deployed but no keyd service is active; dual-role NOT active (install keyd or use --keyd-config-only to accept this explicitly)"
                ;;
            *)
                log_error "keyd step did not complete (config rejected, install failed or restart failed/reverted; rc=$keyd_rc); keyboard hwdb/backlight changes are still installed"
                ;;
        esac
    fi

    log_success "Chromebook top-row keyboard mapping and backlight sync installed! ⌨️"
    # In a dry run install_keyd_step already printed "Would deploy keyd
    # dual-role config"; do not claim deployment (or a real failure) here.
    if [ "${WITH_KEYD:-0}" = "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
        case "${KEYD_STATE:-not-requested}" in
            verified)
                log_success "keyd dual-role included (verified) (Search tap=CapsLock hold=Super, Search+TopRow=F1-F10)"
                ;;
            active)
                log_success "keyd dual-role active (check unavailable) (Search tap=CapsLock hold=Super, Search+TopRow=F1-F10)"
                ;;
            config-only)
                # The config was written, but no keyd service is active. Never
                # claim dual-role is included; the caller's warning above
                # explains the missing service.
                ;;
            failed)
                log_error "keyd dual-role NOT deployed (restart failed or config rejected; see errors above)"
                ;;
            *)
                log_error "keyd dual-role NOT deployed (keyd step reported state '${KEYD_STATE:-unset}'; see errors above)"
                ;;
        esac
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

    # An explicit --with-keyd that did not take effect is a failure (rc 3 for
    # config-only, rc 1 otherwise). --check/--uninstall and dry runs keep rc 0.
    local final_rc=0
    if [ "${WITH_KEYD:-0}" = "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
        case "${KEYD_STATE:-not-requested}" in
            verified | active) : ;;
            config-only) [ "${KEYD_ALLOW_CONFIG_ONLY:-0}" = "1" ] || final_rc=3 ;;
            *) final_rc=1 ;;
        esac
    fi
    return "$final_rc"
}

# CLI Argument Parsing
ACTION="install"
WITH_KEYD=0
# Reset before parsing so an inherited KEYD_ALLOW_CONFIG_ONLY=1 cannot opt in
# to config-only mode implicitly; `--keyd-config-only` re-enables it below.
KEYD_ALLOW_CONFIG_ONLY=0
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
        --keyd-config-only)
            WITH_KEYD=1
            export WITH_KEYD
            KEYD_ALLOW_CONFIG_ONLY=1
            export KEYD_ALLOW_CONFIG_ONLY
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
        # Bare call: as an `||` left operand the whole function would run with
        # errexit suppressed, swallowing failures in later install steps.
        install_keyboard
        ;;
    check)
        check_keyboard_status
        ;;
    uninstall)
        uninstall_keyboard
        ;;
esac
exit $?
