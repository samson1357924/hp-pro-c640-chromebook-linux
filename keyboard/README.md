[English](README.md) | [繁體中文](README.zh-TW.md)

# Keyboard Top-Row Mapping (HP Pro c640 Chromebook)

ChromeOS devices feature dedicated top-row action keys instead of traditional
F1-F12 keys. Under standard Linux, these keys can be remapped either at the
kernel/hardware level using `systemd-hwdb` or at the input daemon level using
`keyd`.

---

## 🎹 Top-Row Key Mapping Reference

| Physical Position | ChromeOS Icon | AT Scancode | Linux hwdb Keycode | Recommended Function |
| :--- | :--- | :--- | :--- | :--- |
| **Top 1 (F1)** | ◀ (Back) | `KEYBOARD_KEY_ea` | `KEY_BACK` | Browser / App Back |
| **Top 2 (F2)** | ▶ (Forward) | `KEYBOARD_KEY_e9` | `KEY_FORWARD` | Browser / App Forward |
| **Top 3 (F3)** | ⟳ (Refresh) | `KEYBOARD_KEY_e7` | `KEY_REFRESH` | Page Reload |
| **Top 4 (F4)** | ⛶ (Fullscreen) | `KEYBOARD_KEY_91` | `KEY_F11` | Toggle Fullscreen |
| **Top 5 (F5)** | ⧉ (Overview) | `KEYBOARD_KEY_92` | `KEY_SCALE` | GNOME / Desktop Task Switcher |
| **Top 6 (F6)** | 🔅 (Brightness Down) | `KEYBOARD_KEY_ee` | `KEY_BRIGHTNESSDOWN` | Decrease Display Backlight |
| **Top 7 (F7)** | 🔆 (Brightness Up) | `KEYBOARD_KEY_ef` | `KEY_BRIGHTNESSUP` | Increase Display Backlight |
| **Top 8 (F8)** | 🔇 (Mute) | `KEYBOARD_KEY_a0` | `KEY_MUTE` | Audio Mute |
| **Top 9 (F9)** | 🔉 (Volume Down) | `KEYBOARD_KEY_ae` | `KEY_VOLUMEDOWN` | Decrease Audio Volume |
| **Top 10 (F10)** | 🔊 (Volume Up) | `KEYBOARD_KEY_b0` | `KEY_VOLUMEUP` | Increase Audio Volume |
| **Search / Launcher** | 🔍 (Search) | `KEYBOARD_KEY_db` | `KEY_LEFTMETA` | Super (Meta) or CapsLock |

---

## 🛠️ Implementation Options

### Option 1: systemd-hwdb (Recommended & Default)

Zero daemon overhead, low latency, native kernel input mapping.

```bash
chmod +x keyboard/install-keyboard.sh
./keyboard/install-keyboard.sh
```

**Options**:

* `./keyboard/install-keyboard.sh --check` : Check if hwdb is deployed.
* `./keyboard/install-keyboard.sh --dry-run` : Preview operations.
* `./keyboard/install-keyboard.sh --uninstall` : Revert hwdb changes.

---

### Option 2: `keyd` Daemon (Advanced Multi-Layer & Dual-Role)

If you want the **Search key** to act as **CapsLock on tap** and **Super/Meta
on hold**, or want `Search + Top-Row` to produce classic `F1-F10`:

> **Prerequisite:** Option 1 `systemd-hwdb` must be installed first. `keyd` relies on
> hwdb having translated `0xEA/0xE9/0xE7/0x91/0x92/0xEE/0xEF/0xA0/0xAE/0xB0/0xDB` to
> `KEY_BACK`/`KEY_LEFTMETA` etc; `cros.conf` uses those names (`back`, `leftmeta`).
> Recommended: `sudo ./keyboard/install-keyboard.sh --with-keyd` (installs hwdb+backlight+keyd atomically).

1. Install `keyd` (pinned to v2.6.0, hash `7c0aecb8bfd34dc8642bf4eefd2e59c89e61cec3` in CI):

   ```bash
   # Ubuntu 25.04+ / Debian 13+ (native)
   sudo apt update && sudo apt install -y keyd

   # Ubuntu 22.04/24.04 or Debian 12 (PPA)
   sudo add-apt-repository ppa:keyd-team/ppa -y
   sudo apt update && sudo apt install -y keyd
   # or build from source pinned:
   git clone --depth 1 --branch v2.6.0 https://github.com/rvaiya/keyd /tmp/keyd
   test "$(git -C /tmp/keyd rev-parse HEAD)" = "7c0aecb8bfd34dc8642bf4eefd2e59c89e61cec3"
   make -C /tmp/keyd && sudo make -C /tmp/keyd install

   # Fedora (COPR)
   sudo dnf copr enable alternateved/keyd -y
   sudo dnf install -y keyd

   # Arch Linux (extra)
   sudo pacman -S keyd

   # NixOS
   # services.keyd.enable = true;  # plus environment.etc."keyd/cros.conf".source = ./keyboard/keyd/cros.conf
   ```

   > **Package name differs by distro (verified on Ubuntu 26.04):** the Debian/Ubuntu
   > package installs **`/usr/bin/keyd.rvaiya`** (version 2.5.0-5), not
   > `/usr/bin/keyd`; the systemd unit is still called `keyd`. Use whichever
   > exists, e.g. `keyd.rvaiya --version`. The installer auto-detects it through
   > `keyd_bin()` in `lib/syscheck.sh`. Also, **`keyd check` only exists in
   > keyd >= 2.6** - on 2.5.x it just prints usage and exits 0.

