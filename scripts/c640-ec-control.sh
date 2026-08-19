#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# scripts/c640-ec-control.sh - ChromeOS EC Control Utility for HP Pro c640 (Dratini)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve lib dir for both layouts:
#   repo/dev:   <repo>/lib
#   installed:  /usr/local/lib/c640-ec (deployed by ec/install-ec.sh)
LIB_DIR=""
for cand in "$ROOT_DIR/lib" "/usr/local/lib/c640-ec"; do
    if [ -f "$cand/logger.sh" ] && [ -f "$cand/syscheck.sh" ]; then
        LIB_DIR="$cand"
        break
    fi
done
if [ -z "$LIB_DIR" ]; then
    echo "c640-ec-control: required libraries (lib/logger.sh, lib/syscheck.sh) not found; re-run ./ec/install-ec.sh" >&2
    exit 1
fi

# shellcheck source=lib/logger.sh
source "$LIB_DIR/logger.sh"
# shellcheck source=lib/syscheck.sh
source "$LIB_DIR/syscheck.sh"

show_help() {
    echo "HP Pro c640 ChromeOS Embedded Controller (EC) Control Utility"
    echo ""
    echo "Usage: $0 [COMMAND] [ARGS...]"
    echo ""
    echo "Commands:"
    echo "  status               Show comprehensive EC dashboard (Battery, Fan, Thermal, Backlight)"
    echo "  battery-limit [PCT]  Set battery charge threshold (e.g. 80 for 75-80% threshold mode)"
    echo "  battery-full         Restore 100% full charging mode"
    echo "  battery-idle         Bypass battery and run strictly on AC power"
    echo "  fan-silent           Set fan to zero-RPM silent mode for quiet typing"
    echo "  fan-auto             Restore automatic EC thermal fan control"
    echo "  fan-speed [RPM]      Set target fan speed in RPM (e.g. 3000)"
    echo "  kblight [PCT]        Set keyboard backlight brightness percentage (0-100)"
    echo "  help                 Show this help message"
}

check_ectool() {
    if ! command -v ectool > /dev/null 2>&1; then
        if [ -x "/usr/local/bin/ectool" ]; then
            ECTOOL_BIN="/usr/local/bin/ectool"
        elif [ "$LIB_DIR" = "$ROOT_DIR/lib" ] && [ -x "$ROOT_DIR/ec/bin/ectool" ]; then
            ECTOOL_BIN="$ROOT_DIR/ec/bin/ectool"
        else
            log_warn "ectool binary not found in PATH."
            log_info "Basic sysfs readings will be used. To enable direct EC controls, run: ./ec/install-ec.sh"
            ECTOOL_BIN=""
            return 1
        fi
    else
        ECTOOL_BIN="ectool"
    fi
    return 0
}

# Run ectool without sudo if /dev/cros_ec is writable via uaccess/plugdev
run_ec() {
    if [ -w "/dev/cros_ec" ]; then
        "$ECTOOL_BIN" "$@"
    else
        sudo "$ECTOOL_BIN" "$@"
    fi
}

