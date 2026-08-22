[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# 🛠️ 疑難排解與避坑 FAQ (Troubleshooting & Pitfall Guide)

本文整理了在 **HP Pro c640 Chromebook (Google `dratini`)** 安裝與使用 Linux 時
最常遇到的十五大問題與根本解決之道。

---

## 🔊 音效問題 (Audio)

### 1. 系統音效顯示 "Dummy Output" (虛擬輸出)，完全無聲

* **根本原因**：標準發行版的 `alsa-ucm-conf` 尚未將 `sof-rt5682` 下游配置納入
  主幹。PipeWire ACP 機制因 ASoC 晶片缺乏 Phantom Jack kcontrol 而誤判所有輸出
  不可用， WirePlumber 只能選擇 off。
* **解決方法**：執行本專案一鍵安裝指令：

  ```bash
  ./setup.sh --audio
  ```

### 2. 核心日誌出現 `cl_dsp_init: timeout with rom_status_reg`，音效卡遺失

* **根本原因**：**Intel Management Engine (ME) 被關閉**。Intel Comet Lake SOF
  DSP 韌體在開機與時脈初始化時強烈依賴 Intel ME 通訊。
* **解決方法**：**嚴禁使用 me_cleaner 或在 UEFI 設定中停用 Intel ME**。請確保
  MrChromebox UEFI 韌體中的 Intel ME 為啟用狀態。

### 3. 耳機插入後喇叭仍出聲，或無法自動切換

* **解決方法**：重新啟動當前使用者的 WirePlumber 服務：

  ```bash
  systemctl --user restart wireplumber
  ```

### 4. 從休眠 (Sleep/Resume) 喚醒後音效啞音

* **解決方法**：

  ```bash
  systemctl --user restart wireplumber pipewire
  ```

---

## 🖐️ 指紋辨識問題 (Fingerprint)

### 5. 執行 `fprintd-enroll` 提示 `/dev/cros_fp: Permission denied`

* **根本原因**：當前使用者尚未加入 `plugdev` 群組，或 udev 權限規則未重新載入。
* **解決方法**：

  ```bash
  sudo usermod -aG plugdev "$USER"
  sudo cp fingerprint/60-cros-fp.rules /etc/udev/rules.d/
  sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=misc
  ```

  *(完成後請登出並重新登入)*

### 6. 開機登入時指紋無效，但鎖定螢幕與 `sudo` 可以用指紋解鎖

* **根本原因**：這是 Linux 桌面（如 GNOME / GDM）的安全性架構設計。**GNOME
  Keyring (儲存 Wi-Fi 密碼、瀏覽器密碼之鑰匙圈) 需要使用者的明文密碼進行解密**。
* **解決方法**：冷開機首次登入需輸入一次密碼以解鎖 Keyring，之後的所有鎖定螢幕
  (`Super + L`)、休眠喚醒、PAM 授權與 `sudo` 均可直接秒按指紋。

### 7. 重開機後指紋完全失效（`command failed: UNAVAILABLE` / `INVALID_PARAM`）

* **症狀**：重開機之後，GDM 登入、鎖定螢幕 (`Super + L`)、`sudo` 或任何
  `fprintd-verify` 都不再辨識指紋；`journalctl -u fprintd` 顯示
  `Device reported an error during verify: command failed: UNAVAILABLE`
  （首次嘗試有時會是 `INVALID_PARAM`）。
* **根本原因（分兩層）**：
  1. **協定層** —— FPC1025 Match-on-Chip 感應器由 ChromeOS FPMCU 驅動。FPMCU 上有兩個東西：
     **seed 與 user context (`user_id`)**，兩者都在 FPMCU 的 **RAM（不是 flash）** 裡：seed（與
     `SEED_SET` 旗標）只在*暖*重開機（FPMCU 持續供電）時保留，*冷*重開機會遺失、由主機從
     `/var/lib/fprint/crfpmoc.key` 重新送 `FP_SEED`。crfpmoc driver 的 keys 交握包含一個
     `FP_CONTEXT` 步驟，它會 (1) 重新建立加解密 context，並 (2) 觸發 FPMCU 感應器的
     reset/open（`fp_sensor_open`，約 175 ms）把感應器重新初始化。若該步驟在「seed 已設」時被跳過，
      重開機後感應器就停在未初始化狀態，所有模板操作都會回傳 `EC_RES_UNAVAILABLE`。此問題由某個舊版
      driver（「seed 已設時直接跳到 KEYS_DONE」的那一版）引入。另一個潛在 bug 是 `RESET_SENSOR` 與
     `FP_MODE_FINGER_UP` 的模式衝突（會噴 `INVALID_PARAM`），已在下 `FP_CONTEXT_ASYNC` 前先發
     `FP_MODE=0` 清除模式來修掉。兩者都已在目前的 driver 修好（`crfpmoc_keys_enc_status_cb` 現在
     跳到 `KEYS_CLEAR_MODE`，這是 `KEYS` 子狀態機新增的一步）。
  2. **資料層（為什麼必須重新註冊）** —— 每個模板的解密金鑰是由 seed + 每模板 salt 推導出來的，
     對應 Chromium 自己的設計：`HW_Key = HKDF(SBP_Src_Key, TPM_Seed, User_Salt, User_ID)`
     （<https://chromium.googlesource.com/chromiumos/platform/ec/+/HEAD/docs/fingerprint/fingerprint-authentication-design-doc.md>）。
     在**壞掉**的那版 driver 下註冊的模板，一旦感應器/context 的帶起流程——或
     `/var/lib/fprint/crfpmoc.key` 裡的 seed——改變，就可能無法解密。`user_id` **並不存在模板裡**，
     所以那些模板無論怎麼改 driver 都永遠無法復原。每次 open 都重新建立 context 是*正確*的修法
     （呼應 Chromium 的 `biod` 在每次上傳前都會 `SetContext`），但它意味著壞版 driver 的舊模板必須
     重新註冊。（註：目前的 crfpmoc driver 送的是 zero context，所以實際綁定只是 seed + 每模板 salt。）
* **解決方法**：
  1. 確認已安裝含兩項修復的 crfpmoc（driver 時間晚於 2026-08-15）；必要時重跑
     `fingerprint/install-fingerprint.sh`，再 `sudo systemctl restart fprintd`。
  2. **必須重新註冊指紋 —— 舊模板永久無法解密**：

     ```bash
     fprintd-delete "$USER"
     fprintd-enroll "$USER"
     ```

     （依提示重複按壓同一根手指；像之前一樣把兩隻拇指 / 食指都註冊起來。）
  3. 重新註冊後，跨重開機都能正常驗證，因為新模板是用目前穩定的 seed 檔加密的。
     **絕對不要刪除或重新產生 `/var/lib/fprint/crfpmoc.key`**（必須保持 `root:root`、`0600`）
     ——一旦遺失或權限錯誤，就得冷重開機或重新註冊才能恢復。

### 8. 兩套指紋程式搶佔 `/dev/cros_fp`

* **根本原因**：同一時間只應由一個程式驅動 FPMCU。本專案使用 crfpmoc libfprint driver
  （由 `fprintd` 使用）。另一套專案 **ChocolateLoverRaj/rust-fp**
  （`/usr/local/bin/rust-fp-dbus-interface` 及其 `rust-fp-dbus-interface.service`）
  也會開啟 `/dev/cros_fp`。由於 seed/context/模板是 FPMCU 上的單一全域狀態，兩個程式同時下達
  `EC_CMD_FP_SEED` / `EC_CMD_FP_CONTEXT` / enroll / verify 會互相汙染對方的加解密 context 與解鎖狀態。
* **解決方法**：只保留一套。若已安裝 rust-fp，停用它並改用 crfpmoc：

   ```bash
   sudo systemctl disable --now rust-fp-dbus-interface.service
   sudo systemctl restart fprintd
   ```

   （或移除 rust-fp 的 binary 與 service 後重開機。）

---

## ⌨️ 鍵盤與輸入問題 (Keyboard)

### 9. 頂排功能鍵（上一頁/重新整理/亮度/音量）按了無反應

* **根本原因**：系統缺少 `90-chromebook-keyboard.hwdb` 掃描碼映射。
* **解決方法**：

  ```bash
  ./setup.sh --keyboard
  ```

### 10. 想要將 Search 鍵設定為「短按 CapsLock、長按 Super」

* **解決方法**：安裝並啟用 `keyd`：

  ```bash
  sudo apt install -y keyd   # (或 dnf/pacman)
  sudo cp keyboard/keyd/cros.conf /etc/keyd/default.conf
  sudo systemctl enable --now keyd
  ```

---

## 🔋 電源管理與待機問題 (Power & Suspend)

### 11. 蓋螢幕休眠一整夜耗電過多 (超過 5~8%)

* **根本原因**：Intel AX201 Wi-Fi 背景喚醒 (WoWLAN) 或 PCIe ASPM 節能未完全
  啟用，導致 SoC 無法進入低功耗 Package C10 (SLP_S0#) 狀態。
* **解決方法**：
  1. 停用 Wi-Fi 睡眠喚醒：

     ```bash
     sudo iw phy phy0 wowlan disable
     ```

  2. 在 `/etc/default/grub` 中的 `GRUB_CMDLINE_LINUX_DEFAULT` 加上 `pcie_aspm=force`，並執行 `sudo update-grub`。
  3. 安裝 `tlp` 或 `power-profiles-daemon` 管理省電狀態。

### 12. 蓋上螢幕筆電不會休眠

* **解決方法**：確認 `/etc/systemd/logind.conf.d/99-hp-c640-lid.conf`
  （由 `./power/install-power.sh` 安裝）或 `/etc/systemd/logind.conf` 中設定：

  ```ini
  [Login]
  HandleLidSwitch=suspend
  HandleLidSwitchExternalPower=suspend
  ```

* **⚠️ 修改 logind 設定後請「重新開機」，不要執行 `systemctl restart
  systemd-logind`**：
  在桌面 session 進行中重啟 `systemd-logind` 會**登出所有已登入使用者**
  （session leader 在 deserialization 時遺失，導致整個 GNOME session 崩潰、
  使用者 manager 被強制結束，甚至看起來像系統當機）。而且新設定本來就要
  下次登入/開機才生效，所以重新開機（或登出再登入）才是正確且唯一安全的
  套用方式。

  ```bash
  # 不要這樣做：
  sudo systemctl restart systemd-logind

  # 請這樣做——重新開機後蓋螢幕規則即生效：
  sudo systemctl reboot
  ```

  *（2026-08-18 實測：重啟 systemd-logind 在 HP Pro c640 上引發完整登出風暴，
  外觀上如同系統當機。）*

### 13. 休眠喚醒後（或鎖定後立刻）鎖定畫面沒有指紋提示

* **症狀**：盒蓋休眠後打開（或鎖定後馬上操作），解鎖畫面**沒有指紋提示、
  碰觸感應器無效**。按 `Esc` 重新進入登入畫面後指紋恢復正常。
* **根因**：兩個 PAM worker 的裝置 Claim 競賽。解鎖時 GDM **同時** fork
  `gdm-password` worker 與 `gdm-fingerprint` worker，兩者的 PAM stack 原本都
  含 `pam_fprintd`：`gdm-password` 從 `common-auth` 引入（fprintd profile 經
  `pam-auth-update` 啟用時），`gdm-fingerprint` 則有
  `auth required pam_fprintd.so`。fprintd 一個裝置只允許**一個 Claim**；
  password worker 先 fork、先搶到，fingerprint worker 收到
  `Authorization denied ... Device was already claimed`，整個 fingerprint
  服務失敗，GNOME Shell 便隱藏指紋提示。休眠後重認證在喚醒後 ~400ms 就開始，
  使競賽結果變成必然。
* **證據**：

  ```text
  fprintd: Authorization denied to :1.142 to call method 'Claim' for device
  'ChromeOS Fingerprint Match-on-Chip': Device was already claimed
  ```

  上游追蹤：GNOME/gdm#1071、libfprint/fprintd#214、
  GNOME/gnome-shell#7791（至 2026-08 皆未修復）。
* **解決方法（2026-08-18 起本專案安裝器已內建）**：讓 `pam_fprintd` **不要
  出現在 `common-auth`**，指紋只在 sudo 啟用（`/etc/pam.d/sudo` 加入
  `auth sufficient pam_fprintd.so`）。GDM 登入畫面與鎖定畫面仍透過專屬的
  `gdm-fingerprint` PAM 服務運作，從此必定搶到 Claim。

  ```bash
  # 安裝器實際執行的動作：
  sudo pam-auth-update --remove fprintd
  sudo sed -i '/^@include common-auth$/i auth sufficient pam_fprintd.so max-tries=1 timeout=10' /etc/pam.d/sudo
  ```

  *（這也消除了 sudo 的競賽窗口——見第 8 節「單一 stack」原則。）*
* **手動復原（舊安裝適用）**：按 `Esc` 取消失敗的解鎖回合再重新解鎖——
  新 worker 會乾淨地重新 Claim。或先執行 `sudo systemctl restart fprintd`
  再解鎖。
* **PAM 修復後的殘留問題（喚醒後 FPMCU open 立即失敗）**：即使競賽已消除，
  喚醒後的**第一次**解鎖仍可能失敗：claim 成功但 crfpmoc 的**裝置 open 瞬間
  失敗**（S3 喚醒後頭 ~2 秒 EC/FPMCU 通道尚未就緒），`pam_fprintd` 回傳錯誤、
  Shell 不顯示指紋提示（此情況沒有 `already claimed` 日誌——2026-08-19 以
  `G_MESSAGES_DEBUG=fprintd` 證實：只有 `claiming the device: 0`、沒有
  `claimed device 0`）。本專案提供兩道互補的修復：
  1. **驅動層 open 重試（真正的修復，2026-08-19 起）**：audited `crfpmoc`
     驅動在喚醒後 EC 通道回報 I/O 或 EC 錯誤時，以有限預算
     （`CRFPMOC_OPEN_MAX_RETRIES` × 500ms）重試 open SSM。正常 open 第一次
     即成功、**零額外延遲**；只有失敗的 open 才會等待。
  2. **system-sleep hook 衛生機制**：`fingerprint/systemd/fprintd-sleep.sh`
     在睡前停止 fprintd，確保喚醒後一定是全新 daemon。

  盒蓋測試後驗證：

  ```bash
  journalctl -b -e -u fprintd | grep -E "claim|open|retry"
  # 預期：喚醒後第一次 claim 就出現 "claimed device 0"
  #       （若 EC 通道需要時間，才會看到 "retrying" 行）
  ```

  *（若仍失敗：在 fprintd.service drop-in 暫時加
  `Environment=G_MESSAGES_DEBUG=fprintd`，再重複盒蓋測試以捕捉驅動錯誤。）*

### 14. 開蓋喚醒後螢幕全黑（需按鍵/點擊才亮）

* **症狀**：盒蓋休眠（S3 `deep`）後打開，系統已喚醒（`PM: suspend exit`）
  但面板**全黑**，直到按鍵或點擊才亮。不是當機——輸入一到鎖定畫面即正常。
* **根因（2026-08-18 兩個候選機制）**：
  1. **GNOME 使用者層再次黑屏**（最可能，符合「按鍵即恢復」特徵）：
     `gsd-power` 在休眠時關閉面板；螢幕護盾的鎖定動畫在顯示器關閉期間停滯，
     resume 後動畫完成、電源外掛又把螢幕**關回去**（GNOME/mutter#4111，
     修補候選 gnome-shell!3742——尚未合併）。
  2. **Comet Lake 的 i915 PSR resume bug**（gitlab.freedesktop.org/drm/i915），
     或 kernel 7.0 的 eDP 背光回歸（drm/i915/kernel#16791、#16825）。
     可能性較低——那些 bug 不會因按鍵而恢復。
* **解決方法（本專案）**：`power/install-power.sh` 的 modprobe 調校
  `options i915 enable_psr=0 enable_fbc=1 enable_guc=2` 是 repo 針對
  休眠/喚醒黑屏的候選對策。2026-08-19 已安裝並重開機，但**未解決本機的
  黑屏問題**（仍須按鍵才亮——使用者已接受此行為；見
  [VERIFICATION.md](verification.md)）。如想試用請套用後重開機：

  ```bash
  ./power/install-power.sh   # 或手動：
  sudo install -D -m 0644 power/modprobe.d/99-hp-c640-power.conf \
      /etc/modprobe.d/99-hp-c640-power.conf
  sudo update-initramfs -u
  sudo systemctl reboot
  ```

  > [!NOTE]
  > kernel ≥ 7.0 時安裝器會自動移除已刪除的 `iwlwifi d0i3_disable`
  > 參數（見該檔註解標頭）。
* **若 `enable_psr=0` 後面板仍黑**：在 `/etc/environment` 試
  `MUTTER_DEBUG_FORCE_KMS_MODE=simple`（隔離 atomic-KMS resume 路徑，見
  drm/i915/kernel#16825），或用 `busctl monitor` 監看
  `org.gnome.SettingsDaemon.Power` 是否有 resume 後再度關閉螢幕的事件
  （可證實使用者層再黑屏假說）。回報至 GNOME/mutter#4111。

### 15. 電池充過 90% 或出現 `ERROR: Old EC doesn't support sustainer`

* **症狀**：下達 `ectool chargecontrol normal 80 90` 出現 `ERROR: Old EC doesn't support sustainer`，
  或是系統在重開機、S3 休眠喚醒後充超過 90%。
* **根本原因**：
  1. HP Pro c640 (Dratini) 搭載 ChromeOS EC v1 韌體 (`dratini_v2.0.2851`)。EC v1 僅支援硬體狀態切換
     (`normal`, `idle`, `discharge`)，韌體內部不支援自動維持百分比區間的 Sustainer 演算法。
  2. 在 S3 休眠期間或剛開機時，缺乏喚醒鉤子與開機提早啟動會留下暫態空窗，導致短暫以預設 normal 模式充電。
* **解決方案**：
  1. 使用專案強化後的 `c640-battery-limit.service` 與 `c640-ec-sleep.sh`：

     ```bash
     ./ec/install-ec.sh --enable-battery-limit
     ```

  2. 該服務採用守護程式 (`battery-daemon 90`) 搭配 `sysinit.target` 開機提早啟動與 `systemd-sleep` 喚醒鉤子，
     主動下達 0 mA AC 旁路 (`idle` / `inhibit-charge`)，無需依賴 EC Sustainer 即可精準控電。
  3. 執行 `c640-ec-control status` 或 `ectool battery` 驗證（目前充電電流應為 `0 mA`）。
