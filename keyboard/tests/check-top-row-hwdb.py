#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Check the AT keyboard scancode -> keycode map against the hwdb fixture.

This script has three distinct capabilities. They are easy to confuse, so read
this carefully before drawing conclusions about what the firmware sends:

  1. (default) EVIOCGKEYCODE table check -- read-only ioctl. For every scancode
     in ``hwdb-top-row-scancodes.tsv``, compare the kernel's current scancode
     -> keycode translation with the expected hwdb key name. This proves the
     *kernel/udev side* is set up correctly, not what the hardware emitted.
     With ``--device PATH`` and no ``--listen``/``--scan`` this table check is
     performed directly on PATH via ``os.open()`` and does not require
     python3-evdev at all.

  2. ``--listen SECONDS`` -- polls EVIOCGKEY and prints **post-hwdb KEY_*
     state** (keycodes after udev translation). It never sees the raw
     scancode, so it cannot tell 0xea from 0x3b.

  3. ``--scan SECONDS`` -- reads the device's event stream non-exclusively and
     prints raw ``EV_MSC/MSC_SCAN`` values (exactly what udev
     ``KEYBOARD_KEY_*`` matches) alongside the post-hwdb ``EV_KEY`` names.
     This is the mode to use when you want to know whether a key press really
     sends 0xea or 0x3b.

None of the modes call EVIOCGRAB, so the desktop keeps working. However, keyd
grabs the *physical* AT keyboard exclusively; while it holds that grab, no
other reader (including --scan and plain evtest) can observe its MSC_SCAN
events. To capture raw scancodes, stop keyd first, run the capture on a TTY or
with the desktop input otherwise unused, then restore the service:

  sudo systemctl stop keyd      # input will briefly not be remapped
  sudo python3 keyboard/tests/check-top-row-hwdb.py --scan 20
  sudo systemctl start keyd     # restore

Usage:
  sudo python3 keyboard/tests/check-top-row-hwdb.py
  sudo python3 keyboard/tests/check-top-row-hwdb.py --listen 15
  sudo python3 keyboard/tests/check-top-row-hwdb.py --scan 20
  sudo python3 keyboard/tests/check-top-row-hwdb.py --device /dev/input/event2 --scan 20
  sudo python3 keyboard/tests/check-top-row-hwdb.py --device /dev/input/event2  # table only, no evdev needed
  python3 keyboard/tests/check-top-row-hwdb.py --self-test   # no device needed

``--fixture PATH`` overrides the scancode/key TSV (used by detect-hardware.sh).

