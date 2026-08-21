<!-- markdownlint-disable MD013 -->

# HP Pro c640 Chromebook (Google Dratini) Linux

<div class="mdx-hero" markdown>

<div class="mdx-hero__content" markdown>

## The Complete Pitfall-Avoidance Guide and Hardware Enablement

Complete Linux support for **HP Pro c640 Chromebook** (Board: `dratini` / Baseboard: `hatch` / Intel 10th Gen Comet Lake-U) — driver patches, cross-distro automation, and honest verified-vs-untested documentation.

[Get Started :material-rocket-launch:](QUICKSTART.md){ .md-button .md-button--primary }
[Honest Verification :material-shield-check:](verification.md){ .md-button }
[View on GitHub :fontawesome-brands-github:](https://github.com/samson1357924/hp-pro-c640-chromebook-linux){ .md-button }

</div>

</div>

---

## 💻 Device Specifications

| Item | Detail |
| :--- | :--- |
| **Model** | [HP Pro c640 Chromebook](https://support.hp.com/hk-zh/product/product-specs/hp-pro-c640-chromebook/33298399) |
| **Board Codename** | Google `dratini` (Baseboard: `hatch`) |
| **Processor** | Intel 10th Gen Core i3/i5/i7 (Comet Lake-U: i3-10110U, i5-10210U, i5-10310U, i7-10610U) |
| **Fingerprint Reader** | Fingerprint Cards FPC1025 (ChromeOS Match-on-Chip via `/dev/cros_fp`) |
| **Audio System** | Intel Comet Lake cAVS SOF DSP (`snd_sof_pci_intel_cnl`) + Realtek RT5682 + Maxim MAX98357A |
| **Firmware** | MrChromebox UEFI Full ROM / Coreboot |

---

## 📊 Hardware Status At-a-Glance

> **Honest by design** — 🟢 = verified on real HP Pro c640 (Ubuntu 26.04 / kernel 7.0.0-29 / 2026-08-19), ⚠️ = driver bound but functional test not captured, ❌ = not measured. See [Verification Matrix](verification.md) for evidence bundle and reproducibility steps.

| Hardware Component | Status | Driver / Solution | Notes & Support Level |
| :--- | :---: | :--- | :--- |
| **Fingerprint** | 🟢 **Working** | `crfpmoc` (custom `libfprint` MoC driver) | Lock-screen unlock and `sudo` PAM verified. **GDM cold-boot login still requires password** (GNOME keyring); see [verification.md](verification.md). |
| **Stereo Speakers & Microphone** | 🟢 **Speakers & mic working** | Intel SOF DSP + ALSA UCM2 / PipeWire | Speakers (PCM 5), headphones (PCM 0), dual-mic split working. **Headphone auto-switch not captured** — see [verification.md](verification.md). |
| **Wi-Fi 6 & Bluetooth 5.0** | ⚠️ **Driver bound** | Intel AX201 (`iwlwifi` / `btusb`) | Drivers bind out of the box; **WPA3/throughput not measured** (see [verification.md](verification.md)). |
| **Touchscreen & Touchpad** | ⚠️ **Driver bound** | `i2c_hid` / `elan_i2c` | Modules present; **gesture/palm-rejection not captured** (see [verification.md](verification.md)). |
| **Intel UHD Display & Hardware Decoding** | ⚠️ **Driver bound** | `i915` (Wayland / X11) | Display works; **VA-API 4K60 not measured** (see [verification.md](verification.md)). |
| **Keyboard Backlight & Top-Row Keys** | ⚠️ **Top-row verified** | `cros_ec` + `udev hwdb` / `keyd` | Top-row F1–F10 mapped (hwdb verified). **Backlight not tested** — see [verification.md](verification.md). |
| **Sleep/Resume** | 🟢 **S3 lid cycle verified** | ACPI S3 `deep` (default) + `s2idle` | Real lid-close S3 cycle verified 2026-08-18. **Key/fingerprint wake untested**; panel stays dark until keypress (see [verification.md](verification.md)). |
| **Dual Type-C Output & Fast Charging** | ⚠️ **Charging works** | USB-PD + DP 1.2 Alt Mode | PD charging present; **external display via Type-C not verified** (see [verification.md](verification.md)). |

!!! note "Last verified"
    **2026-08-19** on Ubuntu 26.04 LTS (kernel `7.0.0-29-generic`, PipeWire `1.6.2`, fprintd `1.94.5`, MrChromebox `2606.1`). Evidence bundle `c640-diagnostic-20260815_152233.tar.gz` — see [verification.md](verification.md) for how to reproduce.

---

## 🚀 Quick Start

### One-Liner

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git ~/projects/hp-pro-c640-chromebook-linux
cd ~/projects/hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

### Common Commands

| Requirement | Command |
| :--- | :--- |
| **Full installation (keyboard + audio + fingerprint + power + EC)** | `./setup.sh --all` |
| **Install audio UCM only** | `./setup.sh --audio` (or `./audio/install-audio.sh`) |
| **Install fingerprint driver + PAM (Hybrid A+C)** | `./setup.sh --fingerprint` |
| **Force compile fingerprint from source (Plan A)** | `./setup.sh --source` |
| **Install top-row keyboard mapping only** | `./setup.sh --keyboard` |
| **Run hardware diagnostics** | `./setup.sh --check` |
| **Preview mode (no system changes)** | `./setup.sh --all --dry-run` |
| **One-click uninstall & restore** | `./setup.sh --uninstall` |

---

## 📚 Documentation Map

<div class="grid cards" markdown>

- :material-rocket-launch: **Getting Started**

    ---

    New to this device? Start here for install, compatibility and firmware.

    [:octicons-arrow-right-24: Quick Start](QUICKSTART.md)
    [:octicons-arrow-right-24: Compatibility](COMPATIBILITY.md)
    [:octicons-arrow-right-24: Firmware](FIRMWARE.md)

- :material-shield-check: **Verification & Help**

    ---

    Honest tested-vs-untested matrix, troubleshooting and recovery.

    [:octicons-arrow-right-24: Verification Matrix](verification.md) — **read this first**
    [:octicons-arrow-right-24: Troubleshooting (14 pitfalls)](TROUBLESHOOTING.md)
    [:octicons-arrow-right-24: Uninstall & Restore](UNINSTALL.md)

- :material-microscope: **Deep Dive**

    ---

    Protocol-level analysis for fingerprint, audio and power.

    [:octicons-arrow-right-24: MoC Fingerprint Driver](deep-dive/cros-fp-moc-driver.md)
    [:octicons-arrow-right-24: SOF Audio Topology](deep-dive/intel-sof-ucm-audio.md)
    [:octicons-arrow-right-24: Power & Suspend](deep-dive/power-and-suspend.md)

- :material-linux: **Distro Guides**

    ---

    Per-distro steps and packaging notes.

    [:octicons-arrow-right-24: Ubuntu / Debian](distros/ubuntu-debian.md)
    [:octicons-arrow-right-24: Fedora](distros/fedora.md)
    [:octicons-arrow-right-24: Arch Linux](distros/arch-linux.md)
    [:octicons-arrow-right-24: openSUSE](distros/opensuse.md)
    [:octicons-arrow-right-24: NixOS](distros/nixos.md)

</div>

---

## 🧩 Module Highlights

### 🖐️ Fingerprint (`fingerprint/`)

FPC1025 Match-on-Chip via `/dev/cros_fp` with audited **`crfpmoc`** driver:

- **Hybrid A+C**: prebuilt `.deb`/`.rpm`/`.pkg.tar.zst` from Releases → fallback to source compile (Plan A)
- 50 ms state-machine polling fixes epoll starvation (missing IRQ)
- Weak-pointer guard eliminates Use-After-Free, `/var/lib/fprint/crfpmoc.key` `0600` seed
- Debian / Arch / RPM / standalone source packages — see [Fingerprint README](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/tree/main/fingerprint)

### 🔊 Audio (`audio/`)

Comet Lake SOF DSP via ALSA UCM2:

- Speakers PCM 5 (`max98357a`), Headphones PCM 0 (`rt5682`) auto-switch, DMIC PCM 1 split stereo
- PipeWire Phantom Jack fix — see [SOF Deep Dive](deep-dive/intel-sof-ucm-audio.md)

### ⌨️ Keyboard (`keyboard/`)

- **Option A (default)**: `systemd-hwdb` zero-overhead, TTY/X11/Wayland
- **Option B**: `keyd` dual-mode `Search` → CapsLock / Super, Super+TopRow → F1–F10 — see [keyboard/keyd/cros.conf](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/keyboard/keyd/cros.conf)

---

## 🙏 Acknowledgements

Special thanks to **Abhinav Baid** (original `crfpmoc`), **Felix Niederer**, **Michael Evans**, **[Marco Trevisan / libfprint](https://gitlab.freedesktop.org/libfprint/libfprint)**, **[MrChromebox](https://mrchromebox.tech/) / [Chrultrabook](https://chrultrabook.com/)**, **[WeirdTreeThing](https://github.com/WeirdTreeThing)** and the **[ChromiumOS EC Team](https://chromium.googlesource.com/chromiumos/platform/ec/)** — see [CREDITS](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/CREDITS.md).

---

## 📜 License & Compliance

This project follows [REUSE 3.0](https://reuse.software/) with SPDX:

| Module | Path | License |
| :--- | :--- | :--- |
| Master scripts & tools | `setup.sh`, `scripts/`, `lib/`, `power/`, `ec/` | **MIT** |
| Fingerprint driver & tests | `fingerprint/driver/`, `fingerprint/tests/` | **LGPL-2.1-or-later** |
| Audio UCM topology | `audio/ucm/` | **BSD-3-Clause** |
| Keyboard hwdb & docs | `keyboard/90-*.hwdb`, `docs/` | **CC0-1.0 / MIT** |

See [LICENSE](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/LICENSE), [LICENSES/](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/tree/main/LICENSES) and [CREDITS](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/CREDITS.md).
