#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Live functional test for the keyd dual-role Search key.

This injects events through a virtual keyboard instead of requiring a human to
press the real one, then reads what keyd's virtual keyboard emits. It verifies:

  1. tap Search                       -> CAPSLOCK only (no META, no guard)
  2. hold Search + each top-row key   -> F1 ... F10 (all ten)
  3. each top-row key alone           -> its media key (pass-through)
  4. hold Search, release alone       -> lone META down/up, NO LEFTCTRL guard
                                         (this is what lets Mutter open the
                                         GNOME overview)

LIMITATION: this test feeds keycodes *after* the hwdb translation. It cannot
tell whether the physical keyboard really emits KEY_BACK/KEY_BRIGHTNESSDOWN,
because it injects those keycodes directly. Use
`keyboard/tests/check-top-row-hwdb.py` on the real machine to verify the AT
scancodes (0x3b-0x44 on Dratini). An earlier version of this test passed while
the top row was still sending raw F1-F10, because the hwdb mapped scancodes the
hardware never sends.

Why a virtual device: keyd 2.5.x only grabs devices it classified as a keyboard
at start-up (no hot-plug support), so the test creates the device first, then
restarts keyd. The device advertises the AT keyboard id 0001:0001 so the
`[ids] 0001:0001` stanza in cros.conf matches it.

Requirements:
  * root (needs /dev/uinput, EVIOCGRAB-reading /dev/input/event*, systemctl)
  * python3-evdev (`sudo apt install python3-evdev`)
  * keyd installed, enabled and configured via
    `sudo ./keyboard/install-keyboard.sh --with-keyd`

Run:
  sudo python3 keyboard/tests/keyd-dualrole-uinput.py

