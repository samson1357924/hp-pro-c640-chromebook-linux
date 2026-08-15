[English](../README.md) | [繁體中文](../README.zh-CN.md)

# 🔧 韌體刷機與還原指南 (Firmware & Recovery Guide)

本指南詳細說明如何為 **HP Pro c640 Chromebook (Google `dratini`)** 刷入
**MrChromebox UEFI Full ROM** 韌體以安裝原生 Linux，以及未來如何 100% 完整還原
回原廠 ChromeOS。

---

## ⚠️ 刷機前必讀重要觀念

> [!IMPORTANT]
>
> 1. **HP Pro c640 沒有實體防寫螺絲 (No WP Screw)**：本機採用 Google Cr50 安全晶片保護韌體。
> 2. **解除寫入保護（HW WP）的最簡方法：斷開電池排線**。只要在拔掉電池排線的狀態下插上充電器開機，Cr50 即會自動停用硬體寫入保護！
> 3. **永遠備份原廠 ROM**：在執行 MrChromebox 韌體刷機工具時，系統會提示備份原始韌體，**務必插入隨身碟保存 `stock-firmware.rom`**。

---

## 🛠️ 第一階段：解除硬體寫入保護 (Disable Hardware WP)

### 步驟說明（斷開電池法）

1. 將 Chromebook 完全關機，拔除所有 USB 線材與充電器。
2. 拆卸 D 面底殼（轉下底部所有螺絲並使用塑膠撬棒打開卡榫）。
3. **找到主機板與電池連接的排線接頭，將電池排線拔下**。
4. 在**電池排線保持拔除**的狀態下，將原廠 USB-C PD 充電器插入筆電（筆電會自動通電開機）。
5. 此時系統啟動，Cr50 安全晶片偵測無電池供電，硬體寫入保護（Hardware Write Protection）已完全停用。

---

## 🚀 第二階段：進入開發者模式並刷入 MrChromebox UEFI Full ROM

1. **進入 ChromeOS 開發者模式**：
   - 開機按住 `Esc + Refresh + Power` 進入 Recovery 模式。
   - 按下 `Ctrl + D`，按 Enter 確認清除本機資料並切換為 Developer Mode。
2. **開機連上 Wi-Fi**：
   - 進入 ChromeOS 歡迎畫面，連上無線網路。
   - 按下 `Ctrl + Alt + T` 開啟 crosh 終端機，輸入 `shell` 並按 Enter 進入 Bash 環境。
3. **執行 MrChromebox 韌體安裝腳本**：

   ```bash
   cd; curl -LO https://mrchromebox.tech/firmware-util.sh && sudo bash firmware-util.sh
   ```

4. **選擇 `Install / Update UEFI (Full ROM) Firmware` (選項 2)**：
   - 依照提示確認刷機。
   - **當提示備份 Stock Firmware 時，插入 USB 隨身碟，輸入儲存路徑將 `stock-firmware.rom` 備份到隨身碟上！**
5. **刷機完成與復原硬體**：
   - 刷入完成後關閉電源，拔掉充電器。
   - **將電池排線重新插回主機板**，鎖回底蓋螺絲。
   - 重新開機即可看到 MrChromebox 兔子 Logo，插入任何標準 Linux 安裝隨身碟（Ubuntu / Fedora / Arch 等）開始安裝系統！

---

## 🔄 第三階段：還原回原廠 ChromeOS (Restore Stock Firmware)

若日後需要將筆電重設或還原原廠 ChromeOS：

1. 使用 Linux Live USB 開機進入桌面環境。
2. 連上網路，開啟終端機執行 MrChromebox 工具：

   ```bash
   cd; curl -LO https://mrchromebox.tech/firmware-util.sh && sudo bash firmware-util.sh
   ```

3. 選擇 **`Restore Stock Firmware`**。
4. 插入存有先前備份的 `stock-firmware.rom` 隨身碟，依照畫面指示完成還原。
5. 還原完成後關機。
6. 使用其他電腦在 Chrome 瀏覽器安裝擴充功能「**Chromebook 復原公用程式
   (Chromebook Recovery Utility)**」，為型號 `HP Pro c640 Chromebook` (或輸入
   `DRATINI`) 製作原廠復原隨身碟。
7. 插入復原隨身碟並開機，系統將全自動重灌原廠 ChromeOS 官方鏡像。
