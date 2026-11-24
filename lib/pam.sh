#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lib/pam.sh - Cross-Distro PAM Configuration for Fingerprint Authentication

if [ -n "${_LIB_PAM_SH_LOADED:-}" ]; then
    return 0
fi
_LIB_PAM_SH_LOADED=1

SCRIPT_DIR_PAM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logger.sh
source "$SCRIPT_DIR_PAM/logger.sh"
# shellcheck source=lib/distro.sh
source "$SCRIPT_DIR_PAM/distro.sh"
# shellcheck source=lib/backup.sh
# configure_pam_fingerprint() uses run_manifest_operation(); the fingerprint
# installer already sources backup.sh first, but keep this header self-contained.
source "$SCRIPT_DIR_PAM/backup.sh"

# One canonical definition of the line WE add to sudo PAM. Install and
# uninstall must never disagree about what "our line" is. The two env seams
# let the sandboxed tests redirect /etc/pam.d into /tmp without ever touching
# the host's PAM files; production always uses the defaults.
_PAM_FP_SUDO_LINE='auth sufficient pam_fprintd.so max-tries=1 timeout=10'
_PAM_SUDO_PATH="${CROS_ENABLEMENT_PAM_SUDO_PATH:-/etc/pam.d/sudo}"
_PAM_DIR="${CROS_ENABLEMENT_PAM_DIR:-/etc/pam.d}"

# Debian's common-* files AND the debconf libpam-runtime/profiles selection are
# both managed by pam-auth-update. Its diff_profiles() derives the enabled
# profile list from the CURRENT common-* content plus the saved module snapshots
# in /var/lib/pam, and a later `pam-auth-update --package` (PAM module/package
# upgrade, or an administrator rerun) persists that derived list back into
# debconf. Merely sed-deleting pam_fprintd.so would therefore permanently lose
# the user's fprintd selection on the next package maintenance (re-review #13
# finding #1). Strategy:
#  1. snapshot the original debconf selection (value AND its seen flag) and every
#     saved module file into a sidecar next to the manifest (first-wins, never
#     overwritten); legacy sidecars without seen metadata restore value only;
#  2. back up ALL existing common-* files (not just fp-containing ones), because
#     --package may rewrite every one of them; strip only the fp module lines;
#  3. run `pam-auth-update --package` ourselves so debconf + /var/lib/pam
#     converge to a stable "no fprintd" state (a later upgrade is a no-op);
#  4. on uninstall, after manifest rollback restores common-*/sudo bytes, write
#     the snapshotted selection back, restore the saved snapshots, run --package
#     again and verify the selection equals the snapshot before consuming it.
# Re-review #15 finding #2: `pam-auth-update --package` in step 4 REWRITES the
# files rollback just restored (umask 0022 + .pam-new rename: 0600 -> 0644,
# whitespace canonicalised, symlink -> regular file). Manifest-record consumption
# cannot prove their final state. A THIRD root:0700 snapshot next to the sidecar
# records every common-*/sudo target (bytes, mode, lstat owner, type, link target
# and ABSENCE) plus the live savedir's directory metadata. After ALL external
# tool calls it is idempotently re-applied, then verified byte-for-byte before
# all three halves are consumed together.
# We still NEVER call `pam-auth-update --remove`: that action deletes the
# debconf profile selection outright.
_PAM_COMMON_BASES=(common-auth common-account common-session common-session-noninteractive common-password)
_PAM_COMMON_FP_FOUND=0
_PAM_SAVED_DIR="${CROS_ENABLEMENT_PAM_SAVED_DIR:-/var/lib/pam}"
_PAM_SEL_SIDECAR="${CROS_ENABLEMENT_PAM_SELECTION_FILE:-${MANIFEST_FILE%/*}/pam-selection}"
_PAM_SAVED_SNAPSHOT_DIR="${_PAM_SEL_SIDECAR}.saved"
_PAM_COMMON_SNAPSHOT_DIR="${_PAM_SEL_SIDECAR}.common"
_PAM_SEL_MAGIC='# cros-enablement: PAM profile selection snapshot (first-wins; do not edit)'
_PAM_COMMON_MAGIC='# cros-enablement: PAM common/sudo state snapshot (first-wins; do not edit)'
# Set ONLY after our own .common publish succeeds. Rollback must use THIS flag,
# never "the dir exists now": during staging a foreign installer may win the
# race, and its snapshot must survive even though our install fails (P2-3).
_PAM_COMMON_PUBLISHED=0

_pam_backup_common_files() {
    local base file
    _PAM_COMMON_FP_FOUND=0
    for base in "${_PAM_COMMON_BASES[@]}"; do
        file="$_PAM_DIR/$base"
        # A dangling symlink is still an original target: use the same
        # lstat-style existence test as backup_file()/manifest (PAM-52).
        [ -e "$file" ] || [ -L "$file" ] || continue
        # Every common-* can be rewritten by --package, so every existing one
        # must be rollback-tracked byte-for-byte, not only those with fp lines.
        backup_file_manifest_aware "$file" "fingerprint" || return $?
        if [ ! -L "$file" ] && grep -qF -- 'pam_fprintd.so' "$file"; then
            _PAM_COMMON_FP_FOUND=1
        fi
    done
    return 0
}

# --- debconf selection / seen-flag helpers ----------------------------------
#
# re-review P1 #2: debconf-show prints "* libpam-runtime/profiles: ..." when the
# question is SEEN and "  libpam-runtime/profiles: ..." when it is unseen. The
# old parser only accepted the latter, so a non-empty seen=true selection was
# read as an empty string, snapshotted as empty, and never restored on uninstall.
#
# Prefer debconf-communicate: its protocol carries BOTH a status and the value,
# so "question absent" / "tool failed" cannot be confused with a legal empty
# value. Keep a PREFIX-AWARE debconf-show fallback for the VALUE on hosts
# without it; the seen flag is NOT available through that fallback (it cannot
# be written back without the protocol tool), so such snapshots stay LEGACY:
# value only, no FSET on restore.
#
# Contract of _pam_read_selection / _pam_read_selection_seen:
#   rc 0 -> value on stdout (the SELECTION may legitimately be empty)
#   rc 1 -> the key/field was unreadable; NEVER report an empty string with rc 0
_pam_debconf_query() {
    # Each argument is one debconf-communicate command. A REAL tool exits with
    # the NUMERIC STATUS OF THE LAST command: GET of a missing key prints
    # "10 ..." and exits 10. Callers MUST check this process rc AND parse the
    # reply's status token. The optional `timeout` only bounds a hung tool; it
    # does not change the sudo invocation (passwordless sudo still applies).
    if command -v timeout > /dev/null 2>&1; then
        printf '%s\n' "$@" | timeout 5 sudo debconf-communicate libpam-runtime 2> /dev/null
    else
        printf '%s\n' "$@" | sudo debconf-communicate libpam-runtime 2> /dev/null
    fi
}

_pam_debconf_reply_value() {
    # $1 = one "<status> <value>" reply line. Print the value ONLY for status 0.
    local line="$1" status value
    status="${line%% *}"
    [ "$status" = "0" ] || return 1
    value=""
    [ "$line" = "$status" ] || value="${line#* }"
    value="${value%$'\r'}"
    printf '%s' "$value"
}

_pam_read_selection() {
    local reply last value rc=0
    if command -v debconf-communicate > /dev/null 2>&1; then
        reply="$(_pam_debconf_query 'GET libpam-runtime/profiles')" || rc=$?
        # The PROCESS rc is the last command's status on the real tool, so a
        # non-zero rc is a hard failure (absent key / tool error) — NEVER a
        # cue to fall back to debconf-show.
        [ "$rc" -eq 0 ] || return 1
        if [ -n "$reply" ]; then
            last="$(printf '%s\n' "$reply" | tail -n 1)"
            if value="$(_pam_debconf_reply_value "$last")"; then
                printf '%s' "$value"
                return 0
            fi
            # The final reply line carries a NON-ZERO protocol status: the
            # question is absent. No fallback: debconf-show cannot distinguish
            # "absent" from a legal empty value.
            return 1
        fi
        # No protocol line at all is unusable too (a legal answer is at least
        # "0 "), and the tool IS present: still no fallback.
        return 1
    fi
    # Fallback ONLY when debconf-communicate is genuinely unavailable.
    # Accept BOTH prefixes. A missing line is a hard failure, not an empty value
    # (the "V:" marker keeps an empty value distinguishable).
    reply="$(sudo debconf-show libpam-runtime 2> /dev/null \
        | awk '/^(  |\* )libpam-runtime\/profiles:[[:space:]]*/ {
                  sub(/^(  |\* )libpam-runtime\/profiles:[[:space:]]*/, "")
                  print "V:" $0
              }' | tail -n 1)"
    [ -n "$reply" ] || return 1
    printf '%s' "${reply#V:}"
}

_pam_read_selection_seen() {
    local reply last value rc=0
    if command -v debconf-communicate > /dev/null 2>&1; then
        reply="$(_pam_debconf_query 'FGET libpam-runtime/profiles seen')" || rc=$?
        # Same rule as _pam_read_selection: the process rc IS the last
        # command's status on a real tool. Never hide a failure with a fallback.
        [ "$rc" -eq 0 ] || return 1
        if [ -n "$reply" ]; then
            last="$(printf '%s\n' "$reply" | tail -n 1)"
            if value="$(_pam_debconf_reply_value "$last")"; then
                case "$value" in
                    true | false)
                        printf '%s' "$value"
                        return 0
                        ;;
                esac
            fi
            # A status-bearing reply means the seen field/question is absent.
            return 1
        fi
        return 1
    fi
    # debconf-show's '* ' / '  ' display prefix is NOT a restorable seen flag:
    # writing it back needs FSET/debconf-communicate, which is absent here.
    # Report "unavailable" so the snapshot stays LEGACY (value only, no FSET)
    # instead of recording a flag the product could never put back.
    return 1
}

_pam_set_selection_seen() {
    # $1 = true|false. Check BOTH the process rc (last command's status on a
    # real tool) and the reply's protocol status — same contract as the readers.
    local reply last status rc=0
    command -v debconf-communicate > /dev/null 2>&1 || return 1
    reply="$(_pam_debconf_query "FSET libpam-runtime/profiles seen $1")" || rc=$?
    [ "$rc" -eq 0 ] || return 1
    [ -n "$reply" ] || return 1
    last="$(printf '%s\n' "$reply" | tail -n 1)"
    status="${last%% *}"
    [ "$status" = "0" ]
}

_PAM_SAVED_SNAPSHOT_STAGE="${_PAM_SAVED_SNAPSHOT_DIR}.stage.$$"

# Filled by _pam_verify_sidecar_content(); consumed by the snapshot/restore
# transaction so "read it back and compare" never re-parses the file ad hoc.
_PAM_VERIFY_VALUE=""
_PAM_VERIFY_SEEN=""
_PAM_VERIFY_SAVED=""
# 1 only when BOTH optional metadata lines are absent (a genuine legacy
# sidecar). seen-without-saved is truncation, never legacy.
_PAM_VERIFY_LEGACY=0

# A caller-writable (TMPDIR) file for NUL-separated path lists and read-back
# buffers. `while ... < <(sudo find ...)` throws away find's rc, so every
# enumeration is materialised here and the rc is checked BEFORE the loop runs.
# Files created this way are never published; only root-created files are.
_pam_tmp_file() {
    mktemp "${TMPDIR:-/tmp}/cros-pam-snapshot.XXXXXX"
}

# Existence probe for root-owned 0700 snapshot dirs. Privileged ONLY for a
# non-root caller: a root caller uses the shell's own test, so a restricted
# sudo stub that does not implement `test` cannot fake "snapshot present".
# $1=d|e|f|l, $2=path. stat/sha256sum/readlink/cat always go through sudo.
_pam_fs_probe() {
    if [ "$(id -u)" -eq 0 ]; then
        case "$1" in
            d) [ -d "$2" ] ;;
            e) [ -e "$2" ] || [ -L "$2" ] ;;
            f) [ -f "$2" ] ;;
            l) [ -L "$2" ] ;;
            *) return 2 ;;
        esac
    else
        case "$1" in
            d) sudo test -d "$2" 2> /dev/null ;;
            e) sudo test -e "$2" 2> /dev/null || sudo test -L "$2" 2> /dev/null ;;
            f) sudo test -f "$2" 2> /dev/null ;;
            l) sudo test -L "$2" 2> /dev/null ;;
            *) return 2 ;;
        esac
    fi
}