Exit code 0 = all checks passed. NOTE: restarting keyd briefly drops the real
keyboard remapping, so run this from a TTY/SSH or accept a ~1s interruption.
"""
import select
import subprocess
import sys
import time

import evdev
from evdev import ecodes as e, UInput, InputDevice, list_devices

KEYD_NAME = "keyd virtual keyboard"
TEST_DEVICE_NAME = "c640-dualrole-test"

# keyd 2.5.x classifies a device as a keyboard only when it exposes the full
# `keyboard_mask` (KEY_1..0, Q..Y) or KEY_BRIGHTNESSUP. Without them the device
# gets ID_INPUT_KEY=1 but is silently ignored by keyd.
KEYS = (
    [getattr(e, f"KEY_{c}") for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"]
    + [getattr(e, f"KEY_{d}") for d in "1234567890"]
    + [
        e.KEY_ENTER,
        e.KEY_SPACE,
        e.KEY_LEFTSHIFT,
        e.KEY_LEFTMETA,
        # Post-hwdb top-row keycodes: Back..VolumeUp plus F11/F1.
        e.KEY_BACK,
        e.KEY_FORWARD,
        e.KEY_REFRESH,
        e.KEY_F11,
        e.KEY_SCALE,
        e.KEY_BRIGHTNESSDOWN,
        e.KEY_BRIGHTNESSUP,
        e.KEY_MUTE,
        e.KEY_VOLUMEDOWN,
        e.KEY_VOLUMEUP,
    ]
)

# The top row after hwdb: injected keycode -> expected keycode on the meta layer.
TOP_ROW = (
    ("Back", e.KEY_BACK, "KEY_F1"),
    ("Forward", e.KEY_FORWARD, "KEY_F2"),
    ("Refresh", e.KEY_REFRESH, "KEY_F3"),
    ("Fullscreen (F11)", e.KEY_F11, "KEY_F4"),
    ("Overview (Scale)", e.KEY_SCALE, "KEY_F5"),
    ("BrightnessDown", e.KEY_BRIGHTNESSDOWN, "KEY_F6"),
    ("BrightnessUp", e.KEY_BRIGHTNESSUP, "KEY_F7"),
    ("Mute", e.KEY_MUTE, "KEY_F8"),
    ("VolumeDown", e.KEY_VOLUMEDOWN, "KEY_F9"),
    ("VolumeUp", e.KEY_VOLUMEUP, "KEY_F10"),
)

# Modifier key names, filtered out where only the non-modifier result matters.
# The tap assertion additionally requires that no META/CTRL pair appears at all:
# keyd's old plain overload() emitted a LEFTCTRL guard around the tap, which
# made Mutter treat it as Meta+Ctrl.
MODIFIERS = ("KEY_LEFTMETA", "KEY_LEFTCTRL", "KEY_RIGHTMETA", "KEY_RIGHTCTRL")


def key_name(code):
    """Return one readable name for a keycode (resolve evdev aliases)."""
    name = evdev.ecodes.KEY.get(code, str(code))
    if isinstance(name, tuple):
        # e.g. (KEY_MIN_INTERESTING, KEY_MUTE): prefer the descriptive alias.
        return next((n for n in name if n != "KEY_MIN_INTERESTING"), name[0])
    return name


def find_keyd():
    for path in list_devices():
        try:
            dev = InputDevice(path)
        except OSError:
            continue
        if dev.name == KEYD_NAME:
            return dev
    return None


def collect(dev, seconds, label):
    """Collect EV_KEY events for `seconds` and print them."""
    out = []
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([dev.fd], [], [], max(0, end - time.time()))
        if not ready:
            break
        for ev in dev.read():
            if ev.type == e.EV_KEY:
                out.append((key_name(ev.code), ev.value))
    print(f"[{label}] {out}")
    return out


def names(events):
    return [name for name, _ in events]


def press(ui, code, hold=0.05):
    ui.write(e.EV_KEY, code, 1)
    ui.syn()
    time.sleep(hold)
    ui.write(e.EV_KEY, code, 0)
    ui.syn()


def main():
    ui = UInput(
        {e.EV_KEY: KEYS},
        name=TEST_DEVICE_NAME,
        vendor=1,
        product=1,
        version=1,
        bustype=e.BUS_USB,
    )
    failures = []
    try:
        time.sleep(1.0)  # let udev settle
        subprocess.run(["systemctl", "restart", "keyd"], check=True)
        time.sleep(1.5)

        kd = find_keyd()
        if kd is None:
            print("FAIL: keyd virtual keyboard not found (is keyd running?)")
            return 1
        print(f"keyd output device: {kd.path}")

        log = subprocess.run(
            ["journalctl", "-u", "keyd", "-n", "40", "--no-pager"],
            capture_output=True,
            text=True,
        ).stdout
        attached = TEST_DEVICE_NAME in log
        print("keyd attached to test device:", attached)
        if not attached:
            print("FAIL: keyd did not grab the test device (check [ids] in /etc/keyd/cros.conf)")
            failures.append("attach")

        # 1. tap Search -> CAPSLOCK only. A plain overload() would also emit
        # META plus the LEFTCTRL guard here, so check the raw event names
        # instead of filtering modifiers out.
        press(ui, e.KEY_LEFTMETA, hold=0.05)
        tap = names(collect(kd, 0.6, "tap Search"))
        non_mods = [n for n in tap if n not in MODIFIERS]
        if (
            tap.count("KEY_CAPSLOCK") == 2
            and set(non_mods) == {"KEY_CAPSLOCK"}
            and "KEY_LEFTMETA" not in tap
            and "KEY_LEFTCTRL" not in tap
        ):
            print("PASS: tap Search -> CAPSLOCK only (no META, no guard)")
        else:
            print("FAIL: tap Search expected CAPSLOCK only, got", tap)
            failures.append("tap")

        # 2. hold Search + each top-row key -> F1 ... F10.
        for label, code, expected in TOP_ROW:
            ui.write(e.EV_KEY, e.KEY_LEFTMETA, 1)
            ui.syn()
            time.sleep(0.6)  # exceed the tap timeout and enter the meta layer
            press(ui, code)
            ui.write(e.EV_KEY, e.KEY_LEFTMETA, 0)
            ui.syn()
            held = names(collect(kd, 0.7, f"hold Search + {label}"))
            if expected in held:
                print(f"PASS: hold Search + {label} -> {expected}")
            else:
                print(f"FAIL: hold Search + {label} expected {expected}, got", held)
                failures.append(f"hold-{expected.lower()}")

        # 3. each top-row key alone -> its own media key (pass-through).
        for label, code, _expected in TOP_ROW:
            press(ui, code)
            media = names(collect(kd, 0.6, f"{label} alone"))
            own = key_name(code)
            if own in media:
                print(f"PASS: {label} alone -> {own}")
            else:
                print(f"FAIL: {label} alone expected {own}, got", media)
                failures.append(f"media-{label.lower().split()[0]}")

        # 4. hold Search and release it alone -> clean lone META, no LEFTCTRL.
        # keyd's clear_mod() guard would otherwise turn this into Meta+Ctrl and
        # Mutter would not treat it as the overlay key (no GNOME overview).
        ui.write(e.EV_KEY, e.KEY_LEFTMETA, 1)
        ui.syn()
        time.sleep(0.6)
        ui.write(e.EV_KEY, e.KEY_LEFTMETA, 0)
        ui.syn()
        lone = collect(kd, 0.8, "hold Search alone, release")
        lone_names = names(lone)
        # Autorepeat events (value 2) are normal while the key is held; the
        # point is that the final release is a bare META (no LEFTCTRL guard).
        if (
            lone_names
            and lone_names[0] == "KEY_LEFTMETA"
            and lone_names[-1] == "KEY_LEFTMETA"
            and lone[0][1] == 1
            and lone[-1][1] == 0
            and "KEY_LEFTCTRL" not in lone_names
            and "KEY_RIGHTCTRL" not in lone_names
        ):
            print("PASS: hold Search alone -> bare META release (no guard)")
        else:
            print("FAIL: hold Search alone expected a META release without LEFTCTRL guard")
            failures.append("hold-meta-clean")

        kd.close()
    finally:
        ui.close()
        # Drop the virtual device and let keyd re-scan without it.
        subprocess.run(["systemctl", "restart", "keyd"], check=False)

    if failures:
        print("RESULT=FAIL", failures)
        return 1
    print("RESULT=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
