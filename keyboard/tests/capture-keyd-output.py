#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Passively record what keyd's virtual keyboard delivers to the desktop.

The keyd daemon grabs the physical AT keyboard and re-emits the remapped keys on
its own virtual keyboard (``keyd virtual keyboard``). This script opens that
device read-only and prints the events, so it shows exactly what GNOME/KDE
receives for a real key press.

It never calls ``EVIOCGRAB``, so the desktop keeps working while it runs.

WARNING: never grab the keyd virtual keyboard (``evtest --grab``,
``evemu-record --grab``, raw ``EVIOCGRAB``): that kills desktop input until the
tool exits. Plain ``evtest`` without ``--grab`` is read-only and safe. A physical
keyboard grabbed by keyd is invisible to other readers, which is why this script
reads the keyd virtual keyboard instead. ``keyd monitor`` cannot be used either:
keyd 2.5.x cannot open devices it already grabbed, so the physical keyboard
never shows up there.

Usage:
  sudo python3 keyboard/tests/capture-keyd-output.py
  sudo python3 keyboard/tests/capture-keyd-output.py --seconds 0   # until Ctrl+C
  sudo python3 keyboard/tests/capture-keyd-output.py --device /dev/input/event7

Then press the keys you want to verify (e.g. tap Search, or hold Search and
press a top-row key) and read the output.

Exit status:
  0 - capture window ended normally, including --seconds 0 interrupted with
      Ctrl+C, or a read OSError / the device disappearing (handled as a clean
      end of capture, not an error),
  1 - a bad argument (e.g. negative --seconds -> immediate exit 1), no keyd
      device found, or the requested device could not be opened.
"""
import argparse
import glob
import math
import os
import select
import sys
import time

try:
    import evdev
    from evdev import ecodes as e
except ImportError:
    print("FAIL: python3-evdev is missing; install it with: sudo apt install python3-evdev")
    sys.exit(1)

KEYD_NAME = "keyd virtual keyboard"


def find_keyd_device():
    permission_denied = False
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            dev = evdev.InputDevice(path)
        except PermissionError:
            permission_denied = True
            continue
        except OSError:
            continue
        if dev.name == KEYD_NAME:
            return dev
        dev.close()
    if permission_denied:
        raise PermissionError("Insufficient permissions to read /dev/input/event* (run with sudo)")
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


def key_name(code):
    """Return one readable name per keycode (evdev aliases are tuples)."""
    name = evdev.ecodes.KEY.get(code, f"KEY_{code}")
    if isinstance(name, tuple):
        # e.g. (KEY_MIN_INTERESTING, KEY_MUTE): prefer the descriptive alias.
        return next((n for n in name if n != "KEY_MIN_INTERESTING"), name[0])
    return name


def main():
    args = parse_args()

    if args.seconds is not None and args.seconds < 0:
        print("FAIL: --seconds must be >= 0 (use 0 to capture until Ctrl+C)")
        return 1

    if args.seconds is not None and not math.isfinite(args.seconds):
        print("FAIL: --seconds must be finite")
        return 1

    if args.device:
        try:
            dev = evdev.InputDevice(args.device)
        except PermissionError:
            print("FAIL: Insufficient permissions to read /dev/input/event* (run with sudo)")
            return 1
        except OSError as exc:
            print(f"FAIL: cannot open {args.device}: {exc}")
            return 1
        if dev.name != KEYD_NAME:
            print(f"WARN: {dev.path} is {dev.name!r}, not {KEYD_NAME!r}")
    else:
        try:
            dev = find_keyd_device()
        except PermissionError as exc:
            print(f"FAIL: {exc}")
            return 1
        if dev is None:
            print(f"FAIL: {KEYD_NAME!r} not found; is keyd running? (systemctl status keyd)")
            return 1

    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} passive capture {dev.path} {dev.name} (no EVIOCGRAB)", flush=True)
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
                    print(f"{stamp} {key_name(ev.code)} {ev.value}", flush=True)
                elif ev.type == e.EV_SYN and ev.code == e.SYN_DROPPED:
                    print(f"{stamp} !!! SYN_DROPPED (events were lost)", flush=True)
    except KeyboardInterrupt:
        print("stopped", flush=True)
    except OSError as exc:
        print(f"{dev.path} read failed ({exc}); stopping capture", flush=True)
    finally:
        dev.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
