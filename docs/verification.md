[English](../README.md) | [繁體中文](../README.zh-TW.md)

# ✅ Verification Matrix

> **Honest status**: this document clearly separates what has been **actually
> tested on a real HP Pro c640** (with exact software versions) from what is
> **config-only / not yet verified**. Claims in the README and
> [COMPATIBILITY.md](COMPATIBILITY.md) that are not backed by the evidence
> below should be treated as untested.

---

## 🖥️ Test Environment

| Item | Value |
| :--- | :--- |
| **Device** | HP Pro c640 Chromebook (board: `dratini` / baseboard: `hatch`) |
| **BIOS / Firmware** | MrChromebox UEFI Full ROM, version `2606.1` |
| **OS** | Ubuntu 26.04 LTS (Resolute Raccoon), x86_64 |
| **Kernel** | `7.0.0-29-generic` (Ubuntu 7.0.0-29.29, built 2026-07-17) |
| **Desktop** | GNOME (gnome-shell + GDM), Wayland |
| **Audio stack** | PipeWire `1.6.2`, WirePlumber `0.5.13`, alsa-ucm-conf `1.2.15.3` |
| **Fingerprint stack** | fprintd `1.94.5`, libfprint-2 `1.95.1` (custom build with `crfpmoc`) |
| **Evidence bundle** | `c640-diagnostic-20260815_152233.tar.gz` (collected 2026-08-15) |

---

## ✅ Verified on This Device

Legend: 🟢 = verified working on the machine above; 📄 = evidence file in the
diagnostic bundle.

### 1. Fingerprint (`crfpmoc`)

