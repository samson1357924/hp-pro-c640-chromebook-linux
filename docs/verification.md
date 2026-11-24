[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# ✅ Verification Matrix

> **Honest status**: this document clearly separates what has been **actually
> tested on a real HP Pro c640** (with exact software versions) from what is
> **config-only / not yet verified**. Claims in the README and
> [COMPATIBILITY.md](COMPATIBILITY.md) that are not backed by the evidence
> below should be treated as untested.

---

## 🖥️ Test Environment

| Item | Value |
| :--- | :--- |
| **Device** | HP Pro c640 Chromebook (board: `dratini` / baseboard: `hatch`) |
| **BIOS / Firmware** | MrChromebox UEFI Full ROM, version `2606.1` |
| **OS** | Ubuntu 26.04 LTS (Resolute Raccoon), x86_64 |
| **Kernel** | `7.0.0-38-generic` for the 2026-10-31 keyboard/backlight session; the 2026-08 evidence bundle was collected on `7.0.0-29-generic` |
| **Desktop** | GNOME (gnome-shell + GDM), Wayland |
| **Audio stack** | PipeWire `1.6.2`, WirePlumber `0.5.13`, alsa-ucm-conf `1.2.15.3` |
| **Fingerprint stack** | fprintd `1.94.5`, libfprint-2 `1.95.1` (custom build with `crfpmoc`) |
| **Evidence bundle** | `c640-diagnostic-20260815_152233.tar.gz` (collected 2026-08-15) |

---

## ✅ Verified on This Device

Legend: 🟢 = verified working on the machine above; 📄 = evidence file in the
diagnostic bundle.

### 1. Fingerprint (`crfpmoc`)

| Check | Result | Evidence |
| :--- | :---: | :--- |
| Driver compiled into libfprint | 🟢 | `libfprint-2.so.2.0.0` contains `FpiDeviceCrfpMoc` / `crfpmoc_enroll` symbols |
| Enrolled fingerprints | 🟢 | `fprintd-list`: 2 prints (`right-thumb`, `right-index-finger`) registered on `samson1357924` |
| `/dev/cros_fp` + `/dev/cros_ec` present | 🟢 | 📄 `fingerprint_ec/dev_nodes.txt`; since 2026-08-18 `/dev/cros_fp` = `crw-rw----+ root plugdev` + uaccess ACL (repo rule applied) |
| Driver source matches this repo | 🟢 | `diff -r fingerprint/driver <build-tree>/drivers/crfpmoc` → no differences |
| udev rules (installed) | 🟢 | 2026-08-18: repo rule installed (`GROUP="plugdev", MODE="0660", TAG+="uaccess"`), verified via `getfacl` after reboot — old `0666` version backed up |
| Unit tests | 🟢 | `test-crfpmoc-unit` binary (in `/usr/libexec/installed-tests/libfprint-2/`) passes 4/4: `fp_info_v3`, `fp_info_v1`, `enc_status_bitmask`, `payload_bounds` |
| Lock-screen fingerprint after suspend/resume | 🟢 | **Fully verified 2026-08-19**: (1) PAM claim race fixed 2026-08-18 (fprintd out of `common-auth`, kept in `gdm-fingerprint` + `sudo` only — was "Device was already claimed", GNOME/gdm#1071); (2) FPMCU open failure right after wake fixed by driver-level open retry (`CRFPMOC_OPEN_MAX_RETRIES` × 500 ms in crfpmoc.c) + system-sleep hook (`fprintd-sleep.sh` stops fprintd pre-sleep). User lid-cycle test: **first unlock has fingerprint prompt, zero resume delay, no retry lines in logs**. See [TROUBLESHOOTING.md §14](TROUBLESHOOTING.md) |
| `sudo` PAM authorization | 🟢 | `fprintd` lives in `/etc/pam.d/sudo` only (claim-race fix 2026-08-18 — not in `common-auth`); after `sudo -k`, `sudo whoami` prompts for and accepts the fingerprint (test method in [fingerprint README](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/fingerprint/README.md#2-verify-enrolled-fingerprint)). PAM stack verified in same session as lock-screen fix above |

### 2. Audio (Intel SOF DSP + ALSA UCM2 + PipeWire)

| Check | Result | Evidence |
| :--- | :---: | :--- |
| Sound card present | 🟢 | `sof-audio-pci-intel-cnl` bound to `00:1f.3` (📄 `hardware/lspci.txt`) |
| UCM profiles identical to repo | 🟢 | `diff` of `/usr/share/alsa/ucm2/conf.d/sof-rt5682/` vs `audio/ucm/ucm2/` → **no differences** |
| Speakers (PCM 5) | 🟢 | 📄 `audio/aplay.txt`: `device 5: Speakers`; wpctl default sink = `Speaker` |
| Headphones (PCM 0) | ⚠️ | 📄 `audio/aplay.txt`: `device 0: Port1`; wpctl lists `Headphones` sink — **auto-switch on plug/unplug not captured in evidence** |
| HDMI/DP outputs (PCM 2/3/4) | ⚠️ | 📄 `audio/aplay.txt`: HDMI1/2/3 listed; wpctl lists 3 HDMI sinks — **external display output not verified** (no HDMI/DP display was connected during testing) |
| Dual-microphone split (Mic 1/Mic 2) | 🟢 | 📄 `audio/wpctl.txt`: `Mic1__source.split` + `Mic2__source.split` filters active |
| Headset microphone | 🟢 | 📄 `audio/wpctl.txt`: `Headset Microphone` source present |
| Kernel warnings | 🟢 | 📄 `system/dmesg_warnings.txt` — **empty** (0 lines) |
| Actual playback | 🟢 | 📄 `audio/wpctl.txt`: Chromium stream routed `Speaker:playback_FL/FR [active]` |

### 3. Keyboard Top-Row (systemd-hwdb) & Backlight Sync

| Check | Result | Evidence |
| :--- | :---: | :--- |
| hwdb installed | 🟢 | `/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb` present; `diff` against the repo file is empty |
| hwdb scancode map (real hardware) | 🟢 | `keyboard/tests/check-top-row-hwdb.py` (2026-10-31 19:45:29, `EVIOCGKEYCODE` on the real keyboard): all 11 entries `OK` - `0x3b`→`KEY_BACK`, `0x40`→`KEY_BRIGHTNESSDOWN`, `0x42`→`KEY_MUTE`, `0xdb`→`KEY_LEFTMETA`. This proves the kernel map, not what a key press emits; the physical emission was captured separately (`18:14:47-18:15:18`, see the keyd row). The top row emits standard AT scancodes `0x3b`-`0x44`, not ChromeOS action scancodes. |
| keyd option B | 🟢 | **Installed 2026-10-31** (keyd 2.5.0-5 as `/usr/bin/keyd.rvaiya`) with `overloadt2(meta, capslock, 200)`. Virtual uinput test (19:45:37, `keyboard/tests/keyd-dualrole-uinput.py`) PASS: tap Search→`CAPSLOCK` only (no `META`, no guard), all ten Search+top-row chords→`F1`-`F10`, all ten top-row keys alone→their media keycode, hold Search alone→bare `LEFTMETA` release with **no `LEFTCTRL` guard**. Real-key passive capture (`18:14:47-18:15:18`): lone hold released as bare `LEFTMETA` (GNOME overview opened on screen), tap sent `CAPSLOCK` only, single brightness/mute/volume presses changed brightness and volume, Search+Back sent `F1`. Journal shows `match 0001:0001 (AT Translated Set 2 keyboard)` and `ignoring 0000:0006 (Video Bus)` |
| hwdb DMI match (real modalias) | 🟢 | `udevadm test /sys/class/input/event2` applies `KEYBOARD_KEY_*` via the `evdev:atkbd:` lookup even with the firmware's extra `br0.0:efr0.0` fields; non-`atkbd` lookups printing `No entry found from hwdb` is expected |
| kbd backlight udev rule | 🟢 | `61-chromeos-kbd-backlight.rules` installed 2026-10-31; `TAG+="uaccess"` + `RUN+=chgrp plugdev` / `RUN+=chmod 0660` → `ls -l .../brightness` = `-rw-rw---- root plugdev`, user write succeeds without sudo after `udevadm trigger --subsystem-match=leds` |
| kbd backlight daemon | 🟢 | Installed to `/usr/local/bin/`; 2026-10-31: `--test-blank` 2→0, `--test-unblank` 0→2, state file `0600` and removed; `gdbus emit ... ScreenSaver.ActiveChanged true/false` → 2→0→2 with **zero sudo calls** in the user journal. Write chain verified by unit tests: one gsd-power `Properties.Set`, UPower fallback with `[WARN]`, forced-legacy sysfs path, 0 saved, non-zero current overwritten, ScreenSaver-active deferral, and log lines visible on stderr. Phase 6 adds back-end re-probe (`RECOVERED`), write+verify `set_brightness()` rc, live-over-cache `save_state`, consume-after-verify staging, tristate defer and resume handoff — 406 daemon cases pass after the re-review fixes (below); real S3 verified below |
| kbd backlight user service | 🟢 | `/etc/systemd/user/`, globally enabled and **active for uid 1000** (`systemctl --global is-enabled`, `systemctl --user is-active` both OK); `StandardError=journal` makes daemon log lines visible in `journalctl --user -u c640-kbd-backlight-sync.service` |
| kbd backlight sleep hook | 🟢 | `/usr/lib/systemd/system-sleep/`; 2026-10-31 direct call: `pre suspend` saved 6, simulated 0 → `post suspend` restored 6, state removed. Now a **pure handoff writer** (no D-Bus/LED/state deletion; `0600` + chown + atomic `mv`; `C640_KBD_HANDOFF_DIR`); 73 hook cases pass. The root `/run/c640-kbd-backlight/state` is a **single-shot diagnostic snapshot of the first suspend in a boot** — first-wins, not consumed and never used for restore. **Real S3 freeze/thaw verified 2026-11-22** (details below) |

#### Real S3 acceptance (2026-11-22, full systemd freeze/thaw)

Environment: systemd `259`, gnome-settings-daemon `50`,
`rtcwake -m no -s 20` plus `systemctl suspend` (the complete systemd sleep
freeze/thaw flow, not a direct hook invocation). Before suspend: state = `30`,
brightness = `0` (screen already blank), ScreenSaver = `true`.

| Check | Result | Evidence |
| :--- | :---: | :--- |
| **Branch A — resume while still locked** | 🟢 | Suspend entry `04:34:19` → exit `04:34:39` (first run) and `04:48:37` → `04:48:58` (second run, after `faa458e`). ScreenSaver still `true`; brightness `2` (gsd-power's tiny residual, **not** restored to 30); `state=30` preserved; `handoff.suspend` consumed; `handoff.resume` retained. Journal: `ignoring blank-side suspend handoff 0; keeping saved user brightness 30`, `resume: ScreenSaver=active`, `resume deferred: ScreenSaver still active (saved=30)`. The first (pre-fix) run showed `suspend handoff 0 overrides differing daemon state 30` → `state=0`; fixed by `faa458e`. |
| **Branch B — restore after unlock** | 🟢 | `loginctl unlock-session 2` → `ScreenSaver inactive -> restoring kbd backlight`, `unblank: resume flag present; routing through handle_resume`, `resume: ScreenSaver=inactive after 0s (saved=30)`, `restoring brightness 30`, `resume: restore complete; resume flag consumed`. Brightness, gsd-power and UPower all `30`; state and both handoff files consumed. |
| **Final machine state** | 🟢 | Locked again, brightness/gsd/UPower in sync, service enabled + active globally and per user, `state=30` (the test user brightness). |

> [!NOTE]
> These runs used `rtcwake` + `systemctl suspend`, which exercises the same systemd
> `PrepareForSleep` freeze/thaw and system-sleep hook path as a lid close. A separate
> **manual lid-close cycle** was not part of this run and remains a supplementary
> to-test item.

#### Sixth re-review fixes (2026-11-23, unit-tested)

These are logic/robustness fixes covered by the shell unit suites; the 2026-11-22 real
S3 records above are kept verbatim and no new hardware run is claimed here.

* **Only an applied restore consumes the flag.** Adoption, restore and the new
  `verify_restore_applied()` share result codes `0=RC_DONE`, `1=RC_FAIL`, `2=RC_DEFER`.
  Lock failures, a surviving `STATE`/`restore-pending`, or a brightness readback that
  differs from the saved value return DEFER/FAIL instead of 0. Only DONE removes the
  state and both handoff files; DEFER keeps them for the 5s sampler to retry and
  `handle_unblank()` logs `unblank: restore deferred` rather than a false WARN.
  `log_warn_once` now uses a state-dir marker so warnings stay once-per-key across
  subshells.
* **Corrupt manifest fails closed.** `lib/backup.sh` uses one validator for all readers
  and writers: a missing manifest creates an empty skeleton, but an existing corrupt one
  logs `MANIFEST_INVALID ... original bytes left untouched`, leaves the original bytes
  untouched and makes `manifest_has_target` (tristate 0/1/2) and all three writers fail.
  Backup is refused before any target is touched.
* **Persist before blanking.** `compute_save_brightness()` is factored out;
  `save_state [value]` returns `0` (saved) / `1` (lock wait failed) / `2` (write failed)
  under `flock -w "$C640_KBD_SAVE_LOCK_WAIT"` (default 2s). `handle_blank()` samples,
  saves (two retries with the captured value) and **only then** writes 0; on total
  failure it logs `blank: brightness NOT saved`, keeps the LED on and re-seeds the
  last-user cache. `--test-blank` exits 1 when saving fails.

Current unit-test totals (these fixes plus the seventh, eighth, ninth, tenth and eleventh
re-review fixes below): **406** daemon, **73** sleep-hook and **1642** rollback cases (the last
run as root), all 0 failures.

#### Seventh re-review fixes (2026-11-23, unit-tested)

These are logic/robustness fixes covered by the shell unit suites; the 2026-11-22 real
S3 records above are kept verbatim and no new hardware run is claimed here.

* **Persist the pre-blank snapshot; self-heal invalid state.** `handle_blank()` samples
  brightness once before switching the LED off and the first `save_state "$captured"`
  uses that captured value directly — a second sample could see a blank-side hardware
  `0` and fall back to a stale last-user cache (saving `8` instead of the real `30`).
  `save_state()` is atomic and first-wins **only for a valid copy**; an empty,
  non-numeric, multi-line or binary state file is validated under `STATE_LOCK` and
  atomically replaced with the captured value
  (`replacing invalid saved brightness with N`). Only a real write failure returns rc
  `2` and leaves the LED on; rc `0`/`1`/`2` and the result-code/retry contract are
  unchanged.
* **Validate manifest fields and gate rollback before mutation.** The shared manifest
  validator now checks field types (validate, never repair): record `target` must be an
  absolute path string without NUL, `component`/`installed_at`/`version`/`scope` must be
  strings when present, and `was_existing`/`was_enabled`/`was_active`/`was_member` must be
  booleans (`"false"` and `1` are rejected, not coerced); service `name`/`component` and
  group `group`/`user`/`component` are required, optional fields may be absent (legacy
  v1), unknown keys ignored. A wrong type is a new `MANIFEST_INVALID` reason (not only
  corrupt JSON) and leaves the original bytes untouched. `rollback_component()`,
  `uninstall_keyboard()` and `remove_group_membership()` fail closed before any
  service/file side effect, and rollback consumes the validated document via stdin (no
  TOCTOU). A mid-run script failure logs
  `rollback of <component> failed; service/file state may be partial` and returns rc 1
  instead of claiming success.
* **Skip pseudo-targets.** Non-absolute manifest targets such as the fingerprint
  `package:libfprint-crfpmoc` are skipped, logging
  `skipping manifest entry with non-absolute target` (Meson plan destinations must be
  absolute too), so the installer never writes a record its own validator would reject.

Current unit-test totals (these fixes plus the eighth, ninth, tenth and eleventh re-review
fixes below): **406** daemon, **73** sleep-hook and **1642** rollback cases (the last run as root),
all 0 failures.

#### Eighth re-review fixes (2026-11-23, unit-tested)

These are logic/robustness fixes covered by the shell unit suites; the 2026-11-22 real
S3 records above are kept verbatim and no new hardware run is claimed here.

* **Safety fields are required; unknown state fails closed.** The validator now requires
  `records[*].was_existing`, `services[*].was_enabled` / `was_active` and
  `groups[*].was_member` to be booleans — every real writer (v1.0 and v2.0) has always
  emitted them, confirmed against git history. The only genuine legacy tolerance is
  absent top-level arrays, a keyd record missing `component` (backfilled) or `scope`.
  Rollback adds an `UNKNOWN` sentinel: a missing/non-bool field deletes no file, stops
  no service and drops no group membership, keeps the record, warns and returns rc 1 —
  unknown is never treated as false. `_keyd_managed_by_us()` likewise requires a valid
  bool snapshot before it will disable/stop keyd.
* **An absent target is still restored from the first backup.** Rollback no longer
  branches on `lexists`: for `was_existing` records it always finds the oldest matching
  backup and rebuilds the original file/symlink (stage + `os.replace`, first-wins
  `matches[0]`, owner/symlink/mode restored), even if the installed file was removed by
  the user or another tool. A record is consumed only after its whole action succeeds;
  with no backup it keeps the record and warns (`[WARN NO BACKUP]`) instead of inventing
  a file.
* **Every restore command checks its result.** Each `systemctl` enable/disable/start/stop
  checks `.returncode` (timeouts, stderr and spawn errors included). A failed service
  keeps its record, logs `SERVICE_RESTORE_FAILED` / `ROLLBACK_INCOMPLETE` and returns
  non-zero so a later run can retry; successful ones log `[RESTORED SERVICE]`.
* **Group membership is recorded before it is changed.** For `plugdev` (and the other
  managed groups) the installer first persists the original membership, then checks
  `sudo usermod -aG` rc explicitly (no `|| true`); on failure it removes the just-written
  record when no earlier record existed. The shared `manifest_has_group` /
  `manifest_remove_group` / `ensure_group_membership` helpers are used by the keyboard,
  fingerprint and EC callers.

All install callers now save the rollback rc, finish their remaining cleanup and return
that rc last, so `set -e` cannot abort cleanup on a failed rollback.

Current unit-test totals (these fixes plus the ninth, tenth and eleventh re-review fixes
below): **406** daemon, **73** sleep-hook and **1642** rollback cases (the last run as root),
all 0 failures.

#### Ninth re-review fixes (2026-11-23, unit-tested)

These are logic/robustness fixes covered by the shell unit suites; the 2026-11-22 real
S3 records above are kept verbatim and no new hardware run is claimed here.

* **A failed restore swap keeps the installed target.** `restore_original()` now stages
  next to the target and uses a single atomic `os.replace()` for regular files/symlinks
  without unlinking first, so a failed swap never makes the original configuration
  disappear. Any swap involving a directory (including dir→dir) moves the old entry aside
  (and back on failure), then cleans it up with `remove_path()` after success. All eight target×backup
  combinations are covered by the rollback suite.
* **A missing backup is a real failure.** For `was_existing` records with no first backup,
  rollback adds `problem("RECORD_BACKUP_MISSING", ...)`, keeps the record, creates no fake
  file and lets the other items keep rolling back, but prints
  `ROLLBACK_INCOMPLETE: N item(s) retained` and returns rc 1 instead of `finished!`.
* **Concurrent manifest writers are serialized.** Every manifest read-modify-write writer
  (the backup helpers in `lib/backup.sh` plus the keyboard keyd-link normalizer) shares a
  root-controlled `flock -x -w` lock on `$MANIFEST_DIR/.install-manifest.lock` (fd 9,
  re-entrant depth, fail closed if `flock` is missing or the wait times out); the gate →
  re-read → decision → write critical section keeps first-wins records from being lost,
  and every writer uses a unique
  `.install-manifest.*.tmp` (mkstemp + fsync + `chmod 0644` + `os.replace`) so parallel
  writers cannot clobber each other's temp file. The lock file is created with noclobber
  so no writer replaces its inode.

Current unit-test totals (these fixes plus the tenth and eleventh re-review fixes below):
**406** daemon, **73** sleep-hook and **1642** rollback cases (the last run as root),
all 0 failures.

#### Tenth re-review fixes (2026-11-23, unit-tested)

These are logic/robustness fixes covered by the shell unit suites; the 2026-11-22 real
S3 records above are kept verbatim and no new hardware run is claimed here.

* **The lock is hardened against symlink swaps and unprivileged DoS.** The manifest lock
  (`$MANIFEST_DIR/.install-manifest.lock`, fd 9) is now a root-owned `0600` file (an old
  `0644` lock is upgraded), so a peer account cannot open it and hold an exclusive flock to
  starve every installer. Acquisition is delegated to a short-lived `coproc sudo bash -c`
  root holder that owns fd 9, checks the fd/path `(dev,ino)`, owner `0`, mode `600` and
  regular-file type via `/proc/$$/fd/9` INSIDE the holder process (real `sudo` closes
  inherited fds, so a separate `sudo python3 fstat(9)` is both wrong on a real system and
  stub-green in tests), takes the bounded `flock -x -w` wait
  (`CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT`, default 10s), prints `READY` and blocks on stdin.
  Closing the pipe on release/crash gives EOF, so the kernel drops the flock with no stale
  lock and no EXIT trap. Symlinks, non-regular files, inode swaps and an untrusted parent
  directory (not root/current-user owned, or group/other-writable `mode & 022 != 0` — keep the
  directory at `0755`) all fail closed before any privileged chmod/chown/open; lock creation
  uses `umask 077` + `set -C`, never `install`.
* **A whole component operation is one lock transaction.** `run_manifest_operation()` wraps
  backup/record → deploy → finish/rollback for keyboard (including the keyd step), audio,
  fingerprint (including PAM), EC/battery and power installers, with `MANIFEST_LOCK_DEPTH`
  making nested helpers re-entrant and no lock at all in `DRY_RUN`. The body is called bare so
  `set -e` stays active (no fail-open deployment) and no EXIT trap is installed (the
  fingerprint installer keeps its own trap). This closes the race where process A wrote a
  `was_existing=false` record, unlocked, process B's uninstall consumed it while the target
  was absent, and A then deployed a file with no tracking record. The `fingerprint --source`
  build holds the lock for the whole clone/compile, so raise the timeout for a parallel
  operation.

Current unit-test totals (these fixes plus the eleventh re-review fixes below):
**406** daemon, **73** sleep-hook and **1642** rollback cases (the last run as root),
all 0 failures.

#### Eleventh re-review fixes (2026-11-23, unit-tested)

These are logic/robustness fixes covered by the shell unit suites; the 2026-11-22 real
S3 records above are kept verbatim and no new hardware run is claimed here.

* **plugdev ownership is decided across all components.** `remove_group_membership()`
  aggregates the `(group,user)` records of every component: any explicit `was_member=false`
  proves we added the membership, all `true` (or no record) meant **keep it at the eleventh
  re-review** (the twelfth added rc 3 stale-record consumption when no udev rule needs the
  group), and a wrong safety-field type fails closed. After a successful `gpasswd -d` all
  records for the pair are consumed together, so a full install/uninstall no longer depends on whether
  keyboard or fingerprint was installed first. `gpasswd -d` failure is now an error with
  rc 1 (R1-R10, including original non-member/already-member, both orders, single-module,
  gpasswd failure, udev gating, DRY_RUN and wrong-type cases); the keyboard, fingerprint
  and EC uninstallers fold it into their exit code.
* **PAM original configuration is protected.** Uninstall no longer sed-edits sudo PAM:
  `disable_pam_fingerprint()` performs no direct edit, and `rollback_component("fingerprint")`
  restores the original bytes, so a pre-existing exact `pam_fprintd` line survives. Install
  uses `grep -qFx --` for an exact match and honours the `CROS_ENABLEMENT_PAM_SUDO_PATH` /
  `CROS_ENABLEMENT_PAM_DIR` test seams. On Debian Tier 2 the `common-*` files that really
  contain a fp line are backed up before fp lines are stripped (this eleventh-re-review
  wording described a `pam-auth-update --remove fprintd` call that the **twelfth** re-review
  replaced with direct `sed`; the **thirteenth** then added a selection/saved-file snapshot,
  `--package` convergence and uninstall restoration (uninstall now writes debconf only after
  rollback is confirmed complete).
  A read-only post-rollback check warns on a stale manifest record
  or a corrupt manifest but never mutates a file; Fedora `authselect` and openSUSE
  `pam-config` profile state is a documented limitation (warning only). PAM-1..8 verify
  byte-identical sudo PAM after install + uninstall when the original already had the line.
* **The lock's parent directory is a root-controlled trust boundary.** Only a root-owned
  parent is accepted (no EUID/UID branch), every ancestor is checked (non-root-owned or
  g/o-writable without sticky fails closed; a root-owned sticky world-writable layer such as
  `/tmp` `1777` is allowed; symlinks only when their container is root-owned and not g/o-writable),
  and the root holder pins the direct parent with fd 8 (uid/mode/type/dev+ino recheck,
  `FAILED:parentdir`) to defeat a rename that would let a second process lock a fresh inode.
  S10/S10b/S10c/S10d/T13 cover the user-owned-`1777` ancestor rejection, the root-`1777`
  pass, the rename/double-holder defence and a non-root caller on the default root-owned path.
  A custom writable lock parent is no longer accepted.
* **CI failure fix — PAM fault injection is per-call.** After the push, the
  Backup/Rollback CI job reported 1383 passed / 4 failed: PAM-4's
  `STUB_FAIL_ROLLBACK_PY=1` leaked from the parent shell into PAM-8. `dab9436`
  passes the fault flag as an explicit argument to `run_pam_install()` /
  `run_pam_uninstall()` and exports it only inside the sandbox snippet, so a later
  uninstall cannot inherit it. New **PAM-9** regression injects fail=1 first, then
  deliberately poisons the parent environment with fail=0 and verifies a clean
  rollback with byte-identical PAM files (+5 assertions; rollback total **1642**).

Unit-test totals after these fixes: **406** daemon, **73** sleep-hook and **1642** rollback
cases (the last run as root), all 0 failures.

#### Twelfth re-review fixes (2026-11-24, unit-tested)

These are logic/robustness fixes covered by the shell unit suites; the 2026-11-22 real
S3 records above are kept verbatim and **no new hardware run is claimed here**.

* **The lock's trust boundary is the canonical, symlink-free path (P2 SECURITY; custom
  manifest path BLOCKER).** `CROS_ENABLEMENT_MANIFEST_DIR` must be absolute (`must be an
  absolute path`), and every literal component is checked with `-L`: any symlink component
  is refused (`contains a symlink` / `untrusted symlink`) even when root-owned and otherwise
  safe — a deliberate fail-closed trade-off because a symlink can hide a user-writable real
  target that can rename the lock. The gate resolves the deepest **existing** prefix with
  `realpath -e`, re-appends the missing layers (so first-time creation still works), runs
  the root-controlled ancestor gate on the **real** path (`untrusted realpath ancestor`), and
  uses that canonical path for the lock. Inside the process that actually holds fd 9 the
  root helper re-derives `realpath -e "$dir"` and requires equality (`FAILED:canonical`),
  then checks every real ancestor for uid `0` and `mode & 022 == 0` or a root-owned sticky
  bit (`FAILED:ancestor`); the fd 8 parent pin and `FAILED:parentdir` are unchanged. R1
  (relative CWD), R2 (trusted symlink → user target), R2e2e (canonical ancestor end-to-end),
  R3 (holder rejects a symlink-derived path) and R4 (control) cover the regression.
* **Stale all-true group records are refreshed (P2 PERMISSION LIFECYCLE).**
  `_GROUP_OWNERSHIP_PY` now returns rc 3 when **every** `(group,user)` record says
  `was_member=true` (pre-existing) — rc 0 (some `false`) and rc 1 (no record) are unchanged,
  rc 2 still fails closed. With rc 3 and a udev rule still referencing the group, the
  first-wins snapshot is kept; with **no** rule (all consumers uninstalled), all stale records
  are consumed with **zero `gpasswd` calls** — all-true means membership was never added by
  us, so consuming metadata cannot change permissions and the next install re-snapshots the
  real, possibly admin-changed state. Consume failure fails closed and keeps the records.
  R3 was extended and R11 (admin group change → re-install rollback timing), R12/R13/R14
  and R9b cover the lifecycle.
* **The Debian PAM profile selection is preserved (P2 STATE RESTORATION) — superseded by the
  thirteenth re-review below.** Install no longer calls `pam-auth-update --remove fprintd` at
  all: that action also deletes debconf's `libpam-runtime/profiles` selection, which manifest
  rollback cannot restore. Tier 2 backed up the `common-*` files containing fp, then a direct
  `sed -i '/pam_fprintd\.so/d'` removed only the module lines — the same `common-auth`-has-no-fp
  result that closes the GDM unlock claim race. The twelfth-re-review design left debconf
  unmanaged after that sed; the **thirteenth** re-review found that a later
  `pam-auth-update --package` derives the profile list from the current `common-*` content and
  would then permanently drop the user's selection, so it replaced this with a first-wins
  snapshot + self-convergence + uninstall restore (see the new section below). Fedora
  `authselect` / openSUSE `pam-config` profile-state warnings remain.

Current unit-test totals: **406** daemon, **73** sleep-hook and **1642** rollback cases (the
last run as root), all 0 failures. No new real S3 run in this round.

#### Thirteenth re-review fixes (2026-11-24, unit-tested)

These are logic/robustness fixes covered by the shell unit suites; the 2026-11-22 real S3
records above are kept verbatim and **no new hardware run is claimed here**. CI adds a new
Ubuntu 24.04 container E2E job that exercises the unmodified Debian/Ubuntu `pam-auth-update`
and debconf tools (baseline with real `pam-auth-update --enable fprintd`, a sensitivity control
that sed-only + real `--package` loses the selection, a full install → `--package` → uninstall
round-trip, and a non-root/passwordless-`sudo` uninstall case).

* **PAM profile selection survives package updates (P1, cross-package reversibility).** Install
  now snapshots debconf `libpam-runtime/profiles` and every `/var/lib/pam/*` saved module file
  into a first-wins sidecar (`pam-selection` mode `0644`, `pam-selection.saved` a root-owned
  `0700` directory) before touching any file — atomic, with every read/copy mediated by `sudo`
  so a non-root caller with passwordless `sudo` can restore them. **All** existing `common-*`
  files are rollback-tracked (not only fp-containing ones, because `--package` rewrites any
  of them). Direct `sed -i '/pam_fprintd\.so/d'` still
  closes the GDM race immediately; then the installer itself runs `pam-auth-update --package`
  so debconf and `/var/lib/pam` converge to a stable "no fprintd" state and a later
  package-triggered run is a no-op. `--remove` is still never used. On uninstall, after a
  read-only probe confirms the sudo record and every `common-*` record are consumed (a corrupt
  manifest or a surviving record keeps the snapshot), the saved bytes are copied back, the
  original multiselect is written with `debconf-set-selections`, `--package` runs again and
  the live selection is verified (exact or whitespace/order-insensitive set) before the sidecar
  is consumed; a mismatch keeps it and returns rc 1. The fingerprint installer folds
  `disable_pam_fingerprint`'s rc into rollback_rc.
* **Group membership keeps per-install generation evidence (P2).** Group records may carry an
  optional boolean `added_by_project` (absent = legacy `false`; wrong type is `MANIFEST_INVALID`
  and fails closed). `was_member` stays first-wins. On reinstall where the original snapshot
  was `true` but the user is currently not a member (admin removed it while still installed),
  the writer sets the flag; the ownership probe treats it like `was_member=false` (rc 0), so
  uninstall removes the membership granted this generation. A failed `usermod` clears **only**
  the flag via `manifest_clear_group_added`; consume-all removes the whole row, flag included.
  R15–R20 cover the lifecycle.

Current unit-test totals: **406** daemon, **73** sleep-hook and **1642** rollback cases (the
last run as root), all 0 failures. No new real S3 run in this round.

### 4. Wi-Fi / Bluetooth / Webcam / Storage

| Check | Result | Evidence |
| :--- | :---: | :--- |
| Wi-Fi 6 AX201 | ⚠️ | 📄 `hardware/lspci.txt`: `iwlwifi` on `00:14.3` — **device present, connectivity/throughput not measured** |
| Bluetooth AX201 | ⚠️ | 📄 `hardware/lsusb.txt`: `btusb` — Intel `8087:0026` — **device present, pairing/audio not measured** |
| Webcam | ⚠️ | 📄 `hardware/lsusb.txt`: `uvcvideo` — Foxlink `05c8:03e1` — **device present, capture not tested** |
| SD / SATA | ⚠️ | 📄 `hardware/lspci.txt`: `sdhci-pci` x2, `ahci` — **device present, I/O not tested** |
| WPA3 / Wi-Fi throughput | ❌ | **Not measured** (no network-level tests in evidence) |

### 5. Power & Suspend

| Check | Result | Evidence |
| :--- | :---: | :--- |
| Sleep modes advertised | 🟢 | 📄 `system/mem_sleep.txt`: `s2idle [deep]` — **both** supported |
| **Current default** | ⚠️ | **`deep` (S3) is the current default**, not s2idle (README now says "S3 deep default, s2idle available") |
| Actual suspend/resume cycle | 🟢 | **Tested 2026-08-18**: lid close → `PM: suspend entry (deep)` → `ACPI: PM: Preparing to enter system sleep state S3` → open lid → `Waking up from system sleep state S3` → `PM: suspend exit`, zero errors (journalctl -k). Also confirms the lid-close rule from `power/systemd/logind.conf.d/` is live. |
| S0ix residency / ASPM tuning | ❌ | **Not measured** (no PMC `slp_s0_residency` evidence) |
| Battery charge control | 🟢 | `c640-ec-control` & `c640-battery-limit.service`: `CHARGE_BEHAVIOUR=inhibit-charge` @ 90% (0 mA hardware AC bypass; dual-track sysfs + `ectool` LPC control verified; 0-window sleep hook tested across S3 suspend) |

### 6. Display / Graphics

| Check | Result | Evidence |
| :--- | :---: | :--- |
| i915 driver bound | 🟢 | 📄 `hardware/lspci.txt`: `i915` on `00:02.0` (CometLake-U GT2) |
| VA-API 4K 60fps hardware decode | ❌ | **Not measured** (`vainfo` not available in evidence bundle) |
| Dual Type-C video output | ❌ | **Not verified** — no external display was connected during testing; only `CROS_USBPD_CHARGER0/1` power-supply nodes exist (📄 bundle has no DP-alt-mode evidence) |

---

## ⚠️ Other Components (Status Per Row)

These files are installed, available-but-not-enabled, or deliberately not
installed on the device above, exactly as the status column says. 🟢 rows have
the evidence noted inline; ⚠️/❌ rows are **not** verified and should be treated
as "provided for your distro, verify on your own hardware":

| Module | Files | Status |
| :--- | :--- | :---: |
| **Power tuning — modprobe quirks** | `power/modprobe.d/99-hp-c640-power.conf` | 🟢 installed + rebooted 2026-08-19 (d0i3 stripped, initramfs rebuilt); **dark-panel-after-resume persists** (screen still dark until keypress — user accepted; see [TROUBLESHOOTING.md §15](TROUBLESHOOTING.md)) |
| **Power tuning — wireplumber / logind** | `power/wireplumber/50-disable-suspend.conf`, `power/systemd/logind.conf.d/99-hp-c640-lid.conf` | 🟢 installed 2026-08-18 (logind lid rule verified via a real S3 lid cycle) |
| **Power tuning — TLP** | `power/tlp/99-hp-c640.conf` | ❌ not installed — **conflicts with the active `power-profiles-daemon`** (see ⚠️ below) |
| **EC control & battery protection** | `ec/install-ec.sh`, `scripts/c640-ec-control.sh`, `ec/systemd/c640-battery-limit.service`, `ec/systemd/c640-ec-sleep.sh` | 🟢 installed + hardware-verified 2026-08-23 (standalone `ectool` LPC handshake, status dashboard, 90% battery daemon, 0 mA idle bypass, and S3 resume hook verified) |
| **Fingerprint system-sleep hook** | `fingerprint/systemd/fprintd-sleep.sh` | 🟢 installed + verified 2026-08-19 (lid-cycle test: first unlock has fingerprint prompt, zero resume delay, no retry lines) |
| **Fingerprint udev rule** | `fingerprint/60-cros-fp.rules` (plugdev/0660/uaccess) | 🟢 installed 2026-08-18, verified via `getfacl` after reboot |
| **keyd keyboard config** | `keyboard/keyd/cros.conf` | 🟢 installed 2026-10-31; `overloadt2` verified with the virtual uinput test (tap→CapsLock, hold→bare Meta, Search+top row→F1-F10) and with real-key passive capture on the same day |
| **PipeWire phantom-jack patch** | `audio/patches/acp-phantom-jack.patch` | ❌ current PipeWire 1.6.2 already handles jack state (patch is for older versions) |
| **Touchscreen / touchpad** | stock kernel drivers (`elan_i2c`) | ⚠️ modules present (`i2c-ELAN0000/0001`), but **no functional gesture test in evidence** |
| **Keyboard backlight sync (ScreenBlank)** | `keyboard/c640-kbd-backlight-sync`, `61-chromeos-kbd-backlight.rules`, `c640-kbd-backlight-sync.service`, `c640-kbd-backlight-sleep.sh` | 🟢 installed + hardware-verified 2026-10-31 (event-driven `gdbus`/`ScreenSaver` 2→0→2, `--test-blank`/`--test-unblank` PASS, sysfs `0660 root:plugdev`, sleep hook save/restore 6→0→6 — a pre-refactor direct invocation; the current hook is a pure handoff writer — see §3). CI asserts deployed daemon/unit/hook are byte-identical to the repo and runs shell unit tests (406 daemon + 73 hook + 1642 rollback, the last as root); **full real S3 freeze/thaw verified 2026-11-22** (locked defer + unlocked restore, see §3) |
| **Sleep-wake via key/fingerprint** | stock ACPI | ⚠️ lid-open S3 resume verified (journal `PM: suspend exit`); key/fingerprint wake untested |
| **Known issue — dark panel after lid open** | i915 PSR/FBC/GuC quirks (see §15) | 🟡 quirk installed but **did not fix it**: screen stays dark until a keypress after lid-open S3 resume — user accepted, remedies still open |
| **Arch / Fedora / openSUSE / NixOS packaging** | `fingerprint/packaging/PKGBUILD`, `*.spec`, distro docs | ❌ only **Ubuntu 26.04** hardware-tested; CI runs the installer's source build in Arch/Fedora/Ubuntu containers, but the `PKGBUILD`/`.spec` packaging definitions themselves are **not exercised by CI** |

> [!NOTE]
> **`power/modprobe.d/99-hp-c640-power.conf` on kernel ≥ 7.0**: the
> `iwlwifi d0i3_disable=0` parameter was **removed** in kernel 7.0, so the
> installer (`power/install-power.sh`) and this device both strip that token
> automatically (otherwise modprobe would fail and **Wi-Fi would not load**).
> `enable_guc=2` means HuC-load-only on 7.0, and the i915 `enable_psr=0` /
> `enable_fbc=1` tweaks are applied here specifically for the
> dark-panel-after-resume issue. **TLP is not installed** on this device:
> it conflicts with the active `power-profiles-daemon` on Ubuntu 26.04.

---

## 📋 How to Reproduce the Evidence

```bash
# Full hardware + audio + fingerprint + power status in one archive:
./scripts/sysreport.sh
# Fingerprint enrollment/verification:
fprintd-list "$USER"
fprintd-verify "$USER"
# Audio devices:
aplay -l
wpctl status
# Sleep mode:
cat /sys/power/mem_sleep
```

> [!NOTE]
> The diagnostic bundle (`c640-diagnostic-*.tar.gz`) is git-ignored to avoid
> leaking serials/PII. Commit **sanitized** evidence here if you want
> verifiable proof in the repository itself.

---

## 🔄 Last Verified

* **Date**: 2026-08-15 (evidence bundle), 2026-08-17 (unit tests re-run),
  2026-08-18 (batch-1 installs + lid-close S3 suspend/resume test +
  fingerprint claim-race fix), 2026-08-19 (system-sleep hook + i915 PSR
  quirk installed & rebooted; lid-cycle fingerprint re-test passed — first
  unlock works, zero resume delay, no retry lines; dark-panel issue
  unresolved, user accepted), 2026-08-23 (EC 90% battery daemon + `c640-ec-sleep.sh`
  zero-window resume hook + standalone `ectool` LPC handshake verified; packaging
  iteration 2 `1.94.10-2` metadata prepared, driver source unchanged),
  2026-08-29 (keyboard backlight sync installed — config-only at the time,
  CI smoke passed; superseded by the 2026-10-31 entry below),
  2026-10-31 (keyboard top row re-measured: hwdb now maps the real AT scancodes
  `0x3b`-`0x44`; keyd `overloadt2` dual-role Search verified with the uinput
  test and with real-key passive capture; backlight sync installed and
  exercised end-to-end with `--test-blank`, `ScreenSaver.ActiveChanged` and the
  sleep hook),
  2026-11-22 (Phase 6 real S3 acceptance of the keyboard-backlight handoff:
  `rtcwake -m no -s 20` + `systemctl suspend` on systemd 259 / gnome-settings-daemon
  50; locked resume defers and keeps `state=30`, then `loginctl unlock-session 2`
  restores brightness/gsd/UPower to 30 and consumes both handoff files),
  2026-11-23 (sixth, seventh, eighth, ninth, tenth and eleventh re-review unit-test re-runs:
  406 daemon, 73 sleep-hook and 1642 rollback cases, 0 failures; result-code, fail-closed
  manifest, save-before-blank, single-sample/invalid-state self-heal, manifest field
  validation, pre-mutation rollback gate and rollback safety semantics — required/unknown-state
  fail closed, absent-target first-backup restore, checked systemctl restores,
  record-before-change group membership, atomic restore without unlink and rc 1 for a
  missing backup, a cross-process manifest lock with unique writer temps, the tenth
  re-review's 0600 root-only holder lock plus whole-operation serialization, and the eleventh
  re-review's cross-component plugdev ownership, rollback-only PAM restoration and
  root-controlled lock parent with fd 8 pin — docs synced — no new real-S3 run),
  2026-11-24 (twelfth re-review unit-test re-run: 406 daemon, 73 sleep-hook and 1642 rollback
  cases, 0 failures; canonical symlink-free manifest-lock trust boundary with holder-side
  `FAILED:canonical` / `FAILED:ancestor` rechecks, stale all-true group-record consumption
  with zero gpasswd, and Debian PAM profile-selection preservation via direct line removal —
  docs synced — no new real-S3 run),
  2026-11-24 (thirteenth re-review unit-test re-run: 406 daemon, 73 sleep-hook and 1642 rollback
  cases, 0 failures; first-wins PAM selection/saved-profile sidecar with `--package` convergence
  and verified uninstall restoration, plus optional per-install `added_by_project` group
  evidence, including a real-tool Ubuntu 24.04 container E2E — docs synced — no new real-S3 run)
* **OS / kernel**: Ubuntu 26.04 LTS; `7.0.0-38-generic` for the 2026-10-31
  keyboard/backlight session, `7.0.0-29-generic` for the 2026-08 evidence bundle
* **Firmware**: MrChromebox `2606.1`
* **Hardware**: HP Pro c640 Chromebook (`dratini`/`hatch`)
