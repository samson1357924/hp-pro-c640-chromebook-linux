[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# ✅ 實測驗證矩陣 (Verification Matrix)

> **誠實狀態聲明**：本文件清楚區分**已在真實 HP Pro c640 上實測**的項目
> （附上精確軟體版本），以及**僅提供設定檔、尚未驗證**的項目。README 與
> [COMPATIBILITY.md](COMPATIBILITY.md) 中若宣稱了下方證據無法背書的內容，
> 應視為未實測。

---

## 🖥️ 實測環境 (Test Environment)

| 項目 | 數值 |
| :--- | :--- |
| **裝置** | HP Pro c640 Chromebook (board: `dratini` / baseboard: `hatch`) |
| **BIOS / 韌體** | MrChromebox UEFI Full ROM，版本 `2606.1` |
| **作業系統** | Ubuntu 26.04 LTS (Resolute Raccoon)，x86_64 |
| **核心** | `7.0.0-29-generic` (Ubuntu 7.0.0-29.29，2026-07-17 建置) |
| **桌面環境** | GNOME (gnome-shell + GDM)，Wayland |
| **音訊堆疊** | PipeWire `1.6.2`、WirePlumber `0.5.13`、alsa-ucm-conf `1.2.15.3` |
| **指紋堆疊** | fprintd `1.94.5`、libfprint-2 `1.95.1`（內建 `crfpmoc` 的自訂建置） |
| **證據包** | `c640-diagnostic-20260815_152233.tar.gz`（2026-08-15 收集） |

---

## ✅ 本機已實測並驗證

圖例：🟢 = 在上述機器上驗證可用；📄 = 證據存在於診斷包內。

### 1. 指紋 (`crfpmoc`)

| 檢查項目 | 結果 | 證據 |
| :--- | :---: | :--- |
| 驅動已編譯進 libfprint | 🟢 | `libfprint-2.so.2.0.0` 內含 `FpiDeviceCrfpMoc` / `crfpmoc_enroll` 符號 |
| 已註冊指紋 | 🟢 | `fprintd-list`：`samson1357924` 註冊 2 枚（`right-thumb`、`right-index-finger`） |
| `/dev/cros_fp` + `/dev/cros_ec` 存在 | 🟢 | 📄 `fingerprint_ec/dev_nodes.txt`；2026-08-18 起 `/dev/cros_fp` = `crw-rw----+ root plugdev` + uaccess ACL（repo 規則已套用） |
| 驅動原始碼與本 repo 一致 | 🟢 | `diff -r fingerprint/driver <build-tree>/drivers/crfpmoc` → 無差異 |
| udev rules（已安裝版） | 🟢 | 2026-08-18 已安裝 repo 版（`GROUP="plugdev", MODE="0660", TAG+="uaccess"`），重開機後以 `getfacl` 驗證；舊 `0666` 版已備份 |
| 單元測試 | 🟢 | `test-crfpmoc-unit`（`/usr/libexec/installed-tests/libfprint-2/`）4/4 全過：`fp_info_v3`、`fp_info_v1`、`enc_status_bitmask`、`payload_bounds` |
| 休眠喚醒後鎖定畫面指紋 | 🟢 | **2026-08-19 完整驗證**：(1) PAM Claim 競賽 2026-08-18 修復（fprintd 移出 `common-auth`，僅保留 `gdm-fingerprint` + `sudo`——先前為 "Device was already claimed"，GNOME/gdm#1071）；(2) 喚醒後 FPMCU open 立即失敗由驅動層 open 重試修復（crfpmoc.c 的 `CRFPMOC_OPEN_MAX_RETRIES` × 500ms）+ system-sleep hook（`fprintd-sleep.sh` 睡前停 fprintd）。使用者盒蓋測試：**第一次解鎖即有指紋提示、喚醒零延遲、日誌無 retry 行**。見 [TROUBLESHOOTING.md §13](TROUBLESHOOTING.md) |
| `sudo` PAM 授權 | 🟢 | `fprintd` 僅存在於 `/etc/pam.d/sudo`（2026-08-18 Claim 競賽修復——不在 `common-auth`）；`sudo -k` 後執行 `sudo whoami` 會跳出指紋提示並接受驗證（測試方法見 [fingerprint README](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/fingerprint/README.md#test)）。PAM 堆疊與上述鎖定畫面修復同一 session 驗證 |

### 2. 音訊 (Intel SOF DSP + ALSA UCM2 + PipeWire)

| 檢查項目 | 結果 | 證據 |
| :--- | :---: | :--- |
| 音效卡存在 | 🟢 | `sof-audio-pci-intel-cnl` 綁定 `00:1f.3`（📄 `hardware/lspci.txt`） |
| UCM 設定與 repo 完全一致 | 🟢 | `/usr/share/alsa/ucm2/conf.d/sof-rt5682/` 與 `audio/ucm/ucm2/` diff → **無差異** |
| 喇叭 (PCM 5) | 🟢 | 📄 `audio/aplay.txt`：`device 5: Speakers`；wpctl 預設 sink = `Speaker` |
| 耳機 (PCM 0) | ⚠️ | 📄 `audio/aplay.txt`：`device 0: Port1`；wpctl 列出 `Headphones` sink — **插拔自動切換未納入證據** |
| HDMI/DP 輸出 (PCM 2/3/4) | ⚠️ | 📄 `audio/aplay.txt`：HDMI1/2/3；wpctl 列出 3 個 HDMI sink — **外接顯示器輸出未驗證**（測試期間未連接 HDMI/DP 螢幕） |
| 雙麥克風 split (Mic 1/Mic 2) | 🟢 | 📄 `audio/wpctl.txt`：`Mic1__source.split` + `Mic2__source.split` filter 運作中 |
| 耳機麥克風 | 🟢 | 📄 `audio/wpctl.txt`：`Headset Microphone` source 存在 |
| 核心警告 | 🟢 | 📄 `system/dmesg_warnings.txt` — **空檔**（0 行） |
| 實際播放 | 🟢 | 📄 `audio/wpctl.txt`：Chromium 串流路由至 `Speaker:playback_FL/FR [active]` |

### 3. 鍵盤頂排 (systemd-hwdb)

| 檢查項目 | 結果 | 證據 |
| :--- | :---: | :--- |
| hwdb 已安裝 | 🟢 | `/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb` 存在 |
| hwdb 與 repo 一致 | 🟢 | `diff` → 僅 SPDX header 註解不同（功能完全相同） |
| keyd 選項 B | ⚠️ | **本機未安裝**（使用 hwdb 選項 A）；僅提供設定檔 |

### 4. Wi-Fi / 藍牙 / 視訊鏡頭 / 儲存

| 檢查項目 | 結果 | 證據 |
| :--- | :---: | :--- |
| Wi-Fi 6 AX201 | ⚠️ | 📄 `hardware/lspci.txt`：`iwlwifi` 於 `00:14.3` — **裝置存在，連線/吞吐量未量測** |
| 藍牙 AX201 | ⚠️ | 📄 `hardware/lsusb.txt`：`btusb` — Intel `8087:0026` — **裝置存在，配對/音訊未量測** |
| 視訊鏡頭 | ⚠️ | 📄 `hardware/lsusb.txt`：`uvcvideo` — Foxlink `05c8:03e1` — **裝置存在，影像擷取未測試** |
| SD / SATA | ⚠️ | 📄 `hardware/lspci.txt`：`sdhci-pci` x2、`ahci` — **裝置存在，I/O 未測試** |
| WPA3 / Wi-Fi 吞吐量 | ❌ | **未量測**（證據包內無網路層測試） |

### 5. 電源與休眠

| 檢查項目 | 結果 | 證據 |
| :--- | :---: | :--- |
| 休眠模式可用 | 🟢 | 📄 `system/mem_sleep.txt`：`s2idle [deep]` — **兩者皆支援** |
| **目前預設值** | ⚠️ | **目前預設是 `deep` (S3)，不是 s2idle**（README 已改為「預設 S3 deep，s2idle 可用」） |
| 實際休眠/喚醒週期 | 🟢 | **2026-08-18 實測**：盒蓋 → `PM: suspend entry (deep)` → `ACPI: PM: Preparing to enter system sleep state S3` → 開蓋 → `Waking up from system sleep state S3` → `PM: suspend exit`，零錯誤（journalctl -k）。同時證明 `power/systemd/logind.conf.d/` 的盒蓋規則已生效。 |
| S0ix residency / ASPM 調校 | ❌ | **未量測**（無 PMC `slp_s0_residency` 證據） |
| 電池充電控制 | 🟢 | 📄 `fingerprint_ec/battery.txt`：`CHARGE_BEHAVIOUR=inhibit-charge` @ 90%（由本機輔助腳本設定，**非** repo 的 `c640-ec-control`） |

### 6. 顯示 / 圖形

| 檢查項目 | 結果 | 證據 |
| :--- | :---: | :--- |
| i915 驅動綁定 | 🟢 | 📄 `hardware/lspci.txt`：`i915` 於 `00:02.0`（CometLake-U GT2） |
| VA-API 4K 60fps 硬體解碼 | ❌ | **未量測**（證據包內無 `vainfo` 輸出） |
| 雙 Type-C 影像輸出 | ❌ | **未驗證** — 測試期間未接外接螢幕；僅有 `CROS_USBPD_CHARGER0/1` 電源節點（📄 包內無 DP alt-mode 證據） |

---

## ⚠️ 僅提供設定檔／尚未實測

下列檔案在上述裝置上皆屬「僅設定」——狀態欄標明已安裝或存在但未啟用。
未實測項目請視為「提供給你的發行版參考，請自行驗證」：

| 模組 | 檔案 | 狀態 |
| :--- | :--- | :---: |
| **電源調校 — modprobe quirks** | `power/modprobe.d/99-hp-c640-power.conf` | 🟢 2026-08-19 已安裝並重開機（已過濾 d0i3、重建 initramfs）；**開蓋黑屏問題仍在**（仍須按鍵才亮——使用者已接受，見 [TROUBLESHOOTING.md §14](TROUBLESHOOTING.md)） |
| **電源調校 — wireplumber / logind** | `power/wireplumber/50-disable-suspend.conf`、`power/systemd/logind.conf.d/99-hp-c640-lid.conf` | 🟢 2026-08-18 已安裝（logind 盒蓋規則經真實 S3 週期驗證） |
| **電源調校 — TLP** | `power/tlp/99-hp-c640.conf` | ❌ 未安裝 — **與運作中的 `power-profiles-daemon` 衝突**（見下方） |
| **EC 控制** | `ec/install-ec.sh`、`scripts/c640-ec-control.sh`、`ec/systemd/c640-battery-limit.service` | ❌ 未安裝（無 `ectool`、無 `/usr/local/bin/c640-ec-control`）；本機電池上限改以 `charge_behaviour` sysfs + **另一支本機腳本**達成 |
| **指紋 system-sleep hook** | `fingerprint/systemd/fprintd-sleep.sh` | 🟢 2026-08-19 已安裝並驗證（盒蓋測試：第一次解鎖即有指紋、喚醒零延遲、日誌無 retry 行） |
| **指紋 udev rule** | `fingerprint/60-cros-fp.rules` (plugdev/0660/uaccess) | 🟢 2026-08-18 已安裝，重開機後以 `getfacl` 驗證 |
| **keyd 鍵盤設定** | `keyboard/keyd/cros.conf` | ❌ 使用 hwdb 選項 A |
| **PipeWire phantom-jack 修補** | `audio/patches/acp-phantom-jack.patch` | ❌ 目前 PipeWire 1.6.2 已內建處理（patch 供舊版使用） |
| **觸控螢幕 / 觸控板 / 背光** | 內建核心驅動（`elan_i2c`、`cros_kbd_led_backlight`） | ⚠️ 模組存在（`i2c-ELAN0000/0001`），但**無手勢/背光功能測試證據** |
| **按鍵/指紋喚醒休眠** | 內建 ACPI | ⚠️ 開蓋 S3 喚醒已驗證（journal `PM: suspend exit`）；按鍵/指紋喚醒未測試 |
| **已知問題 — 開蓋後黑屏** | i915 PSR/FBC/GuC 調校（見 §14） | 🟡 調校已安裝但**未解決**：開蓋 S3 喚醒後螢幕仍黑到按鍵才亮——使用者已接受，對策仍未定案 |
| **Arch / Fedora / openSUSE / NixOS 打包** | `fingerprint/packaging/PKGBUILD`、`*.spec`、發行版文件 | ❌ 僅 **Ubuntu 26.04** 實測；CI 會在 Arch/Fedora/Ubuntu 容器執行安裝器的原始碼建置，但 **PKGBUILD/`.spec` 打包定義本身並未由 CI 驗證** |

> [!NOTE]
> **`power/modprobe.d/99-hp-c640-power.conf` 於 kernel ≥ 7.0**：`iwlwifi
> d0i3_disable=0` 參數在 kernel 7.0 已被移除，安裝器（`power/install-power.sh`）
> 與本機都會自動濾除該 token（否則 modprobe 失敗、**Wi-Fi 無法載入**）。
> 7.0 上 `enable_guc=2` 只代表 HuC 載入；`enable_psr=0`/`enable_fbc=1` 在此
> 專為開蓋黑屏問題套用。**本機不裝 TLP**：與 Ubuntu 26.04 正在運作的
> `power-profiles-daemon` 衝突。

---

## 📋 如何重現證據

```bash
# 一次收集硬體 + 音訊 + 指紋 + 電源完整狀態：
./scripts/sysreport.sh
# 指紋註冊/驗證：
fprintd-list "$USER"
fprintd-verify "$USER"
# 音訊裝置：
aplay -l
wpctl status
# 休眠模式：
cat /sys/power/mem_sleep
```

> [!NOTE]
> 診斷包（`c640-diagnostic-*.tar.gz`）因可能含序號/PII 而被 .gitignore 排除。
> 若想在 repo 內留下可驗證的證據，請提交**去敏處理後**的輸出至此目錄。

---

## 🔄 最近驗證時間

* **日期**：2026-08-15（證據包）、2026-08-17（單元測試重跑）、2026-08-18
  （批次 1 安裝 + 盒蓋 S3 休眠/喚醒實測 + 指紋 Claim 競賽修復）、2026-08-19
  （system-sleep hook + i915 PSR 調校安裝並重開機；盒蓋指紋重測通過——第一次
  解鎖即成功、喚醒零延遲、日誌無 retry 行；黑屏問題未解決，使用者已接受）
* **OS / 核心**：Ubuntu 26.04 LTS，`7.0.0-29-generic`
* **韌體**：MrChromebox `2606.1`
* **硬體**：HP Pro c640 Chromebook（`dratini`/`hatch`）
