[English](README.md) | [繁體中文](README.zh-TW.md)

# HP Pro c640 Chromebook (Google Dratini) Linux: The Complete Pitfall-Avoidance Guide and Hardware Enablement Plan

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: ChromeOS / Linux](https://img.shields.io/badge/Platform-Chromebook%20Linux-green.svg)](docs/COMPATIBILITY.md)
[![Hardware: Google Dratini / Hatch](https://img.shields.io/badge/Hardware-Google%20Dratini%20(Comet%20Lake)-orange.svg)](docs/COMPATIBILITY.md)
[![Docs: GitHub Pages](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/actions/workflows/pages.yml/badge.svg)](https://samson1357924.github.io/hp-pro-c640-chromebook-linux/)

This project provides a complete Linux hardware enablement plan for the **HP
Pro c640 Chromebook** (Google Board: **`dratini`** / Baseboard: **`hatch`** /
Intel 10th Gen Comet Lake-U), including driver patches, cross-distribution
automated installation scripts, and a comprehensive guide to avoiding pitfalls.

---

## 💻 Device Specifications

* **Model**: [HP Pro c640 Chromebook](https://support.hp.com/hk-zh/product/product-specs/hp-pro-c640-chromebook/33298399)
* **Board Codename**: Google `dratini` (Baseboard: `hatch`)
* **Processor**: Intel 10th Gen Core i3/i5/i7 (Comet Lake-U: i3-10110U, i5-10210U, i5-10310U, i7-10610U)
* **Fingerprint Reader**: Fingerprint Cards FPC1025 (ChromeOS Match-on-Chip via `/dev/cros_fp`)
* **Audio System**: Intel Comet Lake cAVS SOF DSP (`snd_sof_pci_intel_cnl`) + Realtek RT5682 + Maxim MAX98357A
* **Firmware**: MrChromebox UEFI Full ROM / Coreboot

---

## 📊 Hardware Status

| Hardware Component | Status | Driver / Solution | Notes & Support Level |
| :--- | :---: | :--- | :--- |
| **Fingerprint** | 🟢 **Working** | `crfpmoc` (custom `libfprint` MoC driver) | Lock-screen unlock and `sudo` PAM authorization verified on this device. **GDM cold-boot login still requires the user password** (GNOME keyring decrypts on first login); see [VERIFICATION.md](docs/verification.md). |
| **Stereo Speakers & Microphone (Audio)** | 🟢 **Speakers & mic working** | Intel SOF DSP + ALSA UCM2 / PipeWire | Speakers (PCM 5), headphones (PCM 0), dual-microphone split working. **Headphone auto-switch on plug/unplug not captured in evidence** — see [VERIFICATION.md](docs/verification.md). |
| **Wi-Fi 6 & Bluetooth 5.0** | ⚠️ **Driver bound** | Intel AX201 (`iwlwifi` / `btusb`) | Drivers bind out of the box; **WPA3/throughput not yet measured** on this device (see [VERIFICATION.md](docs/verification.md)). |
| **Touchscreen & Touchpad** | ⚠️ **Driver bound** | `i2c_hid` / `elan_i2c` | Modules present; **gesture/palm-rejection functional test not captured** (see [VERIFICATION.md](docs/verification.md)). |
| **Intel UHD Display & Hardware Decoding** | ⚠️ **Driver bound** | `i915` (Wayland / X11) | Display works out of the box; **VA-API 4K 60fps hardware decode not yet measured** (see [VERIFICATION.md](docs/verification.md)). |
| **Keyboard Backlight & Top-Row Function Keys** | ⚠️ **Top-row verified** | `cros_ec` + `udev hwdb` / `keyd` | Top-row F1-F10 mapped to previous page, refresh, brightness, and volume (hwdb verified). **Backlight brightness not tested** — see [VERIFICATION.md](docs/verification.md). |
| **Sleep/Resume** | 🟢 **S3 lid cycle verified** | ACPI S3 `deep` (default) + `s2idle` | Real lid-close S3 suspend/resume cycle verified 2026-08-18 (zero errors). **Key/fingerprint wake untested**; known issue: panel stays dark on lid open until a keypress (see [VERIFICATION.md](docs/verification.md)). |
| **Dual Type-C Output & Fast Charging** | ⚠️ **Charging works** | USB-PD + DP 1.2 Alt Mode | PD charging nodes present; **external display via Type-C not yet verified** (see [VERIFICATION.md](docs/verification.md)). |

---

## 🚀 Quick Start

### 1. One-Click Fully Automated Installation (Unified Master CLI)

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git ~/projects/hp-pro-c640-chromebook-linux
cd ~/projects/hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

### 2. Common CLI Commands

| Requirement | Command |
| :--- | :--- |
| **Full Installation (keyboard + audio + fingerprint + power + EC)** | `./setup.sh --all` |
| **Install audio UCM configuration only** | `./setup.sh --audio` (or `./audio/install-audio.sh`) |
| **Install fingerprint driver and PAM (Hybrid A+C)** | `./setup.sh --fingerprint` (or `./fingerprint/install-fingerprint.sh`) |
| **Force compile fingerprint driver from source (Plan A)** | `./setup.sh --source` (or `./fingerprint/install-fingerprint.sh --source`) |
| **Install top-row keyboard mapping only** | `./setup.sh --keyboard` (or `./keyboard/install-keyboard.sh`) |
| **Run system hardware comprehensive diagnostics** | `./setup.sh --check` (or `./scripts/detect-hardware.sh`) |
| **Preview mode (no system files modified)** | `./setup.sh --all --dry-run` |
| **One-click uninstall and system restore** | `./setup.sh --uninstall` |

---

## 📚 Documentation Suite

* ✅ **[VERIFICATION.md (Tested vs Untested)](docs/verification.md)**: What was
  **actually tested** on a real HP Pro c640 (with exact versions) vs config-only
  items — read before trusting any "100% working" claim.
* 🚀 **[QUICKSTART.md (Getting Started)](docs/QUICKSTART.md)**: quick enablement flow and commands.
* 📊 **[COMPATIBILITY.md (Hardware Compatibility)](docs/COMPATIBILITY.md)**: Detailed chip specifications and kernel requirements.
* 🔧 **[FIRMWARE.md (Firmware Flashing & Recovery)](docs/FIRMWARE.md)**:
  MrChromebox UEFI flashing, **disconnecting the battery cable to remove the
  Cr50 hardware write-protect (HW WP)**, and steps to restore ChromeOS.
* 🛠️ **[TROUBLESHOOTING.md (Troubleshooting & Pitfall FAQ)](docs/TROUBLESHOOTING.md)**:
  Reference table for the fourteen most common faults and how to avoid them (Dummy
  Output, Intel ME enablement requirements, S0ix power tuning, etc.).
* 🔄 **[UNINSTALL.md (System Recovery & Uninstall)](docs/UNINSTALL.md)**: Backup/restore mechanism and native package restoration.

### 🔬 Deep Dive

* 🖐️ **[ChromeOS Match-on-Chip Fingerprint Driver Architecture](docs/deep-dive/cros-fp-moc-driver.md)**:
  EC communication protocol, 50ms state-machine polling, and TPM key security.
* 🔊 **[Intel SOF DSP and ALSA UCM2 Audio Topology](docs/deep-dive/intel-sof-ucm-audio.md)**:
  PCM mapping, Phantom Jack analysis, and PipeWire routing.
* 🔋 **[S0ix Sleep Mode and Power Management](docs/deep-dive/power-and-suspend.md)**:
  ASPM power saving and Wi-Fi WoWLAN power consumption optimization.

### 🐧 Distro Guides

* [Ubuntu & Debian Configuration Guide](docs/distros/ubuntu-debian.md)
* [Fedora & Silverblue Configuration Guide](docs/distros/fedora.md)
* [Arch Linux & EndeavourOS Configuration Guide (including PKGBUILD)](docs/distros/arch-linux.md)
* [openSUSE Tumbleweed Configuration Guide](docs/distros/opensuse.md)
* [NixOS Declarative Configuration Guide](docs/distros/nixos.md)

---

## 🧩 Core Feature Modules

### 🖐️ Fingerprint Module (`fingerprint/`)

The HP Pro c640 is equipped with an FPC1025 Match-on-Chip sensor that
communicates through the ChromeOS EC controller (`/dev/cros_fp`). This project
integrates the deeply audited and fixed **`crfpmoc`** driver with a **Hybrid A+C Architecture**:

* **Hybrid Fast Installation**: Automatically installs prebuilt native
  packages (`.deb`, `.rpm`, `.pkg.tar.zst`) from GitHub Releases; seamlessly
  falls back to source compilation (Plan A) when offline.
* Uses 50ms-delay state-machine polling to fully resolve the epoll starvation
  issue caused by the missing interrupt in the Linux kernel.
* Weak-pointer memory guarding to eliminate Use-After-Free hazards.
* `/var/lib/fprint/crfpmoc.key` independent random encryption seed (permissions `0600`).
* Provides Debian `.deb`, Arch PKGBUILD, RPM Spec, and standalone source packaging.

### 🔊 Audio Subsystem (`audio/`)

Comet Lake SOF DSP audio is fully enabled through the ALSA UCM2 topology:

* Built-in stereo speakers: PCM 5 (`max98357a`).
* 3.5mm headphone jack: PCM 0 (`rt5682`), with automatic plug/unplug switching.
* Digital microphone array: PCM 1 (DMIC Split split into two channels).
* Provides the PipeWire ACP Phantom Jack fix patch ([patches/acp-phantom-jack.patch](audio/patches/acp-phantom-jack.patch)).

### ⌨️ Top-Row Keyboard Mapping (`keyboard/`)

* **Option A (recommended by default)**: `systemd-hwdb` kernel-level mapping,
  zero resource consumption, supports TTY, X11 and Wayland.
* **Option B (advanced dual-mode)**: Provides a `keyd` configuration file
  ([keyboard/keyd/cros.conf](keyboard/keyd/cros.conf)) supporting the Search
  key "short-press CapsLock, long-press Super", and holding Super converts the
  top row into standard F1-F10.

---

## 🙏 Acknowledgements & Credits

Special thanks to the following open-source projects, contributors and
communities that laid the foundation for cross-platform ChromeOS and Linux
hardware support:

* **Abhinav Baid**: Original author of the
  `crfpmoc` (ChromeOS Match-on-Chip) libfprint driver.
* **Felix Niederer**: Early maintenance and
  architecture contributions to the `crfpmoc` driver.
* **Michael Evans**: Protocol extension and multi-version fix contributions.
* **[Marco Trevisan (Treviño)](https://github.com/3v1n0)** and the
  **[libfprint / freedesktop.org](https://gitlab.freedesktop.org/libfprint/libfprint)**
  team: A powerful and robust Linux biometric driver framework.
* **[MrChromebox](https://mrchromebox.tech/)** and the
  **[Chrultrabook Project](https://chrultrabook.com/)** community: Outstanding
  Coreboot / UEFI Full ROM firmware and Chromebook Linux community support.
* **[WeirdTreeThing](https://github.com/WeirdTreeThing)**: Maintainer of Chromebook Linux Audio UCM configurations.
* **[ChromiumOS Embedded Controller (EC) Team](https://chromium.googlesource.com/chromiumos/platform/ec/)**:
  The open-source ChromeOS EC Host Commands and FPMCU protocol specification.

---

## 📜 License & Compliance

This project follows [REUSE Specification 3.0](https://reuse.software/) and the
[SPDX standard](https://spdx.dev/) to implement rigorous mixed-license
management:

| Component Module | Applicable Path | License (SPDX) | Full License Text |
| :--- | :--- | :--- | :--- |
| **Master scripts and tools** | `setup.sh`, `scripts/`, `lib/`, `power/`, `ec/` | **MIT License** | [`LICENSES/MIT.txt`](LICENSES/MIT.txt) |
| **Fingerprint driver and tests** | `fingerprint/driver/`, `fingerprint/tests/` | **LGPL-2.1-or-later** | [`LICENSES/LGPL-2.1-or-later.txt`](LICENSES/LGPL-2.1-or-later.txt) / [`COPYING.LGPL`](COPYING.LGPL) |
| **Audio UCM topology configuration** | `audio/ucm/` | **BSD-3-Clause** | [`LICENSES/BSD-3-Clause.txt`](LICENSES/BSD-3-Clause.txt) |
| **Hardware key database and documentation** | `keyboard/90-*.hwdb`, `docs/` | **CC0-1.0 / MIT** | [`LICENSES/CC0-1.0.txt`](LICENSES/CC0-1.0.txt) |

> [!NOTE]
> Please refer to [**`CREDITS.md`**](CREDITS.md) for the copyright statements
> of the upstream authors (Abhinav Baid, WeirdTreeThing, Marco Trevisan, ALSA
> Project, ChromiumOS Authors), the acknowledgement list, and the records of
> derivative modifications.
