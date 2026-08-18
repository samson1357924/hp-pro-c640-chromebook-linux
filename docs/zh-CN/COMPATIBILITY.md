[English](../../README.md) | [繁體中文](../../README.zh-CN.md)

# 📊 硬體相容性矩陣 (Hardware Compatibility Matrix)

HP Pro c640 Chromebook (開發代號：**Google `dratini`**，Baseboard：**`hatch`**，Intel 第 10 代 Comet Lake-U 平台) 在 Linux 下的硬體組件支援狀況如下：

---

## 💻 組件狀態總覽

| 硬體組件 | 晶片型號 / 規格 | Linux 核心驅動 | 支援狀態 | 備註 / 解決方案 |
| :--- | :--- | :--- | :---: | :--- |
| **指紋辨識** | Fingerprint Cards FPC1025 (FPMCU MoC) | `/dev/cros_fp` (`cros_ec_spi`) | 🟢 **正常** | 本專案 `crfpmoc` 驅動 + PAM；鎖定解鎖與 `sudo` **2026-08-19 實機驗證**。 |
| **內建立體聲喇叭** | Maxim MAX98357A (I2S Amp) | `snd_soc_max98357a` | 🟢 **正常** | 透過 ALSA UCM2 PCM 5 輸出；**實機驗證**（Chromium 播放）。 |
| **3.5mm 耳機孔** | Realtek RT5682 (I2C) | `snd_soc_rt5682` | ⚠️ **驅動已綁定** | 裝置存在 (PCM 0)；**插拔自動切換未納入證據**。 |
| **內建數位麥克風** | 2-channel PDM DMIC | `snd_soc_dmic` | 🟢 **正常** | UCM PCM Split 分流為立體聲 Mic 1 與 Mic 2；**實機驗證**。 |
| **Wi-Fi 6** | Intel Wi-Fi 6 AX201 (CNVi) | `iwlwifi` | ⚠️ **驅動已綁定** | 開箱即載入；**WPA3 / 吞吐量未量測**。 |
| **藍牙 5.0** | Intel AX201 Bluetooth | `btusb` / `btintel` | ⚠️ **驅動已綁定** | 控制器存在；**配對 / A2DP 音訊未納入證據**。 |
| **觸控板** | ELAN I2C Touchpad | `i2c_hid` / `elan_i2c` | ⚠️ **驅動已綁定** | 模組存在；**多指手勢 / 防誤觸未功能測試**。 |
| **觸控螢幕 (選配)** | Goodix / ELAN / G2Touch | `i2c_hid_acpi` | ⚠️ **驅動已綁定** | 模組存在；**多點觸控 / 手寫筆輸入未功能測試**。 |
| **GPU / 內顯** | Intel UHD Graphics 620 | `i915` | ⚠️ **驅動已綁定** | 顯示開箱即用；**VA-API 4K 60fps 解碼未量測**。 |
| **視訊鏡頭** | 720p HD Camera (附隱私蓋) | `uvcvideo` | ⚠️ **驅動已綁定** | 標準 USB UVC 鏡頭；**擷取未測試**。 |
| **雙 Type-C 輸出** | 2x USB-C 3.2 Gen 1 (PD + DP) | `typec` / `xhci_pci` | ⚠️ **充電正常** | PD 充電節點存在；**DP 1.2 螢幕輸出未驗證**。 |
| **鍵盤頂排按鍵** | ChromeOS Top-Row Keys | `udev hwdb` / `keyd` | 🟢 **正常** | 映射為標準媒體鍵；**hwdb 已驗證**（背光亮度未測試）。 |
| **待機休眠** | S0ix Modern Standby + ACPI S3 | `s2idle` + `deep` | 🟢 **S3 盒蓋週期已驗證** | 預設 S3 `deep`；2026-08-18 實測真實盒蓋週期。**按鍵/指紋喚醒未測試**；開蓋後螢幕需按鍵才亮（見 [TROUBLESHOOTING.md §14](../TROUBLESHOOTING.md)）。 |

---

## 🐧 推薦發行版與內核版本需求

* **推薦 Linux 核心**：Linux Kernel `>= 5.15` (推薦 `>= 6.5` 以獲得最佳 SOF DSP 與 S0ix 功耗表現)。
* **音效伺服器**：PipeWire `>= 0.3.65` (推薦 PipeWire 1.0+ / WirePlumber 0.4.14+)。
* **發行版實測狀態**（實際硬體驗證內容請見 [VERIFICATION.md](verification.md)）：
  * 🟢 **已於實機硬體驗證**：**Ubuntu 26.04 LTS**（kernel `7.0.0-29-generic`、PipeWire `1.6.2`、WirePlumber `0.5.13`、fprintd `1.94.5`）
  * ⚠️ **僅 CI 建置驗證（無硬體實測）**：Debian 12/13、Fedora 39-41、Arch Linux / EndeavourOS、openSUSE Tumbleweed
