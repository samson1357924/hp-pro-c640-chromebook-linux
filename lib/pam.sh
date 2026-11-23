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

# Debian's `pam-auth-update --remove fprintd` REWRITES the common-* stack, so
# the pre-existing bytes must be backed up and tracked for rollback BEFORE the
# tool runs. Only files that really contain a pam_fprintd line are claimed; an
# unrelated common-auth is never recorded by us. The caller reads the flag
# below to decide whether the tool call is needed at all.
_PAM_COMMON_FP_FOUND=0
_pam_backup_common_files_with_fprintd() {
    local base file
    _PAM_COMMON_FP_FOUND=0
    for base in common-auth common-account common-session \
        common-session-noninteractive common-password; do
        file="$_PAM_DIR/$base"
        [ -f "$file" ] || continue
        if grep -qF -- 'pam_fprintd.so' "$file"; then
            backup_file_manifest_aware "$file" "fingerprint" || return $?
            _PAM_COMMON_FP_FOUND=1
        fi
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
            # Track any common-* file we are about to change so rollback (not
            # a post-rollback tool call) restores its ORIGINAL bytes.
            _pam_backup_common_files_with_fprintd || return $?
            if [ "$_PAM_COMMON_FP_FOUND" -eq 1 ]; then
                if command -v pam-auth-update > /dev/null 2>&1; then
                    log_info "Removing fprintd from common-auth (avoids the GDM unlock claim race)..."
                    sudo pam-auth-update --remove fprintd
                    log_success "fprintd removed from common-auth."
                else
                    log_warn "pam-auth-update not found. Please verify /etc/pam.d/common-auth manually."
                fi
            else
                log_info "No pam_fprintd line in Debian common-* PAM files; skipping pam-auth-update --remove."
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

disable_pam_fingerprint() {
    log_info "Disabling PAM fingerprint authentication on $DISTRO_FAMILY ($DISTRO_ID)..."

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "PAM rollback skipped in dry-run mode."
        return 0
    fi

    case "$DISTRO_FAMILY" in
        debian)
            # common-auth bytes are restored by rollback_component(), NOT by a
            # post-rollback `pam-auth-update --remove fprintd` (that rewrote the
            # file a second time and could drop the user's original entries).
            log_info "sudo and common-* PAM files are restored by manifest rollback; $_PAM_SUDO_PATH is not edited."
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
