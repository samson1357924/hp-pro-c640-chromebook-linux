# Audio Diagnostics SOP (sofrt5682)

## 1. Prerequisites

* `pipewire`, `wireplumber`, `pipewire-tools` (for `spa-acp-tool`), `alsa-utils`.
* Run from a **normal login session** (the `--sim-no-ucm` mode restarts your
  PipeWire session).

## 2. Toolchain

### 2.1 `wpctl status`
Sinks/sources, the `*` default marker, and profile state.
```bash
wpctl status
```

### 2.2 `wpctl inspect` / `wpctl get-volume`
```bash
wpctl inspect @DEFAULT_AUDIO_SINK@
wpctl get-volume @DEFAULT_AUDIO_SINK@
```

### 2.3 `pw-dump`
Node objects carry `api.alsa.*` props and the active profile:
```bash
pw-dump | jq -r '.. | objects | select(.type? == "PipeWire:Interface:Node") |
  .info.props | "\(.["node.name"]) profile=\(.["api.alsa.profile"])"'
```

### 2.4 `spa-acp-tool` — the A/B probe (main tool)
```bash
export ACP_PATHS_DIR=/usr/share/alsa-card-profile/mixer/paths
export ACP_PROFILES_DIR=/usr/share/alsa-card-profile/mixer/profile-sets
spa-acp-tool -vvvv -p 'api.alsa.path=hw:0' -p 'api.alsa.use-ucm=false' list-profiles
spa-acp-tool -vvvv -p 'api.alsa.path=hw:0' -p 'api.alsa.use-ucm=true'  list-profiles
```
Expected difference:
* `use-ucm=false` → only `off` (and `output:stereo-fallback available: no`).
* `use-ucm=true` → HiFi family profiles with `available: yes`.

`-vvvv` is required for profile/port probe debug (levels below 4 silence it).

### 2.5 `alsa-info.sh`
```bash
wget https://www.alsa-project.org/alsa-info.sh && sh alsa-info.sh
```
Upload and attach the URL when reporting issues.

### 2.6 `alsactl init`
```bash
sudo alsactl init
```
Shows UCM2 load errors (the no-UCM case has a characteristic error).

### 2.7 `journalctl -u wireplumber`
```bash
journalctl --user -u wireplumber -e
# keywords: ACP, "Failed to enumerate profiles", profile warnings
```

### 2.8 `dmesg`
```bash
dmesg | grep -i -E 'sof|rt5682|max98357'
```
Clean output rules out firmware/kernel (see [root-cause.md §4](root-cause.md)).

## 3. "No UCM" Checklist

* [ ] `wpctl status` shows no physical sink; profile = `off`
* [ ] ACP enumeration warnings in WirePlumber logs
* [ ] `spa-acp-tool` with `use-ucm=false` lists only `off`
* [ ] `strace` shows `conf.d/sof-rt5682/*.conf` ENOENT
* [ ] `/usr/share/alsa/ucm2/conf.d/sof-rt5682/` missing the 8 files
* [ ] `dmesg` clean (firmware ruled out)

5+ checks → high-confidence "missing UCM" diagnosis.

## 4. Test Matrix (UCM × headphone)

| Scenario | wpctl profile | Available ports | Playback | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| No UCM, no headphone | off / Dummy Output | none | fails | bug reproduced |
| No UCM, headphone in | off (or headphone available) | headphone only | headphone ok, speakers silent | fallback limit ([root-cause §8](root-cause.md)) |
| UCM, no headphone | HiFi / Speaker | Speaker | speakers ok | fixed |
| UCM, headphone in | HiFi (auto-switch) | Speaker→Headphone | auto-switch works | fixed |

Note: to test speakers directly use `speaker-test -D hw:0,5` (PCM5). Testing
the default sink routes to PCM0 (headphone DAC).

## 5. Quick Fix

1. `./audio/install-audio-ucm.sh` (or manual steps in [audio/README.md](../README.md)).
2. Verify md5 (see [audio/ucm/README.md](../ucm/README.md)).
3. `systemctl --user restart wireplumber`.
4. Re-run the matrix rows 3–4.

## 6. Reporting

Paste the checklist result + an `alsa-info.sh` URL into a
[hardware issue](../../.github/ISSUE_TEMPLATE/hardware_issue.yml) using
`./audio/diagnose-audio.sh -o /tmp/audio-report.txt`.