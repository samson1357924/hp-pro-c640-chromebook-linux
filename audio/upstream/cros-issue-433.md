<!-- ARCHIVE NOTE
  upstream: https://github.com/WeirdTreeThing/chromebook-linux-audio/issues/433
  status:   published 2026-08-15
  archived: 2026-08-15, verbatim from /tmp/opencode/cros-issue-body.md
-->
**Describe the bug**

This is a **success report**, not a bug. After installing the downstream UCM configuration for this device, ALL audio functionality works correctly on Ubuntu 26.04 LTS with the official (non-custom) kernel:

- **Internal speakers** — working, set as the default output, hardware volume control works (DAC1 Playback Volume + Spk Switch handled by the UCM)
- **Headphone jack** — working, auto-switches between Speaker and Headphones on jack insert/remove (rt5682 jack detection)
- **Internal microphones** — working (DMIC via PCM split into 2 stereo channels; sources "Internal Microphone 1" and "Internal Microphone 2")
- **Headset microphone** — working
- **HDMI audio output 1/2/3** — working
- No Dummy Output, no errors in WirePlumber logs, stable across reboots

The fix consisted of installing the downstream UCM from `WeirdTreeThing/alsa-ucm-conf-cros` (standalone branch, files verified md5-identical to the repo):

- `/usr/share/alsa/ucm2/conf.d/sof-rt5682/` (sof-rt5682.conf, HiFi.conf, rt5682-headset.conf, rt5682-init.conf)
- `/usr/share/alsa/ucm2/platforms/intel-sof/` (platform.conf, codecs.conf)
- `/usr/share/alsa/ucm2/codecs/max98357a/speaker.conf`
- `/usr/share/alsa/ucm2/codecs/hda/hdmi234.conf`

Active profile is now `HiFi` (available=yes, priority 9600). Before the UCM install, WirePlumber could only select the "off" profile (all fallback profiles were `available: no`) and the system only had the Dummy Output sink.

This confirms that Dratini audio works on modern userspace. The failure mode described in issue #265 ("Incompatible syntax 7 in sof-rt5682.conf" on old LTS userspace) does not apply to Ubuntu 26.04, since alsa-lib 1.2.15.3 fully supports UCM syntax 7. This report may be relevant for closing #265.

Note: Intel ME is **enabled** in the UEFI settings (see issue #394 — with Intel ME disabled the SOF DSP fails to boot with `cl_dsp_init: timeout with rom_status_reg`).

**Distro name and version**

- Ubuntu 26.04 LTS x86_64 (`PRETTY_NAME="Ubuntu 26.04 LTS"`, `VERSION_ID="26.04"`, codename `resolute`)
- Kernel: `7.0.0-29-generic` (Ubuntu official kernel, `#29-Ubuntu SMP`, gcc 15.2.0, from Launchpad buildd — NOT a custom build)
- alsa-ucm-conf: `1.2.15.3-1ubuntu1.5`
- alsa-utils: `1.2.15.2-1ubuntu1`
- libasound2t64 / libasound2-data: `1.2.15.3-1ubuntu1.1`
- pipewire: `1.6.2-1ubuntu1.1`
- wireplumber: `0.5.13-1ubuntu1`
- gstreamer1.0-pipewire: `1.6.2-1ubuntu1.1`

**Boardname**

`Dratini` — HP Pro C640 Chromebook (hatch family)

DMI details:
- `product_family: Google_Hatch`
- `product_name: Dratini`
- `sys_vendor: Google`
- ALSA card: `sofrt5682` ("HP-Dratini-rev4"), SOF driver `sof-audio-pci-intel-cnl`, firmware `intel/sof/community/sof-cml.ri` version 2:2:0-57864

**Sound card / ALSA PCM layout**

```
$ cat /proc/asound/cards
 0 [sofrt5682      ]: sof-rt5682 - sof-rt5682
                      HP-Dratini-rev4

Playback:  device 0 = Port1 (rt5682 headphones), 2/3/4 = HDMI 1/2/3, 5 = Speakers (max98357a amp)
Capture:   device 0 = Port1 (headset mic), 1 = DMIC 48k, 8 = DMIC16kHz
```

**Loaded kernel modules**

`snd_soc_sof_rt5682`, `snd_soc_max98357a`, `snd_soc_rt5682`, `snd_sof`, `snd_sof_pci_intel_cnl`, `snd_soc_intel_sof_realtek_common`, `snd_soc_intel_sof_maxim_common` — all loaded.

**Current PipeWire state (after fix)**

```
Sinks:  * Speaker (default, vol controllable)
        Headphones
        HDMI / DisplayPort 1/2/3 Output
Sources: Headset Microphone
        Internal Microphone 1 (and 2, split)
Device profiles: HiFi = available yes (active), pro-audio = unknown
Default sink: alsa_output.pci-0000_00_1f.3-platform-cml_rt5682_def.HiFi__Speaker__sink
```

`journalctl --user -u wireplumber -b | grep -i error` → **no matches**.

**Logs**

[attach `debug-logs-Dratini-*.tar.gz` produced by `debugging.sh` as required by the issue template]

Additional context for maintainers: the UCM files installed are byte-identical to the `standalone` branch of `WeirdTreeThing/alsa-ucm-conf-cros` (verified via md5 comparison of all 8 files). They were installed manually (not via apt; `dpkg -S` shows no package owns them), so they are not overwritten by `alsa-ucm-conf` package updates (`alsa-ucm-conf` was updated to `1.2.15.3-1ubuntu1.5` on 2026-08-12 without touching the cros files).