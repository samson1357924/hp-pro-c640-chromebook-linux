# HP Pro c640 Chromebook (Google Dratini) Linux

<div class="mdx-hero" markdown>

<div class="mdx-hero__content" markdown>

## 避坑全指南與硬體啟用方案

為 **HP Pro c640 Chromebook**（Board: `dratini` / Baseboard: `hatch` / Intel 10th Gen Comet Lake-U）提供完整 Linux 支援 — 驅動補丁、跨發行版自動化與誠實的已驗證/未驗證文件。

[快速開始 :material-rocket-launch:](QUICKSTART.md){ .md-button .md-button--primary }
[實測驗證 :material-shield-check:](verification.md){ .md-button }
[在 GitHub 上查看 :fontawesome-brands-github:](https://github.com/samson1357924/hp-pro-c640-chromebook-linux){ .md-button }

</div>

</div>

---

## 💻 設備硬體規格

| 項目 | 詳細 |
| :--- | :--- |
| **裝置型號** | [HP Pro c640 Chromebook](https://support.hp.com/hk-zh/product/product-specs/hp-pro-c640-chromebook/33298399) |
| **主機板代號** | Google `dratini`（Baseboard: `hatch`） |
| **處理器** | Intel 10th Gen Core i3/i5/i7 (Comet Lake-U: i3-10110U, i5-10210U, i5-10310U, i7-10610U) |
| **指紋識別器** | Fingerprint Cards FPC1025 (ChromeOS Match-on-Chip via `/dev/cros_fp`) |
| **音訊系統** | Intel Comet Lake cAVS SOF DSP (`snd_sof_pci_intel_cnl`) + Realtek RT5682 + Maxim MAX98357A |
| **韌體** | MrChromebox UEFI Full ROM / Coreboot |

---

## 📊 硬體運作狀態一覽

> **誠實為本** — 🟢 = 已在實機 HP Pro c640 驗證（Ubuntu 26.04 / kernel 7.0.0-29 / 2026-08-19），⚠️ = 驅動已綁定但功能測試未納入證據，❌ = 未量測。詳見 [實測驗證矩陣](verification.md)。

| 硬體組件 | 運作狀態 | 驅動 / 解決方案 | 說明與支援度 |
| :--- | :---: | :--- | :--- |
| **指紋辨識** | 🟢 **正常** | `crfpmoc` (特製 `libfprint` MoC 驅動) | 鎖定螢幕解鎖與 `sudo` PAM 已驗證。**GDM 冷開機仍需密碼**（GNOME keyring）；見 [verification.md](verification.md)。 |
| **立體聲喇叭 & 麥克風** | 🟢 **喇叭與麥克風正常** | Intel SOF DSP + ALSA UCM2 / PipeWire | 喇叭 (PCM 5)、耳機 (PCM 0)、雙麥克風分流正常。**耳機插拔自動切換未納入證據** — 見 [verification.md](verification.md)。 |
| **Wi-Fi 6 & 藍牙 5.0** | ⚠️ **驅動已綁定** | Intel AX201 (`iwlwifi` / `btusb`) | 驅動開箱即綁定；**WPA3/吞吐量尚未量測**（見 [verification.md](verification.md)）。 |
| **觸控螢幕 & 觸控板** | ⚠️ **驅動已綁定** | `i2c_hid` / `elan_i2c` | 模組存在；**手勢/防掌觸未納入證據**（見 [verification.md](verification.md)）。 |
| **Intel UHD 顯示與硬解** | ⚠️ **驅動已綁定** | `i915` (Wayland / X11) | 顯示開箱即用；**VA-API 4K 60fps 未量測**（見 [verification.md](verification.md)）。 |
| **鍵盤背光 & 頂排功能鍵** | ⚠️ **頂排已驗證** | `cros_ec` + `udev hwdb` / `keyd` | 頂排 F1–F10 已映射（hwdb 已驗證）。**背光未測試** — 見 [verification.md](verification.md)。 |
| **待機休眠** | 🟢 **S3 盒蓋週期已驗證** | ACPI S3 `deep`（預設）+ `s2idle` | 2026-08-18 實測盒蓋 S3 休眠/喚醒（零錯誤）。**按鍵/指紋喚醒未測試**；開蓋後需按鍵才亮（見 [verification.md](verification.md)）。 |
| **雙 Type-C 輸出與快充** | ⚠️ **充電正常** | USB-PD + DP 1.2 Alt Mode | PD 充電正常；**Type-C 外接螢幕未驗證**（見 [verification.md](verification.md)）。 |

!!! note "最後驗證"
    **2026-08-19** 於 Ubuntu 26.04 LTS（kernel `7.0.0-29-generic`、PipeWire `1.6.2`、fprintd `1.94.5`、MrChromebox `2606.1`）。證據包 `c640-diagnostic-20260815_152233.tar.gz` — 見 [verification.md](verification.md) 的重現步驟。

---

## 🚀 快速開始

### 一鍵安裝

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git ~/projects/hp-pro-c640-chromebook-linux
cd ~/projects/hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

### 常用指令

| 需求 | 指令 |
| :--- | :--- |
| **完整安裝（鍵盤 + 音效 + 指紋 + 電源 + EC）** | `./setup.sh --all` |
| **僅安裝音訊 UCM 設定** | `./setup.sh --audio` (或 `./audio/install-audio.sh`) |
| **僅安裝指紋驅動與 PAM（混合 A+C）** | `./setup.sh --fingerprint` |
| **強制從源碼編譯指紋驅動（Plan A）** | `./setup.sh --source` |
| **僅安裝頂排鍵盤映射** | `./setup.sh --keyboard` |
| **執行系統硬體綜合診斷** | `./setup.sh --check` |
| **預覽模式（不改動系統檔案）** | `./setup.sh --all --dry-run` |
| **一鍵解除安裝與復原** | `./setup.sh --uninstall` |

---

## 📚 文件地圖

<div class="grid cards" markdown>

- :material-rocket-launch: **開始使用**

    ---

    初次使用此設備？從此開始了解安裝、相容性與韌體。

    [:octicons-arrow-right-24: 快速開始](QUICKSTART.md)
    [:octicons-arrow-right-24: 硬體相容性](COMPATIBILITY.md)
    [:octicons-arrow-right-24: 韌體刷機](FIRMWARE.md)

- :material-shield-check: **驗證與協助**

    ---

    誠實的已測/未測矩陣、疑難排解與復原。

    [:octicons-arrow-right-24: 實測驗證矩陣](verification.md) — **請優先閱讀**
    [:octicons-arrow-right-24: 疑難排解（14 坑）](TROUBLESHOOTING.md)
    [:octicons-arrow-right-24: 解除安裝與還原](UNINSTALL.md)

- :material-microscope: **深度解析**

    ---

    指紋、音訊與電源的協議級剖析。

    [:octicons-arrow-right-24: MoC 指紋驅動](deep-dive/cros-fp-moc-driver.md)
    [:octicons-arrow-right-24: SOF 音訊拓樸](deep-dive/intel-sof-ucm-audio.md)
    [:octicons-arrow-right-24: 電源與休眠](deep-dive/power-and-suspend.md)

- :material-linux: **發行版指南**

    ---

    各發行版專屬步驟與打包說明。

    [:octicons-arrow-right-24: Ubuntu / Debian](distros/ubuntu-debian.md)
    [:octicons-arrow-right-24: Fedora](distros/fedora.md)
    [:octicons-arrow-right-24: Arch Linux](distros/arch-linux.md)
    [:octicons-arrow-right-24: openSUSE](distros/opensuse.md)
    [:octicons-arrow-right-24: NixOS](distros/nixos.md)

</div>

---

## 🧩 模組亮點

### 🖐️ 指紋辨識 (`fingerprint/`)

FPC1025 Match-on-Chip 經 `/dev/cros_fp` 與審計後的 **`crfpmoc`** 驅動：

- **混合 A+C**：自 Releases 預編譯 `.deb`/`.rpm`/`.pkg.tar.zst` 秒裝 → 離線自動回退源碼編譯（Plan A）
- 50 ms 狀態機輪詢修復 epoll 飢餓（缺少中斷）
- 弱指標守護杜絕 Use-After-Free，`/var/lib/fprint/crfpmoc.key` `0600` 種子
- Debian / Arch / RPM / 獨立源碼包 — 見 [fingerprint README](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/tree/main/fingerprint)

### 🔊 音訊 (`audio/`)

Comet Lake SOF DSP 經 ALSA UCM2：

- 喇叭 PCM 5 (`max98357a`)、耳機 PCM 0 (`rt5682`) 自動切換、DMIC PCM 1 分流立體聲
- PipeWire Phantom Jack 修復 — 見 [SOF 深度解析](deep-dive/intel-sof-ucm-audio.md)

### ⌨️ 鍵盤 (`keyboard/`)

- **方案 A（預設）**：`systemd-hwdb` 零開銷，TTY/X11/Wayland 通用
- **方案 B**：`keyd` 雙模 `Search` → CapsLock / Super，Super+頂排 → F1–F10 — 見 [keyboard/keyd/cros.conf](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/keyboard/keyd/cros.conf)

---

## 🙏 致謝

特別感謝 **Abhinav Baid**（原創 `crfpmoc`）、**Felix Niederer**、**Michael Evans**、**[Marco Trevisan / libfprint](https://gitlab.freedesktop.org/libfprint/libfprint)**、**[MrChromebox](https://mrchromebox.tech/) / [Chrultrabook](https://chrultrabook.com/)**、**[WeirdTreeThing](https://github.com/WeirdTreeThing)** 與 **[ChromiumOS EC Team](https://chromium.googlesource.com/chromiumos/platform/ec/)** — 見 [CREDITS](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/CREDITS.md)。

---

## 📜 授權與合規

本專案遵循 [REUSE 3.0](https://reuse.software/) 與 SPDX：

| 組件模組 | 適用路徑 | 授權條款 |
| :--- | :--- | :--- |
| 主控腳本與工具 | `setup.sh`, `scripts/`, `lib/`, `power/`, `ec/` | **MIT** |
| 指紋驅動與測試 | `fingerprint/driver/`, `fingerprint/tests/` | **LGPL-2.1-or-later** |
| 音訊 UCM 拓樸 | `audio/ucm/` | **BSD-3-Clause** |
| 鍵盤 hwdb 與文件 | `keyboard/90-*.hwdb`, `docs/` | **CC0-1.0 / MIT** |

見 [LICENSE](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/LICENSE)、[LICENSES/](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/tree/main/LICENSES) 與 [CREDITS](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/CREDITS.md)。
