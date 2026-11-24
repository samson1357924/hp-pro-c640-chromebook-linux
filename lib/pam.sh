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
# We still NEVER call `pam-auth-update --remove`: that action deletes the
# debconf profile selection outright.
_PAM_COMMON_BASES=(common-auth common-account common-session common-session-noninteractive common-password)
_PAM_COMMON_FP_FOUND=0
_PAM_SAVED_DIR="${CROS_ENABLEMENT_PAM_SAVED_DIR:-/var/lib/pam}"
_PAM_SEL_SIDECAR="${CROS_ENABLEMENT_PAM_SELECTION_FILE:-${MANIFEST_FILE%/*}/pam-selection}"
_PAM_SAVED_SNAPSHOT_DIR="${_PAM_SEL_SIDECAR}.saved"
_PAM_SEL_MAGIC='# cros-enablement: PAM profile selection snapshot (first-wins; do not edit)'

_pam_backup_common_files() {
    local base file
    _PAM_COMMON_FP_FOUND=0
    for base in "${_PAM_COMMON_BASES[@]}"; do
        file="$_PAM_DIR/$base"
        [ -f "$file" ] || continue
        # Every common-* can be rewritten by --package, so every existing one
        # must be rollback-tracked byte-for-byte, not only those with fp lines.
        backup_file_manifest_aware "$file" "fingerprint" || return $?
        if grep -qF -- 'pam_fprintd.so' "$file"; then
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
    reply="$(sudo debconf-show libpam-runtime 2>/dev/null \
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
                    true|false) printf '%s' "$value"; return 0 ;;
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

# Snapshot every saved module file into a per-PID staging directory. Nothing is
# published here: the caller publishes the COMPLETE staging directory with one
# rename only after the selection sidecar is ready, so neither half of the
# snapshot can ever be observed half written. Every read/copy goes through sudo
# so a non-root caller with passwordless sudo can snapshot a root-only
# /var/lib/pam (a plain user glob would silently match nothing).
_pam_stage_saved_dir() {
    local f base rc=0
    [ -d "$_PAM_SAVED_DIR" ] || return 0
    sudo rm -rf -- "$_PAM_SAVED_SNAPSHOT_STAGE" 2> /dev/null || true
    sudo install -d -m 700 -- "$_PAM_SAVED_SNAPSHOT_STAGE" || return 1
    while IFS= read -r -d '' f; do
        base="${f##*/}"
        sudo cp -a -- "$f" "$_PAM_SAVED_SNAPSHOT_STAGE/$base" || rc=1
    done < <(sudo find "$_PAM_SAVED_DIR" -maxdepth 1 -type f -print0 2> /dev/null)
    return "$rc"
}

_pam_publish_saved_dir() {
    # A single rename publishes the staging dir. The installer holds the
    # manifest lock for its whole operation, so sidecar + .saved are published
    # as one atomic unit with respect to any other installer.
    [ -d "$_PAM_SAVED_SNAPSHOT_STAGE" ] || return 1
    if [ -e "$_PAM_SAVED_SNAPSHOT_DIR" ]; then
        sudo rm -rf -- "$_PAM_SAVED_SNAPSHOT_STAGE" 2> /dev/null || true
        return 0
    fi
    if ! sudo mv -- "$_PAM_SAVED_SNAPSHOT_STAGE" "$_PAM_SAVED_SNAPSHOT_DIR"; then
        sudo rm -rf -- "$_PAM_SAVED_SNAPSHOT_STAGE" 2> /dev/null || true
        return 1
    fi
    return 0
}

_pam_snapshot_saved_dir() {
    # Repair entry point: a sidecar may already exist while .saved is missing
    # (crash between the two publishes). Never skip that case forever.
    [ -e "$_PAM_SAVED_SNAPSHOT_DIR" ] && return 0
    _pam_stage_saved_dir || return 1
    _pam_publish_saved_dir
}

