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

# Results of the most recent manifest_load(). Every reader and writer shares
# these so a corrupt manifest can never be mistaken for an empty one and
# silently overwritten (which would erase all earlier backup/service/group
# records and make a fresh V1 backup look like the ORIGINAL).
MANIFEST_JSON=""
# shellcheck disable=SC2034 # read by callers/tests after manifest_load()
MANIFEST_CREATED=0

# Single validation source for all manifest readers/writers. Reads the path
# from argv[1]; malformed input exits 2 with a MANIFEST_INVALID diagnostic on
# stderr, valid input prints one canonical JSON document on stdout.
# Validate only (never repair/coerce): a field that is present with the wrong
# type is an invalid manifest, not a value to normalise.
# Safety-decision fields (records[*].was_existing, services[*].was_enabled /
# was_active, groups[*].was_member) are REQUIRED: every real writer, v1.0 and
# v2.0, has always emitted them (verified against git history). A missing one
# means "original state unknown", NEVER "false" — treating it as false would
# let rollback delete a user's file / disable a user's service / drop a group
# membership without evidence. Truly optional legacy fields (component, scope,
# installed_at, top-level services/groups arrays) stay optional and are
# normalised/defaulted.
_MANIFEST_VALIDATE_PY='
import json, sys, os

mp = sys.argv[1]

def invalid(reason):
    print("MANIFEST_INVALID: %s: %s" % (mp, reason), file=sys.stderr)
    sys.exit(2)

def check(obj, key, kind, where, required=False):
    if key not in obj:
        if required:
            invalid("%s is missing required field %s" % (where, key))
        return
    value = obj[key]
    if kind == "str":
        ok = isinstance(value, str)
    elif kind == "bool":
        ok = isinstance(value, bool)
    elif kind == "abspath":
        # isinstance first: os.path.isabs(12) raises TypeError (traceback
        # instead of a MANIFEST_INVALID diagnostic). Reject embedded NULs
        # explicitly: os.path.isabs("/tmp/x\x00evil") is True, but
        # os.path.realpath() in rollback raises ValueError and crashes the
        # python after services have already been restored.
        ok = isinstance(value, str) and os.path.isabs(value) and "\x00" not in value
    else:
        ok = False
    if not ok:
        invalid("%s.%s must be %s (got %s)" %
                (where, key,
                 {"str": "a string", "bool": "a boolean",
                  "abspath": "an absolute path string"}[kind],
                 repr(value)[:80]))

try:
    with open(mp, "r") as f:
        data = json.load(f)
except Exception as e:
    invalid("cannot parse manifest: %s" % e)

# Container checks (unchanged semantics).
if not isinstance(data, dict):
    invalid("top-level JSON value is not an object")
if not isinstance(data.get("records"), list):
    invalid("records is missing or not a list")
for key in ("services", "groups"):
    if key in data and not isinstance(data[key], list):
        invalid("%s is not a list" % key)
for key in ("records", "services", "groups"):
    for i, item in enumerate(data.get(key, [])):
        if not isinstance(item, dict):
            invalid("%s[%d] is not an object" % (key, i))

# Field-level type checks. Unknown keys are ignored (forward compatibility).
if "version" in data:
    check(data, "version", "str", "manifest")

for i, rec in enumerate(data["records"]):
    where = "records[%d]" % i
    check(rec, "target",       "abspath", where, required=True)
    check(rec, "component",    "str",     where)   # optional: legacy v1 backfill
    check(rec, "was_existing", "bool",    where, required=True)
    check(rec, "installed_at", "str",     where)   # optional: no safety impact

for i, svc in enumerate(data.get("services", [])):
    where = "services[%d]" % i
    check(svc, "name",        "str",  where, required=True)
    check(svc, "component",   "str",  where, required=True)
    check(svc, "was_enabled", "bool", where, required=True)
    check(svc, "was_active",  "bool", where, required=True)
    check(svc, "scope",       "str",  where)       # optional: user scope added later

