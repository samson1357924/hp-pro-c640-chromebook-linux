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

### (3) Deploy Keyboard Top-Row Mapping

```bash
sudo cp keyboard/90-chromebook-keyboard.hwdb /etc/udev/hwdb.d/
sudo systemd-hwdb update
sudo udevadm trigger --subsystem-match=input
```

### (4) Configure PAM Fingerprint Authentication

> [!IMPORTANT]
> Keep `pam_fprintd` **out of `/etc/pam.d/system-auth`**. `system-auth` is
> included by `gdm-password`; on unlock GDM forks the `gdm-password` and
> `gdm-fingerprint` workers concurrently and both try to Claim the single
> fprintd device — the loser gets "Device was already claimed" and the lock
> screen shows no fingerprint prompt (GNOME/gdm#1071). Enable fingerprint
> **only for sudo**:

Edit `/etc/pam.d/sudo` and add the following line at the top:

```text
auth      sufficient pam_fprintd.so
```
