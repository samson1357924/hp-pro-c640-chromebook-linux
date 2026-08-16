#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# fingerprint/install-fingerprint.sh - Cross-Distro Fingerprint Driver (crfpmoc) Installer & Manager
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
# shellcheck source=lib/pam.sh
source "$ROOT_DIR/lib/pam.sh"

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --install, -i      Build & install crfpmoc libfprint driver & configure PAM (default)"
    echo "  --check, -c        Check fingerprint hardware, node, and driver status"
    echo "  --uninstall, -u    Uninstall custom libfprint driver & restore system package"
    echo "  --dry-run, -n      Preview steps without executing commands"
    echo "  --help, -h         Show this help message"
}

check_fp_status() {
    log_section "HP Pro c640 Fingerprint Hardware & Driver Status"
    check_dmi_board || true
    check_cros_fp_device || true

    local real_user
    real_user="$(get_real_user)"

    log_info "fprintd Device List for user '$real_user':"
    if command -v fprintd-list > /dev/null 2>&1; then
        fprintd-list "$real_user" || log_warn "fprintd-list returned non-zero. Device may not be registered yet."
    else
        log_warn "fprintd-list command not found in PATH."
    fi

    log_info "Installed libfprint libraries in $LIBDIR:"
    ls -la "$LIBDIR"/libfprint-2.so* 2> /dev/null || log_warn "No libfprint-2.so found in $LIBDIR."
}

uninstall_fp() {
    log_section "Uninstalling Custom crfpmoc Driver"
    rollback_component "fingerprint"

    if [ "${DRY_RUN:-0}" != "1" ]; then
        sudo udevadm control --reload-rules 2> /dev/null || true
        log_info "Reloaded udev rules."

        # Revert PAM
        disable_pam_fingerprint || true

        # Re-register restored stock libraries
        sudo ldconfig

        log_info "To restore your distribution's stock libfprint package, run:"
        case "$DISTRO_FAMILY" in
            debian) echo "  sudo apt install --reinstall -y libfprint-2-2" ;;
            fedora) echo "  sudo dnf reinstall -y libfprint" ;;
            arch) echo "  sudo pacman -S --overwrite='*' libfprint" ;;
            suse) echo "  sudo zypper install --force libfprint-2-2" ;;
            *) echo "  Reinstall libfprint package via your distribution's package manager." ;;
        esac
    fi
    log_success "Fingerprint driver uninstallation finished."
}

