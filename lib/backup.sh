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

# ---------------------------------------------------------------------------
# Cross-process transaction lock for the global install manifest.
#
# Every mutation is a read-modify-write over the WHOLE JSON document. Without
# a shared lock, two concurrent installers can both read the same snapshot,
# append their own record and os.replace() it: the last writer silently drops
# the other component's first-wins backup/service/group tracking data (review
# #9 finding #1). The lock is held from the fail-closed validation gate through
# the final atomic replace, and every writer re-reads the manifest *inside* the
# lock so it never mutates a stale snapshot.
#
# Design details (re-review #10 findings #2 and #3, fixed together):
#  - the lock file is root-owned 0600 next to the manifest (same filesystem).
#    An unprivileged account cannot even open it, so it cannot hold an
#    exclusive flock and starve every installer for the whole wait window;
#  - a non-root installer therefore cannot open the lock itself. Acquisition
#    is delegated to a short-lived ROOT holder started with `coproc`:
#    `sudo bash -c HELPER`. The helper owns fd 9, verifies fd<->path
#    inode/owner/type/mode INSIDE the process that actually holds fd 9 (real
#    sudo closes inherited fds, so a separate `sudo python3 fstat(9)` would be
#    both wrong on a real system and stub-green in tests), takes the bounded
#    `flock -x -w TIMEOUT`, prints READY, then blocks reading its stdin;
#  - the bash parent controls the helper's lifetime only via the coproc pipe:
#    closing the write fd makes the helper see EOF, exit and let the kernel
#    release the flock. There is deliberately NO EXIT/INT/TERM trap: a killed
#    installer closes its pipe too, so no stale lock can survive a crash;
#  - MANIFEST_LOCK_DEPTH makes nested public helpers (backup gate -> add_entry,
#    ensure_group_membership -> has_group/add_group/remove_group) re-entrant
#    without spawning a second holder (which would deadlock against ourselves);
#  - missing/broken flock, a symlink/non-regular lock, a swapped inode or a
#    bad parent directory all fail closed (mutation returns 1, bytes intact);
#    re-review #11 finding #3 tightens this further: only a root-controlled
#    parent (and root-controlled ancestors) may host the lock, because the
#    parent's owner can rename a live lock and let a second process lock a
#    brand-new inode. The holder pins the direct parent with fd 8 too.
#  - DRY_RUN callers return BEFORE this lock, so no lock file is created;
#  - manifest_load() itself stays lock-free (pure reader): the public entry
#    point owns the lock and calls manifest_load() again inside it.
# ---------------------------------------------------------------------------
MANIFEST_LOCK_FILE="$MANIFEST_DIR/.install-manifest.lock"
# shellcheck disable=SC2034 # fd number is used by the root holder below
MANIFEST_LOCK_FD=9
MANIFEST_LOCK_DEPTH=0
MANIFEST_LOCK_TIMEOUT="${CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT:-10}"
MANIFEST_LOCK_HOLDER_PID=""
MANIFEST_LOCK_HOLDER_RFD=""
MANIFEST_LOCK_HOLDER_WFD=""
# Re-review #12 finding #1: canonical, symlink-free lock parent/lock resolved by
# the gate below. Empty when a test deliberately overrides _manifest_lock_dir_ok
# to exercise the root holder alone; the holder then falls back to the literal
# path and its own rechecks still fail closed.
MANIFEST_LOCK_CANON_DIR=""
MANIFEST_LOCK_CANON_FILE=""