_pam_snapshot_selection() {
    local sel="" sel_rc=0 seen="" has_seen=0 seen_line="" tmp won=0 staged=0
    if [ -e "$_PAM_SEL_SIDECAR" ]; then
        log_info "Keeping the existing PAM selection snapshot at $_PAM_SEL_SIDECAR (first-wins)."
        # Repair the other half of a partially published snapshot instead of
        # leaving the saved profiles permanently out of sync.
        _pam_snapshot_saved_dir \
            || log_warn "Could not repair the saved PAM profile snapshot; uninstall convergence may be incomplete."
        return 0
    fi
    # rc 0 + empty stdout is a LEGAL empty selection. rc 1 means the key is
    # absent / unreadable and must never be snapshotted as a successful empty.
    sel="$(_pam_read_selection)" || sel_rc=$?
    if [ "$sel_rc" -ne 0 ]; then
        log_error "Could not read debconf libpam-runtime/profiles (key absent or tool failure); refusing to snapshot an unreadable selection."
        return 1
    fi
    if seen="$(_pam_read_selection_seen)"; then
        has_seen=1
        seen_line="# cros-enablement: selection-seen=$seen"
    else
        log_warn "Could not read the debconf seen flag; the snapshot restores the value only (legacy behaviour)."
    fi
    tmp="${_PAM_SEL_SIDECAR}.tmp.$$"
    if ! {
        printf '%s\n' "$_PAM_SEL_MAGIC"
        [ -z "$seen_line" ] || printf '%s\n' "$seen_line"
        printf '%s\n' "$sel"
    } \
        | sudo tee "$tmp" > /dev/null; then
        log_warn "Could not write the PAM selection snapshot; the original selection cannot be restored automatically."
        sudo rm -f -- "$tmp" 2> /dev/null || true
        return 0
    fi
    # tee inherits the caller's umask (077 under passwordless sudo), which would
    # leave a 0600 root-owned sidecar that a NON-ROOT uninstall cannot read.
    sudo chmod 0644 -- "$tmp" 2> /dev/null \
        || log_warn "Could not chmod the PAM selection snapshot; a non-root uninstall may not be able to read it."
    # Prepare the saved-dir snapshot BEFORE either file becomes visible.
    if _pam_stage_saved_dir; then
        staged=1
    else
        log_warn "Could not snapshot every saved PAM profile file; uninstall convergence may be incomplete."
    fi
    # Hard-link publish: fails harmlessly if another installer won first-wins.
    if sudo ln "$tmp" "$_PAM_SEL_SIDECAR" 2> /dev/null; then
        won=1
        log_info "Snapshotted the PAM profile selection to $_PAM_SEL_SIDECAR."
    else
        log_info "Another installer published $_PAM_SEL_SIDECAR first; keeping its snapshot."
    fi
    sudo rm -f -- "$tmp"
    if [ "$staged" -eq 1 ] && [ -d "$_PAM_SAVED_SNAPSHOT_STAGE" ] \
        && { [ "$won" -eq 1 ] || [ ! -e "$_PAM_SAVED_SNAPSHOT_DIR" ]; }; then
        _pam_publish_saved_dir \
            || log_warn "Could not publish the saved PAM profile snapshot; uninstall convergence may be incomplete."
    else
        sudo rm -rf -- "$_PAM_SAVED_SNAPSHOT_STAGE" 2> /dev/null || true
    fi
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
        true|false) printf '%s' "$v"; return 0 ;;
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

