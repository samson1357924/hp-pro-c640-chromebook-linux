# Contributing to HP Pro c640 Chromebook Linux Guide

Thank you for your interest in improving hardware support for the HP Pro c640 Chromebook and related ChromeOS devices!

---

## 🛠️ Development & Testing

### 1. Fingerprint Driver (`crfpmoc`)
* **Unit Tests**: Compile and run the standalone unit tests:
  ```bash
  cd fingerprint/tests
  gcc -Wall -Wextra -O2 test-crfpmoc-unit.c $(pkg-config --cflags --libs glib-2.0) -o test-crfpmoc-unit
  ./test-crfpmoc-unit
  ```
* **Protocol Modifications**: When editing ChromeOS EC Host Command structures in `fingerprint/driver/crfpmoc.h` or `crfpmoc.c`, ensure all fields sent to or received from the MCU are wrapped in `GUINT32_TO_LE()` / `GUINT32_FROM_LE()`.

### 2. Top-Row Keyboard Mapping (`HWDB`)
* **Testing Mappings**:
  ```bash
  sudo systemd-hwdb update
  sudo udevadm trigger --subsystem-match=input
  sudo evtest
  ```
* Ensure all HWDB properties start with a **single leading space** and match proper DMI strings (`cat /sys/class/dmi/id/product_name`).

### 3. Submitting Pull Requests
1. Fork the repository.
2. Create a feature branch (`git checkout -b feat/audio-improvement`).
3. Commit using Conventional Commits (`feat(audio): ...`, `fix(fingerprint): ...`, `docs: ...`).
4. Submit a Pull Request.
