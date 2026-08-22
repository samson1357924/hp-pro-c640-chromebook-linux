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
    echo "  battery-limit [PCT]  Set and evaluate battery charge limit (default: 90, range: 20-95)"
    echo "  battery-eval [PCT]   One-shot evaluation of charge limit (used by sleep hooks)"
    echo "  battery-daemon [PCT] Run charge limit protection daemon loop (used by systemd)"
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
        local status capacity health energy_full energy_design behaviour
        status=$(cat /sys/class/power_supply/BAT0/status 2> /dev/null || echo "Unknown")
        capacity=$(cat /sys/class/power_supply/BAT0/capacity 2> /dev/null || echo "Unknown")
        energy_full=$(cat /sys/class/power_supply/BAT0/energy_full 2> /dev/null || echo "0")
        energy_design=$(cat /sys/class/power_supply/BAT0/energy_full_design 2> /dev/null || echo "0")
        behaviour=$(cat /sys/class/power_supply/BAT0/charge_behaviour 2> /dev/null || echo "N/A")

        echo "  - Charge Status: $status ($capacity%)"
        echo "  - Charge Behaviour: $behaviour"
        [[ "$energy_design" =~ ^[0-9]+$ ]] || energy_design=0
        [[ "$energy_full" =~ ^[0-9]+$ ]] || energy_full=0
        if [ "$energy_design" -gt 0 ]; then
            health=$((energy_full * 100 / energy_design))
            echo "  - Battery Health: $health% ($((energy_full / 1000)) mWh / $((energy_design / 1000)) mWh design)"
        fi
    fi

    log_info "=== Thermal & Fan Status ==="
    if check_ectool; then
        local fan_rpm
        fan_rpm=$(run_ec pwmgetfanrpm 2> /dev/null || echo "N/A")
        echo "  - Fan Speed: $fan_rpm"
        echo "  - Thermal Sensors:"
        run_ec temps all 2> /dev/null | sed 's/^/    /' || true
    else
        echo "  - Direct EC Fan and thermal monitoring requires ectool."
    fi

    log_info "=== Keyboard Backlight Status ==="
    if [ -f "/sys/class/leds/chromeos::kbd_backlight/brightness" ]; then
        local kbd_curr kbd_max
        kbd_curr=$(cat /sys/class/leds/chromeos::kbd_backlight/brightness 2> /dev/null || echo "0")
        kbd_max=$(cat /sys/class/leds/chromeos::kbd_backlight/max_brightness 2> /dev/null || echo "100")
        echo "  - Keyboard Backlight: $kbd_curr / $kbd_max"
    fi
}

set_sysfs_charge_behaviour() {
    local want="$1"
    local bat="/sys/class/power_supply/BAT0"
    if [ -f "$bat/charge_behaviour" ]; then
        local cur active
        cur=$(cat "$bat/charge_behaviour" 2> /dev/null || echo "")
        active=$(echo "$cur" | sed -n 's/.*\[\(.*\)\].*/\1/p')
        [ -z "$active" ] && active=$(echo "$cur" | awk '{print $1}')
        if [ "$active" != "$want" ]; then
            if [ -w "$bat/charge_behaviour" ]; then
                echo "$want" > "$bat/charge_behaviour" 2> /dev/null || true
            else
                echo "$want" | sudo tee "$bat/charge_behaviour" > /dev/null 2>&1 || true
            fi
        fi
    fi
}

eval_battery_limit() {
    local pct="${1:-90}"
    if ! [[ "$pct" =~ ^[0-9]+$ ]] || [ "$pct" -lt 20 ] || [ "$pct" -gt 95 ]; then
        log_error "Battery limit must be an integer between 20 and 95 (got: $pct)."
        exit 1
    fi

    local online="0"
    for ac_path in /sys/class/power_supply/AC /sys/class/power_supply/ADP1 /sys/class/power_supply/ACAD; do
        if [ -f "$ac_path/online" ]; then
            online=$(cat "$ac_path/online" 2> /dev/null || echo "0")
            break
        fi
    done

    local cap
    cap=$(cat /sys/class/power_supply/BAT0/capacity 2> /dev/null || echo "0")
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
    [[ "$online" =~ ^[0-9]+$ ]] || online=0

    if [ "$online" = "1" ]; then
        if [ "$cap" -ge "$pct" ]; then
            # Target reached/exceeded: switch to AC bypass (stop charging)
            set_sysfs_charge_behaviour "inhibit-charge"
            if check_ectool 2> /dev/null; then
                run_ec chargecontrol idle > /dev/null 2>&1 || true
            fi
        else
            # Below target: charge normally
            set_sysfs_charge_behaviour "auto"
            if check_ectool 2> /dev/null; then
                run_ec chargecontrol normal > /dev/null 2>&1 || true
            fi
        fi
    else
        # Unplugged: reset to auto/normal so it's ready when AC is reconnected
        set_sysfs_charge_behaviour "auto"
        if check_ectool 2> /dev/null; then
            run_ec chargecontrol normal > /dev/null 2>&1 || true
        fi
    fi
}

daemon_battery_limit() {
    local pct="${1:-90}"
    if ! [[ "$pct" =~ ^[0-9]+$ ]] || [ "$pct" -lt 20 ] || [ "$pct" -gt 95 ]; then
        log_error "Battery limit must be an integer between 20 and 95 (got: $pct)."
        exit 1
    fi

    cleanup_daemon() {
        log_info "Stopping battery daemon; restoring normal charging..."
        set_battery_full
        exit 0
    }
    trap cleanup_daemon SIGTERM SIGINT

    log_info "Starting c640 battery protection daemon (Limit: $pct%)..."
    while true; do
        eval_battery_limit "$pct" || true
        sleep 30
    done
}

set_battery_limit() {
    local pct="${1:-90}"
    if ! [[ "$pct" =~ ^[0-9]+$ ]] || [ "$pct" -lt 20 ] || [ "$pct" -gt 95 ]; then
        log_error "Battery limit must be an integer between 20 and 95 (got: $pct)."
        exit 1
    fi

    log_info "Evaluating and applying battery limit ($pct%)..."
    eval_battery_limit "$pct"
    log_success "Battery limit set to $pct%. AC Bypass active when capacity >= $pct%."
}

set_battery_full() {
    log_info "Restoring standard 100% full charging mode..."
    set_sysfs_charge_behaviour "auto"
    if check_ectool 2> /dev/null; then
        run_ec chargecontrol normal 2> /dev/null || true
    fi
    log_success "Battery charge control restored to 100% standard mode."
}

set_battery_idle() {
    log_info "Switching to pure AC Bypass mode (battery idle)..."
    set_sysfs_charge_behaviour "inhibit-charge"
    if check_ectool 2> /dev/null; then
        run_ec chargecontrol idle 2> /dev/null || true
    fi
    log_success "Battery charging paused; running strictly on AC power."
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
    if ! [[ "$rpm" =~ ^[1-9][0-9]*$ ]]; then
        log_error "Fan speed must be a positive integer (got: $rpm)."
        exit 1
    fi
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
        val=$((pct * max / 100))
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
        set_battery_limit "${2:-90}"
        ;;
    battery-eval)
        eval_battery_limit "${2:-90}"
        ;;
    battery-daemon)
        daemon_battery_limit "${2:-90}"
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
