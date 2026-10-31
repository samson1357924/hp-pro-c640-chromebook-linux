#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Passively record what keyd's virtual keyboard delivers to the desktop.

The keyd daemon grabs the physical AT keyboard and re-emits the remapped keys on
its own virtual keyboard (``keyd virtual keyboard``). This script opens that
device read-only and prints the events, so it shows exactly what GNOME/KDE
receives for a real key press.

It never calls ``EVIOCGRAB``, so the desktop keeps working while it runs.

WARNING: do not use ``evtest``, ``evemu-record`` or any other tool that grabs
the keyd virtual keyboard. Grabbing it makes the whole desktop keyboard go dead
until that tool exits. ``keyd monitor`` cannot be used either: keyd 2.5.x cannot
open devices it already grabbed, so the physical keyboard never shows up there.

Usage:
  sudo python3 keyboard/tests/capture-keyd-output.py
  sudo python3 keyboard/tests/capture-keyd-output.py --seconds 0   # until Ctrl+C
  sudo python3 keyboard/tests/capture-keyd-output.py --device /dev/input/event7

Then press the keys you want to verify (e.g. tap Search, or hold Search and
press a top-row key) and read the output.

Exit status: 0 when the capture window ends, 1 if no keyd device is found.
"""
import argparse
import os
import select
import sys
import time

try:
    import evdev
    from evdev import ecodes as e
    from evdev import list_devices
except ImportError:
    print("FAIL: python3-evdev is missing; install it with: sudo apt install python3-evdev")
    sys.exit(1)

KEYD_NAME = "keyd virtual keyboard"


def find_keyd_device():
    for path in sorted(list_devices()):
        try:
            dev = evdev.InputDevice(path)
        except OSError:
            continue
        if dev.name == KEYD_NAME:
            return dev
        dev.close()
    return None


def parse_args():
    parser = argparse.ArgumentParser(
        description="Passively capture keyd virtual keyboard events (never grabs the device).",
    )
    parser.add_argument(
        "--device",
        help="event node to read (default: auto-detect the keyd virtual keyboard)",
    )
    parser.add_argument(
        "--seconds",
        type=float,
        default=120.0,
        help="capture duration in seconds, 0 means until Ctrl+C (default: 120)",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    if args.device:
        try:
            dev = evdev.InputDevice(args.device)
        except OSError as exc:
            print(f"FAIL: cannot open {args.device}: {exc}")
            return 1
        if dev.name != KEYD_NAME:
            print(f"WARN: {dev.path} is {dev.name!r}, not {KEYD_NAME!r}")
    else:
        dev = find_keyd_device()
        if dev is None:
            print(f"FAIL: {KEYD_NAME!r} not found; is keyd running? (systemctl status keyd)")
            return 1

    print(f"passive capture {dev.path} {dev.name} (no EVIOCGRAB)", flush=True)
    if args.seconds:
        print(f"listening for {args.seconds:g}s, press keys now", flush=True)

    end = time.monotonic() + args.seconds
    try:
        while True:
            timeout = 1.0 if not args.seconds else max(0.0, end - time.monotonic())
            if args.seconds and timeout == 0.0:
                break
            ready, _, _ = select.select([dev.fd], [], [], timeout)
            if not ready:
                if not os.path.exists(dev.path):
                    print(f"{dev.path} disappeared", flush=True)
                    break
                continue
            for ev in dev.read():
                stamp = time.strftime("%H:%M:%S")
                if ev.type == e.EV_KEY:
                    name = evdev.ecodes.KEY.get(ev.code, f"KEY_{ev.code}")
                    print(f"{stamp} {name} {ev.value}", flush=True)
                elif ev.type == e.EV_SYN and ev.code == e.SYN_DROPPED:
                    print(f"{stamp} !!! SYN_DROPPED (events were lost)", flush=True)
    except KeyboardInterrupt:
        print("stopped", flush=True)
    finally:
        dev.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