for i, grp in enumerate(data.get("groups", [])):
    where = "groups[%d]" % i
    check(grp, "group",      "str",  where, required=True)
    check(grp, "user",       "str",  where, required=True)
    check(grp, "component",  "str",  where, required=True)
    check(grp, "was_member", "bool", where, required=True)

# Canonical output (unchanged): defaults are only added at the top level;
# record-level fields are never injected/reordered, preserving first-wins.
data.setdefault("version", "2.0")
data.setdefault("services", [])
data.setdefault("groups", [])
print(json.dumps(data, sort_keys=True, separators=(",", ":")))
'

manifest_load() {
    # shellcheck disable=SC2034 # MANIFEST_CREATED is read by callers/tests
    MANIFEST_JSON=""
    MANIFEST_CREATED=0
    # -e/-L together: a dangling symlink is NOT "missing" and must never be
    # replaced with a fresh empty manifest.
    if [ ! -e "$MANIFEST_FILE" ] && [ ! -L "$MANIFEST_FILE" ]; then
        MANIFEST_JSON='{"records":[],"services":[],"version":"2.0","groups":[]}'
        MANIFEST_CREATED=1
        return 0
    fi
    local output
    if ! output="$(python3 -c "$_MANIFEST_VALIDATE_PY" "$MANIFEST_FILE" 2>&1)"; then
        log_error "MANIFEST_INVALID: $output (manifest at $MANIFEST_FILE is corrupt/invalid; original bytes left untouched)"
        MANIFEST_JSON=""
        MANIFEST_CREATED=0
        return 1
    fi
    MANIFEST_JSON="$output"
    # shellcheck disable=SC2034 # read by callers/tests
    MANIFEST_CREATED=0
    return 0
}

manifest_has_target() {
    # $1=target; 0=tracked (reinstall), 1=not tracked (safe to back up),
    # 2=manifest corrupt/unreadable (fail closed; never conflated with 1).
    if ! manifest_load; then
        return 2
    fi
    if [ "$MANIFEST_CREATED" = "1" ]; then
        # No manifest exists yet: there are no records to check, so the target is
        # untracked.  Avoid depending on python3 here (minimal/dry-run containers
        # may not have it); an existing manifest still goes through the validator.
        return 1
    fi
    local rc=0
    printf '%s' "$MANIFEST_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
target = sys.argv[1]
if any(isinstance(r, dict) and r.get("target") == target for r in data.get("records", [])):
    sys.exit(0)
sys.exit(1)
' "$1" 2> /dev/null || rc=$?
    if [ "$rc" -gt 1 ]; then
        return 2
    fi
    return "$rc"
}

backup_file_manifest_aware() {
    # $1=target $2=component
    # On re-install of an already-tracked target, keep the ORIGINAL backup
    # (first backup) instead of overwriting it with our custom version, so
    # rollback can always restore the pre-customization file.
    local target="$1" component="$2"
    local probe_rc=0
    manifest_has_target "$target" || probe_rc=$?
    case "$probe_rc" in
        0)
            log_info "Reinstall: keeping original backup for $target"
            return 0
            ;;
        1) ;; # untracked target: safe to back up
        *)
            # Fail closed BEFORE backup_file: a corrupt manifest must not be
            # treated as "untracked" and then have a fresh V1 backup written
            # over it (the new backup would be mislabelled as the ORIGINAL).
            log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to back up $target"
            return 1
            ;;
    esac
    local existed=0
    [ -e "$target" ] || [ -L "$target" ] && existed=1
    if ! backup_file "$target"; then
        log_error "Backup of $target failed; NOT recording a manifest entry (rollback coverage must never be claimed without a real backup)"
        return 1
    fi
    if ! manifest_add_entry "$target" "$component" "$existed"; then
        log_error "Manifest write failed for $target: a backup exists but is NOT claimed in the manifest; refusing to continue"
        return 1
    fi
    return 0
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
import json, sys, os
plan = json.load(open(sys.argv[1]))
skip = tuple(sys.argv[2].split())
for dest in plan.values():
    # Only absolute destinations can be tracked: manifest_add_entry stores
    # this verbatim as a record target, which the validator requires to be
    # an absolute path. A relative path from the install plan must not make
    # our own manifest invalid on the next load.
    if isinstance(dest, str) and os.path.isabs(dest) and not dest.startswith(skip):
        print(dest)
