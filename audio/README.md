# Audio & Speaker Setup (HP Pro c640 Chromebook / Dratini)

This directory documents the audio configuration for the **Intel Comet Lake Sound Open Firmware (SOF)** audio DSP and Maxim/Realtek codecs on the HP Pro c640 Chromebook.

---

## 🎧 Hardware Overview

* **Audio DSP**: Intel Comet Lake PCH-LP Sound Open Firmware (`snd_sof_pci_intel_cnl`)
* **Codec Topology**: Intel SOF DSP with stereo internal speakers, digital microphones, and 3.5mm headset jack.
* **Firmware**: SOF v2.x+ (`/lib/firmware/intel/sof/` and `/lib/firmware/intel/sof-tplg/`)

---

## 📦 Installation & Prerequisites

Ensure the required Sound Open Firmware binaries and ALSA UCM profiles are installed:

```bash
# Ubuntu / Debian
sudo apt update
sudo apt install -y firmware-sof-signed alsa-ucm-conf pipewire wireplumber pipewire-audio-client-libraries

# Enable PipeWire user services
systemctl --user enable --now pipewire pipewire-pulse wireplumber
```

---

## 🧪 Verification & Diagnostics

1. **Verify Sound Cards**:
   ```bash
   aplay -l
   # Should list: sof-hda-dsp or sof-soundwire
   ```

2. **Verify PipeWire Sinks & Sources**:
   ```bash
   wpctl status
   ```

3. **Test Speaker Playback**:
   ```bash
   speaker-test -c 2 -t wav
   ```

---

## ❓ Troubleshooting & FAQs

### 1. Issue: "Dummy Output" shown in Settings
* **Cause**: SOF firmware missing or kernel module not loaded.
* **Fix**: Check `dmesg | grep -i sof` and ensure `firmware-sof-signed` is installed, then reboot.

### 2. Issue: Microphone level too low
* **Fix**: Open `alsamixer` (Press `F6` to select the SOF soundcard), navigate to `Dmic0 Capture Volume` or `Capture`, and increase gain to ~80%.

### 3. Issue: Audio muted after system resume from sleep
* **Fix**: Restart user-level PipeWire services:
  ```bash
  systemctl --user restart wireplumber pipewire
  ```
