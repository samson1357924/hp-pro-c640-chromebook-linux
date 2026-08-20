#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# fingerprint/install-fingerprint.sh - Cross-Distro Fingerprint Driver (crfpmoc) Installer & Manager
# Supports Hybrid A+C Architecture: Fast Prebuilt Packages with Automatic Source Build Fallback
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

PKG_VERSION="${PKG_VERSION:-1.94.10}"
RELEASE_REPO="${RELEASE_REPO:-samson1357924/hp-pro-c640-chromebook-linux}"
RELEASE_TAG="${RELEASE_TAG:-latest}"
INSTALL_MODE="auto" # "auto" (Hybrid), "source" (Plan A), "prebuilt" (Plan C)

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --install, -i           Install crfpmoc driver (Hybrid: prebuilt package with source fallback)"
    echo "  --source, --build       Force building from source (Plan A: pinned commit + driver overlay)"
    echo "  --prebuilt, --pkg       Force installing prebuilt package only (Plan C)"
    echo "  --release-tag <TAG>     GitHub Release tag to fetch prebuilt packages from (default: latest)"
    echo "  --release-repo <REPO>   GitHub repository for releases (default: samson1357924/hp-pro-c640-chromebook-linux)"
    echo "  --check, -c             Check fingerprint hardware, node, and driver status"
    echo "  --uninstall, -u         Uninstall custom libfprint driver & restore system package"
    echo "  --dry-run, -n           Preview steps without executing commands"
    echo "  --help, -h              Show this help message"
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
    # The encryption seed is created at driver runtime (first device open),
    # not at install time, so it can only be cleaned up on uninstall.
    if [ -f /var/lib/fprint/crfpmoc.key ]; then
        manifest_add_entry /var/lib/fprint/crfpmoc.key "fingerprint" "0"
        log_warn "Will remove /var/lib/fprint/crfpmoc.key (enrolled prints must be re-enrolled after reinstall)"
    fi
    rollback_component "fingerprint"
    remove_group_membership "plugdev" "$(get_real_user)" "fingerprint"

    # Remove prebuilt package if installed via package manager
    if [ "${DRY_RUN:-0}" != "1" ]; then
        case "$DISTRO_FAMILY" in
            debian)
                if dpkg -s libfprint-crfpmoc > /dev/null 2>&1; then
                    log_info "Removing libfprint-crfpmoc package via apt..."
                    sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y libfprint-crfpmoc || true
                fi
                ;;
            fedora)
                if rpm -q libfprint-crfpmoc > /dev/null 2>&1; then
                    log_info "Removing libfprint-crfpmoc package via dnf..."
                    sudo dnf remove -y libfprint-crfpmoc || true
                fi
                ;;
            arch)
                if pacman -Q libfprint-crfpmoc > /dev/null 2>&1; then
                    log_info "Removing libfprint-crfpmoc package via pacman..."
                    sudo pacman -R --noconfirm libfprint-crfpmoc || true
                fi
                ;;
            suse)
                if rpm -q libfprint-crfpmoc > /dev/null 2>&1; then
                    log_info "Removing libfprint-crfpmoc package via zypper..."
                    sudo zypper --non-interactive remove -y libfprint-crfpmoc || true
                fi
                ;;
        esac

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
    else
        log_dryrun "Remove package libfprint-crfpmoc if present"
        log_dryrun "udevadm control --reload-rules"
        log_dryrun "disable_pam_fingerprint"
        log_dryrun "ldconfig"
        log_dryrun "Reinstall stock libfprint package via your distribution's package manager"
    fi
    log_success "Fingerprint driver uninstallation finished."
}

