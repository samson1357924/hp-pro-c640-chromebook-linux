# Root Cause: Dummy Output on sofrt5682 (HP Pro c640)

## 1. TL;DR

* **Symptom**: Settings shows "Dummy Output"; there is no sound at all.
* **Root cause**: The distro `alsa-ucm-conf` package ships **no UCM configuration
  for the `sofrt5682` card** → ALSA Card Profile (ACP) falls back to mixer-path
  probing → every analog output profile is marked `available: no` → WirePlumber
  can only select the `off` profile → no real sink → Dummy Output.
* **Evidence chain**: `strace` (UCM file search ENOENT) + `spa-acp-tool` A/B
  comparison + clean dmesg. Full details below.

## 2. Affected Environment

* Sound card: `sofrt5682` (card 0) — Intel SOF DSP + rt5682 headset codec +
  max98357a speakers.
* Verified broken on: Ubuntu 26.04 LTS, alsa-ucm-conf 1.2.15.3-1ubuntu1.5,
  pipewire 1.6.2-1ubuntu1.1, wireplumber 0.5.13-1ubuntu1, kernel 7.0.0-29-generic.

## 3. Symptoms

* GUI: "Dummy Output" in sound settings; no real device listed.
* `wpctl status`: no physical sink; the only available profile is `off`.
* Audio: speakers **and** headphone silent.
* `dmesg`: completely clean — firmware loads fine, no `cl_dsp_init` timeout.
  This is what ruled out the firmware theory.

## 4. Wrong Explanations (excluded — do not revisit)

| Old theory | Refutation |
| :--- | :--- |
| SOF firmware missing | `dmesg | grep -i sof` shows clean load; `/lib/firmware/intel/sof/` populated; `lsmod | grep snd_sof` shows modules loaded. |
| Reinstall `firmware-sof-signed` | No effect — package was present and correct. |
| PipeWire/WirePlumber config broken | Fresh installs reproduce it; service logs show only ACP profile enumeration warnings. |

## 5. The Real Chain

1. ALSA UCM2 card configs live in `/usr/share/alsa/ucm2/conf.d/<card>/`.
   Ubuntu's `alsa-ucm-conf` has **no `sof-rt5682` directory** (the card name in
   UCM keeps its dash: `sof-rt5682`).
2. `alsa-card-profile` (ACP, ported from PulseAudio) probes the card:
   * **With UCM** → profiles are defined by the UCM use-cases (`EnumProfile`).
   * **Without UCM** → mixer-path probing: each output profile requires at
     least one *alive* port (a port whose jack kcontrol reports "plugged" or
     that needs no jack at all).
3. **Evidence A — strace shows the failed search**:
   ```bash
   strace -f -e trace=openat,newfstatat -o /tmp/wp.strace \
     systemctl --user restart wireplumber
   grep -E 'sof-rt5682|CardLongName' /tmp/wp.strace | grep ENOENT
   # openat(.../conf.d/sof-rt5682/driver.conf) = -1 ENOENT
   # openat(.../conf.d/sof-rt5682/CardLongName.conf) = -1 ENOENT
   ```
4. Mixer-path probing result: only the **Headphone Jack** path survives:
   * Speaker path: `max98357a` has **no jack detection** → the port needs no
     kcontrol only if the path is defined as always-present; with the distro
     paths, the speaker port has no jack kcontrol at all, so it is dropped.
   * Headphone path survives probing, but the jack is unplugged →
     `available: no`.
5. Conclusion: every analog output profile is `available: no` → WirePlumber
   only has `off` → no sink → upper layers show Dummy Output.
6. **Evidence B — spa-acp-tool A/B comparison** (same machine, same session):
   ```bash
   ACP_PATHS_DIR=/usr/share/alsa-card-profile/mixer/paths \
   ACP_PROFILES_DIR=/usr/share/alsa-card-profile/mixer/profile-sets \
   spa-acp-tool -p 'api.alsa.use-ucm=false' -c 0 list-profiles
   # → only "off" / output:stereo-fallback available: no
   ```
   With `api.alsa.use-ucm=true` (UCM installed):
   `output:stereo-fallback available: yes` and the HiFi profiles listed.
7. **Evidence C — clean dmesg** excludes the kernel/firmware layer and locks
   the fault into the userspace configuration layer.

## 6. Pitfalls

* **alsaucm test trap**: `alsaucm -c sofrt5682` (non-hw mode) does **not** search
  `conf.d/` — only `-c hw:0` does. Verify with `strace -e openat alsaucm ...`.
  Don't trust a test tool's behavior until you've verified how it searches.
* **Card name vs UCM dir**: ALSA card is `sofrt5682` (no dash); the UCM
  directory is `sof-rt5682`. Mixing them up makes "it's installed!" checks
  produce false positives.
* **Silent fallback**: alsa-lib silently ignores missing UCM — nothing in
  `journalctl` says "UCM missing". Absence of errors ≠ configuration present.
* **Intel ME**: on a machine with Intel ME disabled, SOF fails with
  `cl_dsp_init: timeout with rom_status_reg` — a *different* failure mode from
  this issue; don't conflate the two.

## 7. Lesson: Wrong Direction (force-sof-profile.lua)

An earlier attempt forced the `stereo-fallback` profile to `available: yes`
via a WirePlumber Lua hook. It failed for three reasons:

1. **Routing**: the fallback sink opens `hw:0` = **PCM0** = the *headphone*
   DAC (rt5682). The physical speakers are on **PCM5** = `max98357a`. Result:
   speakers silent (and the headphone jack may even produce sound).
2. **Index semantics**: ACP fallback device indexes are *ordinal* numbers, not
   ALSA PCM numbers — `hw:0,X` mapping is non-intuitive and easy to get wrong.
3. **Design**: routing is UCM's job. Bypassing it with a hook is treating the
   symptom; it also breaks jack auto-switching.

The hook file was removed from this system. Do not reintroduce it.

## 8. Fallback Routing Limits (no UCM)

| ALSA PCM | Physical device |
| :--- | :--- |
| 0 | Port1 headphone (rt5682) |
| 5 | Speakers (max98357a) |
| 8 | DMIC16kHz (capture) |

Without UCM there is **no automatic routing**: the fallback sink stays on
PCM0, so `speaker-test -D hw:0,5` works for speakers but nothing switches
between speaker and headphone.

## 9. Fix

Install the UCM profiles (see [../README.md](../README.md#installation-ucm-profiles)):
`./audio/install-audio-ucm.sh`, then `systemctl --user restart wireplumber`.

## 10. References

* [upstream.md](upstream.md) — issue #433, PR #832, RFC #5428, phantom-jack MR.
* [diagnostics.md](diagnostics.md) — toolchain SOP and the UCM × jack test matrix.