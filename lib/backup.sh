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

BACKUP_BASE_DIR="${CROS_ENABLEMENT_BACKUP_DIR:-/var/backups/cros-enablement}"
MANIFEST_DIR="${CROS_ENABLEMENT_MANIFEST_DIR:-/var/lib/cros-enablement}"
MANIFEST_FILE="$MANIFEST_DIR/install-manifest.json"

manifest_has_target() {
    # $1=target; returns 0 if already tracked in the manifest, 1 otherwise
    [ -f "$MANIFEST_FILE" ] || return 1
    python3 -c '
import json, sys, os
mp, t = sys.argv[1], sys.argv[2]
if not os.path.exists(mp):
    sys.exit(1)
d = json.load(open(mp))
sys.exit(0 if any(r.get("target") == t for r in d.get("records", [])) else 1)
' "$MANIFEST_FILE" "$1" 2> /dev/null || return 1
}

backup_file_manifest_aware() {
    # $1=target $2=component
    # On re-install of an already-tracked target, keep the ORIGINAL backup
    # (first backup) instead of overwriting it with our custom version, so
    # rollback can always restore the pre-customization file.
    local target="$1" component="$2"
    if manifest_has_target "$target"; then
        log_info "Reinstall: keeping original backup for $target"
        return 0
    fi
    local existed=0
    [ -e "$target" ] || [ -L "$target" ] && existed=1
    backup_file "$target"
    manifest_add_entry "$target" "$component" "$existed"
}

backup_meson_install_plan() {
    # $1 = build dir, $2 = component
    # meson writes the full install plan (absolute destinations incl. soname
    # symlinks, .pc, .gir, .typelib, headers) into build/meson-info/
    # intro-installed.json. Back up / record every destination that ninja
    # install will write, so uninstall can restore or remove all of them.
    local builddir="$1" component="$2"
    local plan="$builddir/meson-info/intro-installed.json"
    if [ ! -f "$plan" ]; then
        if command -v meson > /dev/null 2>&1; then
            meson introspect --installed "$builddir" > "$plan" 2> /dev/null \
                || log_warn "meson introspect failed; install plan unavailable"
        else
            log_warn "No install plan and meson unavailable; rollback coverage for $component will be partial."
            return 0
        fi
    fi
    if [ ! -f "$plan" ]; then
        log_warn "No install plan for $builddir; rollback coverage for $component will be partial."
        return 0
    fi
    local dest
    local skip_prefixes
    skip_prefixes="${CROS_ENABLEMENT_INSTALLED_TESTS_PREFIXES:-/usr/libexec/installed-tests/ /usr/share/installed-tests/}"
    while IFS= read -r dest; do
        [ -z "$dest" ] && continue
        backup_file_manifest_aware "$dest" "$component"
    done < <(python3 -c '
import json, sys
plan = json.load(open(sys.argv[1]))
skip = tuple(sys.argv[2].split())
for dest in plan.values():
    if isinstance(dest, str) and not dest.startswith(skip):
        print(dest)
' "$plan" "$skip_prefixes")
}

manifest_add_service() {
    # $1=unit $2=component — record the enable/active state of a systemd
    # unit at install time so rollback can restore it on uninstall.
    # First record wins: a reinstall must not overwrite the state captured
    # at the original install, or rollback would undo installer-created state.
    [ "${DRY_RUN:-0}" = "1" ] && {
        log_dryrun "Would record service state: $1"
        return 0
    }
    systemctl cat "$1" > /dev/null 2>&1 || return 0
    local enabled active
    systemctl is-enabled "$1" > /dev/null 2>&1 && enabled=1 || enabled=0
    systemctl is-active "$1" > /dev/null 2>&1 && active=1 || active=0
    sudo mkdir -p "$MANIFEST_DIR"
    sudo python3 -c '
import json, sys, os
mp, name, comp, enabled, active = sys.argv[1:6]
data = {"version":"2.0","records":[],"services":[],"groups":[]}
if os.path.exists(mp):
    try:
        with open(mp) as f:
            data = json.load(f)
    except Exception:
        pass
data.setdefault("version", "2.0")
data.setdefault("records", [])
data.setdefault("services", [])
data.setdefault("groups", [])
if not any(s.get("name") == name and s.get("component") == comp for s in data["services"]):
    data["services"].append({
        "name": name, "component": comp,
        "was_enabled": enabled == "1", "was_active": active == "1"
    })
tmp = mp + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, mp)
' "$MANIFEST_FILE" "$1" "$2" "$enabled" "$active"
}

