# 🔬 深度技術解析：S0ix 睡眠模式、ASPM 節能與電源管理

本文深入分析 **HP Pro c640 Chromebook** (Comet Lake-U / `dratini`) 在 Linux 系統下的 S0ix Modern Standby 機制、休眠耗電調校與喚醒事件管理。

---

## 1. S0ix (s2idle) vs S3 (Deep Sleep)

Intel 10th Gen Comet Lake 搭配 Coreboot / MrChromebox UEFI 韌體**僅支援 S0ix (`s2idle`)**，不支援傳統的 ACPI S3 (`deep`)。

```bash
cat /sys/power/mem_sleep
# 輸出格式應為：[s2idle]
```

在 S0ix 狀態下，CPU 核心停止運作，SoC 進入 Package C10 (SLP_S0#) 超低功耗狀態，達到與 S3 相當之待機續航，同時兼具毫秒級瞬間喚醒之優點。

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
Dratini 觸控板 (`GPE0_DW0_21`) 與指紋辨識器 (`GPE0_DW0_23`) 具備喚醒能力。若放入背包受壓導致意外開機，可透過以下指令檢查並適度停用喚醒源：
```bash
cat /proc/acpi/wakeup
# 停用特定設備喚醒 (例如 TPAD):
# echo TPAD | sudo tee /proc/acpi/wakeup
```
