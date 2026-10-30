#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Live functional test for the keyd dual-role Search key.

This injects events through a virtual keyboard instead of requiring a human to
press the real one, then reads what keyd's virtual keyboard emits. It verifies:

  1. tap Search                       -> CAPSLOCK
  2. hold Search + Back               -> META (held) ... F1
  3. hold Search + BrightnessDown     -> F6  (Search+top-row = F1-F10 layer)
  4. BrightnessDown alone             -> brightnessdown (media layer)

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
        e.KEY_BACK,
        e.KEY_F1,
        e.KEY_BRIGHTNESSUP,
        e.KEY_BRIGHTNESSDOWN,
    ]
)

# keyd's modifier guard (src/keyboard.c:clear_mod) wraps a lone LEFTCTRL/ALT
# release with a short LEFTCTRL down/up pair so GNOME does not treat the tap as
# an Activities shortcut. These are expected and not failures.
MODIFIERS = ("KEY_LEFTMETA", "KEY_LEFTCTRL", "KEY_RIGHTMETA", "KEY_RIGHTCTRL")


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
                out.append((evdev.ecodes.KEY.get(ev.code, str(ev.code)), ev.value))
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

        # 1. tap Search -> CAPSLOCK
        press(ui, e.KEY_LEFTMETA, hold=0.05)
        tap = names(collect(kd, 0.6, "tap Search"))
        non_mods = [n for n in tap if n not in MODIFIERS]
        if tap.count("KEY_CAPSLOCK") == 2 and set(non_mods) == {"KEY_CAPSLOCK"}:
            print("PASS: tap Search -> CAPSLOCK (modifier guard LEFTCTRL ignored)")
        else:
            print("FAIL: tap Search expected CAPSLOCK only")
            failures.append("tap")

        # 2. hold Search + Back -> META + F1
        ui.write(e.EV_KEY, e.KEY_LEFTMETA, 1)
        ui.syn()
        time.sleep(0.6)  # exceed the tap timeout and enter the meta layer
        press(ui, e.KEY_BACK)
        ui.write(e.EV_KEY, e.KEY_LEFTMETA, 0)
        ui.syn()
        held = names(collect(kd, 0.8, "hold Search + Back"))
        if "KEY_LEFTMETA" in held and "KEY_F1" in held:
            print("PASS: hold Search + Back -> META + F1")
        else:
            print("FAIL: hold Search + Back expected META and F1")
            failures.append("hold-f1")

        # 3. hold Search + BrightnessDown -> F6
        ui.write(e.EV_KEY, e.KEY_LEFTMETA, 1)
        ui.syn()
        time.sleep(0.6)
        press(ui, e.KEY_BRIGHTNESSDOWN)
        ui.write(e.EV_KEY, e.KEY_LEFTMETA, 0)
        ui.syn()
        held2 = names(collect(kd, 0.8, "hold Search + BrightnessDown"))
        if "KEY_F6" in held2:
            print("PASS: hold Search + BrightnessDown -> F6")
        else:
            print("FAIL: hold Search + BrightnessDown expected F6 (F1-F10 layer)")
            failures.append("hold-f6")

        # 4. BrightnessDown alone -> brightnessdown media key
        press(ui, e.KEY_BRIGHTNESSDOWN)
        media = names(collect(kd, 0.6, "BrightnessDown alone"))
        if "KEY_BRIGHTNESSDOWN" in media and "KEY_F6" not in media:
            print("PASS: BrightnessDown alone -> brightnessdown")
        else:
            print("FAIL: BrightnessDown alone expected the media key")
            failures.append("media")

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
