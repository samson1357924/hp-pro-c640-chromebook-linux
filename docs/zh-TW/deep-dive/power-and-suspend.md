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
