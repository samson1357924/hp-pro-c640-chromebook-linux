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

### 3. Audio (ALSA UCM for sofrt5682)
#### 3.1 UCM update source
* Upstream new UCM: `standalone` branch of
  [WeirdTreeThing/alsa-ucm-conf-cros](https://github.com/WeirdTreeThing/alsa-ucm-conf-cros)
  (maintains the sof-rt5682 profiles).
* This repo mirrors them in [audio/ucm/](audio/ucm/README.md). Rule: **upstream
  first, mirror second**; unpin the mirror after upstream [PR #832](https://github.com/alsa-project/alsa-ucm-conf/pull/832) merges.

#### 3.2 md5 verification flow
* Compare the 8 files against the vendored commit (`diff -r` / `md5sum`, see
  [audio/ucm/README.md](audio/ucm/README.md)), then install:
  ```bash
  sudo cp -r audio/ucm/ucm2/* /usr/share/alsa/ucm2/
  sudo alsactl init
  systemctl --user restart wireplumber
  ```
* Failure trap: the UCM directory is `sof-rt5682` (dash) while the ALSA card is
  `sofrt5682` (no dash) — see [root-cause.md](audio/docs/root-cause.md#6-pitfalls).

#### 3.3 spa-acp-tool testing
* A/B comparison commands (`use-ucm=false` / `true`) are in
  [diagnostics.md](audio/docs/diagnostics.md#24-spa-acp-tool--the-ab-probe-main-tool).

#### 3.4 Upstream correspondence
* All changes should first target upstream (PR #832, work item #5428); this
  repo's mirror is for verification and reporting only, not forked development.

### 4. Submitting Pull Requests
1. Fork the repository.
2. Create a feature branch (`git checkout -b feat/audio-improvement`).
3. Commit using Conventional Commits (`feat(audio): ...`, `fix(fingerprint): ...`, `docs: ...`).
4. Submit a Pull Request.