2. Install configuration (via installer, recommended):

   ```bash
   sudo ./keyboard/install-keyboard.sh --with-keyd
   # equivalent manual:
   # sudo install -D -m 0644 keyboard/keyd/cros.conf /etc/keyd/cros.conf
   # sudo ln -sf cros.conf /etc/keyd/default.conf
   # keyd check /etc/keyd/cros.conf     # only keyd >= 2.6; 2.5.x validates on start
   # sudo systemctl enable keyd
   # sudo systemctl restart keyd         # keyd 2.5.x reads config only at start-up
   ```

3. Verify & tune:

   ```bash
   keyd --version || keyd.rvaiya --version   # Ubuntu 26.04 ships keyd.rvaiya
   sudo keyd monitor || sudo keyd.rvaiya monitor
   # short press Search -> capslock ; long hold -> leftmeta ; Search+TopRow -> F1
   sudo systemctl status keyd
   journalctl -eu keyd -f
   # If tap vs hold is too sensitive, add to /etc/keyd/cros.conf [global]:
   # overload_tap_timeout = 200  # ms, see man keyd
   # sudo systemctl restart keyd
   ```

   **GNOME Wayland trackpad quirk** (optional, fixes `disable-while-typing` stall):

   ```bash
   sudo mkdir -p /etc/libinput
   printf '[Keyd]\nMatchName=keyd virtual keyboard\nAttrKeyboardIntegration=internal\n' | sudo tee /etc/libinput/local-overrides.quirks > /dev/null
   ```

    **Notes:**
    * `[ids] 0001:0001` scopes `cros.conf` to the internal AT keyboard. The wildcard
      `*` also grabs the ChromeOS `Video Bus` (`0000:0006`) and every external USB
      keyboard, which duplicates brightness handling and swallows external keys.
      Add an external keyboard by ID from `sudo keyd monitor` if you want it remapped too.
    * **Tap produces a short `leftmeta` + `leftctrl` pair before `capslock`** on
      keyd 2.5.x. That is keyd's modifier guard (`clear_mod()` in `src/keyboard.c`):
      it stops GNOME from interpreting the bare Meta press as an Activities shortcut.
      It is expected; assert on `KEY_CAPSLOCK` when scripting a test.
    * keyd 2.5.x has no hot-plug device detection: after changing `/etc/keyd/*.conf`
      you must `sudo systemctl restart keyd` (a `reload` only re-parses config for
      already-grabbed devices).
    * `X11` users: `setxkbmap` is reset on `keyd restart`; reapply after.
    * `TTY` works via `uinput`; panic: `backspace+escape+enter` if config locks you out.

---

### Option 3: Keyboard Backlight Sync with Screen Blank

Automatically turns off the keyboard backlight when the screen blanks/locks
and restores it when the screen lights up. Handles both GNOME Wayland idle
(`org.gnome.ScreenSaver` + `org.freedesktop.login1 PrepareForSleep` for S3 lid)
and the ChromeOS EC `cros_kbd_led_backlight` (`/sys/class/leds/chromeos::kbd_backlight`).

Installed automatically via `./keyboard/install-keyboard.sh`:

```bash
./keyboard/install-keyboard.sh                          # install hwdb + backlight sync
./keyboard/install-keyboard.sh --with-keyd              # hwdb + backlight + keyd dual-role (Option 2)
./keyboard/install-keyboard.sh --check                  # verify daemon/service/udev/keyd state
./keyboard/install-keyboard.sh --uninstall              # remove all keyboard components (incl. keyd)
./keyboard/install-keyboard.sh --with-keyd --dry-run    # preview all
```

**What it installs:**

* `61-chromeos-kbd-backlight.rules` → `/etc/udev/rules.d/` (`TAG+="uaccess"`,
  plus `RUN+=chgrp plugdev` / `RUN+=chmod 0660` on the brightness attribute)
* `c640-kbd-backlight-sync` → `/usr/local/bin/` (bash daemon,
  `gdbus`/`dbus-monitor` event-driven, no polling by default)
