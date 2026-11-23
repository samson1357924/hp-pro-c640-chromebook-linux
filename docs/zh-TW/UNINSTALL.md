[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# 🔄 系統復原與解除安裝指南 (Uninstallation & Rollback)

本專案具備完整的**無損撤銷（Idempotent & Reversible）**機制。所有透過
`setup.sh` 或各子模組安裝的檔案均受到 `/var/lib/cros-enablement/install-manifest.json`
與 `/var/backups/cros-enablement/` 的保護。

---

## ⚡ 一鍵全自動解除安裝

在專案目錄下執行：

```bash
./setup.sh --uninstall
```

該指令會全自動執行：

1. 移除 `/usr/share/alsa/ucm2/` 中的 `sof-rt5682` 自訂 UCM 設定檔。
2. 移除鍵盤 hwdb 與背光同步（5 項）：
   `/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb`（+ `systemd-hwdb update`）、
   `/etc/udev/rules.d/61-chromeos-kbd-backlight.rules`（+ `udevadm trigger`）、
   `/usr/local/bin/c640-kbd-backlight-sync`、
   `/etc/systemd/user/c640-kbd-backlight-sync.service`（`--global disable` + per-user）、
   `/usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh`，並清除
   `/run/c640-kbd-backlight/state`。
3. 移除 `/etc/udev/rules.d/60-cros-fp.rules`。
4. 移除電源管理調校（logind 設定與休眠輔助）。
5. 移除 EC 工具、90% 電池保護服務與休眠喚醒鉤子。
6. 從**本專案首次安裝前的最早備份**還原每個檔案（重裝會保留第一次備份，
   因此 rollback 永遠還原到專案介入前的狀態）。
7. 還原安裝器曾修改的 systemd 服務啟用/運作狀態（`thermald`、`tlp`、
   `c640-battery-limit.service`、`c640-kbd-backlight-sync.service` 的 `scope: user`
   經 `--global` + per-user `daemon-reload` 等），並移除**安裝器新增的 plugdev 群組成員**
   （安裝前已存在、或仍被其他 udev 規則引用的成員資格會被保留）。
8. 移除指紋加密種子 `/var/lib/fprint/crfpmoc.key`，並提示發行版重裝原生
   `libfprint` 套件的指令。

### Rollback 安全保證

rollback 只有在某筆紀錄的整個動作都確認成功後才會消耗它。若下列保證無法達成，紀錄會
**保留**在 `/var/lib/cros-enablement/install-manifest.json`，附上警告並回 rc 1（找不到
原始備份時也一樣），供日後再次執行 `./setup.sh --uninstall` 重試——絕不會被當成已完成
而悄悄略過。其他可處理的項目仍會正常 rollback，但最終結束碼非 0，且不會印出
`finished!`：

* **原始狀態未知絕不當成 false。** 安全欄位 `was_existing`、`was_enabled`、`was_active`、
  `was_member` 為必填。若快照缺失或不是布林，rollback 拒絕自動還原該筆紀錄：檔案、
  服務狀態與群組 membership 都保持原樣，記錄警告（`RECORD_STATE_UNKNOWN` /
  `SERVICE_STATE_UNKNOWN`）並回 rc 1。同樣地，沒有有效的布林服務快照時，安裝器也不會
  停用/停止 `keyd`。
* **目標被移走時仍會還原。** 對安裝前就存在的檔案，rollback 一律從**第一份（最早）
  備份**還原——即使期間安裝的檔案/symlink 已被移除——先暫存到目標旁，再以單次原子
  `os.replace()` 取代，並保留 owner、mode 與 symlink 目標。普通檔案與 symlink **不會先
  unlink**，因此取代失敗時已安裝的目標仍保持原樣；任何涉及目錄的交換（含 dir→dir）
  都會短暫把舊項目移到一旁並在失敗時移回。找不到備份時會保留紀錄、警告（`[WARN NO BACKUP]`）、記錄
  `RECORD_BACKUP_MISSING` / `ROLLBACK_INCOMPLETE` 並回 rc 1，不會憑空建立檔案。
* **服務還原失敗就保留紀錄。** 每一次 `systemctl` enable/disable/start/stop 都會檢查
  回傳碼（含 timeout、stderr 與 spawn error）。還原失敗時會記錄
  `SERVICE_RESTORE_FAILED` / `ROLLBACK_INCOMPLETE`、保留服務紀錄供重試，並回傳非 0，
  而不是謊稱成功。
* **先記錄群組 membership 再變更。** 安裝器先把原始 `plugdev` 成員資格寫入 manifest，
  之後才明確檢查 `usermod` 的 rc。若變更失敗，就移除剛寫入的紀錄（除非已有較早的
  紀錄），以免日後 uninstall 移除使用者自行取得的成員資格。
* **並行的安裝/解除安裝不會遺失追蹤紀錄，也不會留下未追蹤的部署。** 每個元件安裝器
  透過 `lib/backup.sh` 的 `run_manifest_operation()`，在**整個元件操作交易**——備份/紀錄 →
  部署檔案與服務 → 完成或回滾——只取得一把操作級鎖。巢狀 helper（備份 gate、群組 helper、
  keyd-link 正規化與 `rollback_component()`）透過 `MANIFEST_LOCK_DEPTH` 重入同一把鎖，因此
  並行的 uninstall 不會在目標檔仍缺席時消耗剛寫入的 `was_existing=false` 紀錄——那會讓已
  部署的檔案留在磁碟上卻沒有 manifest 紀錄，日後也無法移除。鎖在 fail-closed 驗證 gate
  之前取得，並持續持有到最終原子取代完成；每一次 manifest read-modify-write 都在鎖內
  重新讀取文件，因此某程序 first-wins 的備份/服務/群組紀錄不會被另一程序覆寫。每個
  writer 使用 manifest 目錄中唯一的 `.install-manifest.*.tmp` 暫存檔（fsync + `chmod 0644`
  與 `os.replace`），避免平行 writer 互相覆寫暫存檔。`DRY_RUN` 不取鎖，也不建立鎖檔。
* **鎖檔為 root-only，並能防範惡意路徑。** `$MANIFEST_DIR/.install-manifest.lock` 是
  root 擁有的 `0600` 普通檔（舊版 `0644` 鎖會在首次使用時升級），因此非特權的 peer 帳號
  連開啟都做不到，更無法握住 exclusive `flock` 在整個等待期間阻塞所有安裝器——非 root
  shell 仍能執行安裝器，因為取得鎖的工作交給了透過 passwordless `sudo` 啟動的短暫 root
  helper。該 helper 以 `coproc sudo bash -c` 啟動：它持有 fd 9、執行有界的 `flock -x -w`
  等待（`CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT`，預設 10 秒）、印出 `READY`，然後阻塞讀取
  stdin。關閉父行程的 write fd 會讓 helper 看到 EOF、結束並讓核心釋放 flock，因此崩潰或
  `kill -9` 不會留下 stale lock（刻意不安裝 EXIT/INT/TERM trap）。symlink 與非普通檔的鎖
  會被拒絕；父目錄必須由 root 或目前使用者擁有，且不可群組/其他可寫（`mode & 022 == 0`，
  因此 `/var/lib/cros-enablement` 請維持 `0755`）；root helper 並在**實際持有 fd 9 的行程內**
  比對 `/proc/$$/fd/9` 的 `(dev,ino)` 與鎖路徑，檢查 fd owner 為 `0`、mode 為 `600`、
  型別為普通檔，因此 init 期間或等待 `flock` 期間的 inode 替換都會 fail closed。缺少
  `flock`、逾時或上述任何檢查失敗都會保持 manifest 位元組不變並回 rc 1。
* **長時間操作可能需要調高鎖等待上限。** `fingerprint/install-fingerprint.sh --source`
  會在 `git clone`/建置/編譯期間持續持有操作鎖，因此平行的安裝/解除安裝可能撞上預設
  10 秒等待而 fail closed。在該時段啟動平行操作前，請調高
  `CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT`（例如設為 `300`）。

---

## 🛠️ 單一模組獨立解除安裝

* **僅移除音訊 UCM 配置**：

  ```bash
  ./audio/install-audio.sh --uninstall
  ```

* **僅移除指紋 udev 規則、PAM 設定與 system-sleep hook**：

  ```bash
  ./fingerprint/install-fingerprint.sh --uninstall
  ```

  *（會還原備份的 `libfprint` 函式庫與 `60-cros-fp.rules`、將
  `pam_fprintd` 的 PAM 變更還原（`/etc/pam.d/sudo` 回到 stock、fprintd
  移出 `common-auth`）、移除 `fprintd-sleep.sh` system-sleep hook、移除
  `/var/lib/fprint/crfpmoc.key` 與安裝器新增的 plugdev 成員資格，並還原
  服務狀態。）*

* **僅移除鍵盤頂排映射與背光同步**（上述 5 項）：

  ```bash
  ./keyboard/install-keyboard.sh --uninstall
  ```

  > 此操作會移除全部 5 項鍵盤相關檔案、全域停用 user service、
  > 若背光停留在 0 則恢復為 50%、清除 `/run/c640-kbd-backlight/state` 與
  > `/run/user/$UID/c640-kbd-backlight.state`，並移除安裝器新增的 `plugdev`
  > 成員（保留原本已存在的成員）。
  >
  > 若當初使用 `--with-keyd` 安裝，也會移除 `/etc/keyd/cros.conf` 與
  > 舊版指向 `cros.conf` 的 `/etc/keyd/default.conf` symlink（有安裝前備份時會
  > 還原），並停用 `keyd` 服務。

* **僅移除電源管理調校**（logind 設定、休眠輔助、TLP 設定、thermald 服務啟用）：

  ```bash
  ./power/install-power.sh --uninstall
  ```

  > [!WARNING]
  > 移除電源模組後請**重新開機**（或登出再登入）——**不要**執行
  > `systemctl restart systemd-logind`。在有登入 session 的桌面環境中重啟
  > `systemd-logind` 會登出所有人（session leader 在 deserialization 時遺失），
  > 外觀上與系統當機完全相同（HP Pro c640 實測，2026-08-18）。

* **僅移除 EC 工具與服務**（含 90% 電池保護 `c640-battery-limit.service` 與 `c640-ec-sleep.sh`）：

  ```bash
  ./ec/install-ec.sh --uninstall
  ```

---

## 🔋 附註：90% 電池保護服務

`./ec/install-ec.sh --enable-battery-limit` 會安裝並啟動 `c640-battery-limit.service`，
將電池充電上限維持在 90% 以延長壽命。執行 `./ec/install-ec.sh --uninstall` 或
`./setup.sh --uninstall` 時會一併移除。

> [!NOTE]
> **解除安裝後之狀態還原**：解除安裝時會全自動將充電模式恢復為標準 100% 完整充電
> （`battery-full`）並還原自動風扇溫控（`fan-auto`）。`plugdev`
> 群組本身不會被移除（其他元件或系統套件可能仍依賴它），只會移除安裝器
> 新增的成員資格。`/dev/cros_ec` 會維持 `0660` 權限直到裝置重新插拔或重開機。

## 📦 發行版原生套件還原

若您曾編譯並安裝過 `crfpmoc` 的 `libfprint`，可透過系統套件管理員重新安裝發行版
原生版本：

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
