[English](../../README.md) | [繁體中文](../../README.zh-CN.md)

# 🛠️ 疑難排解與避坑 FAQ (Troubleshooting & Pitfall Guide)

本文整理了在 **HP Pro c640 Chromebook (Google `dratini`)** 安裝與使用 Linux 時
最常遇到的十大問題與根本解決之道。

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

* **解決方法**：確保 `/etc/systemd/logind.conf` 中設定：

  ```ini
  [Login]
  HandleLidSwitch=suspend
  HandleLidSwitchExternalPower=suspend
  ```

  然後重啟服務：`sudo systemctl restart systemd-logind`。