install_fp() {
    log_section "Installing crfpmoc Fingerprint Driver for HP Pro c640 ($DISTRO_NAME)"

    # 0. Preflight checks
    check_dmi_board || true
    check_cros_fp_device || true

    local real_user
    real_user="$(get_real_user)"

    # 1. Install build dependencies
    log_step 1 6 "Installing compilation tools and dependencies for $DISTRO_FAMILY..."
    read -r -a build_deps <<< "$(get_fingerprint_build_deps)"
    install_packages "${build_deps[@]}"

    # 2. Configure udev device permissions & user group
    log_step 2 6 "Configuring udev permissions for /dev/cros_fp..."
    local udev_rule_dst="/etc/udev/rules.d/60-cros-fp.rules"
    local udev_rule_existed=0
    if [ -e "$udev_rule_dst" ]; then
        udev_rule_existed=1
    fi
    backup_file "$udev_rule_dst"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install 60-cros-fp.rules to $udev_rule_dst"
        log_dryrun "Add user '$real_user' to group plugdev"
    else
        sudo install -D -m 0644 "$SCRIPT_DIR/60-cros-fp.rules" "$udev_rule_dst"
        manifest_add_entry "$udev_rule_dst" "fingerprint" "$udev_rule_existed"

        # Ensure plugdev group exists and add user
        if ! getent group plugdev > /dev/null 2>&1; then
            sudo groupadd plugdev 2> /dev/null || true
        fi
        if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
            sudo usermod -aG plugdev "$real_user" || true
            log_success "Added user '$real_user' to 'plugdev' group."
        fi

        sudo udevadm control --reload-rules 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=misc 2> /dev/null || true
        [ -e /dev/cros_fp ] && sudo chmod 0660 /dev/cros_fp 2> /dev/null || true
    fi

    # 3. Prepare crfpmoc build tree
    log_step 3 6 "Preparing crfpmoc libfprint build tree..."
    local crfpmoc_dir="${CRFPMOC_DIR:-}"
    local is_temp_dir=0

    if [ -n "$crfpmoc_dir" ] && [ -d "$crfpmoc_dir" ]; then
        log_info "Using user-specified CRFPMOC_DIR: $crfpmoc_dir"
    elif [ -d "$ROOT_DIR/../crfpmoc" ]; then
        crfpmoc_dir="$(cd "$ROOT_DIR/../crfpmoc" && pwd)"
        log_info "Found sibling repository: $crfpmoc_dir"
    else
        if [ "${DRY_RUN:-0}" = "1" ]; then
            crfpmoc_dir="/tmp/crfpmoc-dryrun"
            log_dryrun "Would clone crfpmoc into secure temporary directory"
        else
            crfpmoc_dir="$(mktemp -d -t crfpmoc-build-XXXXXX)"
            is_temp_dir=1
            log_info "Cloning crfpmoc upstream into secure directory: $crfpmoc_dir..."
            git clone --depth 1 https://github.com/samson1357924/crfpmoc.git "$crfpmoc_dir"
        fi
    fi

    # Sync bundled driver source into the build tree
    if [ -d "$SCRIPT_DIR/driver" ] && [ -d "$crfpmoc_dir/libfprint/drivers/crfpmoc" ] && [ "${DRY_RUN:-0}" != "1" ]; then
        log_info "Syncing local audited driver source files to build tree..."
        cp -f "$SCRIPT_DIR"/driver/crfpmoc* "$crfpmoc_dir/libfprint/drivers/crfpmoc/" 2> /dev/null || true
    fi

    # 4. Build & Install libfprint
    log_step 4 6 "Building and installing libfprint with crfpmoc driver..."
    local meson_libdir="${LIBDIR#/usr/}"
    [ -z "$meson_libdir" ] && meson_libdir="lib"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "meson setup build --prefix=/usr --libdir=$meson_libdir in $crfpmoc_dir"
        log_dryrun "ninja -C build && sudo ninja -C build install"
    else
        cd "$crfpmoc_dir"
        if [ ! -f "build/build.ninja" ]; then
            rm -rf build
            meson setup build --prefix=/usr --libdir="$meson_libdir" \
                -Ddrivers=default -Dintrospection=true \
                -Dgtk-examples=false -Ddoc=false
        else
            meson setup build --reconfigure --prefix=/usr --libdir="$meson_libdir" \
                -Ddrivers=default -Dintrospection=true \
                -Dgtk-examples=false -Ddoc=false
        fi

        ninja -C build

        # Clean any stale /usr/local artifacts
        sudo rm -f /usr/local/lib/*/libfprint-2.so* \
            /usr/local/lib/libfprint-2.so* \
            /usr/local/lib/*/pkgconfig/libfprint-2.pc \
            /usr/local/lib/*/girepository-1.0/FPrint-2.0.typelib \
            /usr/local/share/gir-1.0/FPrint-2.0.gir || true
        sudo rm -rf /usr/local/include/libfprint-2 || true

        # Back up any stock libfprint libraries that ninja install will overwrite,
        # so uninstall can restore them instead of leaving the custom build in place
        while IFS= read -r -d '' lib; do
            backup_file "$lib"
            manifest_add_entry "$lib" "fingerprint" "1"
        done < <(find "$LIBDIR" -maxdepth 1 -name 'libfprint-2.so*' -print0 2> /dev/null)

        sudo ninja -C build install
        sudo ldconfig

        # Record libraries created by this install (no prior stock library
        # existed), so uninstall can remove them
        while IFS= read -r -d '' lib; do
            if ! grep -qF "\"$lib\"" "$MANIFEST_FILE" 2> /dev/null; then
                manifest_add_entry "$lib" "fingerprint" "0"
            fi
        done < <(find "$LIBDIR" -maxdepth 1 -name 'libfprint-2.so*' -print0 2> /dev/null)

        # Clean up temporary build tree if generated
        if [ "$is_temp_dir" = "1" ] && [ -d "$crfpmoc_dir" ]; then
            rm -rf "$crfpmoc_dir"
        fi
    fi

    # 5. Restart fprintd and configure PAM
    log_step 5 6 "Configuring fprintd service & PAM integration..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "systemctl restart fprintd"
        log_dryrun "configure_pam_fingerprint"
    else
        sudo rm -f /etc/systemd/system/fprintd.service.d/cros-fp.conf || true
        sudo systemctl daemon-reload
        sudo systemctl restart fprintd.service 2> /dev/null || sudo systemctl restart fprintd 2> /dev/null || true
        configure_pam_fingerprint
    fi

    # 6. Verification
    log_step 6 6 "Verifying biometric device discovery..."
    if [ "${DRY_RUN:-0}" != "1" ]; then
        fprintd-list "$real_user" || true
    fi

    log_section "Fingerprint setup completed successfully! 🎉"
    echo "To enroll your fingerprint, run:"
    echo "    fprintd-enroll \"$real_user\""
    echo "To verify enrollment, run:"
    echo "    fprintd-verify \"$real_user\""
}

# CLI Argument Parsing
ACTION="install"
while [ $# -gt 0 ]; do
    case "$1" in
        --install | -i)
            ACTION="install"
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
        install_fp
        ;;
    check)
        check_fp_status
        ;;
    uninstall)
        uninstall_fp
        ;;
esac