configure_udev_and_sleep_hook() {
    local real_user
    real_user="$(get_real_user)"

    # Configure udev device permissions & user group
    log_info "Configuring udev permissions for /dev/cros_fp..."
    local udev_rule_dst="/etc/udev/rules.d/60-cros-fp.rules"
    backup_file_manifest_aware "$udev_rule_dst" "fingerprint"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install 60-cros-fp.rules to $udev_rule_dst"
        log_dryrun "Add user '$real_user' to group plugdev"
    else
        sudo install -D -m 0644 "$SCRIPT_DIR/60-cros-fp.rules" "$udev_rule_dst"

        # Ensure plugdev group exists and add user
        if ! getent group plugdev > /dev/null 2>&1; then
            sudo groupadd plugdev 2> /dev/null || true
        fi
        if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
            if id -u "$real_user" > /dev/null 2>&1; then
                local was_member=0
                id -nG "$real_user" 2> /dev/null | tr ' ' '\n' | grep -qx "plugdev" && was_member=1
                sudo usermod -aG plugdev "$real_user" || true
                manifest_add_group "plugdev" "$real_user" "fingerprint" "$was_member"
                log_success "Added user '$real_user' to 'plugdev' group."
            else
                log_warn "User '$real_user' does not exist; skipping plugdev membership."
            fi
        fi

        sudo udevadm control --reload-rules 2> /dev/null || true
        sudo udevadm trigger --subsystem-match=misc 2> /dev/null || true
        [ -e /dev/cros_fp ] && sudo chmod 0660 /dev/cros_fp 2> /dev/null || true
    fi

    # Install system-sleep hook: stop fprintd before sleep so the first
    # unlock after resume gets a fresh daemon and a fully re-initialized
    # FPMCU (see docs/TROUBLESHOOTING.md §13 / gnome-shell#7791).
    local sleep_hook_dst="/usr/lib/systemd/system-sleep/fprintd-sleep.sh"
    backup_file_manifest_aware "$sleep_hook_dst" "fingerprint"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install $SCRIPT_DIR/systemd/fprintd-sleep.sh -> $sleep_hook_dst"
    else
        sudo install -D -m 0755 "$SCRIPT_DIR/systemd/fprintd-sleep.sh" "$sleep_hook_dst"
        log_success "Installed fprintd system-sleep hook."
    fi
}

configure_service_and_pam() {
    local real_user
    real_user="$(get_real_user)"

    log_info "Configuring fprintd service & PAM integration..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "systemctl restart fprintd"
        log_dryrun "configure_pam_fingerprint"
        log_dryrun "fprintd-list $real_user"
    else
        # NOTE: deliberately do NOT create any fprintd.service.d drop-in.
        # The device-claim race on unlock (GNOME/gdm#1071) is fixed at the
        # PAM layer by configure_pam_fingerprint (fprintd out of common-auth,
        # fingerprint in sudo only) — see docs/TROUBLESHOOTING.md §13.
        sudo systemctl daemon-reload
        sudo systemctl restart fprintd.service 2> /dev/null || sudo systemctl restart fprintd 2> /dev/null || true
        configure_pam_fingerprint
        fprintd-list "$real_user" || true
    fi
}

