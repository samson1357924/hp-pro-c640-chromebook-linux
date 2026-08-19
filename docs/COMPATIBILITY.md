# 📊 Hardware Compatibility Matrix

Hardware component support under Linux for the HP Pro c640 Chromebook
(codenamed **Google `dratini`**, baseboard **`hatch`**, Intel 10th Gen Comet
Lake-U platform):

---

## 💻 Component Status Overview

| Hardware Component | Chip Model / Spec | Linux Kernel Driver | Support Status | Notes / Solutions |
| :--- | :--- | :--- | :---: | :--- |
| **Fingerprint Reader** | Fingerprint Cards FPC1025 (FPMCU MoC) | `/dev/cros_fp` (`cros_ec_spi`) | 🟢 **Working** | This project's `crfpmoc` driver + PAM; lock-screen unlock and `sudo` **hardware-tested 2026-08-19**. |
| **Built-in Stereo Speakers** | Maxim MAX98357A (I2S Amp) | `snd_soc_max98357a` | 🟢 **Working** | Output via ALSA UCM2 PCM 5; **hardware-tested** (Chromium playback). |
| **3.5mm Headphone Jack** | Realtek RT5682 (I2C) | `snd_soc_rt5682` | ⚠️ **Driver bound** | Device present (PCM 0); **auto-switch on plug/unplug not captured in evidence**. |
| **Built-in Digital Microphones** | 2-channel PDM DMIC | `snd_soc_dmic` | 🟢 **Working** | UCM PCM Split into stereo Mic 1 / Mic 2; **hardware-tested**. |
| **Wi-Fi 6** | Intel Wi-Fi 6 AX201 (CNVi) | `iwlwifi` | ⚠️ **Driver bound** | Loads out of the box; **WPA3 / throughput not measured** on this device. |
| **Bluetooth 5.0** | Intel AX201 Bluetooth | `btusb` / `btintel` | ⚠️ **Driver bound** | Controller present; **pairing / A2DP audio not captured in evidence**. |
| **Touchpad** | ELAN I2C Touchpad | `i2c_hid` / `elan_i2c` | ⚠️ **Driver bound** | Module present; **multi-finger gestures / palm rejection not functionally tested**. |
| **Touchscreen (optional)** | Goodix / ELAN / G2Touch | `i2c_hid_acpi` | ⚠️ **Driver bound** | Module present; **multi-touch / stylus input not functionally tested**. |
| **GPU / Integrated Graphics** | Intel UHD Graphics 620 | `i915` | ⚠️ **Driver bound** | Display works out of the box; **VA-API 4K 60fps decode not measured**. |
| **Webcam** | 720p HD Camera (with privacy shutter) | `uvcvideo` | ⚠️ **Driver bound** | Standard USB UVC camera; **capture not tested**. |
| **Dual Type-C Output** | 2x USB-C 3.2 Gen 1 (PD + DP) | `typec` / `xhci_pci` | ⚠️ **Charging works** | PD charging nodes present; **DP 1.2 display output not verified**. |
| **Keyboard Top-Row Keys** | ChromeOS Top-Row Keys | `udev hwdb` / `keyd` | 🟢 **Working** | Mapped to standard media keys; **hwdb verified** (backlight brightness untested). |
| **Standby / Sleep** | S0ix Modern Standby + ACPI S3 | `s2idle` + `deep` | 🟢 **S3 lid cycle verified** | S3 `deep` default; real lid-close cycle tested 2026-08-18. **Key/fingerprint wake untested**; panel stays dark on lid open until a keypress (see [TROUBLESHOOTING.md §14](TROUBLESHOOTING.md)). |

---

## 🐧 Recommended Distros & Kernel Requirements

* **Recommended Linux kernel**: Linux Kernel `>= 5.15` (recommend `>= 6.5` for the best SOF DSP and S0ix power performance).
* **Audio server**: PipeWire `>= 0.3.65` (recommend PipeWire 1.0+ / WirePlumber 0.4.14+).
* **Distro testing status** (see [VERIFICATION.md](verification.md) for what was actually
  hardware-tested):
  * 🟢 **Hardware-tested on real device**: **Ubuntu 26.04 LTS** (kernel `7.0.0-29-generic`,
    PipeWire `1.6.2`, WirePlumber `0.5.13`, fprintd `1.94.5`)
  * ⚠️ **Build-tested in CI only (no hardware test)**: Ubuntu 24.04, Fedora 42,
    Arch Linux (distro-matrix dry-run + dependency resolution), plus packaging
    lint (Arch `namcap`, Fedora `rpmlint`)
