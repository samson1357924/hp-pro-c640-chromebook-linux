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
            if command -v pam-auth-update >/dev/null 2>&1; then
                log_info "Enabling fprintd via pam-auth-update..."
                sudo pam-auth-update --enable fprintd
                log_success "PAM configuration updated via pam-auth-update."
            else
                log_warn "pam-auth-update not found. Please verify /etc/pam.d/common-auth manually."
            fi
            ;;
        fedora)
            if command -v authselect >/dev/null 2>&1; then
                log_info "Enabling fingerprint via authselect..."
                sudo authselect enable-feature with-fingerprint
                sudo authselect apply-changes
                log_success "PAM configuration updated via authselect."
            else
                log_warn "authselect not found. Please enable fprintd in PAM manually."
            fi
            ;;
        suse)
            if command -v pam-config >/dev/null 2>&1; then
                log_info "Enabling fprintd via pam-config..."
                sudo pam-config -a --fprintd
                log_success "PAM configuration updated via pam-config."
            else
                log_warn "pam-config not found. Please enable fprintd in PAM manually."
            fi
            ;;
        arch)
            log_info "For Arch Linux, PAM configuration is typically managed in /etc/pam.d/system-auth."
            log_info "Add 'auth sufficient pam_fprintd.so' above pam_unix.so if not automatically present."
            ;;
        nixos)
            log_info "For NixOS, ensure 'services.fprintd.enable = true;' is in configuration.nix."
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
            if command -v pam-auth-update >/dev/null 2>&1; then
                log_info "Disabling fprintd via pam-auth-update..."
                sudo pam-auth-update --remove fprintd
                log_success "PAM fingerprint configuration removed."
            fi
            ;;
        fedora)
            if command -v authselect >/dev/null 2>&1; then
                log_info "Disabling fingerprint via authselect..."
                sudo authselect disable-feature with-fingerprint
                sudo authselect apply-changes
                log_success "PAM fingerprint configuration removed."
            fi
            ;;
        suse)
            if command -v pam-config >/dev/null 2>&1; then
                log_info "Disabling fprintd via pam-config..."
                sudo pam-config -d --fprintd
                log_success "PAM fingerprint configuration removed."
            fi
            ;;
        arch|nixos|*)
            log_info "Please revert any manual PAM fprintd entries from /etc/pam.d/system-auth if needed."
            ;;
    esac
}
