#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lib/distro.sh - Linux Distribution Detection & Package Management Abstraction

if [ -n "${_LIB_DISTRO_SH_LOADED:-}" ]; then
    return 0
fi
_LIB_DISTRO_SH_LOADED=1

SCRIPT_DIR_DISTRO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logger.sh
source "$SCRIPT_DIR_DISTRO/logger.sh"

export DISTRO_ID=""
export DISTRO_LIKE=""
export DISTRO_FAMILY=""
export DISTRO_NAME=""
export DISTRO_VERSION=""
export LIBDIR=""

detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_LIKE="${ID_LIKE:-$DISTRO_ID}"
        DISTRO_NAME="${PRETTY_NAME:-$NAME}"
        DISTRO_VERSION="${VERSION_ID:-}"
    elif [ -f /etc/redhat-release ]; then
        DISTRO_ID="rhel"
        DISTRO_LIKE="fedora"
        DISTRO_NAME="$(cat /etc/redhat-release)"
    elif [ -f /etc/debian_version ]; then
        DISTRO_ID="debian"
        DISTRO_LIKE="debian"
        DISTRO_NAME="Debian $(cat /etc/debian_version)"
    else
        DISTRO_ID="unknown"
        DISTRO_LIKE="unknown"
        DISTRO_NAME="Generic Linux"
    fi

    # Classify into standard distro families
    case "$DISTRO_ID" in
        ubuntu | debian | linuxmint | pop | elementary | zorin | kali | neon)
            DISTRO_FAMILY="debian"
            ;;
        fedora | rhel | centos | rocky | almalinux | nobara)
            DISTRO_FAMILY="fedora"
            ;;
        arch | endeavouros | manjaro | cachyos | garuda | artix)
            DISTRO_FAMILY="arch"
            ;;
        opensuse* | suse | tumbleweed | leap)
            DISTRO_FAMILY="suse"
            ;;
        nixos)
            DISTRO_FAMILY="nixos"
            ;;
        *)
            case "$DISTRO_LIKE" in
                *debian* | *ubuntu*) DISTRO_FAMILY="debian" ;;
                *fedora* | *rhel*) DISTRO_FAMILY="fedora" ;;
                *arch*) DISTRO_FAMILY="arch" ;;
                *suse*) DISTRO_FAMILY="suse" ;;
                *) DISTRO_FAMILY="unsupported" ;;
            esac
            ;;
    esac

    # Determine multiarch library directory
    if [ "$DISTRO_FAMILY" = "debian" ] && command -v dpkg-architecture > /dev/null 2>&1; then
        local deb_multiarch
        deb_multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2> /dev/null || true)"
        if [ -n "$deb_multiarch" ] && [ -d "/usr/lib/$deb_multiarch" ]; then
            LIBDIR="/usr/lib/$deb_multiarch"
        elif [ -d "/usr/lib/x86_64-linux-gnu" ]; then
            LIBDIR="/usr/lib/x86_64-linux-gnu"
        else
            LIBDIR="/usr/lib"
        fi
    elif [ "$DISTRO_FAMILY" = "arch" ]; then
        LIBDIR="/usr/lib"
    elif [ -d "/usr/lib64" ]; then
        LIBDIR="/usr/lib64"
    else
        LIBDIR="/usr/lib"
    fi
}

# Run detection once
detect_distro

# Install packages with abstract package manager
install_packages() {
    local pkgs=("$@")
    [ ${#pkgs[@]} -eq 0 ] && return 0

    log_info "Target packages to install: ${pkgs[*]}"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dryrun "Package install command skipped (${DISTRO_FAMILY}): ${pkgs[*]}"
        return 0
    fi

    case "$DISTRO_FAMILY" in
        debian)
            sudo env DEBIAN_FRONTEND=noninteractive apt-get update -y
            sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
            ;;
        fedora)
            sudo dnf install -y "${pkgs[@]}"
            ;;
        arch)
            sudo pacman -S --needed --noconfirm "${pkgs[@]}"
            ;;
        suse)
            sudo zypper --non-interactive install --no-recommends "${pkgs[@]}"
            ;;
        nixos)
            log_warn "NixOS is a declarative distribution. Please add packages to your configuration.nix / home-manager:"
            log_warn "Packages: ${pkgs[*]}"
            ;;
        *)
            log_error "Unsupported distribution family: $DISTRO_FAMILY. Please install dependencies manually: ${pkgs[*]}"
            return 1
            ;;
    esac
}

# Return distro-specific dependencies for building libfprint / crfpmoc
get_fingerprint_build_deps() {
    case "$DISTRO_FAMILY" in
        debian)
            # libudev-dev provides udev.pc, which meson requires to resolve
            # the udevdir (the crfpmoc build uses the 'udev' helper); it is
            # also pulled in transitively via libgudev-1.0-dev. git +
            # ca-certificates are needed for the pinned upstream clone.
            echo "build-essential git ca-certificates meson ninja-build pkg-config libglib2.0-dev libgusb-dev libpixman-1-dev libgudev-1.0-dev libudev-dev libjson-glib-dev libgirepository1.0-dev gobject-introspection fprintd libpam-fprintd"
            ;;
        fedora)
            echo "gcc git ca-certificates meson ninja-build pkgconf-pkg-config glib2-devel libgusb-devel pixman-devel libgudev-devel json-glib-devel gobject-introspection-devel fprintd fprintd-pam"
            ;;
        arch)
            echo "base-devel git meson ninja pkgconf glib2 libgusb pixman libgudev json-glib gobject-introspection fprintd"
            ;;
        suse)
            echo "patterns-devel-base-devel_basis git meson ninja pkg-config glib2-devel libgusb-devel libpixman-1-0-devel libgudev-1_0-devel json-glib-devel gobject-introspection-devel fprintd fprintd-pam"
            ;;
        *)
            echo "meson ninja gcc git pkg-config glib2 libgusb pixman libgudev fprintd"
            ;;
    esac
}

# Return distro-specific runtime dependencies for libfprint / crfpmoc
get_fingerprint_runtime_deps() {
    case "$DISTRO_FAMILY" in
        debian)
            echo "fprintd libpam-fprintd curl ca-certificates"
            ;;
        fedora)
            echo "fprintd fprintd-pam curl ca-certificates"
            ;;
        arch)
            echo "fprintd curl ca-certificates"
            ;;
        suse)
            echo "fprintd fprintd-pam curl ca-certificates"
            ;;
        *)
            echo "fprintd curl ca-certificates"
            ;;
    esac
}

# Return user session UID and username
get_real_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
    else
        echo "${USER:-$(id -un)}"
    fi
}

get_real_user_uid() {
    local u
    u="$(get_real_user)"
    id -u "$u" 2> /dev/null || echo "1000"
}
