# 🛠️ 疑難排解與避坑 FAQ (Troubleshooting & Pitfall Guide)

本文整理了在 **HP Pro c640 Chromebook (Google `dratini`)** 安裝與使用 Linux 時最常遇到的十大問題與根本解決之道。

---

## 🔊 音效問題 (Audio)

### 1. 系統音效顯示 "Dummy Output" (虛擬輸出)，完全無聲
* **根本原因**：標準發行版的 `alsa-ucm-conf` 尚未將 `sof-rt5682` 下游配置納入主幹。PipeWire ACP 機制因 ASoC 晶片缺乏 Phantom Jack kcontrol 而誤判所有輸出不可用， WirePlumber 只能選擇 off。
* **解決方法**：執行本專案一鍵安裝指令：
  ```bash
  ./setup.sh --audio
  ```

### 2. 核心日誌出現 `cl_dsp_init: timeout with rom_status_reg`，音效卡遺失
* **根本原因**：**Intel Management Engine (ME) 被關閉**。Intel Comet Lake SOF DSP 韌體在開機與時脈初始化時強烈依賴 Intel ME 通訊。
* **解決方法**：**嚴禁使用 me_cleaner 或在 UEFI 設定中停用 Intel ME**。請確保 MrChromebox UEFI 韌體中的 Intel ME 為啟用狀態。

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
* **根本原因**：這是 Linux 桌面（如 GNOME / GDM）的安全性架構設計。**GNOME Keyring (儲存 Wi-Fi 密碼、瀏覽器密碼之鑰匙圈) 需要使用者的明文密碼進行解密**。
* **解決方法**：冷開機首次登入需輸入一次密碼以解鎖 Keyring，之後的所有鎖定螢幕 (`Super + L`)、休眠喚醒、PAM 授權與 `sudo` 均可直接秒按指紋。

---

## ⌨️ 鍵盤與輸入問題 (Keyboard)

### 7. 頂排功能鍵（上一頁/重新整理/亮度/音量）按了無反應
* **根本原因**：系統缺少 `90-chromebook-keyboard.hwdb` 掃描碼映射。
* **解決方法**：
  ```bash
  ./setup.sh --keyboard
  ```

### 8. 想要將 Search 鍵設定為「短按 CapsLock、長按 Super」
* **解決方法**：安裝並啟用 `keyd`：
  ```bash
  sudo apt install -y keyd   # (或 dnf/pacman)
  sudo cp keyboard/keyd/cros.conf /etc/keyd/default.conf
  sudo systemctl enable --now keyd
  ```

---

## 🔋 電源管理與待機問題 (Power & Suspend)

### 9. 蓋螢幕休眠一整夜耗電過多 (超過 5~8%)
* **根本原因**：Intel AX201 Wi-Fi 背景喚醒 (WoWLAN) 或 PCIe ASPM 節能未完全啟用，導致 SoC 無法進入低功耗 Package C10 (SLP_S0#) 狀態。
* **解決方法**：
  1. 停用 Wi-Fi 睡眠喚醒：
     ```bash
     sudo iw phy phy0 wowlan disable
     ```
  2. 在 `/etc/default/grub` 中的 `GRUB_CMDLINE_LINUX_DEFAULT` 加上 `pcie_aspm=force`，並執行 `sudo update-grub`。
  3. 安裝 `tlp` 或 `power-profiles-daemon` 管理省電狀態。

### 10. 蓋上螢幕筆電不會休眠
* **解決方法**：確保 `/etc/systemd/logind.conf` 中設定：
  ```ini
  [Login]
  HandleLidSwitch=suspend
  HandleLidSwitchExternalPower=suspend
  ```
  然後重啟服務：`sudo systemctl restart systemd-logind`。
