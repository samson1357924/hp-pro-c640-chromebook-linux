# 🔄 Uninstallation & Rollback Guide

This project has a complete **lossless, idempotent & reversible** mechanism.
All files installed via `setup.sh` or the individual sub-modules are protected
by `/var/lib/cros-enablement/install-manifest.json` and
`/var/backups/cros-enablement/`.

---

## ⚡ One-Click Full Uninstallation

Run this inside the project directory:

```bash
./setup.sh --uninstall
```

This command automatically:

1. Removes the custom `sof-rt5682` UCM configuration files from `/usr/share/alsa/ucm2/`.
2. Removes keyboard hwdb & backlight sync (5 artifacts):
   `/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb` (+ `systemd-hwdb update`),
   `/etc/udev/rules.d/61-chromeos-kbd-backlight.rules` (+ `udevadm trigger`),
   `/usr/local/bin/c640-kbd-backlight-sync`,
   `/etc/systemd/user/c640-kbd-backlight-sync.service` (`--global disable` + per-user),
   `/usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh`, and cleans
   `/run/c640-kbd-backlight/state`.
3. Removes `/etc/udev/rules.d/60-cros-fp.rules`.
4. Removes the power management tweaks (logind config and suspend helpers).
5. Removes the EC tools, the 90% battery protection service, and the sleep hook.
6. Restores every file from the **first backup taken before this project ever
   touched it** (re-installs keep the original backup, so rollback always
   restores the pre-project state).
7. Restores the enabled/active state of systemd services the installer
   modified (`thermald`, `tlp`, `c640-battery-limit.service`,
   `c640-kbd-backlight-sync.service` with `scope: user` via `--global` + per-user
   `daemon-reload`, …) and removes **plugdev group memberships that the installer
   added** (memberships that existed before installation, or still required by
   other udev rules, are kept).
8. Removes the fingerprint encryption seed `/var/lib/fprint/crfpmoc.key` and
   shows the commands to reinstall the distro's native `libfprint` package.

### Rollback safety guarantees

Rollback consumes a manifest record only after that record's whole action has been
confirmed. If a guarantee below cannot be met, the record is **kept** in
`/var/lib/cros-enablement/install-manifest.json` with a warning and rc 1 — including
when no original backup exists — so a later `./setup.sh --uninstall` run can retry; it
is never silently treated as done. Other processable items still roll back normally,
but the final exit code is non-zero and `finished!` is not printed:

* **Unknown original state is never assumed false.** The safety fields
  `was_existing`, `was_enabled`, `was_active` and `was_member` are required. Rollback
  refuses to auto-restore an entry whose snapshot is missing or not a boolean: it leaves
  the file, service state and group membership untouched, warns
  (`RECORD_STATE_UNKNOWN` / `SERVICE_STATE_UNKNOWN`) and returns rc 1. Likewise, without
  a valid bool service snapshot the installer will not disable/stop `keyd`.
* **A target that was moved away is still restored.** For files that existed before
  installation, rollback always restores the **first (oldest) backup** — even if the
  installed file/symlink was removed in the meantime — staging it next to the target and
  swapping it in with a single atomic `os.replace()` (owner, mode and symlink target
  preserved). Regular files and symlinks are **never unlinked first**, so a failed swap
  leaves the installed target untouched; any swap involving a directory (including dir→dir)
  briefly moves the old entry aside and back if it fails. With no backup available it keeps the
  record, warns (`[WARN NO BACKUP]`), logs `RECORD_BACKUP_MISSING` /
  `ROLLBACK_INCOMPLETE` and returns rc 1 rather than creating a fake file.
* **A failed service restore keeps its record.** Every `systemctl` enable/disable/start/
  stop return code is checked (timeouts, stderr and spawn errors included). A failed
  restore logs `SERVICE_RESTORE_FAILED` / `ROLLBACK_INCOMPLETE`, keeps the service record
  for a retry and returns non-zero instead of silently claiming success.
* **Group membership is recorded before it is changed.** The installer snapshots the
  original `plugdev` membership first and only then checks `usermod` rc explicitly. If
  the change fails it removes the record it just wrote (unless an older one existed), so
  uninstall will not later drop a membership the user obtained on their own.
* **Concurrent install/uninstall runs cannot lose tracking records or leave untracked
  deployments.** Each component installer takes ONE operation-level lock around its whole
  transaction — backup/record → deploy files and services → finish or rollback — through
  `run_manifest_operation()` in `lib/backup.sh`. Nested helpers (the backup gate, group
  helpers, the keyd-link normalizer and `rollback_component()`) re-enter the same lock via
  `MANIFEST_LOCK_DEPTH`, so a concurrent uninstall cannot consume a just-written
  `was_existing=false` record while the target file is still absent — which would leave a
  deployed file on disk with no manifest record and no way to remove it later. The lock is
  acquired before the fail-closed validation gate and held through the final atomic replace,
  and every manifest read-modify-write re-reads the document inside it, so one process's
  first-wins backup/service/group records cannot be overwritten by another. Each writer uses
  a unique `.install-manifest.*.tmp` file in the manifest directory (fsync + `chmod 0644` +
  `os.replace`) so parallel writers cannot clobber each other's temporary file. `DRY_RUN`
  takes no lock and creates no lock file.
