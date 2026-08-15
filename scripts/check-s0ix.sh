#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# scripts/check-s0ix.sh - Automated S0ix Modern Standby & Package C-State Diagnostics for HP Pro c640
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logger.sh
source "$ROOT_DIR/lib/logger.sh"
# shellcheck source=lib/syscheck.sh
source "$ROOT_DIR/lib/syscheck.sh"

log_section "HP Pro c640 S0ix (s2idle) Modern Standby Diagnostic"
check_dmi_board || true

# 1. Check mem_sleep mode
MEM_SLEEP=$(cat /sys/power/mem_sleep 2> /dev/null || echo "unknown")
log_info "[1/4] Current ACPI Sleep Mode (/sys/power/mem_sleep): $MEM_SLEEP"
if [[ "$MEM_SLEEP" == *"[s2idle]"* ]]; then
    log_success "  [OK] System is set to [s2idle] (S0ix Modern Standby)."
else
    log_warn "  [WARN] Default is not [s2idle]. Set via: echo s2idle | sudo tee /sys/power/mem_sleep"
fi

# 2. Check Intel PMC Core debugfs interface
PMC_DIR="/sys/kernel/debug/pmc_core"
if [ ! -d "$PMC_DIR" ]; then
    sudo mount -t debugfs none /sys/kernel/debug 2> /dev/null || true
fi

log_info "[2/4] Intel PMC Core SLP_S0 Residency Counter:"
if [ -f "$PMC_DIR/slp_s0_residency_usec" ]; then
    CURRENT_SLP=$(sudo cat "$PMC_DIR/slp_s0_residency_usec" 2> /dev/null || echo "0")
    log_success "  Found PMC Core debugfs: Current SLP_S0 residency = ${CURRENT_SLP} µs"
else
    log_warn "  intel_pmc_core debugfs interface not available (debugfs mounted? kernel module loaded?)."
fi

# 3. Check PCIe ASPM & Wi-Fi WoWLAN
log_info "[3/4] PCIe ASPM & Peripheral Power Gating:"
if command -v lspci > /dev/null 2>&1; then
    ASPM_STATUS=$(lspci -vv 2> /dev/null | grep -E "(ASPM.*Enabled|LnkCtl:.*ASPM)" | head -n 4 || true)
    if [ -n "$ASPM_STATUS" ]; then
        echo "$ASPM_STATUS"
    fi
fi

# 4. Optional Standby Stress Test
if [ "${1:-}" = "--test-suspend" ] || [ "${1:-}" = "-t" ]; then
    log_info "[4/4] Executing 10-second S0ix Standby Test (via rtcwake)..."
    if ! command -v rtcwake > /dev/null 2>&1; then
        log_error "rtcwake command not found. Please install util-linux."
        exit 1
    fi

    BEFORE_SLP=0
    [ -f "$PMC_DIR/slp_s0_residency_usec" ] && BEFORE_SLP=$(sudo cat "$PMC_DIR/slp_s0_residency_usec" 2> /dev/null || echo "0")

    log_info "Going to sleep in 3 seconds... System will automatically wake up after 10s."
    sleep 3
    sudo rtcwake -m freeze -s 10
    sleep 2

    if [ -f "$PMC_DIR/slp_s0_residency_usec" ]; then
        AFTER_SLP=$(sudo cat "$PMC_DIR/slp_s0_residency_usec" 2> /dev/null || echo "0")
        DELTA=$((AFTER_SLP - BEFORE_SLP))
        log_info "Post-suspend SLP_S0 Residency: ${AFTER_SLP} µs (Delta: +${DELTA} µs)"
        if [ "$DELTA" -ge 7000000 ]; then
            log_success "🎉 S0ix Test PASSED! System spent >70% time in hardware SLP_S0 state!"
        elif [ "$DELTA" -gt 0 ]; then
            log_warn "⚠️ S0ix Test PARTIAL: SLP_S0 counter increased but residency was low (+${DELTA} µs)."
        else
            log_error "❌ S0ix Test FAILED: SLP_S0 counter did not increase. A peripheral blocked Package C10."
            if [ -f "$PMC_DIR/substate_requirements" ]; then
                log_info "PMC Substate Requirements:"
                sudo cat "$PMC_DIR/substate_requirements" 2> /dev/null || true
            fi
        fi
    fi
else
    log_info "[4/4] S0ix Live Test: pass '--test-suspend' to run a 10s rtcwake sleep test."
fi
