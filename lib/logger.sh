#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lib/logger.sh - Structured Terminal & File Logger for HP Pro c640 Linux Enablement

# Avoid multiple inclusions
if [ -n "${_LIB_LOGGER_SH_LOADED:-}" ]; then
    return 0
fi
_LIB_LOGGER_SH_LOADED=1

LOG_FILE="${LOG_FILE:-/tmp/cros-linux-setup.log}"

# Color codes
CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_RED="\033[1;31m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"

_log_write() {
    local level="$1"
    local color="$2"
    local symbol="$3"
    shift 3
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Terminal output
    echo -e "${color}${CLR_BOLD}[${symbol}]${CLR_RESET} ${msg}" >&2

    # File output (strip ANSI colors)
    if [ -n "$LOG_FILE" ]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log_info() {
    _log_write "INFO" "$CLR_BLUE" "INFO" "$*"
}

log_success() {
    _log_write "SUCCESS" "$CLR_GREEN" "OK" "$*"
}

log_warn() {
    _log_write "WARN" "$CLR_YELLOW" "WARN" "$*"
}

log_error() {
    _log_write "ERROR" "$CLR_RED" "FAIL" "$*"
}

log_dryrun() {
    _log_write "DRY-RUN" "$CLR_MAGENTA" "DRY-RUN" "$*"
}

log_step() {
    local step_num="$1"
    local total_steps="$2"
    shift 2
    echo -e "\n${CLR_CYAN}${CLR_BOLD}===> [${step_num}/${total_steps}] ${*}${CLR_RESET}" >&2
    if [ -n "$LOG_FILE" ]; then
        echo -e "\n=== [${step_num}/${total_steps}] ${*} ===" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log_section() {
    echo -e "\n${CLR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}" >&2
    echo -e "${CLR_BOLD}  $*${CLR_RESET}" >&2
    echo -e "${CLR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}" >&2
}