manifest_add_group() {
    # $1=group $2=user $3=component [$4=was_member override: 0/1] — record
    # whether the user was already a member of the group BEFORE we added
    # them (snapshot it before usermod), so uninstall only removes
    # memberships we created. First record wins: a reinstall must not
    # overwrite the membership state captured at the original install.
    [ -z "$2" ] || [ "$2" = "root" ] && return 0
    [ "${DRY_RUN:-0}" = "1" ] && {
        log_dryrun "Would record group: $2@$1"
        return 0
    }
    local was_member="${4:-0}"
    if [ "$was_member" != "0" ] && [ "$was_member" != "1" ]; then
        id -nG "$2" 2> /dev/null | tr ' ' '\n' | grep -qx "$1" && was_member=1 || was_member=0
    fi
    sudo mkdir -p "$MANIFEST_DIR"
    sudo python3 -c '
import json, sys, os
mp, group, user, comp, member = sys.argv[1:6]
data = {"version":"2.0","records":[],"services":[],"groups":[]}
if os.path.exists(mp):
    try:
        with open(mp) as f:
            data = json.load(f)
    except Exception:
        pass
data.setdefault("version", "2.0")
data.setdefault("records", [])
data.setdefault("services", [])
data.setdefault("groups", [])
if not any(g.get("group") == group and g.get("user") == user and g.get("component") == comp for g in data["groups"]):
    data["groups"].append({
        "group": group, "user": user, "component": comp,
        "was_member": member == "1"
    })
tmp = mp + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, mp)
' "$MANIFEST_FILE" "$1" "$2" "$3" "$was_member"
}

remove_group_membership() {
    # $1=group $2=user $3=component — call AFTER rollback_component (so udev
    # rules are gone and the reference check is accurate).
    [ -z "$2" ] || [ "$2" = "root" ] && return 0
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Would evaluate group membership removal: $2@$1"
        return 0
    fi
    [ -f "$MANIFEST_FILE" ] || return 0
    # Only remove membership if WE recorded adding it (user was not already
    # a member before our install).
    local ours
    ours=$(python3 -c '
import json, sys, os
mp, group, user, comp = sys.argv[1:5]
if not os.path.exists(mp):
    sys.exit(1)
d = json.load(open(mp))
for g in d.get("groups", []):
    if g.get("group") == group and g.get("user") == user and g.get("component") == comp:
        sys.exit(0 if not g.get("was_member") else 1)
sys.exit(1)
' "$MANIFEST_FILE" "$1" "$2" "$3" 2> /dev/null) && ours="1" || ours="0"
    if [ "$ours" != "1" ]; then
        log_info "User '$2' was already in group '$1' before install; keeping membership."
        return 0
    fi
    # Keep membership if another udev rule (e.g. from another component
    # still installed) references the group.
    if grep -rl "GROUP=\"$1\"" /etc/udev/rules.d/ 2> /dev/null | grep -q .; then
        log_info "udev rules still reference group '$1'; keeping '$2' in it."
        return 0
    fi
    if sudo gpasswd -d "$2" "$1" 2> /dev/null; then
        log_info "Removed '$2' from group '$1'."
    else
        log_warn "Could not remove '$2' from group '$1'; keeping manifest record for retry."
        return 0
    fi
    sudo python3 -c '
import json, sys, os
mp, group, user, comp = sys.argv[1:5]
if not os.path.exists(mp):
    sys.exit(0)
d = json.load(open(mp))
d.setdefault("groups", [])
d["groups"] = [g for g in d["groups"] if not (g.get("group") == group and g.get("user") == user and g.get("component") == comp)]
tmp = mp + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, mp)
' "$MANIFEST_FILE" "$1" "$2" "$3"
}

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
        echo '{"version":"2.0","records":[],"services":[],"groups":[]}' | sudo tee "$MANIFEST_FILE" > /dev/null
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