* `c640-kbd-backlight-sync.service` → `/etc/systemd/user/` (enabled globally,
  `WantedBy=graphical-session.target`)
* `c640-kbd-backlight-sleep.sh` → `/usr/lib/systemd/system-sleep/` (S3 resume restore,
  0.6s debounce for `LED_CORE_SUSPENDRESUME`)

> **Why `RUN+=chmod`?** `MODE=`, `GROUP=` and `uaccess` only apply to `/dev`
> device nodes. `/sys/class/leds/chromeos::kbd_backlight/brightness` is a plain
> sysfs attribute with no device node, so udev cannot chmod it that way and the
> attribute stays `root:root 0644`. The rule therefore runs `chgrp plugdev` +
> `chmod 0660` explicitly (verified working on Ubuntu 26.04). Without it the user
> daemon falls back to `echo | sudo -n tee`, which a session service usually
> cannot answer. Verify:
>
> ```bash
> ls -l /sys/class/leds/chromeos::kbd_backlight/brightness   # root plugdev 0660
> sudo udevadm control --reload-rules
> sudo udevadm trigger --subsystem-match=leds                # re-apply without reboot
> id -nG | tr ' ' '\n' | grep -qx plugdev && echo "user is in plugdev"
> ```

**Manual test without blanking the screen:**

```bash
c640-kbd-backlight-sync --check          # show current brightness & state
c640-kbd-backlight-sync --test-blank     # simulate screen blank -> save + set 0
cat /sys/class/leds/chromeos::kbd_backlight/brightness  # should be 0
c640-kbd-backlight-sync --test-unblank   # simulate unblank -> restore
```

**Optional IdleMonitor polling** (off by default, for "dim before blank"):

```bash
# Enable Mutter IdleMonitor polling (idle-delay + 5s threshold) via drop-in:
sudo mkdir -p /etc/systemd/user/c640-kbd-backlight-sync.service.d
echo -e "[Service]\nEnvironment=C640_KBD_ENABLE_IDLEMONITOR=1" | sudo tee /etc/systemd/user/c640-kbd-backlight-sync.service.d/override.conf > /dev/null
sudo systemctl daemon-reload
sudo systemctl --global daemon-reload 2> /dev/null || true
systemctl --user daemon-reload 2> /dev/null || true
systemctl --user restart c640-kbd-backlight-sync.service 2> /dev/null || true
# To disable: sudo rm /etc/systemd/user/c640-kbd-backlight-sync.service.d/override.conf && daemon-reload
```

**Wayland/X11 compatibility:** primary path is `org.gnome.ScreenSaver` (GNOME Wayland
native, event-driven, no polling). `IdleMonitor` is optional. Non-GNOME sessions
fall back to the `system-sleep` hook for lid-close S3.

**Logs:**

```bash
journalctl --user -u c640-kbd-backlight-sync.service -f
journalctl --user -u c640-kbd-backlight-sync.service --since "5 min ago" | cat
```

---

## 🧪 Verification & Testing

Verify that key events are properly recognized:

```bash
sudo evtest
# Select "AT Translated Set 2 keyboard" and press the top-row keys.
```

### Automated keyd dual-role test (no human keypress needed)

`keyboard/tests/keyd-dualrole-uinput.py` creates a virtual keyboard with the
AT id `0001:0001`, restarts keyd so it is grabbed, injects keystrokes and
asserts on what keyd's own virtual keyboard emits:

```bash
sudo apt install -y python3-evdev
sudo python3 keyboard/tests/keyd-dualrole-uinput.py
# PASS: tap Search -> CAPSLOCK
# PASS: hold Search + Back -> META + F1
# PASS: hold Search + BrightnessDown -> F6
# PASS: BrightnessDown alone -> brightnessdown
# RESULT=PASS
```

### Passive capture of real key presses (safe)

`keyboard/tests/capture-keyd-output.py` reads keyd's virtual keyboard read-only,
so the desktop keeps receiving input while it runs:

```bash
sudo apt install -y python3-evdev
sudo python3 keyboard/tests/capture-keyd-output.py --seconds 120
# 12:49:15 KEY_LEFTMETA 1     <- tap Search
# 12:49:16 KEY_CAPSLOCK 1
# 12:49:18 KEY_LEFTMETA 1     <- hold Search (Super)
# 12:49:26 KEY_F6 1           <- hold Search + BrightnessDown
```

**Never grab the keyd virtual keyboard** (`evtest`, `evemu-record`, raw
`EVIOCGRAB`). A grab takes the device away from the compositor and the whole
keyboard stops working until the tool exits. `keyd monitor` is not a substitute
either: keyd 2.5.x cannot open a device it has already grabbed, so the internal
keyboard never appears there.

### Reading `udevadm test` output

