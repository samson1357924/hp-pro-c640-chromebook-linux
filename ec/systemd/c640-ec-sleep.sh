#!/bin/sh
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# /usr/lib/systemd/system-sleep/c640-ec-sleep.sh
#
# HP Pro c640 (Google Dratini) — Instant battery charge control re-evaluation on resume.
#
# Why: During S3 deep sleep, userspace polling is frozen. While the ChromeOS EC keeps
# its hardware state across S3, re-evaluating immediately upon resume ensures zero-window
# protection if the AC state changed or if charge control requires re-assertion.

case "$1" in
    post)
        if [ -x "/usr/local/bin/c640-ec-control" ]; then
            /usr/local/bin/c640-ec-control battery-eval 90 > /dev/null 2>&1 || true
        fi
        ;;
esac

exit 0
