[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

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
| **鍵盤頂排按鍵與背光同步** | ChromeOS Top-Row + `chromeos::kbd_backlight` | `udev hwdb` / `keyd` + `c640-kbd-backlight-sync`（user service + system-sleep）+ `61-chromeos-kbd-backlight.rules` | 🟢 **頂排＋雙重角色＋背光皆已驗證（2026-10-31）** | 頂排 hwdb 映射的 AT 掃描碼 `0x3b`-`0x44` 是由 hwdb 轉換後 `EVIOCGKEY` 對照標準 AT 表推論（不是 ChromeOS action 掃描碼）；`check-top-row-hwdb.py` 在實體鍵盤上確認 11 條 `EVIOCGKEYCODE` 全數相符（只證明核心映射表 — 原始 `MSC_SCAN` 未捕獲，確認需停掉 keyd 後用 `--scan`），實體按鍵被動擷取也確認按鍵以 hwdb 轉換後的 `EV_KEY` 送達桌面。keyd 雙重角色 Search：虛擬 uinput 測試 PASS — 輕點 CapsLock（無 Meta、無防護）、**單獨長按** Super 無 `LEFTCTRL` 防護、Super+頂排 F1–F10（10 組全過，`[meta:M]` 圖層的 `LEFTCTRL` 組合鍵防護屬預期）、10 個頂排單按各自媒體鍵；實體被動擷取確認單獨長按會開 GNOME 總覽、單按可調亮度/音量/靜音。背光於螢幕熄滅自動關閉/恢復（`ScreenSaver.ActiveChanged` 2→0→2，無 sudo）與 sleep hook 發布 S3 handoff 檔（由解凍後的使用者 daemon 還原）皆已驗證；sysfs `0660 root:plugdev`。2026-11-22 曾以**舊 hook** 觀察到完整 S3 freeze/thaw（`rtcwake` + `systemctl suspend`）——僅為歷史證據；**現行 HEAD（新 selector／root 邊界）待目標機執行**，手動盒蓋循環仍為補充待測。**keyd 版本範圍：**語法僅在 CI 以 2.6.0 驗證（`keyd check`）；tap/hold/防護行為只在實機以 2.5.0-5 驗證；其它版本未驗證（上游 2.6.x 對 `overloadt2` 有已知行為差異）。本機安裝的 daemon 仍對應 `a03e4a0`（早於第十九次 re-review 四項 fix（唯讀稽核時點的觀察）），螢幕黑掉時背光仍維持 30——已知 Tier 2 限制、非本輪 regression；見下方真機觀察。 |
| **待機休眠** | S0ix Modern Standby + ACPI S3 | `s2idle` + `deep` | 🟢 **S3 盒蓋週期已驗證** | 預設 S3 `deep`；2026-08-18 實測真實盒蓋週期。**按鍵/指紋喚醒未測試**；開蓋後螢幕需按鍵才亮（見 [TROUBLESHOOTING.md §15](TROUBLESHOOTING.md)）。 |

### Sleep hook handoff 支援範圍

root system-sleep hook 只在下列條件下發布 S3 handoff 檔：

1. **Session 選擇。** 接受 **零個或恰好一個**合格 session — 由 `loginctl show-session` 確認的
   active、local、graphical user session（`Active=yes`、`Remote=no`、`Class=user`、
   `Type=wayland|x11`、非 closing 的 `State`、非空的 `Seat`，以及數字 **Session.User**，
   印出為 `User=<uid>`），且 `show-seat ActiveSession` 一致。**`UID=` 是 User object
   （logind private state）的屬性，不是 session 屬性**，絕不從 `show-session` 解析。
   session ID 為**英數**字串（例如 `c1`），不限十進位。greeter、SSH、tty 與 background
   session 永遠不合格。零個、多個候選（包含 multi-seat 模糊情況），或任一屬性（含 `User`）
   缺失／不可用都 fail closed：不寫 handoff，但 root 的 `/run/c640-kbd-backlight/state`
   診斷快照仍會保存。判斷寫入 **root journal**
   （`selected session ... for uid ...` 或 `session selection fail-closed: ...`），daemon 不做
   跨 uid 掃描。唯讀的 `keyboard/tests/loginctl-contract-check.sh` 會以真正的 `loginctl`
   在運作中的 systemd host 上驗證此 schema（systemd host 為 `CONTRACT OK`、非 systemd 為
   `SKIP`）——它**不執行** S3 週期。
2. **Runtime dir。** `/run/user/<uid>` 必須已存在、不可為 symlink、mode 恰為 `0700` 且 owner
   吻合該 uid。hook **絕不**建立、chmod 或 chown 它；不存在或不安全即 fail closed（不寫
   handoff）。
3. **loginctl 屬性缺漏。** `Active`／`Remote`／`Class`／`Type`／`State`／`Seat`／`User`／
   `ActiveSession` 任一缺失或不可用即排除該 session；沒有合格候選時 hook fail closed。
4. **`C640_KBD_HANDOFF_DIR` 覆寫。** explicit override 完全跳過 loginctl 選擇與 uid 釘住；
   **未使用 override 時**，`post` 才會沿用 `pre` 釘住的 uid（僅供驗證，絕不重選）。daemon 只對 explicit override 不一致
   發出 WARN，不掃描其他 uid。
5. **無 `/tmp` 降級。** `post` 時 runtime dir 消失即 fail closed；hook 絕不退回 `/tmp` 或
   任何其他目錄。
6. **Root 寫入邊界。** 兩個使用者 handoff 檔由 inline `python3` writer 以**釘住的
   directory fd** 發布（`O_DIRECTORY|O_NOFOLLOW`、`O_EXCL|O_NOFOLLOW` 的 `0600` 暫存檔、
   `fchmod`／`fchown`、重查目錄 identity、以 `src_dir_fd`／`dst_dir_fd` 執行
   `os.rename`、驗證發布後 inode）——即 fd 釘住版的 `mv -T -f --`，**沒有 `cp` 降級，
   也沒有一般 `mv` 降級**。root 診斷快照與 uid 釘住檔仍使用有 guard 的同目錄
   `mv -T -f --`。對 handoff writer 而言，目的項目在暫存內容前後都會檢查：最終 component
   必須不存在或為普通檔；symlink、目錄或特殊檔會以 `unsafe destination entry`（或
   `cannot publish ...`）fail closed，同時重查父目錄的 `(dev,ino)` identity，避免重新
   命名把寫入導向別處。**沒有 `cp` 降級，也沒有一般 `mv` 降級**可能解引用該項目。
   `C640_KBD_HANDOFF_DIR` 依設計信任 caller（explicit override 只檢查 `-d`，路徑由
   caller 負責），但最終 component 仍受同一 guard 保護。

> [!IMPORTANT]
> **真實 S3 狀態：**下方的 2026-11-22 完整 freeze/thaw 結果是舊 hook 的歷史證據。
> 新的 `Session.User` selector、root 寫入邊界與第十九次 payload／login1 修正目前只經本機
> contract check、stub 測試與 CI 驗證——**尚未在 HP Pro c640 以現行 HEAD 重跑真實 S3**
> （待目標機執行；已授權，排在本輪 push 後）。請見 [verification.md §3](verification.md) 的 checklist。

#### 真機觀察（唯讀，2026-11-26）

先前「本環境無 HP c640 硬體」的說法**已更正**。本機唯讀檢查顯示 DMI
`sys_vendor=Google`、`product_name=Dratini`、`board_vendor=HP`，coreboot
`MrChromebox-2606.1`、hostname `ubuntu-c640`、kernel `7.0.0-44`；
`/sys/class/leds/chromeos::kbd_backlight` 存在（`max=100`、目前 `30`），且使用者 daemon
正在執行。不過 `/usr/local/bin/c640-kbd-backlight-sync` 對應舊 commit `a03e4a0`，
**早於第十九次 re-review 四項 fix（唯讀稽核時點的觀察）**——因此 CI 的「installed == repo」byte-identical 檢查
**不是本機事實**。使用者回報螢幕黑掉時鍵盤背光仍維持 `30`。工作假說是已知
**Tier 2** 限制（daemon 只把 `ScreenSaver.ActiveChanged` 當 blank 觸發；Wayland 的
`idle-dim=true`／`idle-brightness=30` 可能讓螢幕黑掉而 ScreenSaver 仍 inactive；
IdleMonitor／brightness-signal 支援未實作且預設關閉），**不是本輪 regression**。
現行 HEAD 的真實 S3／lock-unlock 仍 pending。

#### 升級窗（第十七次 ↔ 第十九次 re-review）

suspend/resume payload 合約改了兩個欄位：root cycle marker 從兩欄
（`<token> <dev:ino>`）變三欄（`<token> <dev:ino> <value>`），resume flag 從三欄
（`<token> <epoch> <action>`）變四欄（`<token> <epoch> <action> <committed_value>`）。
legacy 兩欄 marker 現在**直接拒絕**（fail closed）；legacy 三欄 resume flag 仍被 daemon
**接受**，有第四欄時以其為權威，suspend／committed 不符時警告。**hook 與 daemon 必須
同包升級**：新 hook 配舊 daemon 可能發布舊 parser 讀不了的 flag；舊 hook 配新 daemon
則走 legacy 路徑、失去 committed value 證明。`python3` 在 `pre`／`post` 的發布與驗證
兩階段都是執行期依賴。

#### Fail closed 訊息與處置（第十七次 re-review）

| 訊息（root／user journal） | 意義 | 處置 |
| :--- | :--- | :--- |
| `Uncertain PAM rule syntax in <file> ... refusing to modify PAM configuration`／`Removing the fingerprint rule ... would change a per-management-group stack or its numeric jump target ...`／`Unsupported PAM include target ...`／`Unsupported PAM stack topology in common-* files; refusing to modify PAM configuration`／`PAM stack transformation is not provably safe for <label> (rc N): UNSUPPORTED PAM topology: ...` | 自訂 stack 無法在 per-management-group 模型中安全解析、拓撲無法解析／不支援（例如未建模 substack 可能影響 numeric jump 或 transformation），或移除 fp 模組會改變 numeric jump 落點；`@include` 會展開，不影響 numeric jump／transformation 的 substack 視為不透明 frame、不拒絕。 | 安裝在任何 PAM 編輯**之前**以非 0 結束；snapshot 與 debconf 均不變。請手動檢查 stack 後重跑——不要用 substring `sed` 代替。 |
| `a non-fprintd PAM rule or a numeric jump endpoint changed during convergence`／`Refusing to modify <file>: the sudo '<label>' anchor is missing`／`PAM transaction failed after mutation; force-restoring common-*/sudo from the first-wins snapshot ...` | 外部工具新增／改寫規則（模組 argument 的 `argsfp` 指紋改變），或 mutation 後驗證失敗。 | addition allowlist 預設為空，新增規則即 fail closed；mutation 後會先從保留的 snapshot **強制還原**再回 rc 1（該路徑保留、不消耗 snapshot）。請手動還原預期政策後重跑。 |
| `suspend/resume handoff token mismatch ...`、`cycle-begin file ... not adopted`、`suspend handoff token epoch ... stale` | handoff 不屬於本次 suspend cycle（過期副本、偽造 flag 或 `pre` 失敗）。 | daemon 保持已存亮度不變；視為 handoff 失敗而非還原。重跑 S3 週期；見 [verification.md](verification.md) §3。 |
| `resume handoff skipped (fail-closed): invalid cycle marker ...`、`suspend inode ... != cycle marker ...`、`suspend/cycle value mismatch ...`（TOKEN/VALUE/INODE/STRUCT/IO） | 使用了 legacy 兩欄 root marker，或 suspend bytes 在 `pre` 後被改動（同 inode 改值或 inode 替換）。`post` 從**單一**釘住 fd 逐位元組讀取，拒絕發布 resume flag。 | 不接受該 handoff。請以同一套件還原 hook／daemon 並重跑 S3 週期。legacy 三欄 resume flag 仍被 daemon 接受，committed value 為權威。 |
| `keeping committed cycle handoff`／`prepare-for-sleep: cannot anchor cycle-begin to token ...; resume will fail closed` | 延後的 `PrepareForSleep(true)` 在 `pre`／`post` commit 本輪之後才送達。 | true handler 保留可證明為現行的 handoff，並把 `cycle-begin` 重新錨定到 token epoch（非 wall-clock 時間）；真正過期的成對檔案仍會移除。沒有 resume flag 時，`PrepareForSleep(false)` 經 `restore_from_local_state()` 還原本機 daemon state，不 adopt handoff。 |
| `retry epoch invalidation failed; all brightness writers fail closed`／`retry epoch channel unhealthy; all brightness writers fail closed` | 連原地撤銷 epoch 也失敗（`COORDINATION_UNHEALTHY`），過期 witness 不可信。引用的 log 字串為逐字輸出，實際強制範圍僅限後續 gate。 | 每個後續 gate fail closed。修好 runtime state 目錄後重啟使用者 daemon。範圍僅限後續 gate；已進入 `WRITE_LOCK` 的 writer 無法回溯，可能仍完成一次寫入；state 目錄完全不可寫時持久 marker 無法建立，撤銷前已 fork 的 worker 只看到 in-process flag。此為非阻塞殘留，此降級狀態下不宣稱回溯撤銷。 |
| `evidence clock unavailable; evidence expired`／`evidence clock moved backwards; evidence expired` | monotonic 時鐘來源無法讀取或回撥，guard witness 年齡未知。 | guard 重新探測；仍無法驗證即 fail closed、不寫入。檢查 `/proc/uptime`／`C640_KBD_MONOTONIC_FILE`。 |
| `handoff skipped (fail-closed): python3 unavailable; cannot publish <file>` | hook 執行環境缺少 `python3`。 | 在目標機安裝 `python3`；在此之前不發布 handoff（fail closed、不還原）。 |

---

## 🐧 推薦發行版與內核版本需求

* **推薦 Linux 核心**：Linux Kernel `>= 5.15` (推薦 `>= 6.5` 以獲得最佳 SOF DSP 與 S0ix 功耗表現)。
* **音效伺服器**：PipeWire `>= 0.3.65` (推薦 PipeWire 1.0+ / WirePlumber 0.4.14+)。
* **發行版實測狀態**（實際硬體驗證內容請見 [VERIFICATION.md](verification.md)）：
  * 🟢 **已於實機硬體驗證**：**Ubuntu 26.04 LTS**
    （2026-10-31 鍵盤 session 為 kernel `7.0.0-38-generic`，2026-08 證據包為
    `7.0.0-29-generic`；PipeWire `1.6.2`、WirePlumber `0.5.13`、fprintd `1.94.5`）
  * ⚠️ **僅 CI 建置驗證（無硬體實測）**：Ubuntu 24.04、Fedora 42、Arch Linux
    （distro-matrix dry-run 與依賴解析），以及打包檢查（Arch `namcap`、Fedora `rpmlint`）
