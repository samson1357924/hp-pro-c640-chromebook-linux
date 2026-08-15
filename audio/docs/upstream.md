# Upstream Status & Contributor Actions (sof-rt5682 UCM)

## 1. Upstream Tracking

| Track | Content | Status | URL |
| :--- | :--- | :--- | :--- |
| alsa-ucm-conf PR #832 | Upstream the 22 UCM files for sof-rt5682 | **closed (withdrawn)** 2026-08-15 — submitted without coordinating with the downstream UCM author first; retry requires prior coordination (see [../upstream/alsa-ucm-conf-pr-832.md](../upstream/alsa-ucm-conf-pr-832.md)) | https://github.com/alsa-project/alsa-ucm-conf/pull/832 |
| cros issue #433 | Success report for the downstream UCM | published | https://github.com/WeirdTreeThing/chromebook-linux-audio/issues/433 |
| pipewire work item #5428 | RFC: ACP marks all analog profiles `available: no` when no UCM exists | open | https://gitlab.freedesktop.org/pipewire/pipewire/-/work_items/5428 |
| pipewire phantom-jack MR | Fix: phantom jacks (ASoC has no phantom jack support) → treat as always-present | **not submitted** — freedesktop fork quota limit blocks creating a personal fork | materials in [../upstream/](../upstream/) |

Archived copies: [audio/upstream/](../upstream/README.md).

## 2. Known-Good Environment Table

| Environment | alsa-ucm-conf | pipewire | wireplumber | SOF fw | Result |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Ubuntu 26.04 LTS (this repo, verified 2026-08-15) | 1.2.15.3-1ubuntu1.5 (no sof-rt5682) + repo mirror UCM | 1.6.2-1ubuntu1.1 | 0.5.13-1ubuntu1 | 2:2:0-57864 | working |
| Ubuntu 26.04 LTS stock | 1.2.15.3-1ubuntu1.5 | 1.6.2-1ubuntu1.1 | 0.5.13-1ubuntu1 | 2:2:0-57864 | Dummy Output |

Add rows with tester + date as new versions are validated.

## 3. Contributor Follow-up Checklist

* [ ] Coordinate with the downstream UCM author (WeirdTreeThing) and agree on
  attribution/review scope; then retry upstreaming the sof-rt5682 UCM to
  alsa-ucm-conf (PR #832 was withdrawn 2026-08-15)
* [ ] Track #5428; report ACP behavior changes across PipeWire releases
* [ ] Once the freedesktop quota issue is resolved, submit the phantom-jack MR
  (body: [../upstream/pipewire-mr-5428.md](../upstream/pipewire-mr-5428.md),
  base master `195dea9`, patch = commit `a459563`)
* [ ] After UCM upstreaming succeeds: unpin this repo's UCM mirror
  ([audio/ucm/](../ucm/README.md)) and prefer the distro package
* [ ] Update the Known-Good table after OS/kernel upgrades

## 4. Related

* Root cause: [root-cause.md](root-cause.md) — Diagnostic SOP: [diagnostics.md](diagnostics.md)