_pam_enumerate_saved_files() {
    # $1=directory. Echoes the temp file path only on a SUCCESSFUL sudo find.
    local list
    list="$(_pam_tmp_file)" || return 1
    # Intentionally redirect into a caller-owned (mktemp, 0600) file: this is a
    # privilege boundary, not an accidental root-owned write. Using sudo tee
    # would leave $list root-owned and break non-root uninstall readability
    # (PAM-19/41).
    # shellcheck disable=SC2024
    if ! sudo find "$1" -maxdepth 1 -type f -print0 > "$list" 2> /dev/null; then
        rm -f -- "$list"
        return 1
    fi
    printf '%s\n' "$list"
}

_pam_snapshot_cleanup_stage() {
    # Stage data is ours and temporary, but a failed cleanup is logged rather
    # than silently swallowed (review P3).
    sudo rm -rf -- "$_PAM_SAVED_SNAPSHOT_STAGE" 2> /dev/null \
        || log_error "Could not clean the saved PAM profile staging directory $_PAM_SAVED_SNAPSHOT_STAGE."
    return 0
}

# Remove a root-owned temp file, reporting (never silently swallowing) a
# failure. Leftover temp files cannot invalidate the published snapshot, so
# callers continue; the important removals are checked at their call sites.
_pam_remove_temp_file() {
    if ! sudo rm -f -- "$1" 2> /dev/null; then
        log_error "Could not remove temporary file $1."
    fi
    return 0
}

# Count NUL-separated paths without relying on grep's "no match" rc.
_pam_count_enumerated_files() {
    tr '\0' '\n' < "$1" | awk 'NF { n++ } END { print n + 0 }'
}

# Snapshot every saved module file into a per-PID staging directory. Nothing is
# published here: the caller publishes the COMPLETE staging directory with one
# rename only after the selection sidecar is ready, so neither half of the
# snapshot can ever be observed half written. Every read/copy goes through sudo
# so a non-root caller with passwordless sudo can snapshot a root-only
# /var/lib/pam (a plain user glob would silently match nothing).
_pam_stage_saved_dir() {
    local f base rc=0 list
    [ -d "$_PAM_SAVED_DIR" ] || return 0
    _pam_snapshot_cleanup_stage
    if ! sudo install -d -m 700 -- "$_PAM_SAVED_SNAPSHOT_STAGE"; then
        log_error "Could not create the saved PAM profile snapshot staging directory."
        return 1
    fi
    list="$(_pam_enumerate_saved_files "$_PAM_SAVED_DIR")" || {
        log_error "Could not enumerate $_PAM_SAVED_DIR; refusing to snapshot an incomplete saved profile set."
        _pam_snapshot_cleanup_stage
        return 1
    }
    while IFS= read -r -d '' f; do
        base="${f##*/}"
        if ! sudo cp -a -- "$f" "$_PAM_SAVED_SNAPSHOT_STAGE/$base" \
            || ! sudo cmp -s -- "$f" "$_PAM_SAVED_SNAPSHOT_STAGE/$base"; then
            log_error "Could not snapshot the saved PAM profile file '$f'."
            rc=1
        fi
    done < "$list"
    rm -f -- "$list"
    if [ "$rc" -ne 0 ]; then
        _pam_snapshot_cleanup_stage
        return 1
    fi
    return 0
}

_pam_publish_saved_dir() {
    # A single rename publishes the staging dir. The installer holds the
    # manifest lock for its whole operation, so sidecar + .saved are published
    # as one atomic unit with respect to any other installer. A pre-existing
    # .saved here is NOT a harmless first-wins race: we only get here after
    # winning the sidecar, so it would make the two halves inconsistent. It is
    # preserved byte-for-byte (it may be the only surviving original copy);
    # ONLY our own staging directory is removed.
    [ -d "$_PAM_SAVED_SNAPSHOT_STAGE" ] || return 1
    if [ -e "$_PAM_SAVED_SNAPSHOT_DIR" ]; then
        log_error "$_PAM_SAVED_SNAPSHOT_DIR already exists (orphaned snapshot); preserving it and refusing to publish an inconsistent saved profile snapshot."
        _pam_snapshot_cleanup_stage
        return 1
    fi
    if ! sudo mv -- "$_PAM_SAVED_SNAPSHOT_STAGE" "$_PAM_SAVED_SNAPSHOT_DIR"; then
        log_error "Could not publish the saved PAM profile snapshot."
        _pam_snapshot_cleanup_stage
        return 1
    fi
    return 0
}

# True when .saved is absent OR contains no regular files. Enumeration failure
# is NOT "empty": callers must fail closed on an unreadable snapshot.
_pam_saved_snapshot_is_empty() {
    # 0 = empty/absent, 1 = has files, 2 = unreadable (never treated as empty).
    local list count
    [ -d "$_PAM_SAVED_SNAPSHOT_DIR" ] || return 0
    list="$(_pam_enumerate_saved_files "$_PAM_SAVED_SNAPSHOT_DIR")" || return 2
    count="$(_pam_count_enumerated_files "$list")"
    rm -f -- "$list"
    [ "$count" -eq 0 ] && return 0
    return 1
}

# Read-back helpers. The snapshot is only complete when the metadata line,
# readable files and (for a complete snapshot) byte-identical copies all agree.
_pam_saved_snapshot_readable() {
    local f rc=0 list count
    [ -d "$_PAM_SAVED_SNAPSHOT_DIR" ] || return 1
    list="$(_pam_enumerate_saved_files "$_PAM_SAVED_SNAPSHOT_DIR")" || return 1
    count="$(_pam_count_enumerated_files "$list")"
    if [ "$count" -eq 0 ]; then
        log_error "$_PAM_SAVED_SNAPSHOT_DIR is empty; an empty saved snapshot cannot satisfy saved-snapshot=complete."
        rc=1
    fi
    while IFS= read -r -d '' f; do
        sudo cat -- "$f" > /dev/null 2>&1 || rc=1
    done < "$list"
    rm -f -- "$list"
    return "$rc"
}

# Bidirectional comparison: snapshot -> live catches missing/changed live files,
# live -> snapshot catches EXTRA live files that --package could later use to
# derive a selection we never snapshotted.
_pam_saved_snapshot_matches_live() {
    local f base rc=0 list live_list count
    [ -d "$_PAM_SAVED_SNAPSHOT_DIR" ] || return 1
    list="$(_pam_enumerate_saved_files "$_PAM_SAVED_SNAPSHOT_DIR")" || return 1
    live_list="$(_pam_enumerate_saved_files "$_PAM_SAVED_DIR")" || {
        rm -f -- "$list"
        return 1
    }
    count="$(_pam_count_enumerated_files "$list")"
    if [ "$count" -eq 0 ]; then
        log_error "$_PAM_SAVED_SNAPSHOT_DIR is empty; refusing to accept an empty saved snapshot."
        rc=1
    fi
    while IFS= read -r -d '' f; do
        base="${f##*/}"
        if ! sudo test -f "$_PAM_SAVED_DIR/$base" \
            || ! sudo cmp -s -- "$f" "$_PAM_SAVED_DIR/$base"; then
            log_error "Saved PAM profile '$base' is not byte-identical to its snapshot."
            rc=1
        fi
    done < "$list"
    while IFS= read -r -d '' f; do
        base="${f##*/}"
        # The snapshot dir is root:0700: a non-root caller cannot stat it, so
        # the existence probe must be privileged just like find/cmp above.
        if ! sudo test -f "$_PAM_SAVED_SNAPSHOT_DIR/$base" 2> /dev/null; then
            log_error "Live saved PAM profile '$base' has no counterpart in $_PAM_SAVED_SNAPSHOT_DIR."
            rc=1
        fi
    done < "$live_list"
    rm -f -- "$list" "$live_list"
    return "$rc"
}

_pam_sidecar_fields() {
    local tmp awk_rc
    [ -f "$_PAM_SEL_SIDECAR" ] || return 1
    tmp="$(_pam_tmp_file)" || return 1
    # Intentionally redirect into a caller-owned (mktemp, 0600) file: this is a
    # privilege boundary, not an accidental root-owned write. Using sudo tee
    # would leave $tmp root-owned and break non-root uninstall readability
    # (PAM-19/41).
    # shellcheck disable=SC2024
    if ! sudo cat -- "$_PAM_SEL_SIDECAR" > "$tmp" 2> /dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    # Emit prefixed lines so even an EMPTY data line survives command
    # substitution's trailing-newline stripping.
    awk -v magic="$_PAM_SEL_MAGIC" '
        BEGIN { magic_n=0; seen_n=0; saved_n=0; data_n=0; other=0; bad=0 }
        {
            if ($0 == magic) { magic_n++; if (NR != 1) other=1; next }
            if ($0 ~ /^# cros-enablement: selection-seen=(true|false)$/) {
                seen_n++; seen=$0; sub(/^.*=/, "", seen); next
            }
            if ($0 ~ /^# cros-enablement: saved-snapshot=(complete|absent)$/) {
                saved_n++; saved=$0; sub(/^.*=/, "", saved); next
            }
            if ($0 ~ /^#/) { other=1; next }
            data_n++; data=$0
        }
        END {
            if (data_n == 1 && data != "" &&
                data !~ /^[[:space:]]*[[:alnum:]_.:@+\/-]+([[:space:]]*,[[:space:]]*[[:alnum:]_.:@+\/-]+)*[[:space:]]*$/) bad=1
            if (data_n == 1 && data ~ /^[[:space:]]*$/) data=""
            print "MAGIC=" magic_n
            print "SEEN_N=" seen_n
            print "SAVED_N=" saved_n
            print "DATA_N=" data_n
            print "OTHER=" other
            print "BAD=" bad
            print "VALUE=" data
            print "SEEN=" seen
            print "SAVED=" saved
        }
    ' "$tmp"
    awk_rc=$?
    if ! rm -f -- "$tmp"; then
        log_error "Could not remove the temporary sidecar read-back buffer."
        return 1
    fi
    return "$awk_rc"
}

_pam_verify_sidecar_content() {
    local fields line magic_n="" seen_n="" saved_n="" data_n="" other="" bad=""
    local value="" seen="" saved="" mode
    # Always reset classification state: a previous failed verification must
    # never leave a stale "legacy" flag behind (review P3).
    _PAM_VERIFY_LEGACY=0
    [ -f "$_PAM_SEL_SIDECAR" ] || {
        log_error "PAM selection sidecar $_PAM_SEL_SIDECAR is missing."
        return 1
    }
    # The uninstaller may be a non-root caller with passwordless sudo: a
    # root-only 0600 sidecar could never be read back by that caller.
    [ -r "$_PAM_SEL_SIDECAR" ] && cat -- "$_PAM_SEL_SIDECAR" > /dev/null 2>&1 || {
        log_error "PAM selection sidecar $_PAM_SEL_SIDECAR is not readable by this caller."
        return 1
    }
    mode="$(stat -c '%a' -- "$_PAM_SEL_SIDECAR" 2> /dev/null || echo 000)"
    if ! (((8#$mode & 044) != 0)) 2> /dev/null; then
        log_error "PAM selection sidecar $_PAM_SEL_SIDECAR is not world-readable (mode $mode)."
        return 1
    fi
    fields="$(_pam_sidecar_fields)" || {
        log_error "Could not read PAM selection sidecar $_PAM_SEL_SIDECAR back through sudo."
        return 1
    }
    while IFS= read -r line; do
        case "$line" in
            MAGIC=*) magic_n="${line#MAGIC=}" ;;
            SEEN_N=*) seen_n="${line#SEEN_N=}" ;;
            SAVED_N=*) saved_n="${line#SAVED_N=}" ;;
            DATA_N=*) data_n="${line#DATA_N=}" ;;
            OTHER=*) other="${line#OTHER=}" ;;
            BAD=*) bad="${line#BAD=}" ;;
            VALUE=*) value="${line#VALUE=}" ;;
            SEEN=*) seen="${line#SEEN=}" ;;
            SAVED=*) saved="${line#SAVED=}" ;;
        esac
    done <<< "$fields"
    # Default every counter numerically so a truncated awk result can never be
    # compared as a string or silently classified as "legacy".
    magic_n="${magic_n:-0}"
    seen_n="${seen_n:-0}"
    saved_n="${saved_n:-0}"
    data_n="${data_n:-0}"
    other="${other:-1}"
    bad="${bad:-1}"
    if [ "$magic_n" -ne 1 ] || [ "$data_n" -ne 1 ] || [ "$other" -ne 0 ] \
        || [ "$bad" -ne 0 ] || [ "$seen_n" -gt 1 ] || [ "$saved_n" -gt 1 ]; then
        log_error "PAM selection sidecar $_PAM_SEL_SIDECAR is partial/corrupt; refusing to treat it as a valid snapshot."
        return 1
    fi
    # P2-1: legacy means NO optional metadata at all. A sidecar carrying seen
    # but lacking saved-snapshot was truncated/corrupted, not written by an
    # older installer, so it must never take the best-effort path.
    if [ "$saved_n" -eq 0 ] && [ "$seen_n" -ne 0 ]; then
        log_error "PAM selection sidecar $_PAM_SEL_SIDECAR has seen metadata but no saved-snapshot metadata; refusing to classify a truncated sidecar as legacy."
        return 1
    fi
    if [ "$saved_n" -eq 0 ] && [ "$seen_n" -eq 0 ]; then
        _PAM_VERIFY_LEGACY=1
    else
        _PAM_VERIFY_LEGACY=0
    fi
    _PAM_VERIFY_VALUE="$value"
    _PAM_VERIFY_SEEN="$seen"
    _PAM_VERIFY_SAVED="$saved"
    return 0
}

