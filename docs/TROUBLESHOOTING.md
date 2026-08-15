# 🛠️ Troubleshooting & Pitfall Guide

This article covers the ten most common problems and their root-cause solutions
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
     re-initializes the sensor. Commit `8f5ee65` ("Jump directly to KEYS_DONE
     when encryption seed is already set") skipped that step whenever the seed was
     already set, so after a reboot the sensor stayed uninitialized → every
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
  + its `rust-fp-dbus-interface.service`), also opens `/dev/cros_fp`. Because the
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

* **Solution**: make sure `/etc/systemd/logind.conf` contains:

  ```ini
  [Login]
  HandleLidSwitch=suspend
  HandleLidSwitchExternalPower=suspend
  ```

  Then restart the service: `sudo systemctl restart systemd-logind`.