| Check | Result | Evidence |
| :--- | :---: | :--- |
| Driver compiled into libfprint | 🟢 | `libfprint-2.so.2.0.0` contains `FpiDeviceCrfpMoc` / `crfpmoc_enroll` symbols |
| Enrolled fingerprints | 🟢 | `fprintd-list`: 2 prints (`right-thumb`, `right-index-finger`) registered on `samson1357924` |
| `/dev/cros_fp` + `/dev/cros_ec` present | 🟢 | 📄 `fingerprint_ec/dev_nodes.txt`; since 2026-08-18 `/dev/cros_fp` = `crw-rw----+ root plugdev` + uaccess ACL (repo rule applied) |
| Driver source matches this repo | 🟢 | `diff -r fingerprint/driver <build-tree>/drivers/crfpmoc` → no differences |
| udev rules (installed) | 🟢 | 2026-08-18: repo rule installed (`GROUP="plugdev", MODE="0660", TAG+="uaccess"`), verified via `getfacl` after reboot — old `0666` version backed up |
| Unit tests | 🟢 | `test-crfpmoc-unit` binary (in `/usr/libexec/installed-tests/libfprint-2/`) passes 4/4: `fp_info_v3`, `fp_info_v1`, `enc_status_bitmask`, `payload_bounds` |
| Lock-screen fingerprint after suspend/resume | 🟢 | **Fully verified 2026-08-19**: (1) PAM claim race fixed 2026-08-18 (fprintd out of `common-auth`, kept in `gdm-fingerprint` + `sudo` only — was "Device was already claimed", GNOME/gdm#1071); (2) FPMCU open failure right after wake fixed by driver-level open retry (`CRFPMOC_OPEN_MAX_RETRIES` × 500 ms in crfpmoc.c) + system-sleep hook (`fprintd-sleep.sh` stops fprintd pre-sleep). User lid-cycle test: **first unlock has fingerprint prompt, zero resume delay, no retry lines in logs**. See [TROUBLESHOOTING.md §13](TROUBLESHOOTING.md) |
| `sudo` PAM authorization | 🟢 | `fprintd` lives in `/etc/pam.d/sudo` only (claim-race fix 2026-08-18 — not in `common-auth`); after `sudo -k`, `sudo whoami` prompts for and accepts the fingerprint (test method in [fingerprint/README.md §Test](fingerprint/README.md)). PAM stack verified in same session as lock-screen fix above |

### 2. Audio (Intel SOF DSP + ALSA UCM2 + PipeWire)

| Check | Result | Evidence |
| :--- | :---: | :--- |
| Sound card present | 🟢 | `sof-audio-pci-intel-cnl` bound to `00:1f.3` (📄 `hardware/lspci.txt`) |
| UCM profiles identical to repo | 🟢 | `diff` of `/usr/share/alsa/ucm2/conf.d/sof-rt5682/` vs `audio/ucm/ucm2/` → **no differences** |
| Speakers (PCM 5) | 🟢 | 📄 `audio/aplay.txt`: `device 5: Speakers`; wpctl default sink = `Speaker` |
| Headphones (PCM 0) | ⚠️ | 📄 `audio/aplay.txt`: `device 0: Port1`; wpctl lists `Headphones` sink — **auto-switch on plug/unplug not captured in evidence** |
| HDMI/DP outputs (PCM 2/3/4) | ⚠️ | 📄 `audio/aplay.txt`: HDMI1/2/3 listed; wpctl lists 3 HDMI sinks — **external display output not verified** (no HDMI/DP display was connected during testing) |
| Dual-microphone split (Mic 1/Mic 2) | 🟢 | 📄 `audio/wpctl.txt`: `Mic1__source.split` + `Mic2__source.split` filters active |
| Headset microphone | 🟢 | 📄 `audio/wpctl.txt`: `Headset Microphone` source present |
| Kernel warnings | 🟢 | 📄 `system/dmesg_warnings.txt` — **empty** (0 lines) |
| Actual playback | 🟢 | 📄 `audio/wpctl.txt`: Chromium stream routed `Speaker:playback_FL/FR [active]` |

### 3. Keyboard Top-Row (systemd-hwdb)

| Check | Result | Evidence |
| :--- | :---: | :--- |
| hwdb installed | 🟢 | `/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb` present |
| hwdb identical to repo | 🟢 | `diff` → only SPDX header comments differ (functionally identical) |
| keyd option B | ⚠️ | **Not installed on this machine** (hwdb option A used); config file provided only |

### 4. Wi-Fi / Bluetooth / Webcam / Storage

| Check | Result | Evidence |
| :--- | :---: | :--- |
| Wi-Fi 6 AX201 | ⚠️ | 📄 `hardware/lspci.txt`: `iwlwifi` on `00:14.3` — **device present, connectivity/throughput not measured** |
| Bluetooth AX201 | ⚠️ | 📄 `hardware/lsusb.txt`: `btusb` — Intel `8087:0026` — **device present, pairing/audio not measured** |
| Webcam | ⚠️ | 📄 `hardware/lsusb.txt`: `uvcvideo` — Foxlink `05c8:03e1` — **device present, capture not tested** |
| SD / SATA | ⚠️ | 📄 `hardware/lspci.txt`: `sdhci-pci` x2, `ahci` — **device present, I/O not tested** |
| WPA3 / Wi-Fi throughput | ❌ | **Not measured** (no network-level tests in evidence) |

### 5. Power & Suspend

| Check | Result | Evidence |
| :--- | :---: | :--- |
| Sleep modes advertised | 🟢 | 📄 `system/mem_sleep.txt`: `s2idle [deep]` — **both** supported |
| **Current default** | ⚠️ | **`deep` (S3) is the current default**, not s2idle (README now says "S3 deep default, s2idle available") |
| Actual suspend/resume cycle | 🟢 | **Tested 2026-08-18**: lid close → `PM: suspend entry (deep)` → `ACPI: PM: Preparing to enter system sleep state S3` → open lid → `Waking up from system sleep state S3` → `PM: suspend exit`, zero errors (journalctl -k). Also confirms the lid-close rule from `power/systemd/logind.conf.d/` is live. |
| S0ix residency / ASPM tuning | ❌ | **Not measured** (no PMC `slp_s0_residency` evidence) |
| Battery charge control | 🟢 | 📄 `fingerprint_ec/battery.txt`: `CHARGE_BEHAVIOUR=inhibit-charge` @ 90% (set via local helper, **not** the repo's `c640-ec-control` yet) |

### 6. Display / Graphics

| Check | Result | Evidence |
| :--- | :---: | :--- |
| i915 driver bound | 🟢 | 📄 `hardware/lspci.txt`: `i915` on `00:02.0` (CometLake-U GT2) |
| VA-API 4K 60fps hardware decode | ❌ | **Not measured** (`vainfo` not available in evidence bundle) |
| Dual Type-C video output | ❌ | **Not verified** — no external display was connected during testing; only `CROS_USBPD_CHARGER0/1` power-supply nodes exist (📄 bundle has no DP-alt-mode evidence) |

---

## ⚠️ Config-Only / NOT Yet Verified

These files are **config-only on the device above** — installed or
available-but-not-enabled as the status column says. Anything not measured
should be considered "provided for your distro, verify on your own hardware":

| Module | Files | Status |
| :--- | :--- | :---: |
| **Power tuning — modprobe quirks** | `power/modprobe.d/99-hp-c640-power.conf` | 🟢 installed + rebooted 2026-08-19 (d0i3 stripped, initramfs rebuilt); **dark-panel-after-resume persists** (screen still dark until keypress — user accepted; see [TROUBLESHOOTING.md §14](TROUBLESHOOTING.md)) |
| **Power tuning — wireplumber / logind** | `power/wireplumber/50-disable-suspend.conf`, `power/systemd/logind.conf.d/99-hp-c640-lid.conf` | 🟢 installed 2026-08-18 (logind lid rule verified via a real S3 lid cycle) |
| **Power tuning — TLP** | `power/tlp/99-hp-c640.conf` | ❌ not installed — **conflicts with the active `power-profiles-daemon`** (see ⚠️ below) |
| **EC control** | `ec/install-ec.sh`, `scripts/c640-ec-control.sh`, `ec/systemd/c640-battery-limit.service` | ❌ not installed (no `ectool`, no `/usr/local/bin/c640-ec-control`); local battery limit works via `charge_behaviour` sysfs + a **different** local helper |
| **Fingerprint system-sleep hook** | `fingerprint/systemd/fprintd-sleep.sh` | 🟢 installed + verified 2026-08-19 (lid-cycle test: first unlock has fingerprint prompt, zero resume delay, no retry lines) |
| **Fingerprint udev rule** | `fingerprint/60-cros-fp.rules` (plugdev/0660/uaccess) | 🟢 installed 2026-08-18, verified via `getfacl` after reboot |
| **keyd keyboard config** | `keyboard/keyd/cros.conf` | ❌ option A (hwdb) used instead |
| **PipeWire phantom-jack patch** | `audio/patches/acp-phantom-jack.patch` | ❌ current PipeWire 1.6.2 already handles jack state (patch is for older versions) |
| **Touchscreen / touchpad / backlight** | stock kernel drivers (`elan_i2c`, `cros_kbd_led_backlight`) | ⚠️ modules present (`i2c-ELAN0000/0001`), but **no functional gesture/backlight test in evidence** |
| **Sleep-wake via key/fingerprint** | stock ACPI | ⚠️ lid-open S3 resume verified (journal `PM: suspend exit`); key/fingerprint wake untested |
| **Known issue — dark panel after lid open** | i915 PSR/FBC/GuC quirks (see §14) | 🟡 quirk installed but **did not fix it**: screen stays dark until a keypress after lid-open S3 resume — user accepted, remedies still open |
| **Arch / Fedora / openSUSE / NixOS packaging** | `fingerprint/packaging/PKGBUILD`, `*.spec`, distro docs | ❌ only **Ubuntu 26.04** hardware-tested; CI runs the installer's source build in Arch/Fedora/Ubuntu containers, but the `PKGBUILD`/`.spec` packaging definitions themselves are **not exercised by CI** |

> [!NOTE]
> **`power/modprobe.d/99-hp-c640-power.conf` on kernel ≥ 7.0**: the
> `iwlwifi d0i3_disable=0` parameter was **removed** in kernel 7.0, so the
> installer (`power/install-power.sh`) and this device both strip that token
> automatically (otherwise modprobe would fail and **Wi-Fi would not load**).
> `enable_guc=2` means HuC-load-only on 7.0, and the i915 `enable_psr=0` /
> `enable_fbc=1` tweaks are applied here specifically for the
> dark-panel-after-resume issue. **TLP is not installed** on this device:
> it conflicts with the active `power-profiles-daemon` on Ubuntu 26.04.

---

## 📋 How to Reproduce the Evidence

```bash
# Full hardware + audio + fingerprint + power status in one archive:
./scripts/sysreport.sh
# Fingerprint enrollment/verification:
fprintd-list "$USER"
fprintd-verify "$USER"
# Audio devices:
aplay -l
wpctl status
# Sleep mode:
cat /sys/power/mem_sleep
```

> [!NOTE]
> The diagnostic bundle (`c640-diagnostic-*.tar.gz`) is git-ignored to avoid
> leaking serials/PII. Commit **sanitized** evidence here if you want
> verifiable proof in the repository itself.

---

## 🔄 Last Verified

* **Date**: 2026-08-15 (evidence bundle), 2026-08-17 (unit tests re-run),
  2026-08-18 (batch-1 installs + lid-close S3 suspend/resume test +
  fingerprint claim-race fix), 2026-08-19 (system-sleep hook + i915 PSR
  quirk installed & rebooted; lid-cycle fingerprint re-test passed — first
  unlock works, zero resume delay, no retry lines; dark-panel issue
  unresolved, user accepted)
* **OS / kernel**: Ubuntu 26.04 LTS, `7.0.0-29-generic`
* **Firmware**: MrChromebox `2606.1`
* **Hardware**: HP Pro c640 Chromebook (`dratini`/`hatch`)