data = {"version":"2.0","records":[],"services":[],"groups":[]}
if os.path.exists(manifest_path):
    try:
        with open(manifest_path, "r") as f:
            data = json.load(f)
    except Exception:
        data = {"version":"2.0","records":[],"services":[],"groups":[]}

data.setdefault("version", "2.0")
data.setdefault("records", [])
data.setdefault("services", [])
data.setdefault("groups", [])
data["records"] = [r for r in data["records"] if r.get("target") != target]
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
        local allowed_prefixes
        allowed_prefixes="${CROS_ENABLEMENT_ALLOWED_PREFIXES:-/etc/ /usr/ /lib/ /lib64/ /opt/ /var/lib/fprint/}"
        sudo python3 -c '
import json, os, sys, shutil, glob, fnmatch

manifest_path = sys.argv[1]
target_comp = sys.argv[2]
backup_base = sys.argv[3]
allowed_prefixes = tuple(sys.argv[4].split())

def in_scope(path):
    # Literal prefix (system defaults like /etc/) or glob pattern (tests)
    return any(path.startswith(p) or fnmatch.fnmatch(path, p) for p in allowed_prefixes)

if not os.path.exists(manifest_path):
    sys.exit(0)

try:
    with open(manifest_path, "r") as f:
        data = json.load(f)
except Exception as e:
    print(f"Error reading manifest: {e}", file=sys.stderr)
    sys.exit(1)

# Restore systemd service states BEFORE touching files, so units are still
# present when systemctl disable/start is called.
data.setdefault("services", [])
services = data["services"]
restored_services = []
for svc in services:
    if target_comp != "all" and svc.get("component") != target_comp:
        continue
    name = svc.get("name")
    if not name:
        continue
    print(f"Restoring service state: {name}")
    import subprocess
    if svc.get("was_enabled"):
        subprocess.run(["systemctl", "enable", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        subprocess.run(["systemctl", "disable", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if svc.get("was_active"):
        subprocess.run(["systemctl", "start", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        subprocess.run(["systemctl", "stop", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    restored_services.append(svc)
data["services"] = [s for s in services if s not in restored_services]

records = data.get("records", [])
remaining_records = []
PROTECTED_DIRS = {"/", "/etc", "/usr", "/var", "/bin", "/sbin", "/lib", "/lib64", "/home", "/root"}

for rec in records:
    comp = rec.get("component", "")
    target = rec.get("target", "")
    was_existing = rec.get("was_existing", False)
    
    if target_comp != "all" and comp != target_comp:
        remaining_records.append(rec)
        continue
    
    real = os.path.realpath(target) if target else ""
    if not target or real in PROTECTED_DIRS or not in_scope(real):
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
            # Restore the OLDEST backup (matches[0]): for legacy manifests
            # that may hold multiple backups of the same target, the first
            # one is the pre-customization original.
            pattern = os.path.join(backup_base, "*", target.lstrip("/"))
            matches = sorted(glob.glob(pattern))
            if matches:
                original_backup = matches[0]
                print(f"  [RESTORING PREVIOUS BACKUP] {original_backup} -> {target}")
                if os.path.lexists(target):
                    if os.path.islink(target) or os.path.isfile(target):
                        os.remove(target)
                    else:
                        shutil.rmtree(target, ignore_errors=True)
                if os.path.islink(original_backup):
                    os.symlink(os.readlink(original_backup), target)
                elif os.path.isdir(original_backup):
                    shutil.copytree(original_backup, target, dirs_exist_ok=True)
                else:
                    shutil.copy2(original_backup, target)
            else:
                print(f"  [NOTE] {target} existed prior to install. Left intact.")
                # Keep the record so a later rollback run can still restore
                # the original once the backup becomes available.
                remaining_records.append(rec)

tmp_manifest = manifest_path + ".tmp"
data["records"] = remaining_records
with open(tmp_manifest, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp_manifest, manifest_path)
' "$MANIFEST_FILE" "$target_comp" "$BACKUP_BASE_DIR" "$allowed_prefixes"
    else
        log_warn "python3 not found; automatic rollback unavailable. Files may need manual restoration."
    fi

    log_success "Rollback for component [$target_comp] finished!"
}
