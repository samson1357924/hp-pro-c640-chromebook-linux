# 🛠️ Troubleshooting & Pitfall Guide

This article covers the sixteen most common problems and their root-cause solutions
when installing and using Linux on the **HP Pro c640 Chromebook (Google
`dratini`)**.

---

## 🔊 Audio

### 1. System audio shows "Dummy Output" with no sound at all

* **Root cause**: the stock `alsa-ucm-conf` of standard distros has not yet
  merged the `sof-rt5682` downstream configuration into mainline. The PipeWire
  ACP mechanism misdetects all outputs as unavailable because the ASoC chip
  lacks a Phantom Jack kcontrol, leaving WirePlumber with only "off" to choose.
* **Solution**: run this project's one-click install command:

  ```bash
  ./setup.sh --audio
  ```

### 2. Kernel log shows `cl_dsp_init: timeout with rom_status_reg`, sound card missing

* **Root cause**: **Intel Management Engine (ME) is disabled**. The Intel Comet
  Lake SOF DSP firmware relies heavily on Intel ME communication during boot and
  clock initialization.
* **Solution**: **never use me_cleaner or disable Intel ME in the UEFI
  settings**. Make sure Intel ME is enabled in the MrChromebox UEFI firmware.

### 3. Speakers still play when headphones are plugged in, or switching is not automatic

* **Solution**: restart the WirePlumber service for the current user:

  ```bash
  systemctl --user restart wireplumber
  ```

### 4. Audio is muted after waking from sleep (Sleep/Resume)

* **Solution**:

  ```bash
  systemctl --user restart wireplumber pipewire
  ```

---

## 🖐️ Fingerprint

### 5. `fprintd-enroll` reports `/dev/cros_fp: Permission denied`

* **Root cause**: the current user is not in the `plugdev` group, or the udev permission rules have not been reloaded.
* **Solution**:

  ```bash
  sudo usermod -aG plugdev "$USER"
  sudo cp fingerprint/60-cros-fp.rules /etc/udev/rules.d/
  sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=misc
  ```

  *(Log out and log back in afterwards)*

### 6. Fingerprint doesn't work at boot login, but lock screen and `sudo` do

* **Root cause**: this is a security architecture design of Linux desktops
  (e.g. GNOME / GDM). **GNOME Keyring (the keyring that stores Wi-Fi passwords
  and browser passwords) needs your plaintext password to be decrypted**.
* **Solution**: on a cold boot, type your password once at first login to unlock
  the Keyring; after that, all lock-screen unlocks (`Super + L`),
  wake-from-suspend, PAM authorization and `sudo` can be done instantly with a
  fingerprint.

### 7. Fingerprint stops working after a reboot (`command failed: UNAVAILABLE` / `INVALID_PARAM`)

* **Symptoms**: after a reboot the finger is no longer recognized at GDM login,
  lock screen (`Super + L`), `sudo` or any `fprintd-verify`. `journalctl -u
  fprintd` shows `Device reported an error during verify: command failed:
  UNAVAILABLE` (the first attempt may instead be `INVALID_PARAM`).
