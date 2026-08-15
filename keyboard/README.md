# Keyboard Top-Row Mapping (HP Pro c640 Chromebook)

ChromeOS devices feature dedicated top-row action keys instead of traditional F1-F12 keys. Under standard Linux, these keys can be remapped either at the kernel/hardware level using `systemd-hwdb` or at the input daemon level using `keyd`.

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
| **Search / Launcher**| 🔍 (Search) | `KEYBOARD_KEY_db` | `KEY_LEFTMETA` | Super (Meta) or CapsLock |

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
If you want the **Search key** to act as **CapsLock on tap** and **Super/Meta on hold**, or want `Search + Top-Row` to produce classic `F1-F10`:

1. Install `keyd`:
   ```bash
   # Ubuntu / Debian
   sudo apt install -y keyd  # or build from https://github.com/rvaiya/keyd
   # Fedora
   sudo dnf install -y keyd
   # Arch Linux
   sudo pacman -S keyd
   ```
2. Copy configuration:
   ```bash
   sudo cp keyboard/keyd/cros.conf /etc/keyd/default.conf
   sudo systemctl enable --now keyd
   ```

---

## 🧪 Verification & Testing

Verify that key events are properly recognized:

```bash
sudo evtest
# Select "AT Translated Set 2 keyboard" and press the top-row keys.
```
