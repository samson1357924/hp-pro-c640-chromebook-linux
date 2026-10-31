#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Verify the real AT keyboard scancode -> keycode map against the hwdb fixture.

The unit-style tests cannot catch a wrong *scancode*: they inject keycodes after
the hwdb translation. This script reads the mapping that the kernel actually has
for the internal AT keyboard and compares it with
``keyboard/tests/hwdb-top-row-scancodes.tsv``.

It only uses EVIOCGKEYCODE / EVIOCGKEY, which are read-only ioctls. It never
calls EVIOCGRAB, so the desktop keeps working (keyd may still own the device;
the ioctls work regardless).

Usage:
  sudo python3 keyboard/tests/check-top-row-hwdb.py
  sudo python3 keyboard/tests/check-top-row-hwdb.py --listen   # also log presses

Exit status: 0 all expected mappings present, 1 otherwise.
"""
import argparse
import fcntl
import os
import struct
import sys
import time

try:
    import evdev
    from evdev import InputDevice, ecodes as e, list_devices
except ImportError:
    print("FAIL: python3-evdev is missing; install it with: sudo apt install python3-evdev")
    sys.exit(1)

AT_KEYBOARD_NAME = "AT Translated Set 2 keyboard"
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hwdb-top-row-scancodes.tsv")
EVIOCGKEYCODE = 0x80084504


def find_at_keyboard():
    for path in sorted(list_devices()):
        try:
            dev = InputDevice(path)
        except OSError:
            continue
        if dev.name == AT_KEYBOARD_NAME:
            return dev
        dev.close()
    return None


def expected_keycode(name):
    """hwdb key name (back) -> KEY_BACK code."""
    code = getattr(e, "KEY_" + name.upper(), None)
    if code is None:
        raise SystemExit(f"FAIL: unknown hwdb key name {name!r} in {FIXTURE}")
    return code


def key_name(code):
    """ecodes.KEY may hold aliases as a tuple (e.g. 113 -> MUTE/MIN_INTERESTING)."""
    name = evdev.ecodes.KEY.get(code, code)
    if isinstance(name, tuple):
        name = "/".join(str(n) for n in name)
    return str(name)


def read_fixture():
    rows = []
    with open(FIXTURE, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) < 2 or not fields[0].strip() or not fields[1].strip():
                raise SystemExit(f"FAIL: malformed fixture row (need scancode<TAB>key): {line!r}")
            sc, key = fields[0].strip(), fields[1].strip()
            try:
                scancode = int(sc, 16)
            except ValueError:
                raise SystemExit(f"FAIL: bad scancode {sc!r} in {FIXTURE}") from None
            label = " ".join(f.strip() for f in fields[2:] if f.strip())
            rows.append((scancode, key, label))
    return rows


def get_keycode(fd, scancode):
    out = fcntl.ioctl(fd, EVIOCGKEYCODE, struct.pack("ii", scancode, 0))
    _sc, code = struct.unpack("ii", out)
    return code


def listen(dev, seconds):
    print(f"listening on {dev.path} for {seconds:g}s (EVIOCGKEY polling, no grab)", flush=True)
    prev = set()
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        cur = set(dev.active_keys())
        for code in sorted(cur - prev):
            print(f"{time.strftime('%H:%M:%S')} {key_name(code)} down", flush=True)
        for code in sorted(prev - cur):
            print(f"{time.strftime('%H:%M:%S')} {key_name(code)} up", flush=True)
        prev = cur
        time.sleep(0.03)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--listen", type=float, metavar="SECONDS",
                        help="after checking, log key presses for this many seconds")
    args = parser.parse_args()

    dev = find_at_keyboard()
    if dev is None:
        print(f"FAIL: {AT_KEYBOARD_NAME!r} not found")
        return 1

    try:
        fd = os.open(dev.path, os.O_RDONLY)
    except PermissionError:
        print(f"FAIL: cannot read {dev.path} (EVIOCGKEYCODE needs root); re-run with sudo")
        return 1
    failures = 0
    try:
        print(f"{dev.path}: {dev.name}")
        print(f"{'scancode':8s} {'hwdb key':16s} {'expected':<20s} {'kernel':<20s} result")
        for scancode, key, label in read_fixture():
            want = expected_keycode(key)
            got = get_keycode(fd, scancode)
            ok = got == want
            failures += 0 if ok else 1
            print(f"0x{scancode:02x}     {key:16s} {key_name(want):<20s} {key_name(got):<20s} "
                  f"{'OK' if ok else 'MISMATCH'}  # {label}")
    finally:
        os.close(fd)

    if args.listen:
        listen(dev, args.listen)

    dev.close()
    if failures:
        print(f"RESULT=FAIL ({failures} scancode(s) not mapped as expected)")
        print("Reinstall with: sudo ./keyboard/install-keyboard.sh --with-keyd")
        print("then check:     udevadm info /dev/input/event2 | grep KEYBOARD_KEY")
        return 1
    print("RESULT=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