# --- common-*/sudo original state snapshot (third, root:0700 half) -----------
#
# Layout of $_PAM_COMMON_SNAPSHOT_DIR:
#   state           root:0600; magic, four savedir-* lines, six target rows
#   files/<base>    verbatim copy of each regular-file target (never a symlink)
#
# A target row is TAB separated:
#   base, absolute path, present(0|1), type(file|link|absent),
#   mode(octal|-), owner(uid:gid|-), link target(-), sha256(-)
# For a regular file sha256 is over its bytes; for a symlink it is over the
# readlink() output, which also works for DANGLING links. Every read goes
# through sudo (non-root uninstall must see root-only live files/dirs), while
# the buffer we parse stays caller-owned via _pam_tmp_file() (no root-owned
# redirect target).
_pam_common_snapshot_fields() {
    # $1 = snapshot dir (defaults to the published one). Prints validated
    # savedir-* metadata lines followed by validated target rows.
    local dir="${1:-$_PAM_COMMON_SNAPSHOT_DIR}" tmp rc
    _pam_fs_probe d "$dir" || return 1
    tmp="$(_pam_tmp_file)" || return 1
    # shellcheck disable=SC2024 # caller-owned buffer: sudo tee would make the read-back file root-owned
    if ! sudo cat -- "$dir/state" > "$tmp" 2> /dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    awk -v magic="$_PAM_COMMON_MAGIC" -v expected="$((${#_PAM_COMMON_BASES[@]} + 1))" '
        BEGIN { magic_n=0; other=0; bad=0; rows=0 }
        $0 == magic { magic_n++; next }
        /^# cros-enablement: savedir-path=\// { saved_path++; print; next }
        /^# cros-enablement: savedir-present=[01]$/ { saved_present++; print; next }
        /^# cros-enablement: savedir-mode=([0-7]+|-)$/ { saved_mode++; print; next }
        /^# cros-enablement: savedir-owner=[0-9]+:[0-9]+$/ || /^# cros-enablement: savedir-owner=-$/ {
            saved_owner++; print; next
        }
        /^#/ { other=1; next }
        {
            n = split($0, f, "\t")
            if (n != 8 || f[1] !~ /^[A-Za-z0-9-]+$/ || f[2] !~ /^\// || f[3] !~ /^[01]$/) {
                bad=1; next
            }
            if (seen[f[1]]++) bad=1
            if (f[3] == "0") {
                if (f[4] != "absent" || f[5] != "-" || f[6] != "-" || f[7] != "-" || f[8] != "-") bad=1
            } else if (f[4] == "file") {
                if (f[5] !~ /^[0-7]+$/ || length(f[5]) < 3 || length(f[5]) > 4 \
                    || f[6] !~ /^[0-9]+:[0-9]+$/ || f[7] != "-" \
                    || length(f[8]) != 64 || f[8] !~ /^[0-9a-f]+$/) bad=1
            } else if (f[4] == "link") {
                if (f[5] !~ /^[0-7]+$/ || length(f[5]) < 3 || length(f[5]) > 4 \
                    || f[6] !~ /^[0-9]+:[0-9]+$/ || f[7] == "" \
                    || length(f[8]) != 64 || f[8] !~ /^[0-9a-f]+$/) bad=1
            } else bad=1
            rows++
            print
        }
        END {
            if (magic_n != 1 || other || bad || rows != expected \
                || saved_path != 1 || saved_present != 1 || saved_mode != 1 || saved_owner != 1) exit 1
        }
    ' "$tmp"
    rc=$?
    rm -f -- "$tmp"
    return "$rc"
}

_pam_common_normalized_hash() {
    # Whitespace-insensitive but ORDER-SENSITIVE digest. The real
    # pam-auth-update may canonicalise spacing when it rewrites common-*; that
    # is NOT an admin edit and stays equivalent (PAM-43 control). An added,
    # removed or REORDERED MODULE line IS an admin edit: sorting the lines here
    # would erase exactly that ordering information, so keep the file order and
    # fail closed instead of silently overwriting it (PAM-17/PAM-53).
    local path="$1"
    if ! _pam_fs_probe f "$path"; then
        printf '%s\n' '-'
        return 0
    fi
    sudo cat -- "$path" 2> /dev/null \
        | awk '{ $1 = $1; if (NF) print }' \
        | sha256sum | awk '{print $1}'
}

_pam_probe_common_target() {
    # $1=absolute path -> present, type, mode, owner, link target, sha256.
    # type=unsupported is a fail-closed signal (directory / special file).
    local path="$1" present=0 type=absent mode="-" owner="-" link="-" sha="-"
    if _pam_fs_probe l "$path"; then
        present=1
        type='link'
        link="$(sudo readlink -- "$path")" || return 1
        sha="$(printf '%s' "$link" | sha256sum | awk '{print $1}')"
    elif _pam_fs_probe e "$path"; then
        if _pam_fs_probe d "$path" || ! _pam_fs_probe f "$path"; then
            printf '1\tunsupported\t-\t-\t-\t-\n'
            return 0
        fi
        present=1
        type='file'
        sha="$(sudo sha256sum -- "$path" | awk '{print $1}')"
    fi
    if [ "$present" -eq 1 ]; then
        mode="$(sudo stat -c '%a' -- "$path")" || return 1
        owner="$(sudo stat -c '%u:%g' -- "$path")" || return 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$present" "$type" "$mode" "$owner" "$link" "$sha"
}

_pam_common_snapshot_row() {
    # $1=base $2=absolute path $3=files dir. Copies regular-file bytes and
    # prints the eight-field state row on stdout.
    local base="$1" path="$2" files="$3" probe present type mode owner link sha
    probe="$(_pam_probe_common_target "$path")" || return 1
    IFS=$'\t' read -r present type mode owner link sha <<< "$probe"
    case "$type" in
        unsupported)
            log_error "Unsupported PAM target at $path (directory or special file); refusing to snapshot it."
            return 1
            ;;
        file)
            if ! sudo cp -a -- "$path" "$files/$base" \
                || ! sudo cmp -s -- "$path" "$files/$base"; then
                log_error "Could not snapshot $path byte-for-byte into the common state snapshot."
                return 1
            fi
            ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$base" "$path" "$present" "$type" "$mode" "$owner" "$link" "$sha"
}

_pam_common_cleanup_stage() {
    # $1=stage dir; ours, but report (never silently swallow) cleanup failures.
    if ! sudo rm -rf -- "$1" 2> /dev/null; then
        log_error "Could not clean the PAM common-state staging directory $1."
    fi
    return 0
}

_pam_common_snapshot_readable() {
    # $1=snapshot dir (published or staged). Read back the state file AND every
    # copied byte so a half-published/truncated snapshot can never be accepted.
    local dir="${1:-$_PAM_COMMON_SNAPSHOT_DIR}" fields line base path present type mode owner link sha
    local saved_present saved_mode saved_owner sum
    fields="$(_pam_common_snapshot_fields "$dir")" || {
        log_error "$dir has a missing/corrupt PAM common-state manifest; failing closed."
        return 1
    }
    saved_present="$(printf '%s\n' "$fields" | sed -n 's/^# cros-enablement: savedir-present=//p')"
    saved_mode="$(printf '%s\n' "$fields" | sed -n 's/^# cros-enablement: savedir-mode=//p')"
    saved_owner="$(printf '%s\n' "$fields" | sed -n 's/^# cros-enablement: savedir-owner=//p')"
    case "$saved_present" in
        0) [ "$saved_mode" = "-" ] && [ "$saved_owner" = "-" ] || return 1 ;;
        1)
            case "$saved_mode" in
                [0-7] | [0-7][0-7] | [0-7][0-7][0-7] | [0-7][0-7][0-7][0-7]) ;;
                *)
                    log_error "Invalid savedir mode in $dir/state."
                    return 1
                    ;;
            esac
            case "$saved_owner" in
                *:*) ;;
                *)
                    log_error "Invalid savedir owner in $dir/state."
                    return 1
                    ;;
            esac
            ;;
        *)
            log_error "Invalid savedir presence in $dir/state."
            return 1
            ;;
    esac
    while IFS=$'\t' read -r base path present type mode owner link sha; do
        case "$base" in \#*) continue ;; esac
        [ "$type" = "file" ] || continue
        # The staged/published dir is root:0700: a non-root caller must probe
        # through sudo or every copy would look "missing" (PAM-19).
        if ! _pam_fs_probe f "$dir/files/$base"; then
            log_error "$dir/files/$base is missing; refusing an incomplete PAM common-state snapshot."
            return 1
        fi
        sum="$(sudo sha256sum -- "$dir/files/$base" | awk '{print $1}')" || return 1
        [ "$sum" = "$sha" ] || {
            log_error "$dir/files/$base does not match its recorded checksum; refusing an incomplete snapshot."
            return 1
        }
    done <<< "$fields"
    return 0
}

_pam_snapshot_common_state() {
    # Publish the third half AFTER sidecar + .saved. First-wins: an existing
    # .common is validated and never overwritten.
    local stage="${_PAM_COMMON_SNAPSHOT_DIR}.stage.$$" tmp="" base file
    local saved_present=1 saved_mode="-" saved_owner="-" rc=0
    _PAM_COMMON_PUBLISHED=0
    if _pam_fs_probe e "$_PAM_COMMON_SNAPSHOT_DIR"; then
        log_error "Orphaned $_PAM_COMMON_SNAPSHOT_DIR has no sidecar published by this invocation; preserving it."
        return 1
    fi
    _pam_common_cleanup_stage "$stage"
    # Create the STAGE itself root:0700 before /files. A bare
    # `install -d -m 700 -- "$stage/files"` leaves the implicitly created
    # parent at the caller's umask (0755 under CI's umask 0022); the published
    # .common would then be 0755 despite the CI check and the docs (the
    # .saved half already installs its stage explicitly at 0700).
    if ! sudo install -d -m 700 -- "$stage" \
        || ! sudo install -d -m 700 -- "$stage/files"; then
        log_error "Could not create the PAM common-state staging directory."
        return 1
    fi
    tmp="$(_pam_tmp_file)" || {
        _pam_common_cleanup_stage "$stage"
        return 1
    }
    if _pam_fs_probe d "$_PAM_SAVED_DIR"; then
        saved_present=1
        saved_mode="$(sudo stat -c '%a' -- "$_PAM_SAVED_DIR")" || rc=1
        saved_owner="$(sudo stat -c '%u:%g' -- "$_PAM_SAVED_DIR")" || rc=1
    else
        saved_present=0
    fi
    {
        printf '%s\n' "$_PAM_COMMON_MAGIC"
        printf '# cros-enablement: savedir-path=%s\n' "$_PAM_SAVED_DIR"
        printf '# cros-enablement: savedir-present=%s\n' "$saved_present"
        printf '# cros-enablement: savedir-mode=%s\n' "$saved_mode"
        printf '# cros-enablement: savedir-owner=%s\n' "$saved_owner"
        for base in "${_PAM_COMMON_BASES[@]}"; do
            _pam_common_snapshot_row "$base" "$_PAM_DIR/$base" "$stage/files" || printf 'SNAPSHOT_ROW_FAILED\n'
        done
        _pam_common_snapshot_row sudo "$_PAM_SUDO_PATH" "$stage/files" || printf 'SNAPSHOT_ROW_FAILED\n'
    } >> "$tmp"
    # A row helper's failure is observable as an invalid extra line; never
    # publish a snapshot built from partial metadata.
    if [ "$rc" -ne 0 ] || grep -qF 'SNAPSHOT_ROW_FAILED' "$tmp" \
        || ! sudo install -m 600 -- "$tmp" "$stage/state" \
        || ! _pam_common_snapshot_readable "$stage"; then
        log_error "Could not build a complete PAM common/sudo state snapshot; refusing to publish it."
        rm -f -- "$tmp"
        _pam_common_cleanup_stage "$stage"
        return 1
    fi
    rm -f -- "$tmp"
    if _pam_fs_probe e "$_PAM_COMMON_SNAPSHOT_DIR"; then
        log_error "$_PAM_COMMON_SNAPSHOT_DIR appeared while staging; preserving it and refusing to publish."
        _pam_common_cleanup_stage "$stage"
        return 1
    fi
    # -T refuses a destination that appeared between the probe above and this
    # rename: a plain `mv dir dir` would nest OUR stage INSIDE the foreign
    # snapshot and even report success (P2-3 first-wins race).
    if ! sudo mv -T -- "$stage" "$_PAM_COMMON_SNAPSHOT_DIR"; then
        log_error "Could not publish the PAM common/sudo state snapshot."
        _pam_common_cleanup_stage "$stage"
        return 1
    fi
    _PAM_COMMON_PUBLISHED=1
    _pam_common_snapshot_readable || {
        log_error "Published PAM common/sudo state snapshot failed its read-back; refusing to continue."
        return 1
    }
    return 0
}

