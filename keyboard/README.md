[English](README.md) | [繁體中文](README.zh-TW.md)

# Keyboard Top-Row Mapping (HP Pro c640 Chromebook)

Many ChromeOS devices feature dedicated top-row action keys instead of
traditional F1-F12 keys (this Dratini instead sends plain AT `F1`-`F10`). Under
standard Linux, these keys can be remapped either at the
kernel/hardware level using `systemd-hwdb` or at the input daemon level using
`keyd`.

---

## 🎹 Top-Row Key Mapping Reference

| Physical Position | ChromeOS Icon | Raw Scancode / hwdb Property | Linux hwdb Keycode | Recommended Function |
| :--- | :--- | :--- | :--- | :--- |
| **Top 1 (F1)** | ◀ (Back) | `0x3b` / `KEYBOARD_KEY_3b` | `KEY_BACK` | Browser / App Back |
| **Top 2 (F2)** | ▶ (Forward) | `0x3c` / `KEYBOARD_KEY_3c` | `KEY_FORWARD` | Browser / App Forward |
| **Top 3 (F3)** | ⟳ (Refresh) | `0x3d` / `KEYBOARD_KEY_3d` | `KEY_REFRESH` | Page Reload |
| **Top 4 (F4)** | ⛶ (Fullscreen) | `0x3e` / `KEYBOARD_KEY_3e` | `KEY_F11` | Toggle Fullscreen |
| **Top 5 (F5)** | ⧉ (Overview) | `0x3f` / `KEYBOARD_KEY_3f` | `KEY_SCALE` | GNOME / Desktop Task Switcher |
| **Top 6 (F6)** | 🔅 (Brightness Down) | `0x40` / `KEYBOARD_KEY_40` | `KEY_BRIGHTNESSDOWN` | Decrease Display Backlight |
| **Top 7 (F7)** | 🔆 (Brightness Up) | `0x41` / `KEYBOARD_KEY_41` | `KEY_BRIGHTNESSUP` | Increase Display Backlight |
| **Top 8 (F8)** | 🔇 (Mute) | `0x42` / `KEYBOARD_KEY_42` | `KEY_MUTE` | Audio Mute |
| **Top 9 (F9)** | 🔉 (Volume Down) | `0x43` / `KEYBOARD_KEY_43` | `KEY_VOLUMEDOWN` | Decrease Audio Volume |
| **Top 10 (F10)** | 🔊 (Volume Up) | `0x44` / `KEYBOARD_KEY_44` | `KEY_VOLUMEUP` | Increase Audio Volume |
| **Search / Launcher** | 🔍 (Search) | `0xdb` / `KEYBOARD_KEY_db` | `KEY_LEFTMETA` | Super (Meta) or CapsLock |

> **Scancodes inferred on real Dratini hardware (2026-10-31).** The `0x3b`-`0x44`
> (`KEY_F1`-`KEY_F10`) values were inferred from post-hwdb `EVIOCGKEY` key state
> against the standard AT scancode table, and `EVIOCGKEYCODE` confirmed the
> kernel map — **not** ChromeOS action scancodes (`0xea`, `0xe9`, `0xe7`, ...)
> that some other Chromebooks use. No raw `MSC_SCAN` capture is present in this
> evidence: confirming it still requires `check-top-row-hwdb.py --scan` after
> stopping keyd (or plain `evtest` without `--grab`). hwdb must map
> `0x3b`-`0x44`; mapping the action scancodes has no effect on this machine. The
> inferred table lives in `keyboard/tests/hwdb-top-row-scancodes.tsv` and is
> asserted in CI.
>
> **Other Chromebooks / other Hatch boards:** this mapping applies **only** to
> the Dratini / HP Pro c640 DMI entries explicitly listed in
> `keyboard/90-chromebook-keyboard.hwdb`; it does **not** match other Hatch
> boards (on real Dratini, "Hatch" is the product family, not the product name,
> so no `pn*Hatch*` wildcard is used). Other models emit their own scancodes and
> need their own hwdb entry. Before relying on this table, stop keyd
> (`sudo systemctl stop keyd`) and read `EV_MSC/MSC_SCAN` with
> `check-top-row-hwdb.py --scan 60` or plain `evtest` (no `--grab`), then infer
> the scancode against the standard AT table and create your own hwdb entry.
> On an unknown model or when `EVIOCGKEYCODE` is unsupported, use
> `check-top-row-hwdb.py --scan-only 60`: it skips the table check entirely, so
> a Dratini fixture mismatch cannot block raw capture. **After capturing, run
> `sudo systemctl start keyd` to restore the service** —
> otherwise Search tap/hold and brightness remapping stay disabled. `--listen`
> only shows the post-hwdb `KEY_*` events, not raw scancodes.

---

## 🛠️ Implementation Options

### Option 1: systemd-hwdb (Recommended & Default)

Zero daemon overhead, low latency, native kernel input mapping.

```bash
chmod +x keyboard/install-keyboard.sh
./keyboard/install-keyboard.sh
```

**Options**:

* `./keyboard/install-keyboard.sh --check` : Check if hwdb is deployed.
* `./keyboard/install-keyboard.sh --dry-run` : Preview operations.
* `./keyboard/install-keyboard.sh --uninstall` : Remove the top-row hwdb, backlight sync and (if installed) the keyd config.
* `./keyboard/install-keyboard.sh --with-keyd` : Install with keyd (advanced dual-role).
  Fails (non-zero) if the keyd service cannot be activated: rc 3 when only the config
  was written (no keyd binary), rc 1 for a rejected config, a failed service-manifest
  write (no config deploy, no enable/restart; snapshot kept as `.failed`) or a failed
  restart/revert.
* `./keyboard/install-keyboard.sh --keyd-config-only` : Implies `--with-keyd`, but explicitly
  accepts the config-only outcome (no keyd binary/service) with rc 0. The installer still
  reports that dual-role is **not** active.

**Keyd snapshot base (advanced):** `CROS_ENABLEMENT_KEYD_SNAPSHOT_DIR` overrides the default
`/var/lib/cros-enablement-keyd-snapshots`. A custom path must be absolute: the base must be
root-owned with mode `0700`, every ancestor must be root-owned, and the direct parent must not
be group/other-writable (a sticky bit does not exempt it). Paths under a user's home directory
are rejected; if any check fails the installer refuses to deploy keyd config.

**Backup manifest is fail-closed:** deployed files, services and groups are tracked in
`/var/lib/cros-enablement/install-manifest.json`. A missing manifest is still created as
an empty skeleton, but an **existing corrupt/invalid** one logs `MANIFEST_INVALID ...
original bytes left untouched`, leaves the file byte-for-byte unchanged and makes the
backup/writer paths refuse to continue (no target is backed up or claimed as tracked
while the manifest cannot be parsed). Repair or deliberately remove the corrupt manifest
before reinstalling, so rollback coverage is never silently lost.

