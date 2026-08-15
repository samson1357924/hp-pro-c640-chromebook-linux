# Audio Setup (sofrt5682: rt5682 Headphone + max98357a Speakers / Dratini)

Audio on the HP Pro c640 Chromebook is **fully working** once the ALSA UCM
profiles are installed (vendored in [audio/ucm/](ucm/README.md)): the `HiFi`
profile becomes available, internal stereo Speakers is the default sink, and
headphone/microphone/HDMI all work seamlessly.

---

## 🎧 Hardware Overview & Routing Topology

* **Audio DSP**: Intel Comet Lake PCH-LP Sound Open Firmware (`snd_sof_pci_intel_cnl`, `snd_sof`)
* **Sound Card**: `sofrt5682` — Realtek `rt5682` headset codec + Maxim
  `max98357a` speaker amplifier + dual-channel DMIC array
* **Firmware**: Intel SOF DSP v2.x+ (`sof-cml.ri` in `/lib/firmware/intel/sof/` and topology `sof-cml-rt5682-max98357a.tplg`)

### ALSA PCM Mapping

| PCM Index | Device Role | Hardware Codec | ALSA Device | Status / Routing |
| :---: | :--- | :--- | :--- | :--- |
| **PCM 0** | Port1 Headphone & Headset Mic | Realtek `rt5682` | `hw:0,0` | 🟢 3.5mm jack with auto-detection (JD1) |
| **PCM 1** | Internal Stereo DMIC (Split) | Intel cAVS DMIC | `hw:0,1` | 🟢 Split into `Mic1` & `Mic2` stereo streams |
| **PCM 2** | HDMI / DisplayPort 1 | Intel HDA HDMI | `hw:0,2` | 🟢 Type-C DP Alt Mode / HDMI port |
| **PCM 3** | HDMI / DisplayPort 2 | Intel HDA HDMI | `hw:0,3` | 🟢 Type-C DP Alt Mode |
| **PCM 4** | HDMI / DisplayPort 3 | Intel HDA HDMI | `hw:0,4` | 🟢 Type-C DP Alt Mode |
| **PCM 5** | Internal Stereo Speakers | Maxim `max98357a` | `hw:0,5` | 🟢 Default sink with hardware volume control |
| **PCM 8** | DMIC 16kHz | Intel cAVS DMIC | `hw:0,8` | 🟢 Low-power speech processing |

---

## 🛠️ Cross-Distribution Installation

### Step 1: Install System Prerequisites

* **Ubuntu / Debian**:

  ```bash
  sudo apt install -y firmware-sof-signed pipewire wireplumber alsa-ucm-conf
  ```

* **Fedora**:

  ```bash
  sudo dnf install -y alsa-sof-firmware pipewire wireplumber alsa-ucm
  ```

* **Arch Linux / EndeavourOS**:

  ```bash
  sudo pacman -S --needed sof-firmware pipewire pipewire-pulse wireplumber alsa-ucm-conf
  ```

* **openSUSE (Tumbleweed / Leap)**:

  ```bash
  sudo zypper install -y sof-firmware pipewire wireplumber alsa-ucm-conf
  ```

---

### Step 2: Install UCM2 Audio Profiles

Most standard distribution packages for `alsa-ucm-conf` do **not** ship
downstream Chromebook `sof-rt5682` profiles out of the box, causing the
"Dummy Output" issue.

#### Option A: Automated CLI Script (Recommended)

```bash
chmod +x audio/install-audio.sh
./audio/install-audio.sh
```

**Supported Flags**:

* `./audio/install-audio.sh --check` : Inspect current card and PipeWire sink status.
* `./audio/install-audio.sh --dry-run` : Preview file operations without modifying the filesystem.
* `./audio/install-audio.sh --uninstall` : Remove installed UCM profiles and revert changes.

#### Option B: Manual Steps (Declarative)

```bash
sudo cp -r audio/ucm/ucm2/* /usr/share/alsa/ucm2/
sudo alsactl init
systemctl --user restart wireplumber
```

---

## 🧪 Verification & Diagnostics

1. **Verify ALSA Sound Cards**:

   ```bash
   aplay -l
   # Should output: card 0: sofrt5682 [sof-rt5682], device 0 (Port1), device 5 (Speakers), etc.
   ```

2. **Verify PipeWire Sinks & Sources**:

   ```bash
   wpctl status
   # Output should list:
   # Sinks: Comet Lake PCH-LP cAVS Speaker (* default), Headphones, HDMI 1-3
   # Sources: Comet Lake PCH-LP cAVS 1 (Mic1 Split), Headset Microphone
   ```

3. **Speaker Test**:

   ```bash
   speaker-test -c 2 -t wav
   ```

4. **Run Comprehensive Audio Diagnostic Tool**:

   ```bash
   ./audio/diagnose-audio.sh
   ```

---

## ❓ Troubleshooting & Known Pitfalls

### 1. "Dummy Output" shown in System Audio Settings

* **Cause**: Missing `sof-rt5682` UCM configuration in `/usr/share/alsa/ucm2/`.
  PipeWire fallback probe fails on ASoC hardware because `max98357a` lacks an
  ALSA phantom jack kcontrol.
* **Fix**: Run `./audio/install-audio.sh`.
* **Deep Dive**: See [audio/docs/root-cause.md](docs/root-cause.md).

### 2. `cl_dsp_init: timeout with rom_status_reg` in dmesg

* **Cause**: **Intel Management Engine (ME) is disabled** in UEFI/Coreboot
  settings. The SOF DSP hardware depends on Intel ME communication during
  initialization.
* **Fix**: **Keep Intel ME enabled** in MrChromebox UEFI firmware settings.

### 3. Headphone auto-switching not triggering

* **Fix**: Restart user session WirePlumber:

  ```bash
  systemctl --user restart wireplumber
  ```

---

## 📁 Upstream References & Patches

* [patches/acp-phantom-jack.patch](patches/acp-phantom-jack.patch) — PipeWire ACP patch submitted in MR #5428
* [docs/root-cause.md](docs/root-cause.md) — Root cause analysis of ASoC phantom jack probing
* [docs/diagnostics.md](docs/diagnostics.md) — Diagnostic toolchain SOP & test matrix
* [docs/upstream.md](docs/upstream.md) — Upstream contribution status (ALSA PR #832, PipeWire MR #5428)

---

## 🙏 Credits

* **[WeirdTreeThing](https://github.com/WeirdTreeThing)** — Maintainer of
  [alsa-ucm-conf-cros](https://github.com/WeirdTreeThing/alsa-ucm-conf-cros)
  whose `sof-rt5682` profiles are vendored here (BSD-3-Clause).
* **[ALSA project](https://www.alsa-project.org/)** — Upstream UCM2 framework.
* **[PipeWire project](https://pipewire.org/)** — Modern Linux audio and video server.