Exit status: 0 all expected mappings present (and self-test passed), 1
otherwise. Prints RESULT=PASS or RESULT=FAIL on stdout for the table check.
A missing fixture or an unavailable EVIOCGKEYCODE ioctl prints FAIL with NO
RESULT line, so callers (detect-hardware.sh) treat it as inconclusive.
"""
import argparse
import fcntl
import glob
import math
import os
import select
import struct
import sys
import time

try:
    import evdev
    from evdev import InputDevice, ecodes as e
except ImportError:
    # Defer the failure so --help / --self-test / argument validation still
    # work on a machine without python3-evdev.
    evdev = None
    InputDevice = None
    e = None

AT_KEYBOARD_NAME = "AT Translated Set 2 keyboard"
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hwdb-top-row-scancodes.tsv")
EVIOCGKEYCODE = 0x80084504

# Stable Linux input-event-code numbers. Used by --scan and by --self-test so
# the formatting logic stays testable even when python3-evdev is not installed.
EV_KEY = 1
EV_MSC = 4
MSC_SCAN = 4
EV_SYN = 0       # 0x00 (== e.EV_SYN); 3 is EV_ABS, NOT EV_SYN
EV_ABS = 3       # 0x03; used by --self-test to prove code=3 alone is not SYN_DROPPED
SYN_DROPPED = 3  # 0x03 SYN_* code value, only meaningful when type == EV_SYN
KEY_BACK = 158
# Stable Linux input-event-code numbers (linux/input-event-codes.h). They let
# the pure EVIOCGKEYCODE table check run without python3-evdev installed, which
# is the mode detect-hardware.sh delegates to. Keep in sync with evdev.ecodes.
_FALLBACK_KEY_CODES = {
    "BACK": 158,
    "FORWARD": 159,
    "REFRESH": 173,
    "F11": 87,
    "SCALE": 120,
    "BRIGHTNESSDOWN": 224,
    "BRIGHTNESSUP": 225,
    "MUTE": 113,
    "VOLUMEDOWN": 114,
    "VOLUMEUP": 115,
    "LEFTMETA": 125,
}
_FALLBACK_KEY_NAMES = {code: f"KEY_{name}" for name, code in _FALLBACK_KEY_CODES.items()}
_KEY_STATE_NAMES = {0: "up", 1: "down", 2: "repeat"}

KEYD_HINT = (
    "no MSC_SCAN observed — is the device grabbed by keyd? Stop it with "
    "`sudo systemctl stop keyd`, retry, then restore the service"
)


def find_at_keyboard():
    permission_denied = False
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            dev = InputDevice(path)
        except PermissionError:
            permission_denied = True
            continue
        except OSError:
            continue
        if dev.name == AT_KEYBOARD_NAME:
            return dev
        dev.close()
    if permission_denied:
        raise PermissionError("Insufficient permissions to read /dev/input/event* (run with sudo)")
    return None


def expected_keycode(name):
    """hwdb key name (back) -> KEY_BACK code; works without evdev too."""
    if evdev is not None:
        code = getattr(e, "KEY_" + name.upper(), None)
    else:
        code = _FALLBACK_KEY_CODES.get(name.upper())
    if code is None:
        raise SystemExit(f"FAIL: unknown hwdb key name {name!r} in {FIXTURE}")
    return code


def key_name(code):
    """Return one readable name per keycode (evdev aliases are tuples)."""
    if evdev is not None:
        name = evdev.ecodes.KEY.get(code, code)
        if isinstance(name, tuple):
            name = next((n for n in name if n != "KEY_MIN_INTERESTING"), name[0])
        return str(name)
    return _FALLBACK_KEY_NAMES.get(code, f"KEY_{code}")


def format_scan_event(ev):
    """Format one raw input event for --scan; return None if uninteresting.

    ``ev`` only needs ``type``, ``code`` and ``value`` attributes, so synthetic
    events can be passed in by --self-test. EV_MSC/MSC_SCAN carries the raw
    scancode (what udev KEYBOARD_KEY_* matches); EV_KEY is the post-hwdb name.
    EV_SYN/SYN_DROPPED (type=0, code=3) is warned about here; EV_ABS/code=3 is
    deliberately NOT, because the event *type* is what distinguishes them.
    """
    if ev.type == EV_SYN and ev.code == SYN_DROPPED:
        return "!!! SYN_DROPPED (events lost)"
    if ev.type == EV_MSC and ev.code == MSC_SCAN:
        return f"MSC_SCAN=0x{ev.value:02x}"
    if ev.type == EV_KEY:
        return f"{key_name(ev.code)} {_KEY_STATE_NAMES.get(ev.value, ev.value)}"
    return None


def format_listen_state(code, down):
    """Format a --listen key transition: post-hwdb KEY_* state only.

    Deliberately does not take a scancode argument: --listen reads EVIOCGKEY,
    which cannot observe raw MSC_SCAN values.
    """
    return f"{key_name(code)} {'down' if down else 'up'}"


def keyd_hint(saw_scan):
    """Return the keyd-grab warning when --scan saw no MSC_SCAN, else None."""
    return None if saw_scan else KEYD_HINT


def read_fixture(path=FIXTURE):
    rows = []
    with open(path, encoding="utf-8") as handle:
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
                raise SystemExit(f"FAIL: bad scancode {sc!r} in {path}") from None
            label = " ".join(f.strip() for f in fields[2:] if f.strip())
            rows.append((scancode, key, label))
    return rows


def get_keycode(fd, scancode):
    out = fcntl.ioctl(fd, EVIOCGKEYCODE, struct.pack("ii", scancode, 0))
    _sc, code = struct.unpack("ii", out)
    return code


def listen(dev, seconds):
    """Poll EVIOCGKEY: post-hwdb KEY_* state, NOT raw scancodes."""
    print(f"listening on {dev.path} (phys {dev.phys}) for {seconds:g}s "
          "(post-hwdb KEY_* state, NOT raw scancodes)", flush=True)
    print("raw scancodes require --scan (with keyd stopped) or plain evtest (no --grab)", flush=True)
    prev = set()
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        cur = set(dev.active_keys())
        for code in sorted(cur - prev):
            print(f"{time.strftime('%H:%M:%S')} {format_listen_state(code, True)}", flush=True)
        for code in sorted(prev - cur):
            print(f"{time.strftime('%H:%M:%S')} {format_listen_state(code, False)}", flush=True)
        prev = cur
        time.sleep(0.03)


def scan(dev, seconds):
    """Read dev's event stream non-exclusively; never call EVIOCGRAB.

    Prints raw MSC_SCAN values and post-hwdb EV_KEY names, bounded by a
    monotonic deadline. If no MSC_SCAN is observed, print an explicit keyd
    grab hint instead of failing silently.
    """
    print(f"scanning {dev.path} (phys {dev.phys}) for {seconds:g}s "
          "(raw MSC_SCAN + post-hwdb EV_KEY, NO EVIOCGRAB)", flush=True)
    print("press a top-row key now; MSC_SCAN is the raw value udev KEYBOARD_KEY_* matches", flush=True)
    end = time.monotonic() + seconds
    saw_scan = False
    saw_key = False
    try:
        while time.monotonic() < end:
            timeout = max(0.0, end - time.monotonic())
            ready, _, _ = select.select([dev.fd], [], [], timeout)
            if not ready:
                continue
            try:
                events = dev.read()
            except OSError as exc:
                print(f"{dev.path} read failed: {exc}", flush=True)
                break
            for ev in events:
                line = format_scan_event(ev)
                if line is None:
                    continue
                if ev.type == EV_MSC and ev.code == MSC_SCAN:
                    saw_scan = True
                elif ev.type == EV_KEY:
                    saw_key = True
                print(f"{time.strftime('%H:%M:%S')} {line}", flush=True)
    except KeyboardInterrupt:
        print("stopped", flush=True)
    hint = keyd_hint(saw_scan)
    if hint:
        print(hint, flush=True)
    if not saw_scan and not saw_key:
        print("(no key events observed either — press a key during the window)", flush=True)


def run_self_test():
    """Verify --scan shows raw 0xea while --listen only shows KEY_BACK.

    Synthetic events: a physical press first emits EV_MSC/MSC_SCAN=0xea, then
    the hwdb-translated EV_KEY=KEY_BACK. No real device (or evdev) needed.
    Also synthesize a real EV_SYN/SYN_DROPPED (must warn) and an EV_ABS/code=3
    (must NOT warn), because the SYN_DROPPED code (3) collides with EV_ABS (3)
    and only the event *type* tells them apart.
    """
    class _Event:
        def __init__(self, etype, code, value):
            self.type, self.code, self.value = etype, code, value

    events = [
        _Event(EV_MSC, MSC_SCAN, 0xea),   # raw scancode from the hardware
        _Event(EV_KEY, KEY_BACK, 1),      # post-hwdb keycode seen by EVIOCGKEY
        _Event(EV_KEY, KEY_BACK, 0),
        _Event(EV_SYN, SYN_DROPPED, 0),   # type=0, code=3: real SYN_DROPPED
        _Event(EV_ABS, 3, 0),             # type=3, code=3: must NOT be misreported
    ]
    scan_lines = []
    for ev in events:
        line = format_scan_event(ev)
        if line is not None:
            scan_lines.append(line)
    listen_lines = [format_listen_state(KEY_BACK, True), format_listen_state(KEY_BACK, False)]

    failures = []
    if not any("MSC_SCAN=0xea" in line for line in scan_lines):
        failures.append("--scan must print the raw MSC_SCAN=0xea")
    if not any("KEY_BACK down" in line for line in scan_lines):
        failures.append("--scan must print the post-hwdb KEY_BACK down")
    if "KEY_BACK up" not in scan_lines:
        failures.append("--scan must print the KEY_BACK up transition")
    if not any("SYN_DROPPED" in line for line in scan_lines):
        failures.append("--scan must warn on EV_SYN/SYN_DROPPED (type=0, code=3)")
    if sum("SYN_DROPPED" in line for line in scan_lines) != 1:
        failures.append("--scan must warn exactly once (EV_ABS/code=3 must not false-positive)")
    if format_scan_event(_Event(EV_ABS, 3, 0)) is not None:
        failures.append("EV_ABS/code=3 must be ignored, not reported as SYN_DROPPED")
    if any("MSC_SCAN" in line or "0xea" in line for line in listen_lines):
        failures.append("--listen must NOT print raw scancodes")
    if "KEY_BACK down" not in listen_lines or "KEY_BACK up" not in listen_lines:
        failures.append("--listen prints only post-hwdb KEY_* transitions")
    if keyd_hint(False) != KEYD_HINT or keyd_hint(True) is not None:
        failures.append("keyd hint must appear only when no MSC_SCAN was observed")

    print("self-test: synthetic 0xea press -> hwdb KEY_BACK")
    for line in scan_lines:
        print(f"  --scan   {line}")
    for line in listen_lines:
        print(f"  --listen {line}")
    if failures:
        for msg in failures:
            print(f"FAIL: {msg}")
        print("SELF-TEST=FAIL")
        return 1
    print("SELF-TEST=PASS (scan shows raw 0xea; listen shows only KEY_BACK)")
    return 0


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Check AT keyboard scancode->keycode mappings (EVIOCGKEYCODE) against the hwdb fixture.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  sudo ...py                         EVIOCGKEYCODE table check only\n"
            "  sudo ...py --listen 15             post-hwdb KEY_* state (NOT raw scancodes)\n"
            "  sudo ...py --scan 20               raw MSC_SCAN + EV_KEY (stop keyd first)\n"
            "  ...py --self-test                  synthetic-event check, no device needed\n"
            "  ...py --device EVENT --fixture TSV table check with an explicit fixture\n"
        ),
    )
    parser.add_argument(
        "--fixture", metavar="PATH", default=FIXTURE,
        help=f"scancode/key TSV to compare against (default: {FIXTURE})",
    )
    parser.add_argument(
        "--device", metavar="PATH",
        help=f"event node to check (default: auto-detect {AT_KEYBOARD_NAME!r}); "
             "a table-only check opens PATH directly (no python3-evdev needed); "
             "with --listen/--scan, dev.path and dev.phys are printed for identification",
    )
    parser.add_argument(
        "--listen", type=float, metavar="SECONDS",
        help="after the table check, poll EVIOCGKEY key state for SECONDS; "
             "this is post-hwdb KEY_* state, NOT raw scancodes",
    )
    parser.add_argument(
        "--scan", type=float, metavar="SECONDS",
        help="after the table check, read raw EV_MSC/MSC_SCAN and EV_KEY events "
             "non-exclusively for SECONDS (stop keyd first: sudo systemctl stop keyd)",
    )
    parser.add_argument(
        "--self-test", action="store_true",
        help="run a synthetic-event self-test (no real device needed) and exit",
    )
    args = parser.parse_args(argv)
    for name in ("listen", "scan"):
        value = getattr(args, name)
        if value is None:
            continue
        if value < 0:
            print(f"FAIL: --{name} must be >= 0 (got {value})", file=sys.stderr)
            raise SystemExit(1)
        if not math.isfinite(value):
            print(f"FAIL: --{name} must be finite (got {value})", file=sys.stderr)
            raise SystemExit(1)
    return args


def run_table_check(fd, path, fixture_path, ident):
    """Print and run the read-only EVIOCGKEYCODE table check; return failures."""
    print(f"{path}{ident}")
    print(f"{'scancode':8s} {'hwdb key':16s} {'expected':<20s} {'kernel':<20s} result")
    failures = 0
    for scancode, key, label in read_fixture(fixture_path):
        want = expected_keycode(key)
        got = get_keycode(fd, scancode)
        ok = got == want
        failures += 0 if ok else 1
        print(f"0x{scancode:02x}     {key:16s} {key_name(want):<20s} {key_name(got):<20s} "
              f"{'OK' if ok else 'MISMATCH'}  # {label}")
    return failures


def main(argv=None):
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()
    print(f"started {time.strftime('%Y-%m-%d %H:%M:%S')}")

    # Only --listen/--scan/auto-detect need InputDevice. A --device table check
    # can open the event node directly, so it works without python3-evdev.
    need_input_device = args.listen is not None or args.scan is not None or not args.device
    if need_input_device and evdev is None:
        print("FAIL: python3-evdev is missing; install it with: sudo apt install python3-evdev")
        return 1

    dev = None
    if need_input_device:
        if args.device:
            try:
                dev = InputDevice(args.device)
            except PermissionError:
                print("FAIL: Insufficient permissions to read /dev/input/event* (run with sudo)")
                return 1
            except OSError as exc:
                print(f"FAIL: cannot open {args.device}: {exc}")
                return 1
            if dev.name != AT_KEYBOARD_NAME:
                print(f"WARN: {dev.path} is {dev.name!r}, not {AT_KEYBOARD_NAME!r}")
        else:
            try:
                dev = find_at_keyboard()
            except PermissionError as exc:
                print(f"FAIL: {exc}")
                return 1
            if dev is None:
                print(f"FAIL: {AT_KEYBOARD_NAME!r} not found")
                return 1
        path = dev.path
        ident = f": {dev.name} (phys {dev.phys})"
    else:
        # Pure --device table check: deliberately no InputDevice/name probe so
        # this path works without python3-evdev (detect-hardware.sh uses it).
        path = args.device
        ident = " (EVIOCGKEYCODE table check; python3-evdev not required)"

    try:
        fd = os.open(path, os.O_RDONLY)
    except PermissionError:
        print(f"FAIL: cannot read {path} (EVIOCGKEYCODE needs root); re-run with sudo")
        return 1
    failures = 0
    try:
        failures = run_table_check(fd, path, args.fixture, ident)
    except FileNotFoundError as exc:
        # A missing --fixture TSV is not an ioctl failure. Still no RESULT line
        # is printed, so callers treat this as inconclusive rather than PASS.
        print(f"FAIL: fixture unavailable ({args.fixture}): {exc}")
        return 1
    except OSError as exc:
        # e.g. not an event node, or the ioctl is unavailable: no RESULT line
        # is printed, so callers treat this as inconclusive rather than PASS.
        print(f"FAIL: EVIOCGKEYCODE unavailable on {path}: {exc}")
        return 1
    finally:
        os.close(fd)

    if dev is not None:
        if args.listen:
            listen(dev, args.listen)
        if args.scan:
            scan(dev, args.scan)
        dev.close()

    if failures:
        print(f"RESULT=FAIL ({failures} scancode(s) not mapped as expected)")
        print("Reinstall with: sudo ./keyboard/install-keyboard.sh --with-keyd")
        print(f"then check:     udevadm info {path} | grep KEYBOARD_KEY")
        return 1
    print("RESULT=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
