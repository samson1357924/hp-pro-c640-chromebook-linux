<!-- ARCHIVE NOTE
  upstream: https://github.com/alsa-project/alsa-ucm-conf/pull/832
  status:   closed (withdrawn) 2026-08-15 — submitted without coordinating with the
            downstream UCM author first; closed out of respect. Retry path:
            coordinate with WeirdTreeThing (standalone branch author) and/or
            upstream alsa maintainers before resubmitting.
  archived: 2026-08-15
-->
# alsa-ucm-conf PR #832 — ucm2: sof-rt5682: add support for SOF rt5682 Chromebooks

Summary of the submitted upstream PR (commit `676963f`). Full diff: the
vendored files in [audio/ucm/](../ucm/README.md) (22 files total, including
`hdmi2345.conf`/`hdmi567.conf` dependencies required by the dynamic
`/codecs/hda/${var:hdmi}.conf` include).

## Commit message

```
ucm2: sof-rt5682: add support for SOF rt5682 Chromebooks

Add UCM configuration for the sof-rt5682 card used on ChromeOS devices
(Dratini/hatch family and others). The configuration supports the
rt5682/rt5682s headset codecs, max98357a/max98360a/max98373/max98390/
rt1011/rt1015/rt1015p/rt1019p speaker amplifiers, HDMI output and DMIC
capture, with platform detection based on DMI product family.

The files are taken from the standalone branch of
WeirdTreeThing/alsa-ucm-conf-cros. Verified on an HP Pro C640
Chromebook (Dratini, Google_Hatch) running Ubuntu 26.04 LTS with
alsa-lib 1.2.15.3 (UCM syntax 7): speaker, headset jack, DMIC and
HDMI all working, HiFi profile active with no Dummy Output.

Signed-off-by: samson1357924 <98934496+samson1357924@users.noreply.github.com>
```

## Review fixes applied before submission

* Added missing `hdmi2345.conf` / `hdmi567.conf` (dependency closure of the dynamic include)
* Converted `platform.conf` to LF line endings (was CRLF)
* Removed trailing whitespace in `rt5682-init.conf`

## Status

| Check | Result |
| :--- | :--- |
| validate-signedoff | PASS |
| Validate UCM configuration | action_required (first-time contributor — needs maintainer approval) |
| Final | **CLOSED (withdrawn)** 2026-08-15 |

## Follow-up

* Retry path: coordinate with the downstream UCM author (WeirdTreeThing,
  `standalone` branch) and/or upstream alsa maintainers **before** resubmitting;
  agree on attribution and review scope first.
* Until upstreamed, this repo's mirror ([audio/ucm/](../ucm/README.md)) remains
  the install source (see [docs/upstream.md](../docs/upstream.md)).