' "$plan" "$skip_prefixes")
}

_get_real_user_backup() {
    # Helper to get real user without sourcing distro.sh (used for user services)
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
    elif [ -n "${USER:-}" ] && [ "$USER" != "root" ]; then
        echo "$USER"
    else
        echo ""
    fi
}

manifest_add_service() {
    # $1=unit $2=component — record the enable/active state of a systemd
    # unit at install time so rollback can restore it on uninstall.
    # First record wins: a reinstall must not overwrite the state captured
    # at the original install, or rollback would undo installer-created state.
    # Supports both system services and user services (--global scope).
    [ "${DRY_RUN:-0}" = "1" ] && {
        log_dryrun "Would record service state: $1"
        return 0
    }
    if ! manifest_load; then
        log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to record service state for $1"
        return 1
    fi
    local is_user=0
    local scope="system"
    # Detect user service by path or --global cat success
    if [ -f "/etc/systemd/user/$1" ] || [ -f "/usr/lib/systemd/user/$1" ]; then
        is_user=1
        scope="user"
    elif systemctl --global cat "$1" > /dev/null 2>&1; then
        is_user=1
        scope="user"
    elif systemctl cat "$1" > /dev/null 2>&1; then
        is_user=0
        scope="system"
    else
        return 0
    fi
    local enabled active
    if [ "$is_user" = "1" ]; then
        systemctl --global is-enabled "$1" > /dev/null 2>&1 && enabled=1 || enabled=0
        local real_user
        real_user="$(_get_real_user_backup)"
        if [ -n "$real_user" ] && [ "$real_user" != "root" ] && id -u "$real_user" > /dev/null 2>&1; then
            local uid
            uid="$(id -u "$real_user" 2> /dev/null || echo "")"
            if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
                sudo -u "$real_user" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user is-active "$1" > /dev/null 2>&1 && active=1 || active=0
            else
                active=0
            fi
        else
            active=0
        fi
    else
        systemctl is-enabled "$1" > /dev/null 2>&1 && enabled=1 || enabled=0
        systemctl is-active "$1" > /dev/null 2>&1 && active=1 || active=0
    fi
    sudo mkdir -p "$MANIFEST_DIR"
    local write_rc=0
    printf '%s' "$MANIFEST_JSON" | sudo python3 -c '
import json, sys, os
mp, name, comp, enabled, active, scope = sys.argv[1:7]
data = json.load(sys.stdin)
data.setdefault("version", "2.0")
data.setdefault("records", [])
data.setdefault("services", [])
data.setdefault("groups", [])
if not any(s.get("name") == name and s.get("component") == comp for s in data["services"]):
    data["services"].append({
        "name": name, "component": comp,
        "was_enabled": enabled == "1", "was_active": active == "1",
        "scope": scope
    })
tmp = mp + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, mp)
' "$MANIFEST_FILE" "$1" "$2" "$enabled" "$active" "$scope" || write_rc=$?
    [ "$write_rc" -le 1 ] || write_rc=1
    return "$write_rc"
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
    if ! manifest_load; then
        log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to record group $2@$1"
        return 1
    fi
    local was_member="${4:-0}"
    if [ "$was_member" != "0" ] && [ "$was_member" != "1" ]; then
        id -nG "$2" 2> /dev/null | tr ' ' '\n' | grep -qx "$1" && was_member=1 || was_member=0
    fi
    sudo mkdir -p "$MANIFEST_DIR"
    local write_rc=0
    printf '%s' "$MANIFEST_JSON" | sudo python3 -c '
