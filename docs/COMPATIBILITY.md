# 📊 Hardware Compatibility Matrix

Hardware component support under Linux for the HP Pro c640 Chromebook
(codenamed **Google `dratini`**, baseboard **`hatch`**, Intel 10th Gen Comet
Lake-U platform):

---

## 💻 Component Status Overview

| Hardware Component | Chip Model / Spec | Linux Kernel Driver | Support Status | Notes / Solutions |
| :--- | :--- | :--- | :---: | :--- |
| **Fingerprint Reader** | Fingerprint Cards FPC1025 (FPMCU MoC) | `/dev/cros_fp` (`cros_ec_spi`) | 🟢 **Working** | This project's `crfpmoc` driver + PAM; lock-screen unlock and `sudo` **hardware-tested 2026-08-19**. |
| **Built-in Stereo Speakers** | Maxim MAX98357A (I2S Amp) | `snd_soc_max98357a` | 🟢 **Working** | Output via ALSA UCM2 PCM 5; **hardware-tested** (Chromium playback). |
| **3.5mm Headphone Jack** | Realtek RT5682 (I2C) | `snd_soc_rt5682` | ⚠️ **Driver bound** | Device present (PCM 0); **auto-switch on plug/unplug not captured in evidence**. |
| **Built-in Digital Microphones** | 2-channel PDM DMIC | `snd_soc_dmic` | 🟢 **Working** | UCM PCM Split into stereo Mic 1 / Mic 2; **hardware-tested**. |
| **Wi-Fi 6** | Intel Wi-Fi 6 AX201 (CNVi) | `iwlwifi` | ⚠️ **Driver bound** | Loads out of the box; **WPA3 / throughput not measured** on this device. |
| **Bluetooth 5.0** | Intel AX201 Bluetooth | `btusb` / `btintel` | ⚠️ **Driver bound** | Controller present; **pairing / A2DP audio not captured in evidence**. |
| **Touchpad** | ELAN I2C Touchpad | `i2c_hid` / `elan_i2c` | ⚠️ **Driver bound** | Module present; **multi-finger gestures / palm rejection not functionally tested**. |
| **Touchscreen (optional)** | Goodix / ELAN / G2Touch | `i2c_hid_acpi` | ⚠️ **Driver bound** | Module present; **multi-touch / stylus input not functionally tested**. |
| **GPU / Integrated Graphics** | Intel UHD Graphics 620 | `i915` | ⚠️ **Driver bound** | Display works out of the box; **VA-API 4K 60fps decode not measured**. |
| **Webcam** | 720p HD Camera (with privacy shutter) | `uvcvideo` | ⚠️ **Driver bound** | Standard USB UVC camera; **capture not tested**. |
| **Dual Type-C Output** | 2x USB-C 3.2 Gen 1 (PD + DP) | `typec` / `xhci_pci` | ⚠️ **Charging works** | PD charging nodes present; **DP 1.2 display output not verified**. |
| **Keyboard Top-Row Keys & Backlight Sync** | ChromeOS Top-Row + `chromeos::kbd_backlight` | `udev hwdb` / `keyd` + `c640-kbd-backlight-sync` (user service + system-sleep) + `61-chromeos-kbd-backlight.rules` | 🟢 **Top-row + dual-role + backlight verified (2026-10-31)** | Top-row hwdb maps AT scancodes `0x3b`-`0x44` inferred from post-hwdb `EVIOCGKEY` against the standard AT table (not the ChromeOS action scancodes); `check-top-row-hwdb.py` confirmed all 11 `EVIOCGKEYCODE` entries on the real keyboard (kernel map only — raw `MSC_SCAN` was not captured; confirm with `--scan` after stopping keyd), and a real-key passive capture confirmed the presses reach the desktop as post-hwdb `EV_KEY`. keyd dual-role Search: virtual uinput test PASS for tap CapsLock (no Meta/guard), **lone hold** Super with no `LEFTCTRL` guard, Super+TopRow F1–F10 (all ten; the `[meta:M]` layer's `LEFTCTRL` chord guard is expected here) and each top-row key alone; real-key passive capture confirmed lone hold → GNOME overview and single presses → brightness/volume/mute. Backlight auto-off/restore on screen blank verified (`ScreenSaver.ActiveChanged` 2→0→2, no sudo) and sleep hook publishes S3 handoff files (thawed user daemon performs the restore) verified; sysfs `0660 root:plugdev`. A full S3 freeze/thaw was observed 2026-11-22 (`rtcwake` + `systemctl suspend`) with the **old hook** — historical evidence only; **the current HEAD (new selector/root boundary) is pending on the target machine**, and a manual lid-close cycle remains a supplementary to-test. **keyd version scope:** syntax validated in CI with 2.6.0 (`keyd check` only); tap/hold/guard behaviour validated on the device with 2.5.0-5 only; other versions unverified (upstream 2.6.x has known `overloadt2` behaviour differences). |
| **Standby / Sleep** | S0ix Modern Standby + ACPI S3 | `s2idle` + `deep` | 🟢 **S3 lid cycle verified** | S3 `deep` default; real lid-close cycle tested 2026-08-18. **Key/fingerprint wake untested**; panel stays dark on lid open until a keypress (see [TROUBLESHOOTING.md §15](TROUBLESHOOTING.md)). |

### Sleep-hook handoff support scope

The root system-sleep hook publishes S3 handoff files only under these conditions:

1. **Session selection.** It accepts **zero or exactly one** qualifying session — an active,
   local, graphical user session confirmed by `loginctl show-session` (`Active=yes`,
   `Remote=no`, `Class=user`, `Type=wayland|x11`, non-closing `State`, non-empty `Seat` and a
   numeric **Session.User**, printed as `User=<uid>`) **and** `show-seat ActiveSession`.
   **`UID=` is a User-object (logind private state) property, not a session property** and is
   never parsed from `show-session`. Session IDs are **alphanumeric** strings (e.g. `c1`), not
   decimal-only. Greeter, SSH, tty and background sessions never qualify. Zero candidates,
   multiple candidates (including multi-seat ambiguity) or a missing/unusable property —
   including a missing `User` — fail closed: no handoff is written, but the root
   `/run/c640-kbd-backlight/state` diagnostic snapshot is still saved. The decision goes to
   the **root journal** as `selected session ... for uid ...` or
   `session selection fail-closed: ...`; the daemon does no cross-uid scan. The read-only
   `keyboard/tests/loginctl-contract-check.sh` validates this schema against the real
   `loginctl` on a running systemd host (`CONTRACT OK`; `SKIP` on non-systemd) — it does
   **not** perform an S3 cycle.
2. **Runtime dir.** `/run/user/<uid>` must already exist, must not be a symlink, must be
   exactly mode `0700` and owned by the selected uid. The hook **never** creates, chmods or
   chowns it; a missing/insecure dir is fail-closed (no handoff).
3. **Missing loginctl properties.** If `Active` / `Remote` / `Class` / `Type` / `State` /
   `Seat` / `User` / `ActiveSession` is missing or unusable, that session is rejected; with no
   surviving candidate the hook fails closed.
4. **`C640_KBD_HANDOFF_DIR` override.** An explicit override bypasses loginctl selection and
   uid pinning entirely. **Without an override**, `post` reuses the uid pinned by `pre`
   (verification only, never re-selection). The daemon warns only for an explicit override
   mismatch; it does not scan
   other uids.
5. **No `/tmp` fallback.** A runtime dir that disappears at `post` is fail-closed; the hook
   never falls back to `/tmp` or any other directory.
6. **Root write boundary.** The two user handoff files are published by an inline
   `python3` writer with a **pinned directory fd** (`O_DIRECTORY|O_NOFOLLOW`, an
   `O_EXCL|O_NOFOLLOW` `0600` temp, `fchmod`/`fchown`, directory-identity recheck,
   `os.rename` with `src_dir_fd`/`dst_dir_fd`, then published-inode verification) —
   the fd-pinned equivalent of `mv -T -f --`, with **no `cp` and no plain-`mv`
   fallback**. The root diagnostic snapshot and the uid pin still use a guarded
   same-directory `mv -T -f --`. For the handoff writer, the destination entry is guarded both before and
   after the content is staged: the final component must be absent or a regular file; a
   symlink, directory or special entry fails closed with `unsafe destination entry` (or
   `cannot publish ...`), and the parent directory's `(dev,ino)` identity is rechecked so a
   rename cannot redirect the write. There is **no `cp` fallback and no plain-`mv`
   fallback** that could dereference the entry. `C640_KBD_HANDOFF_DIR` is trusted by design
   (an explicit override is only checked with `-d`; the caller owns that path), but the final
   component is still protected by the same guard.

> [!IMPORTANT]
> **Real S3 status:** the 2026-11-22 full freeze/thaw result below is historical evidence
> from the old hook. The new `Session.User` selector and root write boundary have only
> been validated by the local contract check, stub suites and CI — **they have NOT been
> re-run on real S3 on the HP Pro c640 with this HEAD** (pending on the target machine).
> See the checklist in [verification.md §3](verification.md).

#### Fail-closed messages and handling (17th re-review)

| Message (root/user journal) | Meaning | Handling |
| :--- | :--- | :--- |
| `Uncertain PAM rule syntax in <file> ... refusing to modify PAM configuration` / `numeric jump target identity changes after removing fingerprint module` | A custom PAM stack could not be parsed safely, or removing an fp module would change a numeric-jump landing. | Install exits non-zero **before any PAM edit**; no snapshot or debconf change. Review the custom stack by hand and re-run — do not substitute a substring `sed`. |
| `suspend/resume handoff token mismatch ...`, `cycle-begin file ... not adopted`, `suspend handoff token epoch ... stale` | The handoff does not belong to this suspend cycle (stale copy, forged flag or a failed `pre`). | The daemon leaves the saved brightness unchanged; treat it as a failed handoff, not a restore. Re-run the S3 cycle; see [verification.md](verification.md) §3. |
| `retry epoch invalidation failed; all brightness writers fail closed` / `retry epoch channel unhealthy; all brightness writers fail closed` | Even in-place epoch revocation failed (`COORDINATION_UNHEALTHY`); stale witnesses cannot be trusted. The quoted log wording is verbatim; the enforced scope is subsequent gates only. | Every subsequent gate fails closed. Fix the runtime state directory and restart the user daemon. Scope: the marker blocks subsequent gates only. A writer already inside the `WRITE_LOCK` critical section cannot be recalled and may still complete one write; if the state directory is completely unwritable the persistent marker cannot be created, so workers forked before revocation only see the in-process flag. These are non-blocking residuals — no retroactive cancellation is claimed in this degraded state. |
| `evidence clock unavailable; evidence expired` / `evidence clock moved backwards; evidence expired` | The monotonic clock source is unreadable or moved backwards, so guard witness age is unknown. | The guard re-probes; if still unverifiable it fails closed with no write. Check `/proc/uptime` / `C640_KBD_MONOTONIC_FILE`. |
| `handoff skipped (fail-closed): python3 unavailable; cannot publish <file>` | `python3` is missing from the hook's runtime environment. | Install `python3` on the target; until then no handoff is published (fail closed, no restore). |

---

## 🐧 Recommended Distros & Kernel Requirements

* **Recommended Linux kernel**: Linux Kernel `>= 5.15` (recommend `>= 6.5` for the best SOF DSP and S0ix power performance).
* **Audio server**: PipeWire `>= 0.3.65` (recommend PipeWire 1.0+ / WirePlumber 0.4.14+).
* **Distro testing status** (see [VERIFICATION.md](verification.md) for what was actually
  hardware-tested):
  * 🟢 **Hardware-tested on real device**: **Ubuntu 26.04 LTS** (kernel `7.0.0-38-generic` for the
    2026-10-31 keyboard session, `7.0.0-29-generic` for the 2026-08 evidence
    bundle; PipeWire `1.6.2`, WirePlumber `0.5.13`, fprintd `1.94.5`)
  * ⚠️ **Build-tested in CI only (no hardware test)**: Ubuntu 24.04, Fedora 42,
    Arch Linux (distro-matrix dry-run + dependency resolution), plus packaging
    lint (Arch `namcap`, Fedora `rpmlint`)
