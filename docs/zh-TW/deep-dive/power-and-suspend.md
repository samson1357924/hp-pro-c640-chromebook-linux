[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# 🔬 深度技術解析：S0ix 睡眠模式、ASPM 節能與電源管理

本文深入分析 **HP Pro c640 Chromebook** (Comet Lake-U / `dratini`) 在 Linux 系統下的 S0ix Modern Standby 機制、休眠耗電調校與喚醒事件管理。

---

## 1. s2idle (S0ix) vs S3 (Deep Sleep)

在本機（Ubuntu、kernel 7.0）上，韌體**同時提供**兩種休眠模式，且預設為 **S3 deep sleep**：

```bash
cat /sys/power/mem_sleep
# 本機（Dratini + 現行韌體）實際輸出：s2idle [deep]
```

方括號標示目前的預設模式。最近一次休眠記錄確認 deep sleep 確實被使用且功能正常：

```text
PM: suspend entry (deep)
```

這推翻了「Coreboot / MrChromebox UEFI 韌體僅提供 s2idle」的舊假設：可用模式取決於確切的韌體版本與核心，請在自身安裝環境讀取 `/sys/power/mem_sleep` 實測確認，不要直接沿用假設。

兩種模式差異如下：

* **S3 (`deep`)**：平台執行真正的系統休眠（記憶體自刷新、SPM 轉換、整機低功耗），但喚醒需數秒。
* **s2idle (S0ix Modern Standby)**：核心不進入韌體定義的休眠狀態，而是停止 CPU 核心、讓 SoC 嘗試進入 Package C10 (SLP_S0#) 超低功耗狀態，具備毫秒級瞬間喚醒。

執行期切換預設模式：

```bash
echo deep | sudo tee /sys/power/mem_sleep
# 或改用 S0ix Modern Standby：
echo s2idle | sudo tee /sys/power/mem_sleep
```

若要永久生效，請在 `/etc/default/grub` 的 `GRUB_CMDLINE_LINUX_DEFAULT` 加入 `mem_sleep_default=deep`（或 `=s2idle`）並執行 `sudo update-grub`。

---

## 2. 避免 Suspend 異常耗電調校清單

若蓋螢幕待機過夜耗電超過 5~8%，請依序檢查以下三項：

### (1) 停用 Wi-Fi 背景網路喚醒 (WoWLAN)

Intel AX201 Wi-Fi 在睡眠時若收到多播封包可能反覆喚醒 SoC：

```bash
sudo iw phy phy0 wowlan disable
```

可將此指令寫入 `/etc/rc.local` 或 systemd sleep hook。

### (2) 強制啟用 PCIe ASPM (Active State Power Management)

確保 NVMe SSD 與 PCIe 匯流排能進入 L1 節能狀態：
編輯 `/etc/default/grub`：

```ini
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pcie_aspm=force"
```

更新引導：`sudo update-grub`。

### (3) 檢視 ACPI 喚醒源 (`/proc/acpi/wakeup`)

Dratini 觸控板 (`GPE0_DW0_21`) 與指紋辨識器 (`GPE0_DW0_23`) 具備喚醒能力。若
放入背包受壓導致意外開機，可透過以下指令檢查並適度停用喚醒源：

```bash
cat /proc/acpi/wakeup
# 停用特定設備喚醒 (例如 TPAD):
# echo TPAD | sudo tee /proc/acpi/wakeup
```

---

## 3. ChromeOS EC v1 (Dratini) 電源與充電控制架構

**HP Pro c640 Chromebook** (Comet Lake-U / `dratini`) 搭載 Nuvoton NPCX796F Embedded Controller (EC)，
運行 ChromeOS EC 韌體（版本 `dratini_v2.0.2851`）。

### EC API 世代差異與硬體 AC 旁路

* **EC v2/v3 (較新款 Chromebook 與 Framework)**：支援韌體層級的電池維持器
  (`chargecontrol normal <lower> <upper>`)，由 EC 內部硬體自動維持電量區間。
* **EC v1 (HP Pro c640 Dratini)**：實作標準三狀態充電控制：
  * `normal` (0)：正常充電至 100%。
  * `idle` (1)：**硬體 AC 旁路模式 (AC Bypass)**（停止對電池充電，電池電流為 **0 mA**，整機直接由變壓器供電）。
  * `discharge` (2)：插電時強制由電池放電。

因為本機 EC 韌體屬於 v1 架構，不支援 Sustainer 區間指令（會回傳 `ERROR: Old EC doesn't support sustainer`），
因此充電門檻必須由作業系統層級主動判定與管理。

### 雙軌容錯控制：sysfs + ectool

本專案實作了核心與硬體雙軌相容機制：

1. **Linux 核心 sysfs (`cros_charge_control`)**：寫入 `inhibit-charge` 或 `auto` 至
   `/sys/class/power_supply/BAT0/charge_behaviour`。
2. **EC 原生 Host Command (`ectool`)**：透過 `/dev/cros_ec` LPC 介面發送
   `ectool chargecontrol idle` 或 `normal`。

---

## 4. 休眠與開機「0 空窗保護機制」 (Zero-Window Gap Protection)

傳統電池門檻輪詢腳本在「冷開機」與「S3 休眠」時容易出現過充空窗：

1. **開機啟動空窗**：傳統 systemd 服務在 `After=multi-user.target` 啟動時距離核心初始化約有 18~20 秒延遲，
   可能導致開機期間短暫全速充電。
2. **S3 休眠輪詢凍結**：進入 S3 休眠時，使用者空間的輪詢行程 (`sleep 30`) 會被 cgroup freezer 凍結；
   若休眠期間插上變壓器，可能造成未受控充電。

### 解決方案：sysinit Target + systemd-sleep 喚醒鉤子

* **開機提早啟動**：`c640-battery-limit.service` 設定為 `After=sysinit.target`，在開機 ~1.5 秒內即刻就緒。
* **喚醒即時鉤子**：`/usr/lib/systemd/system-sleep/c640-ec-sleep.sh` 在系統自 S3/S0ix 喚醒瞬間
  （`post` 鉤子）於 <0.05 秒內重新評估電量並下達 `inhibit-charge` / `idle`。
* **硬體 S3 保持特性**：經實機測試驗證，處於 `idle` (0 mA) 狀態的 EC 晶片在經歷 S3 deep sleep 休眠後，
  喚醒時仍持續精確維持 0 mA AC 旁路，不發生狀態丟失。

---

## 5. Standalone `ectool` 建置與使用指南

若要在標準 Linux (Ubuntu, Debian, Fedora, Arch) 上與 ChromeOS EC 直接通訊：

### 原始碼編譯 (`DHowett/ectool`)

```bash
# 安裝編譯依賴
sudo apt install -y cmake build-essential pkg-config libftdi1-dev libusb-1.0-0-dev

# 下載並編譯
git clone --depth=1 https://github.com/DHowett/ectool.git
cd ectool
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc)

# 安裝
sudo install -D -m 0755 src/ectool /usr/local/bin/ectool
```

### `c640-ec-control` 常用指令

```bash
# 查看完整 EC 儀表板（電池詳細數據、風扇轉速、主機板 3 處熱敏電阻溫度、鍵盤背光）
c640-ec-control status

# 設定 90% 充電上限保護
c640-ec-control battery-limit 90

# 強制切換為純 AC 旁路供電（電池 0 mA 靜止）
c640-ec-control battery-idle

# 恢復 100% 完整充電模式
c640-ec-control battery-full

# 風扇靜音模式（打字 0 RPM 靜音） / 恢復自動溫控
c640-ec-control fan-silent
c640-ec-control fan-auto
```