import json, sys, os
mp, group, user, comp, member = sys.argv[1:6]
data = json.load(sys.stdin)
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
' "$MANIFEST_FILE" "$1" "$2" "$3" "$was_member" || write_rc=$?
    [ "$write_rc" -le 1 ] || write_rc=1
    return "$write_rc"
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
    # Fail closed BEFORE gpasswd -d (a real side effect): a schema-invalid
    # group record (e.g. was_member="false", truthy in Python) must never be
    # accepted as evidence that we should delete a membership. This also
    # protects the fingerprint/EC uninstall callers of this helper.
    if ! manifest_load; then
        log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to remove group membership for $2@$1"
        return 1
    fi
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
        # was_member is a safety-decision field: only an explicit bool false
        # proves that WE added the membership. Missing/wrong type is unknown,
        # never "false" — keep the membership (fail closed). The validator
        # gate above already rejects such manifests; this is defence in depth
        # for this direct json.load path.
        was_member = g.get("was_member")
        sys.exit(0 if isinstance(was_member, bool) and not was_member else 1)
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
        if ! sudo mkdir -p "$(dirname "$backup_path")"; then
            log_error "Could not create backup directory for $target; refusing to continue"
            return 1
        fi
        if ! sudo cp -a "$target" "$backup_path"; then
            log_error "Could not back up $target -> $backup_path; refusing to continue"
            # Remove a possible partial copy so a failed backup is never
            # mistaken for a complete one by rollback. Keep the guard: only
            # ever delete paths under our own backup base.
            case "$backup_path" in
                "$BACKUP_BASE_DIR"/*) sudo rm -rf -- "$backup_path" ;;
            esac
            return 1
        fi
        log_info "Backed up existing file: $target -> $backup_path"
    fi
    return 0
}

manifest_add_entry() {
    local target="$1"
    local component="$2"
    local was_existing="$3" # 1 = yes, 0 = created new

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Would record in manifest: [$component] $target (existing=$was_existing)"
        return 0
    fi

    # Pseudo-targets are not filesystem paths: fingerprint records
    # "package:libfprint-crfpmoc" after installing a prebuilt package, and the
    # validator requires every record target to be absolute. Writing such a
    # record would make OUR OWN manifest invalid on the next load and fail
    # closed for every component. No caller consumes these pseudo-records, so
    # skip them (successfully) instead of poisoning the manifest.
    if [ -z "${target:-}" ] || [[ "$target" != /* ]]; then
        log_warn "skipping manifest entry with non-absolute target: ${target:-<empty>}"
        return 0
    fi

    # Load (and validate) BEFORE any mkdir/tee/write: a corrupt manifest must
    # never be replaced with an empty skeleton.
    if ! manifest_load; then
        log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to record $target"
        return 1
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
    local write_rc=0
    printf '%s' "$MANIFEST_JSON" | sudo python3 -c '
import json, sys, os
manifest_path, target, comp, existing, ts = sys.argv[1:6]
data = json.load(sys.stdin)

data.setdefault("version", "2.0")
data.setdefault("records", [])
data.setdefault("services", [])
data.setdefault("groups", [])
data["records"] = [r for r in data["records"] if r.get("target") != target]
data["records"].append({
    "target": target,
    "component": comp,
    "was_existing": existing == "1",
    "installed_at": ts
})

tmp_manifest = manifest_path + ".tmp"
with open(tmp_manifest, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp_manifest, manifest_path)
' "$MANIFEST_FILE" "$target" "$component" "$was_existing" "$timestamp" || write_rc=$?
    [ "$write_rc" -le 1 ] || write_rc=1
    return "$write_rc"
}

rollback_component() {
    local target_comp="${1:-all}"
    log_section "Rolling Back / Uninstalling [$target_comp]"

    if [ ! -f "$MANIFEST_FILE" ]; then
        log_warn "No install manifest found at $MANIFEST_FILE. Nothing to rollback automatically."
        return 0
    fi

    # FAIL CLOSED before any mutation. This function used to read the manifest
    # itself (without the validator) and restored services BEFORE files, so a
    # schema-invalid record (e.g. target=12) would mutate services and then
    # throw TypeError at os.path.realpath() — a partial rollback. Validating
    # here, before DRY_RUN and before any service/file side effect, prevents
    # that. The python below consumes this exact validated MANIFEST_JSON.
    if ! manifest_load; then
        log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to roll back $target_comp"
        return 1
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Rollback would process records in $MANIFEST_FILE for component: $target_comp"
        return 0
    fi

    if command -v python3 > /dev/null 2>&1; then
        local allowed_prefixes
        allowed_prefixes="${CROS_ENABLEMENT_ALLOWED_PREFIXES:-/etc/ /usr/ /lib/ /lib64/ /opt/ /var/lib/fprint/}"
        # Capture the python rc: a failed/unknown item must NOT be reported as
        # a successful rollback. Services are restored before files, so a
        # partial failure can leave state behind; the retained manifest
        # records (written back atomically before the python exits non-zero)
        # are what make a later retry possible.
        #
        # Three findings share one invariant here: a record is consumed ONLY
        # after its whole action has been confirmed successful. Every
        # failure/unknown goes into problems[], the whitelists
        # remaining_services / remaining_records keep everything else, and a
        # SINGLE atomic write-back happens BEFORE the single sys.exit(1).
        if ! printf '%s' "$MANIFEST_JSON" | sudo python3 -c '
import json, os, sys, shutil, glob, fnmatch, subprocess

manifest_path = sys.argv[1]
target_comp = sys.argv[2]
backup_base = sys.argv[3]
allowed_prefixes = tuple(sys.argv[4].split())

# Unknown original state is NOT false. A missing/wrong-typed was_* field must
# never authorize a destructive action (delete / disable / stop / gpasswd).
UNKNOWN = object()
problems = []   # single source of truth for the final rc

def in_scope(path):
    # Literal prefix (system defaults like /etc/) or glob pattern (tests)
    return any(path.startswith(p) or fnmatch.fnmatch(path, p) for p in allowed_prefixes)

def problem(kind, detail):
    problems.append("%s %s" % (kind, detail))
    print("  [WARN] %s %s" % (kind, detail), file=sys.stderr)

def run_cmd(argv, name, action):
    """True only when the command exits 0; spawn errors count as failures."""
    try:
        p = subprocess.run(argv, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, text=True,
                           errors="replace", timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        problem("SERVICE_RESTORE_FAILED",
                "name=%s action=%s rc=spawn-error stderr=%s" %
                (name, action, repr(str(e))[:200]))
        return False
    if p.returncode != 0:
        problem("SERVICE_RESTORE_FAILED",
                "name=%s action=%s rc=%d stderr=%s" %
                (name, action, p.returncode,
                 repr((p.stderr or "").strip())[:200]))
        return False
    return True

def user_manager():
    """(user, uid, xdg); xdg == "" means no reachable per-user manager."""
    user = os.environ.get("SUDO_USER", "")
    if not user or user == "root":
        return user, "", ""
    try:
        import pwd
        uid = pwd.getpwnam(user).pw_uid
    except (KeyError, OSError):
        return user, "", ""
    # Test seam: redirect the /run/user lookup into a sandbox. Production
    # uses the real /run/user; tests never write to the host /run.
    xdg_root = os.environ.get("CROS_ENABLEMENT_TEST_XDG_ROOT", "/run/user")
    xdg = os.path.join(xdg_root, str(uid))
    return user, str(uid), xdg if os.path.isdir(xdg) else ""

# Consume the EXACT document that the fail-closed manifest_load gate above
# validated (no second, unvalidated parse; no TOCTOU window). manifest_path
# is still argv[1] for the final atomic write-back.
data = json.load(sys.stdin)

# Restore systemd service states BEFORE touching files, so units are still
# present when systemctl disable/start is called.
# Supports both system and user scopes (scope field added for kbd backlight user service).
data.setdefault("services", [])
services = data["services"]
remaining_services = []
consumed_service_ids = set()   # id(), not dict equality: duplicate records must not be co-consumed

for svc in services:
    if target_comp != "all" and svc.get("component") != target_comp:
        remaining_services.append(svc)
        continue
    name = svc.get("name")
    if not name:
        remaining_services.append(svc)
        continue

    was_enabled = svc.get("was_enabled", UNKNOWN)
    was_active = svc.get("was_active", UNKNOWN)
    if not isinstance(was_enabled, bool) or not isinstance(was_active, bool):
        missing = ",".join(k for k, v in (("was_enabled", was_enabled),
                                          ("was_active", was_active))
                           if not isinstance(v, bool))
        problem("SERVICE_STATE_UNKNOWN",
                "UNKNOWN ORIGINAL STATE name=%s missing_or_invalid=%s; "
                "skipping ALL state changes, record kept" % (name, missing))
        remaining_services.append(svc)
        continue

    scope = svc.get("scope", "system")
    print("Restoring service state: %s (scope=%s)" % (name, scope))
    ok = True
    if scope == "user":
        verb = "enable" if was_enabled else "disable"
        ok = run_cmd(["systemctl", "--global", verb, name],
                     name, "--global " + verb)
        if ok:
            user, uid, xdg = user_manager()
            if xdg:
                verb2 = "start" if was_active else "stop"
                ok = run_cmd(["sudo", "-u", user, "env", "XDG_RUNTIME_DIR=" + xdg,
                              "systemctl", "--user", verb2, name],
                             name, "--user " + verb2)
            elif was_active:
                # was_active=true but no per-user bus: the original active
                # state cannot be reached, so this record is NOT restorable.
                problem("SERVICE_RESTORE_FAILED",
                        "name=%s action=--user start rc=unavailable stderr=%s" %
                        (name, repr("no user manager (SUDO_USER=%s, uid=%s)" %
                                    (user or "<unset>", uid or "<unknown>"))[:200]))
                ok = False
            # was_active=false + no bus: target already stopped; --global
            # disable above prevents auto-start, so the goal is achieved.
    else:
        verb = "enable" if was_enabled else "disable"
        ok = run_cmd(["systemctl", verb, name], name, verb)
        if ok:
            verb = "start" if was_active else "stop"
            ok = run_cmd(["systemctl", verb, name], name, verb)

    if ok:
        consumed_service_ids.add(id(svc))
        print("  [RESTORED SERVICE] %s" % name)
    else:
        print("  [SERVICE RESTORE INCOMPLETE] %s; record kept for retry" % name,
              file=sys.stderr)
        remaining_services.append(svc)

data["services"] = [s for s in services if id(s) not in consumed_service_ids]

records = data.get("records", [])
remaining_records = []
PROTECTED_DIRS = {"/", "/etc", "/usr", "/var", "/bin", "/sbin", "/lib", "/lib64", "/home", "/root"}

def find_first_backup(target):
    # Mirror the "$BACKUP_BASE_DIR/$timestamp$target" layout of backup_file()
    # and the _find_rollback_backup() lookup in install-keyboard.sh. Timestamp prefixes are
    # YYYYMMDD_HHMMSS%N, so sorted()[0] is the FIRST (original) backup.
    # glob.escape keeps []*? in a path literal instead of a pattern.
    pattern = os.path.join(backup_base, "*", glob.escape(target.lstrip("/")))
    matches = sorted(glob.glob(pattern))
    return matches[0] if matches else None

def remove_path(path):
    """Return None on success, an error string on failure; never raise."""
    try:
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
        return None
    except OSError as exc:
        return str(exc)

def restore_original(target, backup):
    """Stage next to the target, then swap atomically. Return None on success."""
    stage = target + ".cros-rollback-tmp-%d" % os.getpid()
    try:
        parent = os.path.dirname(target)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent, exist_ok=True)

        # islink FIRST: os.path.isdir() is also true for a symlink to a dir.
        if os.path.islink(backup):
            os.symlink(os.readlink(backup), stage)
        elif os.path.isdir(backup):
            shutil.copytree(backup, stage, symlinks=True, dirs_exist_ok=True)
            shutil.copystat(backup, stage, follow_symlinks=False)
        else:
            shutil.copy2(backup, stage, follow_symlinks=False)

        # cp -a preserved ownership; copy2/copytree do not. Best effort only:
        # some filesystems reject chown on symlinks, owner is not safety data.
        st = os.lstat(backup)
        try:
            os.chown(stage, st.st_uid, st.st_gid, follow_symlinks=False)
        except (OSError, NotImplementedError):
            pass

        if os.path.isdir(target) and not os.path.islink(target):
            # os.replace() cannot overwrite a non-empty directory: move the
            # old one aside first and put it back if the swap fails.
            old = target + ".cros-rollback-old-%d" % os.getpid()
            os.rename(target, old)
            try:
                os.replace(stage, target)
            except OSError:
                os.rename(old, target)
                raise
            shutil.rmtree(old, ignore_errors=True)
        else:
            if os.path.lexists(target):
                os.remove(target)
            os.replace(stage, target)
        return None
    except OSError as exc:
        try:
            if os.path.isdir(stage) and not os.path.islink(stage):
                shutil.rmtree(stage)
            elif os.path.lexists(stage):
                os.remove(stage)
        except OSError:
            pass
        return str(exc)

for rec in records:
    comp = rec.get("component", "")
    target = rec.get("target", "")

    if target_comp != "all" and comp != target_comp:
        remaining_records.append(rec)
        continue

    was_existing = rec.get("was_existing", UNKNOWN)
    if not isinstance(was_existing, bool):
        problem("RECORD_STATE_UNKNOWN",
                "UNKNOWN ORIGINAL STATE target=%s field=was_existing; "
                "no delete and no restore, record kept" % target)
        remaining_records.append(rec)
        continue

    real = os.path.realpath(target) if target else ""
    if not target or real in PROTECTED_DIRS or not in_scope(real):
        print("  [SKIPPED OUT-OF-SCOPE TARGET] %s" % target, file=sys.stderr)
        remaining_records.append(rec)
        continue

    print("Processing rollback for: %s (component: %s)" % (target, comp))
    if was_existing:
        # Find the first backup REGARDLESS of whether the target still exists.
        # A user or another tool may have removed our installed file; the
        # original must still be restored from the first backup (finding #2).
        backup = find_first_backup(target)
        if backup is None:
            # Keep the record for a later retry, but do NOT invent a file and
            # do NOT fail the whole rollback (matches the historical rc=0).
            print("  [WARN NO BACKUP] %s: original unavailable; record kept" %
                  target, file=sys.stderr)
            remaining_records.append(rec)
            continue
        err = restore_original(target, backup)
        if err is not None:
            problem("RECORD_RESTORE_FAILED",
                    "target=%s backup=%s stderr=%s; record kept" %
                    (target, backup, repr(err)[:200]))
            remaining_records.append(rec)
            continue
        print("  [RESTORED PREVIOUS BACKUP] %s -> %s" % (backup, target))
    else:
        # We created this target: only delete it when it is still present.
        # Absence is a safe no-op (goal already reached) and consumes the record.
        if not os.path.lexists(target):
            print("  [NOTE] %s already absent; nothing to remove" % target)
            continue
        kind = "DIR" if os.path.isdir(target) and not os.path.islink(target) else "FILE"
        err = remove_path(target)
        if err is not None:
            problem("RECORD_REMOVE_FAILED",
                    "target=%s stderr=%s; record kept" % (target, repr(err)[:200]))
            remaining_records.append(rec)
            continue
        print("  [REMOVED %s] %s" % (kind, target))

# SINGLE atomic write-back of the retained records. This MUST happen before
# any non-zero exit, otherwise a failure would erase the records needed for
# the next retry (and erase untouched records of other components as well).
tmp_manifest = manifest_path + ".tmp"
data["records"] = remaining_records
with open(tmp_manifest, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp_manifest, manifest_path)

if problems:
    print("ROLLBACK_INCOMPLETE: %d item(s) retained (see WARN lines above)" %
          len(problems), file=sys.stderr)
    sys.exit(1)
' "$MANIFEST_FILE" "$target_comp" "$BACKUP_BASE_DIR" "$allowed_prefixes"; then
            log_error "rollback of $target_comp failed; service/file state may be partial (retained records remain for retry)"
            return 1
        fi
    else
        log_warn "python3 not found; automatic rollback unavailable. Files may need manual restoration."
    fi

    log_success "Rollback for component [$target_comp] finished!"
}