* **The lock file is root-only and safe against hostile paths.**
  `$MANIFEST_DIR/.install-manifest.lock` is a root-owned `0600` regular file (an older `0644`
  lock is upgraded on first use), so an unprivileged peer account cannot even open it, let
  alone hold an exclusive `flock` and starve every installer for the whole wait window — a
  non-root shell can still run an installer because acquisition is delegated to a short-lived
  root helper started via passwordless `sudo`. That helper is launched with `coproc sudo bash
  -c`: it owns fd 9, takes the bounded `flock -x -w` wait (`CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT`,
  default 10s), prints `READY`, then blocks reading its stdin. Closing the parent's write fd
  makes the helper see EOF, exit and let the kernel release the flock, so a crash or `kill -9`
  cannot leave a stale lock (there is deliberately no EXIT/INT/TERM trap). Symlinks and
  non-regular lock files are refused, the parent directory must be owned by root or the
  current user and must not be group/other-writable (`mode & 022 == 0`, so keep
  `/var/lib/cros-enablement` at `0755`), and the root helper compares the `(dev,ino)` of fd 9
  (via `/proc/$$/fd/9`) with the lock path and checks fd owner `0`, mode `600` and regular-file
  type — all inside the process that actually holds fd 9 — so an inode swap during init or
  while waiting for `flock` fails closed. Missing `flock`, a timeout or any failed check
  leaves the manifest bytes intact and returns rc 1.
* **Long-running operations may need a larger lock timeout.**
  `fingerprint/install-fingerprint.sh --source` holds the operation lock across the
  `git clone`/build/compile steps, so a parallel install/uninstall can hit the default 10s
  wait and fail closed. Raise `CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT` (for example to `300`)
  before starting a parallel operation in that window.

---

## 🛠️ Per-Module Uninstallation

* **Remove only the audio UCM configuration**:

  ```bash
  ./audio/install-audio.sh --uninstall
  ```

* **Remove only the fingerprint udev rules, PAM config and system-sleep
  hook**:

  ```bash
  ./fingerprint/install-fingerprint.sh --uninstall
  ```

  *(This restores the backed-up `libfprint` libraries and `60-cros-fp.rules`,
  reverts the `pam_fprintd` PAM changes (`/etc/pam.d/sudo` back to stock,
  fprintd out of `common-auth`), removes the `fprintd-sleep.sh` system-sleep
  hook, removes `/var/lib/fprint/crfpmoc.key` and the plugdev membership the
  installer added, and rolls the service states back.)*

* **Remove only the keyboard top-row mapping & backlight sync** (5 artifacts above):

  ```bash
  ./keyboard/install-keyboard.sh --uninstall
  ```

  > This removes all 5 keyboard artifacts, disables the user service globally,
  > restores brightness to 50% if left at 0, cleans `/run/c640-kbd-backlight/state`
  > and `/run/user/$UID/c640-kbd-backlight.state`, and drops installer-added
  > `plugdev` membership (keeps pre-existing memberships).
  >
  > If you installed with `--with-keyd`, it also removes `/etc/keyd/cros.conf`
  > and any legacy `/etc/keyd/default.conf` symlink that pointed to `cros.conf`
  > (restoring the pre-install backup when one exists) and disables the `keyd`
  > service.

* **Remove only the power management tweaks** (logind config, suspend
  helpers, TLP config, thermald service enablement):

  ```bash
  ./power/install-power.sh --uninstall
  ```

  > [!WARNING]
  > After uninstalling the power module, **reboot** (or log out and back in)
  > — do **not** run `systemctl restart systemd-logind`. With an active
  > desktop session, restarting `systemd-logind` logs everyone out (the
  > session leader is lost on deserialization), which looks exactly like a
  > system crash (verified on an HP Pro c640, 2026-08-18).

* **Remove only the EC tools and services** (including the 90% battery
  protection `c640-battery-limit.service` and `c640-ec-sleep.sh`):

  ```bash
  ./ec/install-ec.sh --uninstall
  ```

---

## 🔋 Note: 90% Battery Protection Service

`./ec/install-ec.sh --enable-battery-limit` installs and starts
`c640-battery-limit.service`, which keeps the battery at 90% charge to
prolong its lifespan. It is removed automatically by
`./ec/install-ec.sh --uninstall` and by `./setup.sh --uninstall`.

> [!NOTE]
> **State left behind after uninstall**: uninstallation automatically
> restores standard 100% full charging (`battery-full`) and automatic fan
> control (`fan-auto`). The `plugdev` group itself is not removed (other
> components or system packages may rely on it), only installer-created
> memberships are dropped. `/dev/cros_ec` keeps mode `0660` until the device
> is re-plugged or the machine reboots.

## 📦 Restore Distro Native Packages

If you compiled and installed the `crfpmoc` `libfprint`, you can reinstall the
distro's native version through your package manager:

* **Ubuntu / Debian**:

  ```bash
  sudo apt install --reinstall -y libfprint-2-2
  ```

* **Fedora**:

  ```bash
  sudo dnf reinstall -y libfprint
  ```

* **Arch Linux**:

  ```bash
  sudo pacman -S --overwrite='*' libfprint
  ```

* **openSUSE**:

  ```bash
  sudo zypper install --force libfprint-2-2
  ```
