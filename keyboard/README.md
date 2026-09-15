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

2. Install configuration (via installer, recommended):

   ```bash
   sudo ./keyboard/install-keyboard.sh --with-keyd
   # equivalent manual:
   # sudo install -D -m 0644 keyboard/keyd/cros.conf /etc/keyd/cros.conf
   # sudo ln -sf cros.conf /etc/keyd/default.conf
   # keyd check /etc/keyd/cros.conf
   # sudo systemctl enable --now keyd
   ```

3. Verify & tune:

   ```bash
   keyd --version
   sudo keyd monitor  # short press Search -> capslock, long hold -> leftmeta ; Search+TopRow -> F1
   sudo systemctl status keyd
   journalctl -eu keyd -f
   # If tap vs hold is too sensitive, add to /etc/keyd/cros.conf [global]:
   # overload_tap_timeout = 200  # ms, see man keyd
   # sudo keyd reload
   ```

   **GNOME Wayland trackpad quirk** (optional, fixes `disable-while-typing` stall):

   ```bash
   sudo mkdir -p /etc/libinput
   printf '[Keyd]\nMatchName=keyd virtual keyboard\nAttrKeyboardIntegration=internal\n' | sudo tee /etc/libinput/local-overrides.quirks > /dev/null
   ```

    **Notes:**
    * `X11` users: `setxkbmap` is reset on `keyd restart`; reapply after.
    * `TTy` works via `uinput`; panic: `backspace+escape+enter` if config locks you out.

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

* `61-chromeos-kbd-backlight.rules` → `/etc/udev/rules.d/` (`TAG+="uaccess"`)
* `c640-kbd-backlight-sync` → `/usr/local/bin/` (bash daemon,
  `gdbus`/`dbus-monitor` event-driven, no polling by default)
* `c640-kbd-backlight-sync.service` → `/etc/systemd/user/` (enabled globally,
  `WantedBy=graphical-session.target`)
* `c640-kbd-backlight-sleep.sh` → `/usr/lib/systemd/system-sleep/` (S3 resume restore,
  0.6s debounce for `LED_CORE_SUSPENDRESUME`)

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
