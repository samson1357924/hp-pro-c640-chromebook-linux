# 📊 Hardware Compatibility Matrix

Hardware component support under Linux for the HP Pro c640 Chromebook
(codenamed **Google `dratini`**, baseboard **`hatch`**, Intel 10th Gen Comet
Lake-U platform):

---

## 💻 Component Status Overview

| Hardware Component | Chip Model / Spec | Linux Kernel Driver | Support Status | Notes / Solutions |
| :--- | :--- | :--- | :---: | :--- |
| **Fingerprint Reader** | Fingerprint Cards FPC1025 (FPMCU MoC) | `/dev/cros_fp` (`cros_ec_spi`) | 🟢 **100% Working** | Uses this project's `crfpmoc` driver + PAM. Supports lock-screen unlock and `sudo`. |
| **Built-in Stereo Speakers** | Maxim MAX98357A (I2S Amp) | `snd_soc_max98357a` | 🟢 **100% Working** | Output via ALSA UCM2 PCM 5, supports hardware volume control. |
| **3.5mm Headphone Jack** | Realtek RT5682 (I2C) | `snd_soc_rt5682` | 🟢 **100% Working** | Supports automatic plug detection switching (JD1) and headset mic input. |
| **Built-in Digital Microphones** | 2-channel PDM DMIC | `snd_soc_dmic` | 🟢 **100% Working** | UCM PCM Split divides into stereo Mic 1 and Mic 2. |
| **Wi-Fi 6** | Intel Wi-Fi 6 AX201 (CNVi) | `iwlwifi` | 🟢 **No setup needed** | Built into the kernel, supports 802.11ax and WPA3. |
| **Bluetooth 5.0** | Intel AX201 Bluetooth | `btusb` / `btintel` | 🟢 **No setup needed** | Supports BLE, A2DP audio and HID Bluetooth peripherals. |
| **Touchpad** | ELAN I2C Touchpad | `i2c_hid` / `elan_i2c` | 🟢 **No setup needed** | Native multi-finger gestures and palm rejection. |
| **Touchscreen (optional)** | Goodix / ELAN / G2Touch | `i2c_hid_acpi` | 🟢 **No setup needed** | Supports multi-touch and USI Stylus pen input. |
| **GPU / Integrated Graphics** | Intel UHD Graphics 620 | `i915` | 🟢 **No setup needed** | Supports Wayland/X11, VA-API hardware encode/decode (4K 60fps). |
| **Webcam** | 720p HD Camera (with privacy shutter) | `uvcvideo` | 🟢 **No setup needed** | Standard USB UVC camera. |
| **Dual Type-C Output** | 2x USB-C 3.2 Gen 1 (PD + DP) | `typec` / `xhci_pci` | 🟢 **No setup needed** | Both ports support 45W/65W PD fast charging and DP 1.2 display output. |
| **Keyboard Top-Row Keys** | ChromeOS Top-Row Keys | `udev hwdb` / `keyd` | 🟢 **100% Working** | Mapped to standard media keys such as Back/Forward/Reload/Brightness/Volume. |
| **Standby / Sleep** | S0ix Modern Standby + ACPI S3 | `s2idle` + `deep` | 🟢 **100% Working** | Both modes advertised; S3 `deep` is the default (see the power deep-dive). Supports lid-close sleep and fast wake via keys/fingerprint. |

---

## 🐧 Recommended Distros & Kernel Requirements

* **Recommended Linux kernel**: Linux Kernel `>= 5.15` (recommend `>= 6.5` for the best SOF DSP and S0ix power performance).
* **Audio server**: PipeWire `>= 0.3.65` (recommend PipeWire 1.0+ / WirePlumber 0.4.14+).
* **Verified distros**:
  * **Ubuntu 24.04 LTS / 26.04 LTS** (works perfectly)
  * **Debian 12 (Bookworm) / 13 (Trixie)**
  * **Fedora 39 / 40 / 41**
  * **Arch Linux / EndeavourOS**
  * **openSUSE Tumbleweed**
