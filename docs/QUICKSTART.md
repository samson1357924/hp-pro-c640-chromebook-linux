# 🚀 Quick Start Guide

This guide walks you through all the hardware driver configuration on your
**HP Pro c640 Chromebook** (Google `dratini` / `hatch`) in a few minutes (fingerprint build takes longer).

---

## ⚡ One-Liner Setup

Copy and run the following commands to automatically install the top-row
keyboard mapping, ALSA UCM2 audio configuration and the `crfpmoc` fingerprint
driver:

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git ~/projects/hp-pro-c640-chromebook-linux
cd ~/projects/hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

---

## 🧭 Common Commands Overview

| Purpose | Command |
| :--- | :--- |
| **Full one-click installation** | `./setup.sh --all` |
| **Install only the audio UCM configuration** | `./setup.sh --audio` or `./audio/install-audio.sh` |
| **Install only the fingerprint driver and PAM** | `./setup.sh --fingerprint` or `./fingerprint/install-fingerprint.sh` |
| **Install only the keyboard top-row mapping** | `./setup.sh --keyboard` or `./keyboard/install-keyboard.sh` |
| **Install only the power management tweaks** | `./power/install-power.sh` |
| **Enable the 90% battery protection service** | `./ec/install-ec.sh --enable-battery-limit` |
| **Comprehensive hardware diagnostics** | `./setup.sh --check` or `./scripts/detect-hardware.sh` |
| **Preview all changes (dry-run)** | `./setup.sh --all --dry-run` |
| **One-click uninstall and rollback** | `./setup.sh --uninstall` |

---

## 🖐️ Fingerprint Enrollment

After installation, enroll your fingerprint with the standard `fprintd` tool:

```bash
# 1. Enroll the default finger (right index finger)
fprintd-enroll "$USER"

# 2. Verify the fingerprint
fprintd-verify "$USER"

# 3. Test sudo authentication (use -k to clear the existing sudo cache)
sudo -k && sudo whoami
```

---

## 🔊 Test Audio Immediately

```bash
# Test stereo speaker output
speaker-test -c 2 -t wav

# Check the current audio device status
wpctl status
```

---

## 🔋 Check EC & Battery Protection

```bash
# Inspect complete EC health dashboard
c640-ec-control status

# Set battery limit to 90% (with automatic AC bypass)
c640-ec-control battery-limit 90

# Quiet typing fan silent mode
c640-ec-control fan-silent
```

---

## 📖 What's Next

* Running into any problems? See the [Troubleshooting & Pitfall FAQ (TROUBLESHOOTING.md)](TROUBLESHOOTING.md).
* Want to learn about MrChromebox flashing and hardware write-protection
  removal? See the [Firmware Flashing & Recovery Guide (FIRMWARE.md)](FIRMWARE.md).
* Using a specific distro (Fedora/Arch/NixOS)? See the [distro-specific guides (distros/)](distros/ubuntu-debian.md).
