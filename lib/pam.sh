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

configure_pam_fingerprint() {
    log_info "Configuring PAM for fingerprint authentication on $DISTRO_FAMILY ($DISTRO_ID)..."

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "PAM configuration skipped in dry-run mode."
        return 0
    fi

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
            if command -v pam-auth-update > /dev/null 2>&1; then
                log_info "Removing fprintd from common-auth (avoids the GDM unlock claim race)..."
                sudo pam-auth-update --remove fprintd
                log_success "fprintd removed from common-auth."
            else
                log_warn "pam-auth-update not found. Please verify /etc/pam.d/common-auth manually."
            fi

            local sudo_pam="/etc/pam.d/sudo"
            if [ -f "$sudo_pam" ]; then
                local fp_line="auth sufficient pam_fprintd.so max-tries=1 timeout=10"
                if grep -q "^${fp_line}$" "$sudo_pam"; then
                    log_info "pam_fprintd already configured in $sudo_pam."
                else
                    log_info "Enabling fingerprint for sudo only in $sudo_pam..."
                    backup_file "$sudo_pam"
                    manifest_add_entry "$sudo_pam" "fingerprint" "1"
                    # Remove any other fingerprint PAM module lines first
                    # (e.g. a stale rust-fp module) to keep a single stack.
                    sudo sed -i '/^auth[[:space:]].*\(pam_fprintd\.so\|rust_fp\|fp_pam\)/d' "$sudo_pam"
                    sudo sed -i '/^@include common-auth$/i auth sufficient pam_fprintd.so max-tries=1 timeout=10' "$sudo_pam"
                    log_success "sudo fingerprint PAM configured."
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
            local sudo_pam="/etc/pam.d/sudo"
            if [ -f "$sudo_pam" ]; then
                local fp_line="auth sufficient pam_fprintd.so max-tries=1 timeout=10"
                if grep -q "^${fp_line}$" "$sudo_pam"; then
                    log_info "pam_fprintd already configured in $sudo_pam."
                else
                    log_info "Enabling fingerprint for sudo only in $sudo_pam..."
                    backup_file_manifest_aware "$sudo_pam" "fingerprint"
                    # Remove any other fingerprint PAM module lines first
                    # (e.g. a stale rust-fp module) to keep a single stack.
                    sudo sed -i '/^auth[[:space:]].*\(pam_fprintd\.so\|rust_fp\|fp_pam\)/d' "$sudo_pam"
                    sudo sed -i '0,/^auth[[:space:]]\+include[[:space:]]\+system-auth/i auth sufficient pam_fprintd.so max-tries=1 timeout=10' "$sudo_pam"
                    log_success "sudo fingerprint PAM configured."
                fi
            else
                log_warn "$sudo_pam not found; sudo fingerprint not configured."
            fi
            ;;
        suse)
            if command -v pam-config > /dev/null 2>&1; then
                log_info "Enabling fprintd via pam-config..."
                sudo pam-config -a --fprintd
                log_success "PAM configuration updated via pam-config."
            else
                log_warn "pam-config not found. Please enable fprintd in PAM manually."
            fi
            ;;
        arch)
            # Do NOT add pam_fprintd to /etc/pam.d/system-auth: gdm-password
            # includes system-auth and would race the dedicated
            # gdm-fingerprint PAM worker for the single fprintd device Claim
            # on unlock (GNOME/gdm#1071). Enable fingerprint for sudo only.
            local sudo_pam="/etc/pam.d/sudo"
            if [ -f "$sudo_pam" ]; then
                local fp_line="auth sufficient pam_fprintd.so max-tries=1 timeout=10"
                if grep -q "^${fp_line}$" "$sudo_pam"; then
                    log_info "pam_fprintd already configured in $sudo_pam."
                else
                    log_info "Enabling fingerprint for sudo only in $sudo_pam..."
                    backup_file_manifest_aware "$sudo_pam" "fingerprint"
                    sudo sed -i '/^auth[[:space:]].*\(pam_fprintd\.so\|rust_fp\|fp_pam\)/d' "$sudo_pam"
                    sudo sed -i '/^auth[[:space:]]\+include[[:space:]]\+system-auth/i auth sufficient pam_fprintd.so max-tries=1 timeout=10' "$sudo_pam"
                    log_success "sudo fingerprint PAM configured."
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

disable_pam_fingerprint() {
    log_info "Disabling PAM fingerprint authentication on $DISTRO_FAMILY ($DISTRO_ID)..."

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "PAM rollback skipped in dry-run mode."
        return 0
    fi

    case "$DISTRO_FAMILY" in
        debian)
            local sudo_pam="/etc/pam.d/sudo"
            if [ -f "$sudo_pam" ]; then
                log_info "Removing pam_fprintd from $sudo_pam..."
                sudo sed -i '/^auth sufficient pam_fprintd.so/d' "$sudo_pam"
                log_success "sudo PAM fingerprint line removed."
            fi
            if command -v pam-auth-update > /dev/null 2>&1; then
                log_info "Disabling fprintd via pam-auth-update..."
                sudo pam-auth-update --remove fprintd
                log_success "PAM fingerprint configuration removed."
            fi
            ;;
        fedora)
            local sudo_pam="/etc/pam.d/sudo"
            if [ -f "$sudo_pam" ]; then
                log_info "Removing pam_fprintd from $sudo_pam..."
                sudo sed -i '/^auth sufficient pam_fprintd.so/d' "$sudo_pam"
                log_success "sudo PAM fingerprint line removed."
            fi
            if command -v authselect > /dev/null 2>&1; then
                log_info "Disabling fingerprint via authselect..."
                sudo authselect disable-feature with-fingerprint 2> /dev/null || true
                sudo authselect apply-changes 2> /dev/null || true
                log_success "PAM fingerprint configuration removed."
            fi
            ;;
        suse)
            if command -v pam-config > /dev/null 2>&1; then
                log_info "Disabling fprintd via pam-config..."
                sudo pam-config -d --fprintd
                log_success "PAM fingerprint configuration removed."
            fi
            ;;
        arch)
            local sudo_pam="/etc/pam.d/sudo"
            if [ -f "$sudo_pam" ]; then
                sudo sed -i '/^auth sufficient pam_fprintd.so/d' "$sudo_pam"
                log_info "Removed pam_fprintd from $sudo_pam."
            fi
            log_info "Please revert any manual PAM fprintd entries from /etc/pam.d/system-auth if needed."
            ;;
        nixos)
            log_info "Revert the services.fprintd / PAM options in configuration.nix if needed."
            ;;
        *)
            log_info "Please revert any manual PAM fprintd entries from /etc/pam.d/system-auth if needed."
            ;;
    esac
}
