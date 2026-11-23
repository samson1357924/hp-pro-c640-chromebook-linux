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
   added**. Ownership is decided from every component's original-state record,
   so memberships that existed before installation, or still required by other
   udev rules, are kept, and the uninstall order of the modules does not matter.
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
* **plugdev ownership is decided across all components, and stale records are refreshed.**
  A full install can write two records for the same `(group,user)` (for example keyboard
  records `was_member=false` and fingerprint later records `was_member=true`). The shared
  ownership probe returns rc 0 when at least one record is explicitly `was_member=false`
  (we added the membership), rc 1 when there is **no** record for the pair, rc 3 when
  **every** record is `was_member=true` (pre-existing), and rc 2 for a missing/wrong-type
  field (fail closed, change nothing). first-wins is unchanged: any `false` authorizes
  `gpasswd -d`, and a udev rule that still references the group keeps the membership.
  After a successful `gpasswd -d` all records for that pair are consumed together
  (including a sibling's `true`), so uninstalling fingerprint before keyboard — or the
  reverse — gives the same result. On **rc 3** no `gpasswd` runs at all (all-true means we
  never added the user): if a udev rule still references the group the snapshot is kept;
  once no rule references it — the signal that every component using the group is gone —
  all stale records are consumed **with zero `gpasswd` calls**, so the next install takes
  a fresh snapshot of the real, possibly admin-changed membership. A consume failure
  fails closed and keeps the records for retry. `gpasswd -d` failure logs an error and
  returns rc 1 (the three uninstallers fold it into their exit code); no "removed" success
  is reported, and the records stay for a later retry.
* **PAM files are restored by rollback only; uninstall never deletes a pre-existing line.**
  `disable_pam_fingerprint()` performs **no sed and no direct edit** of `/etc/pam.d/sudo`
  (or any distro PAM file). All bytes come from the first backup via
  `rollback_component("fingerprint")`, so an exact `pam_fprintd` line that was already
  present before installation is preserved. On Debian/Ubuntu, Tier 2 backs up every
  `common-*` file that actually contains `pam_fprintd.so`, then removes **only those module
  lines with a direct `sed -i '/pam_fprintd\.so/d'`**. The installer never calls
  `pam-auth-update --remove fprintd`: that action also deletes debconf's
  `libpam-runtime/profiles` selection, a persistent state the manifest cannot restore.
  Direct line removal reaches the same goal (`common-auth` has no fp line, so GDM's
  `gdm-password` include cannot win the device claim) while leaving the selection intact —
  a later `pam-auth-update` regenerates the **original** stack. Uninstall calls no profile
  tool at all; the original `common-*` bytes come back from rollback. Trade-off: if an
  administrator runs `pam-auth-update --force` during installation, the still-enabled
  selection can write the fp line back into `common-auth` (briefly restoring the GDM race);
  that is non-persistent and rollback restores the files. After uninstall the selection is
  the original one — if fprintd was originally enabled, later tool runs regenerate the
  original fp-containing stack, which is by definition the original state. A read-only
  post-rollback check warns if a manifest record still covers `/etc/pam.d/sudo` (manual
  cleanup may be needed) or if the manifest is corrupt — it never modifies a file. Fedora
  `authselect` and openSUSE `pam-config` profile state is outside the manifest: the tool
  calls remain but a warning asks you to restore any pre-existing profile manually.
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
  non-regular lock files are refused. `CROS_ENABLEMENT_MANIFEST_DIR` must be an **absolute
  path** (otherwise `must be an absolute path`), and **any literal symlink component is
  rejected** — even a root-owned, otherwise safe one — logging `contains a symlink` and
  `untrusted symlink`. This is a deliberate fail-closed choice: a symlink can hide a real
  target in a user-writable tree whose owner could rename the lock. The gate canonicalizes
  the deepest existing prefix with `realpath -e` and re-appends the missing layers
  (first-time creation is still supported), then runs the root-controlled check on the
  **real** path — a non-root-controlled canonical ancestor logs `untrusted realpath
  ancestor`. The direct parent must be **root-owned** — a caller-owned parent can rename a
  live lock inode, so ownership by the current EUID/UID no longer qualifies and a wrong
  owner logs `must be root-owned` — and must not be group/other-writable (`mode & 022 == 0`,
  so keep `/var/lib/cros-enablement` at `0755`). Every ancestor is also checked: a
  non-root-owned or group/other-writable layer without a sticky bit fails closed with
  `not root-controlled` (a root-owned sticky world-writable layer such as `/tmp` `1777` is
  allowed). A custom lock parent under a user-writable tree is therefore refused. The root helper
  compares the `(dev,ino)` of fd 9 (via `/proc/$$/fd/9`) with the lock path and
  checks fd owner `0`, mode `600` and regular-file type — all inside the process that actually
  holds fd 9 — so an inode swap during init or while waiting for `flock` fails closed.
  Inside that same process the holder also re-derives `realpath -e "$dir"` and requires it
  to equal the handed-in directory, otherwise it prints `FAILED:canonical`; every real
  ancestor must be uid `0` and either not group/other-writable or root-owned with a sticky
  bit, otherwise `FAILED:ancestor`. The holder also pins the direct parent with **fd 8**,
  re-checking uid `0`, `mode & 022 == 0`, directory type and the parent's `(dev,ino)` against
  the pathname; any mismatch prints `FAILED:parentdir` and aborts before the lock is taken,
  defeating a rename that would let a second process lock a fresh inode while the first
  holder is live. Missing `flock`, a timeout or any failed check leaves the manifest bytes
  intact and returns rc 1.
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

  *(This restores the backed-up `libfprint` libraries, `60-cros-fp.rules` and
  sudo/`common-*` PAM bytes via manifest rollback — uninstall never sed-edits
  `/etc/pam.d/sudo`, and a `pam_fprintd` line already present is kept. It removes
  the `fprintd-sleep.sh` system-sleep hook and `/var/lib/fprint/crfpmoc.key`,
  drops the installer-added plugdev membership (ownership decided across all
  components), and rolls the service states back.)*

* **Remove only the keyboard top-row mapping & backlight sync** (5 artifacts above):

  ```bash
  ./keyboard/install-keyboard.sh --uninstall
  ```

  > This removes all 5 keyboard artifacts, disables the user service globally,
  > restores brightness to 50% if left at 0, cleans `/run/c640-kbd-backlight/state`
  > and `/run/user/$UID/c640-kbd-backlight.state`, and drops installer-added
  > `plugdev` membership (ownership decided across all components;
  > pre-existing memberships kept; a `gpasswd -d` failure returns rc 1).
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
