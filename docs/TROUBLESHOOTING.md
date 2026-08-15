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

---

## ⌨️ Keyboard

### 7. Top-row function keys (Back/Reload/Brightness/Volume) don't respond

* **Root cause**: the system is missing the `90-chromebook-keyboard.hwdb` scancode mapping.
* **Solution**:

  ```bash
  ./setup.sh --keyboard
  ```

### 8. Want the Search key to act as "CapsLock on tap, Super on hold"

* **Solution**: install and enable `keyd`:

  ```bash
  sudo apt install -y keyd   # (or dnf/pacman)
  sudo cp keyboard/keyd/cros.conf /etc/keyd/default.conf
  sudo systemctl enable --now keyd
  ```

---

## 🔋 Power & Suspend

### 9. Closing the lid overnight drains too much battery (over 5-8%)

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

### 10. Laptop doesn't suspend when the lid is closed

* **Solution**: make sure `/etc/systemd/logind.conf` contains:

  ```ini
  [Login]
  HandleLidSwitch=suspend
  HandleLidSwitchExternalPower=suspend
  ```

  Then restart the service: `sudo systemctl restart systemd-logind`.
