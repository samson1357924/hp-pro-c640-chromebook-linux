# 🔬 Deep Dive: Intel Comet Lake SOF DSP and ALSA UCM2 Audio Topology

This article analyzes the audio hardware architecture, ALSA UCM2 topology
management, and PipeWire routing mechanism of the **HP Pro c640 Chromebook**
(Intel Comet Lake PCH-LP cAVS `[8086:02c8]` / `sof-rt5682`).

---

## 1. Audio Hardware Topology

The HP Pro c640 has three independent audio chips and channels:

```text
                             +----------------------------------------+
                             |    Intel Comet Lake cAVS SOF DSP       |
                             |      (snd_sof_pci_intel_cnl)           |
                             +----+-----------------+---------------+--+
                                  |                 |               |
              I2C4 + I2S          |                 | I2S           | PDM
                   +--------------+                 |               |
                   |                                |               |
                   v                                v               v
    +------------------------------+   +-----------------------+   +-------------------+
    |    Realtek RT5682 Codec      |   | Maxim MAX98357A Amp   |   | 2-ch Digital DMIC |
    |  - PCM 0: Headphone DAC      |   | - PCM 5: Internal     |   | - PCM 1: Stereo   |
    |  - PCM 0: Headset Mic ADC    |   |   Stereo Speakers     |   |   Microphone Array|
    |  - JD1: Jack Detection       |   +-----------------------+   +-------------------+
    +------------------------------+
```

---

## 2. Root-Cause Analysis of "Dummy Output"

When the Linux system does not have the dedicated UCM2 profile installed,
PipeWire falls back to the legacy PulseAudio `alsa-card-profile` (ACP)
mechanism:

1. **Phantom Jack probe blind spot**:
   - The MAX98357A speaker amplifier is a direct-connected device, and the profile defines `[Jack Speaker Phantom]`.
   - The kernel only creates Phantom Jack kcontrols on HDA sound cards;
     ASoC-based architectures (such as SOF) **never create an ALSA kcontrol for
     Phantom Jack**.
   - Because ACP's `jack_probe()` cannot find the kcontrol, it discards the entire `analog-output-speaker` mixer path.
2. **Profile collapse and Dummy Output degradation**:
   - The only remaining analog output path is the headphone jack; when no
     headphones are plugged in, the jack state is `available: no`.
   - All Analog Profiles become `available: no`, and WirePlumber's
     `find-best-profile.lua` can only select `off`, degrading to `Dummy Output`.

---

## 3. Two-Layer UCM2 Defense Architecture

The two-layer fix mechanism implemented in this project:

1. **Layer 1: Deploy complete ALSA UCM2 profile files (PR #832)**:
   - `sof-rt5682.conf` / `HiFi.conf` / `rt5682-headset.conf` / `max98357a/speaker.conf`
   - Precisely routes headphones to PCM 0 and speakers to PCM 5, splitting the dual microphones out of PCM 1 via `SplitPCM`.
   - Bypasses legacy ACP probing; WirePlumber directly applies the UCM HiFi Profile (Priority 9600).
2. **Layer 2: PipeWire ACP Phantom Jack patch (MR #5428)**:
   - Fixes `jack_probe()`: if a jack name that lacks a kcontrol contains
     `Phantom` and is inside `required-any`, it is treated as present and its
     availability is kept as `unknown`.
   - Even in UCM-less Live CD or freshly installed environments, it avoids
     falling into the Dummy Output whole-system-silence pitfall.
