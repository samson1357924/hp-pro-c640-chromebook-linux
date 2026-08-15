#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# scripts/backup-restore.sh - Backup Inspector & Rollback Utility
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logger.sh
source "$ROOT_DIR/lib/logger.sh"
# shellcheck source=lib/backup.sh
source "$ROOT_DIR/lib/backup.sh"

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --list, -l          List all manifest records and backups (default)"
    echo "  --rollback [COMP]   Rollback a specific component (audio, fingerprint, keyboard, all)"
    echo "  --help, -h          Show this help message"
}

list_backups() {
    log_section "HP Pro c640 Linux Enablement Manifest & Backup Records"

    if [ -f "$MANIFEST_FILE" ]; then
        log_info "Manifest file: $MANIFEST_FILE"
        if command -v python3 > /dev/null 2>&1; then
            python3 -c '
import json, sys
manifest_path = sys.argv[1]
with open(manifest_path, "r") as f:
    data = json.load(f)
print(f"Total installed entries: {len(data.get(\"records\", []))}")
for i, rec in enumerate(data.get("records", []), 1):
    print(f"  [{i}] Component: {rec.get(\"component\")} | Target: {rec.get(\"target\")} | Installed: {rec.get(\"installed_at\")}")
' "$MANIFEST_FILE"
        else
            cat "$MANIFEST_FILE"
        fi
    else
        log_info "No install manifest found at $MANIFEST_FILE."
    fi

    if [ -d "$BACKUP_BASE_DIR" ]; then
        log_info "Backup storage: $BACKUP_BASE_DIR"
        ls -la "$BACKUP_BASE_DIR"
    else
        log_info "No backup directory found at $BACKUP_BASE_DIR."
    fi
}

case "${1:-list}" in
    --list | -l | list)
        list_backups
        ;;
    --rollback | -r | rollback)
        shift
        comp="${1:-all}"
        rollback_component "$comp"
        ;;
    --help | -h)
        show_help
        ;;
    *)
        log_error "Unknown option: $1"
        show_help
        exit 1
        ;;
esac
