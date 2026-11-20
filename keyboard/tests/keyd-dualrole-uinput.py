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

SIDE EFFECTS / SAFETY:
  The virtual keyboard we inject into is the device the desktop actually
  listens to, so injected events reach the real compositor. During the run
  CapsLock is toggled, brightness/volume may change, and the GNOME overview is
  opened ~11 times. Do not touch the keyboard while running. CapsLock state is
  toggled — re-toggle it afterwards if needed.

Requirements:
  * root (needs /dev/uinput, read-only /dev/input/event*, systemctl)
  * Python >= 3.7 (uses subprocess.run(text=True, capture_output=True))
  * python3-evdev (`sudo apt install python3-evdev`)
  * keyd installed, enabled and configured via
    `sudo ./keyboard/install-keyboard.sh --with-keyd`

Run:
  sudo python3 keyboard/tests/keyd-dualrole-uinput.py

Exit code 0 = all checks passed. NOTE: restarting keyd briefly drops the real
keyboard remapping, so run this from a TTY/SSH or accept a ~1s interruption.
"""
import os
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
        # Post-hwdb top-row keycodes: Back..VolumeUp plus F11.
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


def close_quietly(dev):
    """Close an evdev device without letting a cleanup-only error escape."""
    if dev is None:
        return
    try:
        dev.close()
    except OSError:
        pass


def find_keyd():
    for path in list_devices():
        try:
            dev = InputDevice(path)
        except OSError:
            continue
        if dev.name == KEYD_NAME:
            return dev
        dev.close()  # do not leak handles for devices that are not keyd's
    return None


def collect(dev, seconds, label):
    """Collect EV_KEY events for `seconds` and print them.

    Uses a monotonic clock so the window cannot be shortened by clock changes.
    A select timeout does not end the window early — we keep waiting until
    `end`. Returns ``(events, dropped)``: ``dropped`` is True when SYN_DROPPED
    was seen or the device could not be read, i.e. the stream is incomplete and
    must not be trusted for a PASS verdict.
    """
    out = []
    dropped = False
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            ready, _, _ = select.select([dev.fd], [], [], max(0.0, end - time.monotonic()))
            if not ready:
                continue
            batch = dev.read()
        except OSError as exc:
            # Device vanished mid-capture (e.g. keyd died): fail cleanly
            # instead of dumping a traceback.
            print(f"WARN: [{label}] device read failed ({exc}); capture untrustworthy")
            dropped = True
            break
        for ev in batch:
            if ev.type == e.EV_KEY:
                out.append((key_name(ev.code), ev.value))
            elif ev.type == e.EV_SYN and ev.code == e.SYN_DROPPED:
                print(f"WARN: [{label}] SYN_DROPPED seen — events may have been lost")
                dropped = True
    print(f"[{label}] {out}")
    return out, dropped


def collect_checked(dev, seconds, label, failures):
    """collect() plus: an untrustworthy capture is a hard failure, never PASS."""
    events, dropped = collect(dev, seconds, label)
    if dropped:
        print(f"FAIL: [{label}] event capture was incomplete; cannot trust this check")
        failures.append(f"dropped:{label}")
    return events


def names(events):
    return [name for name, _ in events]


def press(ui, code, hold=0.05):
    ui.write(e.EV_KEY, code, 1)
    ui.syn()
    time.sleep(hold)
    ui.write(e.EV_KEY, code, 0)
    ui.syn()


def main():
    if os.geteuid() != 0:
        print("FAIL: keyd-dualrole-uinput.py requires root permissions (run with sudo)")
        return 1

    ui = None
    try:
        ui = UInput(
            {e.EV_KEY: KEYS},
            name=TEST_DEVICE_NAME,
            vendor=1,
            product=1,
            version=1,
            bustype=e.BUS_USB,
        )
        time.sleep(1.0)  # let udev settle
        subprocess.run(["systemctl", "restart", "keyd"], check=True)
        time.sleep(1.5)
    except (OSError, subprocess.CalledProcessError, FileNotFoundError) as exc:
        print(f"FAIL: setup error (creating /dev/uinput device or restarting keyd): {exc}")
        # A failed `systemctl restart keyd` may have stopped keyd already. Try
        # to restore it, and say so explicitly if that best effort also fails.
        try:
            subprocess.run(["systemctl", "restart", "keyd"], check=True)
        except (OSError, subprocess.CalledProcessError, FileNotFoundError) as restore_exc:
            print(f"WARN: keyd may not be restored (restart failed: {restore_exc}); run `sudo systemctl restart keyd` manually")
        close_quietly(ui)
        return 1

    failures = []
    kd = None
    try:
        print(f"started {time.strftime('%Y-%m-%d %H:%M:%S')}")
        kd = find_keyd()
        if kd is None:
            print("FAIL: keyd virtual keyboard not found (is keyd running?)")
            return 1
        print(f"keyd output device: {kd.path}")

        res = subprocess.run(
            ["journalctl", "-u", "keyd", "--since", "20 seconds ago", "--no-pager"],
            capture_output=True,
            text=True,
        )
        log = res.stdout
        if res.returncode != 0 or TEST_DEVICE_NAME not in log:
            log = subprocess.run(
                ["journalctl", "-u", "keyd", "-n", "100", "--no-pager"],
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
        tap = names(collect_checked(kd, 0.6, "tap Search", failures))
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
            held = names(collect_checked(kd, 0.7, f"hold Search + {label}", failures))
            # Require exactly the expected non-modifier key: emitting both the
            # new F-key and the old media key would still pass a looser check.
            held_non_mods = [n for n in held if n not in MODIFIERS]
            if held_non_mods and set(held_non_mods) == {expected}:
                print(f"PASS: hold Search + {label} -> {expected}")
            else:
                print(f"FAIL: hold Search + {label} expected only {expected}, got", held)
                failures.append(f"hold-{expected.lower()}")

        # 3. each top-row key alone -> its own media key (pass-through).
        for label, code, _expected in TOP_ROW:
            press(ui, code)
            media = names(collect_checked(kd, 0.6, f"{label} alone", failures))
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
        lone = collect_checked(kd, 0.8, "hold Search alone, release", failures)
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
            and "KEY_CAPSLOCK" not in lone_names
        ):
            print("PASS: hold Search alone -> bare META release (no guard)")
        else:
            print("FAIL: hold Search alone expected a META release without LEFTCTRL guard")
            failures.append("hold-meta-clean")

    finally:
        # Close devices on every path (including early returns / exceptions),
        # using a quiet close so cleanup errors cannot mask the real result.
        close_quietly(kd)
        close_quietly(ui)
        # Drop the virtual device and let keyd re-scan without it. Do not fail
        # silently: leave a clear warning if the cleanup restart did not work.
        try:
            res = subprocess.run(["systemctl", "restart", "keyd"], check=False)
            if res.returncode != 0:
                print(f"WARN: keyd restart after test exited {res.returncode}; restart keyd manually")
        except (OSError, subprocess.CalledProcessError, FileNotFoundError) as exc:
            print(f"WARN: could not restart keyd after test ({exc}); restart keyd manually")

    if failures:
        print("RESULT=FAIL", failures)
        return 1
    print("RESULT=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