# Pure-bash ancestor gate (no sudo, no python3). Anyone who can write a
# directory on the path can rename the lock pathname out from under a live
# holder, so every existing layer must be root-controlled. A ROOT-owned sticky
# world-writable layer (e.g. /tmp) is the one exception: there a non-owner
# cannot rename or unlink somebody else's entry, while the owner is root.
_manifest_lock_ancestors_ok() {
    local dir="$1" p pp meta uid mode
    p="${dir%/}"
    [ -n "$p" ] || p="/"
    while :; do
        if [ -L "$p" ]; then
            # A symlink is only trustworthy when only root can replace it (its
            # containing directory is root-owned and not group/other-writable).
            pp="${p%/*}"
            [ -n "$pp" ] || pp="/"
            meta="$(stat -c '%u|%a' -- "$pp" 2> /dev/null)" || {
                log_error "Cannot stat manifest lock ancestor parent $pp; refusing to lock"
                return 1
            }
            uid="${meta%%|*}"
            mode="${meta#*|}"
            if [ "$uid" != 0 ] || [ -z "$mode" ] \
                || [ $(((8#$mode & 022) != 0)) -eq 1 ] || [ ! -d "$p" ]; then
                log_error "Manifest lock ancestor $p is an untrusted symlink; refusing to lock"
                return 1
            fi
        elif [ -d "$p" ]; then
            # A missing layer is skipped (init creates it as root and re-checks
            # afterwards), but higher ancestors are still walked and checked.
            meta="$(stat -c '%u|%a' -- "$p" 2> /dev/null)" || {
                log_error "Cannot stat manifest lock ancestor $p; refusing to lock"
                return 1
            }
            uid="${meta%%|*}"
            mode="${meta#*|}"
            if [ -z "$mode" ]; then
                log_error "Manifest lock ancestor $p is not root-controlled (uid=$uid mode=$mode); refusing to lock"
                return 1
            fi
            if [ "$uid" != 0 ] \
                || { [ $(((8#$mode & 022) != 0)) -eq 1 ] && [ $(((8#$mode & 01000) == 0)) -eq 1 ]; }; then
                log_error "Manifest lock ancestor $p is not root-controlled (uid=$uid mode=$mode); refusing to lock"
                return 1
            fi
        fi
        [ "$p" = "/" ] && break
        case "$p" in
            */*)
                p="${p%/*}"
                [ -n "$p" ] || p="/"
                ;;
            *) p="/" ;;
        esac
    done
    return 0
}

# Re-review #12 finding #1: CROS_ENABLEMENT_MANIFEST_DIR may be RELATIVE, or
# may traverse a symlink whose real target lives in a user-owned directory. The
# old walker only inspected literal components, so it could accept a path while
# the directory that can actually rename the lock is user-controlled. Require
# an absolute path, reject literal symlinks, canonicalize the deepest EXISTING
# prefix (realpath -e; init creates missing layers and re-checks), then run the
# root-controlled ancestor gate on the REAL path.
_manifest_lock_literal_no_symlink() {
    local dir="$1" rest cur comp
    rest="${dir#/}"
    cur=""
    while [ -n "$rest" ]; do
        comp="${rest%%/*}"
        if [ -n "$comp" ]; then
            cur="$cur/$comp"
            if [ -L "$cur" ]; then
                log_error "Manifest lock directory $dir contains a symlink ($cur); untrusted symlink; refusing to lock"
                return 1
            fi
        fi
        case "$rest" in
            */*) rest="${rest#*/}" ;;
            *) rest="" ;;
        esac
    done
    return 0
}

# Echoes the canonical (symlink-free, absolute) lock parent, or fails closed.
_manifest_lock_canonical_dir() {
    local dir="$1" probe suffix="" canon
    case "$dir" in
        /*) ;;
        *)
            log_error "Manifest directory $dir must be an absolute path; refusing to lock"
            return 1
            ;;
    esac
    _manifest_lock_literal_no_symlink "$dir" || return 1
    probe="$dir"
    while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do
        suffix="/${probe##*/}$suffix"
        probe="${probe%/*}"
        [ -n "$probe" ] || probe="/"
    done
    if ! canon="$(realpath -e -- "$probe" 2> /dev/null)"; then
        log_error "Cannot canonicalize manifest lock parent $dir; refusing to lock"
        return 1
    fi
    canon="${canon%/}"
    [ -n "$canon" ] || canon="/"
    canon="$canon$suffix"
    if ! _manifest_lock_ancestors_ok "$canon"; then
        log_error "Manifest lock canonical path $canon has an untrusted realpath ancestor; refusing to lock"
        return 1
    fi
    printf '%s\n' "$canon"
}

# Direct-parent type/owner/mode check, shared by the literal and canonical
# paths. The literal pass is first so the long-standing S6/S7/S10 diagnostics
# (group/other-writable, is a symlink or not a directory, must be root-owned)
# are preserved; the canonical pass is what actually enforces the trust
# boundary when a symlink hides the real target.
_manifest_lock_parent_perm_ok() {
    local dir="$1" meta uid mode
    if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
        log_error "Manifest lock parent $dir is a symlink or not a directory; refusing to lock"
        return 1
    fi
    if [ -e "$dir" ]; then
        meta="$(stat -c '%u|%a' -- "$dir" 2> /dev/null)" || {
            log_error "Cannot stat manifest lock parent $dir; refusing to lock"
            return 1
        }
        uid="${meta%%|*}"
        mode="${meta#*|}"
        if [ "$uid" != 0 ]; then
            log_error "Manifest lock parent $dir is owned by uid $uid (must be root-owned); refusing to lock"
            return 1
        fi
        if [ -z "$mode" ] || [ $(((8#$mode & 022) != 0)) -eq 1 ]; then
            log_error "Manifest lock parent $dir is group/other-writable (mode $mode); refusing to lock"
            return 1
        fi
    fi
    return 0
}

# Keeps the original (dir) signature so test overrides still work; publishes
# the canonical parent/lock for init() and the root holder.
_manifest_lock_dir_ok() {
    local dir="$1" canon base
    _manifest_lock_parent_perm_ok "$dir" || return 1
    if ! canon="$(_manifest_lock_canonical_dir "$dir")"; then return 1; fi
    [ -n "$canon" ] || return 1
    _manifest_lock_parent_perm_ok "$canon" || return 1
    base="${MANIFEST_LOCK_FILE##*/}"
    [ -n "$base" ] || base=".install-manifest.lock"
    MANIFEST_LOCK_CANON_DIR="$canon"
    MANIFEST_LOCK_CANON_FILE="$canon/$base"
    return 0
}

manifest_lock_init() {
    local lock="$MANIFEST_LOCK_FILE" dir="$MANIFEST_DIR" meta owner mode
    MANIFEST_LOCK_CANON_DIR=""
    MANIFEST_LOCK_CANON_FILE=""
    _manifest_lock_dir_ok "$dir" || return 1
    # The canonical path is empty only when a test overrides the gate to
    # exercise the root holder alone (S10c); keep the literal path in that case.
    dir="${MANIFEST_LOCK_CANON_DIR:-$dir}"
    lock="${MANIFEST_LOCK_CANON_FILE:-$lock}"

    # Reject symlinks and EVERY non-regular type before any open or chmod:
    # `exec 9< directory` succeeds on Linux and a FIFO would block forever.
    if [ -L "$lock" ]; then
        log_error "Manifest lock path $lock is a symlink; refusing to lock"
        return 1
    fi
    if [ -e "$lock" ] && [ ! -f "$lock" ]; then
        log_error "Manifest lock path $lock is not a regular file; refusing to lock"
        return 1
    fi
    if [ ! -e "$lock" ]; then
        sudo mkdir -p "$dir" || {
            log_error "Could not create manifest dir $dir"
            return 1
        }
        # Re-run the gate on the canonical directory after mkdir creates any
        # missing layers, so the final on-disk owner/mode are checked too.
        _manifest_lock_dir_ok "$dir" || return 1
        dir="${MANIFEST_LOCK_CANON_DIR:-$dir}"
        lock="${MANIFEST_LOCK_CANON_FILE:-$lock}"
        # NEVER use `install`: it replaces the destination inode on every call.
        # `set -C` is O_EXCL|O_NOFOLLOW (it rejects an existing symlink too),
        # and umask 077 makes the single creation root:0600 atomically.
        if ! { sudo sh -c 'umask 077; set -C; : > "$1"' _ "$lock"; } 2> /dev/null; then
            # Losing the creation race is fine only if the winner left a
            # regular file behind; anything else fails closed.
            if [ -L "$lock" ] || [ ! -f "$lock" ]; then
                log_error "Could not create manifest lock $lock"
                return 1
            fi
        fi
    fi

    # The parent directory is not group/other-writable, so hardening a path we
    # have just confirmed to be a regular non-symlink cannot be redirected by
    # an unprivileged account to somebody else's inode.
    meta="$(stat -c '%u|%a' -- "$lock" 2> /dev/null)" || {
        log_error "Cannot stat manifest lock $lock; refusing to lock"
        return 1
    }
    owner="${meta%%|*}"
    mode="${meta#*|}"
    if [ "$owner" != 0 ]; then
        # Self-owned leftovers (e.g. a stubbed sudo run as the current user)
        # are repairable; a third-party owner is a hard failure.
        if [ "$owner" = "${EUID:-$(id -u)}" ] || [ "$owner" = "${UID:-$(id -u)}" ]; then
            if ! sudo chown 0:0 "$lock" 2> /dev/null; then
                log_error "Could not set manifest lock owner to root; refusing to lock"
                return 1
            fi
        else
            log_error "Manifest lock $lock is owned by uid $owner (not root); refusing to lock"
            return 1
        fi
    fi
    # Existing 0644 locks left by older versions must be tightened.
    if [ "$(stat -c '%a' -- "$lock" 2> /dev/null)" != 600 ]; then
        if ! sudo chmod 0600 "$lock" 2> /dev/null; then
            log_error "Could not set manifest lock mode to 0600; refusing to lock"
            return 1
        fi
    fi
    # Re-check the FINAL on-disk state: a stubbed or broken sudo must never let
    # us proceed with a lock an unprivileged account can open.
    meta="$(stat -c '%u|%a' -- "$lock" 2> /dev/null)" || {
        log_error "Cannot stat manifest lock $lock; refusing to lock"
        return 1
    }
    owner="${meta%%|*}"
    mode="${meta#*|}"
    if [ -L "$lock" ] || [ ! -f "$lock" ] || [ "$owner" != 0 ] || [ "$mode" != 600 ]; then
        log_error "Manifest lock $lock is not a root-owned 0600 regular file (uid=$owner mode=$mode); refusing to lock"
        return 1
    fi
    return 0
}

# Runs as `sudo bash -c` inside the coproc, i.e. as root and with fd 9 owned by
# this very process. Everything security-relevant is checked HERE, after open,
# so it cannot be fooled by a path swap between init and acquisition. The
# trailing `read` is the lifetime leash: EOF on stdin means the parent is gone.
# shellcheck disable=SC2034 # assigned and consumed by the helper process
_MANIFEST_LOCK_HOLDER_SH='
lock=$1
timeout=$2
if [ -L "$lock" ]; then printf "FAILED:symlink\n"; exit 1; fi
# -f is locale-independent and true for both empty and non-empty regular
# files; it rejects directories and FIFOs BEFORE open (opening a FIFO blocks).
if [ ! -f "$lock" ]; then printf "FAILED:type\n"; exit 1; fi
if ! { exec 9< "$lock"; } 2>/dev/null; then printf "FAILED:open\n"; exit 1; fi
path_ino=$(stat -c %i -- "$lock" 2>/dev/null || echo "")
path_dev=$(stat -c %d -- "$lock" 2>/dev/null || echo "")
fd_ino=$(stat -Lc %i -- /proc/$$/fd/9 2>/dev/null || echo "")
fd_dev=$(stat -Lc %d -- /proc/$$/fd/9 2>/dev/null || echo "")
fd_uid=$(stat -Lc %u -- /proc/$$/fd/9 2>/dev/null || echo "")
fd_mode=$(stat -Lc %a -- /proc/$$/fd/9 2>/dev/null || echo "")
fd_ftype=$(stat -Lc %f -- /proc/$$/fd/9 2>/dev/null || echo "")
# Re-review #11 finding #3: pin the DIRECT parent with fd 8 INSIDE the process
# that holds fd 9. A stale parent-shell stat, or an ancestor the caller can
# rename, must never let us lock a path whose parent an attacker controls.
dir=${lock%/*}; [ -n "$dir" ] || dir=/
# Re-review #12: the parent hands us a canonical path; re-derive it HERE,
# inside the process that actually holds fd 9. A symlink swapped in after the
# parent-shell gate must be rejected before any flock is taken.
cdir=$(realpath -e -- "$dir" 2>/dev/null || echo "")
if [ -z "$cdir" ] || [ "$cdir" != "$dir" ]; then printf "FAILED:canonical\n"; exit 1; fi
if ! { exec 8< "$dir"; } 2>/dev/null; then printf "FAILED:parentdir\n"; exit 1; fi
dm="$(stat -Lc "%u|%a|%i|%d|%f" -- /proc/$$/fd/8 2>/dev/null || echo "")"
du=${dm%%|*}; r=${dm#*|}; dmode=${r%%|*}; r=${r#*|}; dino=${r%%|*}; r=${r#*|}; ddev=${r%%|*}; dtype=${r#*|}
pdi=$(stat -c %i -- "$dir" 2>/dev/null || echo "")
pdd=$(stat -c %d -- "$dir" 2>/dev/null || echo "")
if [ -z "$dm" ] || [ -z "$du" ] || [ -z "$dmode" ] || [ -z "$dino" ] || [ -z "$ddev" ] ||
   [ -z "$dtype" ] || [ -z "$pdi" ] || [ -z "$pdd" ] || [ "$du" != 0 ] ||
   [ $(((8#$dmode & 022) != 0)) -eq 1 ] ||
   [ $(((16#$dtype & 0170000) != 0040000)) -eq 1 ] ||
   [ "$pdi" != "$dino" ] || [ "$pdd" != "$ddev" ]; then
    printf "FAILED:parentdir\n"; exit 1
fi
# Re-review #12: every REAL ancestor (not just the direct parent) must be
# root-controlled, with the root-owned sticky (/tmp) exception preserved.
# This runs AFTER the fd-8 parent check so S10c keeps its FAILED:parentdir
# diagnostic when the direct parent itself is caller-owned.
p="$dir"
while :; do
    am="$(stat -Lc "%u|%a" -- "$p" 2>/dev/null || echo "")"
    [ -n "$am" ] || { printf "FAILED:ancestor\n"; exit 1; }
    au=${am%%|*}; amode=${am#*|}
    bad=0
    [ "$au" = 0 ] || bad=1
    if [ $(((8#$amode & 022) != 0)) -eq 1 ] && [ $(((8#$amode & 01000) == 0)) -eq 1 ]; then bad=1; fi
    [ "$bad" -eq 0 ] || { printf "FAILED:ancestor\n"; exit 1; }
    [ "$p" = "/" ] && break
    p="${p%/*}"; [ -n "$p" ] || p="/"
done
if [ -z "$path_ino" ] || [ -z "$path_dev" ] || [ -z "$fd_ino" ] || [ -z "$fd_dev" ] ||
   [ -z "$fd_uid" ] || [ -z "$fd_mode" ] || [ -z "$fd_ftype" ] ||
   [ "$path_ino" != "$fd_ino" ] || [ "$path_dev" != "$fd_dev" ] ||
   [ "$fd_uid" != 0 ] || [ "$fd_mode" != 600 ] ||
   [ $(( (16#$fd_ftype & 0170000) )) -ne $((0100000)) ]; then
    printf "FAILED:inode\n"; exit 1
fi
if ! flock -x -w "$timeout" 9; then printf "FAILED:flock\n"; exit 1; fi
printf "READY\n"
IFS= read -r _ || true
exit 0
'

_manifest_lock_release() {
    # Order matters: close the READ fd, then the WRITE fd (that EOF is what
    # makes the helper exit and drop the flock), and only then reap it.
    if [ -n "$MANIFEST_LOCK_HOLDER_RFD" ]; then
        # shellcheck disable=SC2294
        eval "exec ${MANIFEST_LOCK_HOLDER_RFD}<&-" 2> /dev/null || true
    fi
    if [ -n "$MANIFEST_LOCK_HOLDER_WFD" ]; then
        # shellcheck disable=SC2294
        eval "exec ${MANIFEST_LOCK_HOLDER_WFD}>&-" 2> /dev/null || true
    fi
    if [ -n "$MANIFEST_LOCK_HOLDER_PID" ]; then
        wait "$MANIFEST_LOCK_HOLDER_PID" 2> /dev/null || true
    fi
    MANIFEST_LOCK_HOLDER_PID=""
    MANIFEST_LOCK_HOLDER_RFD=""
    MANIFEST_LOCK_HOLDER_WFD=""
    MANIFEST_LOCK_DEPTH=0
}

manifest_lock() {
    if [ "$MANIFEST_LOCK_DEPTH" -gt 0 ]; then
        # Already held by this process: just track nesting. A second holder
        # would block on our own flock and deadlock.
        MANIFEST_LOCK_DEPTH=$((MANIFEST_LOCK_DEPTH + 1))
        return 0
    fi
    if ! command -v flock > /dev/null 2>&1; then
        log_error "flock not found; refusing manifest mutation (install util-linux)"
        return 1
    fi
    # A still-running holder means a previous acquisition was never released;
    # spawning a second coproc with the same name would be ambiguous.
    if [ -n "$MANIFEST_LOCK_HOLDER_PID" ] && kill -0 "$MANIFEST_LOCK_HOLDER_PID" 2> /dev/null; then
        log_error "Manifest lock holder pid $MANIFEST_LOCK_HOLDER_PID still alive; refusing to lock"
        return 1
    fi
    manifest_lock_init || return 1

    coproc MANIFEST_LOCK_HOLDER {
        sudo bash -c "$_MANIFEST_LOCK_HOLDER_SH" _ "${MANIFEST_LOCK_CANON_FILE:-$MANIFEST_LOCK_FILE}" "$MANIFEST_LOCK_TIMEOUT"
    }
    MANIFEST_LOCK_HOLDER_RFD="${MANIFEST_LOCK_HOLDER[0]}"
    MANIFEST_LOCK_HOLDER_WFD="${MANIFEST_LOCK_HOLDER[1]}"
    local line="" rc=0
    if ! IFS= read -r -t "$((MANIFEST_LOCK_TIMEOUT + 3))" -u "$MANIFEST_LOCK_HOLDER_RFD" line; then
        rc=1
    fi
    if [ "$line" != "READY" ]; then
        [ "$rc" -ne 0 ] || rc=1
        log_error "Manifest lock wait failed (rc=$rc after ${MANIFEST_LOCK_TIMEOUT}s) on $MANIFEST_LOCK_FILE (holder: ${line:-no response}); refusing to write"
        _manifest_lock_release
        return 1
    fi
    MANIFEST_LOCK_DEPTH=1
    return 0
}

manifest_unlock() {
    if [ "$MANIFEST_LOCK_DEPTH" -gt 0 ]; then
        MANIFEST_LOCK_DEPTH=$((MANIFEST_LOCK_DEPTH - 1))
    fi
    if [ "$MANIFEST_LOCK_DEPTH" -eq 0 ]; then
        # Always release: even when the python writer returned non-zero the
        # caller must not leak the flock to the next mutation.
        _manifest_lock_release
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Operation-level transaction lock (re-review #10 finding #1).
#
# The metadata helpers above release the lock before returning, so an
# installer that does "backup_file_manifest_aware -> sudo install -D" still
# leaves a window where a concurrent uninstall can consume the just-written
# `was_existing=false` record while the target is absent. The deployed file
# then exists with NO manifest record, so no later uninstall can remove it.
# Installers therefore call THIS once around the whole component operation
# (backup/record -> deploy -> finish/rollback), using MANIFEST_LOCK_DEPTH for
# all the nested helpers (backup gate, group helpers, keyd normalization,
# rollback_component) so they never spawn a second holder.
#
# The body is invoked with a BARE call on purpose. `|| rc=$?` or
# `if "$fn"; then` makes bash ignore `set -e` inside the body, so an
# unguarded failed backup gate would silently fall through to `sudo install`
# (fail-open deployment). With a bare call, an errexit-aborted body kills the
# shell at that line; the root holder's coproc pipe sees EOF and the kernel
# releases the flock (crash-safe, SEC T12). Deliberately NO EXIT trap here:
# it would clobber the fingerprint installer's existing EXIT/INT/TERM trap.
# ---------------------------------------------------------------------------
run_manifest_operation() {
    local fn="${1:-}"
    if [ -z "$fn" ] || ! declare -F "$fn" > /dev/null 2>&1; then
        log_error "run_manifest_operation: invalid function '${fn:-<empty>}'"
        return 1
    fi
    shift
    if [ "${DRY_RUN:-0}" = "1" ]; then
        "$fn" "$@" # no lock / no lock file in dry-run (T6)
        return $?
    fi
    manifest_lock || return 1 # fail closed BEFORE any side effect
    "$fn" "$@"                # BARE call: preserve caller's errexit semantics
    local rc=$?
    manifest_unlock
    return "$rc"
}

# Shared durability helper injected into every manifest WRITER's `-c` script.
# Keeping one implementation here avoids six subtly different copies while
# leaving each writer's argv (and therefore the test-stub contract) unchanged.
# A UNIQUE same-directory temp replaces the old shared "$MANIFEST_FILE.tmp":
# concurrent writers can never overwrite each other's temp, and os.replace()
# stays atomic. The dir fsync is best effort; every failure unlinks the temp.
_MANIFEST_ATOMIC_WRITE_PY='
import tempfile

def atomic_write_json(mp, data):
    d = os.path.dirname(os.path.abspath(mp))
    fd, tmp = tempfile.mkstemp(prefix=".install-manifest.", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, mp)
        try:
            dfd = os.open(d, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except OSError:
            pass
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
'

# Ownership of a (group,user) membership is decided by the EARLIEST observed
# state across ALL components, not by the component currently uninstalling.
# A full install records keyboard:was_member=false then
# fingerprint:was_member=true (same pair); each component's own record alone
# cannot answer "did we add this membership?", so uninstall must aggregate.
# rc 0 = at least one component recorded was_member=false, OR any record has
#        added_by_project=true (per-install evidence that we re-added the user
#        after an earlier true snapshot) => we added it
# rc 1 = NO record for this (group,user) => nothing to roll back
# rc 3 = every record was_member=true AND no added_by_project flag =>
#        pre-existing; metadata is stale once no component/udev rule needs the
#        group (consume it, NO gpasswd)
# rc 2 = unreadable / wrong safety-field type => caller fails closed
# argc = 6 (python3 -c SCRIPT mp group user): below every writer-stub threshold
# used by the test suite, and it does not contain any rollback-fault marker.
_GROUP_OWNERSHIP_PY='
import json, sys, os
mp, group, user = sys.argv[1:4]
if not os.path.exists(mp):
    sys.exit(2)
try:
    with open(mp) as f:
        data = json.load(f)
except Exception:
    sys.exit(2)
matches = [g for g in data.get("groups", [])
           if isinstance(g, dict) and g.get("group") == group and g.get("user") == user]
if not matches:
    sys.exit(1)
for g in matches:
    w = g.get("was_member")
    if not isinstance(w, bool):
        sys.exit(2)          # defence in depth; the validator gate rejects this too
    if "added_by_project" in g and not isinstance(g["added_by_project"], bool):
        sys.exit(2)          # defence in depth; wrong type is never permission evidence
for g in matches:
    if g["was_member"] is False or g.get("added_by_project") is True:
        sys.exit(0)          # explicit false OR a per-install added flag proves we added it
sys.exit(3)                  # all true, no added flag: pre-existing, safe to drop stale metadata
'

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
# normalised/defaulted. groups[*].added_by_project is OPTIONAL per-install
# evidence (missing = legacy false, meaning "no extra evidence"): a present
# field with the wrong type is still invalid and fails closed. Canonical output
# never injects it into existing records (first-wins byte semantics).
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
    check(grp, "group",             "str",  where, required=True)
    check(grp, "user",              "str",  where, required=True)
    check(grp, "component",         "str",  where, required=True)
    check(grp, "was_member",        "bool", where, required=True)
    check(grp, "added_by_project",  "bool", where)   # optional; wrong type -> invalid

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

manifest_has_group() {
    # $1=group $2=user $3=component
    # 0 = a record already exists (first-wins: it must never be rolled back by
    #     a later failed attempt), 1 = no record, 2 = manifest corrupt/unreadable
    #     (fail closed; caller must not touch group membership).
    # Reuses the validator-backed manifest_load exactly like manifest_has_target
    # so a corrupt manifest can never be mistaken for "no record". The probe is
    # argc=5 (python3 -c SCRIPT group user component), below every writer stub
    # threshold used by the test suite.
    if ! manifest_load; then
        return 2
    fi
    if [ "$MANIFEST_CREATED" = "1" ]; then
        # No manifest file yet: there are no group records to find. Avoid
        # python3 here, mirroring manifest_has_target's no-python3 behaviour.
        return 1
    fi
    local rc=0
    printf '%s' "$MANIFEST_JSON" | python3 -c '
import json, sys
group, user, comp = sys.argv[1:4]
data = json.load(sys.stdin)
if any(g.get("group") == group and g.get("user") == user and g.get("component") == comp
        for g in data.get("groups", [])):
    sys.exit(0)
sys.exit(1)
' "$1" "$2" "$3" 2> /dev/null || rc=$?
    [ "$rc" -le 1 ] || rc=2
    return "$rc"
}

_backup_file_manifest_aware_body() {
    # Gate -> backup -> record as ONE transaction. Called with the manifest
    # lock already held (or in DRY_RUN, where every helper is a no-op logger).
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

backup_file_manifest_aware() {
    # $1=target $2=component
    # On re-install of an already-tracked target, keep the ORIGINAL backup
    # (first backup) instead of overwriting it with our custom version, so
    # rollback can always restore the pre-customization file.
    #
    # The first-wins GATE and the record WRITE must be one transaction: holding
    # the lock across both means a concurrent installer cannot slip a record in
    # between "is this tracked?" and "append my record" (review #9 finding #1).
    local target="$1" component="$2"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        # No lock in dry-run: no lock file / sudo side effects. The body's
        # helpers each log their own dry-run message and return 0.
        _backup_file_manifest_aware_body "$target" "$component" || return $?
        return 0
    fi
    manifest_lock || return 1
    local rc=0
    _backup_file_manifest_aware_body "$target" "$component" || rc=$?
    manifest_unlock
    return "$rc"
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

_manifest_add_service_body() {
    # Ratified inside the manifest lock: manifest_load() re-reads the latest
    # bytes so the first-wins check in python operates on a fresh snapshot.
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
    # argv is UNCHANGED (argc=8): the helper is part of the -c script, not an
    # extra argument, so the existing python stubs keep matching.
    printf '%s' "$MANIFEST_JSON" | sudo python3 -c "$_MANIFEST_ATOMIC_WRITE_PY"'import json, sys, os
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
atomic_write_json(mp, data)
' "$MANIFEST_FILE" "$1" "$2" "$enabled" "$active" "$scope" || write_rc=$?
    [ "$write_rc" -le 1 ] || write_rc=1
    return "$write_rc"
}

manifest_add_service() {
    # $1=unit $2=component — record the enable/active state of a systemd
    # unit at install time so rollback can restore it on uninstall.
    # First record wins: a reinstall must not overwrite the state captured
    # at the original install, or rollback would undo installer-created state.
    # Supports both system services and user services (--global scope).
    # DRY_RUN returns BEFORE the lock so no lock file/sudo call is made.
    [ "${DRY_RUN:-0}" = "1" ] && {
        log_dryrun "Would record service state: $1"
        return 0
    }
    manifest_lock || return 1
    local rc=0
    _manifest_add_service_body "$@" || rc=$?
    manifest_unlock
    return "$rc"
}

_manifest_add_group_body() {
    if ! manifest_load; then
        log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to record group $2@$1"
        return 1
    fi
    local was_member="${4:-0}"
    if [ "$was_member" != "0" ] && [ "$was_member" != "1" ]; then
        id -nG "$2" 2> /dev/null | tr ' ' '\n' | grep -qx "$1" && was_member=1 || was_member=0
    fi
    # $5=mark_added (0/1): per-install evidence that THIS attempt re-added the
    # user after an earlier true snapshot (admin removed membership while the
    # component was still installed). Anything else is treated as 0.
    local mark_added="${5:-0}"
    case "$mark_added" in
        0 | 1) ;;
        *) mark_added=0 ;;
    esac
    sudo mkdir -p "$MANIFEST_DIR"
    local write_rc=0
    # argc=8 (python3 -c SCRIPT mp group user comp member mark): still matches
    # block_group_manifest_write (argc>=7 + was_member marker) for T1/T6.
    printf '%s' "$MANIFEST_JSON" | sudo python3 -c "$_MANIFEST_ATOMIC_WRITE_PY"'import json, sys, os
mp, group, user, comp, member, mark = sys.argv[1:7]
data = json.load(sys.stdin)
data.setdefault("version", "2.0")
data.setdefault("records", [])
data.setdefault("services", [])
data.setdefault("groups", [])
existing = [g for g in data["groups"]
            if g.get("group") == group and g.get("user") == user and g.get("component") == comp]
if existing:
    # first-wins: was_member and any existing value are NEVER changed. Only ADD
    # the new evidence when the original snapshot was true and this attempt
    # really re-added the user; an original false is already proof by itself.
    if mark == "1" and all(g.get("was_member") is True for g in existing):
        for g in existing:
            g["added_by_project"] = True
else:
    data["groups"].append({
        "group": group, "user": user, "component": comp,
        "was_member": member == "1",
        "added_by_project": mark == "1",
    })
atomic_write_json(mp, data)
' "$MANIFEST_FILE" "$1" "$2" "$3" "$was_member" "$mark_added" || write_rc=$?
    [ "$write_rc" -le 1 ] || write_rc=1
    return "$write_rc"
}

manifest_add_group() {
    # $1=group $2=user $3=component [$4=was_member override: 0/1]
    # [$5=mark_added override: 0/1] — record whether the user was already a
    # member of the group BEFORE we added them (snapshot it before usermod), so
    # uninstall only removes memberships we created. First record wins: a
    # reinstall must not overwrite the membership state captured at the
    # original install. mark_added stores per-install evidence (only when the
    # original was_member is true); it is cleared by manifest_clear_group_added
    # if this attempt's usermod fails.
    [ -z "$2" ] || [ "$2" = "root" ] && return 0
    [ "${DRY_RUN:-0}" = "1" ] && {
        log_dryrun "Would record group: $2@$1"
        return 0
    }
    manifest_lock || return 1
    local rc=0
    _manifest_add_group_body "$@" || rc=$?
    manifest_unlock
    return "$rc"
}

# Re-review #13 (P2 CONDITIONAL PERMISSION LIFECYCLE): if usermod -aG fails
# AFTER we persisted an added_by_project flag, clear ONLY that flag. The
# original first-wins record (and its was_member) is never removed here (T6).
# The script carries the unique # GROUP_ADDED_FLAG_CLEAR marker for precise
# fault injection; argc=6 and neither was_member nor GROUP_CONSUME_ALL appears
# in the script, so no existing writer-fault stub intercepts it.
_clear_group_added_body() {
    if ! manifest_load; then
        log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to clear group-added evidence for $2@$1"
        return 1
    fi
    printf '%s' "$MANIFEST_JSON" | sudo python3 -c "$_MANIFEST_ATOMIC_WRITE_PY"'# GROUP_ADDED_FLAG_CLEAR
import json, sys, os
mp, group, user, comp = sys.argv[1:5]
data = json.load(sys.stdin)
data.setdefault("groups", [])
changed = False
for g in data["groups"]:
    if (g.get("group") == group and g.get("user") == user and g.get("component") == comp
            and g.get("added_by_project") is True):
        g["added_by_project"] = False
        changed = True
if changed:
    atomic_write_json(mp, data)
' "$MANIFEST_FILE" "$1" "$2" "$3"
}

manifest_clear_group_added() {
    # $1=group $2=user $3=component — clear per-install added evidence only
    # after a FAILED usermod. DRY_RUN and a missing manifest are no-ops.
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    [ -f "$MANIFEST_FILE" ] || return 0
    manifest_lock || return 1
    local rc=0
    _clear_group_added_body "$@" || rc=$?
    manifest_unlock
    return "$rc"
}

_manifest_remove_group_body() {
    # Held under the lock: python's own json.load() therefore sees the same
    # stable bytes that the manifest_load() gate validated.
    if ! manifest_load; then
        log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to remove group record $2@$1"
        return 1
    fi
    sudo python3 -c "$_MANIFEST_ATOMIC_WRITE_PY"'import json, sys, os
mp, group, user, comp = sys.argv[1:5]
if not os.path.exists(mp):
    sys.exit(0)
d = json.load(open(mp))
d.setdefault("groups", [])
before = len(d["groups"])
d["groups"] = [g for g in d["groups"]
               if not (g.get("group") == group and g.get("user") == user
                       and g.get("component") == comp)]
if len(d["groups"]) == before:
    sys.exit(0)          # no matching record: do not rewrite the file at all
atomic_write_json(mp, d)
' "$MANIFEST_FILE" "$1" "$2" "$3"
}

manifest_remove_group() {
    # $1=group $2=user $3=component — remove EXACTLY one group record with a
    # precise list filter + atomic os.replace (never sed/text substitution), so
    # records of other users/components and all records/services stay intact.
    # Shared by the install rollback path (undo a record we just wrote when
    # usermod failed); the uninstall consumer uses manifest_remove_group_all().
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    [ -f "$MANIFEST_FILE" ] || return 0
    manifest_lock || return 1
    local rc=0
    _manifest_remove_group_body "$@" || rc=$?
    manifest_unlock
    return "$rc"
}

_manifest_remove_group_all_body() {
    # Held under the reentrant manifest lock. Unlike manifest_remove_group()
    # this consumes EVERY component record for the same (group,user): once the
    # membership has actually been removed, a sibling's stale true/false record
    # must not survive to mislead a later uninstall pass.
    if ! manifest_load; then
        log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to remove group records for $2@$1"
        return 1
    fi
    # argc=5 (python3 -c SCRIPT mp group user): same unique-temp + fsync +
    # os.replace path as every other manifest writer, argv below stub thresholds.
    sudo python3 -c "$_MANIFEST_ATOMIC_WRITE_PY"'# GROUP_CONSUME_ALL
import json, sys, os
mp, group, user = sys.argv[1:4]
if not os.path.exists(mp):
    sys.exit(0)
d = json.load(open(mp))
d.setdefault("groups", [])
before = len(d["groups"])
d["groups"] = [g for g in d["groups"]
               if not (g.get("group") == group and g.get("user") == user)]
if len(d["groups"]) == before:
    sys.exit(0)              # nothing matched: do not rewrite at all
atomic_write_json(mp, d)
' "$MANIFEST_FILE" "$1" "$2"
}

manifest_remove_group_all() {
    # $1=group $2=user — consume all component records for this pair, but ONLY
    # after a successful gpasswd -d. Same lock + unique-temp + os.replace path
    # as manifest_remove_group; no second lock primitive is introduced.
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    [ -f "$MANIFEST_FILE" ] || return 0
    manifest_lock || return 1
    local rc=0
    _manifest_remove_group_all_body "$@" || rc=$?
    manifest_unlock
    return "$rc"
}

_ensure_group_membership_body() {
    # Held under the manifest lock for its ENTIRE duration: the membership
    # snapshot, the first-wins gate, the group record and the usermod (plus its
    # cleanup) form one transaction. Returning with the lock still held is the
    # caller wrapper's responsibility via a single manifest_unlock().
    local group="$1" user="$2" component="$3"

    # (1) Snapshot the PRE-install state before any side effect.
    local was_member=0
    id -nG "$user" 2> /dev/null | tr ' ' '\n' | grep -qx "$group" && was_member=1 || was_member=0

    # (2) Probe for an existing record BEFORE writing. first-wins: a record
    # created by an earlier install must never be removed by a later failure.
    local probe_rc=0 had_record=0
    manifest_has_group "$group" "$user" "$component" || probe_rc=$?
    case "$probe_rc" in
        0) had_record=1 ;;
        1) had_record=0 ;;
        *)
            # Fail closed before touching /etc/group, just like the manifest
            # gate in backup_file_manifest_aware() and remove_group_membership().
            log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to change '$user' membership in '$group'"
            return 1
            ;;
    esac

    # (2b) Re-review #13 (P2): an existing record whose was_member=true, but
    # whose CURRENT membership is false, means THIS install is about to re-add
    # a membership an administrator removed while the component was installed.
    # First-wins keeps the old true snapshot, so persist per-install evidence.
    # The writer only sets the flag when every existing snapshot is true.
    local mark_added=0
    if [ "$was_member" = "0" ] && [ "$had_record" = "1" ]; then
        mark_added=1
    fi

    # (3) Persist the original state first. If the write fails we do not even
    # attempt usermod: an untracked privilege change is worse than no change.
    if ! manifest_add_group "$group" "$user" "$component" "$was_member" "$mark_added"; then
        log_error "Group manifest write failed for $user@$group; refusing to change membership (uninstall could not undo it)"
        return 1
    fi

    # (4) Only now perform the real group change, with an explicit rc check.
    # No `|| true`: a failed usermod must never be reported as "Added".
    if [ "$was_member" = "0" ]; then
        if ! sudo usermod -aG "$group" "$user"; then
            log_error "Failed to add '$user' to group '$group'"
            if [ "$mark_added" = "1" ]; then
                # We persisted added evidence before usermod; undo ONLY that
                # evidence so a later uninstall cannot gpasswd a user who is
                # not actually in the group. The original first-wins record
                # (and its was_member) is never removed here.
                if ! manifest_clear_group_added "$group" "$user" "$component"; then
                    log_error "Could not clear added-by-project evidence for $user@$group; kept for manual cleanup"
                fi
            fi
            if [ "$had_record" = "0" ]; then
                # We just wrote the record for THIS attempt; undo it so a
                # later uninstall cannot remove a membership the user
                # obtains on their own. A pre-existing record is left alone.
                if ! manifest_remove_group "$group" "$user" "$component"; then
                    log_error "Could not roll back group record for $user@$group; kept for manual cleanup"
                fi
            fi
            return 1
        fi
        log_info "Added '$user' to group '$group' (re-login required)"
    fi
    return 0
}

ensure_group_membership() {
    # $1=group $2=user $3=component
    # Invariant: if this function returns non-zero, the user's membership in
    # $1 has NOT been changed by us AND no "we added this membership" record
    # was left behind for a failed action. This is the group analogue of the
    # keyd install flow: persist original state FIRST, then mutate /etc/group.
    local group="$1" user="$2" component="$3"
    [ -z "$user" ] || [ "$user" = "root" ] && return 0
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Would ensure '$user' is a member of group '$group'"
        return 0
    fi
    manifest_lock || return 1
    local rc=0
    _ensure_group_membership_body "$group" "$user" "$component" || rc=$?
    manifest_unlock
    return "$rc"
}

# One authoritative predicate for "some component still needs $group".
# Kept byte-for-byte identical to the original production scan so the existing
# grep stub (STUB_UDEV_DIR) keeps intercepting it; every other grep falls through.
_group_udev_rule_references() {
    grep -rl "GROUP=\"$1\"" /etc/udev/rules.d/ 2> /dev/null | grep -q .
}

_remove_group_membership_body() {
    # Held under the manifest lock for its ENTIRE duration: the fail-closed
    # gate, the cross-component ownership probe, the udev reference check,
    # gpasswd and the final record consumption are one transaction. The nested
    # consumer only bumps MANIFEST_LOCK_DEPTH; the wrapper releases once at end.
    local group="$1" user="$2" component="$3"
    # Fail closed BEFORE gpasswd -d (a real side effect): a schema-invalid
    # group record (e.g. was_member="false", truthy in Python) must never be
    # accepted as evidence that we should delete a membership.
    if ! manifest_load; then
        log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to remove group membership for $user@$group"
        return 1
    fi
    # Aggregate across ALL components for (group,user). A sibling component's
    # was_member=false is proof that WE added the membership, even when this
    # component's own record says true (keyboard-then-fingerprint full install).
    # An added_by_project=true flag is equivalent per-install proof even when
    # every was_member is true (admin removed + reinstall while still installed).
    local own_rc=0
    python3 -c "$_GROUP_OWNERSHIP_PY" "$MANIFEST_FILE" "$group" "$user" \
        > /dev/null 2>&1 || own_rc=$?
    case "$own_rc" in
        1)
            log_info "No group record for '$user'@'$group'; nothing to roll back. [$component]"
            return 0
            ;;
        3)
            # ALL records say was_member=true AND none carries an
            # added_by_project flag: we never added this membership, so NO
            # gpasswd is ever authorised here. Two sub-cases:
            #  (a) a udev rule still references the group => a component is
            #      still installed/managing it: keep the first-wins snapshot;
            #  (b) no rule => every module that could add the user is gone.
            #      Consume ALL stale records (no membership change) so the NEXT
            #      install re-snapshots the real, possibly admin-changed state.
            if _group_udev_rule_references "$group"; then
                log_info "udev rules still reference group '$group'; keeping '$user' in it (all records pre-existing). [$component]"
                return 0
            fi
            log_info "All records pre-existing and no udev rule needs '$group'; consuming stale records for '$user'@'$group' (membership unchanged). [$component]"
            if ! manifest_remove_group_all "$group" "$user"; then
                log_error "Could not consume stale group records for '$user'@'$group'; keeping them for retry."
                return 1
            fi
            return 0
            ;;
        0) ;;
        *)
            log_error "Cannot determine original membership of $user@$group; refusing to change it (manifest rc=$own_rc)"
            return 1
            ;;
    esac
    # rc 0: some component recorded was_member=false, or a record carries an
    # added_by_project=true flag => WE added the membership in this generation.
    # Keep it while ANY udev rule (ours from a sibling, or third-party) needs it.
    if _group_udev_rule_references "$group"; then
        log_info "udev rules still reference group '$group'; keeping '$user' in it."
        return 0
    fi
    if sudo gpasswd -d "$user" "$group" 2> /dev/null; then
        log_info "Removed '$user' from group '$group' (per the original-state manifest snapshot) [$component]."
    else
        # FAIL LOUD: the caller (and setup.sh via its rc fold) must know that
        # the membership was NOT restored. Records stay for a later retry.
        log_error "Could not remove '$user' from group '$group'; keeping manifest records for retry."
        return 1
    fi
    # Consume ALL component records for this pair only AFTER a successful
    # removal, so no stale false/true evidence survives for a later pass.
    if ! manifest_remove_group_all "$group" "$user"; then
        log_error "Could not consume group records for '$user'@'$group'; keeping them for retry."
        return 1
    fi
    return 0
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
    manifest_lock || return 1
    local rc=0
    _remove_group_membership_body "$@" || rc=$?
    manifest_unlock
    return "$rc"
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

_manifest_add_entry_body() {
    local target="$1"
    local component="$2"
    local was_existing="$3" # 1 = yes, 0 = created new

    # Re-read (and validate) INSIDE the lock, immediately before the write: a
    # corrupt manifest must never be replaced with an empty skeleton, and a
    # snapshot taken before another writer committed must never be mutated.
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
    printf '%s' "$MANIFEST_JSON" | sudo python3 -c "$_MANIFEST_ATOMIC_WRITE_PY"'import json, sys, os
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

atomic_write_json(manifest_path, data)
' "$MANIFEST_FILE" "$target" "$component" "$was_existing" "$timestamp" || write_rc=$?
    [ "$write_rc" -le 1 ] || write_rc=1
    return "$write_rc"
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

    manifest_lock || return 1
    local rc=0
    _manifest_add_entry_body "$target" "$component" "$was_existing" || rc=$?
    manifest_unlock
    return "$rc"
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

    # DRY_RUN MUST return before taking the lock: no lock file / sudo side
    # effect in a dry run. The fail-closed load above deliberately stays ahead
    # of this return (a missing python3 cannot be mistaken for a valid gate).
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Rollback would process records in $MANIFEST_FILE for component: $target_comp"
        return 0
    fi

    manifest_lock || return 1
    local rc=0
    _rollback_component_body "$target_comp" || rc=$?
    manifest_unlock # even when python returns non-zero
    [ "$rc" -eq 0 ] && log_success "Rollback for component [$target_comp] finished!"
    return "$rc"
}

_rollback_component_body() {
    local target_comp="$1"
    # Re-read INSIDE the lock: this is the authoritative snapshot the python
    # below consumes, so a concurrent install's record can never be dropped.
    if ! manifest_load; then
        log_error "Manifest at $MANIFEST_FILE is corrupt/invalid; refusing to roll back $target_comp"
        return 1
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
        # argv is UNCHANGED (argc=6): the durability helper is part of the -c
        # script, not an extra argument, so the rollback stub keeps matching.
        if ! printf '%s' "$MANIFEST_JSON" | sudo python3 -c "$_MANIFEST_ATOMIC_WRITE_PY"'import json, os, sys, shutil, glob, fnmatch, subprocess

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
    """Stage next to the target, then swap atomically. Return None on success.

    A failed swap NEVER removes an existing target: the ordinary file/symlink
    path is a single os.replace(); only directory-involving swaps move the old
    path aside (and move it back on failure), because os.replace() cannot
    replace a non-empty dir nor cross the file <-> directory type boundary.
    """
    stage = target + ".cros-rollback-tmp-%d" % os.getpid()
    old = None
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

        # A directory stage cannot replace an existing non-directory (ENOTDIR),
        # and a non-directory stage cannot replace a directory (EISDIR); a dir
        # stage also cannot replace a non-empty dir (ENOTEMPTY). Move the old
        # entry aside ONLY for those cases. Regular file / symlink -> regular
        # file / symlink stays a single atomic replace with NO unlink window.
        stage_is_dir = os.path.isdir(stage) and not os.path.islink(stage)
        target_is_dir = os.path.isdir(target) and not os.path.islink(target)
        if (stage_is_dir or target_is_dir) and os.path.lexists(target):
            old = target + ".cros-rollback-old-%d" % os.getpid()
            os.rename(target, old)
        try:
            os.replace(stage, target)
        except OSError:
            if old is not None:
                os.rename(old, target)   # put the installed entry back
                old = None
            raise
        if old is not None:
            remove_path(old)             # best effort; handles file/link/dir alike
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
            # Keep the record for a later retry, but do NOT invent a file.
            # This is a real failure: report it via problem() so the single
            # write-back still happens and the final rc is non-zero, while
            # other services/files keep rolling back normally.
            print("  [WARN NO BACKUP] %s: original unavailable; record kept" %
                  target, file=sys.stderr)
            problem("RECORD_BACKUP_MISSING",
                    "target=%s component=%s backup_base=%s; original unavailable; record kept" %
                    (target, comp, backup_base))
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
# Unique same-directory temp (atomic_write_json) replaces the old shared .tmp.
data["records"] = remaining_records
atomic_write_json(manifest_path, data)

if problems:
    print("ROLLBACK_INCOMPLETE: %d item(s) retained (see WARN lines above)" %
          len(problems), file=sys.stderr)
    sys.exit(1)
' "$MANIFEST_FILE" "$target_comp" "$BACKUP_BASE_DIR" "$allowed_prefixes"; then
            log_error "rollback of $target_comp failed; service/file state may be partial (retained records remain for retry)"
            rc=1
        fi
    else
        log_warn "python3 not found; automatic rollback unavailable. Files may need manual restoration."
    fi
    return "$rc"
}