_pam_check_existing_common_snapshot() {
    # Called when an EXISTING sidecar won first-wins. A legacy sidecar predates
    # .common: degrade explicitly instead of claiming byte/metadata guarantees.
    if _pam_fs_probe e "$_PAM_COMMON_SNAPSHOT_DIR"; then
        _pam_common_snapshot_readable || return 1
        return 0
    fi
    if [ "${_PAM_VERIFY_LEGACY:-0}" -eq 1 ]; then
        log_warn "Legacy PAM snapshot has no $_PAM_COMMON_SNAPSHOT_DIR; common-*/sudo byte and metadata guarantees are unavailable for this install (best effort only)."
        return 0
    fi
    log_error "PAM sidecar carries metadata but $_PAM_COMMON_SNAPSHOT_DIR is missing; refusing a truncated three-half snapshot."
    return 1
}

# First-wins gate for an EXISTING sidecar. Invalid/partial metadata is never
# mistaken for "another installer published a complete snapshot". Legacy
# sidecars without saved-snapshot metadata stay compatible on a best-effort
# basis (they may predate the metadata line entirely).
_pam_validate_existing_snapshot() {
    local empty_rc=0 live_list count
    _pam_verify_sidecar_content || return 1
    case "$_PAM_VERIFY_SAVED" in
        complete)
            if [ ! -d "$_PAM_SAVED_SNAPSHOT_DIR" ] || ! _pam_saved_snapshot_readable; then
                log_error "Sidecar says saved-snapshot=complete but $_PAM_SAVED_SNAPSHOT_DIR is missing/unreadable; failing closed."
                return 1
            fi
            ;;
        absent)
            if [ -e "$_PAM_SAVED_SNAPSHOT_DIR" ]; then
                log_error "Sidecar says saved-snapshot=absent but $_PAM_SAVED_SNAPSHOT_DIR exists; failing closed."
                return 1
            fi
            ;;
        *)
            if [ "$_PAM_VERIFY_LEGACY" -ne 1 ]; then
                log_error "PAM sidecar has unrecognised saved-snapshot state '$_PAM_VERIFY_SAVED'; failing closed."
                return 1
            fi
            log_info "Legacy PAM sidecar without any optional metadata; using best-effort compatibility."
            if [ -d "$_PAM_SAVED_SNAPSHOT_DIR" ]; then
                empty_rc=0
                _pam_saved_snapshot_is_empty || empty_rc=$?
                case "$empty_rc" in
                    0)
                        # The previous release published an EMPTY .saved when
                        # /var/lib/pam existed but held no profiles. There are
                        # no original bytes to preserve; treat it as absent
                        # (never delete it - it may matter for manual recovery).
                        log_info "Legacy $_PAM_SAVED_SNAPSHOT_DIR is empty; treating it as saved-snapshot=absent."
                        ;;
                    1)
                        _pam_saved_snapshot_readable || {
                            log_error "Legacy saved PAM profile snapshot is unreadable; failing closed."
                            return 1
                        }
                        ;;
                    *)
                        log_error "Could not inspect legacy $_PAM_SAVED_SNAPSHOT_DIR; failing closed."
                        return 1
                        ;;
                esac
            else
                # Re-review #15 finding #3: NEVER re-snapshot the LIVE savedir to
                # repair a missing legacy .saved. install's --package may already
                # have changed those files, so a copy made now would silently
                # bless modified bytes as "original". Only an ABSENT/empty live
                # savedir can honestly be classified as saved-snapshot=absent;
                # a populated one needs manual recovery (PAM-41 empty case stays
                # compatible). Reviewer P2-1: a missing savedir makes sudo find
                # return 1, which must NOT become an install hard failure - the
                # old `[ -d ] || return 0` probe allowed that upgrade path. Only
                # an EXISTING but unreadable savedir fails closed.
                if ! _pam_fs_probe d "$_PAM_SAVED_DIR"; then
                    log_info "Legacy PAM sidecar has no .saved and $_PAM_SAVED_DIR does not exist; treating it as saved-snapshot=absent."
                else
                    live_list="$(_pam_enumerate_saved_files "$_PAM_SAVED_DIR")" || {
                        log_error "Could not inspect $_PAM_SAVED_DIR for the missing legacy saved snapshot; failing closed."
                        return 1
                    }
                    count="$(_pam_count_enumerated_files "$live_list")"
                    rm -f -- "$live_list"
                    if [ "$count" -gt 0 ]; then
                        log_error "Legacy PAM sidecar has no .saved while $_PAM_SAVED_DIR holds profile files (possibly modified by --package); refusing to re-snapshot live state - manual recovery required."
                        return 1
                    fi
                    log_info "Legacy PAM sidecar has no .saved and $_PAM_SAVED_DIR is empty; treating it as saved-snapshot=absent."
                fi
            fi
            ;;
    esac
    return 0
}

# Remove everything WE just published after a failed read-back. The sidecar is
# ours because this invocation won the hard-link race; .saved is ours ONLY when
# $1=1. An orphaned .saved from a previous crash/admin action is the sole copy
# of the original bytes and must NEVER be destroyed here (review P1-2).
_pam_rollback_own_snapshot() {
    local published_saved="${1:-0}" published_common="${2:-0}"
    sudo rm -f -- "$_PAM_SEL_SIDECAR" 2> /dev/null \
        || log_error "Could not remove the sidecar published by this invocation."
    if [ "$published_saved" -eq 1 ]; then
        sudo rm -rf -- "$_PAM_SAVED_SNAPSHOT_DIR" 2> /dev/null \
            || log_error "Could not remove the saved snapshot published by this invocation."
    fi
    if [ "$published_common" -eq 1 ]; then
        sudo rm -rf -- "$_PAM_COMMON_SNAPSHOT_DIR" 2> /dev/null \
            || log_error "Could not remove the common state snapshot published by this invocation."
    fi
    _pam_snapshot_cleanup_stage
}

_pam_snapshot_selection() {
    # A complete transaction: either BOTH halves of the snapshot are published
    # and verified, or nothing is published and this function returns non-zero.
    # Any failure is a hard gate failure for the Debian installer.
    local sel="" sel_rc=0 seen="" seen_line="" saved_line="" saved_state="absent"
    local tmp="" won=0 staged=0 published_saved=0 published_common=0 list count
    if [ -e "$_PAM_SEL_SIDECAR" ]; then
        log_info "Keeping the existing PAM selection snapshot at $_PAM_SEL_SIDECAR (first-wins)."
        _pam_validate_existing_snapshot || return 1
        _pam_check_existing_common_snapshot || return 1
        return 0
    fi
    # P1-2: a .saved without a sidecar may be the ONLY surviving original copy
    # (crash between publishes, a P1-1 consume failure, or an admin deleting
    # the sidecar). Never delete or overwrite it; fail closed and preserve it.
    if [ -e "$_PAM_SAVED_SNAPSHOT_DIR" ]; then
        log_error "Orphaned saved PAM profile snapshot $_PAM_SAVED_SNAPSHOT_DIR has no selection sidecar; preserving it and refusing to publish a new snapshot."
        return 1
    fi
    # Same rule for the third half: an orphaned .common is the only surviving
    # copy of the ORIGINAL common-*/sudo bytes/metadata (which the tool has
    # already rewritten), so it must never be replaced or removed here.
    if _pam_fs_probe e "$_PAM_COMMON_SNAPSHOT_DIR"; then
        log_error "Orphaned PAM common-state snapshot $_PAM_COMMON_SNAPSHOT_DIR has no selection sidecar; preserving it and refusing to publish a new snapshot."
        return 1
    fi
    # rc 0 + empty stdout is a LEGAL empty selection. rc 1 means the key is
    # absent / unreadable and must never be snapshotted as a successful empty.
    sel="$(_pam_read_selection)" || sel_rc=$?
    if [ "$sel_rc" -ne 0 ]; then
        log_error "Could not read debconf libpam-runtime/profiles (key absent or tool failure); refusing to snapshot an unreadable selection."
        return 1
    fi
    # P2-2: "tool genuinely unavailable" is the ONLY case allowed to produce
    # a legacy (value-only) snapshot. If debconf-communicate exists but FGET
    # fails, returns a non-true/false value or times out, that is a hard failure
    # of the same severity as a failed GET - never downgrade it to legacy.
    if command -v debconf-communicate > /dev/null 2>&1; then
        if ! seen="$(_pam_read_selection_seen)"; then
            log_error "debconf-communicate is available but reading the seen flag failed; refusing to snapshot a partial selection."
            return 1
        fi
        seen_line="# cros-enablement: selection-seen=$seen"
    else
        log_warn "debconf-communicate is unavailable; the snapshot restores the value only (legacy behaviour)."
    fi
    # Record whether /var/lib/pam existed at all, so restore can distinguish
    # "there was nothing to snapshot" from "the snapshot failed".
    if [ -d "$_PAM_SAVED_DIR" ]; then
        if ! _pam_stage_saved_dir; then
            log_error "Could not snapshot every saved PAM profile file; refusing to continue."
            return 1
        fi
        list="$(_pam_enumerate_saved_files "$_PAM_SAVED_SNAPSHOT_STAGE")" || {
            log_error "Could not enumerate the staged saved profile snapshot; refusing to continue."
            _pam_snapshot_cleanup_stage
            return 1
        }
        count="$(_pam_count_enumerated_files "$list")"
        rm -f -- "$list"
        if [ "$count" -eq 0 ]; then
            # An empty savedir holds no original bytes; recording "complete"
            # would demand a non-empty .saved that cannot exist (P2-3).
            log_info "$_PAM_SAVED_DIR is empty; recording saved-snapshot=absent."
            saved_state="absent"
            _pam_snapshot_cleanup_stage
        else
            saved_state="complete"
            staged=1
        fi
    else
        log_info "No saved PAM profile directory at $_PAM_SAVED_DIR; recording saved-snapshot=absent."
    fi
    saved_line="# cros-enablement: saved-snapshot=$saved_state"

    tmp="${_PAM_SEL_SIDECAR}.tmp.$$"
    _pam_remove_temp_file "$tmp"
    if ! {
        printf '%s\n' "$_PAM_SEL_MAGIC"
        [ -z "$seen_line" ] || printf '%s\n' "$seen_line"
        printf '%s\n' "$saved_line"
        printf '%s\n' "$sel"
    } | sudo tee "$tmp" > /dev/null; then
        log_error "Could not write the PAM selection snapshot; refusing to continue."
        _pam_remove_temp_file "$tmp"
        if [ "$staged" -eq 1 ]; then _pam_snapshot_cleanup_stage; fi
        return 1
    fi
    # tee inherits the caller's umask (077 under passwordless sudo), which would
    # leave a 0600 root-owned sidecar that a NON-ROOT uninstall cannot read.
    if ! sudo chmod 0644 -- "$tmp"; then
        log_error "Could not chmod the PAM selection snapshot; refusing to continue (a non-root uninstall could not read it)."
        _pam_remove_temp_file "$tmp"
        if [ "$staged" -eq 1 ]; then _pam_snapshot_cleanup_stage; fi
        return 1
    fi

    # Hard-link publish. On a genuine race the existing sidecar must still be
    # proven COMPLETE before we are allowed to report success (first-wins).
    if sudo ln "$tmp" "$_PAM_SEL_SIDECAR" 2> /dev/null; then
        won=1
    fi
    _pam_remove_temp_file "$tmp"
    if [ "$won" -eq 0 ]; then
        if [ "$staged" -eq 1 ]; then _pam_snapshot_cleanup_stage; fi
        if [ -e "$_PAM_SEL_SIDECAR" ]; then
            log_info "Another installer published $_PAM_SEL_SIDECAR first; validating its snapshot."
            _pam_validate_existing_snapshot || return 1
            _pam_check_existing_common_snapshot || return 1
            return 0
        fi
        log_error "Could not publish the PAM selection snapshot; refusing to continue."
        return 1
    fi

    if [ "$saved_state" = "complete" ]; then
        if ! _pam_publish_saved_dir; then
            log_error "Could not publish the saved PAM profile snapshot; refusing to continue."
            # An existing .saved is an orphan, NOT ours: flag 0 preserves it.
            _pam_rollback_own_snapshot 0
            return 1
        fi
        published_saved=1
    else
        # No live savedir: a .saved here would contradict our metadata. Never
        # delete it (it may be an orphan's only copy) - fail closed instead.
        if [ -e "$_PAM_SAVED_SNAPSHOT_DIR" ]; then
            log_error "$_PAM_SAVED_SNAPSHOT_DIR appeared while recording saved-snapshot=absent; preserving it and refusing to continue."
            _pam_rollback_own_snapshot 0
            return 1
        fi
        _pam_snapshot_cleanup_stage
    fi

    # Third half: the ORIGINAL common-*/sudo state must be captured before any
    # sed/--package mutation. If it cannot be built and verified, unwind all
    # three halves published by THIS invocation (orphans are never touched).
    if ! _pam_snapshot_common_state; then
        log_error "Could not publish the PAM common/sudo state snapshot; refusing to continue."
        # P2-3: existence is NOT ownership. If a foreign installer published
        # .common before our mv (or our mv lost the race), it is its ONLY copy:
        # _PAM_COMMON_PUBLISHED stays 0 and rollback preserves it byte-for-byte.
        _pam_rollback_own_snapshot "$published_saved" "$_PAM_COMMON_PUBLISHED"
        return 1
    fi
    published_common=1

    # Read back all THREE published halves before allowing any common-* /
    # debconf mutation. A failure unwinds our own publication.
    if ! _pam_verify_sidecar_content \
        || [ "$_PAM_VERIFY_VALUE" != "$sel" ] \
        || [ "$_PAM_VERIFY_SEEN" != "$seen" ] \
        || [ "$_PAM_VERIFY_SAVED" != "$saved_state" ]; then
        log_error "PAM selection snapshot failed its read-back verification; refusing to continue."
        _pam_rollback_own_snapshot "$published_saved" "$published_common"
        return 1
    fi
    if [ "$saved_state" = "complete" ] \
        && { ! _pam_saved_snapshot_readable || ! _pam_saved_snapshot_matches_live; }; then
        log_error "Saved PAM profile snapshot failed its read-back verification; refusing to continue."
        _pam_rollback_own_snapshot "$published_saved" "$published_common"
        return 1
    fi
    if ! _pam_common_snapshot_readable; then
        log_error "PAM common/sudo state snapshot failed its read-back verification; refusing to continue."
        _pam_rollback_own_snapshot "$published_saved" "$published_common"
        return 1
    fi
    log_info "Snapshotted the PAM profile selection to $_PAM_SEL_SIDECAR (saved-snapshot=$saved_state; common-state=complete)."
    return 0
}

