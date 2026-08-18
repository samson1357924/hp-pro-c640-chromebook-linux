[English](README.md) | [繁體中文](README.zh-CN.md)

# HP Pro c640 Chromebook (Google Dratini) Linux 避坑全指南與硬體啟用方案

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: ChromeOS / Linux](https://img.shields.io/badge/Platform-Chromebook%20Linux-green.svg)](docs/COMPATIBILITY.md)
[![Hardware: Google Dratini / Hatch](https://img.shields.io/badge/Hardware-Google%20Dratini%20(Comet%20Lake)-orange.svg)](docs/COMPATIBILITY.md)

本專案為 **HP Pro c640 Chromebook** (Google Board: **`dratini`** / Baseboard:
**`hatch`** / Intel 10th Gen Comet Lake-U) 提供完整的 Linux 硬體啟用方案，包含
驅動補丁、跨發行版自動化安裝腳本與全方位避坑指南。

---

## 💻 設備硬體規格

* **裝置型號**：[HP Pro c640 Chromebook](https://support.hp.com/hk-zh/product/product-specs/hp-pro-c640-chromebook/33298399)
* **主機板代號**：Google `dratini`（Baseboard: `hatch`）
* **處理器**：Intel 10th Gen Core i3/i5/i7 (Comet Lake-U: i3-10110U, i5-10210U, i5-10310U, i7-10610U)
* **指紋識別器**：Fingerprint Cards FPC1025 (ChromeOS Match-on-Chip via `/dev/cros_fp`)
* **音訊系統**：Intel Comet Lake cAVS SOF DSP (`snd_sof_pci_intel_cnl`) + Realtek RT5682 + Maxim MAX98357A
* **韌體**：MrChromebox UEFI Full ROM / Coreboot

---

## 📊 硬體運作狀態矩陣

| 硬體組件 | 運作狀態 | 驅動 / 解決方案 | 說明與支援度 |
| :--- | :---: | :--- | :--- |
| **指紋辨識** | 🟢 **100% 正常** | `crfpmoc` (特製 `libfprint` MoC 驅動) | 支援 GDM / 鎖定螢幕秒解鎖與 `sudo` PAM 授權。*證據見 [VERIFICATION.md](docs/zh-CN/verification.md)。* |
| **立體聲喇叭 & 麥克風** | 🟢 **喇叭與麥克風正常** | Intel SOF DSP + ALSA UCM2 / PipeWire | 喇叭 (PCM 5)、耳機 (PCM 0)、雙麥克風分流正常。**耳機插拔自動切換未納入證據** — 見 [VERIFICATION.md](docs/zh-CN/verification.md)。 |
| **Wi-Fi 6 & 藍牙 5.0** | ⚠️ **驅動已綁定** | Intel AX201 (`iwlwifi` / `btusb`) | 驅動開箱即綁定；**WPA3/吞吐量尚未量測**（見 [VERIFICATION.md](docs/zh-CN/verification.md)）。 |
| **觸控螢幕 & 觸控板** | ⚠️ **驅動已綁定** | `i2c_hid` / `elan_i2c` | 模組存在；**手勢/防掌觸功能測試未納入證據**（見 [VERIFICATION.md](docs/zh-CN/verification.md)）。 |
| **Intel UHD 顯示與硬解** | ⚠️ **驅動已綁定** | `i915` (Wayland / X11) | 顯示開箱即用；**VA-API 4K 60fps 硬解尚未量測**（見 [VERIFICATION.md](docs/zh-CN/verification.md)）。 |
| **鍵盤背光 & 頂排功能鍵** | ⚠️ **頂排已驗證** | `cros_ec` + `udev hwdb` / `keyd` | 頂排 F1-F10 對應上一頁、重新整理、亮度、音量（hwdb 已驗證）。**背光亮度未測試** — 見 [VERIFICATION.md](docs/zh-CN/verification.md)。 |
| **待機休眠** | 🟢 **S3 盒蓋週期已驗證** | ACPI S3 `deep`（預設）+ `s2idle` | 2026-08-18 實測真實盒蓋 S3 休眠/喚醒週期（零錯誤）。**按鍵/指紋喚醒未測試**；已知問題：開蓋後螢幕需按鍵才亮（見 [VERIFICATION.md](docs/zh-CN/verification.md)）。 |
| **雙 Type-C 輸出與快充** | ⚠️ **充電正常** | USB-PD + DP 1.2 Alt Mode | PD 充電節點存在；**Type-C 外接螢幕尚未驗證**（見 [VERIFICATION.md](docs/zh-CN/verification.md)）。 |

---

## 🚀 快速開始

### 1. 一鍵全自動安裝（統一主控 CLI）

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git ~/projects/hp-pro-c640-chromebook-linux
cd ~/projects/hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

### 2. CLI 常用指令

| 需求 | 指令 |
| :--- | :--- |
| **完整安裝（鍵盤 + 音效 + 指紋）** | `./setup.sh --all` |
| **僅安裝音訊 UCM 設定檔** | `./setup.sh --audio` (或 `./audio/install-audio.sh`) |
| **僅安裝指紋驅動與 PAM** | `./setup.sh --fingerprint` (或 `./fingerprint/install-fingerprint.sh`) |
| **僅安裝頂排鍵盤映射** | `./setup.sh --keyboard` (或 `./keyboard/install-keyboard.sh`) |
| **執行系統硬體綜合診斷** | `./setup.sh --check` (或 `./scripts/detect-hardware.sh`) |
| **預覽模式（不改動系統檔案）** | `./setup.sh --all --dry-run` |
| **一鍵解除安裝與復原系統** | `./setup.sh --uninstall` |

---

## 📚 完整文件目錄索引

* ✅ **[實測驗證矩陣 (VERIFICATION.md)](docs/zh-CN/verification.md)**：哪些項目**已在
  真實 HP Pro c640 上實測**（含精確版本）、哪些僅提供設定檔 — 在相信任何
  「100% 正常」宣稱前請先閱讀。
* 🚀 **[新手指南 (QUICKSTART.md)](docs/QUICKSTART.md)**：3 分鐘快速啟用流程與指令。
* 📊 **[硬體相容性清單 (COMPATIBILITY.md)](docs/COMPATIBILITY.md)**：詳細晶片規格、內核需求。
* 🔧 **[韌體刷機與還原指南 (FIRMWARE.md)](docs/FIRMWARE.md)**：MrChromebox UEFI 刷機、**拔除電池排線解除 Cr50 防寫** 與還原 ChromeOS 步驟。
* 🛠️ **[疑難排解與避坑 FAQ (TROUBLESHOOTING.md)](docs/TROUBLESHOOTING.md)**：十大常見故障與避坑對照表（Dummy Output、Intel ME 開啟需求、S0ix 耗電調校等）。
* 🔄 **[系統復原與解除安裝 (UNINSTALL.md)](docs/UNINSTALL.md)**：備份還原機制與原生套件復原。

### 🔬 深度技術解析

* 🖐️ **[ChromeOS Match-on-Chip 指紋驅動架構](docs/deep-dive/cros-fp-moc-driver.md)**：EC 通訊協議、50ms 狀態機輪詢與 TPM 金鑰安全。
* 🔊 **[Intel SOF DSP 與 ALSA UCM2 音訊拓撲](docs/deep-dive/intel-sof-ucm-audio.md)**：PCM 映射、Phantom Jack 剖析與 PipeWire 路由。
* 🔋 **[S0ix 睡眠模式與電源管理](docs/deep-dive/power-and-suspend.md)**：ASPM 節能、Wi-Fi WoWLAN 耗電優化。

### 🐧 各發行版專屬指南

* [Ubuntu & Debian 配置手冊](docs/distros/ubuntu-debian.md)
* [Fedora & Silverblue 配置手冊](docs/distros/fedora.md)
* [Arch Linux & EndeavourOS 配置手冊（含 PKGBUILD）](docs/distros/arch-linux.md)
* [openSUSE Tumbleweed 配置手冊](docs/distros/opensuse.md)
* [NixOS 宣告式配置手冊](docs/distros/nixos.md)

---

## 🧩 核心功能模組介紹

### 🖐️ 指紋辨識模組 (`fingerprint/`)

HP Pro c640 搭載 FPC1025 Match-on-Chip 感應器，透過 ChromeOS EC 控制器
(`/dev/cros_fp`) 溝通。本專案整合了經過深度審計與修復的 **`crfpmoc`** 驅動：

* 採用 50ms 延遲狀態機輪詢，徹底解決 Linux 核心缺少中斷導致的 epoll 飢餓問題。
* 弱指標記憶體守護，杜絕 Use-After-Free 隱患。
* `/var/lib/fprint/crfpmoc.key` 獨立隨機加密種子（權限 `0600`）。
* 提供 Arch PKGBUILD 與 RPM Spec 原生打包檔。

### 🔊 音效子系統 (`audio/`)

Comet Lake SOF DSP 音效透過 ALSA UCM2 拓撲完美啟用：

* 內建立體聲喇叭：PCM 5 (`max98357a`)。
* 3.5mm 耳機孔：PCM 0 (`rt5682`)，支援自動插拔切換。
* 數位麥克風陣列：PCM 1（DMIC Split 分流為雙聲道）。
* 提供 PipeWire ACP Phantom Jack 修復補丁 ([patches/acp-phantom-jack.patch](audio/patches/acp-phantom-jack.patch))。

### ⌨️ 鍵盤頂排映射 (`keyboard/`)

* **方案 A（預設推薦）**：`systemd-hwdb` 核心層映射，零資源消耗，支援 TTY、X11 與 Wayland。
* **方案 B（進階雙模）**：提供 `keyd` 設定檔
  ([keyboard/keyd/cros.conf](keyboard/keyd/cros.conf))，支援 Search 鍵「短按
  CapsLock、長按 Super」，按住 Super 轉換頂排為標準 F1-F10。

---

## 🙏 致謝與鳴謝

特別感謝以下開源專案、貢獻者與社群為 ChromeOS 與 Linux 跨平台硬體支援所奠定的基礎：

* **Abhinav Baid**：原創 `crfpmoc` (ChromeOS Match-on-Chip) libfprint 驅動程式作者。
* **Felix Niederer**：`crfpmoc` 驅動程式早期維護與架構貢獻。
* **Michael Evans**：協議擴展與多版本修復貢獻。
* **[Marco Trevisan (Treviño)](https://github.com/3v1n0)** 及
  **[libfprint / freedesktop.org](https://gitlab.freedesktop.org/libfprint/libfprint)**
  團隊：強大且健全的 Linux 生物識別驅動框架。
* **[MrChromebox](https://mrchromebox.tech/)** 與
  **[Chrultrabook Project](https://chrultrabook.com/)** 社群：提供卓越的
  Coreboot / UEFI Full ROM 韌體與 Chromebook Linux 社群支援。
* **[WeirdTreeThing](https://github.com/WeirdTreeThing)**：維護 Chromebook Linux Audio UCM 配置。
* **[ChromiumOS Embedded Controller (EC) Team](https://chromium.googlesource.com/chromiumos/platform/ec/)**：
  開源的 ChromeOS EC Host Commands 與 FPMCU 協議規範。

---

## 📜 開源協議與合規宣告

本專案遵循 [REUSE Specification 3.0](https://reuse.software/) 與 [SPDX 標準](https://spdx.dev/) 實施嚴謹的混合授權管理：

| 組件模組 | 適用路徑 | 授權條款 (SPDX) | 授權全文檔案 |
| :--- | :--- | :--- | :--- |
| **主控腳本與工具** | `setup.sh`, `scripts/`, `lib/`, `power/`, `ec/` | **MIT License** | [`LICENSES/MIT.txt`](LICENSES/MIT.txt) |
| **指紋辨識驅動與測試** | `fingerprint/driver/`, `fingerprint/tests/` | **LGPL-2.1-or-later** | [`LICENSES/LGPL-2.1-or-later.txt`](LICENSES/LGPL-2.1-or-later.txt) / [`COPYING.LGPL`](COPYING.LGPL) |
| **音訊 UCM 拓撲設定** | `audio/ucm/` | **BSD-3-Clause** | [`LICENSES/BSD-3-Clause.txt`](LICENSES/BSD-3-Clause.txt) |
| **硬體按鍵資料庫與說明** | `keyboard/90-*.hwdb`, `docs/` | **CC0-1.0 / MIT** | [`LICENSES/CC0-1.0.txt`](LICENSES/CC0-1.0.txt) |

> [!NOTE]
> 各上游著作權人聲明（Abhinav Baid, WeirdTreeThing, Marco Trevisan, ALSA Project, ChromiumOS Authors）、致謝清單與衍生修改記錄請詳閱 [**`CREDITS.md`**](CREDITS.md)。
