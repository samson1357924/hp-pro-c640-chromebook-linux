# 🐧 Ubuntu & Debian Configuration Guide

Applies to: **Ubuntu 22.04 / 24.04 / 26.04 LTS**, **Debian 12 (Bookworm) / 13 (Trixie)**, **Linux Mint**, **Pop!_OS**.

---

## 1. Quick Automated Installation

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git
cd hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

---

## 2. Manual Step-by-Step Guide (Transparent and Auditable)

### (1) Install Package Dependencies

```bash
sudo apt update
sudo apt install -y build-essential meson ninja-build pkg-config \
                    libglib2.0-dev libgusb-dev libpixman-1-dev \
                    libgudev-1.0-dev libudev-dev libjson-glib-dev \
                    libgirepository1.0-dev gobject-introspection \
                    fprintd libpam-fprintd firmware-sof-signed \
                    pipewire wireplumber alsa-ucm-conf
```

### (2) Deploy Audio UCM Configuration

```bash
sudo cp -r audio/ucm/ucm2/* /usr/share/alsa/ucm2/
sudo alsactl init
systemctl --user restart wireplumber
```

### (3) Deploy Keyboard Top-Row Mapping + Backlight Sync

Recommended (covers hwdb + `61-chromeos-kbd-backlight.rules` + daemon + user service + system-sleep):

```bash
sudo ./keyboard/install-keyboard.sh          # hwdb + backlight sync (5 files)
# with dual-role Search: sudo ./keyboard/install-keyboard.sh --with-keyd
```

Manual equivalent (5 files, see `keyboard/README.md` for details):

```bash
sudo cp keyboard/90-chromebook-keyboard.hwdb /etc/udev/hwdb.d/
sudo cp keyboard/udev/61-chromeos-kbd-backlight.rules /etc/udev/rules.d/
sudo install -D -m 0755 keyboard/c640-kbd-backlight-sync /usr/local/bin/c640-kbd-backlight-sync
sudo install -D -m 0644 keyboard/systemd/c640-kbd-backlight-sync.service /etc/systemd/user/c640-kbd-backlight-sync.service
sudo install -D -m 0755 keyboard/systemd/c640-kbd-backlight-sleep.sh /usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh
sudo systemd-hwdb update
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=input
sudo udevadm trigger --subsystem-match=leds
sudo systemctl daemon-reload
sudo systemctl --global enable c640-kbd-backlight-sync.service
# optional keyd dual-role (Search tap=CapsLock hold=Super):
# sudo apt install keyd  # Ubuntu 25.04+ native, else PPA keyd-team/ppa or Copr/source
# sudo ./keyboard/install-keyboard.sh --with-keyd
```

> **Ubuntu 26.04 note (real-hardware verified 2026-10-31):** the `keyd` package
> (2.5.0-5) installs **`/usr/bin/keyd.rvaiya`**, so plain `keyd ...` is "command
> not found"; the service is still `keyd`. There is no `keyd check` subcommand
> before 2.6 - the syntax is validated when the daemon starts. keyd 2.5.x also
> has no hot-plug detection, so re-run `sudo systemctl restart keyd` after
> changing `/etc/keyd/*.conf`. `install-keyboard.sh --with-keyd` handles all
> three cases (binary lookup, optional `check`, restart).
>
> The udev rule sets `root:plugdev 0660` on the keyboard-backlight brightness
> attribute via `RUN+=chgrp/chmod`; `MODE=`/`GROUP=` alone do not touch sysfs.
> Confirm with `ls -l /sys/class/leds/chromeos::kbd_backlight/brightness`.

### (4) Compile and Install the Fingerprint Driver

```bash
# Set up udev permissions
sudo cp fingerprint/60-cros-fp.rules /etc/udev/rules.d/
sudo usermod -aG plugdev "$USER"
sudo udevadm control --reload-rules && sudo udevadm trigger

# Run the automated install script to compile and install
./fingerprint/install-fingerprint.sh
```

> [!IMPORTANT]
> Do **not** run `pam-auth-update --enable fprintd` yourself. That profile injects
> `pam_fprintd` into `common-auth`, which `gdm-password` includes — on unlock GDM
> forks the `gdm-password` and `gdm-fingerprint` workers concurrently and both try
> to Claim the single fprintd device, so the lock screen shows no fingerprint
> prompt (GNOME/gdm#1071). The installer keeps fingerprint **only in
> `/etc/pam.d/sudo`** and removes fp lines from `common-*` with a direct
> `sed -i '/pam_fprintd\.so/d'` during installation.
>
> **Do not run `pam-auth-update --remove fprintd` yourself.** That action deletes
> debconf's `libpam-runtime/profiles` selection outright. On Debian/Ubuntu the
> installer first snapshots that selection and every saved module file under
> `/var/lib/pam` into a first-wins sidecar (`pam-selection` mode `0644`;
> `pam-selection.saved` a root-owned `0700` directory of file copies), with all
> reads/copies through `sudo` so a non-root caller with passwordless `sudo` is
> supported. It backs up **all** existing
> `common-*` bytes (not only fp-containing ones), strips only fp module lines,
> then runs `pam-auth-update --package` itself so debconf and `/var/lib/pam`
> converge to a stable "no fprintd" state and a later package-triggered run is a
> no-op. On uninstall, once manifest rollback is confirmed complete, it copies the
> saved files back, writes the original selection with `debconf-set-selections`,
> runs `--package` again and verifies the selection (exact or set-equivalent)
> before consuming the sidecar; a failed restore keeps it and returns rc 1.
> Trade-off: a selection you change during installation is overwritten on
> uninstall, and a manual `--enable fprintd` reintroduces the GDM race until
> uninstall. If `common-auth` still has an fp line on an older install, remove
> only that line, or re-run `./fingerprint/install-fingerprint.sh`, which handles it:

```bash
sudo sed -i '/pam_fprintd\.so/d' /etc/pam.d/common-auth
```
