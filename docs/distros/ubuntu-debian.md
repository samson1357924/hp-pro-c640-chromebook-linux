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

### (3) Deploy Keyboard Top-Row Mapping

```bash
sudo cp keyboard/90-chromebook-keyboard.hwdb /etc/udev/hwdb.d/
sudo systemd-hwdb update
sudo udevadm trigger --subsystem-match=input
```

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
> Do **not** run `pam-auth-update --enable fprintd`. That profile injects
> `pam_fprintd` into `common-auth`, which `gdm-password` includes — on
> unlock GDM forks the `gdm-password` and `gdm-fingerprint` workers
> concurrently and both try to Claim the single fprintd device, so the lock
> screen shows no fingerprint prompt (GNOME/gdm#1071). The installer keeps
> fingerprint **only in `/etc/pam.d/sudo`**; if you already enabled it in
> `common-auth`, remove it:

```bash
sudo pam-auth-update --remove fprintd
```
