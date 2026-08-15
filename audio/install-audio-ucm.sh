#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Backward compatibility wrapper for audio/install-audio.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/install-audio.sh" "$@"
