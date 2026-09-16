# 🐧 Fedora Configuration Guide

Applies to: **Fedora Workstation 39 / 40 / 41**, **Fedora Silverblue**, **Nobara**, **RHEL 9**.

---

## 1. Quick Automated Installation

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git
cd hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

---

## 2. Manual Step-by-Step Guide

### (1) Install Package Dependencies

```bash
sudo dnf install -y gcc meson ninja-build pkgconf-pkg-config \
                    glib2-devel libgusb-devel pixman-devel \
                    libgudev-devel json-glib-devel \
                    gobject-introspection-devel fprintd fprintd-pam \
                    alsa-sof-firmware pipewire wireplumber alsa-ucm
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
# keyd: sudo dnf copr enable alternateved/keyd -y && sudo dnf install -y keyd
# sudo ./keyboard/install-keyboard.sh --with-keyd
```

### (4) Compile the Fingerprint Driver and Configure PAM (authselect)

```bash
# Compile and install to /usr/lib64 using this project's script
./fingerprint/install-fingerprint.sh
```

> [!IMPORTANT]
> Do **not** run `authselect enable-feature with-fingerprint`. That feature
> injects `pam_fprintd` into `system-auth`, which `gdm-password` includes —
> on unlock GDM forks the `gdm-password` and `gdm-fingerprint` workers
> concurrently and both try to Claim the single fprintd device, so the lock
> screen shows no fingerprint prompt (GNOME/gdm#1071). Keep fingerprint
> **only in `/etc/pam.d/sudo`**:

```bash
# Make sure the with-fingerprint feature stays disabled
sudo authselect disable-feature with-fingerprint
sudo authselect apply-changes

# Enable fingerprint for sudo only (preserve existing stack)
sudo cp /etc/pam.d/sudo /etc/pam.d/sudo.bak
sudo sed -i '/^auth[[:space:]].*pam_fprintd.so/d' /etc/pam.d/sudo
sudo sed -i '0,/^auth[[:space:]]\+include[[:space:]]\+system-auth/s//auth sufficient pam_fprintd.so max-tries=1 timeout=10\n&/' /etc/pam.d/sudo
```
