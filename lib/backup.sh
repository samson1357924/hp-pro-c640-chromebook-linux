#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lib/backup.sh - File Backup, Manifest Tracking and Rollback/Uninstall for HP Pro c640 Linux Enablement

if [ -n "${_LIB_BACKUP_SH_LOADED:-}" ]; then
    return 0
fi
_LIB_BACKUP_SH_LOADED=1

SCRIPT_DIR_BACKUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logger.sh
source "$SCRIPT_DIR_BACKUP/logger.sh"

BACKUP_BASE_DIR="/var/backups/cros-enablement"
MANIFEST_DIR="/var/lib/cros-enablement"
MANIFEST_FILE="$MANIFEST_DIR/install-manifest.json"

backup_file() {
    local target="$1"
    [ -z "$target" ] && return 0

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Would backup file: $target (if exists)"
        return 0
    fi

    if [ -e "$target" ] || [ -L "$target" ]; then
        local timestamp
        timestamp="$(date '+%Y%m%d_%H%M%S%N')"
        local backup_path="$BACKUP_BASE_DIR/$timestamp$target"
        sudo mkdir -p "$(dirname "$backup_path")"
        sudo cp -a "$target" "$backup_path"
        log_info "Backed up existing file: $target -> $backup_path"
    fi
}

manifest_add_entry() {
    local target="$1"
    local component="$2"
    local was_existing="$3" # 1 = yes, 0 = created new

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Would record in manifest: [$component] $target (existing=$was_existing)"
        return 0
    fi

    sudo mkdir -p "$MANIFEST_DIR"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Create empty json if not exists
    if [ ! -f "$MANIFEST_FILE" ]; then
        echo '{"version":"1.0","records":[]}' | sudo tee "$MANIFEST_FILE" > /dev/null
    fi

    # Append entry using python with atomic file write
    if ! command -v python3 > /dev/null 2>&1; then
        log_warn "python3 not found; install manifest cannot be updated. Rollback for this file will be unavailable."
        return 1
    fi
    sudo python3 -c '
import json, sys, os
manifest_path = sys.argv[1]
target = sys.argv[2]
comp = sys.argv[3]
existing = sys.argv[4] == "1"
ts = sys.argv[5]

data = {"version":"1.0","records":[]}
if os.path.exists(manifest_path):
    try:
        with open(manifest_path, "r") as f:
            data = json.load(f)
    except Exception:
        data = {"version":"1.0","records":[]}

data["records"] = [r for r in data.get("records", []) if r.get("target") != target]
data["records"].append({
    "target": target,
    "component": comp,
    "was_existing": existing,
    "installed_at": ts
})

tmp_manifest = manifest_path + ".tmp"
with open(tmp_manifest, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp_manifest, manifest_path)
' "$MANIFEST_FILE" "$target" "$component" "$was_existing" "$timestamp"
}

rollback_component() {
    local target_comp="${1:-all}"
    log_section "Rolling Back / Uninstalling [$target_comp]"

    if [ ! -f "$MANIFEST_FILE" ]; then
        log_warn "No install manifest found at $MANIFEST_FILE. Nothing to rollback automatically."
        return 0
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Rollback would process records in $MANIFEST_FILE for component: $target_comp"
        return 0
    fi

    if command -v python3 > /dev/null 2>&1; then
        sudo python3 -c '
import json, os, sys, shutil, glob

manifest_path = sys.argv[1]
target_comp = sys.argv[2]

if not os.path.exists(manifest_path):
    sys.exit(0)

try:
    with open(manifest_path, "r") as f:
        data = json.load(f)
except Exception as e:
    print(f"Error reading manifest: {e}", file=sys.stderr)
    sys.exit(1)

records = data.get("records", [])
remaining_records = []
backup_base = "/var/backups/cros-enablement"
PROTECTED_DIRS = {"/", "/etc", "/usr", "/var", "/bin", "/sbin", "/lib", "/lib64", "/home", "/root"}
ALLOWED_PREFIXES = ("/etc/", "/usr/", "/lib/", "/lib64/", "/opt/")

for rec in records:
    comp = rec.get("component", "")
    target = rec.get("target", "")
    was_existing = rec.get("was_existing", False)
    
    if target_comp != "all" and comp != target_comp:
        remaining_records.append(rec)
        continue
    
    real = os.path.realpath(target) if target else ""
    if not target or real in PROTECTED_DIRS or not real.startswith(ALLOWED_PREFIXES):
        print(f"  [SKIPPED OUT-OF-SCOPE TARGET] {target}", file=sys.stderr)
        remaining_records.append(rec)
        continue

    print(f"Processing rollback for: {target} (component: {comp})")
    if os.path.lexists(target):
        if not was_existing:
            if os.path.isdir(target) and not os.path.islink(target):
                shutil.rmtree(target, ignore_errors=True)
                print(f"  [REMOVED DIR] {target}")
            else:
                os.remove(target)
                print(f"  [REMOVED FILE] {target}")
        else:
            # Search for latest backup and restore
            pattern = os.path.join(backup_base, "*", target.lstrip("/"))
            matches = sorted(glob.glob(pattern))
            if matches:
                latest_backup = matches[-1]
                print(f"  [RESTORING PREVIOUS BACKUP] {latest_backup} -> {target}")
                if os.path.lexists(target):
                    if os.path.islink(target) or os.path.isfile(target):
                        os.remove(target)
                    else:
                        shutil.rmtree(target, ignore_errors=True)
                if os.path.islink(latest_backup):
                    os.symlink(os.readlink(latest_backup), target)
                elif os.path.isdir(latest_backup):
                    shutil.copytree(latest_backup, target, dirs_exist_ok=True)
                else:
                    shutil.copy2(latest_backup, target)
            else:
                print(f"  [NOTE] {target} existed prior to install. Left intact.")

tmp_manifest = manifest_path + ".tmp"
with open(tmp_manifest, "w") as f:
    json.dump({"version":"1.0","records":remaining_records}, f, indent=2)
os.replace(tmp_manifest, manifest_path)
' "$MANIFEST_FILE" "$target_comp"
    else
        log_warn "python3 not found; automatic rollback unavailable. Files may need manual restoration."
    fi

    log_success "Rollback for component [$target_comp] finished!"
}