try_install_prebuilt_package() {
    log_info "Checking for prebuilt package for $DISTRO_FAMILY ($DISTRO_NAME)..."
    local arch_name
    arch_name="$(uname -m)"
    if [ "$arch_name" != "x86_64" ]; then
        log_warn "Architecture '$arch_name' is not x86_64; skipping prebuilt package."
        return 1
    fi

    local pkg_file=""
    local pkg_type=""

    # 1. Search local directories first
    local search_dirs=("$SCRIPT_DIR/packages" "$SCRIPT_DIR/packaging/output" "$ROOT_DIR/packages" "$PWD")
    case "$DISTRO_FAMILY" in
        debian)
            for d in "${search_dirs[@]}"; do
                local match
                match="$(find "$d" -maxdepth 1 -name "libfprint-crfpmoc_*_amd64.deb" 2> /dev/null | head -n 1 || true)"
                if [ -n "$match" ] && [ -f "$match" ]; then
                    pkg_file="$match"
                    pkg_type="deb"
                    log_info "Found local Debian package: $pkg_file"
                    break
                fi
            done
            ;;
        fedora | suse)
            for d in "${search_dirs[@]}"; do
                local match
                match="$(find "$d" -maxdepth 1 -name "libfprint-crfpmoc-*.x86_64.rpm" 2> /dev/null | head -n 1 || true)"
                if [ -n "$match" ] && [ -f "$match" ]; then
                    pkg_file="$match"
                    pkg_type="rpm"
                    log_info "Found local RPM package: $pkg_file"
                    break
                fi
            done
            ;;
        arch)
            for d in "${search_dirs[@]}"; do
                local match
                match="$(find "$d" -maxdepth 1 -name "libfprint-crfpmoc-*-x86_64.pkg.tar.*" 2> /dev/null | head -n 1 || true)"
                if [ -n "$match" ] && [ -f "$match" ]; then
                    pkg_file="$match"
                    pkg_type="arch"
                    log_info "Found local Arch package: $pkg_file"
                    break
                fi
            done
            ;;
    esac

    # 2. If no local package found, try downloading from GitHub Releases
    if [ -z "$pkg_file" ]; then
        local release_base_url
        if [ "$RELEASE_TAG" = "latest" ]; then
            release_base_url="https://github.com/${RELEASE_REPO}/releases/latest/download"
        else
            release_base_url="https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}"
        fi

        local remote_filename=""
        case "$DISTRO_FAMILY" in
            debian)
                remote_filename="libfprint-crfpmoc_${PKG_VERSION}-1_amd64.deb"
                pkg_type="deb"
                ;;
            fedora | suse)
                remote_filename="libfprint-crfpmoc-${PKG_VERSION}-1.x86_64.rpm"
                pkg_type="rpm"
                ;;
            arch)
                remote_filename="libfprint-crfpmoc-${PKG_VERSION}-1-x86_64.pkg.tar.zst"
                pkg_type="arch"
                ;;
            *)
                log_info "No official prebuilt package format for distro family '$DISTRO_FAMILY'."
                return 1
                ;;
        esac

        local download_url="${release_base_url}/${remote_filename}"
        local tmp_download_dir
        tmp_download_dir="$(mktemp -d -t crfpmoc-pkg-XXXXXX)"
        local tmp_target="${tmp_download_dir}/${remote_filename}"

        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Would attempt download from $download_url -> $tmp_target"
            pkg_file="$tmp_target"
        else
            log_info "Downloading prebuilt package: $remote_filename ..."
            local download_ok=0
            if command -v curl > /dev/null 2>&1; then
                if curl -sSL -f -o "$tmp_target" "$download_url" 2> /dev/null; then
                    download_ok=1
                fi
            elif command -v wget > /dev/null 2>&1; then
                if wget -q -O "$tmp_target" "$download_url" 2> /dev/null; then
                    download_ok=1
                fi
            fi

            if [ "$download_ok" = "1" ] && [ -s "$tmp_target" ]; then
                log_success "Downloaded prebuilt package: $remote_filename"
                pkg_file="$tmp_target"
            else
                log_info "Prebuilt package not available from GitHub Releases (HTTP 404 or network unavailable)."
                rm -rf "$tmp_download_dir"
                return 1
            fi
        fi
    fi

    # 3. Install runtime dependencies
    log_info "Installing runtime dependencies for $DISTRO_FAMILY..."
    read -r -a runtime_deps <<< "$(get_fingerprint_runtime_deps)"
    install_packages "${runtime_deps[@]}"

    # 4. Install native package
    log_info "Installing package ($pkg_type): $pkg_file..."
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Install prebuilt package ($pkg_type): $pkg_file"
    else
        case "$pkg_type" in
            deb)
                sudo dpkg -i "$pkg_file" || {
                    log_info "Resolving deb dependencies with apt-get..."
                    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -f -y
                }
                manifest_add_entry "package:libfprint-crfpmoc" "fingerprint" "0"
                ;;
            rpm)
                if [ "$DISTRO_FAMILY" = "fedora" ]; then
                    sudo dnf install -y "$pkg_file"
                else
                    sudo zypper --non-interactive install --allow-unsigned-rpm "$pkg_file"
                fi
                manifest_add_entry "package:libfprint-crfpmoc" "fingerprint" "0"
                ;;
            arch)
                sudo pacman -U --noconfirm --overwrite='*' "$pkg_file"
                manifest_add_entry "package:libfprint-crfpmoc" "fingerprint" "0"
                ;;
        esac

        if [ -n "${tmp_download_dir:-}" ] && [ -d "$tmp_download_dir" ]; then
            rm -rf "$tmp_download_dir"
        fi
    fi

    return 0
}

