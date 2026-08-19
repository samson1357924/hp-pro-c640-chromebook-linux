# 🛠️ Troubleshooting & Pitfall Guide

This article covers the fourteen most common problems and their root-cause solutions
when installing and using Linux on the **HP Pro c640 Chromebook (Google
`dratini`)**.

---

## 🔊 Audio

### 1. System audio shows "Dummy Output" with no sound at all

* **Root cause**: the stock `alsa-ucm-conf` of standard distros has not yet
  merged the `sof-rt5682` downstream configuration into mainline. The PipeWire
  ACP mechanism misdetects all outputs as unavailable because the ASoC chip
  lacks a Phantom Jack kcontrol, leaving WirePlumber with only "off" to choose.
* **Solution**: run this project's one-click install command:

  ```bash
  ./setup.sh --audio
  ```

### 2. Kernel log shows `cl_dsp_init: timeout with rom_status_reg`, sound card missing

* **Root cause**: **Intel Management Engine (ME) is disabled**. The Intel Comet
  Lake SOF DSP firmware relies heavily on Intel ME communication during boot and
  clock initialization.
* **Solution**: **never use me_cleaner or disable Intel ME in the UEFI
  settings**. Make sure Intel ME is enabled in the MrChromebox UEFI firmware.

### 3. Speakers still play when headphones are plugged in, or switching is not automatic

* **Solution**: restart the WirePlumber service for the current user:

  ```bash
  systemctl --user restart wireplumber
  ```

### 4. Audio is muted after waking from sleep (Sleep/Resume)

* **Solution**:

  ```bash
  systemctl --user restart wireplumber pipewire
  ```

---

## 🖐️ Fingerprint

### 5. `fprintd-enroll` reports `/dev/cros_fp: Permission denied`

* **Root cause**: the current user is not in the `plugdev` group, or the udev permission rules have not been reloaded.
* **Solution**:

  ```bash
  sudo usermod -aG plugdev "$USER"
  sudo cp fingerprint/60-cros-fp.rules /etc/udev/rules.d/
  sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=misc
  ```

  *(Log out and log back in afterwards)*

### 6. Fingerprint doesn't work at boot login, but lock screen and `sudo` do

* **Root cause**: this is a security architecture design of Linux desktops
  (e.g. GNOME / GDM). **GNOME Keyring (the keyring that stores Wi-Fi passwords
  and browser passwords) needs your plaintext password to be decrypted**.
* **Solution**: on a cold boot, type your password once at first login to unlock
  the Keyring; after that, all lock-screen unlocks (`Super + L`),
  wake-from-suspend, PAM authorization and `sudo` can be done instantly with a
  fingerprint.

### 7. Fingerprint stops working after a reboot (`command failed: UNAVAILABLE` / `INVALID_PARAM`)

* **Symptoms**: after a reboot the finger is no longer recognized at GDM login,
  lock screen (`Super + L`), `sudo` or any `fprintd-verify`. `journalctl -u
  fprintd` shows `Device reported an error during verify: command failed:
  UNAVAILABLE` (the first attempt may instead be `INVALID_PARAM`).