`udevadm test /sys/class/input/event2` prints `No entry found from hwdb` for the
generic lookups (`evdev:`, `evdev:name:`, `evdev:name:...:phys:...`). Only the
`evdev:atkbd:$attr{[dmi/id]modalias}` line matters; when it applies
`KEYBOARD_KEY_*`, the mapping is live. Real Dratini firmware reports extra
`br0.0:efr0.0` fields between `bd*` and `svn*`, which `bd*:svnGoogle*` still
matches (verified 2026-10-31).

### Real-hardware validation log (HP Pro c640 / Dratini, 2026-10-31)

Environment: Ubuntu 26.04.1 LTS, kernel `7.0.0-38-generic`, `keyd 2.5.0-5`
(binary `/usr/bin/keyd.rvaiya`), `python3-evdev 1.9.3`, GNOME Wayland session.

| Check | Result | Evidence |
| :--- | :---: | :--- |
| hwdb live translation | 🟢 | `udevadm info /dev/input/event2` → `KEYBOARD_KEY_db=leftmeta`, `ea=back`, `ef=brightnessup` |
| keyd grabs only the internal keyboard | 🟢 | journal: `match 0001:0001 ... (AT Translated Set 2 keyboard)`; `ignoring 0000:0006 (Video Bus)` |
| Tap Search | 🟢 | uinput test: `LEFTMETA+LEFTCTRL` guard pair, then `CAPSLOCK` down/up |
| Hold Search + Back | 🟢 | `META` held → `F1` down/up |
| Hold Search + BrightnessDown | 🟢 | `F6` down/up (Search+top-row = F1-F10 layer) |
| BrightnessDown alone | 🟢 | `KEY_BRIGHTNESSDOWN` down/up (media layer preserved) |
| Physical tap Search (passive capture) | 🟢 | `13:26:02` passive capture (no grab): `LEFTMETA` + `LEFTCTRL` guard pair, then `CAPSLOCK` down/up |
| Physical hold Search + BrightnessDown | 🟢 | `12:49:26` passive capture: `KEY_F6` ×4 (Search+top-row layer) |
| Physical hold Search + Back | 🟢 | `13:25:56` passive capture (no grab): `LEFTMETA` held → `KEY_F1` down/up |
| LED node permissions | 🟢 | `-rw-rw---- root plugdev` on `chromeos::kbd_backlight/brightness` after `udevadm trigger --subsystem-match=leds`; user write succeeds without sudo |
| Daemon blank/unblank | 🟢 | `--test-blank` 2 → 0, `--test-unblank` 0 → 2, state file `0600` and removed |
| Daemon event path | 🟢 | `gdbus emit ... ScreenSaver.ActiveChanged true/false` → brightness 2 → 0 → 2 with **no `sudo` calls** in the user journal |
| Sleep hook | 🟢 | `pre suspend` saved 6, simulated 0, `post suspend` restored 6, state file removed (hook invoked directly; a real S3 lid cycle was not possible during the automated session) |
| `--check` | 🟢 | all green, including "backlight node writable by group plugdev (mode 660)" |

**Pitfalls found on real hardware (now fixed in this repo):**

1. Ubuntu 26.04's `keyd` package ships `/usr/bin/keyd.rvaiya`; `keyd` is not in
   `$PATH`. Use `keyd_bin()` / `command -v keyd keyd.rvaiya`.
2. keyd 2.5.x has no `check` subcommand, and no device hot-plug detection: the
   installer must `systemctl restart keyd` after deploying `/etc/keyd/cros.conf`,
   otherwise the old (or no) mapping stays active.
3. `[ids] *` also grabs the ChromeOS `Video Bus`; scope to `0001:0001`.
4. udev `MODE=`/`GROUP=`/`uaccess` do **not** chmod sysfs LED attributes. The
   backlight daemon therefore needs `RUN+=chgrp plugdev` + `RUN+=chmod 0660` in
   `61-chromeos-kbd-backlight.rules`, otherwise it falls back to `sudo -n tee`,
   which a user service cannot answer.
5. keyd's modifier guard emits a harmless `LEFTCTRL` tap around a bare Meta
   release; tests must assert on `CAPSLOCK`, not "CAPSLOCK only".
6. A user `uinput` device is only grabbed by keyd if it exposes the full
   `keyboard_mask` (`KEY_1..0`, `Q..Y`) or `KEY_BRIGHTNESSUP`; adding a single
   `KEY_LEFTMETA` is not enough.
7. Grabbing the keyd virtual keyboard (`EVIOCGRAB`, `evtest`) removes it from
   the compositor and kills all keyboard input for the desktop. Verify with the
   passive `capture-keyd-output.py` instead.
8. `udevadm test` reports `No entry found from hwdb` for the generic `evdev:`
   lookups even when the mapping works; only the `evdev:atkbd:` lookup applies
   `KEYBOARD_KEY_*`.