_pam_restore_saved_dir_snapshot() {
    [ -d "$_PAM_SAVED_SNAPSHOT_DIR" ] || return 0
    if [ ! -d "$_PAM_SAVED_DIR" ]; then
        sudo install -d -m 755 -- "$_PAM_SAVED_DIR" || return 1
    fi
    local f base rc=0
    # The snapshot dir is root:0700. A plain user glob matches nothing for a
    # non-root caller (rc 0, no warning), leaving /var/lib/pam permanently
    # inconsistent with common-*. Enumerate and copy through sudo instead.
    while IFS= read -r -d '' f; do
        base="${f##*/}"
        sudo cp -a -- "$f" "$_PAM_SAVED_DIR/$base" || rc=1
    done < <(sudo find "$_PAM_SAVED_SNAPSHOT_DIR" -maxdepth 1 -type f -print0 2> /dev/null)
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

_pam_restore_debian_selection() {
    if [ ! -f "$_PAM_SEL_SIDECAR" ]; then
        log_info "No PAM selection snapshot at $_PAM_SEL_SIDECAR; nothing to restore."
        return 0
    fi
    local snapshot="" seen="" restore_seen=0 current="" current_seen="" current_rc=0
    # Saved module snapshots are restored even if the debconf value could not
    # be captured, so the files never stay in the converged no-fprintd state.
    _pam_restore_saved_dir_snapshot \
        || log_warn "Could not restore every saved PAM profile file from the snapshot."
    if ! snapshot="$(_pam_selection_from_sidecar)"; then
        log_error "Could not read the selection sidecar $_PAM_SEL_SIDECAR; keeping it for retry."
        return 1
    fi
    # An EMPTY value is legal and must be restored too (it may clear a value the
    # tool derived during install); only an unreadable source is a hard error.
    if seen="$(_pam_selection_seen_from_sidecar)"; then
        restore_seen=1
    fi
    if ! command -v debconf-set-selections > /dev/null 2>&1; then
        log_warn "debconf-set-selections is unavailable; keeping $_PAM_SEL_SIDECAR for retry."
        return 0
    fi
    if ! printf 'libpam-runtime libpam-runtime/profiles multiselect %s\n' "$snapshot" \
        | sudo debconf-set-selections; then
        log_warn "debconf-set-selections failed; keeping $_PAM_SEL_SIDECAR for retry."
        return 0
    fi
    if command -v pam-auth-update > /dev/null 2>&1; then
        sudo pam-auth-update --package \
            || log_warn "pam-auth-update --package failed during restore; verifying the debconf value directly."
    fi
    # debconf-set-selections / --package mark the question seen. Re-apply the
    # snapshotted flag AFTER the last tool call so it cannot be overwritten.
    # Legacy sidecars have no seen metadata: skip this entirely (backward compat).
    if [ "$restore_seen" -eq 1 ] && ! _pam_set_selection_seen "$seen"; then
        log_error "Could not restore the debconf seen flag ('$seen'); keeping $_PAM_SEL_SIDECAR for retry."
        return 1
    fi
    current="$(_pam_read_selection)" || current_rc=$?
    if [ "$current_rc" -ne 0 ]; then
        log_error "Could not read the debconf selection after restore; keeping $_PAM_SEL_SIDECAR for retry."
        return 1
    fi
    if [ "$restore_seen" -eq 1 ]; then
        current_seen="$(_pam_read_selection_seen)" || current_seen="UNREADABLE"
    fi
    if _pam_selection_equal "$snapshot" "$current" \
        && { [ "$restore_seen" -eq 0 ] || [ "$current_seen" = "$seen" ]; }; then
        sudo rm -f -- "$_PAM_SEL_SIDECAR"
        sudo rm -rf -- "$_PAM_SAVED_SNAPSHOT_DIR"
        log_success "Original PAM profile selection restored; snapshot consumed."
        return 0
    fi
    log_error "PAM selection restore verification failed: expected '$snapshot' (seen=$seen), got '$current' (seen=$current_seen). Keeping $_PAM_SEL_SIDECAR for retry."
    return 1
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
        [ -f "$file" ] || continue
        grep -qF -- 'pam_fprintd.so' "$file" || continue
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
            # Snapshot the debconf selection + saved profiles FIRST, then track
            # every existing common-* file so rollback restores ORIGINAL bytes.
            _pam_snapshot_selection
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
        [ -f "$path" ] || continue
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
                0) _pam_restore_debian_selection || return $? ;;
                *) ;; # warning logged by _pam_rollback_complete; keep the snapshot for retry
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
    # warning when rollback failed or the manifest cannot be trusted.
    _pam_sudo_post_rollback_check
}

# PAM backup/record -> sed mutation is one operation; DRY_RUN is handled by the
# wrapper before taking the lock (the body also keeps its own early return).
configure_pam_fingerprint() {
    run_manifest_operation _configure_pam_fingerprint_body "$@"
}