_pam_selection_from_sidecar() {
    [ -f "$_PAM_SEL_SIDECAR" ] || return 1
    # All '# ...' lines are metadata (magic + optional seen flag), never data.
    sed '/^#/d' "$_PAM_SEL_SIDECAR" | tail -n 1
}

# Optional metadata added to new sidecars. A legacy sidecar has no such line:
# in that case restore the VALUE only and leave the live seen flag untouched.
_pam_selection_seen_from_sidecar() {
    [ -f "$_PAM_SEL_SIDECAR" ] || return 1
    local v
    v="$(sed -n 's/^# cros-enablement: selection-seen=\(true\|false\)$/\1/p' \
        "$_PAM_SEL_SIDECAR" | tail -n 1)"
    case "$v" in
        true | false)
            printf '%s' "$v"
            return 0
            ;;
        *) return 1 ;;
    esac
}

# pam-auth-update persists the debconf multiselect in canonical "a, b, c"
# order. An administrator's raw value may use a different order/spacing, which
# the tool canonicalizes on the next --package. Accept a whitespace-insensitive
# set match too, but NEVER accept a different set: a mismatch keeps the sidecar
# and returns 1 (fail closed).
_pam_selection_set() {
    tr ',' '\n' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | awk 'NF' | sort
}
_pam_selection_equal() {
    local e a
    [ "$1" = "$2" ] && return 0
    e="$(printf '%s\n' "$1" | _pam_selection_set)"
    a="$(printf '%s\n' "$2" | _pam_selection_set)"
    [ -n "$e" ] && [ "$e" = "$a" ]
}

_pam_restore_savedir_metadata() {
    # Restore the LIVE savedir's own mode/owner/presence from .common. Called
    # both before copying saved files back and again after all external tool
    # calls (so a tool that chmods the directory cannot go unnoticed).
    local fields line path present mode owner saved_path rc=0
    fields="$(_pam_common_snapshot_fields)" || {
        log_error "Could not read the PAM common-state manifest for the savedir metadata restore."
        return 1
    }
    while IFS=$'\t' read -r line; do
        case "$line" in
            \#\ cros-enablement:\ savedir-path=*) saved_path="${line#*=}" ;;
            \#\ cros-enablement:\ savedir-present=*) present="${line#*=}" ;;
            \#\ cros-enablement:\ savedir-mode=*) mode="${line#*=}" ;;
            \#\ cros-enablement:\ savedir-owner=*) owner="${line#*=}" ;;
        esac
    done <<< "$fields"
    if [ "$saved_path" != "$_PAM_SAVED_DIR" ]; then
        log_error "Saved PAM profile directory changed from '$saved_path' to '$_PAM_SAVED_DIR'; refusing to restore into a different location."
        return 1
    fi
    if [ "$present" = "1" ]; then
        if _pam_fs_probe d "$_PAM_SAVED_DIR" && ! _pam_fs_probe l "$_PAM_SAVED_DIR"; then
            :
        elif ! sudo install -d -m "$mode" -- "$_PAM_SAVED_DIR"; then
            log_error "Could not recreate $_PAM_SAVED_DIR with its original mode."
            return 1
        fi
        # chown first: changing ownership can clear setuid/setgid bits.
        if ! sudo chown "$owner" -- "$_PAM_SAVED_DIR" \
            || ! sudo chmod "$mode" -- "$_PAM_SAVED_DIR"; then
            log_error "Could not restore the original mode/owner of $_PAM_SAVED_DIR."
            return 1
        fi
    elif [ "$present" = "0" ]; then
        if _pam_fs_probe d "$_PAM_SAVED_DIR" && ! _pam_fs_probe l "$_PAM_SAVED_DIR"; then
            if ! sudo rmdir -- "$_PAM_SAVED_DIR" 2> /dev/null; then
                log_error "$_PAM_SAVED_DIR was originally absent but is now a non-empty directory; refusing to delete live state - manual recovery required."
                return 1
            fi
        fi
    else
        log_error "Invalid savedir presence in the PAM common-state manifest."
        return 1
    fi
    return "$rc"
}

_pam_restore_saved_dir_snapshot() {
    local f base rc=0 list
    [ -d "$_PAM_SAVED_SNAPSHOT_DIR" ] || return 0
    # Restore the directory's ORIGINAL mode/owner before writing into it; the
    # old unconditional `install -d -m 755` silently destroyed a root:0700
    # savedir (finding #3). Legacy snapshots have no .common: keep the old
    # fallback and say so explicitly.
    if _pam_fs_probe e "$_PAM_COMMON_SNAPSHOT_DIR"; then
        _pam_restore_savedir_metadata || return 1
    else
        log_warn "No PAM common-state snapshot; $_PAM_SAVED_DIR directory metadata is restored on a best-effort basis only."
        if [ ! -d "$_PAM_SAVED_DIR" ]; then
            if ! sudo install -d -m 755 -- "$_PAM_SAVED_DIR"; then
                log_error "Could not recreate $_PAM_SAVED_DIR for the saved PAM profile restore."
                return 1
            fi
        fi
    fi
    # The snapshot dir is root:0700. A plain user glob matches nothing for a
    # non-root caller (rc 0, no warning), leaving /var/lib/pam permanently
    # inconsistent with common-*. Enumerate, copy AND verify every file through
    # sudo; never delete the snapshot (it may be the only surviving copy).
    list="$(_pam_enumerate_saved_files "$_PAM_SAVED_SNAPSHOT_DIR")" || {
        log_error "Could not enumerate the saved PAM profile snapshot."
        return 1
    }
    while IFS= read -r -d '' f; do
        base="${f##*/}"
        if ! sudo cp -a -- "$f" "$_PAM_SAVED_DIR/$base" \
            || ! sudo cmp -s -- "$f" "$_PAM_SAVED_DIR/$base"; then
            log_error "Could not restore saved PAM profile '$base' byte-for-byte from its snapshot."
            rc=1
        fi
    done < "$list"
    rm -f -- "$list"
    return "$rc"
}

_pam_converge_profiles() {
    if ! command -v pam-auth-update > /dev/null 2>&1; then
        log_warn "pam-auth-update is unavailable; keeping the selection snapshot for uninstall convergence."
        return 0
    fi
    if ! sudo pam-auth-update --package; then
        log_warn "pam-auth-update --package failed; keeping the selection snapshot for uninstall convergence."
        return 0
    fi
    log_info "pam-auth-update --package converged the debconf selection and saved profiles (no fprintd)."
    return 0
}

_pam_keep_retry_data() {
    log_error "PAM snapshot restore FAILED; keeping $_PAM_SEL_SIDECAR, $_PAM_SAVED_SNAPSHOT_DIR and $_PAM_COMMON_SNAPSHOT_DIR (if present) intact for retry."
}

