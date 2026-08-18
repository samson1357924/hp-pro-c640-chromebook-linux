#!/bin/sh
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# /usr/lib/systemd/system-sleep/fprintd-sleep.sh
#
# HP Pro c640 (Google Dratini) — clean fprintd shutdown before sleep.
#
# Why: after S3 resume the FPMCU (ChromeOS EC fingerprint MCU) is left
# half-initialized by the driver's in-place resume path, so the first unlock
# attempt claims the device but fails verification instantly and the lock
# screen shows no fingerprint prompt (GNOME/gnome-shell#7791). Stopping
# fprintd before sleep closes the device cleanly; on resume the first unlock
# worker D-Bus-activates a fresh daemon whose open path re-establishes the
# crypto context (FP_CONTEXT), which reliably re-initializes the sensor.
# See docs/TROUBLESHOOTING.md §13.

case "$1" in
    pre)
        systemctl stop fprintd.service 2>/dev/null || true
        ;;
    post)
        # No delay here: resume completes at full speed. The crfpmoc driver
        # itself retries the device open for a bounded time when the EC/FPMCU
        # channel is not ready yet right after S3 wake (crfpmoc_open_ssm_done
        # retry budget in crfpmoc.c), so the first unlock attempt gets a
        # fingerprint prompt without slowing down every resume by seconds.
        ;;
esac

exit 0
