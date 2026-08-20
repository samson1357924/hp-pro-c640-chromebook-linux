[English](README.md) | [繁體中文](README.zh-TW.md)

# Fingerprint Setup (ChromeOS Match-on-Chip `crfpmoc`)

This module provides complete instructions, driver source reference,
cross-distribution packaging templates, and automated installation scripts for
the **FPC1025 Match-on-Chip (MoC)** fingerprint reader on the HP Pro c640
Chromebook (Google `dratini` / `hatch`).

---

## 🔍 How It Works

The fingerprint sensor on HP Pro c640 is connected via SPI to the ChromeOS
Fingerprint MCU (FPMCU) and exposed to Linux through the `/dev/cros_fp`
character device interface.

### Technical Problem in Standard Linux

1. **Missing ACPI GPIO Interrupts**: In generic Linux distributions, the FPMCU
   ACPI interrupt line is not connected to `cros_ec_chardev` event wait queues.
   As a result, standard `epoll` / `GPollableInputStream` calls never fire when
   a finger touches the sensor.
2. **Key Encryption & Seed Management**: Match-on-Chip sensors require an
   active encryption seed and user context to decrypt templates in MCU RAM.
3. **Template Serialization**: Host drivers must chunk and stream templates
   with Little-Endian `FP_TEMPLATE_COMMIT` flags.

### Solutions in `crfpmoc`

* **50ms SSM Delayed Polling Loop**: Direct non-blocking single-shot
  `poll(&pfd, 1, 0)` + `read(fd)` inside GLib state machine jumps, completely
  eliminating epoll deadlocks.
* **Weak Pointer State Machine Guards**: Prevents Use-After-Free hazards during
  sensor cancellation or timeouts.
* **Persistent Key Derivation**: Persists a 32-byte secret seed under
  `/var/lib/fprint/crfpmoc.key` with `0600` permissions.
* **Zero-bypass Authentication**: Ensures verify/identify operations never
  report success upon unexpected hardware responses or errors.

---

## 🛠️ Installation & Management

### Automated Installation (Hybrid A+C Architecture)

The included installation script automatically detects your distribution
(Ubuntu/Debian, Fedora, Arch, openSUSE), checks for fast prebuilt packages from
GitHub Releases, and seamlessly falls back to building from source (Plan A) if
offline or unsupported:

```bash
chmod +x install-fingerprint.sh
# Default Hybrid mode (checks prebuilt package first, falls back to source build):
./install-fingerprint.sh

# Force building from source (Plan A: pinned commit + audited driver overlay):
./install-fingerprint.sh --source
```

**Supported Options**:

* `./install-fingerprint.sh --install` (or `-i`): Default hybrid installation.
* `./install-fingerprint.sh --source` (or `--build`): Force building from source.
* `./install-fingerprint.sh --prebuilt` (or `--pkg`): Force prebuilt package only.
* `./install-fingerprint.sh --release-tag <TAG>`: Specify release tag to fetch from.
* `./install-fingerprint.sh --check` (or `-c`): Inspect fingerprint device status and list registered prints.
* `./install-fingerprint.sh --dry-run` (or `-n`): Preview installation steps without making system changes.
* `./install-fingerprint.sh --uninstall` (or `-u`): Revert udev rules, remove packages, and restore distro stock packages.

---

## 📦 Native Distribution Packaging

For users who prefer native package management over direct source installation:

* **Debian / Ubuntu**: Run [`packaging/build-deb.sh`](packaging/build-deb.sh) to build `.deb` package (`dpkg -i`).
* **Arch Linux / EndeavourOS**: Use the provided [`packaging/PKGBUILD`](packaging/PKGBUILD) with `makepkg -si`.
* **Fedora / openSUSE**: Use [`packaging/libfprint-crfpmoc.spec`](packaging/libfprint-crfpmoc.spec) with `rpmbuild`.
* **Standalone Source Tarball**: Generate a self-contained source archive with [`packaging/create-source-tarball.sh`](packaging/create-source-tarball.sh).

---

## 🧪 Usage & Testing

### 1. Enroll Fingerprint

```bash
# Enroll default finger (right index)
fprintd-enroll "$USER"

# Or enroll a specific finger:
fprintd-enroll -f right-thumb "$USER"
fprintd-enroll -f left-index-finger "$USER"
```

