#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# power/install-power.sh - Power Management & Modern Standby (S0ix) Optimizer for HP Pro c640
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

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --install, -i      Install power optimization profiles & quirks (default)"
    echo "  --check, -c        Check power management status, mem_sleep & ASPM"
    echo "  --uninstall, -u    Uninstall power management profiles & restore defaults"
    echo "  --dry-run, -n      Preview changes without modifying the system"
    echo "  --help, -h         Show this help message"
}

check_power_status() {
    log_section "HP Pro c640 Power Management & Modern Standby Status"
    check_dmi_board || true

    local mem_sleep
    mem_sleep=$(cat /sys/power/mem_sleep 2> /dev/null || echo "unknown")
    log_info "Supported mem_sleep modes: $mem_sleep"
    local mem_sleep_default="${mem_sleep##*[}"
    mem_sleep_default="${mem_sleep_default%]*}"
    if [[ "$mem_sleep" == *"s2idle"* ]]; then
        log_success "  S0ix Modern Standby (s2idle) is available (default: $mem_sleep_default)."
    else
        log_warn "  S0ix (s2idle) is not advertised by /sys/power/mem_sleep; check firmware settings."
    fi

    log_info "PCIe ASPM Policy:"
    local aspm_policy
    aspm_policy=$(cat /sys/module/pcie_aspm/parameters/policy 2> /dev/null || echo "unknown")
    log_info "  Current ASPM Policy: $aspm_policy"

    log_info "Active Power Management Daemons:"
    if systemctl is-active --quiet thermald 2> /dev/null; then
        log_success "  thermald is active (Intel Thermal Management)."
    else
        log_warn "  thermald is not running. Consider installing thermald."
    fi

    if systemctl is-active --quiet tlp 2> /dev/null; then
        log_success "  tlp is active."
    fi
}

uninstall_power() {
    log_section "Uninstalling Power Optimization Profiles"
    rollback_component "power"

    if [ "${DRY_RUN:-0}" != "1" ]; then
        sudo rm -f /etc/tlp.d/99-hp-c640.conf
        sudo rm -f /etc/modprobe.d/99-hp-c640-power.conf
        sudo rm -f /etc/systemd/logind.conf.d/99-hp-c640-lid.conf
        sudo rm -f /etc/wireplumber/wireplumber.conf.d/50-disable-suspend.conf

        sudo systemctl restart systemd-logind 2> /dev/null || true
    fi
    log_success "Power optimization profiles removed."
}

install_power() {
    log_section "Installing Power & S0ix Optimizations for HP Pro c640 ($DISTRO_NAME)"

    # Preflight check
    check_dmi_board || true

    # 1. Install thermald & TLP if supported
    log_step 1 4 "Checking power management packages for $DISTRO_FAMILY..."
    case "$DISTRO_FAMILY" in
        debian)
            install_packages thermald tlp
            ;;
        fedora)
            install_packages thermald tlp
            ;;
        arch)
            install_packages thermald tlp
            ;;
        suse)
            install_packages thermald tlp
            ;;
        *)
            log_info "Please ensure thermald and tlp are installed."
            ;;
    esac

    # 2. Deploy TLP configuration
    log_step 2 4 "Deploying Comet Lake TLP profile..."
    local tlp_dst="/etc/tlp.d/99-hp-c640.conf"
    local tlp_src="$SCRIPT_DIR/tlp/99-hp-c640.conf"
    if [ -f "$tlp_src" ]; then
        backup_file "$tlp_dst"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Install -D -m 0644 $tlp_src -> $tlp_dst"
        else
            sudo mkdir -p /etc/tlp.d
            sudo install -D -m 0644 "$tlp_src" "$tlp_dst"
            manifest_add_entry "$tlp_dst" "power" "0"
            log_success "Deployed $tlp_dst"
        fi
    fi

    # 3. Deploy i915 / iwlwifi modprobe quirks
    log_step 3 4 "Deploying GPU & Wi-Fi power quirks (anti-blackscreen & ASPM)..."
    local modprobe_dst="/etc/modprobe.d/99-hp-c640-power.conf"
    local modprobe_src="$SCRIPT_DIR/modprobe.d/99-hp-c640-power.conf"
    if [ -f "$modprobe_src" ]; then
        backup_file "$modprobe_dst"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Install -D -m 0644 $modprobe_src -> $modprobe_dst"
        else
            sudo install -D -m 0644 "$modprobe_src" "$modprobe_dst"
            manifest_add_entry "$modprobe_dst" "power" "0"
            log_success "Deployed $modprobe_dst"
        fi
    fi

    # Deploy logind lid switch rule
    local logind_dst="/etc/systemd/logind.conf.d/99-hp-c640-lid.conf"
    local logind_src="$SCRIPT_DIR/systemd/logind.conf.d/99-hp-c640-lid.conf"
    if [ -f "$logind_src" ]; then
        backup_file "$logind_dst"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Install -D -m 0644 $logind_src -> $logind_dst"
        else
            sudo mkdir -p /etc/systemd/logind.conf.d
            sudo install -D -m 0644 "$logind_src" "$logind_dst"
            manifest_add_entry "$logind_dst" "power" "0"
            log_success "Deployed $logind_dst"
        fi
    fi

    # 4. Deploy WirePlumber anti-pop configuration
    log_step 4 4 "Deploying WirePlumber anti-pop rule..."
    local wp_dst="/etc/wireplumber/wireplumber.conf.d/50-disable-suspend.conf"
    local wp_src="$SCRIPT_DIR/wireplumber/50-disable-suspend.conf"
    if [ -f "$wp_src" ]; then
        backup_file "$wp_dst"
        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dryrun "Install -D -m 0644 $wp_src -> $wp_dst"
        else
            sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
            sudo install -D -m 0644 "$wp_src" "$wp_dst"
            manifest_add_entry "$wp_dst" "power" "0"
            log_success "Deployed $wp_dst"
        fi
    fi

    if [ "${DRY_RUN:-0}" != "1" ]; then
        sudo systemctl enable --now thermald 2> /dev/null || true
        sudo systemctl enable --now tlp 2> /dev/null || true
    fi

    log_section "Power optimizations installed successfully! ⚡"
    echo "To test your S0ix Modern Standby health, run:"
    echo "    ./scripts/check-s0ix.sh"
}

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
        install_power
        ;;
    check)
        check_power_status
        ;;
    uninstall)
        uninstall_power
        ;;
esac