* **Root cause (two layers)**:
  1. **Protocol layer** — the FPC1025 Match-on-Chip sensor is driven by the
     ChromeOS FPMCU. The FPMCU holds the **seed** and a **user context
     (`user_id`)**, both in FPMCU **RAM (not flash)**: the seed (and the
     `SEED_SET` flag) survive a *warm* reboot only because the FPMCU stays
     powered, and on a *cold* boot they are lost and the host re-sends `FP_SEED`
     from `/var/lib/fprint/crfpmoc.key`. The crfpmoc driver's keys handshake
     contains an `FP_CONTEXT` step that (a) re-establishes the crypto context and
     (b) triggers the FPMCU sensor reset/open (`fp_sensor_open`, ~175 ms) that
      re-initializes the sensor. A previous driver build (which jumped directly to
      `KEYS_DONE` when the encryption seed was already set) skipped that step
      whenever the seed was already set, so after a reboot the sensor stayed
      uninitialized → every
     template operation failed with `EC_RES_UNAVAILABLE`. A second latent bug, a
     `RESET_SENSOR`/`FP_MODE_FINGER_UP` mode conflict that produced
     `INVALID_PARAM`, was also fixed by clearing the sensor mode (`FP_MODE=0`)
     before `FP_CONTEXT_ASYNC`. Both are fixed in the current driver
     (`crfpmoc_keys_enc_status_cb` now jumps to `KEYS_CLEAR_MODE`, which is a new
     step in the `KEYS` sub-SSM).
  2. **Data layer (why you must re-enroll)** — the per-template decryption key is
     derived from the seed + a per-template salt, mirroring Chromium's own design
     where `HW_Key = HKDF(SBP_Src_Key, TPM_Seed, User_Salt, User_ID)`
     (<https://chromium.googlesource.com/chromiumos/platform/ec/+/HEAD/docs/fingerprint/fingerprint-authentication-design-doc.md>).
     Templates enrolled under the **broken** build can fail to decrypt once the
     sensor/context bring-up — or the seed stored in `/var/lib/fprint/crfpmoc.key`
     — changes. The `user_id` is **not stored inside the template**, so such
     templates can never be recovered by a driver change. Re-establishing the
     context on every open is the *correct* fix (it mirrors how Chromium's `biod`
     calls `SetContext` before every template upload), but it means templates
     from the broken build must be re-enrolled. (Note: the current crfpmoc driver
     sends a zero context, so the binding is effectively seed + per-template
     salt.)
* **Solution**:
  1. Make sure you built and installed a crfpmoc that includes both fixes (driver
     newer than 2026-08-15). Re-run `fingerprint/install-fingerprint.sh` if
     needed, then `sudo systemctl restart fprintd`.
  2. **Re-enroll your fingerprints — the old templates are undecryptable**:

     ```bash
     fprintd-delete "$USER"
     fprintd-enroll "$USER"
     ```

     (Place the same finger repeatedly when prompted; enroll both thumbs / index
     fingers as before.)
  3. After re-enrolling, verify works across reboots because the new templates
     are encrypted with the now-stable seed file. **Never delete or regenerate
     `/var/lib/fprint/crfpmoc.key`** (must stay `root:root`, `0600`) — if it is
     lost or its permissions are wrong, a cold reboot or a fresh re-enroll is
     required to recover.

### 8. Two fingerprint stacks fighting over `/dev/cros_fp`

* **Root cause**: only one host program should drive the FPMCU at a time. This
  project uses the crfpmoc libfprint driver (consumed by `fprintd`). A separate
  project, **ChocolateLoverRaj/rust-fp** (`/usr/local/bin/rust-fp-dbus-interface`
   and its `rust-fp-dbus-interface.service`), also opens `/dev/cros_fp`. Because the
  seed/context/template state is a single global on the FPMCU, two programs
  issuing `EC_CMD_FP_SEED` / `EC_CMD_FP_CONTEXT` / enroll / verify will corrupt
  each other's encryption context and unlock state.
* **Solution**: use only one stack. If `rust-fp` is installed, disable it and rely
   on crfpmoc:

   ```bash
   sudo systemctl disable --now rust-fp-dbus-interface.service
   sudo systemctl restart fprintd
   ```

   (Alternatively, remove the rust-fp binary and service and reboot.)

---

## ⌨️ Keyboard

### 9. Top-row function keys (Back/Reload/Brightness/Volume) don't respond

* **Root cause**: the system is missing the `90-chromebook-keyboard.hwdb`
  scancode mapping, **or** it has a mapping for scancodes this machine never
  emits (for example a hwdb file copied from another Chromebook). Installing
  the hwdb again will not fix the second case.
* **Solution**:

  ```bash
  # Verify the applied hwdb map first (read-only EVIOCGKEYCODE, no grab):
  sudo python3 keyboard/tests/check-top-row-hwdb.py
  # If it fails, install/refresh the mapping:
  ./setup.sh --keyboard
  ```

  > This file maps the scancodes inferred from post-hwdb `EVIOCGKEY` key state
  > against the AT table on a Dratini: AT `0x3b`-`0x44`; no raw `MSC_SCAN`
  > capture is present in the evidence. It applies only to the explicit
  > Dratini / HP Pro c640 DMI entries in
  > `keyboard/90-chromebook-keyboard.hwdb` — it does **not** match other Hatch
  > boards. Other Chromebooks may emit the ChromeOS action scancodes (`0xea`,
  > `0xe9`, ...) instead and need their own hwdb entry. `--listen` only shows
  > the post-hwdb `KEY_*` events (EVIOCGKEY), not raw scancodes. To find yours,
  > stop keyd (`sudo systemctl stop keyd`) and read `EV_MSC/MSC_SCAN` with
  > `check-top-row-hwdb.py --scan 60` or plain `evtest` (no `--grab`), then infer
  > the scancode against the standard AT table and create your own hwdb entry
  > (see `CONTRIBUTING.md` → "New Chromebook model?" in §2). On an unknown model
  > or when `EVIOCGKEYCODE` is unsupported, use
  > `check-top-row-hwdb.py --scan-only 60`: it skips the table check entirely, so
  > a fixture mismatch or ioctl failure cannot block raw capture. When done, run
  > `sudo systemctl start keyd` to restore the service; otherwise Search
  > tap/hold and brightness remapping stay disabled.
  >
  > `RESULT=` is only the EVIOCGKEYCODE mapping verdict. With `--scan SECONDS`,
  > no observed `MSC_SCAN` (keyd still grabbing, or no key pressed) still prints
  > `RESULT=PASS (mapping check only; raw capture FAILED)` but exits non-zero.
  > Judge overall success by the exit code / `RAW_CAPTURE=`, not `RESULT=PASS`
  > alone.

### 10. Want the Search key to act as "CapsLock on tap, Super on hold"

* **Solution**: install and enable `keyd`:

  ```bash
  sudo apt install -y keyd   # (or dnf/pacman)
  sudo cp keyboard/keyd/cros.conf /etc/keyd/cros.conf
  sudo systemctl enable keyd
  sudo systemctl restart keyd   # required: keyd 2.5.x reads config only at start-up
  ```

  > On Ubuntu 26.04 the package installs `/usr/bin/keyd.rvaiya` (2.5.0); `keyd check`
  > only exists in >= 2.6. The recommended path is
  > `sudo ./keyboard/install-keyboard.sh --with-keyd`, which handles both.
  > If the top row does nothing, first check the **scancodes**, not just the hwdb
  > text: `sudo python3 keyboard/tests/check-top-row-hwdb.py` must print
  > `RESULT=PASS`. This hardware emits AT scancodes `0x3b`-`0x44`, not the
  > ChromeOS action scancodes some other Chromebooks use.
  > If Search tap/hold misbehaves, use `overloadt2(meta, capslock, 200)`, not
  > `overload`: plain overload injects a `LEFTCTRL` guard on release and Mutter
  > then never opens Activities.
  > Verify with `sudo python3 keyboard/tests/capture-keyd-output.py` (read-only;
  > `keyd monitor` cannot open a device keyd already grabbed). Also check that
  > keyd grabbed the internal AT keyboard:
  > `journalctl -u keyd | grep 'DEVICE: match'` should show `0001:0001`.

### 11. Keyboard backlight doesn't turn off / restore with screen blank

* **Symptoms**: `c640-kbd-backlight-sync --check` shows `brightness: 5/100` but `--test-blank`
  stays `0` or doesn't restore; `journalctl --user -u c640-kbd-backlight-sync` is empty
  or `Daemon running: no`. A related symptom is **flicker / oscillation**: the LED
  repeatedly jumps between the saved value and full brightness around blank/unblank,
  usually meaning gsd-power's cache and UPower disagree or the ScreenSaver re-check
  lost a race.

  > [!IMPORTANT]
  > On a real S3 cycle systemd **freezes `user.slice`** before the sleep hook's
  > `post` phase ([systemd-sleep(7)](https://www.freedesktop.org/software/systemd/man/latest/systemd-sleep.html)).
  > A session-bus probe from the root hook therefore always fails or times out;
  > the hook is now a **pure handoff
  > writer**: `pre` publishes `c640-kbd-backlight.suspend` (one integer, `0` valid),
  > `post` publishes `c640-kbd-backlight.resume` (`<epoch> <action>`), both `0600` +
  > chowned to the session user + atomically `mv`-ed into `$XDG_RUNTIME_DIR`
  > (`C640_KBD_HANDOFF_DIR` overrides it). It never writes the LED, deletes state or
  > queries D-Bus. The thawed **user daemon** is the only writer: it adopts the handoff
  > on `PrepareForSleep(false)` from the **system** bus (not frozen) and restores via
  > gsd-power → UPower → legacy. Do not reintroduce root-side session-bus probing
  > in the hook — that was the old second-writer bug. The root
  > `/run/c640-kbd-backlight/state` written by `pre` is only a **single-shot diagnostic
  > snapshot of the first suspend in a boot** (first-wins, kept until reboot); it is not
  > consumed by the hook or the daemon and is never used for restore. The hook writes a
  > handoff only for a **single active local graphical session**; 0 or multiple candidates
  > fail closed in the **root journal** as `session selection fail-closed: ...`, while the
  > chosen uid is logged as `selected session ... for uid ...` and pinned in a root-only
  > `0600` file at `pre` (reused at `post`). It never creates, chmods or chowns
  > `/run/user/<uid>`; a missing/insecure dir fails closed with no handoff. The uid is read
  > from `loginctl show-session`'s **Session.User** (`User=<numeric uid>`), never the
  > User-object `UID=` key, and session IDs may be alphanumeric (e.g. `c1`); a missing
  > `User` rejects that session. Both handoff files are published with a same-directory
  > temp file plus `mv -T -f --`, with destination-entry and parent-inode guards and **no
  > `cp`/plain-`mv` fallback** (`unsafe destination entry`, `cannot publish ...`). An
  > explicit `C640_KBD_HANDOFF_DIR` is trusted by design (only `-d` is checked) but its
  > final component is still guarded. The daemon no longer scans other uids' runtime dirs:
  > only an **explicit** `C640_KBD_HANDOFF_DIR` override that disagrees with its own file
  > logs `[WARN] handoff directory mismatch`. For cross-uid diagnosis read the root
  > journal, not a `/run/user` scan.

* **Seventeenth-re-review fail-closed messages** (refusals to write, never silent success):
  `suspend/resume handoff token mismatch ...`, `cycle-begin file ... not adopted` and
  `suspend handoff token epoch ... stale` mean the handoff is from an earlier cycle (or
  `pre` failed), so the saved brightness is left unchanged — re-run the S3 cycle rather than
  expecting a restore. `handoff skipped (fail-closed): python3 unavailable` means the new
  fd-pinned publisher cannot run: install `python3` on the target.
  `retry epoch invalidation failed; all brightness writers fail closed` means the
  coordination channel could not even be revoked in place (`COORDINATION_UNHEALTHY`): fix the
  runtime state directory and restart the user daemon. `evidence clock unavailable;
  evidence expired` / `evidence clock moved backwards; evidence expired` mean the monotonic
  TTL (`/proc/uptime`) could not be trusted, so the guard re-probes and fails closed if it
  still cannot verify. In all cases the daemon **degrades to refusing writes** rather than
  trusting stale witnesses; none of this is a real-S3 verification.

* **Triage** (all gdbus queries below are read-only):

  ```bash
  c640-kbd-backlight-sync --check          # brightness, STATE_FILE, Daemon running, ScreenSaver available
  systemctl --global is-enabled c640-kbd-backlight-sync.service
  systemctl --user is-active c640-kbd-backlight-sync.service  # needs graphical-session
  journalctl --user -u c640-kbd-backlight-sync.service -f
  loginctl show-user "$USER" -p State       # active?
  # read-only schema check of the selector (no S3, no writes):
  bash keyboard/tests/loginctl-contract-check.sh   # CONTRACT OK on systemd host, SKIP otherwise
  loginctl show-session "$XDG_SESSION_ID" -p User  # must be User=<numeric uid>, never UID=
  udevadm test /sys/class/leds/chromeos::kbd_backlight  # check TAG+="uaccess" rule
  ls -l /sys/class/leds/chromeos::kbd_backlight/brightness  # 0660 + plugdev?
  cat /sys/class/leds/chromeos::kbd_backlight/brightness
  # read-only handoff files (only present across a suspend/resume cycle):
  cat "$XDG_RUNTIME_DIR/c640-kbd-backlight.suspend" 2>/dev/null  # saved value, 0 valid
  cat "$XDG_RUNTIME_DIR/c640-kbd-backlight.resume" 2>/dev/null   # "<epoch> <action>"
  # read-only D-Bus probes (no writes, safe while the daemon runs):
  gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.GetActive
  gdbus call --session --dest org.freedesktop.ScreenSaver --object-path /org/freedesktop/ScreenSaver --method org.freedesktop.ScreenSaver.GetActive
  gdbus call --session --dest org.gnome.SettingsDaemon.Power --object-path /org/gnome/SettingsDaemon/Power --method org.freedesktop.DBus.Properties.Get org.gnome.SettingsDaemon.Power.Keyboard Brightness
  gdbus call --system --dest org.freedesktop.UPower --object-path /org/freedesktop/UPower/KbdBacklight --method org.freedesktop.UPower.KbdBacklight.GetBrightness
  # expect gsd percent ≈ raw/max*100; if they disagree you may see flicker
  # non-GNOME (Sway/KDE): org.gnome.ScreenSaver not available -> daemon falls back to org.freedesktop.ScreenSaver + system-sleep hook only
  # minimal image missing gdbus/dbus-monitor: sudo apt install dbus-x11 libglib2.0-bin
  # ectool fallback: ls -l /usr/local/bin/ectool && ectool pwmgetkblight
  # tristate: only ScreenSaver "inactive" permits a restore write (active/unknown defer)
  ```

  **Log verification:** the unit sets `StandardError=journal`, so these lines must
  be visible; absence means an old unit is installed or stderr is being redirected:

  ```bash
  journalctl --user -u c640-kbd-backlight-sync.service --since "5 min ago" \
    | grep -E 'backends probed|RECOVERED|saved brightness|replacing invalid saved brightness|restoring brightness|restore verify|not completed|adoption deferred|restore deferred|resume deferred|unblank: restore deferred|ignoring blank-side|brightness NOT saved|deferred save attempt|restore failed|another restore is in progress|\[WARN\]'
  ```

* **Common fixes**:
  * After install, **re-login** (for `plugdev` / `uaccess` ACL), or `systemctl --user start c640-kbd-backlight-sync.service`.
  * If service not enabled: `sudo systemctl --global enable c640-kbd-backlight-sync.service && systemctl --user daemon-reload`.
  * If `ScreenSaver available: no` on KDE/Sway, the `system-sleep` hook still publishes
    handoff files for lid close (`suspend`), but the thawed user daemon owns the restore,
    so keep it enabled; idle blank needs IdleMonitor: see `keyboard/README.md`
    `C640_KBD_ENABLE_IDLEMONITOR=1`.
  * For `brightness` permission denied: check `groups` includes `plugdev`, or `udevadm trigger --subsystem-match=leds`.
  * On Ubuntu 26.04 the LED attribute is only writable if the udev rule applied its
    `RUN+=chgrp plugdev` + `RUN+=chmod 0660` (verified: `-rw-rw---- root plugdev`).
    `MODE=`/`GROUP=`/`uaccess` alone cannot chmod sysfs, so if
    `ls -l /sys/class/leds/chromeos::kbd_backlight/brightness` shows `root root 0644`,
    run `sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=leds`;
    the daemon then stops falling back to `sudo -n tee`.
  * Root cause check: the user unit cannot prompt for sudo. `journalctl --user -u
    c640-kbd-backlight-sync` showing `sudo: a password is required` confirms the
    permission path above is the problem, not the D-Bus events.
  * Flicker/oscillation: check the read-only queries above. If gsd-power's
    `Brightness` percent and UPower's raw value disagree, the daemon logs
    `[WARN] gsd-power set ... forcing UPower + property refresh`; keep the
    deployed daemon/unit byte-identical to the repo (the smoke test asserts this)
    and avoid other tools writing the LED directly. If ScreenSaver is `true` or
    `unknown` during restore, deferral is expected — wait for the `+0.5s/+1.5s/+3s`
    retries or unlock the session. The hook no longer probes the session bus at all.
  * `resume deferred: ScreenSaver still active` / `... unknown ... deferring restore`
    means the tristate guard is doing its job; keep the state and wait for unlock.
    `C640_KBD_RESUME_ALLOW_UNKNOWN=1` is an explicit **risk acceptance** (may light the
    keyboard under a still-locked screen) and is off by default;
    `C640_KBD_RESUME_PROBE_MAX` caps the post-thaw poll (default 10s).
  * `bash keyboard/tests/loginctl-contract-check.sh` is a **read-only** check of the exact
    `loginctl` schema the hook relies on: with the real `loginctl` it confirms
    `Session.User` is a numeric `User=<uid>` (never a session `UID=` key) and that
    `show-seat ActiveSession` values are alphanumeric session IDs. It prints
    `CONTRACT OK` on a running systemd host and an explicit `SKIP` on a non-systemd
    host (`SKIP` is **not** a pass). It performs **no S3 cycle and no handoff write**,
    so `CONTRACT OK` does **not** mean real S3 has been verified for this HEAD — run the
    target-machine checklist in [verification.md §3](verification.md) before claiming that.
    If it fails, check the `show-session` output for a missing `User` property or a
    decimal-only session-ID assumption in an older hook.
  * `handoff skipped (fail-closed): unsafe destination entry <path>` or
    `... destination entry changed during write` means the final handoff component is a
    symlink, directory or special entry (or changed while the temp file was being
    written). `cannot publish <path>` means the single `mv -T -f --` publish failed; the
    temp file is removed and **no `cp`/plain-`mv` fallback** is attempted, so a hostile
    entry is never dereferenced. Fix the runtime dir entry (remove the symlink/dir) and
    retry the suspend cycle; check the root journal for the exact path.
  * `ignoring blank-side suspend handoff 0; keeping saved user brightness N` means the
    suspend started while the screen was blank: the hook's hardware 0 was correctly
    ignored so unlocking restores the user's brightness N (verified in a real S3 cycle —
    see [verification.md §3](verification.md)).
  * `restore failed (... rc=1): keeping brightness N for retry` or `another restore is
    in progress` means the staged value in `c640-kbd-backlight.restore-pending` is kept
    for a later retry; a crash is recovered at daemon startup. `RECOVERED (0 -> 1)` means
    a previously missing gsd-power/UPower D-Bus name came back and the daemon switched
    back to the gsd single writer after re-probing.
  * `blank: brightness NOT saved (rc=...)` / `blank: deferred save attempt N failed
    (rc=...)` means the blank-side save could not persist the new brightness. The daemon
    keeps the LED **on** (rather than going dark with nothing to restore) and leaves the
    captured value in the last-user cache. Check `C640_KBD_SAVE_LOCK_WAIT` (default 2s):
    a slow restore can hold `STATE_LOCK` until `save_state` times out. `save_state` rc is
    `0` = saved, `1` = lock wait failed, `2` = value selection/write failed. The blank
    samples brightness **once** and the first `save_state "$captured"` uses that value
    directly (no second sample that could see a blank-side `0` and save a stale cache
    value); only an empty capture lets `save_state` sample on its own.
  * `replacing invalid saved brightness with N` means the state file held an empty,
    non-numeric, multi-line or binary value. First-wins protects only a **valid** saved
    integer: under `STATE_LOCK` the bad file was atomically replaced with the brightness
    captured before blanking. A genuine write failure still returns rc `2` and keeps the
    LED on; nothing here changes the rc or retry contract above.
  * The resume path uses result codes `0 = RC_DONE` (write verified; `STATE` /
    `restore-pending` consumed), `1 = RC_FAIL` (bad input / I/O error) and `2 = RC_DEFER`
    (lock contention, a staged restore in flight or ScreenSaver active/unknown). Only
    `RC_DONE` consumes the resume flag and handoff files. `RC_DEFER` keeps flag/handoff/
    state and schedules retries for the sampler or next unblank; `RC_FAIL` keeps the
    resume flag, but the saved state may already have been consumed (only the captured
    value remains in the last-user cache); a write/finalize FAIL still re-arms the
    +0.5/+1.5/+3s retries when a state file remains, whereas a verify or adoption FAIL
    schedules none.
    `restore verify (gen=...): ... not completed`,
    `suspend handoff adoption deferred` and `unblank: restore deferred` are retry
    signals, not failures — wait for the next poll or unlock the session.
  * `MANIFEST_INVALID ... original bytes left untouched` comes from the **installer**,
    not the daemon: `/var/lib/cros-enablement/install-manifest.json` is corrupt, so the
    backup/writer paths fail closed and leave the file byte-for-byte unchanged. A wrong
    **field type** is now also an invalid-manifest reason, not only malformed JSON: a
    record `target` must be an absolute path string without NUL, `component`/
    `installed_at`/`version`/`scope` must be strings when present, and the safety fields
    `was_existing`/`was_enabled`/`was_active`/`was_member` are **required booleans** (a
    missing one means unknown, never `false`; the string `"false"` and number `1` are
    rejected, not coerced). Service `name`/`component` and group `group`/`user`/
    `component` are required; other optional fields may be absent (legacy v1) and unknown
    keys ignored. `groups[*].added_by_project` is an **optional** per-install boolean
    (absent = legacy `false`, "no extra evidence"); a present field of the wrong type is
    also `MANIFEST_INVALID` and fails closed — it is never read as permission evidence.
    Repair or deliberately remove it before reinstalling; never treat an invalid manifest
    as an empty one.
  * `skipping manifest entry with non-absolute target` means the installer skipped a
    pseudo-target (such as the fingerprint `package:libfprint-crfpmoc`) that cannot be a
    record `target`; it is not an error.
    `rollback of <component> failed; service/file state may be partial (retained records
    remain for retry)` means the restore script failed mid-run (services are restored
    before files) and rollback returned rc 1 — the retained records let a later run retry.
    Rollback, uninstall and group-membership removal all validate the manifest **before**
    any `systemctl disable keyd` / `gpasswd -d` / file side effect and fail closed on an
    invalid one.
  * `RECORD_STATE_UNKNOWN` / `SERVICE_STATE_UNKNOWN` means an original-state snapshot is
    missing or not a boolean. Rollback treats it as **unknown, never false**: that file is
    not deleted/restored, that service is not enabled/disabled/started/stopped, and the
    record is kept with rc 1. No keyd disable either — `_keyd_managed_by_us()` needs a
    valid bool service snapshot before it will disable/stop keyd.
  * `[WARN NO BACKUP]` means a `was_existing` target has no first backup available; the
    record is kept (no fake file is created) so a later retry can restore it. Since the
    ninth re-review this is a real failure: `RECORD_BACKUP_MISSING` is recorded as a
    problem and `ROLLBACK_INCOMPLETE: N item(s) retained` is printed, so rollback exits
    rc 1 (no `finished!`) while other processable items still roll back normally. The
    RC/retry contract is unchanged — re-run uninstall once a backup is available.
    `[RESTORED PREVIOUS BACKUP] <backup> -> <target>` means the original was rebuilt from
    the oldest matching backup even though the installed file was already absent.
    `RECORD_RESTORE_FAILED` / `RECORD_REMOVE_FAILED` means the file operation failed; the
    record is kept for retry. A failed restore swap never unlinks the installed target
    first (regular files/symlinks use a single atomic `os.replace()`).
  * `SERVICE_RESTORE_FAILED` / `ROLLBACK_INCOMPLETE` means at least one `systemctl`
    enable/disable/start/stop returned non-zero (or timed out / failed to spawn), or a
    record such as a missing backup was retained; those records are kept for retry and
    rollback returns rc 1. Re-run uninstall after fixing the underlying issue —
    successful restores log `[RESTORED SERVICE]`. Whenever any record is retained, each
    top-level uninstaller prints `Uninstall incomplete; retained state will be retried (see
    FAIL/WARN lines above).` and exits non-zero instead of printing `finished!`.
  * `Manifest lock wait failed (rc=... after ...s) ... (holder: ...)` or `flock not found`
    comes from the cross-process lock. Since the tenth re-review this is an OPERATION-level
    lock: `run_manifest_operation()` holds it for the whole component install/uninstall
    (backup/record → deploy files/services → finish/rollback), so a parallel run cannot consume
    a just-written record while its target is absent and leave an untracked deployed file. The
    wait is bounded by `CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT` (default 10s) on the root-owned
    `0600` file `$MANIFEST_DIR/.install-manifest.lock` (fd 9, held by a short-lived `coproc
    sudo bash -c` root helper); a timeout, a missing `flock` or any validation failure fails
    closed and leaves the manifest bytes intact (rc non-zero). `flock not found` means
    `util-linux` is not installed. Each writer uses a unique `.install-manifest.*.tmp` file
    (fsync + `chmod 0644` + `os.replace`), so parallel runs cannot drop each other's first-wins
    records. Retry after the other run finishes; raise the timeout (e.g. `300`) if a
    `fingerprint/install-fingerprint.sh --source` build is still holding the lock.
  * `Manifest directory ... must be an absolute path; refusing to lock` means
    `CROS_ENABLEMENT_MANIFEST_DIR` was relative. Set an absolute path (normally
    `/var/lib/cros-enablement`); the lock trust boundary cannot be evaluated against an
    ambiguous CWD. `Manifest lock directory ... contains a symlink (...); untrusted symlink;
    refusing to lock` means a literal symlink component was found on the path. Since the
    twelfth re-review **every** literal symlink component is refused, even a root-owned,
    otherwise safe one: a symlink can hide the real target in a user-writable tree whose
    owner could rename the lock. Replace the symlink with a real directory (fail-closed by
    design; this is stricter than the old "trusted symlink" allowance).
    `Manifest lock canonical path ... has an untrusted realpath ancestor; refusing to lock`
    (`untrusted realpath ancestor`) means the **real** path — the deepest existing prefix
    resolved with `realpath -e` plus the missing layers — has an ancestor that is not
    root-controlled. Fix the ownership/mode of that real ancestor; do not route around it
    with another symlink.
  * `... (holder: FAILED:symlink)`, `FAILED:type`, `FAILED:open`, `FAILED:inode`,
    `FAILED:canonical`, `FAILED:ancestor`, `FAILED:parentdir` or `FAILED:flock` is the root
    helper's reason for refusing the lock.
    `FAILED:symlink` / `FAILED:type` / `FAILED:inode` mean the lock path was a symlink, a
    non-regular file (e.g. a directory or FIFO) or was swapped between init and open: the
    helper compares fd 9 with the path's `(dev,ino)` via `/proc/$$/fd/9` plus owner `0`, mode
    `600` and regular-file type INSIDE the process that actually holds fd 9, so an unprivileged
    inode swap cannot redirect the flock. `FAILED:flock` is ordinary contention. The same
    checks log `Manifest lock path ... is a symlink` / `is not a regular file` / `is not a
    root-owned 0600 regular file (uid=... mode=...)` when they fail before the helper starts.
    **`FAILED:canonical`** means the holder re-derived `realpath -e "$dir"` inside the
    process that owns fd 9 and it no longer equals the canonical directory handed over by
    the gate — a symlink was swapped in after the gate ran. **`FAILED:ancestor`** means a
    **real** ancestor above the direct parent was not uid `0`, or was group/other-writable
    without being a root-owned sticky world-writable layer (e.g. `/tmp` `1777`). Both abort
    before any `flock` is taken and leave the manifest bytes intact; fix the path and retry.
  * `FAILED:parentdir` means the fd-8 pin of the lock's **direct parent** failed inside the
    root holder: the parent was not root-owned, was group/other-writable, was not a directory,
    or its `(dev,ino)` no longer matched the pathname. This closes the rename race where A
    holds a live lock, its parent owner renames the path away and B locks a brand-new inode.
    Re-check the directory ownership/mode and retry; the manifest bytes are left intact.
  * `Manifest lock parent ... is group/other-writable (mode ...)`, `is owned by uid ... (must be
    root-owned)`, `is a symlink or not a directory` or `Cannot stat manifest lock parent ...`
    means the direct parent is not trusted, so no privileged chmod/chown/open is attempted.
    Keep `/var/lib/cros-enablement` **root-owned** at mode `0755`; ownership by the current
    EUID/UID is no longer accepted (a caller-owned parent can rename a live lock), a `0775`
    group-writable directory fails closed, and a sticky bit does not exempt the direct parent.
    Every ancestor is checked too: `Manifest lock ancestor ... is not root-controlled
    (uid=... mode=...)` rejects a non-root-owned or g/o-writable layer **without** a sticky bit
    (a root-owned sticky world-writable layer such as `/tmp` `1777` is allowed), and
    `Manifest lock ancestor ... is an untrusted symlink` rejects a symlink unless the directory
    holding it is root-owned and not g/o-writable. Separately, the literal path check now
    rejects **any** symlink component (`contains a symlink`) before canonicalization, and the
    canonical path's ancestors are checked as well (`untrusted realpath ancestor`). A custom
    lock parent under a user-writable tree is therefore refused even when the lock file itself
    would be root-owned.
  * `Could not set manifest lock mode to 0600` / `Could not set manifest lock owner to root`
    means the lock could not be made root-owned `0600` (an older `0644` lock is upgraded
    automatically), so the installer fails closed. A plain `permission denied` when a peer
    account tries to open `$MANIFEST_DIR/.install-manifest.lock` directly is expected and is
    the DoS protection: only the short-lived root holder (via passwordless `sudo`) opens fd 9.
    Do not chmod/chown the lock by hand as an unprivileged user — fix the `sudo` helper or the
    parent directory mode and retry.
  * Group membership is now recorded **before** `usermod` runs: the installer persists the
    original `plugdev` membership, checks `usermod` rc explicitly (no `|| true`) and, if
    the change fails with no earlier record, removes the record it just wrote. The shared
    ownership probe returns rc 0 when some record is explicitly `was_member=false` **or a
    record carries `added_by_project=true`** (both prove we added it), rc 1 for **no record**
    (`No group record for '<user>'@'<group>'; nothing to roll back.`), rc 3 when **all**
    records are `was_member=true` and none carries the flag (pre-existing), rc 2 for a bad
    field type (`Cannot determine original membership of <user>@<group>; refusing to change
    it`, rc 1). first-wins is unchanged: rc 0 runs `gpasswd -d`, and a udev rule that still
    references the group keeps the membership. On **rc 3** no `gpasswd` ever runs: if a udev
    rule still references the group it logs `udev rules still reference group '<group>';
    keeping '<user>' in it (all records pre-existing).` and keeps the snapshot; once no rule
    references it (all components using the group have gone) it logs `All records
    pre-existing and no udev rule needs '<group>'; consuming stale records for
    '<user>'@'<group>' (membership unchanged).` and consumes **all** records with **zero**
    `gpasswd` calls, so the next install re-snapshots the real membership (e.g. after an
    admin changed it). A consume failure logs `Could not consume stale group records for
    '<user>'@'<group>'; keeping them for retry.` (rc 1). With rc 0, uninstall consumes all
    component records only after `gpasswd -d` succeeds (`manifest_remove_group_all`), so the
    module uninstall order cannot leave a stale `was_member` record behind. On a reinstall
    where the original `was_member=true` but the user is currently **not** a member (an admin
    removed it while the component stayed installed), the writer records
    `added_by_project=true` beside the untouched first-wins snapshot; the probe then returns
    rc 0 so uninstall removes the membership granted in this generation. If `usermod -aG`
    fails, `manifest_clear_group_added` clears **only** that flag
    (`Could not clear added-by-project evidence for <user>@<group>; kept for manual cleanup`
    means that clear itself failed); consume-all removes the whole row, flag included.
  * `Could not remove '<user>' from group '<group>'; keeping manifest records for retry.`
    means `gpasswd -d` failed. This is now a **real failure** (log_error, rc 1) — the three
    component uninstallers capture it and fold it into their exit code, so a full
    `./setup.sh --uninstall` no longer reports success while the membership remains.
    Fix the group/permission problem and re-run uninstall; the records are kept for retry.
    `Could not consume group records for '<user>'@'<group>'; keeping them for retry.` has
    the same rc-1/retry meaning when the manifest write after a successful removal fails.
  * `Manifest still records /etc/pam.d/sudo: rollback did not restore it. Uninstall did NOT
    modify this file; remove the project line manually if needed.` is the read-only
    post-rollback PAM check: uninstall never sed-edits sudo PAM (all file restoration comes
    from `rollback_component("fingerprint")`), so a pre-existing exact `pam_fprintd` line is
    not deleted. If the manifest is corrupt it instead warns `Manifest at ... is corrupt/invalid;
    cannot confirm rollback of /etc/pam.d/sudo. Uninstall did NOT modify this file.`
    — either way it only warns. On Debian/Ubuntu the original `common-*` bytes are backed up
    (**all** existing ones, not just fp-containing ones) and restored by rollback. Install
    removes fp lines with a **direct** `sed -i '/pam_fprintd\.so/d'` (log `Removed
    pam_fprintd.so line(s) from ...`), **never** `pam-auth-update --remove fprintd` — that
    action deletes debconf's `libpam-runtime/profiles` selection outright. Since a later
    `pam-auth-update --package` derives the profile list from the current `common-*` content
    and would otherwise lose fprintd permanently, install snapshots the selection and
    `/var/lib/pam/*` into a first-wins sidecar and runs `pam-auth-update --package` itself to
    converge to a stable "no fprintd" state (a package-triggered rerun is then a no-op).
    Uninstall restores from that snapshot only after rollback is complete. Fedora `authselect`
    and openSUSE `pam-config` profile state is outside the manifest, so restore any
    pre-existing profile manually as the warning says.
  * `Snapshotted the PAM profile selection to <path>` / `Keeping the existing PAM selection
    snapshot at <path> (first-wins).` are the install-time sidecar logs. The sidecar
    (`<manifest-dir>/pam-selection`) stores the original debconf `libpam-runtime/profiles`
    multiselect (mode `0644`); `<manifest-dir>/pam-selection.saved` is a root-owned `0700`
    directory holding copies of every file under `/var/lib/pam`. Both are published once,
    first-wins, and all reads/copies go through `sudo` so a non-root uninstall with
    passwordless `sudo` can restore them; `Could not read debconf
    libpam-runtime/profiles; ... will be empty.`, `Could not write the PAM selection snapshot;
    ...` and `Could not snapshot every saved PAM profile file; ...` mean the snapshot is
    incomplete — uninstall then cannot fully restore the original state, so check those
    files by hand. `pam-auth-update --package converged the debconf selection and saved
    profiles (no fprintd).` is the expected self-convergence log; `pam-auth-update --package
    failed; keeping the selection snapshot for uninstall convergence.` keeps the sidecar.
  * `Legacy PAM sidecar without any optional metadata; using best-effort compatibility.`
    means the sidecar was written by an older installer without the `saved-snapshot` metadata:
    restore falls back to inspecting the `.saved` directory (empty ⇒ absent, unreadable ⇒ fail
    closed) instead of assuming a complete snapshot. The related `Legacy PAM sidecar has an
    empty ...; inferring saved-snapshot=absent`, `... has no saved metadata; inferring
    saved-snapshot=complete from ...` and `... has no saved metadata and no ...; inferring
    saved-snapshot=absent (best-effort).` messages are the same compatibility path. A
    contradictory saved-snapshot state in a **current** sidecar still fails closed.
  * `No PAM selection snapshot at <path>; nothing to restore.` means no fprintd-capable
    install left a sidecar, so there is nothing to converge back. `Original PAM profile
    selection restored; snapshot consumed.` is the success path: after rollback is confirmed
    complete, the `.saved` files are copied back, the multiselect is written with
    `debconf-set-selections`, `--package` runs again and the live selection is verified.
    `Manifest still records <path>: rollback is incomplete, leaving the PAM selection
    snapshot for retry.` or `Manifest at ... is corrupt/invalid; leaving the PAM selection
    snapshot for retry.` means debconf was deliberately **not** touched; finish rollback
    (or repair the manifest) and re-run uninstall.
  * `debconf-set-selections is unavailable; keeping <path> for retry.` and
    `debconf-set-selections failed; keeping <path> for retry.` mean the selection could not
    be written — the sidecar and `.saved` snapshot stay for a later uninstall; install
    `debconf` (or fix the `sudo` helper) and retry. `The PAM selection snapshot is empty;
    cannot restore the debconf selection.` means only the `.saved` files were restored.
    `Could not restore every saved PAM profile file from the snapshot.` means some
    `/var/lib/pam` files may still be in the converged no-fprintd state; reinstall them or
    restore by hand.
  * `PAM selection restore verification failed: expected '<a>', got '<b>'. Keeping <path> for
    retry.` is a fail-closed mismatch (rc 1, sidecar retained). The comparison accepts an
    exact match **or** a whitespace/order-insensitive set: `pam-auth-update` canonicalizes
    the multiselect to "a, b, c", so a different order or spacing in your original value is
    fine, but a different **set** of profiles is not (an admin's later deliberate change is
    not silently accepted). Trade-off: because the snapshot is authoritative, a selection
    change made during installation is overwritten on uninstall; manually enabling the
    fprintd profile during install (`pam-auth-update --enable fprintd`) writes fp back into
    `common-auth` and restores the GDM race until uninstall.
  * `External content change detected in ... since the snapshot (added/removed/reordered
    MODULE line); refusing to overwrite it - manual recovery required.` means an admin or a
    tool made a semantic change to a `common-*` file; uninstall returns rc 1 and retains all
    three snapshot halves. `PAM external tool calls complete; re-applying the original
    common/sudo state.` is the expected ordering log — every tool call finishes **before**
    the `.common` restore, and the final bytes/mode/owner/type/link/absence + savedir +
    selection/seen verification runs before consumption. A legacy sidecar without `.common`
    logs `Legacy PAM snapshot has no ... (best effort only)` / `No PAM common-state snapshot (...) ... (legacy best
    effort)` and claims no byte guarantee; `saved-snapshot=absent` plus a populated live
    savedir fails closed with `manual recovery required`. A consumed manifest record and an
    equal selection alone are not success. If the last `.common` half cannot be removed
    after the other two are gone, the sidecar is rebuilt but the state is **not retryable**
    (`manual recovery is REQUIRED`); the retained files must be cleaned up by hand.
  * `Symlinked /etc/pam.d/common-* contains an active pam_fprintd.so module line;
    refusing to install because it cannot be stripped without replacing the link (the GDM
    claim race would remain).` is the **install-time** fail-closed preflight: before any
    snapshot, backup, `sed`, tool call or sudo change, each `common-*` is probed through
    `sudo`; an active fp module behind a symlink cannot be removed without replacing the
    link, so install exits non-zero and leaves **PAM files and the debconf selection
    untouched**. Unreadable targets/grep errors fail closed too; absent or dangling
    targets carry no active module. Replace the symlink with a regular file (or remove
    the fp line under its real target deliberately), then re-run the installer. After a
    successful install the postcondition checks the **actual** `common-*` bytes for no
    active fprintd — a disabled record left in the debconf selection is not sufficient.
  * `Uncertain PAM rule syntax in ...; refusing to modify PAM configuration` or
    `numeric jump target identity changes after removing fingerprint module` means the
    17th-re-review PAM rule parser could not prove a custom stack is safe to edit. Install
    exits non-zero **before any PAM edit**, with the original bytes and debconf selection
    untouched. Trailing comments that merely mention `pam_fprintd.so` are no longer treated
    as active modules, but uncertain syntax, a custom jump control or a changed jump landing
    is not guessed at: fix the custom stack by hand and re-run the installer. A later
    `pam-auth-update` failure is reported honestly (`convergence NOT verified yet`) and does
    not claim the jump endpoints were re-proved.

---

## 🔋 Power & Suspend

### 12. Closing the lid overnight drains too much battery (over 5-8%)

* **Root cause**: Intel AX201 Wi-Fi background wake (WoWLAN) or PCIe ASPM power
  saving is not fully enabled, so the SoC can't reach the low-power Package C10
  (SLP_S0#) state.
* **Solution**:
  1. Disable Wi-Fi wake on sleep:

     ```bash
     sudo iw phy phy0 wowlan disable
     ```

  2. Add `pcie_aspm=force` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then run `sudo update-grub`.
  3. Install `tlp` or `power-profiles-daemon` to manage power saving states.

### 13. Laptop doesn't suspend when the lid is closed

* **Solution**: make sure `/etc/systemd/logind.conf.d/99-hp-c640-lid.conf`
  (installed by `./power/install-power.sh`) or `/etc/systemd/logind.conf`
  contains:

  ```ini
  [Login]
  HandleLidSwitch=suspend
  HandleLidSwitchExternalPower=suspend
  ```

* **⚠️ After changing logind config, REBOOT — do NOT `systemctl restart
  systemd-logind`**:
  restarting `systemd-logind` while a desktop session is active **logs out
  every logged-in user** (the session leader is lost during deserialization,
  which tears down the whole GNOME session, kills the user manager and can
  even look like a system freeze). The new setting only takes effect at the
  next login/boot anyway, so a reboot (or logging out and back in) is the
  correct — and only safe — way to apply it.

  ```bash
  # DON'T do this:
  sudo systemctl restart systemd-logind

  # DO this instead — reboot and the lid rule is live:
  sudo systemctl reboot
  ```

  *(Verified 2026-08-18: restarting systemd-logind caused a full session
  logout storm that appeared as a system crash on an HP Pro c640.)*

### 14. No fingerprint prompt on the lock screen after suspend/resume (or instantly after locking)

* **Symptoms**: after lid-close suspend and reopen (or locking and interacting
  immediately), the unlock dialog shows **no fingerprint hint and touching the
  sensor does nothing**. Pressing `Esc` and re-entering the login screen makes
  fingerprint work.
* **Root cause**: a device-claim race between two PAM workers. On unlock, GDM
  forks the `gdm-password` worker and the `gdm-fingerprint` worker
  concurrently. Both PAM stacks used to contain `pam_fprintd`:
  `gdm-password` pulls it from `common-auth` (if the fprintd profile is
  enabled via `pam-auth-update`), `gdm-fingerprint` has
  `auth required pam_fprintd.so`. fprintd allows **only one Claim** per
  device; the password worker is forked first and wins, the fingerprint
  worker gets `Authorization denied ... Device was already claimed`, the
  whole fingerprint service fails, and GNOME Shell hides the fingerprint
  prompt. Suspended sessions make it deterministic because reauth starts
  ~400 ms after wake.
* **Evidence**:

  ```text
  fprintd: Authorization denied to :1.142 to call method 'Claim' for device
  'ChromeOS Fingerprint Match-on-Chip': Device was already claimed
  ```

  Upstream tracking: GNOME/gdm#1071, libfprint/fprintd#214,
  GNOME/gnome-shell#7791 (all open as of 2026-08).
* **Solution (installed by this project's installer since 2026-08-18)**:
  keep `pam_fprintd` **out of `common-auth`** and enable fingerprint **only
  for sudo** (`auth sufficient pam_fprintd.so` in `/etc/pam.d/sudo`). The
  GDM login screen and lock screen keep working via the dedicated
  `gdm-fingerprint` PAM service, which now always wins the claim.

  ```bash
  # what the installer does on Debian/Ubuntu:
  # back up the original common-* bytes first (Tier 2), then remove ONLY fp module lines.
  # Do NOT use `pam-auth-update --remove fprintd`: it silently deletes the debconf profile
  # selection, which the manifest cannot restore.
  sudo sed -i '/pam_fprintd\.so/d' /etc/pam.d/common-auth
  sudo sed -i '/^@include common-auth$/i auth sufficient pam_fprintd.so max-tries=1 timeout=10' /etc/pam.d/sudo
  ```

  > [!WARNING]
  > These `sed` commands are **legacy manual examples** from before the PAM-aware parser
  > (17th re-review). A substring match deletes **any** line containing `pam_fprintd.so`,
  > including an unrelated auth rule whose trailing `#` comment merely mentions it (e.g.
  > `auth required pam_unix.so nullok # fallback when pam_fprintd.so unavailable`). On a
  > custom stack prefer re-running the installer: it parses the **module-path field**,
  > preserves non-fp bytes, and fails closed on uncertain syntax or changed jump landings
  > (`Uncertain PAM rule syntax ...`, `numeric jump target identity changes ...`). If you
  > must edit by hand, check the module-path field and verify the non-fp bytes afterwards.

  *(This also removes the previous race window for `sudo` — see section 8
  for the single-stack rule.)* If a `common-*` file is a **symlink** whose target
  has an active `pam_fprintd.so` line, `sed -i` would replace the link rather than
  strip the module, so the installer fails closed before touching PAM or the
  debconf selection (`Symlinked ... contains an active pam_fprintd.so module line;
  refusing to install ...` in the root journal). Fix the symlink first, then re-run
  the installer; the installed-state postcondition verifies the real `common-*`
  bytes, not merely the selection.
* **Manual recovery (if you are on an older install)**: press `Esc` to cancel
  the failed unlock round, then unlock again — the fresh workers re-claim
  cleanly. Or run `sudo systemctl restart fprintd` before unlocking.
* **Residual issue after the PAM fix (FPMCU open fails right after resume)**:
  even with the claim race gone, the *first* unlock attempt after resume can
  still fail: the claim succeeds but the crfpmoc **device open fails
  instantly** (the EC/FPMCU channel is not ready in the first ~2 s after S3
  wake), `pam_fprintd` errors and the shell shows no fingerprint prompt (no
  `already claimed` line is logged in this case — confirmed with
  `G_MESSAGES_DEBUG=fprintd`, 2026-08-19: `claiming the device: 0` without
  `claimed device 0`). Two complementary fixes ship with this project:
  1. **Driver-level open retry (the real fix, since 2026-08-19)**: the
     audited `crfpmoc` driver retries the open SSM with a bounded budget
     (`CRFPMOC_OPEN_MAX_RETRIES` × 500 ms) when the EC channel reports I/O or
     EC errors right after wake. A healthy open completes on the first
     attempt with **zero added latency**; only a failed open waits.
  2. **System-sleep hook hygiene**: `fingerprint/systemd/fprintd-sleep.sh`
     stops fprintd before sleep so resume always gets a fresh daemon.

  Verify after a lid cycle:

  ```bash
  journalctl -b -e -u fprintd | grep -E "claim|open|retry"
  # expect: "claimed device 0" on the FIRST post-resume claim
  #         (plus "retrying" lines only if the EC channel needed a moment)
  ```

  *(If it still fails, temporarily install
  `Environment=G_MESSAGES_DEBUG=fprintd` in a fprintd.service drop-in and
  repeat the lid cycle to capture the driver error.)*

### 15. Screen stays dark after lid-open resume (until a key/click)

* **Symptoms**: after lid close (S3 `deep`) and reopen, the system resumes
  (`PM: suspend exit`) but the panel stays **dark** until a key press or
  click. Not a hang — the lock screen works once any input arrives.

  > [!NOTE]
  > A dark **keyboard** backlight right after lid-open is also expected: the thawed
  > daemon defers the restore until ScreenSaver is explicitly `inactive`
  > (`resume deferred: ScreenSaver still active`). Unlock the session and it restores
  > (e.g. `restoring brightness 30`). This is the fail-closed tristate guard described
  > in §11, not the display-panel issue above.

* **Root cause (two candidate mechanisms, 2026-08-18)**:
  1. **GNOME userspace re-blank** (most likely, matches the keypress-cure
     signature): `gsd-power` blanks the panel on suspend; the screen-shield
     lock animation stalls while the display is off, and when it completes
     after resume the power plugin turns the monitor **back off**
     (GNOME/mutter#4111, fix candidate gnome-shell!3742 — unmerged).
  2. **i915 PSR resume bug** on Comet Lake (gitlab.freedesktop.org/drm/i915),
     and/or kernel 7.0 eDP backlight regressions (drm/i915/kernel#16791,
     #16825). Less likely because those are not cured by a keypress.
* **Solution (this project)**: the `power/install-power.sh` modprobe quirk
  `options i915 enable_psr=0 enable_fbc=1 enable_guc=2` is the repo's
  candidate remedy for suspend/resume black screens. It was installed and
  the device rebooted on 2026-08-19, but **it did not resolve the dark
  panel** on this unit (still dark until keypress — user accepted the
  behavior; see [VERIFICATION.md](verification.md)). Apply it and reboot if
  you want to try it:

  ```bash
  ./power/install-power.sh   # or manually:
  sudo install -D -m 0644 power/modprobe.d/99-hp-c640-power.conf \
      /etc/modprobe.d/99-hp-c640-power.conf
  sudo update-initramfs -u
  sudo systemctl reboot
  ```

  > [!NOTE]
  > On kernel ≥ 7.0 the installer automatically strips the removed
  > `iwlwifi d0i3_disable` parameter (see the file's comment header).
* **If the panel is still dark** after a lid cycle with `enable_psr=0`:
  test `MUTTER_DEBUG_FORCE_KMS_MODE=simple` in `/etc/environment` (isolates
  the atomic-KMS resume path, see drm/i915/kernel#16825), or watch
  `busctl monitor` on `org.gnome.SettingsDaemon.Power` for a
  turn-off-after-resume event (confirms the userspace re-blank hypothesis).
  Report findings against GNOME/mutter#4111.

### 16. Battery charges past 90% or `ERROR: Old EC doesn't support sustainer`

* **Symptoms**: attempting to configure `ectool chargecontrol normal 80 90` outputs
  `ERROR: Old EC doesn't support sustainer`, or the battery charges past the target limit
  after a reboot or S3 sleep.
* **Root cause**:
  1. HP Pro c640 (Dratini) runs ChromeOS EC v1 firmware (`dratini_v2.0.2851`). EC v1 only supports
     state commands (`normal`, `idle`, `discharge`), not firmware-autonomous percentage windows.
  2. During S3 sleep or boot, simple polling daemons without sleep hooks leave a brief window where
     the EC reverts to `normal` charging.
* **Solution**:
  1. Use the project's enhanced `c640-battery-limit.service` and `c640-ec-sleep.sh`:

     ```bash
     ./ec/install-ec.sh --enable-battery-limit
     ```

  2. The service uses an active daemon (`battery-daemon 90`) with immediate `sysinit.target` early
     boot startup and a `systemd-sleep` resume hook to enforce 0 mA AC bypass (`idle` / `inhibit-charge`)
     without relying on the unsupported firmware sustainer.
  3. Verify with `c640-ec-control status` or `ectool battery` (Present current should be `0 mA`).