show_status() {
    log_section "HP Pro c640 ChromeOS EC Health Dashboard"
    check_dmi_board || true

    log_info "=== Battery Status (/sys/class/power_supply/BAT0) ==="
    if [ -d "/sys/class/power_supply/BAT0" ]; then
        local status capacity health energy_full energy_design
        status=$(cat /sys/class/power_supply/BAT0/status 2> /dev/null || echo "Unknown")
        capacity=$(cat /sys/class/power_supply/BAT0/capacity 2> /dev/null || echo "Unknown")
        energy_full=$(cat /sys/class/power_supply/BAT0/energy_full 2> /dev/null || echo "0")
        energy_design=$(cat /sys/class/power_supply/BAT0/energy_full_design 2> /dev/null || echo "0")

        echo "  - Charge Status: $status ($capacity%)"
        if [ "$energy_design" -gt 0 ]; then
            local health
            (( health = energy_full * 100 / energy_design ))
            echo "  - Battery Health: $health% ($((energy_full / 1000)) mWh / $((energy_design / 1000)) mWh design)"
        fi
    fi

    log_info "=== Thermal & Fan Status ==="
    if check_ectool; then
        local fan_rpm
        fan_rpm=$(run_ec pwmgetfanrpm 2> /dev/null || echo "N/A")
        echo "  - Fan Speed: $fan_rpm"
    else
        echo "  - Direct EC Fan monitoring requires ectool."
    fi

    log_info "=== Keyboard Backlight Status ==="
    if [ -f "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
        local kbd_curr kbd_max
        kbd_curr=$(cat /sys/class/leds/chromeos::kbd_backlight/brightness 2> /dev/null || echo "0")
        kbd_max=$(cat /sys/class/leds/chromeos::kbd_backlight/max_brightness 2> /dev/null || echo "100")
        echo "  - Keyboard Backlight: $kbd_curr / $kbd_max"
    fi
}

set_battery_limit() {
    local pct="${1:-80}"
    if ! [[ "$pct" =~ ^[0-9]+$ ]] || [ "$pct" -lt 20 ] || [ "$pct" -gt 95 ]; then
        log_error "Battery limit must be an integer between 20 and 95 (got: $pct)."
        exit 1
    fi

    local lower=$((pct - 5))
    [ "$lower" -lt 15 ] && lower=15

    log_info "Configuring Battery Charge Threshold: $lower% -> $pct%..."
    if check_ectool; then
        run_ec chargecontrol normal "$lower" "$pct"
        log_success "Battery limit set to $pct% (recharge at $lower%). AC Bypass enabled!"
    else
        log_error "ectool is required to configure ChromeOS EC charge control. Run ./ec/install-ec.sh first."
        exit 1
    fi
}

set_battery_full() {
    log_info "Restoring standard 100% full charging mode..."
    if check_ectool; then
        run_ec chargecontrol normal
        log_success "Battery charge control restored to 100% standard mode."
    fi
}

set_battery_idle() {
    log_info "Switching to pure AC Bypass mode (battery idle)..."
    if check_ectool; then
        run_ec chargecontrol idle
        log_success "Battery charging paused; running strictly on AC power."
    fi
}

set_fan_silent() {
    log_info "Setting fan to zero-RPM silent mode..."
    if check_ectool; then
        run_ec fanduty 0
        log_success "Fan set to 0% duty (Silent Mode). EC thermal safeguards remain active."
    fi
}

set_fan_auto() {
    log_info "Restoring automatic EC thermal fan control..."
    if check_ectool; then
        run_ec autofanctrl
        log_success "Automatic EC fan control restored."
    fi
}

set_fan_speed() {
    local rpm="${1:-3000}"
    log_info "Setting fan target speed to $rpm RPM..."
    if check_ectool; then
        run_ec pwmsetfanrpm "$rpm"
        log_success "Fan target speed set to $rpm RPM."
    fi
}

set_kblight() {
    local pct="${1:-50}"
    if ! [[ "$pct" =~ ^[0-9]+$ ]] || [ "$pct" -lt 0 ] || [ "$pct" -gt 100 ]; then
        log_error "Keyboard backlight must be an integer between 0 and 100 (got: $pct)."
        exit 1
    fi
    if [ -f "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
        local max
        max=$(cat /sys/class/leds/chromeos::kbd_backlight/max_brightness 2> /dev/null || echo "100")
        local val
        (( val = pct * max / 100 ))
        if [ -w "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
            echo "$val" > /sys/class/leds/chromeos::kbd_backlight/brightness
        else
            echo "$val" | sudo tee /sys/class/leds/chromeos::kbd_backlight/brightness > /dev/null
        fi
        log_success "Keyboard backlight set to $pct% ($val/$max)."
    elif check_ectool; then
        run_ec pwmsetkblight "$pct"
        log_success "Keyboard backlight set to $pct% via ectool."
    fi
}

case "${1:-status}" in
    status)
        show_status
        ;;
    battery-limit)
        set_battery_limit "${2:-80}"
        ;;
    battery-full)
        set_battery_full
        ;;
    battery-idle)
        set_battery_idle
        ;;
    fan-silent)
        set_fan_silent
        ;;
    fan-auto)
        set_fan_auto
        ;;
    fan-speed)
        set_fan_speed "${2:-3000}"
        ;;
    kblight)
        set_kblight "${2:-50}"
        ;;
    help | --help | -h)
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