Records are **validated by field type, never repaired** (one validator shared by all
readers/writers). A record `target` must be an absolute path string with no NUL;
`component`, `installed_at`, `version` and `scope` must be strings when present.
The safety-decision fields `was_existing`, `was_enabled`, `was_active` and `was_member`
are **required booleans** — every real writer (v1.0 and v2.0) has always emitted them,
so the only genuine legacy tolerance is absent top-level arrays, a keyd record missing
`component` (backfilled) or `scope`. The string `"false"` and the number `1` are
rejected, not coerced; service `name`/`component` and group `group`/`user`/`component`
are required, other optional fields may be absent and unknown keys are ignored. A wrong
type is a new `MANIFEST_INVALID` reason (not only corrupt JSON) and leaves the original
bytes untouched. Non-absolute pseudo-targets such as the fingerprint
`package:libfprint-crfpmoc` are skipped before a record is written, logging
`skipping manifest entry with non-absolute target` (Meson install-plan destinations must
be absolute too), so the installer never writes a record its own validator would reject.

**Whole component operations and manifest writes are serialized across processes:**
`install_keyboard()`, `uninstall_keyboard()` and `install_keyd_step()` each take ONE
operation-level lock via `run_manifest_operation()` (`lib/backup.sh`) covering
backup/record → deploy → finish/rollback; nested helpers re-enter through
`MANIFEST_LOCK_DEPTH` and `DRY_RUN` takes no lock. This prevents a parallel uninstall from
consuming a just-written `was_existing=false` record while the target is absent and leaving
a deployed file with no tracking record. Every read-modify-write (the backup helpers plus
the keyd-link normalizer here) runs inside that lock, and `flock -x -w` waits on
`$MANIFEST_DIR/.install-manifest.lock` (fd 9) for at most
`CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT` (default 10s); a missing `flock` or a timeout fails
closed with the manifest bytes intact. The lock is a root-owned `0600` regular file, held by
a short-lived `coproc sudo bash -c` root helper that owns fd 9, checks the fd/path `(dev,ino)`,
owner `0`, mode `600` and file type via `/proc/$$/fd/9`, and releases the flock when the
parent closes the pipe (no stale lock, no EXIT trap). `CROS_ENABLEMENT_MANIFEST_DIR` must be
absolute (`must be an absolute path`), and **every literal symlink component is rejected**
(`contains a symlink` / `untrusted symlink`) even when root-owned — a fail-closed choice,
because a symlink can hide a user-writable target that can rename the lock. The gate resolves
the deepest existing prefix with `realpath -e`, appends missing layers (first-time creation
still works) and checks the **canonical** ancestors (`untrusted realpath ancestor`). The
**direct parent must be root-owned** (ownership by the current EUID/UID no longer qualifies:
its owner could rename a live lock); every ancestor must also be root-controlled — a
non-root-owned or g/o-writable layer without a sticky bit fails closed (`not root-controlled`),
a root-owned sticky world-writable layer such as `/tmp` `1777` is allowed. Keep
`/var/lib/cros-enablement` at `0755`; older `0644` locks are upgraded to `0600`. Inside the
holder process, `realpath -e "$dir"` must still equal the canonical parent (`FAILED:canonical`)
and every real ancestor must be uid `0` plus non-g/o-writable or root-sticky
(`FAILED:ancestor`). The holder also pins the direct parent with **fd 8**
(uid/mode/type/dev+ino recheck, `FAILED:parentdir`),
defeating a rename that would let a second process lock a fresh inode. Symlinks, non-regular
files and inode swaps fail closed too. The gate → re-read → decision → write sequence runs
inside the critical section, so a parallel
run cannot drop another's first-wins backup/service/group records. Each writer uses a unique
`.install-manifest.*.tmp` (mkstemp + fsync + `chmod 0644` + `os.replace`) instead of a shared
`.tmp`, so concurrent writers cannot clobber each other's temporary file. Lock creation uses
`umask 077` + `set -C` — never `install` — so its inode is never replaced.

**Rollback is gated before any side effect:** `rollback_component()`,
`uninstall_keyboard()` and `remove_group_membership()` validate the manifest first —
before `systemctl disable keyd` / `gpasswd -d` and before any service or file change —
and fail closed (rc 1, no log_success) if it is invalid. Rollback feeds the exact
validated document to the restore script over stdin (no second unvalidated parse, no
TOCTOU window). Because services are restored before files, a mid-run script failure can
leave partial state: it logs
`rollback of <component> failed; service/file state may be partial (retained records
remain for retry)` and returns rc 1 instead of claiming success.

**Rollback safety semantics:**

* **Unknown original state fails closed.** A missing or non-bool `was_existing` /
  `was_enabled` / `was_active` / `was_member` means "original state unknown", never
  `false`. Rollback deletes no file, stops no service and drops no membership for such
  a record; it keeps the record, warns (`RECORD_STATE_UNKNOWN` / `SERVICE_STATE_UNKNOWN`)
  and returns rc 1. `_keyd_managed_by_us()` likewise refuses to disable/stop keyd unless
  the record carries a valid bool snapshot.
* **An absent target is still restored.** For a `was_existing` record rollback finds the
  first (oldest) matching backup regardless of whether the target still exists, then
  stages it next to the target and swaps it in with a single atomic `os.replace()` (owner,
  mode and symlink target restored). Regular files/symlinks are never unlinked first, so a
  failed swap leaves the installed target in place; any swap involving a directory (including
  dir→dir) moves the old entry aside and back on failure. The record is consumed only after a confirmed
  success; if no backup exists it keeps the record, warns (`[WARN NO BACKUP]`), logs
  `RECORD_BACKUP_MISSING` / `ROLLBACK_INCOMPLETE` and returns rc 1 instead of creating a
  fake file (other items still roll back normally).
* **A failed restore keeps its record.** Every `systemctl` enable/disable/start/stop
  checks its return code (including timeouts, stderr and spawn errors). A failed service
  logs `SERVICE_RESTORE_FAILED` / `ROLLBACK_INCOMPLETE`, keeps its record for a later
  retry and makes rollback return non-zero; successful restores log `[RESTORED SERVICE]`.
* **Group membership is recorded before it changes.** For `plugdev` the installer first
  persists the original membership, then checks `sudo usermod -aG` rc explicitly (no
  `|| true`); if `usermod` fails and no earlier record existed it removes the just-written
  record. The shared `manifest_has_group` / `manifest_remove_group` /
  `ensure_group_membership` helpers are used by the keyboard, fingerprint and EC code.
* **plugdev ownership is decided across all components; stale records are refreshed.** On
  uninstall `remove_group_membership()` aggregates every component's `(group,user)` record:
  any `was_member=false` proves we added the membership (rc 0), no record means nothing to
  roll back (rc 1), and **all `true`** means pre-existing (rc 3); a wrong field type fails
  closed. first-wins is unchanged — rc 0 runs `gpasswd -d` unless a udev rule still needs the
  group, and a successful removal consumes **all** records for the pair
  (`manifest_remove_group_all`) so a full install/uninstall works in either component order.
  On rc 3 **no gpasswd runs at all**: with a live udev rule the snapshot is kept; once no rule
  references the group (every consumer uninstalled), all stale records are consumed with
  zero `gpasswd` calls so the next install re-snapshots the real membership. Consume failure
  fails closed (rc 1). `gpasswd -d` failure is a real error (rc 1), folded into the
  uninstaller's exit code instead of being reported as success.
