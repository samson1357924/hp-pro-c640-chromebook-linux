# 🔄 Uninstallation & Rollback Guide

This project has a complete **lossless, idempotent & reversible** mechanism.
All files installed via `setup.sh` or the individual sub-modules are protected
by `/var/lib/cros-enablement/install-manifest.json` and
`/var/backups/cros-enablement/`.

---

## ⚡ One-Click Full Uninstallation

Run this inside the project directory:

```bash
./setup.sh --uninstall
```

This command automatically:

1. Removes the custom `sof-rt5682` UCM configuration files from `/usr/share/alsa/ucm2/`.
2. Removes `/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb` and rebuilds the hardware database.
3. Removes `/etc/udev/rules.d/60-cros-fp.rules`.
4. Removes the power management tweaks (logind config and suspend helpers).
5. Removes the EC tools and the 80% battery protection service.
6. Restores every file from the **first backup taken before this project ever
   touched it** (re-installs keep the original backup, so rollback always
   restores the pre-project state).
7. Restores the enabled/active state of systemd services the installer
   modified (`thermald`, `tlp`, `c640-battery-limit.service`, …) and removes
   **plugdev group memberships that the installer added** (memberships that
   existed before installation, or still required by other udev rules, are
   kept).
8. Removes the fingerprint encryption seed `/var/lib/fprint/crfpmoc.key` and
   shows the commands to reinstall the distro's native `libfprint` package.

---

## 🛠️ Per-Module Uninstallation

* **Remove only the audio UCM configuration**:

  ```bash
  ./audio/install-audio.sh --uninstall
  ```

* **Remove only the fingerprint udev rules, PAM config and system-sleep
  hook**:

  ```bash
  ./fingerprint/install-fingerprint.sh --uninstall
  ```

  *(This restores the backed-up `libfprint` libraries and `60-cros-fp.rules`,
  reverts the `pam_fprintd` PAM changes (`/etc/pam.d/sudo` back to stock,
  fprintd out of `common-auth`), removes the `fprintd-sleep.sh` system-sleep
  hook, removes `/var/lib/fprint/crfpmoc.key` and the plugdev membership the
  installer added, and rolls the service states back.)*

* **Remove only the keyboard top-row mapping**:

  ```bash
  ./keyboard/install-keyboard.sh --uninstall
  ```

* **Remove only the power management tweaks** (logind config, suspend
  helpers, TLP config, thermald service enablement):

  ```bash
  ./power/install-power.sh --uninstall
  ```

  > [!WARNING]
  > After uninstalling the power module, **reboot** (or log out and back in)
  > — do **not** run `systemctl restart systemd-logind`. With an active
  > desktop session, restarting `systemd-logind` logs everyone out (the
  > session leader is lost on deserialization), which looks exactly like a
  > system crash (verified on an HP Pro c640, 2026-08-18).

* **Remove only the EC tools and services** (including the 80% battery
  protection `c640-battery-limit.service`):

  ```bash
  ./ec/install-ec.sh --uninstall
  ```

---

## 🔋 Note: 80% Battery Protection Service

`./ec/install-ec.sh --enable-battery-limit` installs and starts
`c640-battery-limit.service`, which keeps the battery at 80% charge to
prolong its lifespan. It is removed automatically by
`./ec/install-ec.sh --uninstall` and by `./setup.sh --uninstall`.

> [!NOTE]
> **State left behind after uninstall**: the EC charge threshold set by the
> battery-limit service persists in the EC controller until you reset it
> explicitly (`./scripts/c640-ec-control.sh battery-full`). The `plugdev`
> group itself is not removed (other components or system packages may rely
> on it), only installer-created memberships are dropped. `/dev/cros_ec`
> keeps mode `0660` until the device is re-plugged or the machine reboots.

## 📦 Restore Distro Native Packages

If you compiled and installed the `crfpmoc` `libfprint`, you can reinstall the
distro's native version through your package manager:

* **Ubuntu / Debian**:

  ```bash
  sudo apt install --reinstall -y libfprint-2-2
  ```

* **Fedora**:

  ```bash
  sudo dnf reinstall -y libfprint
  ```

* **Arch Linux**:

  ```bash
  sudo pacman -S --overwrite='*' libfprint
  ```

* **openSUSE**:

  ```bash
  sudo zypper install --force libfprint-2-2
  ```
