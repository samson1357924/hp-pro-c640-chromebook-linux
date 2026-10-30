#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lib/logger.sh - Structured Terminal & File Logger for HP Pro c640 Linux Enablement

# Avoid multiple inclusions
if [ -n "${_LIB_LOGGER_SH_LOADED:-}" ]; then
    return 0
fi
_LIB_LOGGER_SH_LOADED=1

# Log file selection:
#  - root runs write to /var/log (a /tmp file created by the user is not
#    writable by root after sudo re-runs, and vice versa)
#  - user runs fall back to a per-uid file if the shared /tmp log belongs to
#    another user, avoiding "Permission denied" noise on every log line
if [ -z "${LOG_FILE:-}" ]; then
    if [ "$(id -u 2> /dev/null || echo 0)" -eq 0 ]; then
        LOG_FILE="/var/log/cros-linux-setup.log"
    else
        LOG_FILE="${TMPDIR:-/tmp}/cros-linux-setup.log"
        if ! { : >> "$LOG_FILE"; } 2> /dev/null; then
            LOG_FILE="${TMPDIR:-/tmp}/cros-linux-setup.$(id -u 2> /dev/null || echo unknown).log"
        fi
    fi
fi
if [ -n "$LOG_FILE" ] && ! { : >> "$LOG_FILE"; } 2> /dev/null; then
    LOG_FILE=""
fi

_log_file_append() {
    echo "$1" >> "$LOG_FILE"
}

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
        mkdir -p "$(dirname "$LOG_FILE")" 2> /dev/null || true
        _log_file_append "[$timestamp] [$level] $msg" 2> /dev/null || true
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
        _log_file_append "\n=== [${step_num}/${total_steps}] ${*} ===" 2> /dev/null || true
    fi
}

log_section() {
    echo -e "\n${CLR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}" >&2
    echo -e "${CLR_BOLD}  $*${CLR_RESET}" >&2
    echo -e "${CLR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CLR_RESET}" >&2
}
