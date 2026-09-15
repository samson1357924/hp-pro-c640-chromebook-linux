# 🐧 Arch Linux & EndeavourOS Configuration Guide

Applies to: **Arch Linux**, **EndeavourOS**, **CachyOS**, **Manjaro**.

---

## 1. Quick Automated Installation

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git
cd hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

---

## 2. Native Arch PKGBUILD Installation (Recommended)

This project provides a native PKGBUILD template so that `libfprint-crfpmoc` is fully managed by `pacman`:

```bash
cd fingerprint/packaging
makepkg -si
```

---

## 3. Manual Step-by-Step Setup

### (1) Install Package Dependencies

```bash
sudo pacman -S --needed base-devel meson ninja pkgconf glib2 \
                        libgusb pixman libgudev json-glib \
                        gobject-introspection fprintd \
                        sof-firmware pipewire pipewire-pulse wireplumber alsa-ucm-conf
```

### (2) Deploy Audio UCM Configuration

```bash
sudo cp -r audio/ucm/ucm2/* /usr/share/alsa/ucm2/
sudo alsactl init
systemctl --user restart wireplumber
```

### (3) Deploy Keyboard Top-Row Mapping + Backlight Sync

Recommended:

```bash
sudo ./keyboard/install-keyboard.sh          # hwdb + backlight sync (5 files)
# with dual-role Search: sudo ./keyboard/install-keyboard.sh --with-keyd
```

Manual equivalent (see `keyboard/README.md`):

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
# keyd: sudo pacman -S keyd && sudo ./keyboard/install-keyboard.sh --with-keyd
```

### (4) Configure PAM Fingerprint Authentication

> [!IMPORTANT]
> Keep `pam_fprintd` **out of `/etc/pam.d/system-auth`**. `system-auth` is
> included by `gdm-password`; on unlock GDM forks the `gdm-password` and
> `gdm-fingerprint` workers concurrently and both try to Claim the single
> fprintd device — the loser gets "Device was already claimed" and the lock
> screen shows no fingerprint prompt (GNOME/gdm#1071). Enable fingerprint
> **only for sudo**:

Edit `/etc/pam.d/sudo` — insert before the `system-auth` include (backup first):

```bash
sudo cp /etc/pam.d/sudo /etc/pam.d/sudo.bak
sudo sed -i '/^auth[[:space:]].*pam_fprintd.so/d' /etc/pam.d/sudo
sudo sed -i '0,/^auth[[:space:]]\+include[[:space:]]\+system-auth/s//auth sufficient pam_fprintd.so max-tries=1 timeout=10\n&/' /etc/pam.d/sudo
```