install_fp_from_source() {
    log_section "Compiling crfpmoc libfprint from Source (Plan A)"

    # 1. Install build dependencies
    log_step 1 4 "Installing compilation tools and dependencies for $DISTRO_FAMILY..."
    read -r -a build_deps <<< "$(get_fingerprint_build_deps)"
    install_packages "${build_deps[@]}"

    # 2. Prepare crfpmoc build tree
    log_step 2 4 "Preparing crfpmoc libfprint build tree..."
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
            log_dryrun "Would clone 3v1n0/libfprint (feature/crfpmoc) into secure temporary directory"
        else
            crfpmoc_dir="$(mktemp -d -t crfpmoc-build-XXXXXX)"
            is_temp_dir=1
            log_info "Cloning crfpmoc libfprint (pinned 3v1n0/libfprint feature/crfpmoc @ 5644259) into secure directory: $crfpmoc_dir..."
            git clone --depth 1 --branch feature/crfpmoc --single-branch https://gitlab.freedesktop.org/3v1n0/libfprint.git "$crfpmoc_dir"
            git -C "$crfpmoc_dir" fetch --depth 1 origin 56442591a5c302a906289f30988fb50fc3d82ed6 || {
                log_error "Failed to fetch pinned commit 56442591a5c302a906289f30988fb50fc3d82ed6 of 3v1n0/libfprint (feature/crfpmoc)."
                log_info "The pinned commit may have been rewritten upstream; verify against https://gitlab.freedesktop.org/3v1n0/libfprint."
                exit 1
            }
            git -C "$crfpmoc_dir" checkout --detach FETCH_HEAD
        fi
    fi

    # Sync bundled driver source into the build tree
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Sync $SCRIPT_DIR/driver/* -> $crfpmoc_dir/libfprint/drivers/crfpmoc/"
        log_dryrun "Patch meson.build: add crfpmoc-proto.c to crfpmoc sources (if not already listed)"
    elif [ -d "$SCRIPT_DIR/driver" ] && [ -d "$crfpmoc_dir/libfprint/drivers/crfpmoc" ]; then
        log_info "Syncing local audited driver source files to build tree..."
        cp -f "$SCRIPT_DIR"/driver/crfpmoc* "$crfpmoc_dir/libfprint/drivers/crfpmoc/" 2> /dev/null || true

        # Upstream meson.build only lists crfpmoc.c + crfpmoc-ec-transfer.c;
        # the audited driver also ships crfpmoc-proto.c (pure protocol
        # parsing, used by crfpmoc.c) — add it to the source list idempotently.
        local meson_build="$crfpmoc_dir/libfprint/meson.build"
        if [ -f "$SCRIPT_DIR/driver/crfpmoc-proto.c" ] && [ -f "$meson_build" ] \
            && ! grep -q "drivers/crfpmoc/crfpmoc-proto.c" "$meson_build"; then
            log_info "Adding crfpmoc-proto.c to libfprint meson.build..."
            sed -i "s|'drivers/crfpmoc/crfpmoc-ec-transfer.c',|'drivers/crfpmoc/crfpmoc-ec-transfer.c',\n        'drivers/crfpmoc/crfpmoc-proto.c',|" "$meson_build"
        fi
    fi

    # 3. Build & Install libfprint
    log_step 3 4 "Building and installing libfprint with crfpmoc driver..."
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

        # Back up every file that ninja install will write (libraries with
        # soname symlinks, pkgconfig, GIR/typelib, headers, metainfo, udev
        # rules) from meson's install plan, so uninstall can restore or
        # remove all of them — not just libfprint-2.so*.
        backup_meson_install_plan "$crfpmoc_dir/build" "fingerprint"

        sudo ninja -C build install
        sudo ldconfig

        # Clean up temporary build tree if generated
        if [ "$is_temp_dir" = "1" ] && [ -d "$crfpmoc_dir" ]; then
            rm -rf "$crfpmoc_dir"
        fi
    fi
}

install_fp() {
    log_section "Installing crfpmoc Fingerprint Driver for HP Pro c640 ($DISTRO_NAME)"

    # 0. Preflight checks
    check_dmi_board || true
    if ! check_cros_fp_device; then
        if [ "${DRY_RUN:-0}" != "1" ]; then
            log_error "Preflight failed: /dev/cros_fp not found. Aborting install (run --check for details)."
            return 1
        fi
    fi

    # Configure udev & sleep hook first
    configure_udev_and_sleep_hook

    # Select installation path (Hybrid A+C)
    local installed_ok=0
    if [ "$INSTALL_MODE" = "prebuilt" ]; then
        if try_install_prebuilt_package; then
            installed_ok=1
        else
            log_error "Prebuilt package installation requested, but no matching package could be installed."
            return 1
        fi
    elif [ "$INSTALL_MODE" = "source" ]; then
        install_fp_from_source
        installed_ok=1
    else
        # "auto" (Hybrid): try prebuilt package first, fallback to source
        if try_install_prebuilt_package; then
            log_success "Prebuilt package installed successfully! (Plan C)"
            installed_ok=1
        else
            log_info "No prebuilt package available or download failed; falling back to source compilation (Plan A)..."
            install_fp_from_source
            installed_ok=1
        fi
    fi

    if [ "$installed_ok" != "1" ]; then
        log_error "Failed to install crfpmoc driver."
        return 1
    fi

    # Configure PAM & restart fprintd service
    configure_service_and_pam

    local real_user
    real_user="$(get_real_user)"
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
        --source | --build | --build-from-source)
            ACTION="install"
            INSTALL_MODE="source"
            shift
            ;;
        --prebuilt | --pkg)
            ACTION="install"
            INSTALL_MODE="prebuilt"
            shift
            ;;
        --release-tag)
            RELEASE_TAG="$2"
            shift 2
            ;;
        --release-repo)
            RELEASE_REPO="$2"
            shift 2
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
