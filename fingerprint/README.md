# Fingerprint Setup (ChromeOS Match-on-Chip `crfpmoc`)

This module provides complete instructions, driver source reference, and automated installation scripts for the **FPC1025 Match-on-Chip (MoC)** fingerprint reader on the HP Pro c640 Chromebook (Google `dratini`).

---

## 🔍 How It Works

The fingerprint sensor on HP Pro c640 is connected via SPI to the ChromeOS Fingerprint MCU (FPMCU) and exposed to Linux through the `/dev/cros_fp` character device interface.

### Technical Problem in Standard Linux:
1. **Missing ACPI GPIO Interrupts**: In generic Linux distributions, the FPMCU ACPI interrupt line is not connected to `cros_ec_chardev` event wait queues. As a result, standard `epoll` / `GPollableInputStream` calls never fire when a finger touches the sensor.
2. **Key Encryption & Seed Management**: Match-on-Chip sensors require an active encryption seed and user context to decrypt templates in MCU RAM.
3. **Template Serialization**: Host drivers must chunk and stream templates with Little-Endian `FP_TEMPLATE_COMMIT` flags.

### Solutions in `crfpmoc`:
* **50ms SSM Delayed Polling Loop**: Direct non-blocking single-shot `poll(&pfd, 1, 0)` + `read(fd)` inside GLib state machine jumps, completely eliminating epoll deadlocks.
* **Weak Pointer State Machine Guards**: Prevents Use-After-Free hazards during sensor cancellation or timeouts.
* **Persistent Key Derivation**: Persists a 32-byte secret seed under `/var/lib/fprint/crfpmoc.key` with `0600` permissions.
* **Zero-bypass Authentication**: Ensures verify/identify operations never report success upon unexpected hardware responses or errors.

---

## 🛠️ Automated Installation

Run the automated script to install the udev rules, compile and install `crfpmoc` `libfprint`, and configure PAM:

```bash
chmod +x install-fingerprint.sh
./install-fingerprint.sh
```

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
* **Sudo**: `sudo whoami` (Prompts for fingerprint with password fallback).
* **GDM / Lock Screen**: Press `Super + L`, touch sensor to unlock.
