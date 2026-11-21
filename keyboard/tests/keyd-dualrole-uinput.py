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

VALUE 1/0 PAIRING IS A PASS REQUIREMENT:
  Merely seeing a key's *name* was not enough: a stuck press with no release
  (or a second down) could still PASS. Each assertion now requires exactly one
  clean down(1) -> up(0) transition for the key under test, via
  ``clean_press(values_for(events, key))``. Autorepeat events (value 2) are
  tolerated and filtered out. A leading reset 0 (fresh virtual device) and
  trailing 0s are tolerated; a missing release or a repeated/second **down**
  is a FAIL. A second up (an extra trailing 0) is NOT a FAIL, because the
  single final 0 already satisfies the release requirement. Guard keys
  ("must not appear") are checked by name and are NOT required to be paired,
  to avoid false FAILs.

  Run ``python3 keyboard/tests/keyd-dualrole-uinput.py --self-test`` to verify
  these assertions with synthetic events (no root, device or evdev needed).

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

Requirements (live run only):
  * root (needs /dev/uinput, read-only /dev/input/event*, systemctl)
  * Python >= 3.7 (uses subprocess.run(text=True, capture_output=True))
  * python3-evdev (`sudo apt install python3-evdev`)
  * keyd installed, enabled and configured via
    `sudo ./keyboard/install-keyboard.sh --with-keyd`

Run:
  sudo python3 keyboard/tests/keyd-dualrole-uinput.py        # live test
  python3 keyboard/tests/keyd-dualrole-uinput.py --self-test # synthetic, no root

Exit codes:
  0 = all assertions passed AND keyd was restored afterwards.
  1 = a check or setup failed (RESULT=FAIL / ASSERTIONS=FAIL or setup error).
  2 = all assertions passed but the cleanup `systemctl restart keyd` failed;
      RESULT= still reflects the assertions only, while SERVICE_RESTORE= is the
      independent keyboard-service health signal. Restore keyd manually with
      `sudo systemctl restart keyd` in that case.

