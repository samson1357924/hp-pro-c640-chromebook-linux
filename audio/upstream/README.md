# Upstream Contribution Archive (sof-rt5682 audio)

Archive of upstream contribution materials produced while fixing audio on the
HP Pro c640 Chromebook (Dratini). Files are archived **verbatim** (plus a
strippable `<!-- ARCHIVE NOTE -->` header); the table below is the single
source of truth for status.

## Index

| File | Upstream project | Type | Status | Date | URL | Corresponding commit |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| [cros-issue-433.md](cros-issue-433.md) | WeirdTreeThing/chromebook-linux-audio | issue (success report) | published | 2026-08-15 | https://github.com/WeirdTreeThing/chromebook-linux-audio/issues/433 | — |
| [alsa-ucm-conf-pr-832.md](alsa-ucm-conf-pr-832.md) | alsa-project/alsa-ucm-conf | PR (UCM upstreaming) | closed (withdrawn) | 2026-08-15 | https://github.com/alsa-project/alsa-ucm-conf/pull/832 | `676963f` |
| [pipewire-issue-5428.md](pipewire-issue-5428.md) | pipewire/pipewire | work item (RFC) | published | 2026-08-15 | https://gitlab.freedesktop.org/pipewire/pipewire/-/work_items/5428 | — |
| [pipewire-mr-5428.md](pipewire-mr-5428.md) | pipewire/pipewire | MR body (ACP phantom jack fix) | pending | 2026-08-15 | — (not yet published; freedesktop fork quota limit) | `a459563` |
| [pipewire-acp-phantom-jack.patch](pipewire-acp-phantom-jack.patch) | pipewire/pipewire | patch (git format-patch) | pending | 2026-08-15 | — | `a459563` |

## Snapshot hashes (sha256)

| File | sha256 |
| :--- | :--- |
| cros-issue-433.md | `a81af9228334e3bb001b767502fdf530daa775863f966f60eff43c000810cd8d` |
| alsa-ucm-conf-pr-832.md | `6d743c0de068f28706537a940d346bfdba550ebfef19bf13fa9e294fd6b54ecb` |
| pipewire-issue-5428.md | `fb5ec553c1ba13c16d8cf334e00f89ef0ec237314af227f798f3ba6bd6c23389` |
| pipewire-mr-5428.md | `308a155a929732190bf8dc3b025d2c0b0865716cabfb7b76e292c318c9602086` |
| pipewire-acp-phantom-jack.patch | `a3c0b2bbf16e6ae2067ddbdbb343b4cdf0543632bc7311b2a59634408a128093` |

## License

* Issue/MR bodies and the PR summary: self-authored, MIT.
* Patch: diff of MIT-licensed PipeWire code, authored by samson1357924.
* UCM content referenced by PR #832: BSD-3-Clause (see [audio/ucm/LICENSE](../ucm/LICENSE)).

## Status update procedure

* Change a status: update this table **and** the `<!-- ARCHIVE NOTE -->` header
  of the affected file only — never rename files (names are stable identities).
* Publish the pending MR: remove the template comment on line 1 of
  `pipewire-mr-5428.md` first, submit against master `195dea9`, then update
  this table with the MR URL.