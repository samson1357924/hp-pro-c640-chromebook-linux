<!-- ARCHIVE NOTE
  upstream: https://gitlab.freedesktop.org/pipewire/pipewire/-/work_items/5428
  status:   published 2026-08-15
  archived: 2026-08-15, verbatim from /tmp/opencode/pipewire-issue-body.md
-->
<!-- If you are filing this issue with a regular release please try master as it might already be fixed. -->

- PipeWire version (`pipewire --version`): 1.6.2 (1.6.2-1ubuntu1.1)
- Distribution and distribution version (`PRETTY_NAME` from `/etc/os-release`): Ubuntu 26.04 LTS
- Desktop Environment: GNOME
- Kernel version (`uname -r`): 7.0.0-29-generic

## Description of Problem

On an HP Pro C640 Chromebook (Intel Comet Lake, SOF audio driver, ALSA card `sof-rt5682`, DMI `Google_Hatch`/`Dratini`), **when no ALSA UCM configuration is present for the card, ACP (alsa-card-profile, ported from PulseAudio) marks every analog output profile as `available: no`**. WirePlumber therefore can only select the "off" profile, the system ends up with only the Dummy Output sink, and there is **no sound at all**.

Installing the downstream UCM for this card (WeirdTreeThing/alsa-ucm-conf-cros, `sof-rt5682` directory) makes everything work (Speaker/Headphones/DMIC/HDMI, jack auto-switch), so the kernel/ALSA driver side is fine.

The same symptom is reported by another Chromebook user (Google-Omnigul-rev3, `adl_rt5682`): https://discussion.fedoraproject.org/t/i-have-a-problem-with-an-audio-and-a-microphone-fedora-43-kde/177610/5 (shows `output:stereo-fallback ... available: no` and the only port `analog-output-headphones` marked `not available`).

## Root cause analysis (from the machine)

Without UCM, ACP probes output ports from the alsa-card-profile mixer paths (default.conf profile set). On this card only the `Headphone Jack` path probes successfully. Since no headphones are plugged in, that port is marked unavailable. Because **the only output port is unavailable**, every analog output profile — including `output:stereo-fallback` — becomes `available: no`, and WirePlumber's `find-best-profile` falls back to "off".

Additionally, the `stereo-fallback` profile's sink references **ACP device index 9**, but this card only has PCM devices 0–8 (device 8 is a capture-only DMIC16kHz). Even if the profile is force-activated (e.g. `wpctl set-profile`), the ACP availability check for the fallback sink fails because the referenced PCM device does not exist.

## How Reproducible

Always reproducible on this machine while the UCM config is absent (and always NOT reproducible once the UCM is installed).

### Steps to Reproduce

 1. Boot with the SOF `sof-rt5682` card and no UCM config installed (e.g. `sudo mv /usr/share/alsa/ucm2/conf.d/sof-rt5682 /tmp/` on this machine).
 2. `systemctl --user restart wireplumber`
 3. Inspect the card profiles.

### Actual Results

Verified via `pw-dump` on this machine (UCM config temporarily removed):

```
EnumProfile (alsa_card.pci-0000_00_1f.3-platform-cml_rt5682_def):
  off:                                       available=yes   priority=0
  output:stereo-fallback+input:stereo-fallback: available=no  priority=5151
  output:stereo-fallback:                    available=no   priority=5100
  input:stereo-fallback:                     available=no   priority=51
  pro-audio:                                 available=unknown priority=1
ACTIVE: off
```

`wpctl status` shows only `Dummy Output` as sink. No sound.

### Expected Results

With the same hardware but the UCM installed:

```
EnumProfile:
  off:    available=yes
  HiFi:   available=yes   priority=9600   <- active
  pro-audio: available=unknown
Sinks: Speaker (default), Headphones, HDMI/DP 1/2/3
Sources: Headset Microphone, Internal Microphone 1/2
```

All audio paths work. This is the behaviour PulseAudio exhibits with the same ACP codebase: an analog profile should be usable without UCM.

## Possible improvements (for discussion)

1. **When no UCM is present and mixer-path probing finds no *available* output port**, do not mark the fallback/stereo profile as `available: no`. Probe and use the first working PCM device instead (this card has a perfectly working Speaker PCM at device 5), or at least leave the profile `available: unknown` so WirePlumber can try it.
2. **Fix the fallback sink device index** so it always references an existing PCM device (on this card index 9 > max device 8, so availability can never succeed — currently the only way to get sound without UCM is force-selecting pro-audio).
3. This interacts with WirePlumber's profile selection: https://gitlab.freedesktop.org/pipewire/wireplumber/-/issues/613 and https://gitlab.freedesktop.org/pipewire/wireplumber/-/issues/847.
4. Possibly related ongoing work: MR https://gitlab.freedesktop.org/pipewire/pipewire/-/merge_requests/2946 (`acp: add an option to configure min-output-mappings for profiles`) and MR !2947.

## Additional Info (as attachments)

- `pw-dump > pw-dump.log`: can provide both the "no UCM" and "with UCM" dumps on request
- `aplay -l`: devices 0 (Port1), 2/3/4 (HDMI 1/2/3), 5 (Speakers); capture 0, 1 (DMIC), 8 (DMIC16kHz) — note there is no PCM device 9
- `dmesg | grep -iE "sof|rt5682|snd"`: SOF firmware 2:2:0-57864 loads cleanly
- `spa-acp-tool l` (without UCM): profile list as shown above

Card details: `sofrt5682` ("HP-Dratini-rev4"), SOF driver `sof-audio-pci-intel-cnl` (Comet Lake PCH-LP cAVS, [8086:02c8]), topology `sof-cml-rt5682-max98357a.tplg` (rt5682 headset codec + max98357a speaker amp).