# Rebuild the EXACT sidecar from the values still held in variables after a
# partially failed consume. Reproducing from parts (rather than from a `$(cat)`
# variable) preserves the legal EMPTY data line and all metadata verbatim.
_pam_rebuild_sidecar() {
    local value="$1" seen="$2" has_seen="$3" saved_state="$4" is_legacy="${5:-0}"
    local tmp="${_PAM_SEL_SIDECAR}.rebuild.$$"
    if ! sudo rm -f -- "$tmp" 2> /dev/null; then
        log_error "Could not clear the sidecar rebuild temp file $tmp."
        return 1
    fi
    if ! {
        printf '%s\n' "$_PAM_SEL_MAGIC"
        if [ "$is_legacy" -eq 0 ]; then
            if [ "$has_seen" -eq 1 ]; then
                printf '# cros-enablement: selection-seen=%s\n' "$seen"
            fi
            printf '# cros-enablement: saved-snapshot=%s\n' "$saved_state"
        fi
        printf '%s\n' "$value"
    } | sudo tee "$tmp" > /dev/null; then
        log_error "Could not write the rebuilt PAM selection sidecar."
        _pam_remove_temp_file "$tmp"
        return 1
    fi
    if ! sudo chmod 0644 -- "$tmp"; then
        log_error "Could not chmod the rebuilt PAM selection sidecar."
        _pam_remove_temp_file "$tmp"
        return 1
    fi
    if ! sudo ln "$tmp" "$_PAM_SEL_SIDECAR" 2> /dev/null; then
        log_error "Could not publish the rebuilt PAM selection sidecar."
        _pam_remove_temp_file "$tmp"
        return 1
    fi
    _pam_remove_temp_file "$tmp"
    if ! _pam_verify_sidecar_content; then
        log_error "Rebuilt PAM selection sidecar failed read-back parsing."
        return 1
    fi
    if [ "$_PAM_VERIFY_VALUE" != "$value" ]; then
        log_error "Rebuilt PAM selection sidecar lost its value."
        return 1
    fi
    if [ "$is_legacy" -eq 1 ]; then
        if [ "$_PAM_VERIFY_LEGACY" -ne 1 ]; then
            log_error "Rebuilt legacy PAM sidecar no longer parses as legacy."
            return 1
        fi
    elif { [ "$has_seen" -eq 1 ] && [ "$_PAM_VERIFY_SEEN" != "$seen" ]; } \
        || [ "$_PAM_VERIFY_SAVED" != "$saved_state" ]; then
        log_error "Rebuilt PAM selection sidecar lost its metadata."
        return 1
    fi
    return 0
}

# Consume the snapshot with a recoverable order. We remove the sidecar FIRST
# while .saved is still the only original copy; if .saved removal then fails,
# the sidecar is rebuilt from the values still in memory. For the first two
# halves, every exit has BOTH halves present (retryable) or BOTH gone (success)
# (review P1-1). EXCEPTION: the third (.common) half is consumed AFTER .saved;
# if that final removal fails the saved bytes are gone and CANNOT be rebuilt
# from memory, so the rebuilt sidecar is forensics only and MANUAL recovery is
# REQUIRED -- never claim the three halves stay retryable (final review P2).
_pam_consume_snapshot() {
    local value="$1" seen="$2" has_seen="$3" saved_state="$4" is_legacy="${5:-0}"
    if ! sudo rm -f -- "$_PAM_SEL_SIDECAR" \
        || [ -e "$_PAM_SEL_SIDECAR" ]; then
        log_error "Could not remove $_PAM_SEL_SIDECAR; both halves are kept intact for retry."
        _pam_keep_retry_data
        return 1
    fi
    if ! sudo rm -rf -- "$_PAM_SAVED_SNAPSHOT_DIR" \
        || [ -e "$_PAM_SAVED_SNAPSHOT_DIR" ]; then
        log_error "Could not remove $_PAM_SAVED_SNAPSHOT_DIR; rebuilding the sidecar so both halves stay retryable."
        if _pam_rebuild_sidecar "$value" "$seen" "$has_seen" "$saved_state" "$is_legacy"; then
            _pam_keep_retry_data
        else
            log_error "CRITICAL: could not rebuild the PAM selection sidecar; the original bytes remain at $_PAM_SAVED_SNAPSHOT_DIR but manual recovery is REQUIRED."
        fi
        return 1
    fi
    # Third half LAST: .saved is already gone here, so a failure is NOT
    # retryable -- rebuilding the sidecar cannot recreate the consumed saved
    # bytes (a retry would fail closed on saved-snapshot=complete). Keep the
    # rebuilt sidecar for forensics and say so explicitly (final review P2).
    if _pam_fs_probe e "$_PAM_COMMON_SNAPSHOT_DIR"; then
        if ! sudo rm -rf -- "$_PAM_COMMON_SNAPSHOT_DIR" \
            || _pam_fs_probe e "$_PAM_COMMON_SNAPSHOT_DIR"; then
            log_error "Could not remove $_PAM_COMMON_SNAPSHOT_DIR; .saved was already consumed and cannot be rebuilt, so this state is NOT retryable."
            if _pam_rebuild_sidecar "$value" "$seen" "$has_seen" "$saved_state" "$is_legacy"; then
                log_error "CRITICAL: PAM snapshot consume failed at the third half; the rebuilt sidecar and original common/sudo state remain at $_PAM_COMMON_SNAPSHOT_DIR but manual recovery is REQUIRED."
            else
                log_error "CRITICAL: could not rebuild the PAM selection sidecar; the original common/sudo state remains at $_PAM_COMMON_SNAPSHOT_DIR but manual recovery is REQUIRED."
            fi
            return 1
        fi
    fi
    return 0
}

# Re-apply the ORIGINAL common-*/sudo state AFTER every external tool call.
# This is deliberately idempotent: stage -> verify -> atomic mv (regular file),
# ln -sfn (symlink), rm -f (was absent). A directory at any target is a hard
# failure - rm -rf would destroy live state. No sed is used here (PAM-7).
_pam_restore_common_state_from_snapshot() {
    local fields base path present type mode owner link sha stage probe live
    local live_norm snap_norm rc=0
    fields="$(_pam_common_snapshot_fields)" || {
        log_error "Could not read $_PAM_COMMON_SNAPSHOT_DIR/state for the final common/sudo restore."
        return 1
    }
    while IFS=$'\t' read -r base path present type mode owner link sha; do
        case "$base" in \#*) continue ;; esac
        if _pam_fs_probe d "$path" && ! _pam_fs_probe l "$path"; then
            log_error "Refusing to restore PAM target $path: a directory occupies it (manual recovery required)."
            rc=1
            continue
        fi
        case "$type" in
            absent)
                if ! sudo rm -f -- "$path" || _pam_fs_probe e "$path" || _pam_fs_probe l "$path"; then
                    log_error "Could not remove PAM target $path recorded as originally absent."
                    rc=1
                fi
                ;;
            link)
                if ! sudo rm -f -- "$path" || ! sudo ln -sfn -- "$link" "$path"; then
                    log_error "Could not restore PAM symlink $path -> $link."
                    rc=1
                fi
                ;;
            file)
                # Re-applying over an ADMIN's semantic edit would destroy data
                # that is not ours. A tool rewriting whitespace/mode is benign
                # (its normalised line sequence is unchanged) and IS repaired here.
                live_norm="$(_pam_common_normalized_hash "$path")"
                snap_norm="$(_pam_common_normalized_hash "$_PAM_COMMON_SNAPSHOT_DIR/files/$base")"
                if [ "$live_norm" != "$snap_norm" ]; then
                    log_error "External content change detected in $path since the snapshot (added/removed/reordered MODULE line); refusing to overwrite it - manual recovery required."
                    rc=1
                    continue
                fi
                stage="${path}.cros-common-restore.$$"
                sudo rm -f -- "$stage" 2> /dev/null
                if ! sudo install -m 600 -- "$_PAM_COMMON_SNAPSHOT_DIR/files/$base" "$stage" \
                    || ! sudo chown "$owner" -- "$stage" \
                    || ! sudo chmod "$mode" -- "$stage" \
                    || ! sudo cmp -s -- "$_PAM_COMMON_SNAPSHOT_DIR/files/$base" "$stage" \
                    || ! sudo mv -f -- "$stage" "$path"; then
                    log_error "Could not atomically restore PAM file $path from the common-state snapshot."
                    sudo rm -f -- "$stage" 2> /dev/null
                    rc=1
                fi
                ;;
            *)
                log_error "Unsupported PAM target type '$type' for $path in the common-state snapshot."
                rc=1
                ;;
        esac
    done <<< "$fields"
    if ! _pam_restore_savedir_metadata; then
        rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        return 1
    fi
    # Independent post-restore read-back (the authoritative final verification
    # below repeats it after selection/seen checks).
    while IFS=$'\t' read -r base path present type mode owner link sha; do
        case "$base" in \#*) continue ;; esac
        probe="$(_pam_probe_common_target "$path")" || {
            rc=1
            continue
        }
        live="$(printf '%s' "$probe" | cut -f2-)"
        if [ "$live" != "$(printf '%s\t%s\t%s\t%s\t%s' "$type" "$mode" "$owner" "$link" "$sha")" ]; then
            log_error "Post-restore read-back of $path does not match its original snapshot ($live)."
            rc=1
        fi
    done <<< "$fields"
    [ "$rc" -eq 0 ] || return 1
    log_info "PAM common/sudo state re-applied from $_PAM_COMMON_SNAPSHOT_DIR after all external tool calls."
    return 0
}

# Final authority for common-*/sudo and the savedir directory itself.
# rc 0 = strict verification passed, 1 = mismatch/failure, 2 = no .common
# (legacy degradation; callers must WARN and must NOT claim byte guarantees).
_pam_verify_common_targets_against_snapshot() {
    local fields base path present type mode owner link sha probe live mode_live owner_live
    local link_live sha_live type_live present_live rc=0
    local saved_path saved_present saved_mode saved_owner line
    if ! _pam_fs_probe e "$_PAM_COMMON_SNAPSHOT_DIR"; then
        log_warn "No PAM common-state snapshot ($_PAM_COMMON_SNAPSHOT_DIR); final common-*/sudo byte/metadata verification is unavailable (legacy best effort)."
        return 2
    fi
    fields="$(_pam_common_snapshot_fields)" || {
        log_error "Could not read $_PAM_COMMON_SNAPSHOT_DIR/state for final verification."
        return 1
    }
    while IFS=$'\t' read -r base path present type mode owner link sha; do
        case "$base" in \#*) continue ;; esac
        probe="$(_pam_probe_common_target "$path")" || {
            rc=1
            continue
        }
        IFS=$'\t' read -r present_live type_live mode_live owner_live link_live sha_live <<< "$probe"
        if [ "$type_live" != "$type" ] || [ "$present_live" != "$present" ]; then
            log_error "Final PAM state mismatch for $base ($path): expected $present/$type, got $present_live/$type_live."
            rc=1
            continue
        fi
        if [ "$type" = "absent" ]; then
            continue
        fi
        if [ "$mode_live" != "$mode" ] || [ "$owner_live" != "$owner" ] \
            || [ "$link_live" != "$link" ] || [ "$sha_live" != "$sha" ]; then
            log_error "Final PAM state mismatch for $base ($path): expected mode=$mode owner=$owner link=$link sha=$sha, got mode=$mode_live owner=$owner_live link=$link_live sha=$sha_live."
            rc=1
        fi
    done <<< "$fields"
    saved_path=""
    while IFS=$'\t' read -r line; do
        case "$line" in
            \#\ cros-enablement:\ savedir-path=*) saved_path="${line#*=}" ;;
            \#\ cros-enablement:\ savedir-present=*) saved_present="${line#*=}" ;;
            \#\ cros-enablement:\ savedir-mode=*) saved_mode="${line#*=}" ;;
            \#\ cros-enablement:\ savedir-owner=*) saved_owner="${line#*=}" ;;
        esac
    done <<< "$fields"
    if [ "$saved_path" != "$_PAM_SAVED_DIR" ]; then
        log_error "Final savedir path mismatch: snapshot '$saved_path', live '$_PAM_SAVED_DIR'."
        rc=1
    fi
    if [ "$saved_present" = "1" ]; then
        if ! _pam_fs_probe d "$_PAM_SAVED_DIR" || _pam_fs_probe l "$_PAM_SAVED_DIR"; then
            log_error "Final savedir state mismatch: originally a directory, now absent or a symlink."
            rc=1
        else
            [ "$(sudo stat -c '%a' -- "$_PAM_SAVED_DIR")" = "$saved_mode" ] \
                || {
                    log_error "Final savedir mode mismatch (expected $saved_mode)."
                    rc=1
                }
            [ "$(sudo stat -c '%u:%g' -- "$_PAM_SAVED_DIR")" = "$saved_owner" ] \
                || {
                    log_error "Final savedir owner mismatch (expected $saved_owner)."
                    rc=1
                }
        fi
    elif [ "$saved_present" = "0" ]; then
        if _pam_fs_probe e "$_PAM_SAVED_DIR" || _pam_fs_probe l "$_PAM_SAVED_DIR"; then
            log_error "Final savedir state mismatch: originally absent but still present."
            rc=1
        fi
    fi
    [ "$rc" -eq 0 ] || return 1
    log_info "Verified final common-*/sudo state (bytes, mode, owner, type, link target, absence) and savedir metadata against $_PAM_COMMON_SNAPSHOT_DIR."
    return 0
}