* **Root cause (two layers)**:
  1. **Protocol layer** — the FPC1025 Match-on-Chip sensor is driven by the
     ChromeOS FPMCU. The FPMCU holds the **seed** and a **user context
     (`user_id`)**, both in FPMCU **RAM (not flash)**: the seed (and the
     `SEED_SET` flag) survive a *warm* reboot only because the FPMCU stays
     powered, and on a *cold* boot they are lost and the host re-sends `FP_SEED`
     from `/var/lib/fprint/crfpmoc.key`. The crfpmoc driver's keys handshake
     contains an `FP_CONTEXT` step that (a) re-establishes the crypto context and
     (b) triggers the FPMCU sensor reset/open (`fp_sensor_open`, ~175 ms) that
      re-initializes the sensor. A previous driver build (which jumped directly to
      `KEYS_DONE` when the encryption seed was already set) skipped that step
      whenever the seed was already set, so after a reboot the sensor stayed
      uninitialized → every
     template operation failed with `EC_RES_UNAVAILABLE`. A second latent bug, a
     `RESET_SENSOR`/`FP_MODE_FINGER_UP` mode conflict that produced
     `INVALID_PARAM`, was also fixed by clearing the sensor mode (`FP_MODE=0`)
     before `FP_CONTEXT_ASYNC`. Both are fixed in the current driver
     (`crfpmoc_keys_enc_status_cb` now jumps to `KEYS_CLEAR_MODE`, which is a new
     step in the `KEYS` sub-SSM).
  2. **Data layer (why you must re-enroll)** — the per-template decryption key is
     derived from the seed + a per-template salt, mirroring Chromium's own design
     where `HW_Key = HKDF(SBP_Src_Key, TPM_Seed, User_Salt, User_ID)`
     (<https://chromium.googlesource.com/chromiumos/platform/ec/+/HEAD/docs/fingerprint/fingerprint-authentication-design-doc.md>).
     Templates enrolled under the **broken** build can fail to decrypt once the
     sensor/context bring-up — or the seed stored in `/var/lib/fprint/crfpmoc.key`
     — changes. The `user_id` is **not stored inside the template**, so such
     templates can never be recovered by a driver change. Re-establishing the
     context on every open is the *correct* fix (it mirrors how Chromium's `biod`
     calls `SetContext` before every template upload), but it means templates
     from the broken build must be re-enrolled. (Note: the current crfpmoc driver
     sends a zero context, so the binding is effectively seed + per-template
     salt.)
* **Solution**:
  1. Make sure you built and installed a crfpmoc that includes both fixes (driver
     newer than 2026-08-15). Re-run `fingerprint/install-fingerprint.sh` if
     needed, then `sudo systemctl restart fprintd`.
  2. **Re-enroll your fingerprints — the old templates are undecryptable**:

     ```bash
     fprintd-delete "$USER"
     fprintd-enroll "$USER"
     ```

     (Place the same finger repeatedly when prompted; enroll both thumbs / index
     fingers as before.)
  3. After re-enrolling, verify works across reboots because the new templates
     are encrypted with the now-stable seed file. **Never delete or regenerate
     `/var/lib/fprint/crfpmoc.key`** (must stay `root:root`, `0600`) — if it is
     lost or its permissions are wrong, a cold reboot or a fresh re-enroll is
     required to recover.

### 8. Two fingerprint stacks fighting over `/dev/cros_fp`

* **Root cause**: only one host program should drive the FPMCU at a time. This
  project uses the crfpmoc libfprint driver (consumed by `fprintd`). A separate
  project, **ChocolateLoverRaj/rust-fp** (`/usr/local/bin/rust-fp-dbus-interface`
   and its `rust-fp-dbus-interface.service`), also opens `/dev/cros_fp`. Because the
  seed/context/template state is a single global on the FPMCU, two programs
  issuing `EC_CMD_FP_SEED` / `EC_CMD_FP_CONTEXT` / enroll / verify will corrupt
  each other's encryption context and unlock state.
* **Solution**: use only one stack. If `rust-fp` is installed, disable it and rely
   on crfpmoc:

   ```bash
   sudo systemctl disable --now rust-fp-dbus-interface.service
   sudo systemctl restart fprintd
   ```

   (Alternatively, remove the rust-fp binary and service and reboot.)

---

## ⌨️ Keyboard

### 9. Top-row function keys (Back/Reload/Brightness/Volume) don't respond

* **Root cause**: the system is missing the `90-chromebook-keyboard.hwdb` scancode mapping.
* **Solution**:

  ```bash
  ./setup.sh --keyboard
  ```

### 10. Want the Search key to act as "CapsLock on tap, Super on hold"

* **Solution**: install and enable `keyd`:

  ```bash
  sudo apt install -y keyd   # (or dnf/pacman)
  sudo cp keyboard/keyd/cros.conf /etc/keyd/default.conf
  sudo systemctl enable --now keyd
  ```

---

## 🔋 Power & Suspend

### 11. Closing the lid overnight drains too much battery (over 5-8%)

* **Root cause**: Intel AX201 Wi-Fi background wake (WoWLAN) or PCIe ASPM power
  saving is not fully enabled, so the SoC can't reach the low-power Package C10
  (SLP_S0#) state.
* **Solution**:
  1. Disable Wi-Fi wake on sleep:

     ```bash
     sudo iw phy phy0 wowlan disable
     ```

  2. Add `pcie_aspm=force` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then run `sudo update-grub`.
  3. Install `tlp` or `power-profiles-daemon` to manage power saving states.

### 12. Laptop doesn't suspend when the lid is closed

* **Solution**: make sure `/etc/systemd/logind.conf.d/99-hp-c640-lid.conf`
  (installed by `./power/install-power.sh`) or `/etc/systemd/logind.conf`
  contains:

  ```ini
  [Login]
  HandleLidSwitch=suspend
  HandleLidSwitchExternalPower=suspend
  ```

* **⚠️ After changing logind config, REBOOT — do NOT `systemctl restart
  systemd-logind`**:
  restarting `systemd-logind` while a desktop session is active **logs out
  every logged-in user** (the session leader is lost during deserialization,
  which tears down the whole GNOME session, kills the user manager and can
  even look like a system freeze). The new setting only takes effect at the
  next login/boot anyway, so a reboot (or logging out and back in) is the
  correct — and only safe — way to apply it.

  ```bash
  # DON'T do this:
  sudo systemctl restart systemd-logind

  # DO this instead — reboot and the lid rule is live:
  sudo systemctl reboot
  ```

  *(Verified 2026-08-18: restarting systemd-logind caused a full session
  logout storm that appeared as a system crash on an HP Pro c640.)*

### 13. No fingerprint prompt on the lock screen after suspend/resume (or instantly after locking)

* **Symptoms**: after lid-close suspend and reopen (or locking and interacting
  immediately), the unlock dialog shows **no fingerprint hint and touching the
  sensor does nothing**. Pressing `Esc` and re-entering the login screen makes
  fingerprint work.
* **Root cause**: a device-claim race between two PAM workers. On unlock, GDM
  forks the `gdm-password` worker and the `gdm-fingerprint` worker
  concurrently. Both PAM stacks used to contain `pam_fprintd`:
  `gdm-password` pulls it from `common-auth` (if the fprintd profile is
  enabled via `pam-auth-update`), `gdm-fingerprint` has
  `auth required pam_fprintd.so`. fprintd allows **only one Claim** per
  device; the password worker is forked first and wins, the fingerprint
  worker gets `Authorization denied ... Device was already claimed`, the
  whole fingerprint service fails, and GNOME Shell hides the fingerprint
  prompt. Suspended sessions make it deterministic because reauth starts
  ~400 ms after wake.
* **Evidence**:

  ```text
  fprintd: Authorization denied to :1.142 to call method 'Claim' for device
  'ChromeOS Fingerprint Match-on-Chip': Device was already claimed
  ```

  Upstream tracking: GNOME/gdm#1071, libfprint/fprintd#214,
  GNOME/gnome-shell#7791 (all open as of 2026-08).
* **Solution (installed by this project's installer since 2026-08-18)**:
  keep `pam_fprintd` **out of `common-auth`** and enable fingerprint **only
  for sudo** (`auth sufficient pam_fprintd.so` in `/etc/pam.d/sudo`). The
  GDM login screen and lock screen keep working via the dedicated
  `gdm-fingerprint` PAM service, which now always wins the claim.

  ```bash
  # what the installer does:
  sudo pam-auth-update --remove fprintd
  sudo sed -i '/^@include common-auth$/i auth sufficient pam_fprintd.so max-tries=1 timeout=10' /etc/pam.d/sudo
  ```

  *(This also removes the previous race window for `sudo` — see section 8
  for the single-stack rule.)*
* **Manual recovery (if you are on an older install)**: press `Esc` to cancel
  the failed unlock round, then unlock again — the fresh workers re-claim
  cleanly. Or run `sudo systemctl restart fprintd` before unlocking.
* **Residual issue after the PAM fix (FPMCU open fails right after resume)**:
  even with the claim race gone, the *first* unlock attempt after resume can
  still fail: the claim succeeds but the crfpmoc **device open fails
  instantly** (the EC/FPMCU channel is not ready in the first ~2 s after S3
  wake), `pam_fprintd` errors and the shell shows no fingerprint prompt (no
  `already claimed` line is logged in this case — confirmed with
  `G_MESSAGES_DEBUG=fprintd`, 2026-08-19: `claiming the device: 0` without
  `claimed device 0`). Two complementary fixes ship with this project:
  1. **Driver-level open retry (the real fix, since 2026-08-19)**: the
     audited `crfpmoc` driver retries the open SSM with a bounded budget
     (`CRFPMOC_OPEN_MAX_RETRIES` × 500 ms) when the EC channel reports I/O or
     EC errors right after wake. A healthy open completes on the first
     attempt with **zero added latency**; only a failed open waits.
  2. **System-sleep hook hygiene**: `fingerprint/systemd/fprintd-sleep.sh`
     stops fprintd before sleep so resume always gets a fresh daemon.

  Verify after a lid cycle:

  ```bash
  journalctl -b -e -u fprintd | grep -E "claim|open|retry"
  # expect: "claimed device 0" on the FIRST post-resume claim
  #         (plus "retrying" lines only if the EC channel needed a moment)
  ```

  *(If it still fails, temporarily install
  `Environment=G_MESSAGES_DEBUG=fprintd` in a fprintd.service drop-in and
  repeat the lid cycle to capture the driver error.)*

### 14. Screen stays dark after lid-open resume (until a key/click)

* **Symptoms**: after lid close (S3 `deep`) and reopen, the system resumes
  (`PM: suspend exit`) but the panel stays **dark** until a key press or
  click. Not a hang — the lock screen works once any input arrives.
* **Root cause (two candidate mechanisms, 2026-08-18)**:
  1. **GNOME userspace re-blank** (most likely, matches the keypress-cure
     signature): `gsd-power` blanks the panel on suspend; the screen-shield
     lock animation stalls while the display is off, and when it completes
     after resume the power plugin turns the monitor **back off**
     (GNOME/mutter#4111, fix candidate gnome-shell!3742 — unmerged).
  2. **i915 PSR resume bug** on Comet Lake (gitlab.freedesktop.org/drm/i915),
     and/or kernel 7.0 eDP backlight regressions (drm/i915/kernel#16791,
     #16825). Less likely because those are not cured by a keypress.
* **Solution (this project)**: the `power/install-power.sh` modprobe quirk
  `options i915 enable_psr=0 enable_fbc=1 enable_guc=2` is the repo's
  candidate remedy for suspend/resume black screens. It was installed and
  the device rebooted on 2026-08-19, but **it did not resolve the dark
  panel** on this unit (still dark until keypress — user accepted the
  behavior; see [VERIFICATION.md](verification.md)). Apply it and reboot if
  you want to try it:

  ```bash
  ./power/install-power.sh   # or manually:
  sudo install -D -m 0644 power/modprobe.d/99-hp-c640-power.conf \
      /etc/modprobe.d/99-hp-c640-power.conf
  sudo update-initramfs -u
  sudo systemctl reboot
  ```

  > [!NOTE]
  > On kernel ≥ 7.0 the installer automatically strips the removed
  > `iwlwifi d0i3_disable` parameter (see the file's comment header).
* **If the panel is still dark** after a lid cycle with `enable_psr=0`:
  test `MUTTER_DEBUG_FORCE_KMS_MODE=simple` in `/etc/environment` (isolates
  the atomic-KMS resume path, see drm/i915/kernel#16825), or watch
  `busctl monitor` on `org.gnome.SettingsDaemon.Power` for a
  turn-off-after-resume event (confirms the userspace re-blank hypothesis).
  Report findings against GNOME/mutter#4111.