NOTE: restarting keyd briefly drops the real keyboard remapping, so run this
from a TTY/SSH or accept a ~1s interruption.
"""
import argparse
import os
import select
import subprocess
import sys
import time

try:
    import evdev
    from evdev import ecodes as e, UInput, InputDevice, list_devices
except ImportError:
    # Defer the failure so --help / --self-test still work without python3-evdev.
    evdev = None
    e = None
    UInput = None
    InputDevice = None
    list_devices = None

KEYD_NAME = "keyd virtual keyboard"
TEST_DEVICE_NAME = "c640-dualrole-test"

# Modifier key names, filtered out where only the non-modifier result matters.
# The tap assertion additionally requires that no META/CTRL pair appears at all:
# keyd's old plain overload() emitted a LEFTCTRL guard around the tap, which
# made Mutter treat it as Meta+Ctrl.
MODIFIERS = ("KEY_LEFTMETA", "KEY_LEFTCTRL", "KEY_RIGHTMETA", "KEY_RIGHTCTRL")

# EV_KEY autorepeat value. values_for() drops these so a held key does not
# break the down/up pairing assertion.
REPEAT = 2


def build_keys():
    """Keycodes advertised by the synthetic keyboard (needs evdev)."""
    # keyd 2.5.x classifies a device as a keyboard only when it exposes the
    # full `keyboard_mask` (KEY_1..0, Q..Y) or KEY_BRIGHTNESSUP. Without them
    # the device gets ID_INPUT_KEY=1 but is silently ignored by keyd.
    return (
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


def build_top_row():
    """Injected keycode -> expected keycode on the meta layer (needs evdev)."""
    return (
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


def key_name(code):
    """Return one readable name for a keycode (resolve evdev aliases)."""
    if evdev is None:
        return str(code)
    name = evdev.ecodes.KEY.get(code, str(code))
    if isinstance(name, tuple):
        # e.g. (KEY_MIN_INTERESTING, KEY_MUTE): prefer the descriptive alias.
        return next((n for n in name if n != "KEY_MIN_INTERESTING"), name[0])
    return name


# --- Pure assertion helpers (no evdev dependency; exercised by --self-test) ---

def names(events):
    return [name for name, _ in events]


def values_for(events, key):
    """Values emitted for `key`, with autorepeat (value 2) filtered out."""
    return [value for name, value in events if name == key and value != REPEAT]


def clean_press(values):
    """True iff `values` hold exactly one clean down(1) -> up(0) transition.

    Leading reset 0s (fresh virtual device) and trailing 0s (extra ups) are
    tolerated; autorepeat 2s are expected to be removed by values_for()
    already. A missing release or a repeated/second down is a FAIL; a second
    up is tolerated because v[-1] == 0 already proves the release.
    """
    v = list(values)
    while v and v[0] == 0:
        v = v[1:]
    return bool(v) and v[0] == 1 and v[-1] == 0 and v.count(1) == 1


def unexpected_mods(events, allowed=()):
    """Modifier names in `events` beyond those explicitly allowed.

    Checking the full MODIFIERS tuple (not just the two left-side names) also
    covers RIGHTCTRL/RIGHTMETA. Filtering modifiers out of ``non_mods`` alone
    would silently hide a stray right-side guard.
    """
    return sorted({n for n in names(events) if n in MODIFIERS and n not in allowed})


def check_tap(events):
    """tap Search -> exactly one CAPSLOCK down/up, no modifier guard at all."""
    tap = names(events)
    cap_values = values_for(events, "KEY_CAPSLOCK")
    # A reset 0 of a non-target key on a fresh virtual device must not cause a
    # false FAIL; only real (value != 0) name appearances count as "else".
    non_mods = [n for n, v in events if v != 0 and n not in MODIFIERS]
    ok = (
        clean_press(cap_values)
        and set(non_mods) == {"KEY_CAPSLOCK"}
        and not unexpected_mods(events)
    )
    return ok, {"values": cap_values, "names": tap}


def check_hold(events, expected):
    """hold Search + key -> one down/up of `expected`, no unexpected modifier.

    The `[meta:M]` layer legitimately holds LEFTMETA while active, so that one
    modifier is allowed; a clear_mod() CTRL guard (or RIGHTMETA) is not.
    """
    held = names(events)
    exp_values = values_for(events, expected)
    # Tolerate reset 0s of non-target keys, just like clean_press() does for
    # the target key's leading/trailing resets.
    held_non_mods = [n for n, v in events if v != 0 and n not in MODIFIERS]
    ok = (
        clean_press(exp_values)
        and set(held_non_mods) == {expected}
        and not unexpected_mods(events, allowed=("KEY_LEFTMETA",))
    )
    return ok, {"values": exp_values, "names": held}


def check_media(events, own):
    """top-row key alone -> one clean down/up of `own`, no stray down/mod."""
    media = names(events)
    own_values = values_for(events, own)
    stray = sorted({n for n, v in events if v == 1 and n not in MODIFIERS and n != own})
    ok = (
        clean_press(own_values)
        and not stray
        and not unexpected_mods(events)
    )
    return ok, {"values": own_values, "names": media, "stray_downs": stray}


def check_lone(events):
    """hold Search, release alone -> clean META down/up, no other guard."""
    lone = names(events)
    meta_values = values_for(events, "KEY_LEFTMETA")
    ok = (
        clean_press(meta_values)
        and bool(lone)
        and lone[0] == "KEY_LEFTMETA"
        and lone[-1] == "KEY_LEFTMETA"
        # LEFTMETA is the expected result; all other modifiers (including the
        # previously unchecked RIGHTMETA) are forbidden guards.
        and not unexpected_mods(events, allowed=("KEY_LEFTMETA",))
        and "KEY_CAPSLOCK" not in lone
    )
    return ok, {"values": meta_values, "names": lone}


def close_quietly(dev):
    """Close an evdev device without letting a cleanup-only error escape."""
    if dev is None:
        return
    try:
        dev.close()
    except OSError:
        pass


def keyd_restore_ok(returncode):
    """True iff a `systemctl restart keyd` returned success."""
    return returncode == 0


def restore_keyd():
    """Best-effort restart of keyd at the end of a live run.

    Assertions and service recovery are reported separately: a failed restore
    must never be silently folded into a successful verdict. Returns True only
    when `systemctl restart keyd` actually succeeded.
    """
    try:
        res = subprocess.run(["systemctl", "restart", "keyd"], check=False)
    except (OSError, subprocess.CalledProcessError, FileNotFoundError) as exc:
        print(f"FAIL: could not restart keyd ({exc}); run `sudo systemctl restart keyd` manually")
        return False
    if not keyd_restore_ok(res.returncode):
        print(f"FAIL: keyd restart exited {res.returncode}; run `sudo systemctl restart keyd` manually")
        return False
    return True


def final_verdict(failures, restore_ok):
    """Return ``(lines, exit_code)`` separating assertions from keyd restore.

    ``RESULT=`` only reflects the assertion failures; ``SERVICE_RESTORE=`` is an
    independent keyboard-service health signal. This keeps a run that passed
    every assertion but left keyd stopped from claiming full success.
    """
    if failures:
        return (
            [
                f"ASSERTIONS=FAIL ({', '.join(failures)})",
                f"RESULT=FAIL {failures}",
                f"SERVICE_RESTORE={'PASS' if restore_ok else 'FAIL'}",
            ],
            1,
        )
    if restore_ok:
        return (["ASSERTIONS=PASS", "SERVICE_RESTORE=PASS", "RESULT=PASS"], 0)
    return (
        [
            "ASSERTIONS=PASS",
            "SERVICE_RESTORE=FAIL",
            "RESULT=PASS (assertions only; keyd restore FAILED — run sudo systemctl restart keyd manually)",
        ],
        2,
    )


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


def press(ui, code, hold=0.05):
    ui.write(e.EV_KEY, code, 1)
    ui.syn()
    time.sleep(hold)
    ui.write(e.EV_KEY, code, 0)
    ui.syn()


def run_self_test():
    """Verify the value 1/0 pairing assertions with synthetic events.

    No root, evdev or device needed. Events are ``(name, value)`` tuples,
    exactly like ``collect()`` produces.
    """
    def seq(key, values):
        return [(key, v) for v in values]

    failures = []
    results = []

    def expect(label, check, events, want):
        ok, detail = check(events)
        results.append((label, ok, detail))
        if ok != want:
            failures.append(
                f"{label}: expected {'PASS' if want else 'FAIL'}, "
                f"got {'PASS' if ok else 'FAIL'} ({detail})"
            )

    # 1. tap Search: name appearance alone is not enough.
    expect("tap [1] only down", check_tap, seq("KEY_CAPSLOCK", [1]), False)
    expect("tap [1,1] repeated down", check_tap, seq("KEY_CAPSLOCK", [1, 1]), False)
    expect("tap [1,2] repeat, no up", check_tap, seq("KEY_CAPSLOCK", [1, 2]), False)
    expect("tap [1,2,0]", check_tap, seq("KEY_CAPSLOCK", [1, 2, 0]), True)
    expect("tap [0,1,0] leading reset", check_tap, seq("KEY_CAPSLOCK", [0, 1, 0]), True)
    expect("tap with LEFTCTRL guard", check_tap,
           seq("KEY_CAPSLOCK", [1, 2, 0]) + seq("KEY_LEFTCTRL", [1, 0]), False)
    expect("tap with RIGHTCTRL guard", check_tap,
           seq("KEY_CAPSLOCK", [1, 2, 0]) + seq("KEY_RIGHTCTRL", [1, 0]), False)
    expect("tap with RIGHTMETA guard", check_tap,
           seq("KEY_CAPSLOCK", [1, 2, 0]) + seq("KEY_RIGHTMETA", [1, 0]), False)
    expect("tap with non-target reset 0", check_tap,
           seq("KEY_CAPSLOCK", [1, 2, 0]) + [("KEY_BACK", 0)], True)

    # 2. hold Search + top-row key -> expected F-key. The meta layer holds
    # LEFTMETA, so that modifier is allowed but a CTRL guard is not.
    hold_f1 = lambda ev: check_hold(ev, "KEY_F1")
    expect("hold [1] only down", hold_f1, seq("KEY_F1", [1]), False)
    expect("hold [1,2,0]", hold_f1, seq("KEY_F1", [1, 2, 0]), True)
    expect("hold with LEFTMETA layer down", hold_f1,
           seq("KEY_F1", [1, 2, 0]) + seq("KEY_LEFTMETA", [1, 0]), True)
    expect("hold with LEFTCTRL guard", hold_f1,
           seq("KEY_F1", [1, 2, 0]) + seq("KEY_LEFTCTRL", [1, 0]), False)
    expect("hold with RIGHTMETA guard", hold_f1,
           seq("KEY_F1", [1, 2, 0]) + seq("KEY_RIGHTMETA", [1, 0]), False)
    expect("hold with non-target reset 0", hold_f1,
           seq("KEY_F1", [1, 2, 0]) + [("KEY_BACK", 0)], True)

    # 3. top-row key alone -> its own media key.
    media_back = lambda ev: check_media(ev, "KEY_BACK")
    expect("media [1] only down", media_back, seq("KEY_BACK", [1]), False)
    expect("media [1,2,0]", media_back, seq("KEY_BACK", [1, 2, 0]), True)
    expect("media stray non-mod down", media_back,
           seq("KEY_BACK", [1, 2, 0]) + seq("KEY_F1", [1, 0]), False)
    expect("media with modifier guard", media_back,
           seq("KEY_BACK", [1, 2, 0]) + seq("KEY_RIGHTCTRL", [1, 0]), False)

    # 4. hold Search, release alone -> bare META, no guard.
    expect("lone [1,1,0]", check_lone, seq("KEY_LEFTMETA", [1, 1, 0]), False)
    expect("lone [1,0,1]", check_lone, seq("KEY_LEFTMETA", [1, 0, 1]), False)
    expect("lone with LEFTCTRL guard", check_lone,
           seq("KEY_LEFTMETA", [1, 2, 0]) + seq("KEY_LEFTCTRL", [1, 0]), False)
    expect("lone with RIGHTMETA guard", check_lone,
           seq("KEY_LEFTMETA", [1, 2, 0]) + seq("KEY_RIGHTMETA", [1, 0]), False)
    expect("lone with RIGHTCTRL guard", check_lone,
           seq("KEY_LEFTMETA", [1, 2, 0]) + seq("KEY_RIGHTCTRL", [1, 0]), False)
    expect("lone [1,2,0]", check_lone, seq("KEY_LEFTMETA", [1, 2, 0]), True)

    # 5. Composite verdict: assertion health (RESULT=) and keyd restore health
    #    (SERVICE_RESTORE=) are independent, with distinct exit codes.
    for label, assertions, restore_in, want_code, want_lines in (
        ("verdict pass + restore pass", [], True, 0, ("SERVICE_RESTORE=PASS", "RESULT=PASS")),
        ("verdict pass + restore fail", [], False, 2, ("SERVICE_RESTORE=FAIL", "RESULT=PASS")),
        ("verdict assertions fail", ["tap"], True, 1, ("ASSERTIONS=FAIL", "RESULT=FAIL")),
    ):
        lines, code = final_verdict(assertions, restore_in)
        joined = "\n".join(lines)
        ok = code == want_code and all(s in joined for s in want_lines)
        detail = f"exit={code}, lines={lines}"
        results.append((label, ok, detail))
        if not ok:
            failures.append(f"{label}: expected exit {want_code} with {want_lines}, got {detail}")

    # Direct helper checks (repeat filtering / leading-reset tolerance /
    # restore detection). These are not part of the pairing case count.
    if values_for(seq("KEY_A", [1, 2, 2, 0]), "KEY_A") != [1, 0]:
        failures.append("values_for() must drop autorepeat (value 2)")
    if not clean_press([0, 0, 1, 2, 0, 0]):
        failures.append("clean_press() must tolerate leading/trailing resets and repeat")
    if not keyd_restore_ok(0) or keyd_restore_ok(1):
        failures.append("keyd_restore_ok() must be True only for returncode 0")
    # An assertion failure stays exit 1 even when restore also fails.
    lines, code = final_verdict(["tap"], False)
    if code != 1 or not any("RESULT=FAIL" in line for line in lines):
        failures.append(f"final_verdict(['tap'], False) must still exit 1: {lines} / {code}")

    print("self-test: synthetic EV_KEY value 1/0 pairing and verdict (no device needed)")
    for label, ok, detail in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if failures:
        for msg in failures:
            print(f"FAIL: {msg}")
        print("SELF-TEST=FAIL")
        return 1
    print(f"SELF-TEST=PASS ({len(results)} cases)")
    return 0


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Live functional test for the keyd dual-role Search key via uinput.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  sudo ...py                 live test (needs root + python3-evdev)\n"
            "  ...py --self-test          synthetic 1/0 pairing check, no root/device needed\n"
        ),
    )
    parser.add_argument(
        "--self-test", action="store_true",
        help="run a synthetic-event self-test (no root, evdev or device needed) and exit",
    )
    return parser.parse_args(argv)


def run_checks(ui, kd, failures):
    """Run the assertion body against the live keyd virtual keyboard.

    ``failures`` is the single source of truth for assertion failures. This
    function never prints a verdict, so every path (including a missing keyd
    device) flows to main()'s unified final_verdict().
    """
    top_row = build_top_row()
    print(f"started {time.strftime('%Y-%m-%d %H:%M:%S')}")
    if kd is None:
        print("FAIL: keyd virtual keyboard not found (is keyd running?)")
        failures.append("keyd-not-found")
        return
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
    # META plus the LEFTCTRL guard here, so check the raw names AND require
    # a clean CAPSLOCK down/up pair.
    press(ui, e.KEY_LEFTMETA, hold=0.05)
    ok, detail = check_tap(collect_checked(kd, 0.6, "tap Search", failures))
    if ok:
        print(f"PASS: tap Search -> CAPSLOCK only (no META, no guard) {detail}")
    else:
        print(f"FAIL: tap Search expected CAPSLOCK only (one down/up), got {detail}")
        failures.append("tap")

    # 2. hold Search + each top-row key -> F1 ... F10.
    for label, code, expected in top_row:
        ui.write(e.EV_KEY, e.KEY_LEFTMETA, 1)
        ui.syn()
        time.sleep(0.6)  # exceed the tap timeout and enter the meta layer
        press(ui, code)
        ui.write(e.EV_KEY, e.KEY_LEFTMETA, 0)
        ui.syn()
        ok, detail = check_hold(
            collect_checked(kd, 0.7, f"hold Search + {label}", failures), expected
        )
        if ok:
            print(f"PASS: hold Search + {label} -> {expected} {detail}")
        else:
            print(f"FAIL: hold Search + {label} expected only {expected} (one down/up), got {detail}")
            failures.append(f"hold-{expected.lower()}")

    # 3. each top-row key alone -> its own media key (pass-through).
    for label, code, _expected in top_row:
        press(ui, code)
        own = key_name(code)
        ok, detail = check_media(collect_checked(kd, 0.6, f"{label} alone", failures), own)
        if ok:
            print(f"PASS: {label} alone -> {own} {detail}")
        else:
            print(f"FAIL: {label} alone expected {own} (one down/up, no stray down), got {detail}")
            failures.append(f"media-{label.lower().split()[0]}")

    # 4. hold Search and release it alone -> clean lone META, no LEFTCTRL.
    # keyd's clear_mod() guard would otherwise turn this into Meta+Ctrl and
    # Mutter would not treat it as the overlay key (no GNOME overview).
    ui.write(e.EV_KEY, e.KEY_LEFTMETA, 1)
    ui.syn()
    time.sleep(0.6)
    ui.write(e.EV_KEY, e.KEY_LEFTMETA, 0)
    ui.syn()
    ok, detail = check_lone(collect_checked(kd, 0.8, "hold Search alone, release", failures))
    if ok:
        print(f"PASS: hold Search alone -> bare META release (no guard) {detail}")
    else:
        print(f"FAIL: hold Search alone expected a META release without LEFTCTRL guard, got {detail}")
        failures.append("hold-meta-clean")


def main(argv=None):
    args = parse_args(argv)
    # --self-test returns before the root / evdev / device checks so CI (and a
    # developer machine without python3-evdev) can run it.
    if args.self_test:
        return run_self_test()

    if os.geteuid() != 0:
        print("FAIL: keyd-dualrole-uinput.py requires root permissions (run with sudo)")
        return 1
    if evdev is None:
        print("FAIL: python3-evdev is missing; install it with: sudo apt install python3-evdev")
        return 1

    keys = build_keys()

    ui = None
    try:
        ui = UInput(
            {e.EV_KEY: keys},
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
        # to restore it, and report that health signal separately from the
        # failed setup (which always returns 1).
        restore_ok = restore_keyd()
        print(f"SERVICE_RESTORE={'PASS' if restore_ok else 'FAIL'}")
        close_quietly(ui)
        return 1

    failures = []
    kd = None
    restore_ok = False
    try:
        kd = find_keyd()
        run_checks(ui, kd, failures)
    finally:
        # Close devices on every path (including exceptions), using a quiet
        # close so cleanup errors cannot mask the real result. Close order is
        # kd -> ui -> restart: the virtual device must be gone before keyd
        # re-scans. Restore is a separate health signal from the assertions.
        close_quietly(kd)
        close_quietly(ui)
        restore_ok = restore_keyd()

    lines, code = final_verdict(failures, restore_ok)
    for line in lines:
        print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
