# Audio & Speaker Setup (HP Pro c640 Chromebook / Dratini)

This directory documents the audio configuration for the **Intel Comet Lake Sound Open Firmware (SOF)** audio DSP and Maxim/Realtek codecs on the HP Pro c640 Chromebook.

---

## 🎧 Hardware Overview

* **Audio DSP**: Intel Comet Lake PCH-LP Sound Open Firmware (`snd_sof_pci_intel_cnl`)
* **Codec Topology**: Intel SOF DSP with stereo internal speakers, digital microphones, and 3.5mm headset jack.
* **Firmware**: SOF v2.x+ (`/lib/firmware/intel/sof/` and `/lib/firmware/intel/sof-tplg/`)

---

## 🔧 Solution Overview

Audio on the HP Pro c640 is fully functional with:
1. **Sound Open Firmware (SOF)** driver stack in the Linux kernel (`CONFIG_SND_SOC_SOF_COMETLAKE=m`).
2. **ALSA UCM (Use Case Manager)** audio profiles matching the `dratini` / `hatch` board topology (`/usr/share/alsa/ucm2/Intel/sof-hda-dsp/` or `sof-soundwire`).
3. **PipeWire / WirePlumber**: Modern audio server supporting automatic sink/source switching between internal speakers and headphones.

*Detailed script and configuration files will be documented and added to this directory.*
