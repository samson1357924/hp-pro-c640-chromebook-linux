# HP Pro c640 Chromebook (Google Dratini) Linux Guide & Hardware Enablement

Complete hardware enablement guide, driver fixes, and setup scripts for running Linux (Ubuntu / Debian / Fedora / Arch) on the **HP Pro c640 Chromebook** (Board: **Google `dratini`** / Intel Comet Lake-U).

---

## 💻 Device Specifications

* **Device**: [HP Pro c640 Chromebook](https://support.hp.com/hk-zh/product/product-specs/hp-pro-c640-chromebook/33298399)
* **Google Board Name**: `dratini` (Baseboard: `hatch`)
* **Processor**: Intel 10th Gen Core i3/i5/i7 (Comet Lake-U)
* **Fingerprint Sensor**: Fingerprint Cards FPC1025 (ChromeOS Match-on-Chip via `/dev/cros_fp`)
* **Audio DSP**: Intel Sound Open Firmware (SOF) HD Audio / Maxim / Realtek Codec
* **Firmware**: MrChromebox UEFI Full ROM / Coreboot

---

## 📊 Hardware Working Status

| Component | Status | Driver / Solution | Notes |
| :--- | :---: | :--- | :--- |
| **Fingerprint Reader** | 🟢 **Working** | `crfpmoc` (Custom `libfprint 2.0` driver) | Supports GDM Login, Lockscreen Unlock, and `sudo` PAM auth. |
| **Internal Speakers & Mic** | 🟢 **Working** | Intel SOF Audio + ALSA UCM / PipeWire | Full stereo output & internal mic working. |
| **Wi-Fi 6 & Bluetooth 5.0** | 🟢 **Working** | Intel AX201 (`iwlwifi` / `btusb`) | Works out of the box in standard Linux kernels. |
| **Touchscreen & Touchpad** | 🟢 **Working** | `i2c_hid` / `elan_i2c` | Multi-touch gestures and palm rejection supported. |
| **Display & Intel UHD Graphics** | 🟢 **Working** | `i915` (Wayland / X11) | Hardware accelerated video decode (VA-API). |
| **Keyboard Backlight & Top Row**| 🟢 **Working** | `cros_ec` + `udev hwdb` mapping | Top-row F1-F10 action keys mapped cleanly. |
| **Suspend / Sleep & Resume** | 🟢 **Working** | ACPI `s2idle` | Fast wake-up with working fingerprint resume. |

---

## 🚀 Quick Start (Automated Setup)

Clone this repository and run the unified setup script:

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git ~/projects/hp-pro-c640-chromebook-linux
cd ~/projects/hp-pro-c640-chromebook-linux
chmod +x setup.sh fingerprint/install-fingerprint.sh
./setup.sh
```

---

## 🖐️ Fingerprint Setup (`crfpmoc`)

The fingerprint sensor on HP Pro c640 is an **FPC1025 Match-on-Chip (MoC)** sensor controlled by the ChromeOS Embedded Controller (`/dev/cros_fp`). Standard upstream `libfprint` does not support this interface natively.

This project integrates the customized and audited **`crfpmoc`** driver featuring:
* Non-blocking 50ms state-machine event polling (resolving Linux kernel epoll interrupt starvation).
* Memory-safe weak-pointer lifecycle guards.
* Secure persistent TPM encryption keys (`0600` permissions in `/var/lib/fprint/crfpmoc.key`).
* Full compatibility with standard Linux `fprintd` and PAM authentication stack.

To install or manage the fingerprint driver independently, see [fingerprint/README.md](fingerprint/README.md).

```bash
cd fingerprint/
./install-fingerprint.sh
fprintd-enroll "$USER"
fprintd-verify "$USER"
```

---

## 🔊 Audio & Speakers Setup

Detailed setup, ALSA UCM profiles, and PipeWire configurations for the Intel Comet Lake SOF DSP audio subsystem are documented in [audio/README.md](audio/README.md).

---

## ⌨️ Top-Row Function Keys Setup

ChromeOS top-row action keys (Back, Forward, Refresh, Fullscreen, Overview, Brightness Down/Up, Mute, Volume Down/Up) can be mapped to standard media keys via Udev HWDB:

```bash
sudo cp keyboard/90-chromebook-keyboard.hwdb /etc/udev/hwdb.d/
sudo systemd-hwdb update
sudo udevadm trigger
```
See [keyboard/README.md](keyboard/README.md) for details.

---

## 📜 License

* Documentation and scripts in this repository are licensed under the [MIT License](LICENSE).
* Driver components derived from `libfprint` are licensed under the [GNU LGPL v2.1+](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.en.html).