### 2. Verify Enrolled Fingerprint

```bash
fprintd-verify "$USER"
```

### 3. List Enrolled Fingerprints

```bash
fprintd-list "$USER"
```

### 4. Delete Enrolled Fingerprint

```bash
fprintd-delete "$USER"
```

### 5. System Authentication

* **Sudo**: Test with cleared timestamp cache:

  ```bash
  sudo -k && sudo whoami
  ```

  *(The `-k` flag clears existing sudo cache to guarantee a fingerprint verification prompt).*
* **Lock Screen**: Press `Super + L`, touch the sensor to unlock instantly.

> [!NOTE]
> **PAM strategy (single-stack, race-free)**: the installer deliberately
> keeps `pam_fprintd` **out of `common-auth`** and enables it **only in
> `/etc/pam.d/sudo`**. GDM login/lock-screen fingerprint runs through the
> dedicated `gdm-fingerprint` PAM service. If fingerprint is enabled in
> `common-auth` too (e.g. via `pam-auth-update --enable fprintd`), the
> `gdm-password` worker and the `gdm-fingerprint` worker race to Claim the
> device on unlock — the loser gets "Device was already claimed" and the
> lock screen shows no fingerprint prompt (see
> [TROUBLESHOOTING.md §13](../docs/TROUBLESHOOTING.md) and
> GNOME/gdm#1071).

> [!NOTE]
> **Suspend/resume handling**: the installer ships a system-sleep hook
> (`systemd/fprintd-sleep.sh` → `/usr/lib/systemd/system-sleep/`) that stops
> fprintd before sleep, and the audited `crfpmoc` driver retries the device
> open with a bounded budget right after wake (the ChromeOS EC/FPMCU channel
> can be briefly unusable for ~2 s after S3). Without these, the first
> lock-screen unlock after resume shows no fingerprint prompt (see
> [TROUBLESHOOTING.md §13](../docs/TROUBLESHOOTING.md) and
> GNOME/gnome-shell#7791).

> [!NOTE]
> **Initial Login vs Lock Screen (GNOME Keyring)**:
> In Linux desktop environments (such as GNOME/GDM), unlocking your login
> keyring (which decrypts stored Wi-Fi passwords and browser secrets) requires
> your user password upon cold boot. Lock screen unlocking (`Super + L`), PAM
> authorization, and `sudo` authenticate seamlessly via fingerprint.

---

## ❓ Troubleshooting & FAQs

### 1. `/dev/cros_fp: Permission denied`

Ensure udev rules are loaded and your user belongs to `plugdev`:

```bash
sudo cp 60-cros-fp.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=misc
sudo usermod -aG plugdev "$USER"
```

### 2. Encryption Key Permissions (`crfpmoc.key`)

The persistent encryption seed must be owned by `root:root` with strict
permissions:

```bash
sudo chmod 0600 /var/lib/fprint/crfpmoc.key
```

### 3. Debugging `fprintd` Service

To inspect live driver logs and state transitions:

```bash
sudo journalctl -u fprintd -f
```

---

## 📁 Driver Source Code & Tests

* [`driver/crfpmoc.c`](driver/crfpmoc.c): Main driver state machines, 50ms polling loop, and memory guards.
* [`driver/crfpmoc.h`](driver/crfpmoc.h): ChromeOS EC Host Command structures, MKBP bitmasks, and packet definitions.
* [`driver/crfpmoc-ec-transfer.c`](driver/crfpmoc-ec-transfer.c): Async `ioctl` transfer execution over `/dev/cros_fp`.
* [`driver/crfpmoc-ec-transfer.h`](driver/crfpmoc-ec-transfer.h): Transfer lifecycle and callback headers.
* [`tests/test-crfpmoc-unit.c`](tests/test-crfpmoc-unit.c): Standalone pure-C unit test suite.

---

## 🙏 致謝 (Credits)

* **Abhinav Baid**,
  **Felix Niederer**,
  **Michael Evans**,
  **[Marco Trevisan (Treviño)](https://github.com/3v1n0)** & **libfprint team**.
* **[ChromiumOS EC Team](https://chromium.googlesource.com/chromiumos/platform/ec/)** & **[Chrultrabook Project](https://chrultrabook.com/)**.
