<!-- ARCHIVE NOTE
  upstream: MR for https://gitlab.freedesktop.org/pipewire/pipewire/-/work_items/5428 (not yet published)
  status:   pending 2026-08-15 (freedesktop fork quota limit — cannot create personal fork)
  archived: 2026-08-15, verbatim from /tmp/opencode/pipewire-mr-body.md
  base:     master @ 195dea9; patch = commit a459563 (same tree, amended message)
  note:     remove line 1 (GitLab issue-template comment) before submitting
-->
<!-- If you are filing this issue with a regular release please try master as it might already be fixed. -->

- PipeWire version: master (`195dea9`)
- Distribution and distribution version: Ubuntu 26.04 LTS
- Desktop Environment: GNOME
- Kernel version: 7.0.0-29-generic

## Summary

When a sound card has no UCM configuration, ACP probes ports from the
alsa-card-profile mixer paths (PulseAudio legacy code). Paths that have
phantom jacks (e.g. `[Jack Speaker Phantom]`) in their `required-any`
list are discarded when the jack has no corresponding ALSA kcontrol,
because `jack_probe()` only marks `req_any_present` for jacks that have
a control.

The kernel creates kcontrols for phantom jacks only on HDA devices. ASoC
devices (such as Chromebooks with the SOF `sof-rt5682` machine driver)
never do, so on those machines the `analog-output-speaker` path (and
others with phantom jacks) is always dropped during probing. The only
surviving output port is the headphone jack; when nothing is plugged in,
every output profile becomes `available: no` and WirePlumber can only
select "off" -> Dummy Output, no sound.

## Fix

In `jack_probe()`, treat a phantom jack without a kcontrol as present:
mark the path's `req_any_present` so the path is kept. The port
availability is left `unknown`, which matches the
`state.plugged/unplugged = unknown` settings in the path configuration
files and makes the profile available while preserving jack
auto-switching for real (non-phantom) jacks.

## Testing

Verified on an HP Pro C640 Chromebook (Dratini, `sof-rt5682`, Comet
Lake) with Ubuntu 26.04 LTS, using a debug build of spa-acp-tool with
UCM disabled (`-p 'api.alsa.use-ucm=false'`):

Without the patch:

```
port 0: analog-input-headset-mic (available: no)
port 1: analog-output-headphones (available: no)
-> all analog profiles available: no, only "off" remains
```

With the patch:

```
port 0: analog-input-headset-mic (available: no)
port 1: analog-output-speaker    (available: unknown)   <-- new
port 2: analog-output-headphones (available: no)
output:stereo-fallback                       (available: yes)
output:stereo-fallback+input:stereo-fallback (available: yes)
```

The patch is strictly additive: it can only turn a previously
discarded path into a present one, and only affects the no-kcontrol
case for phantom jacks. HDA cards (which do have phantom kcontrols)
and UCM-configured cards are unaffected.

### Honest limitation

Without UCM, the fallback sink uses `hw:0` (the rt5682 headphone DAC,
PCM 0 on this card), while the internal speakers are on PCM 5
(max98357a). So on this particular machine "profile available" does
not by itself guarantee sound on the internal speakers without
plugging in headphones; correct routing still requires the UCM
configuration (upstreaming in alsa-project/alsa-ucm-conf#832). The
value of this patch is that the card gets a working output profile
instead of only Dummy Output, and paths with phantom jacks behave as
their configuration intends on ASoC hardware.

Fixes: #5428