_pam_restore_debian_selection() {
    local snapshot="" seen="" restore_seen=0 current="" current_seen="" current_rc=0
    local tool_failed=0 is_legacy=0 empty_rc=0 has_common=0 common_rc=0
    # Defensive second gate: even if a caller forgot the disable-side check,
    # touching debconf/savedir while manifest records survive would diverge
    # from common-* and make a later --package refuse to reconcile.
    if ! _pam_rollback_complete; then
        log_error "Rollback is incomplete; refusing to restore the PAM selection."
        _pam_keep_retry_data
        return 1
    fi
    if [ ! -f "$_PAM_SEL_SIDECAR" ]; then
        # P2: an orphaned .saved without its sidecar cannot identify which
        # selection/profile set it belongs to. This is NOT "nothing to do".
        if [ -e "$_PAM_SAVED_SNAPSHOT_DIR" ] || _pam_fs_probe e "$_PAM_COMMON_SNAPSHOT_DIR"; then
            log_error "Orphaned PAM snapshot half ($_PAM_SAVED_SNAPSHOT_DIR / $_PAM_COMMON_SNAPSHOT_DIR) has no selection sidecar; restore is impossible and requires manual recovery."
            return 1
        fi
        log_info "No PAM selection snapshot at $_PAM_SEL_SIDECAR; nothing to restore."
        return 0
    fi
    if ! _pam_verify_sidecar_content; then
        _pam_keep_retry_data
        return 1
    fi
    # The third half is strict whenever it exists. A genuine LEGACY sidecar
    # predates it: degrade openly instead of silently claiming byte guarantees.
    if _pam_fs_probe e "$_PAM_COMMON_SNAPSHOT_DIR"; then
        if ! _pam_common_snapshot_readable; then
            log_error "PAM common/sudo state snapshot is missing/corrupt; refusing to consume the selection snapshot."
            _pam_keep_retry_data
            return 1
        fi
        has_common=1
    elif [ "$_PAM_VERIFY_LEGACY" -eq 1 ]; then
        log_warn "Legacy PAM snapshot has no $_PAM_COMMON_SNAPSHOT_DIR; uninstall falls back to manifest bytes only (no final mode/owner/type guarantee)."
    else
        log_error "PAM sidecar carries metadata but $_PAM_COMMON_SNAPSHOT_DIR is missing; refusing a truncated three-half restore."
        _pam_keep_retry_data
        return 1
    fi
    case "$_PAM_VERIFY_SAVED" in
        complete)
            if [ ! -d "$_PAM_SAVED_SNAPSHOT_DIR" ]; then
                log_error "Sidecar requires $_PAM_SAVED_SNAPSHOT_DIR but it is missing; failing closed."
                _pam_keep_retry_data
                return 1
            fi
            ;;
        absent)
            if [ -e "$_PAM_SAVED_SNAPSHOT_DIR" ]; then
                log_error "Sidecar says saved-snapshot=absent but $_PAM_SAVED_SNAPSHOT_DIR exists; failing closed."
                _pam_keep_retry_data
                return 1
            fi
            ;;
        *)
            # A genuine LEGACY sidecar from the previous release has neither
            # optional metadata line but DID publish .saved. Infer the state
            # from the filesystem so upgrades can still be uninstalled. A
            # seen-without-saved (truncated) sidecar was already rejected by
            # _pam_verify_sidecar_content and can never reach this branch.
            if [ "$_PAM_VERIFY_LEGACY" -ne 1 ]; then
                log_error "PAM sidecar has no usable saved-snapshot state '$_PAM_VERIFY_SAVED'; failing closed."
                _pam_keep_retry_data
                return 1
            fi
            is_legacy=1
            if [ -d "$_PAM_SAVED_SNAPSHOT_DIR" ]; then
                empty_rc=0
                _pam_saved_snapshot_is_empty || empty_rc=$?
                case "$empty_rc" in
                    0)
                        _PAM_VERIFY_SAVED="absent"
                        log_info "Legacy PAM sidecar has an empty $_PAM_SAVED_SNAPSHOT_DIR; inferring saved-snapshot=absent (best-effort)."
                        ;;
                    1)
                        _PAM_VERIFY_SAVED="complete"
                        log_info "Legacy PAM sidecar has no saved metadata; inferring saved-snapshot=complete from $_PAM_SAVED_SNAPSHOT_DIR (best-effort)."
                        ;;
                    *)
                        log_error "Could not inspect legacy $_PAM_SAVED_SNAPSHOT_DIR; failing closed."
                        _pam_keep_retry_data
                        return 1
                        ;;
                esac
            else
                _PAM_VERIFY_SAVED="absent"
                log_info "Legacy PAM sidecar has no saved metadata and no $_PAM_SAVED_SNAPSHOT_DIR; inferring saved-snapshot=absent (best-effort)."
            fi
            ;;
    esac
    # Restore the saved module files first; a failure here is fatal and never
    # discards the only surviving copy of the original bytes.
    if ! _pam_restore_saved_dir_snapshot; then
        _pam_keep_retry_data
        return 1
    fi
    if ! snapshot="$(_pam_selection_from_sidecar)"; then
        log_error "Could not read the selection sidecar $_PAM_SEL_SIDECAR."
        _pam_keep_retry_data
        return 1
    fi
    # An EMPTY value is legal and must be restored too (it may clear a value the
    # tool derived during install); only an unreadable source is a hard error.
    if seen="$(_pam_selection_seen_from_sidecar)"; then
        restore_seen=1
    fi

    # A missing/failing tool is NOT success by itself: keep going, read the
    # live state back and consume the snapshot ONLY if every managed state is
    # provably identical to what we snapshotted (PAM-16/17 policy).
    if ! command -v debconf-set-selections > /dev/null 2>&1; then
        log_warn "debconf-set-selections is unavailable; verifying the live selection before consuming the snapshot."
        tool_failed=1
    elif ! printf 'libpam-runtime libpam-runtime/profiles multiselect %s\n' "$snapshot" \
        | sudo debconf-set-selections; then
        log_warn "debconf-set-selections failed; verifying the live selection before consuming the snapshot."
        tool_failed=1
    fi
    if ! command -v pam-auth-update > /dev/null 2>&1; then
        log_warn "pam-auth-update is unavailable during restore; verifying all managed state before consuming the snapshot."
        tool_failed=1
    elif ! sudo pam-auth-update --package; then
        log_warn "pam-auth-update --package failed during restore; verifying all managed state before consuming the snapshot."
        tool_failed=1
    fi
    # debconf-set-selections / --package mark the question seen. Re-apply the
    # snapshotted flag AFTER the last tool call so it cannot be overwritten.
    # Legacy sidecars have no seen metadata: skip this entirely (backward compat).
    if [ "$restore_seen" -eq 1 ] && ! _pam_set_selection_seen "$seen"; then
        log_error "Could not restore the debconf seen flag ('$seen')."
        _pam_keep_retry_data
        return 1
    fi
    # FINDING #2: every external PAM tool call is now DONE. Only now may we
    # re-apply the original common-*/sudo state; doing this before --package
    # would let the tool rewrite it again and still pass a record-only check.
    log_info "PAM external tool calls complete; re-applying the original common/sudo state."
    if [ "$has_common" -eq 1 ] \
        && ! _pam_restore_common_state_from_snapshot; then
        _pam_keep_retry_data
        return 1
    fi
    current="$(_pam_read_selection)" || current_rc=$?
    if [ "$current_rc" -ne 0 ]; then
        log_error "Could not read the debconf selection after restore."
        _pam_keep_retry_data
        return 1
    fi
    if [ "$restore_seen" -eq 1 ]; then
        current_seen="$(_pam_read_selection_seen)" || current_seen="UNREADABLE"
    fi

    # (a)/(d) rollback complete again after the tool calls; (e) final common-*/
    # sudo bytes/metadata/type/absence; (b) every saved module byte-identical;
    # (c) debconf value AND seen equal the snapshot. Manifest consumption is
    # checked but is NEVER used as a proxy for final file state.
    log_info "Verifying final PAM state before consuming the snapshot..."
    if ! _pam_rollback_complete; then
        _pam_keep_retry_data
        return 1
    fi
    _pam_verify_common_targets_against_snapshot || common_rc=$?
    if [ "$common_rc" -ne 0 ] && [ "$common_rc" -ne 2 ]; then
        _pam_keep_retry_data
        return 1
    fi
    # Use the (possibly inferred) state, not mere directory existence: a
    # legacy empty .saved is treated as "absent" and must not block restore.
    # New sidecars with saved-snapshot=complete keep the strict check.
    if [ "$_PAM_VERIFY_SAVED" = "complete" ] && ! _pam_saved_snapshot_matches_live; then
        _pam_keep_retry_data
        return 1
    fi
    if ! _pam_selection_equal "$snapshot" "$current" \
        || { [ "$restore_seen" -eq 1 ] && [ "$current_seen" != "$seen" ]; }; then
        log_error "PAM selection restore verification failed: expected '$snapshot' (seen=$seen), got '$current' (seen=$current_seen)."
        _pam_keep_retry_data
        return 1
    fi
    if [ "$tool_failed" -eq 1 ]; then
        log_info "A PAM tool failed during restore, but every managed state was verified identical; consuming the snapshot."
    fi
    if ! _pam_consume_snapshot "$snapshot" "$seen" "$restore_seen" "$_PAM_VERIFY_SAVED" "$is_legacy"; then
        return 1
    fi
    log_success "Original PAM profile selection restored; snapshot consumed."
    return 0
}

# Same expression the pam-auth-update stub uses to model the tool's file effect
# (tests/rollback-test.sh). Unanchored on purpose: remove every pam_fprintd.so
# module line in the file, nothing else. Do NOT use pam-auth-update
# --remove/--disable/--force here — see the comment above.
_PAM_COMMON_FP_SED_EXPR='/pam_fprintd\.so/d'

_pam_strip_fprintd_from_common_files() {
    local base file
    for base in "${_PAM_COMMON_BASES[@]}"; do
        file="$_PAM_DIR/$base"
        [ -e "$file" ] || [ -L "$file" ] || continue
        grep -qF -- 'pam_fprintd.so' "$file" 2> /dev/null || continue
        if [ -L "$file" ]; then
            log_error "Refusing to sed a symlinked $file (would replace the link); original bytes are rollback-tracked and the file must be edited manually."
            return 1
        fi
        if ! sudo sed -i "$_PAM_COMMON_FP_SED_EXPR" "$file"; then
            log_error "Could not strip pam_fprintd.so from $file; original backup stays tracked for rollback"
            return 1
        fi
        if grep -qF -- 'pam_fprintd.so' "$file"; then
            log_error "pam_fprintd.so still present in $file after strip; refusing to continue"
            return 1
        fi
        log_info "Removed pam_fprintd.so line(s) from $file; original bytes are tracked for rollback."
    done
    return 0
}