* **PAM restoration is rollback-owned.** The fingerprint uninstaller never sed-edits
  `/etc/pam.d/sudo`; the original bytes come from `rollback_component("fingerprint")`, so a
  pre-existing exact `pam_fprintd` line is preserved. On Debian/Ubuntu, install removes fp
  lines from `common-*` with a direct `sed -i '/pam_fprintd\.so/d'` — never
  `pam-auth-update --remove fprintd`, which would delete the debconf profile selection
  outright. Install snapshots that selection plus `/var/lib/pam/*` (first-wins sidecar) and
  runs `pam-auth-update --package` itself to converge; uninstall restores them with
  `debconf-set-selections` + `--package` after rollback completes, and verifies the
  selection before consuming the snapshot. See [UNINSTALL.md](../docs/UNINSTALL.md) for the
  Tier 2 backup, the admin-override trade-off, the read-only stale-record check and the
  authselect/pam-config limits.

All install callers save the rollback rc, complete their remaining cleanup and return
that rc last, so `set -e` cannot abort cleanup when a rollback fails.

---

### Option 2: `keyd` Daemon (Advanced Multi-Layer & Dual-Role)

If you want the **Search key** to act as **CapsLock on tap** and **Super/Meta
on hold**, or want `Search + Top-Row` to produce classic `F1-F10`:

> **Prerequisite:** Option 1 `systemd-hwdb` must be installed first. `keyd` relies on
> hwdb having translated the inferred top-row scancodes `0x3b`-`0x44` to
> `KEY_BACK`/`KEY_BRIGHTNESSDOWN`/... and `0xDB` to `KEY_LEFTMETA`; `cros.conf`
> uses those names (`back`, `leftmeta`). Run
> `sudo python3 keyboard/tests/check-top-row-hwdb.py` to confirm the kernel map.
> Recommended: `sudo ./keyboard/install-keyboard.sh --with-keyd` (installs
> hwdb+backlight+keyd atomically). If keyd is not installed yet, this now returns rc 3
> instead of claiming dual-role is active; use `--keyd-config-only` if you intentionally
> want only the config deployed (e.g. CI containers).

1. Install `keyd` (CI pins v2.6.0 for syntax checks; on-device behaviour validated on 2.5.0-5):

   ```bash
   # Ubuntu 25.04+ / Debian 13+ (native)
   sudo apt update && sudo apt install -y keyd

   # Ubuntu 22.04/24.04 or Debian 12 (PPA)
   sudo add-apt-repository ppa:keyd-team/ppa -y
   sudo apt update && sudo apt install -y keyd
   # or build from source pinned:
   git clone --depth 1 --branch v2.6.0 https://github.com/rvaiya/keyd /tmp/keyd
   test "$(git -C /tmp/keyd rev-parse HEAD)" = "7c0aecb8bfd34dc8642bf4eefd2e59c89e61cec3"
   make -C /tmp/keyd && sudo make -C /tmp/keyd install

   # Fedora (COPR)
   sudo dnf copr enable alternateved/keyd -y
   sudo dnf install -y keyd

   # Arch Linux (extra)
   sudo pacman -S keyd

   # NixOS
   # services.keyd.enable = true;  # plus environment.etc."keyd/cros.conf".source = ./keyboard/keyd/cros.conf
   ```

   > **Package name differs by distro (verified on Ubuntu 26.04):** the Debian/Ubuntu
   > package installs **`/usr/bin/keyd.rvaiya`** (version 2.5.0-5), not
   > `/usr/bin/keyd`; the systemd unit is still called `keyd`. Use whichever
   > exists, e.g. `keyd.rvaiya --version`. The installer auto-detects it through
   > `keyd_bin()` in `lib/syscheck.sh`. Also, **`keyd check` only exists in
   > keyd >= 2.6** - on 2.5.x it just prints usage and exits 0. CI pins v2.6.0
   > for **syntax only**; all tap/hold/guard behaviour below was measured with
   > 2.5.0-5 on the device (see §Real-hardware validation).

2. Install configuration (via installer, recommended):

   ```bash
   sudo ./keyboard/install-keyboard.sh --with-keyd
   # equivalent manual:
   # sudo install -D -m 0644 keyboard/keyd/cros.conf /etc/keyd/cros.conf
   # keyd check /etc/keyd/cros.conf     # only keyd >= 2.6; 2.5.x validates on start
   # sudo systemctl enable keyd
   # sudo systemctl restart keyd         # keyd 2.5.x reads config only at start-up
   ```

3. Verify & tune:

   ```bash
   keyd --version || keyd.rvaiya --version   # Ubuntu 26.04 ships keyd.rvaiya
   # Passive capture of what keyd sends (safe, never grabs the device):
   sudo python3 keyboard/tests/capture-keyd-output.py --seconds 120
   # short press Search -> capslock ; long hold -> bare leftmeta ; Search+TopRow -> F1
   sudo systemctl status keyd
   journalctl -eu keyd -f
   # Tap/hold threshold is the third argument of overloadt2() in
   # /etc/keyd/cros.conf (200 ms here). The [global] overload_tap_timeout
   # option only affects plain overload(), not overloadt2().
   # Change the 200 and `sudo systemctl restart keyd` to tune it.
   ```

   **GNOME Wayland trackpad quirk** (optional, fixes `disable-while-typing` stall):

   ```bash
   sudo mkdir -p /etc/libinput
   printf '[Keyd]\nMatchName=keyd virtual keyboard\nAttrKeyboardIntegration=internal\n' | sudo tee /etc/libinput/local-overrides.quirks > /dev/null
   ```

    **Notes:**
    * `[ids] 0001:0001` scopes `cros.conf` to the internal AT keyboard. The wildcard
      `*` also grabs the ChromeOS `Video Bus` (`0000:0006`) and every external USB
      keyboard, which duplicates brightness handling and swallows external keys.
      Add an external keyboard by ID from `sudo keyd monitor` if you want it remapped too.
    * **Tap is a clean `CAPSLOCK`**, hold is `Super`, thanks to
      `overloadt2(meta, capslock, 200)`. Plain `overload(meta, capslock)` is not
      enough: it activates Meta on press, and keyd's modifier guard
      (`clear_mod()` in `src/keyboard.c`) then wraps the release in a
      `LEFTCTRL` tap. Mutter sees `Meta+Ctrl` and never opens the GNOME overview.
      `overloadt2` defers the tap/hold decision and its layer-release path
      suppresses the guard, so a pure hold emits a bare `LEFTMETA` down/up.
    * The 200 ms threshold is the tap/hold split: release sooner for CapsLock,
      hold longer for Super. Pressing another key while Search is down resolves
      as a hold.
    * Top-row keys are not remapped in `[main]`; keyd passes them through so the
      hwdb media keys keep working on a single press. `[meta:M]` provides the
      F1-F10 layer.
    * keyd 2.5.x has no hot-plug device detection: after changing `/etc/keyd/*.conf`
      you must `sudo systemctl restart keyd` (a `reload` only re-parses config for
      already-grabbed devices).
    * `X11` users: `setxkbmap` is reset on `keyd restart`; reapply after.
    * `TTY` works via `uinput`; panic: `backspace+escape+enter` if config locks you out.

---

