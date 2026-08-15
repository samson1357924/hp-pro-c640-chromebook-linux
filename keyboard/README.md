# Keyboard Top-Row Mapping (HP Pro c640 Chromebook)

ChromeOS devices have specialized top-row action keys instead of traditional F1-F12 keys. Under standard Linux, these keys can be remapped to standard media and system functions using `systemd-hwdb`.

---

## 🎹 Top-Row Key Mapping Table

| Physical Key | ChromeOS Function | Linux Mapping | Keycode |
| :--- | :--- | :--- | :--- |
| **F1** | Back | Browser Back | `KEY_BACK` |
| **F2** | Forward | Browser Forward | `KEY_FORWARD` |
| **F3** | Refresh | Browser Refresh | `KEY_REFRESH` |
| **F4** | Fullscreen | Fullscreen | `KEY_F11` |
| **F5** | Overview / Switch Window | Task Switcher | `KEY_SCALE` |
| **F6** | Brightness Down | Brightness Down | `KEY_BRIGHTNESSDOWN` |
| **F7** | Brightness Up | Brightness Up | `KEY_BRIGHTNESSUP` |
| **F8** | Mute | Audio Mute | `KEY_MUTE` |
| **F9** | Volume Down | Volume Down | `KEY_VOLUMEDOWN` |
| **F10** | Volume Up | Volume Up | `KEY_VOLUMEUP` |

---

## 🛠️ Installation

1. Copy the HWDB file to system configuration:
   ```bash
   sudo cp 90-chromebook-keyboard.hwdb /etc/udev/hwdb.d/
   ```
2. Update the hardware database:
   ```bash
   sudo systemd-hwdb update
   ```
3. Trigger udev input devices:
   ```bash
   sudo udevadm trigger --subsystem-match=input
   ```

---

## 🧪 Verification & Testing

To verify that key events are properly mapped and captured by Linux:

```bash
sudo apt install -y evtest
sudo evtest
```
*(Select the `AT Translated Set 2 keyboard` device and press the top-row keys to view the reported keycodes)*
