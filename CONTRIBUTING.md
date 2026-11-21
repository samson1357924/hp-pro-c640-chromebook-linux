<!-- markdownlint-disable MD013 -->

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

* **Protocol Modifications**: When editing ChromeOS EC Host Command structures
  in `fingerprint/driver/crfpmoc.h` or `crfpmoc.c`, ensure all fields sent to
  or received from the MCU are wrapped in `GUINT32_TO_LE()` / `GUINT32_FROM_LE()`.

### 2. Top-Row Keyboard Mapping (`HWDB`)

* **Testing Mappings**:

  ```bash
  sudo systemd-hwdb update
  sudo udevadm trigger --subsystem-match=input
  # Read-only: compares EVIOCGKEYCODE with the measured scancode fixture.
  sudo python3 keyboard/tests/check-top-row-hwdb.py
  # Live presses: post-hwdb KEY_* events via EVIOCGKEY, no grab:
  sudo python3 keyboard/tests/check-top-row-hwdb.py --listen 30
  # Synthetic-event self-check of the scanner logic; no device/evdev needed:
  python3 keyboard/tests/check-top-row-hwdb.py --self-test
  ```

  `--self-test` checks the fixture parser against synthetic events, so it needs
  no input device or evdev and is safe to run in CI. Plain `evtest` (no
  `--grab`) is read-only and safe. Never put an `EVIOCGRAB` on the keyd virtual
  keyboard (`evtest --grab`, `evemu-record --grab`): that kills desktop input
  until the tool exits. Once keyd grabs the physical AT keyboard, other readers
  cannot see its events at all — which is why keyd-stage capture reads the keyd
  virtual keyboard instead. These grab caveats belong to the **keyd stage**;
  see `keyboard/README.md` ("Verification & Testing") and
  `docs/TROUBLESHOOTING.md` §10 for the full keyd guidance.

* Ensure all HWDB properties start with a **single leading space** and match proper DMI strings (`cat /sys/class/dmi/id/product_name`).
* **New Chromebook model?** Find its raw scancodes first — do not copy the
  Dratini block. Stop keyd (`sudo systemctl stop keyd`) and read
  `EV_MSC/MSC_SCAN` for each top-row press with either
  `sudo python3 keyboard/tests/check-top-row-hwdb.py --scan 60` or plain
  `sudo evtest` (no `--grab`). On an unknown model or when `EVIOCGKEYCODE` is
  unsupported, use `sudo python3 keyboard/tests/check-top-row-hwdb.py --scan-only 60`:
  it skips the table check entirely, so a Dratini fixture mismatch cannot block
  raw capture. **After capturing, run
  `sudo systemctl start keyd` to restore the service**; otherwise Search
  tap/hold and brightness remapping stay disabled. `--listen` is **not** for
  this: it only observes the post-hwdb `KEY_*` key events via `EVIOCGKEY`, not
  the raw scancode.
  `--scan` additionally requires an observed `MSC_SCAN`: with no raw scan
  (keyd still grabbing the device, or no key pressed) it prints
  `RESULT=PASS (mapping check only; raw capture FAILED)` but exits
  **non-zero**. `RESULT=` is only the EVIOCGKEYCODE mapping verdict — judge
  overall success by the exit code / `RAW_CAPTURE=`, not `RESULT=PASS` alone.
  Infer the scancode from the `MSC_SCAN` values against the standard AT table;
  some Chromebooks send the ChromeOS action scancodes (`0xea`, `0xe9`, ...),
  others standard AT `0x3b`-`0x44`. If the scancodes differ, add a
  model-specific DMI block **and** a model-specific fixture (plus a CI
  assertion for that DMI); do not append different scancodes to the shared
  `keyboard/tests/hwdb-top-row-scancodes.tsv`, because CI asserts that whole
  file against the Dratini DMI.

### 3. Audio (ALSA UCM for sofrt5682)

#### 3.1 UCM update source

* Upstream new UCM: `standalone` branch of
  [WeirdTreeThing/alsa-ucm-conf-cros](https://github.com/WeirdTreeThing/alsa-ucm-conf-cros)
  (maintains the sof-rt5682 profiles).
* This repo mirrors them in [audio/ucm/](audio/ucm/README.md). Rule: **upstream
  first, mirror second**; unpin the mirror after upstream
  [PR #832](https://github.com/alsa-project/alsa-ucm-conf/pull/832) merges.

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

### 4. Documentation & GitHub Pages

* **Local preview** (Python 3.11.5+ is required by the current docs toolchain):

  ```bash
  pip install -r requirements-docs.txt
  mkdocs serve        # http://127.0.0.1:8000/hp-pro-c640-chromebook-linux/
  mkdocs build --strict --site-dir site  # strict: broken links/nav fail
  ```

* **Add a page**: create `docs/<name>.md` (and `docs/zh-TW/<name>.md` for Traditional Chinese), add it to `mkdocs.yml` `nav` under both `en` and `zh-TW`. Assets go to `docs/assets/` (CC0) and styles to `docs/stylesheets/` (CC0).

* **First-time enablement (maintainers only)**: GitHub → Settings → Pages → Build and deployment → Source: **GitHub Actions**. After that, `push` to `main` auto-deploys via `.github/workflows/pages.yml` (build → upload artifact → deploy). PRs only build, never deploy.

* **Checks before PR**: `markdownlint-cli2 --config .markdownlint.yaml "**/*.md"` (ignores `site/`), `lychee --config lychee.toml "**/*.md"`, and `reuse lint` must pass. `site/` and `.cache/` are git-ignored.

### 5. Submitting Pull Requests

1. Fork the repository.
2. Create a feature branch (`git checkout -b feat/audio-improvement`).
3. Commit using Conventional Commits (`feat(audio): ...`, `fix(fingerprint): ...`, `docs: ...`).
4. Submit a Pull Request.