_configure_pam_fingerprint_body() {
    log_info "Configuring PAM for fingerprint authentication on $DISTRO_FAMILY ($DISTRO_ID)..."

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "PAM configuration skipped in dry-run mode."
        return 0
    fi

    local sudo_pam="$_PAM_SUDO_PATH"
    local fp_line="$_PAM_FP_SUDO_LINE"

    case "$DISTRO_FAMILY" in
        debian)
            # IMPORTANT: do NOT use `pam-auth-update --enable fprintd` here.
            # That profile injects pam_fprintd into /etc/pam.d/common-auth,
            # which is included by gdm-password. On unlock GDM forks the
            # gdm-password worker and the gdm-fingerprint worker concurrently;
            # both would Claim the single fprintd device, the loser gets
            # "Device was already claimed" and the lock screen shows no
            # fingerprint prompt (GNOME/gdm#1071, fprintd#214).
            # Fix: keep fprintd OUT of common-auth and enable it ONLY for sudo.
            # Snapshot the debconf selection + saved profiles FIRST as a MANDATORY
            # gate: no backup, sed or converge may run until both halves are
            # published and verified. Then track every existing common-* file so
            # rollback restores ORIGINAL bytes.
            _pam_snapshot_selection || return $?
            _pam_backup_common_files || return $?
            if [ "$_PAM_COMMON_FP_FOUND" -eq 1 ]; then
                # Direct sed removes the fp lines immediately (closing the GDM
                # race) without ever using `--remove`, which deletes the
                # debconf profile selection outright.
                _pam_strip_fprintd_from_common_files || return $?
                log_info "fprintd removed from common-* via direct line removal; original bytes are rollback-tracked."
            else
                log_info "No pam_fprintd line in Debian common-* PAM files; nothing to strip."
            fi
            # Converge debconf + /var/lib/pam to the no-fprintd state NOW, so a
            # later package-triggered --package is a no-op. The snapshot above
            # is the only authority for restoring the original selection.
            _pam_converge_profiles

            if [ -f "$sudo_pam" ]; then
                if grep -qFx -- "$fp_line" "$sudo_pam"; then
                    log_info "pam_fprintd already configured in $sudo_pam."
                else
                    log_info "Enabling fingerprint for sudo only in $sudo_pam..."
                    backup_file_manifest_aware "$sudo_pam" "fingerprint"
                    # Remove any other fingerprint PAM module lines first
                    # (e.g. a stale rust-fp module) to keep a single stack.
                    sudo sed -i '/^auth[[:space:]].*\(pam_fprintd\.so\|rust_fp\|fp_pam\)/d' "$sudo_pam"
                    sudo sed -i '0,/^@include common-auth$/s//auth sufficient pam_fprintd.so max-tries=1 timeout=10\n&/' "$sudo_pam"
                    if grep -qFx -- "$fp_line" "$sudo_pam"; then
                        log_success "sudo fingerprint PAM configured."
                    else
                        log_warn "@include common-auth anchor not found in $sudo_pam; sudo fingerprint NOT configured."
                    fi
                fi
            else
                log_warn "$sudo_pam not found; sudo fingerprint not configured."
            fi
            ;;
        fedora)
            # NOTE: authselect's with-fingerprint profile injects
            # pam_fprintd into system-auth, which gdm-password also includes
            # — the same GDM unlock claim race as on Debian (GNOME/gdm#1071,
            # fprintd#214). Keep pam_fprintd OUT of system-auth and enable it
            # ONLY for sudo. /etc/pam.d/sudo is not managed by authselect, so
            # this survives `authselect apply-changes`.
            if command -v authselect > /dev/null 2>&1; then
                log_info "Reverting any with-fingerprint profile to avoid the GDM unlock claim race..."
                sudo authselect disable-feature with-fingerprint 2> /dev/null || true
                sudo authselect apply-changes 2> /dev/null || true
            fi
            if [ -f "$sudo_pam" ]; then
                if grep -qFx -- "$fp_line" "$sudo_pam"; then
                    log_info "pam_fprintd already configured in $sudo_pam."
                else
                    log_info "Enabling fingerprint for sudo only in $sudo_pam..."
                    backup_file_manifest_aware "$sudo_pam" "fingerprint"
                    # Remove any other fingerprint PAM module lines first
                    # (e.g. a stale rust-fp module) to keep a single stack.
                    sudo sed -i '/^auth[[:space:]].*\(pam_fprintd\.so\|rust_fp\|fp_pam\)/d' "$sudo_pam"
                    sudo sed -i '0,/^auth[[:space:]]\+include[[:space:]]\+system-auth/s//auth sufficient pam_fprintd.so max-tries=1 timeout=10\n&/' "$sudo_pam"
                    if grep -qFx -- "$fp_line" "$sudo_pam"; then
                        log_success "sudo fingerprint PAM configured."
                    else
                        log_warn "'auth include system-auth' anchor not found in $sudo_pam; sudo fingerprint NOT configured."
                    fi
                fi
            else
                log_warn "$sudo_pam not found; sudo fingerprint not configured."
            fi
            ;;
        suse)
            # Do NOT use `pam-config -a --fprintd` — it injects pam_fprintd into
            # common-auth/system-auth which gdm-password includes, causing the
            # GDM unlock claim race (GNOME/gdm#1071). Enable ONLY for sudo.
            if command -v pam-config > /dev/null 2>&1; then
                log_info "Removing fprintd from common-auth/system-auth to avoid GDM claim race..."
                sudo pam-config -d --fprintd 2> /dev/null || true
            fi
            if [ -f "$sudo_pam" ]; then
                if grep -qFx -- "$fp_line" "$sudo_pam"; then
                    log_info "pam_fprintd already configured in $sudo_pam."
                else
                    log_info "Enabling fingerprint for sudo only in $sudo_pam..."
                    backup_file_manifest_aware "$sudo_pam" "fingerprint"
                    sudo sed -i '/^auth[[:space:]].*\(pam_fprintd\.so\|rust_fp\|fp_pam\)/d' "$sudo_pam"
                    sudo sed -i '0,/^auth[[:space:]]\+include[[:space:]]\+system-auth/s//auth sufficient pam_fprintd.so max-tries=1 timeout=10\n&/' "$sudo_pam"
                    if grep -qFx -- "$fp_line" "$sudo_pam"; then
                        log_success "sudo fingerprint PAM configured."
                    else
                        log_warn "'auth include system-auth' anchor not found in $sudo_pam; sudo fingerprint NOT configured."
                    fi
                fi
            else
                log_warn "$sudo_pam not found; sudo fingerprint not configured."
            fi
            ;;
        arch)
            # Do NOT add pam_fprintd to /etc/pam.d/system-auth: gdm-password
            # includes system-auth and would race the dedicated
            # gdm-fingerprint PAM worker for the single fprintd device Claim
            # on unlock (GNOME/gdm#1071). Enable fingerprint for sudo only.
            if [ -f "$sudo_pam" ]; then
                if grep -qFx -- "$fp_line" "$sudo_pam"; then
                    log_info "pam_fprintd already configured in $sudo_pam."
                else
                    log_info "Enabling fingerprint for sudo only in $sudo_pam..."
                    backup_file_manifest_aware "$sudo_pam" "fingerprint"
                    sudo sed -i '/^auth[[:space:]].*\(pam_fprintd\.so\|rust_fp\|fp_pam\)/d' "$sudo_pam"
                    sudo sed -i '0,/^auth[[:space:]]\+include[[:space:]]\+system-auth/s//auth sufficient pam_fprintd.so max-tries=1 timeout=10\n&/' "$sudo_pam"
                    if grep -qFx -- "$fp_line" "$sudo_pam"; then
                        log_success "sudo fingerprint PAM configured."
                    else
                        log_warn "'auth include system-auth' anchor not found in $sudo_pam; sudo fingerprint NOT configured."
                    fi
                fi
            else
                log_warn "$sudo_pam not found; sudo fingerprint not configured."
            fi
            ;;
        nixos)
            log_info "For NixOS, set 'services.fprintd.enable = true;' with the crfpmoc-enabled libfprint override and 'security.pam.services.sudo.fprintAuth = true;' (see docs/distros/nixos.md)."
            ;;
        *)
            log_warn "Automatic PAM configuration not implemented for $DISTRO_FAMILY. Please check distribution documentation."
            ;;
    esac
}

# Read-only post-rollback check. The manifest is the ONLY authority on whether
# we backed up this sudo PAM file: if a record survived, rollback did NOT
# restore it. Uninstall must never run sed here — deleting a pre-existing line
# would destroy the user's original configuration and make a failed rollback
# even worse. rc 2 (corrupt manifest) is also warn-only, never a mutation.
_pam_sudo_post_rollback_check() {
    local sudo_pam="$_PAM_SUDO_PATH"
    local rc=0
    manifest_has_target "$sudo_pam" || rc=$?
    case "$rc" in
        0)
            log_warn "Manifest still records $sudo_pam: rollback did not restore it. Uninstall did NOT modify this file; remove the project line manually if needed."
            ;;
        1) ;; # record consumed by a successful rollback, or we never touched it
        2)
            log_warn "Manifest at $MANIFEST_FILE is corrupt/invalid; cannot confirm rollback of $sudo_pam. Uninstall did NOT modify this file."
            ;;
    esac
}

# A surviving record for ANY file rollback was supposed to restore means
# rollback is not complete: touching debconf / /var/lib/pam now would diverge
# from common-* and make a later --package refuse to reconcile ("Local
# modifications ... not updating", rc 0). manifest_has_target is read-only and
# lock-free, so probing sudo plus every common-* is safe here.
# 0=all records consumed, 1=a record survived, 2=manifest untrustworthy.
_pam_rollback_complete() {
    local base path rc=0
    manifest_has_target "$_PAM_SUDO_PATH" || rc=$?
    case "$rc" in
        0)
            log_warn "Manifest still records $_PAM_SUDO_PATH: rollback is incomplete, leaving the PAM selection snapshot for retry."
            return 1
            ;;
        2)
            log_warn "Manifest at $MANIFEST_FILE is corrupt/invalid; leaving the PAM selection snapshot for retry."
            return 2
            ;;
    esac
    for base in "${_PAM_COMMON_BASES[@]}"; do
        path="$_PAM_DIR/$base"
        # FINDING #3: NEVER skip the manifest probe because the live file is
        # missing. "Originally present, currently gone, restore failed" leaves
        # a surviving record - exactly the case a live-file check hides.
        rc=0
        manifest_has_target "$path" || rc=$?
        case "$rc" in
            0)
                log_warn "Manifest still records $path: rollback is incomplete, leaving the PAM selection snapshot for retry."
                return 1
                ;;
            2)
                log_warn "Manifest at $MANIFEST_FILE is corrupt/invalid; leaving the PAM selection snapshot for retry."
                return 2
                ;;
        esac
    done
    return 0
}

disable_pam_fingerprint() {
    local rc=0
    log_info "Disabling PAM fingerprint authentication on $DISTRO_FAMILY ($DISTRO_ID)..."

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "PAM rollback skipped in dry-run mode."
        return 0
    fi

    case "$DISTRO_FAMILY" in
        debian)
            # common-*/sudo are restored by manifest rollback; this function
            # never seds them. The debconf profile selection and /var/lib/pam
            # are outside the manifest, so they are restored from the first-wins
            # sidecar snapshot and converged with --package ONLY after rollback
            # is confirmed complete (a surviving sudo record means "retry").
            local probe_rc=0
            _pam_rollback_complete || probe_rc=$?
            case "$probe_rc" in
                0) _pam_restore_debian_selection || rc=$? ;;
                # FINDING #3: propagate the probe rc (including rc 2 for a
                # corrupt manifest) instead of warning and returning success.
                *) rc="$probe_rc" ;; # warning logged by _pam_rollback_complete
            esac
            ;;
        fedora)
            log_info "sudo PAM is restored by manifest rollback; $_PAM_SUDO_PATH is not edited."
            # Known limitation: authselect's profile state is outside the
            # manifest. Keep the existing tool calls, but tell the user.
            if command -v authselect > /dev/null 2>&1; then
                log_info "Disabling fingerprint via authselect..."
                sudo authselect disable-feature with-fingerprint 2> /dev/null || true
                sudo authselect apply-changes 2> /dev/null || true
                log_warn "authselect profile state is not tracked by the manifest; restore any pre-existing with-fingerprint profile manually."
            fi
            ;;
        suse)
            log_info "sudo PAM is restored by manifest rollback; $_PAM_SUDO_PATH is not edited."
            # Known limitation: pam-config's profile state is outside the
            # manifest. Keep the existing tool calls, but tell the user.
            if command -v pam-config > /dev/null 2>&1; then
                log_info "Ensuring fprintd not in common-auth via pam-config..."
                sudo pam-config -d --fprintd 2> /dev/null || true
                log_warn "pam-config profile state is not tracked by the manifest; restore any pre-existing fprintd profile manually."
            fi
            ;;
        arch)
            log_info "sudo PAM is restored by manifest rollback; $_PAM_SUDO_PATH is not edited."
            log_info "Please revert any manual PAM fprintd entries from /etc/pam.d/system-auth if needed."
            ;;
        nixos)
            log_info "Revert the services.fprintd / PAM options in configuration.nix if needed."
            ;;
        *)
            log_info "Please revert any manual PAM fprintd entries from /etc/pam.d/system-auth if needed."
            ;;
    esac

    # One check for every distro: silent when the record was consumed, explicit
    # warning when rollback failed or the manifest cannot be trusted. It stays
    # read-only and is ALWAYS called, but its own rc never masks the real rc.
    _pam_sudo_post_rollback_check
    return "$rc"
}

# PAM backup/record -> sed mutation is one operation; DRY_RUN is handled by the
# wrapper before taking the lock (the body also keeps its own early return).
configure_pam_fingerprint() {
    run_manifest_operation _configure_pam_fingerprint_body "$@"
}