### Option 3: Keyboard Backlight Sync with Screen Blank

Automatically turns off the keyboard backlight when the screen blanks/locks
and restores it when the screen lights up. Handles both GNOME Wayland idle
(`org.gnome.ScreenSaver` + `org.freedesktop.login1 PrepareForSleep` for S3 lid)
and the ChromeOS EC `cros_kbd_led_backlight` (`/sys/class/leds/chromeos::kbd_backlight`).

**Write chain (single-writer):** the daemon writes the gsd-power property
`org.gnome.SettingsDaemon.Power.Keyboard.Brightness` (percent) **first** — that
is the one authoritative writer, keeping gsd-power's own cache in sync and
driving UPower/LED. Only when gsd-power is unavailable does it fall back to
UPower `KbdBacklight.SetBrightness` (raw), then to `sysfs`/`ectool`. Reads use
UPower `GetBrightness`. `C640_KBD_FORCE_LEGACY=1` disables both D-Bus backends
and forces the `sysfs`/`ectool` path (useful for A/B comparison).

Installed automatically via `./keyboard/install-keyboard.sh`:

```bash
./keyboard/install-keyboard.sh                          # install hwdb + backlight sync
./keyboard/install-keyboard.sh --with-keyd              # hwdb + backlight + keyd dual-role (Option 2)
./keyboard/install-keyboard.sh --check                  # verify daemon/service/udev/keyd state
./keyboard/install-keyboard.sh --uninstall              # remove all keyboard components (incl. keyd)
./keyboard/install-keyboard.sh --with-keyd --dry-run    # preview all
```

**What it installs:**

* `61-chromeos-kbd-backlight.rules` → `/etc/udev/rules.d/` (`TAG+="uaccess"`,
  plus `RUN+=chgrp plugdev` / `RUN+=chmod 0660` on the brightness attribute)
* `c640-kbd-backlight-sync` → `/usr/local/bin/` (bash daemon,
  `gdbus`/`dbus-monitor` event-driven, no polling by default)
* `c640-kbd-backlight-sync.service` → `/etc/systemd/user/` (enabled globally,
  `WantedBy=graphical-session.target`, `StandardError=journal` so all daemon
  log lines are visible in `journalctl`)
* `c640-kbd-backlight-sleep.sh` → `/usr/lib/systemd/system-sleep/` (S3 pure handoff writer
  under frozen `user.slice`; no LED write, no D-Bus, no state deletion, no delay)

**Save/restore semantics:** a brightness of `0` is a valid saved value and uses the
exact same write-and-verify path as any other value. Brightness selection prefers the
current live non-zero reading, so a change made just before the blank is not lost to the
5s sampler cache. The cache is used for blank-side zeros (firmware already off),
unreadable hardware and a *fresh* explicit manual-off (`source=manual0` with `ts`,
honoured for `C640_KBD_LAST_USER_TTL=15`s only while gsd-power still reports an
**explicit** 0; a failed/empty gsd query means "cannot confirm", NOT 0, so the
live non-zero reading wins). The sampler applies the same rule: two on-screen
zeros with an empty gsd pct are NOT promoted to `manual0`. Its
sidecar `LAST_USER_META_FILE` (`c640-kbd-backlight.last-user.meta`) records
`source=nonzero|manual0` + `ts` + `restore=<generation>`; the generation stamp lets the
unblank guard tell a post-restore user change from a stale pre-blank cache. A daemon
restart re-seeds the cache from the current reading (`cur=0` → `manual0`). With no
state file nothing is written, so manual adjustments are preserved.

`save_state()` is atomic and **first-wins only for a valid copy**: while holding
`STATE_LOCK` it checks that the saved value is a bare non-negative decimal integer on a
single line. A valid existing copy is never overwritten, even by a later blank. An
empty, non-numeric, multi-line or binary state file is not a copy — it is validated
inside the lock and atomically replaced with this blank's captured value, logging
`replacing invalid saved brightness with N`. Value selection happens before the lock;
only a real mktemp/write/verify failure returns rc `2` and leaves the LED on.

`save_state()` has an explicit rc: `0` = a valid copy exists (already present, or
self-healed now), `1` = the bounded `flock -w` on the state lock timed out or errored,
`2` = value selection or the state write failed. `C640_KBD_SAVE_LOCK_WAIT` bounds that
wait (default `2s`; `0` = no wait). On blank the daemon samples the brightness **once,
before switching the LED off**, and the first `save_state "$captured"` uses that captured
value directly — it does **not** sample a second time. Sampling twice could let a
blank-side hardware `0` fall back to a stale last-user cache (saving `8` instead of the
real `30`), and that wrong value would never be corrected by a later retry. Only when
the capture itself is empty does `save_state` sample on its own; retry attempts reuse
the same captured value. The daemon **only turns the LED off after the save succeeds**;
if every attempt fails it logs `blank: brightness NOT saved (...)`,
`blank: deferred save attempt N failed`, leaves the LED on and keeps the captured value
in the last-user cache so a later blank can still persist it. `--test-blank` exits 1 on
a save failure.

`set_brightness()` returns 0 (success) when at least one backend accepted the write and a
readback (`verify_brightness()`) confirmed it; with no readable path at all the accepted
write is treated as success with a WARN. rc 1 means every writer failed or every readback
disagreed. Before the slow write the state is staged to
`C640_KBD_RESTORE_PENDING_FILE` (`c640-kbd-backlight.restore-pending`) so a blank arriving
mid-write can still save a new value; the staged value is consumed **only after** the
write verifies, otherwise it is rolled back (rc 1) and retried at +0.5s/+1.5s/+3s. A
crash between staging and finalize is recovered at the next daemon startup.

**ScreenSaver is a tristate (fail-closed):** `screensaver_tristate()` returns `active`,
`inactive` or `unknown`; only an explicit `inactive` permits a restore write, while
`active`/`unknown` defer and keep the state for a later unblank. The boolean
`screensaver_is_active()` wrapper is used by the sampler, the restart seed and
`guard_blank`: the first two only skip a sample on an unknown answer, while
`guard_blank` **can write 0** when the answer is an explicit `true` (a
best-effort secondary forced-off). Only restore paths use the fail-closed
tristate.

**Sleep hook = pure handoff:** on a real S3 cycle systemd freezes `user.slice` before
the `post` phase, so the hook never queries a user/session D-Bus, never writes the LED
and never deletes state. `pre` writes `/run/c640-kbd-backlight/state` as a **single-shot
diagnostic snapshot of the first suspend in a boot** (first-wins, kept until reboot) and
publishes `c640-kbd-backlight.suspend` (one decimal integer, `0` valid); `post` only
publishes `c640-kbd-backlight.resume` (`<epoch> <action>`). The root snapshot is **not
consumed by the hook or the daemon and is never used for restore**; the daemon consumes
only the two handoff files and its own `$XDG_RUNTIME_DIR/c640-kbd-backlight.state`.
Both handoff files are `0600`, chowned to the resolved session user and atomically
`mv`-ed into `$XDG_RUNTIME_DIR`; `C640_KBD_HANDOFF_DIR` overrides the hook's
directory. A blank-side handoff `0` is ignored when the daemon holds a different
non-zero saved value, so the user's brightness survives a suspend started while
the screen was blank — **except** when all three agree: a fresh last-user record
`source=manual0` (within `C640_KBD_LAST_USER_TTL`), the cache value `0`, and an
**explicit gsd pct 0**. An empty gsd reply is "cannot confirm", so the `0` is still
treated as blank-side and ignored. If a handoff exists in a `/run/user/<uid>`
directory but not in the daemon's runtime directory, the daemon scans that root
read-only and logs `[WARN] handoff directory mismatch` with the path (including a
different session uid); it never cross-adopts files that may belong to another
user. The hook warns with the directory it chose when loginctl reports multiple
sessions. The hook never consumes the handoff files — the daemon does that after a
successful adoption/restore.

