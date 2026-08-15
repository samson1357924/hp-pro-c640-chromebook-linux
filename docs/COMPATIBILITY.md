# 📊 硬體相容性矩陣 (Hardware Compatibility Matrix)

HP Pro c640 Chromebook (開發代號：**Google `dratini`**，Baseboard：**`hatch`**，Intel 第 10 代 Comet Lake-U 平台) 在 Linux 下的硬體組件支援狀況如下：

---

## 💻 組件狀態總覽

| 硬體組件 | 晶片型號 / 規格 | Linux 核心驅動 | 支援狀態 | 備註 / 解決方案 |
| :--- | :--- | :--- | :---: | :--- |
| **指紋辨識** | Fingerprint Cards FPC1025 (FPMCU MoC) | `/dev/cros_fp` (`cros_ec_spi`) | 🟢 **100% 正常** | 使用本專案 `crfpmoc` 驅動 + PAM。支援鎖定解鎖與 `sudo`。 |
| **內建立體聲喇叭** | Maxim MAX98357A (I2S Amp) | `snd_soc_max98357a` | 🟢 **100% 正常** | 透過 ALSA UCM2 PCM 5 輸出，支援硬體音量控制。 |
| **3.5mm 耳機孔** | Realtek RT5682 (I2C) | `snd_soc_rt5682` | 🟢 **100% 正常** | 支援自動插拔切換 (JD1) 與耳麥輸入。 |
| **內建數位麥克風** | 2-channel PDM DMIC | `snd_soc_dmic` | 🟢 **100% 正常** | UCM PCM Split 分流為立體聲 Mic 1 與 Mic 2。 |
| **Wi-Fi 6** | Intel Wi-Fi 6 AX201 (CNVi) | `iwlwifi` | 🟢 **免設定** | 核心內建支援，支援 802.11ax 與 WPA3。 |
| **藍牙 5.0** | Intel AX201 Bluetooth | `btusb` / `btintel` | 🟢 **免設定** | 支援 BLE、A2DP 音訊與 HID 藍牙周邊。 |
| **觸控板** | ELAN I2C Touchpad | `i2c_hid` / `elan_i2c` | 🟢 **免設定** | 多指手勢與防誤觸（Palm Rejection）原生支援。 |
| **觸控螢幕 (選配)** | Goodix / ELAN / G2Touch | `i2c_hid_acpi` | 🟢 **免設定** | 支援多點觸控與手寫筆 (USI Stylus)。 |
| **GPU / 內顯** | Intel UHD Graphics 620 | `i915` | 🟢 **免設定** | 支援 Wayland/X11，VA-API 硬體編解碼 (4K 60fps)。 |
| **視訊鏡頭** | 720p HD Camera (附隱私蓋) | `uvcvideo` | 🟢 **免設定** | 標準 USB UVC 鏡頭。 |
| **雙 Type-C 輸出** | 2x USB-C 3.2 Gen 1 (PD + DP) | `typec` / `xhci_pci` | 🟢 **免設定** | 雙孔皆支援 45W/65W PD 快充與 DP 1.2 螢幕輸出。 |
| **鍵盤頂排按鍵** | ChromeOS Top-Row Keys | `udev hwdb` / `keyd` | 🟢 **100% 正常** | 映射為上一頁/下一頁/重新整理/亮度/音量等標準媒體鍵。 |
| **待機休眠** | Intel S0ix Modern Standby | ACPI `s2idle` | 🟢 **100% 正常** | 支援蓋螢幕休眠與按鍵/指紋快速喚醒。 |

---

## 🐧 推薦發行版與內核版本需求

* **推薦 Linux 核心**：Linux Kernel `>= 5.15` (推薦 `>= 6.5` 以獲得最佳 SOF DSP 與 S0ix 功耗表現)。
* **音效伺服器**：PipeWire `>= 0.3.65` (推薦 PipeWire 1.0+ / WirePlumber 0.4.14+)。
* **已實體驗證發行版**：
  * **Ubuntu 24.04 LTS / 26.04 LTS** (完美運作)
  * **Debian 12 (Bookworm) / 13 (Trixie)**
  * **Fedora 39 / 40 / 41**
  * **Arch Linux / EndeavourOS**
  * **openSUSE Tumbleweed**