**Resume handoff (the thawed daemon is the only writer):** `handle_resume()` runs on
`PrepareForSleep(false)` from the **system** bus (not frozen), on a resume flag picked
up by the sampler, or on startup recovery. A `RESUME_LOCK` serialises the login1 monitor,
sampler and startup paths; the daemon re-probes both D-Bus backends, adopts the suspend
handoff into `STATE_FILE`, then polls the tristate with 0.2/0.4/0.8/1.6/3.2s delays
under a **wall-clock** deadline of `C640_KBD_RESUME_PROBE_MAX=10`s. The deadline is
checked **after each probe** (and before the next one), so it also counts D-Bus
query time; it is not a hard interrupt: worst-case `RESUME_LOCK` hold time is
~`probe_max` + one tristate query (two backends × `timeout 3` ≈ 6s). On expiry the
answer converges as `unknown`. `inactive` → restore through
gsd-power→UPower→legacy;
`active` → defer with retries; `unknown` → converge without a write only when the
current brightness already equals the saved value, otherwise defer.
`C640_KBD_RESUME_ALLOW_UNKNOWN=1` opts in to restoring while the answer is still unknown
— this accepts the risk of lighting a still-locked screen and is off by default.
`handle_unblank()` routes through `handle_resume()` whenever a resume flag is present,
avoiding a double write.

**Physical write serialisation and generation gate (Tier 1):** every physical
`SetBrightness`/gsd `Properties.Set` is wrapped in `WRITE_LOCK` (flock fd 209),
including blank, restore, retries and both guards. `C640_KBD_WRITE_LOCK` overrides
its path. The lock order is `RESUME_LOCK -> STATE_LOCK -> WRITE_LOCK`; nothing inside
`WRITE_LOCK` may take an outer lock (finalize, verify and generation bookkeeping all
run after release). Slow D-Bus reads (the guard's LED readback) are done BEFORE taking
`WRITE_LOCK`, so a 3s gdbus timeout cannot hold up a restore waiting for the lock.
`bump_restore_gen()` reads, increments and atomically republishes the generation AND
clears the guard markers inside `WRITE_LOCK`, then returns 0; on lock failure it
publishes nothing (no degraded out-of-lock write), returns 1, and every caller
converts that into DEFER while keeping flag/handoff/state. `C640_KBD_GUARD_WRITTEN_GEN`
overrides `c640-kbd-backlight.guard-written-gen`, the marker that lets only one of
the two guards of a generation re-set the value.

The optional +0.3/+0.9s unblank guard and the +0.25/+1.0s blank guard re-check the
generation after sleeping and again inside `WRITE_LOCK` before writing; a superseded
guard does ZERO writes. The retry at +0.5/+1.5/+3s also re-checks the generation
after acquiring `WRITE_LOCK`, because its earlier check was made under `STATE_LOCK`
and released while waiting: if a newer cycle bumped the generation in that gap, the
retry releases the lock, rolls `RESTORE_PENDING` back to `STATE_FILE` via
`finalize_restore ... RC_DEFER` (never leaving a PENDING orphan) and exits without a
write.

The unblank guard's decision table, in order:

| State | Action |
| :--- | :--- |
| Generation changed after sleep, or inside `WRITE_LOCK` (also final re-check before write) | Log cancellation; zero writes |
| LED already equals the saved value, or this generation already has a guard marker | Skip (no duplicate write) |
| Stamped cache alone: `lu != saved` **and** `lu_gen == restore_gen` | Treat as user intent; no write, regardless of gsd |
| No such cache, gsd pct still equals `want_pct` | Genuine lost restore; re-apply the saved value |
| Anything else, e.g. `gpct != want_pct`, empty/failed gsd query, unstamped cache | **Ambiguous / fail-closed: no write** |

`read_last_user_record()` cats the meta file ONCE and parses `value=` and `restore=`
from that same snapshot; the guard uses that pair, so a sampler rewrite between two
reads cannot manufacture "old value + new generation" evidence. The stamp proves only
that the cache was written after this restore, not that the sampled value is correct.
**Cost of this rule:** a lost restore whose gsd percentage has *already followed* the
user's new value (`gpct != want_pct`) is now ambiguous and is no longer repaired —
the guard deliberately fails closed instead of overwriting a possible user choice.
The earlier "gsd/LED and the same cache all agree" third clause has been removed.

`WRITE_LOCK` acquisition failure is fail-closed everywhere: `restore_state()` and a
retry defer without writing (the staged value is rolled back); `handle_blank()` leaves
the LED on after the save succeeded; `--test-blank` exits 1 with
`simulated blank: failed to set 0`; the guard logs `WRITE_LOCK unavailable` and skips.
`C640_KBD_SELF_WRITE_SENTINEL` is reserved for the optional **Tier 2 brightness-signal**
path (write `value:gen` under `WRITE_LOCK` before `set_brightness` so a self-write is
not mistaken for user intent); **Tier 2 is NOT implemented** — the sentinel is only
created/cleared by tests and never consulted by Tier 1.

Adoption, restore and `verify_restore_applied()` share a result-code contract:
`0 = RC_DONE` (write verified, `STATE`/`restore-pending` consumed), `1 = RC_FAIL` (bad
input or I/O failure) and `2 = RC_DEFER` (lock contention, a staged restore in flight,
or an active/unknown screen). A lock failure, a surviving `STATE`/`PENDING` file or a
brightness readback that disagrees with the saved value maps to DEFER/FAIL, not success.
**Only `RC_DONE` consumes the resume flag (and the handoff/state)**. `RC_DEFER` keeps
flag/handoff/state and schedules retries for the sampler or next unblank; `RC_FAIL`
keeps the resume flag, but the saved state may already have been consumed (only the
captured value remains in the last-user cache); a write/finalize FAIL still re-arms the
+0.5/+1.5/+3s retries when a state file remains, whereas a verify or adoption FAIL
schedules none. `handle_unblank()` logs `unblank: restore deferred` on DEFER instead of
a false WARN.

**Backend re-probe:** only a successful probe is cached; missing or failing gsd-power /
UPower are re-probed on every use, so a D-Bus name that appears later is adopted. A
failed runtime call drops the cached backend and logs `... lost (1 -> 0) ... re-probe on
next use`; when it returns the daemon logs `... RECOVERED (0 -> 1); switching back to
single writer`. `C640_KBD_FORCE_LEGACY=1` still disables both D-Bus backends and forces
`sysfs`/`ectool` (useful for A/B comparison).

> **Why `RUN+=chmod`?** `MODE=`, `GROUP=` and `uaccess` only apply to `/dev`
> device nodes. `/sys/class/leds/chromeos::kbd_backlight/brightness` is a plain
> sysfs attribute with no device node, so udev cannot chmod it that way and the
> attribute stays `root:root 0644`. The rule therefore runs `chgrp plugdev` +
> `chmod 0660` explicitly (verified working on Ubuntu 26.04). Without it the user
> daemon falls back to `echo | sudo -n tee`, which a session service usually
> cannot answer. Verify:
>
> ```bash
> ls -l /sys/class/leds/chromeos::kbd_backlight/brightness   # root plugdev 0660
> sudo udevadm control --reload-rules
> sudo udevadm trigger --subsystem-match=leds                # re-apply without reboot
> id -nG | tr ' ' '\n' | grep -qx plugdev && echo "user is in plugdev"
> ```

**Manual test without blanking the screen:**

```bash
c640-kbd-backlight-sync --check          # show current brightness & state
c640-kbd-backlight-sync --test-blank     # simulate blank: save, then set 0 (exit 1 if save fails)
cat /sys/class/leds/chromeos::kbd_backlight/brightness  # should be 0
c640-kbd-backlight-sync --test-unblank   # simulate unblank -> restore
```

**Optional IdleMonitor polling** (off by default, for "dim before blank"):

```bash
# Enable Mutter IdleMonitor polling (idle-delay + 5s threshold) via drop-in:
sudo mkdir -p /etc/systemd/user/c640-kbd-backlight-sync.service.d
echo -e "[Service]\nEnvironment=C640_KBD_ENABLE_IDLEMONITOR=1" | sudo tee /etc/systemd/user/c640-kbd-backlight-sync.service.d/override.conf > /dev/null
sudo systemctl daemon-reload
sudo systemctl --global daemon-reload 2> /dev/null || true
systemctl --user daemon-reload 2> /dev/null || true
systemctl --user restart c640-kbd-backlight-sync.service 2> /dev/null || true
# To disable: sudo rm /etc/systemd/user/c640-kbd-backlight-sync.service.d/override.conf && daemon-reload
```

**Wayland/X11 compatibility:** primary path is `org.gnome.ScreenSaver` (GNOME Wayland
native, event-driven, no polling). `IdleMonitor` is optional. On lid-close S3 the
`system-sleep` hook only publishes handoff files; the thawed user daemon performs the
restore, so the user service must be running.

**Logs:** all daemon messages go to stderr; the unit sets
`StandardError=journal`, so they are visible in the user journal (including
`backends probed: gsd=... upower=...`, `RECOVERED (0 -> 1)`, `saved brightness`,
`replacing invalid saved brightness with N`,
`restoring brightness`, `restore verify (gen=...): ... not completed`,
`suspend handoff adoption deferred`, `restore deferred: ScreenSaver ...`,
`resume deferred:`, `unblank: restore deferred`, `ignoring blank-side suspend handoff 0`,
`blank: brightness NOT saved`, `blank: deferred save attempt N failed`,
`restore failed (... rc=...): keeping brightness ... for retry`,
`another restore is in progress`, `resume: restore complete; resume flag consumed`
and `[WARN]` fallback lines):

```bash
journalctl --user -u c640-kbd-backlight-sync.service -f
journalctl --user -u c640-kbd-backlight-sync.service --since "5 min ago" | cat
```

**Runtime environment overrides** (no system files are touched):
`C640_KBD_FORCE_LEGACY=1` disables both D-Bus backends (see above);
`C640_KBD_LAST_USER_TTL` sets the manual-off cache TTL (default 15s);
`C640_KBD_SAVE_LOCK_WAIT` bounds the state-lock wait in `save_state` (default 2s);
`C640_KBD_RESUME_PROBE_MAX` caps the **wall-clock** budget of post-thaw
ScreenSaver polling (checked after each probe; worst case ≈ budget + one query,
default 10s);
`C640_KBD_RESUME_ALLOW_UNKNOWN=1` opts in to restoring on an unknown answer.

**Test-only environment overrides** (no system files are touched): the daemon
accepts `C640_KBD_SYSFS_BRIGHTNESS` / `C640_KBD_SYSFS_MAX` for a fake LED node and
`C640_KBD_HANDOFF_SUSPEND` / `C640_KBD_HANDOFF_RESUME` /
`C640_KBD_RESTORE_PENDING_FILE` / `C640_KBD_RESUME_LOCK` /
`C640_KBD_LAST_USER_META_FILE` for staging/handoff paths, plus
`C640_KBD_WRITE_LOCK`, `C640_KBD_GUARD_WRITTEN_GEN` and
`C640_KBD_SELF_WRITE_SENTINEL` for the write-lock / guard-marker / reserved
Tier-2 sentinel paths. The sleep hook accepts
`C640_KBD_SLEEP_SYSFS`, `C640_KBD_SLEEP_STATE_DIR`, `C640_KBD_HANDOFF_DIR` and
`C640_KBD_RUN_USER_ROOT`; when `C640_KBD_HANDOFF_DIR` is set, the daemon uses the
same value as the hook-side directory for its mismatch diagnostic, and also uses
`C640_KBD_RUN_USER_ROOT` for the read-only cross-uid scan. Its old
`C640_KBD_SLEEP_USER` / `_UID` / `_BUS` /
`_DELAY` bus-probe overrides are ignored (no D-Bus and no delay in the hook).

**Unit tests (no root, no real sysfs/D-Bus):** stub tools live first on `PATH`;
all state is in a temp dir. The daemon suite has 535 cases (write chain, re-probe,
staging/verify, tristate, resume result codes/retry, save-before-blank, single-sample
blank, invalid-state self-heal, mutation-covered empty-gsd-pct, unconfirmed sampler
zeros, wall-clock probe deadline, cross-uid handoff mismatch, gsd-confirmed
fresh-manual0 adoption, generation-stamped guard user-change protection, expired-retry
in-lock generation gate with PENDING rollback, strictly monotonic generation bumps,
fail-closed lock failures and single-read last-user cache) and the
sleep-hook suite has 84 cases (pure handoff, `0600`/`chown`/atomic `mv`,
`C640_KBD_HANDOFF_DIR`, multi-session resolution with IDLE/CLASS preference and
chosen-path warnings, no LED writes). The rollback suite
(`tests/rollback-test.sh`, run as root) has 1981 cases, including corrupt and
field-type-invalid manifest fail-closed, the pre-mutation rollback gate, pseudo-target
skipping, unknown-state fail-closed, absent-target first-backup restore, atomic restores
that keep the target on a failed swap, missing-backup rc 1, the root-only `0600` holder
lock with absolute-path/canonical/literal-symlink/inode/ancestor/parent-dir rejection and fd
8 pin, cross-component plugdev ownership with optional per-install `added_by_project`
evidence (R15-R20), stale all-true record consumption with zero gpasswd and gpasswd failure
rc 1, PAM original-line protection plus first-wins debconf selection / `/var/lib/pam`
snapshot, `pam-auth-update --package` convergence and verified uninstall restoration
(including a non-root/passwordless-`sudo` case), the whole-operation lock (OP1/OP2
FIFO-barrier regressions for deploy vs rollback, a real-installer barrier and fail-closed
bodies), unique writer temps and checked `systemctl` restores. CI also runs a real-tool
Ubuntu 24.04 container E2E for the PAM round-trip.

```bash
bash keyboard/tests/kbd-backlight-daemon-test.sh       # 535 cases
bash keyboard/tests/kbd-backlight-sleep-hook-test.sh   # 84 cases
sudo bash tests/rollback-test.sh                       # 1981 cases (root)
```

---

## 🧪 Verification & Testing

### hwdb scancode map check (run this first)

The hwdb can only work if it maps the scancodes the hardware actually emits.
This read-only check compares the kernel's `EVIOCGKEYCODE` map with
`keyboard/tests/hwdb-top-row-scancodes.tsv` (no grab, safe while keyd runs). It
proves which mapping the kernel applied, not what the hardware emits. The
`0x3b`-`0x44` table was inferred from post-hwdb `EVIOCGKEY` key state against
the standard AT table, and `EVIOCGKEYCODE` confirms the kernel map; no raw
`MSC_SCAN` capture is available in the evidence. To obtain one, stop keyd and
use `check-top-row-hwdb.py --scan` or plain `evtest` (no `--grab`), then infer
the value against the standard AT table. The `--listen` mode only
observes the post-hwdb `KEY_*` key events via `EVIOCGKEY`; before the fix every
physical top-row press still arrived as `KEY_F1`-`KEY_F10` while the
action-scancode hwdb did nothing.

```bash
sudo apt install -y python3-evdev
sudo python3 keyboard/tests/check-top-row-hwdb.py
# 0x3b  back             KEY_BACK             KEY_BACK             OK
# 0x40  brightnessdown   KEY_BRIGHTNESSDOWN   KEY_BRIGHTNESSDOWN   OK
# 0xdb  leftmeta         KEY_LEFTMETA         KEY_LEFTMETA         OK
# RESULT=PASS
```

`RESULT=` reports only the EVIOCGKEYCODE mapping verdict. If you pass
`--scan SECONDS`, raw `MSC_SCAN` is required as well: with no scan observed
(keyd still holds the grab, or no key was pressed) the tool prints
`RESULT=PASS (mapping check only; raw capture FAILED)` but exits **non-zero**.
Judge overall success by the exit code and the `RAW_CAPTURE=` line, not by
grepping `RESULT=PASS` alone.

A `MISMATCH ... KEY_F1` row means hwdb is not applied (or maps the wrong
scancode). Reinstall with `sudo ./keyboard/install-keyboard.sh --with-keyd`.

### Automated keyd dual-role test (virtual keyboard, no human keypress)

`keyboard/tests/keyd-dualrole-uinput.py` creates a virtual keyboard with the
AT id `0001:0001`, restarts keyd so it is grabbed, injects keystrokes and
asserts on what keyd's own virtual keyboard emits:

```bash
sudo apt install -y python3-evdev
sudo python3 keyboard/tests/keyd-dualrole-uinput.py
# PASS: tap Search -> CAPSLOCK only (no META, no guard)
# PASS: hold Search + <each top-row key> -> F1 ... F10 (all ten;
#        LEFTCTRL chord guard from the [meta:M] layer is expected)
# PASS: <each top-row key> alone -> its media key (all ten)
# PASS: hold Search alone -> bare META release (no guard)
# RESULT=PASS
```

> This test injects keycodes **after** the hwdb translation, so it cannot catch
> a wrong scancode. That is exactly how an entirely dead hwdb block passed this
> test before 2026-10-31. Always pair it with the scancode check above.
>
> It also restarts keyd twice, so the real keyboard is unmapped for about a
> second. Run it from a TTY/SSH session or accept the short interruption.

### Passive capture of real key presses (safe)

`keyboard/tests/capture-keyd-output.py` reads keyd's virtual keyboard read-only,
so the desktop keeps receiving input while it runs:

```bash
sudo apt install -y python3-evdev
sudo python3 keyboard/tests/capture-keyd-output.py --seconds 120
# 18:14:47 KEY_LEFTMETA 1     <- hold Search (Super), 2026-10-31
# 18:14:47 KEY_LEFTMETA 2     <- autorepeat while held
# 18:14:50 KEY_LEFTMETA 0     <- bare release: no LEFTCTRL guard
# 18:14:52 KEY_CAPSLOCK 1     <- tap Search (CAPSLOCK only)
# 18:14:52 KEY_CAPSLOCK 0
# 18:15:18 KEY_F1 1           <- hold Search + Back (F2-F10 work the same)
```

**Never grab the keyd virtual keyboard** (`evtest --grab`, `evemu-record
--grab`, raw `EVIOCGRAB`): a grab takes the device away from the compositor and
the whole desktop keyboard stops working until the tool exits. Plain `evtest`
with no `--grab` is read-only and safe. Once keyd grabs the physical AT
keyboard, other readers cannot see its events at all — that is why this capture
tool reads the keyd virtual keyboard instead. `keyd monitor` is not a substitute
either: keyd 2.5.x cannot open a device it has already grabbed, so the internal
keyboard never appears there.

### Reading `udevadm test` output

`udevadm test /sys/class/input/event2` prints `No entry found from hwdb` for the
generic lookups (`evdev:`, `evdev:name:`, `evdev:name:...:phys:...`). Only the
`evdev:atkbd:$attr{[dmi/id]modalias}` line matters; when it applies
`KEYBOARD_KEY_*`, the mapping is live. Real Dratini firmware reports extra
`br0.0:efr0.0` fields between `bd*` and `svn*`, which `bd*:svnGoogle*` still
matches (verified 2026-10-31).

### Real-hardware validation log (HP Pro c640 / Dratini, 2026-10-31)

Environment: Ubuntu 26.04 LTS, kernel `7.0.0-38-generic`, `keyd 2.5.0-5`
(binary `/usr/bin/keyd.rvaiya`), `python3-evdev 1.9.3`, GNOME Wayland session.

> **Evidence version scope:** syntax (`keyd check`) is validated in CI with
> keyd **2.6.0**; the tap/hold/chord-guard behaviour below was validated on the
> real machine with **2.5.0-5** only. Other versions are **unverified** —
> upstream 2.6.x has known `overloadt2` behaviour differences, so do not read
> the 2.6.0 CI syntax check as behavioural validation of 2.6.0.

> Rows marked **uinput** use a virtual keyboard that injects keycodes *after*
> hwdb; they prove the keyd configuration, not that the physical keyboard emits
> those scancodes. Rows marked **passive capture** read keyd's virtual keyboard
> while the real keys were pressed.

| Check | Result | Evidence |
| :--- | :---: | :--- |
| hwdb live translation | 🟢 | `check-top-row-hwdb.py` (2026-10-31 19:45:29, `EVIOCGKEYCODE` on the real keyboard): all 11 entries OK - `0x3b`→`KEY_BACK`, `0x40`→`KEY_BRIGHTNESSDOWN`, `0x42`→`KEY_MUTE`, `0xdb`→`KEY_LEFTMETA` |
| keyd grabs only the internal keyboard | 🟢 | journal: `match 0001:0001 ... (AT Translated Set 2 keyboard)`; `ignoring 0000:0006 (Video Bus)` |
| Tap Search (uinput) | 🟢 | uinput test (2026-10-31 19:45:37): `CAPSLOCK` down/up only - no `META`, no guard pair |
| Hold Search alone (uinput) | 🟢 | uinput test (19:45:37): `LEFTMETA` down, repeats, bare `LEFTMETA` up - no `LEFTCTRL` guard, so Mutter opens the overview |
| Hold Search + top row (uinput) | 🟢 | uinput test (19:45:37): all ten chords `Back`→`F1`, `Forward`→`F2`, `Refresh`→`F3`, `F11`→`F4`, `Scale`→`F5`, `BrightnessDown`→`F6`, `BrightnessUp`→`F7`, `Mute`→`F8`, `VolumeDown`→`F9`, `VolumeUp`→`F10` |
| Top row alone (uinput) | 🟢 | uinput test (19:45:37): all ten keys pass through as their media keycode (`KEY_BACK` ... `KEY_VOLUMEUP`) |
| Physical hold Search, release (passive capture) | 🟢 | `18:14:47-18:14:50`: `LEFTMETA` down + repeats, bare `LEFTMETA` up (**no `LEFTCTRL`**); GNOME Activities opened (confirmed on screen) |
| Physical tap Search (passive capture) | 🟢 | `18:14:52`: `CAPSLOCK` down/up only |
| Physical single press of brightness/mute/volume (passive capture) | 🟢 | `18:14:59-18:15:07`: `KEY_BRIGHTNESSDOWN`/`KEY_BRIGHTNESSUP`/`KEY_MUTE`/`KEY_VOLUMEDOWN`/`KEY_VOLUMEUP`; screen brightness and audio volume changed (confirmed on screen) |
| Physical hold Search + Back (passive capture) | 🟢 | `18:15:18`: `KEY_F1` down/up (meta layer); keyd's layer modifier emits a `LEFTCTRL` guard around chord presses, which is expected and does not affect the lone-hold case |
| LED node permissions | 🟢 | `-rw-rw---- root plugdev` on `chromeos::kbd_backlight/brightness` after `udevadm trigger --subsystem-match=leds`; user write succeeds without sudo |
| Daemon blank/unblank | 🟢 | `--test-blank` 2 → 0, `--test-unblank` 0 → 2, state file `0600` and removed |
| Daemon event path | 🟢 | `gdbus emit ... ScreenSaver.ActiveChanged true/false` → brightness 2 → 0 → 2 with **no `sudo` calls** in the user journal |
| Sleep hook | 🟢 | **2026-10-31 OLD hook behaviour (historical only; no longer valid):** `pre suspend` saved 6, simulated 0, `post suspend` restored 6, state file removed (hook invoked directly in that session). The hook is now a **pure handoff writer** that never writes brightness or deletes state; a full real S3 freeze/thaw cycle was validated later on 2026-11-22 — see [verification.md](../docs/verification.md) |
| `--check` | 🟢 | all green, including "backlight node writable by group plugdev (mode 660)" |

**History (fixed 2026-10-31):** the earlier passive captures at `12:49`, `13:25`
and `13:26` showed `KEY_F1`/`KEY_F6` and were initially recorded as proof of the
keyd meta layer. They were not: the post-hwdb `EVIOCGKEY` state showed plain
`F1`-`F10`, hwdb was mapping ChromeOS action scancodes (`0xea`-`0xb0`) copied
from other Chromebooks, which this hardware never emits, and single presses of
the media keys did nothing. Those rows were removed after the post-hwdb
evidence and AT-table inference led to the corrected hwdb map, and the post-fix
capture above replaced them. The passive capture proves the presses reach the
desktop as `EV_KEY`; there is no raw
`MSC_SCAN` capture in the evidence — that still requires `--scan` after
stopping keyd.

**Pitfalls found on real hardware (now fixed in this repo):**

1. Ubuntu 26.04's `keyd` package ships `/usr/bin/keyd.rvaiya`; `keyd` is not in
   `$PATH`. Use `keyd_bin()` / `command -v keyd keyd.rvaiya`.
2. keyd 2.5.x has no `check` subcommand, and no device hot-plug detection: the
   installer must `systemctl restart keyd` after deploying `/etc/keyd/cros.conf`,
   otherwise the old (or no) mapping stays active.
3. `[ids] *` also grabs the ChromeOS `Video Bus`; scope to `0001:0001`.
4. udev `MODE=`/`GROUP=`/`uaccess` do **not** chmod sysfs LED attributes. The
   backlight daemon therefore needs `RUN+=chgrp plugdev` + `RUN+=chmod 0660` in
   `61-chromeos-kbd-backlight.rules`, otherwise it falls back to `sudo -n tee`,
   which a user service cannot answer.
5. Plain `overload(meta, ...)` is wrong for the GNOME overview: keyd's
   modifier guard wraps the bare Meta release in a `LEFTCTRL` tap, so Mutter
   treats it as `Meta+Ctrl` and never opens Activities. `overloadt2(meta,
   capslock, 200)` defers the decision and releases the layer without the guard.
   A tap also stops emitting `META` entirely, so tests can assert
   "CAPSLOCK only".
6. A user `uinput` device is only grabbed by keyd if it exposes the full
   `keyboard_mask` (`KEY_1..0`, `Q..Y`) or `KEY_BRIGHTNESSUP`; adding a single
   `KEY_LEFTMETA` is not enough.
7. Grabbing the keyd virtual keyboard (`EVIOCGRAB`, `evtest --grab`,
   `evemu-record --grab`) removes it from the compositor and kills all desktop
   keyboard input; plain `evtest` without `--grab` is read-only and safe. A
   physical keyboard grabbed by keyd is invisible to other readers, which is
   why verification uses the passive `capture-keyd-output.py` on the keyd
   virtual keyboard.
8. `udevadm test` reports `No entry found from hwdb` for the generic `evdev:`
   lookups even when the mapping works; only the `evdev:atkbd:` lookup applies
   `KEYBOARD_KEY_*`.
9. The top row on this machine is **inferred** to use standard AT scancodes
   `0x3b`-`0x44` (`KEY_F1`-`KEY_F10`) from post-hwdb `EVIOCGKEY` state against
   the AT table (kernel map confirmed via `EVIOCGKEYCODE`; raw `MSC_SCAN` not
   captured), not ChromeOS action scancodes (`0xea`, `0xe9`,
   ...). A hwdb file copied from another Chromebook can look correct,
   `udevadm info` can show `KEYBOARD_KEY_ea=back`, and the keyd uinput test can
   still pass, while every physical press stays a plain `F` key. Verify with
   `check-top-row-hwdb.py`, not with the mapping table alone.
10. `EVIOCGKEYCODE` shows the *map*; it does not prove the hardware emits those
    scancodes. `EVIOCGKEY` (`--listen` in the check script, or the
    `active_keys()` probe) shows the post-hwdb `KEY_*` code a real press
    produces, not the raw scancode. Read `EV_MSC/MSC_SCAN` with plain `evtest`
    (no `--grab`) or `--scan` after stopping keyd to obtain the raw scancode,
    then infer it against the standard AT table.
