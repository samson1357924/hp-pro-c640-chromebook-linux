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
| **核心** | 2026-10-31 鍵盤/背光 session 為 `7.0.0-38-generic`；2026-08 證據包是在 `7.0.0-29-generic` 收集 |
| **桌面環境** | GNOME (gnome-shell + GDM)，Wayland |
| **音訊堆疊** | PipeWire `1.6.2`、WirePlumber `0.5.13`、alsa-ucm-conf `1.2.15.3` |
| **指紋堆疊** | fprintd `1.94.5`、libfprint-2 `1.95.1`（內建 `crfpmoc` 的自訂建置） |
| **證據包** | `c640-diagnostic-20260815_152248.tar.gz`（2026-08-15 收集） |

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
| 休眠喚醒後鎖定畫面指紋 | 🟢 | **2026-08-19 完整驗證**：(1) PAM Claim 競賽 2026-08-18 修復（fprintd 移出 `common-auth`，僅保留 `gdm-fingerprint` + `sudo`——先前為 "Device was already claimed"，GNOME/gdm#1071）；(2) 喚醒後 FPMCU open 立即失敗由驅動層 open 重試修復（crfpmoc.c 的 `CRFPMOC_OPEN_MAX_RETRIES` × 500ms）+ system-sleep hook（`fprintd-sleep.sh` 睡前停 fprintd）。使用者盒蓋測試：**第一次解鎖即有指紋提示、喚醒零延遲、日誌無 retry 行**。見 [TROUBLESHOOTING.md §14](TROUBLESHOOTING.md) |
| `sudo` PAM 授權 | 🟢 | `fprintd` 僅存在於 `/etc/pam.d/sudo`（2026-08-18 Claim 競賽修復——不在 `common-auth`）；`sudo -k` 後執行 `sudo whoami` 會跳出指紋提示並接受驗證（測試方法見 [fingerprint README](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/fingerprint/README.md#2-verify-enrolled-fingerprint)）。PAM 堆疊與上述鎖定畫面修復同一 session 驗證 |

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

### 3. 鍵盤頂排 (systemd-hwdb) 與背光同步

| 檢查項目 | 結果 | 證據 |
| :--- | :---: | :--- |
| hwdb 已安裝 | 🟢 | `/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb` 存在；與 repo 檔 `diff` 為空 |
| hwdb 掃描碼映射（實機） | 🟢 | `keyboard/tests/check-top-row-hwdb.py`（2026-10-31 19:45:29，對實體鍵盤做 `EVIOCGKEYCODE`）：11 條全部 `OK` — `0x3b`→`KEY_BACK`、`0x40`→`KEY_BRIGHTNESSDOWN`、`0x42`→`KEY_MUTE`、`0xdb`→`KEY_LEFTMETA`。這證明的是核心映射，不是按鍵實際送出的掃描碼。`0x3b`-`0x44` 是由 hwdb 轉換後 `EVIOCGKEY` 按鍵狀態對照標準 AT 表推論；證據中沒有原始 `MSC_SCAN` 捕獲，確認仍需停掉 keyd 後用 `--scan`。`18:14:47-18:15:18` 的實體按鍵被動擷取只證明按鍵以 hwdb 轉換後的 `EV_KEY` 送達桌面，不是 `MSC_SCAN`。 |
| keyd 選項 B | 🟢 | **2026-10-31 已安裝**（keyd 2.5.0-5，執行檔 `/usr/bin/keyd.rvaiya`），使用 `overloadt2(meta, capslock, 200)`。虛擬 uinput 測試（19:45:37，`keyboard/tests/keyd-dualrole-uinput.py`）PASS：輕點 Search→只有 `CAPSLOCK`（不送 `META`、無防護）、10 組 Search+頂排→`F1`-`F10`（現行測試現已預期 `[meta:M]` 圖層的 `LEFTCTRL` 組合鍵防護）、10 個頂排單按→各自媒體鍵、純長按 Search→乾淨的 `LEFTMETA` 放開且**沒有 `LEFTCTRL` 防護**。語法僅在 CI 以 keyd 2.6.0 驗證（`keyd check`）；行為只在本機以 2.5.0-5 驗證，其它版本未驗證（上游 2.6.x 對 `overloadt2` 有已知差異）。實體按鍵被動擷取（`18:14:47-18:15:18`）：單獨長按放開為乾淨 `LEFTMETA`（畫面確認 GNOME 總覽開啟）、輕點只送 `CAPSLOCK`、單按亮度/靜音/音量確實改變亮度與音量、Search+Back 送出 `F1`。journal 顯示 `match 0001:0001 (AT Translated Set 2 keyboard)` 與 `ignoring 0000:0006 (Video Bus)` |
| hwdb DMI 命中（真實 modalias） | 🟢 | `udevadm test /sys/class/input/event2` 透過 `evdev:atkbd:` 查詢套用 `KEYBOARD_KEY_*`，即使韌體多了 `br0.0:efr0.0` 欄位仍命中；非 `atkbd` 查詢印 `No entry found from hwdb` 屬正常 |
| 鍵盤背光 udev rule | 🟢 | `61-chromeos-kbd-backlight.rules` 於 2026-10-31 安裝；`TAG+="uaccess"` + `RUN+=chgrp plugdev` / `RUN+=chmod 0660` → `ls -l .../brightness` 為 `-rw-rw---- root plugdev`，`udevadm trigger --subsystem-match=leds` 後一般使用者可直接寫入，無需 sudo |
| 鍵盤背光 daemon | 🟢 | 已安裝至 `/usr/local/bin/`；2026-10-31：`--test-blank` 2→0、`--test-unblank` 0→2，state 檔 `0600` 且會清除；`gdbus emit ... ScreenSaver.ActiveChanged true/false` → 2→0→2，使用者 journal **零 sudo 呼叫**。寫入鏈由單元測試驗證：單次 gsd-power `Properties.Set`、UPower 降級附 `[WARN]`、強制 legacy sysfs 路徑、存 0、覆寫非 0 現值、ScreenSaver active 延後還原、日誌出現在 stderr。Phase 6 新增後端重新探測（`RECOVERED`）、寫入+驗證 `set_brightness()` rc、即時讀數優先的 `save_state`、驗證後才消耗的暫存機制、三態延後與喚醒 handoff——各次 re-review 修復後 688 個 daemon 案例全過（見下）；2026-11-22 的真實 S3 結果屬舊 hook 的歷史證據，現行 HEAD **待目標機執行**（見下） |
| 鍵盤背光 user service | 🟢 | `/etc/systemd/user/`，全域啟用且 **uid 1000 的服務為 active**（`systemctl --global is-enabled`、`systemctl --user is-active` 皆正常）；`StandardError=journal` 讓 daemon 日誌可由 `journalctl --user -u c640-kbd-backlight-sync.service` 查看 |
| 鍵盤背光 sleep hook | 🟢 | `/usr/lib/systemd/system-sleep/`；2026-10-31 直接呼叫：`pre suspend` 存下 6、模擬 0 → `post suspend` 還原 6、state 清除。現已改為**純 handoff 寫入者**（不查 D-Bus／不寫 LED／不刪 state；`0600` + chown + 原子 `mv`；`C640_KBD_HANDOFF_DIR`）；234 個 hook 案例全過。hook 現在只對單一 active local graphical session 寫 handoff（0 或多個候選在 root journal fail closed），且絕不建立／chmod／chown runtime dir。root 的 `/run/c640-kbd-backlight/state` 只是**本次開機第一次 suspend 的單次診斷快照**——first-wins、不被消耗、也從不用於還原。2026-11-22 的 freeze/thaw 結果為舊 hook 的歷史證據；**現行 HEAD 待目標機執行**（詳情見下） |

#### 真實 S3 驗收 — 2026-11-22 為歷史紀錄；現行 HEAD 待執行（目標機）

> [!IMPORTANT]
> **本輪並未在 HP Pro c640 以最新 HEAD 重跑真實 S3。** 本輪只驗證了 loginctl
> `Session.User` schema/selector（`loginctl show-session` 的 `User=<uid>`、
> session ID 可為英數）在本機 systemd host 上的行為
> （`keyboard/tests/loginctl-contract-check.sh` → `CONTRACT OK`），以及 stub 測試與 CI。
> 非 systemd host 會印出 `SKIP`，這也**不是**通過。下方表格是第五輪（2026-11-22）
> 由**舊 hook** 留下的硬體證據，**不能代替本輪驗收**。所有 ⚠️ 列都必須在目標機
> 重跑，才能宣稱現行 HEAD 支援真實 S3。

| 檢查項目 | 結果（現行 HEAD） | 歷史證據（2026-11-22，舊 hook） |
| :--- | :---: | :--- |
| **分支 A — 喚醒後仍鎖定** | ⚠️ **待執行（目標機）** | suspend entry `04:34:19` → exit `04:34:39`（第一次）與 `04:48:37` → `04:48:58`（第二次，`faa458e` 修復後）；ScreenSaver 仍 `true`、亮度 `2`、`state=30` 保留、`handoff.suspend` 已消耗、`handoff.resume` 保留；journal `ignoring blank-side suspend handoff 0; keeping saved user brightness 30`、`resume deferred: ScreenSaver still active (saved=30)`。 |
| **分支 B — 解鎖後還原** | ⚠️ **待執行（目標機）** | `loginctl unlock-session 2` → `ScreenSaver inactive -> restoring kbd backlight`、`restoring brightness 30`；亮度、gsd-power 與 UPower 三者皆 `30`；state 與兩個 handoff 檔全消耗。 |
| **本機最後狀態** | ⚠️ **待執行（目標機）** | 已重新鎖定、亮度/gsd/UPower 同步、service 全域與使用者層皆 enabled + active，`state=30`。 |

**目標機待執行 checklist（必須在 HP Pro c640 以現行 HEAD 執行）：**

1. `bash keyboard/tests/loginctl-contract-check.sh` → systemd host 應為 `CONTRACT OK`
   （非 systemd 為 `SKIP`）；確認 `Session.User` 是 `User=<數字 uid>`、session ID 可為英數
   （如 `c1`）。
2. `rtcwake -m no -s 20` + `systemctl suspend`（真正的 systemd `PrepareForSleep`
   freeze/thaw，**不是**直接呼叫 hook）；另外，手動盒蓋循環仍列為補充待測。
3. root journal 出現 `selected session <id> on seat <seat> for uid <uid>`（來自
   `Session.User`），且沒有 `session selection fail-closed:`、`unsafe destination entry`、
   `cannot publish ...` 警告。
4. 兩個 handoff 檔都存在於 session user 的 `$XDG_RUNTIME_DIR`（`0600`、owner 正確），
   uid pin 為 root-only，且沒有 `/tmp` 降級。
5. 仍鎖定時喚醒：`resume deferred: ScreenSaver still active`——亮度**不**還原、已存值保留。
6. 解鎖：`restoring brightness N` 接著 `resume: restore complete; resume flag
   consumed`；LED、gsd-power 與 UPower 一致，兩個 handoff 檔皆消耗。
7. consume／最終狀態：state、resume flag 與 handoff 檔皆消失，service 全域與該 uid 皆
   enabled + active。

歷史環境（下方表格的來源）：systemd `259`、gnome-settings-daemon `50`、
`rtcwake -m no -s 20` 搭配 `systemctl suspend`（完整的 systemd sleep freeze/thaw 流程，
不是直接呼叫 hook）。休眠前：state=`30`、亮度=`0`（螢幕已熄滅）、ScreenSaver=`true`。

> [!NOTE]
> 這兩次使用 `rtcwake` + `systemctl suspend`，走的是與蓋蓋相同的 systemd
> `PrepareForSleep` freeze/thaw 與 system-sleep hook 路徑。**手動蓋蓋**循環不在
> 本次範圍內，仍列為補充待測項目。

#### 現況與測試總數（截至 2026-11-25）

| 測試套件 | 結果 | 範圍 |
| :--- | :--- | :--- |
| `keyboard/tests/kbd-backlight-daemon-test.sh` | **688 通過、0 失敗** | 以 stub 為基礎的單元測試 |
| `keyboard/tests/kbd-backlight-sleep-hook-test.sh` | **234 通過、0 失敗** | 以 stub 為基礎的單元測試 |
| `tests/rollback-test.sh` | **2248 通過、0 失敗** | 需 root |
| `keyboard/tests/loginctl-contract-check.sh` | **CONTRACT OK**（本機 systemd host） | 新的唯讀 schema 檢查：`Session.User` 為 `User=<數字 uid>`、`UID=` 只屬 User object、session ID 可為英數；非 systemd host 印出 `SKIP`——**不是**真實 S3 測試 |
| `keyboard/tests/keyd-dualrole-uinput.py` | **22 PASS** | 2026-10-31 歷史 live run（22 PASS），真實 virtual uinput／非 stub——**並非目前 HEAD 的 live run**；`acbc3b9` 後 chord guard 預期已變更，HEAD 上只重跑自我測試 |

出處：stub 測試套件為本機重跑；Python／診斷自我測試為 synthetic（合成）檢查；
22 PASS 是 2026-10-31 的歷史 live run，並未在 HEAD 重跑。
`loginctl-contract-check.sh` 已在本機 systemd host 執行並印出 `CONTRACT OK`
（非 systemd host 必須印 `SKIP`，這**不是**通過）；它只檢查 `Session.User` schema，
不執行 S3 週期、也不寫 handoff。CI 在 push 前的 `2588eb5` 全綠（7 個 workflows）；
本輪 Phase A–E push（`b572f35`..`a4a3fcc`）必須重跑 workflows，本文**尚未確認**重新通過。

Python／診斷自我測試：`check-top-row-hwdb.py` 回報 `SELF-TEST=PASS`、
`keyd-dualrole-uinput.py` 涵蓋 34 個案例、`detect-hardware.sh` 執行 28 個斷言。

keyd 組合鍵案例現在明確把 `[meta:M]` 圖層的 `LEFTCTRL` 組合鍵防護視為**預期**；
單獨長按與輕點仍**不得**有 `LEFTCTRL` 防護（這正是 Mutter 能開啟總覽的條件）。
頂排 `0x3b`-`0x44` 掃描碼仍是從 hwdb 轉換後 `EVIOCGKEY` 按鍵狀態對照標準 AT 表
**推論**而來；`EVIOCGKEYCODE` 只確認核心映射表，目前仍**沒有原始 `MSC_SCAN` 捕獲**——
要確認原始值，需停掉 keyd 後用 `--scan`（或不加 `--grab` 的 `evtest`）。

**沒有新的真實 S3 run。** 上方 2026-11-22（第五輪）驗收表仍是唯一的硬體紀錄；
第六至**第十六次** re-review 只改程式碼，並以 stub／單元測試與 CI 驗證。尤其是新的
`User=<uid>` selector 與 root handoff 寫入邊界，**尚未**在 HP Pro c640 以真實 S3
驗證——請見上方的目標機 checklist。

#### 第十四次 re-review — 修復摘要（2026-11-24）

本次 fork 在第十三次之後新增六個 commit：

* `9f41739` — CI：PAM E2E job 現在確實執行並產出可驗證證據，不再是假綠的 no-op。
* `3c1fcf4` — PAM：正確解析 debconf `seen` 旗標，並以可逆方式還原。
* `21fc6d3` — PAM：讓 profile 快照／還原交易化且 fail closed。
* `ac8da5c` — uninstaller：只有 rollback 真正成功才回報成功（狀態誠實；保留狀態時不印
  `finished!`）。
* `1f1fc4f` — 背光：修正 gsd 空值處理、resume deadline 與 guard 行為。
* `acbc3b9` — 鍵盤：修正 chord guard 測試並統一掃描碼證據口徑。

這些 commit 之後的總數：rollback suite **1981**、daemon **460**、sleep hook **84**，
全部 0 失敗。仍**沒有新的真實 S3 run**——2026-11-22 紀錄不變；keyd chord 測試現在承認
`LEFTCTRL` guard 為預期；`MSC_SCAN` 仍為推論，需 `--scan` 確認。

#### 第十五次 re-review — 修復摘要（2026-11-25）

本次 fork 在第十四次之後新增五個 commit：

* `2cbf5d1` — review 後續：收緊 chord guard 自我測試（34 個案例）並移除兩個未使用的
  handoff 變數；22 PASS 的 keyd live 結果仍是 2026-10-31 的歷史 run。
* `17a873b` — CI：讓 ShellCheck 與 shfmt gate 恢復綠燈；兩位獨立 reviewer 確認 gate 全 green，
  22 項 CI checks 預期全通過（Pages skipped）。
* `2f48bdc` — PAM：新增第三個 root 擁有 `0700` 的 `pam-selection.common` half，記錄每個
  `common-*`／sudo 目標的位元組、mode、lstat owner、type、symlink target 與 absence，外加
  savedir 目錄中繼資料；只在所有外部工具呼叫結束後還原，接著驗證
  bytes/mode/owner/type/link/absence、savedir 與 selection/seen，全部通過才一次消耗三個
  half。「manifest record 已消耗 + selection 相等」**不算**成功。沒有 `.common` 的 legacy
  sidecar 會明確記錄 `Legacy PAM snapshot has no ... (best effort only)` WARN，不宣稱位元組／中繼資料保證；`.saved`
  缺失但 live savedir 非空時 fail closed 並要求 `manual recovery`；對 `common-*` 的語意變更
  回 rc 1 並保留三個 half；若最後一個 `.common` half 在其他 half 已消耗後刪除失敗，
   sidecar 會重建但狀態**無法自動重試**（`manual recovery is REQUIRED`）。
* `530fc65` — 背光：把所有寫入序列化在單一 `WRITE_LOCK`（fd 209）下，於鎖內原子遞增
  restore generation，並在休眠後與寫入前重驗 generation；失效的 guard 完全不寫入。
  unblank guard 改用明確決策表：有戳記的使用者選擇優先、gsd 正向確認代表真的遺失還原，
  其餘**模糊即 fail closed（不寫入）**。**Tier 2 未實作。**
* `4620243` — sleep hook：以 loginctl 屬性加 `show-seat ActiveSession` 選出單一 active、
  local、graphical session（0 或多個候選在 root journal fail closed），`pre` 把 uid 釘在
  root-only `0600` 檔、`post` 沿用且不重選，要求 `/run/user/<uid>` 已存在且為相符的 `0700`，
  並移除 daemon 的跨 uid 掃描；daemon 現在只對 explicit `C640_KBD_HANDOFF_DIR` 覆寫不一致
  發出 WARN。

**第十五次當時的歷史總數**（已被下方第十六次取代）：daemon **539 通過、0 失敗**、
sleep hook **161 通過、0 失敗**、rollback **2137 通過、0 失敗**；keyd self-test **34 個案例**、
`check-top-row-hwdb.py` `SELF-TEST=PASS`、`detect-hardware.sh` **28 個斷言**。仍**沒有新的真實 S3 run**——上方 2026-11-22 第五輪表格
不變；**22 PASS** 的 keyd virtual-uinput 是 2026-10-31 的歷史 live run（`acbc3b9` 後只重跑
自我測試）；Tier 2 未實作。handoff 目標僅限單一 active local graphical session（見
[COMPATIBILITY.md](COMPATIBILITY.md)）。

#### 第十六次 re-review — 修復摘要（2026-11-25）

本次 fork 在第十五次之後新增五個 commit：

* `b572f35` — **sleep hook／Session User contract：** 從 `loginctl show-session` 的
  `Session.User`（`User=<uid>`）讀取數字 uid，不再使用 User object 的 `UID=` 鍵；
  session ID 接受英數（例如 `c1`，不限十進位），並把 `User` 加入缺漏屬性的排除清單。
  新增唯讀的 `keyboard/tests/loginctl-contract-check.sh`（本機 systemd host 為
  `CONTRACT OK`，非 systemd host 明確 `SKIP`——**不是**真實 S3 測試）。
* `a0a8f00` — **PAM symlink fprintd fail closed：** 在任何 snapshot、backup、`sed`、
  外部工具或 sudo 變更之前，都透過 `sudo` 探測每個 `common-*` 目標；若 symlinked
  `common-*` 含**生效中**的 `pam_fprintd.so` 模組，安裝即 fail closed（非 0、
  **不修改 PAM 或 selection**、不發布 first-wins snapshot）。無法讀取/grep 錯誤也
  fail closed；不存在或 dangling 目標視為沒有生效模組。安裝後狀態的 postcondition
  會檢查**實際的** `common-*` 位元組沒有生效的 fprintd（debconf selection 仍可能保留
  已停用的記錄）。
* `fca53c2` — **背光 generation／epoch／TTL：** generation 發布改為 fail closed
  （同目錄 `mktemp` → 寫入 → `chmod` → `mv -T` → readback；目的地不符即移除；只有在
  驗證過的發布**與** marker 清理都成功後，記憶體內的 generation 才前進）；retry/guard
  epoch 在成功與失敗路徑都輪替，因此即使發布失敗也會吊銷舊 retry/guard；guard 證據
  超過 `C640_KBD_GUARD_EVIDENCE_TTL`（預設 6 秒）即重新探測。**Tier 2 brightness signal
  未實作。**
* `4ac9b8f` — **PAM `.common` symlink owner ＋ savedir entries：** `.common` half 記錄每個
  symlink 目標的 **lstat owner**，並以 `chown -h` + `mv -T -f --` 還原，不解引用連結目標。
  savedir entry set（`absent`／`empty`／`nonempty`，附帶具 checksum 的 以 NUL 分隔並排序的 name+type
  manifest）納入最終驗證；任何非 regular entry 即 fail closed。沒有 entries 行的 legacy
  `.common` 降級為 WARN-only 的 best-effort 檢查
  （`Legacy PAM snapshot has no savedir entry-set manifest ...`）。
* `a4a3fcc` — **root handoff 寫入邊界：** handoff／root state 以 `mv -T -f --` 發布，
  在暫存內容前後都做 destination entry guard（最終 component 必須不存在或為普通檔；
  symlink／目錄／特殊檔即 fail closed 並記錄 `unsafe destination entry`／
  `cannot publish ...`），並重新檢查父目錄 inode identity；**沒有 `cp`、也沒有一般
  `mv` 降級**。`C640_KBD_HANDOFF_DIR` 依設計信任 caller（explicit override 只檢查 `-d`），
  但最終 component 仍受保護。

目前總數：daemon **688 通過、0 失敗**、sleep hook **234 通過、0 失敗**、rollback
**2248 通過、0 失敗**；keyd self-test **34 個案例**、`check-top-row-hwdb.py` `SELF-TEST=PASS`、
`detect-hardware.sh` **28 個斷言**、本機 contract check `CONTRACT OK`。CI 在 push 前的
`2588eb5` 全綠（7 個 workflows），本輪 push 後必須重跑。**最新 HEAD 的真實 S3 待目標機
執行**（見上方 checklist）；**22 PASS** 的 keyd virtual-uinput 是 2026-10-31 的歷史 live
run，HEAD 上只重跑自我測試；Tier 2 未實作。

#### 第六次 re-review 修復（2026-11-23，僅單元測試）

Commits: `2905a55`, `f7b1c1b`, `1c447bc`.

* **只有實際套用的還原才消耗 flag。** adopt、還原與新的 `verify_restore_applied()`
  共用結果碼 `0=RC_DONE`、`1=RC_FAIL`、`2=RC_DEFER`。鎖取得失敗、`STATE`/
  `restore-pending` 仍存在、或亮度讀回與已存值不符，都回 DEFER/FAIL 而非 0。只有
  DONE 會移除 state 與兩個 handoff 檔；DEFER 保留它們讓 5 秒取樣器重試，且
  `handle_unblank()` 記錄 `unblank: restore deferred` 而非誤發 WARN。
  `log_warn_once` 改用以 state 目錄中的標記檔，讓警告在跨 subshell 時仍只出現一次。
* **損毀 manifest 採 fail-closed。** `lib/backup.sh` 對所有 reader/writer 使用單一
  驗證器：manifest 不存在時建立空骨架；已存在的損毀 manifest 會記錄
  `MANIFEST_INVALID ... original bytes left untouched`、原檔位元組不變，並讓
  `manifest_has_target`（三態 0/1/2）與三個 writer 全都失敗。備份在任何目標被碰到前
  即被拒絕。
* **熄滅前先保存。** 抽出 `compute_save_brightness()`；`save_state [value]` 在
  `flock -w "$C640_KBD_SAVE_LOCK_WAIT"`（預設 2 秒）下回傳 `0`（已保存）/
  `1`（鎖等待失敗）/ `2`（寫入失敗）。`handle_blank()` 先取樣、保存（以擷取值重試
  兩次），**之後才**寫入 0；全部失敗時記錄 `blank: brightness NOT saved`、保持 LED
  亮著並重新 seed last-user cache。`--test-blank` 在保存失敗時回傳 1。

#### 第七次 re-review 修復（2026-11-23，僅單元測試）

Commits: `a03e4a0`, `461e18e`, `ff78712`.

* **保存熄滅前的快照並自我修復無效 state。** `handle_blank()` 在關閉 LED 前只取樣一次，
  第一次 `save_state "$captured"` 就直接使用該擷取值——若取樣兩次，可能讀到 blank-side
  的硬體 `0` 而回退到過期的 last-user cache（把真實的 `30` 存成 `8`）。`save_state()`
  是原子且 first-wins **只保護有效副本**；空白、非數字、多列或二進位的 state 檔會在
  `STATE_LOCK` 內驗證後，被擷取值原子取代（`replacing invalid saved brightness with N`）。
  只有真正寫入失敗才回 rc `2` 並保持 LED 亮著；rc `0`/`1`/`2` 與結果碼/重試語意不變。
* **驗證 manifest 欄位並在更動前 gate rollback。** 共用驗證器現在會檢查欄位型別（只驗證、
  不修補）：record 的 `target` 必須是無 NUL 的絕對路徑字串，`component`/
  `installed_at`/`version`/`scope` 若存在必須是字串，
  `was_existing`/`was_enabled`/`was_active`/`was_member` 必須是布林（`"false"` 與 `1`
  會被拒絕，不轉換）；service 的 `name`/`component` 與 group 的 `group`/`user`/
  `component` 為必填，選用欄位可缺席（legacy v1），未知 key 忽略。型別錯誤是新的
  `MANIFEST_INVALID` 原因（不只是 JSON 損毀），原檔位元組不變。`rollback_component()`、
  `uninstall_keyboard()` 與 `remove_group_membership()` 在任何服務/檔案副作用前 fail
  closed，rollback 並透過 stdin 消耗驗證過的文件（無 TOCTOU）；腳本執行到一半失敗會記錄
  `rollback of <component> failed; service/file state may be partial` 並回 rc 1，
  而不是謊稱成功。
* **略過 pseudo-target。** 非絕對的 manifest target（例如指紋的
  `package:libfprint-crfpmoc`）會被略過並記錄
  `skipping manifest entry with non-absolute target`（Meson plan 的目的路徑也必須是
  絕對路徑），讓安裝器不會寫出自己驗證器日後會拒絕的紀錄。

#### 第八次 re-review 修復（2026-11-23，僅單元測試）

Commits: `354ad39`, `0113279`, `98291ec`.

* **安全欄位為必填，原始狀態未知即 fail closed。** 驗證器現在要求
  `records[*].was_existing`、`services[*].was_enabled` / `was_active`、
  `groups[*].was_member` 必須是布林——所有真實 writer（v1.0 與 v2.0）一直都會寫出
  這些欄位（已比對 git 歷史）。真正向後相容的只有頂層陣列缺席、keyd record 缺
  `component`（回填）或缺 `scope`。rollback 新增 `UNKNOWN` sentinel：欄位缺失或型別
  錯誤時不刪檔、不停服務、不移除群組成員，保留紀錄、警告並回 rc 1——絕不把 unknown
  當成 false。`_keyd_managed_by_us()` 同樣要求有效的布林快照才會停用/停止 keyd。
* **目標檔缺席時仍從第一份備份還原。** rollback 不再依 `lexists` 分支：`was_existing`
  紀錄一律找出最早且符合的備份，重建原始檔案/symlink（先暫存再 `os.replace`、
  first-wins `matches[0]`、還原 owner/symlink/mode），即使使用者或其他工具已移除安裝
  的檔案也一樣。只有整個動作成功才消耗紀錄；找不到備份時保留紀錄並警告
  (`[WARN NO BACKUP]`)，不會憑空建立檔案。
* **每個還原指令都檢查結果。** 每一次 `systemctl` enable/disable/start/stop 都會檢查
  `.returncode`（含 timeout、stderr 與 spawn error）。失敗的服務會保留紀錄、記錄
  `SERVICE_RESTORE_FAILED` / `ROLLBACK_INCOMPLETE` 並回傳非 0，供日後重試；成功的
  則記錄 `[RESTORED SERVICE]`。
* **先記錄群組 membership 再變更。** 對 `plugdev`（及其他受管理群組），安裝器先把原始
  成員資格寫入 manifest，再明確檢查 `sudo usermod -aG` 的 rc（移除 `|| true`）；失敗時
  若先前沒有紀錄，就移除剛寫入的紀錄。keyboard、fingerprint 與 EC caller 共用
  `manifest_has_group` / `manifest_remove_group` / `ensure_group_membership` helper。

所有安裝 caller 現在會先存 rollback rc、完成其餘收尾，最後才回傳該 rc，避免 `set -e`
在 rollback 失敗時提前中止收尾。

#### 第九次 re-review 修復（2026-11-23，僅單元測試）

Commits: `cf18f6b`, `ac65507`.

* **還原取代失敗時保留已安裝的目標。** `restore_original()` 現在先暫存到目標旁，對
  普通檔案/symlink 以單次原子 `os.replace()` 取代且**不先 unlink**，因此取代失敗
  絕不會讓原設定消失。任何涉及目錄的交換（含 dir→dir）都會把舊項目移到一旁（失敗時移回），
  成功後再以 `remove_path()` 清理。rollback 測試涵蓋全部 8 種 target×backup 組合。
* **找不到備份是真正的失敗。** 對沒有第一份備份的 `was_existing` 紀錄，rollback 會
  記錄 `problem("RECORD_BACKUP_MISSING", ...)`、保留紀錄、不建立假檔，其他項目仍
  正常 rollback，但會印出 `ROLLBACK_INCOMPLETE: N item(s) retained` 並回 rc 1，
  而不會印 `finished!`。
* **並行的 manifest writer 會序列化。** 每一個 manifest read-modify-write writer
  （`lib/backup.sh` 的備份 helper 加上 keyboard 的 keyd-link 正規化）共用 root 控管的
  `flock -x -w` 鎖（`$MANIFEST_DIR/.install-manifest.lock`、fd 9、可重入 depth、缺
  `flock` 或等待
  逾時即 fail closed）；gate → 重新讀取 → 決策 → 寫入的 critical section 避免
  first-wins 紀錄遺失，且每個 writer 使用唯一的 `.install-manifest.*.tmp`（mkstemp、
  fsync、`chmod 0644` 與 `os.replace`），避免平行 writer 覆寫彼此的暫存檔。鎖檔
  以 noclobber 建立，不會被任何 writer 換掉 inode。

#### 第十次 re-review 修復（2026-11-23，僅單元測試）

Commits: `afdfe19`, `df7e621`.

* **鎖已針對 symlink 替換與非特權 DoS 加固。** manifest 鎖
  （`$MANIFEST_DIR/.install-manifest.lock`、fd 9）現在是 root 擁有的 `0600` 檔案
  （舊的 `0644` 鎖會升級），因此 peer 帳號無法開啟它並以 exclusive flock 阻塞所有安裝器。
  取得鎖的工作交給短暫的 `coproc sudo bash -c` root helper：它持有 fd 9，並在**實際持有
  fd 9 的行程內**以 `/proc/$$/fd/9` 檢查 fd/路徑 `(dev,ino)`、owner `0`、mode `600` 與
  普通檔型別（真正的 `sudo` 會關閉繼承的 fd，所以用 `sudo python3 fstat(9)` 不只在真實系統
  上錯誤，還會讓測試 stub 假綠），再執行有界的 `flock -x -w` 等待
  （`CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT`，預設 10 秒）、印出 `READY` 並阻塞讀取 stdin。
  釋放或崩潰時關閉 pipe 即產生 EOF，核心會釋放 flock，不會留下 stale lock，也不需要
  EXIT trap。symlink、非普通檔、inode 替換與不受信任的父目錄（非 root/目前使用者擁有，
  或群組/其他可寫 `mode & 022 != 0`——目錄請維持 `0755`）都會在任何特權
  chmod/chown/open 之前 fail closed；鎖檔以 `umask 077` + `set -C` 建立，絕不用 `install`。
* **整個元件操作是單一鎖交易。** `run_manifest_operation()` 為 keyboard（含 keyd 步驟）、
  audio、fingerprint（含 PAM）、EC/電池與 power 安裝器包住備份/紀錄 → 部署 → 完成/回滾，
  巢狀 helper 以 `MANIFEST_LOCK_DEPTH` 重入，`DRY_RUN` 完全不取鎖。body 以 bare call 呼叫，
  因此 `set -e` 仍生效（不會 fail-open 部署），且不安裝 EXIT trap（保留指紋安裝器既有的
  trap）。這消除了以下競態：程序 A 寫入 `was_existing=false` 紀錄後解鎖、程序 B 的 uninstall
  在目標檔缺席時消耗該紀錄，接著 A 才部署檔案，留下沒有追蹤紀錄的已部署檔案。
  `fingerprint --source` 會在整個 clone/compile 期間持鎖，平行操作請調高 timeout。

#### 第十一次 re-review 修復（2026-11-23，僅單元測試）

Commits: `751c609`, `6774033`, `69712a4`, `dab9436`.

* **plugdev 歸屬由所有元件共同判定。** `remove_group_membership()` 彙總所有元件的
  `(group,user)` 紀錄：任一明確的 `was_member=false` 即證明是我們加入的，全部為 `true`
  （或沒有紀錄）即保留（但若沒有 udev rule 需要該 group，則以 rc 3、零次 `gpasswd`
  消耗過期紀錄），安全欄位型別錯誤則 fail closed。`gpasswd -d` 成功後，該組的所有
  紀錄一併消耗，因此完整安裝/解除安裝不再取決於 keyboard 與 fingerprint 的安裝順序。
  `gpasswd -d` 失敗現在是 error 並回 rc 1（R1–R10 涵蓋原非成員/原已成員、兩種順序、
  單一模組、gpasswd 失敗、udev gating、DRY_RUN 與錯型案例）；keyboard、fingerprint 與
  EC uninstaller 會把它折進結束碼。
* **PAM 原始設定受到保護。** uninstall 不再對 sudo PAM 執行 sed：
  `disable_pam_fingerprint()` 不直接修改檔案，全由 `rollback_component("fingerprint")`
  還原原始位元組，因此原本就存在的精確 `pam_fprintd` 行會保留。安裝端改用
  `grep -qFx --` 精確比對，並支援 `CROS_ENABLEMENT_PAM_SUDO_PATH` /
  `CROS_ENABLEMENT_PAM_DIR` 測試 seam。Debian Tier 2 中，**所有** `common-*` 檔都會先
  備份，再以直接 `sed -i '/pam_fprintd\.so/d'` 只移除 fp 模組行（絕不使用
  `pam-auth-update --remove`）；debconf selection 與 `/var/lib/pam` 檔會先做 first-wins
  快照，安裝器自行以 `pam-auth-update --package` 收斂，uninstall 則在 rollback 確認
  完成後才還原。唯讀的 rollback 後檢查會在 manifest 仍有紀錄或損毀時警告，
  但絕不修改檔案；Fedora 的
  `authselect` 與 openSUSE 的 `pam-config` profile 狀態列為已知限制（僅警告）。
  PAM-1..8 驗證原始 sudo PAM 已有該行時，安裝→解除安裝後位元組完全相同。
* **鎖的父目錄是 root 控管的信任邊界。** 只接受 root 擁有的父目錄（移除 EUID/UID 分支），
  每一層祖先目錄都檢查（非 root 擁有或群組/其他可寫但無 sticky 即 fail closed；root 擁有
  且具 sticky 的世界可寫層例如 `/tmp` `1777` 可通過；symlink 僅在其所在目錄由 root 擁有
  且不可群組/其他可寫時放行），且 root holder 以 fd 8 釘住直接父目錄（重新檢查
  uid/mode/type/dev+ino，失敗印 `FAILED:parentdir`），防止重新命名讓第二個程序對新 inode
  取鎖。S10/S10b/S10c/S10d/T13 涵蓋 user-owned 1777 祖先拒絕、root 1777 通過、
  rename 雙持鎖防護與非 root 呼叫者在預設 root-owned 路徑不誤傷。自訂可寫的 lock parent
  不再被接受。
* **CI 失敗修復——PAM 故障注入改為每次呼叫獨立。** push 後 Backup/Rollback CI job
  回報 1383 通過 / 4 失敗（合計 1387）：PAM-4 的 `STUB_FAIL_ROLLBACK_PY=1` 從父 shell
  洩漏到 PAM-8。`dab9436` 把故障旗標改為 `run_pam_install()` / `run_pam_uninstall()`
  的明確傳參，且只在 sandbox snippet 內 export，後續 uninstall 不會繼承。新增
  **PAM-9** 回歸先注入 fail=1，再故意把父環境污染為 fail=0，驗證 rollback 乾淨完成、
  PAM 檔案位元組完全相同（+5 assertions，當時總數來到 **1392**；現行 rollback suite 為
  **2248** 個案例）。

#### 第十二次 re-review 修復（2026-11-24，僅單元測試）

Commits: `6b56b0e`, `883d9c7`, `783a035`.

* **鎖的信任邊界是 canonical、無 symlink 的路徑（P2 SECURITY；自訂 manifest 路徑
  BLOCKER）。** `CROS_ENABLEMENT_MANIFEST_DIR` 必須是絕對路徑（否則
  `must be an absolute path`），且每一個字面 component 都以 `-L` 檢查：任何 symlink
  component 一律拒絕（`contains a symlink` / `untrusted symlink`），即使是 root 擁有且
  其他方面安全也一樣——這是刻意採取的 fail-closed 取捨，因為 symlink 可隱藏使用者可寫、
  能重新命名鎖的真正目標。gate 以 `realpath -e` 解析**最深的存在**前綴，補回缺少的層
  （仍支援首次建立），對**真實**路徑執行 root 控管檢查（`untrusted realpath ancestor`），
  並以該 canonical 路徑取鎖。實際持有 fd 9 的 root helper 會重新導出
  `realpath -e "$dir"` 並要求相等（`FAILED:canonical`），再檢查每一層真實祖先是否
  uid `0` 且 `mode & 022 == 0` 或為 root sticky（`FAILED:ancestor`）；fd 8 父目錄釘住與
  `FAILED:parentdir` 不變。R1（相對 CWD）、R2（信任 symlink → 使用者目標）、
  R2e2e（canonical 祖先 end-to-end）、R3（holder 拒絕 symlink 衍生路徑）與 R4（控制組）
  涵蓋回歸。
* **過期的 all-true 群組紀錄會更新（P2 PERMISSION LIFECYCLE）。**
  `_GROUP_OWNERSHIP_PY` 現在於**所有** `(group,user)` 紀錄皆為 `was_member=true`（原本就
  存在）時回 rc 3——rc 0（有 `false`）與 rc 1（無紀錄）不變，rc 2 仍 fail closed。
  rc 3 且仍有 udev rule 引用該 group 時保留 first-wins 快照；**沒有** rule（所有使用該
  group 的元件皆已卸載）時，以**零次 gpasswd** 消耗全部過期紀錄——all-true 代表我們從未
  加入 membership，消耗中繼資料不影響權限，並讓下次安裝重新擷取真實、可能包括管理員
  變更後的狀態。消耗失敗會 fail closed 並保留紀錄。R3 已調整，R11（管理員改群組後再
  安裝的可回滾時序）、R12/R13/R14 與 R9b 涵蓋生命週期。
* **Debian PAM profile selection 被完整保留（P2 STATE RESTORATION）。** 安裝時完全
  **不呼叫** `pam-auth-update --remove fprintd`：該動作也會刪除 debconf 的
  `libpam-runtime/profiles` selection，而 manifest rollback 無法還原。Tier 2 備份
  **所有** `common-*` 檔，再**直接**以 `sed -i '/pam_fprintd\.so/d'` 只移除 fp 模組行——
  同樣讓 `common-auth` 不含 fp 而消除 GDM 解鎖 Claim 競賽。由於日後
  `pam-auth-update --package` 會從當前的 `common-*` 內容推導 profile 清單，安裝器還會
  先做 selection 與 `/var/lib/pam` 的 first-wins 快照、自行以 `--package` 收斂，並在
  uninstall 時於 rollback 完成後還原。Fedora `authselect` / openSUSE `pam-config` 的
  profile 狀態警告保留。

#### 第十三次 re-review 修復（2026-11-24，僅單元測試）

Commits: `7ff2623`, `9799e74`, `20d94c4`.

E2E 情境：詳見 .github/workflows/install-smoke.yml（baseline / sensitivity / round-trip / non-root）。

* **PAM profile selection 跨套件更新可逆（P1）。** 安裝時先將 debconf
  `libpam-runtime/profiles` 與每個 `/var/lib/pam/*` 已儲存模組檔快照到 first-wins sidecar
  （`pam-selection` 檔為 `0644`、`pam-selection.saved` 為 root `0700` 目錄）——原子、
  所有讀取/複製經由 `sudo`，因此具備 passwordless `sudo` 的非 root 呼叫端也能還原。
  **所有**現有的 `common-*` 檔都會
  被 rollback 追蹤（不只含 fp 者，因為 `--package` 可能改寫任一檔）。直接
  `sed -i '/pam_fprintd\.so/d'` 仍立即消除 GDM 競賽；接著安裝器自行執行一次
  `pam-auth-update --package`，讓 debconf 與 `/var/lib/pam` 收斂到穩定的「無 fprintd」
  狀態，日後套件觸發的執行即為 no-op。仍然**絕不使用** `--remove`。uninstall 時，
  唯讀探測確認 sudo 與所有 `common-*` 紀錄皆已消耗後（manifest 損毀或紀錄殘留則保留快照），
  先複回儲存的位元組，以 `debconf-set-selections` 寫回原始 multiselect，再跑一次
  `--package`，並驗證線上 selection（精確或忽略空白／順序的集合比對）後才消耗 sidecar；
  比對失敗會保留它並回 rc 1。指紋安裝器會把 `disable_pam_fingerprint` 的 rc 折進 rollback_rc。
* **群組 membership 保留逐次安裝的證據（P2）。** group record 可選填布林
  `added_by_project`（缺席＝legacy `false`；型別錯誤是 `MANIFEST_INVALID` 並 fail closed）。
  `was_member` 仍是 first-wins。重裝時若原始快照為 `true` 但使用者目前不是成員（管理員在
  仍安裝時移除），writer 會設該 flag；歸屬探測把它當作 `was_member=false`（rc 0），
  uninstall 便移除本次授予的成員資格。`usermod` 失敗時以 `manifest_clear_group_added`
  只清除 **flag**；consume-all 則連整列（含 flag）一起移除。R15–R20 涵蓋此生命週期。

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
| 電池充電控制 | 🟢 | `c640-ec-control` 與 `c640-battery-limit.service`：`CHARGE_BEHAVIOUR=inhibit-charge` @ 90%（0 mA 硬體 AC 旁路；雙軌 sysfs + `ectool` LPC 控制已驗證；S3 休眠 0 空窗喚醒鉤子已實測） |

### 6. 顯示 / 圖形

| 檢查項目 | 結果 | 證據 |
| :--- | :---: | :--- |
| i915 驅動綁定 | 🟢 | 📄 `hardware/lspci.txt`：`i915` 於 `00:02.0`（CometLake-U GT2） |
| VA-API 4K 60fps 硬體解碼 | ❌ | **未量測**（證據包內無 `vainfo` 輸出） |
| 雙 Type-C 影像輸出 | ❌ | **未驗證** — 測試期間未接外接螢幕；僅有 `CROS_USBPD_CHARGER0/1` 電源節點（📄 包內無 DP alt-mode 證據） |

---

## ⚠️ 其他元件（逐列狀態）

下列檔案在上述裝置上分別是已安裝、存在但未啟用，或刻意不安裝——以狀態欄為準。
標 🟢 的列有列內註明的實測證據；標 ⚠️/❌ 的列**尚未**驗證，請視為
「提供給你的發行版參考，請自行驗證」：

| 模組 | 檔案 | 狀態 |
| :--- | :--- | :---: |
| **電源調校 — modprobe quirks** | `power/modprobe.d/99-hp-c640-power.conf` | 🟢 2026-08-19 已安裝並重開機（已過濾 d0i3、重建 initramfs）；**開蓋黑屏問題仍在**（仍須按鍵才亮——使用者已接受，見 [TROUBLESHOOTING.md §15](TROUBLESHOOTING.md)） |
| **電源調校 — wireplumber / logind** | `power/wireplumber/50-disable-suspend.conf`、`power/systemd/logind.conf.d/99-hp-c640-lid.conf` | 🟢 2026-08-18 已安裝（logind 盒蓋規則經真實 S3 週期驗證） |
| **電源調校 — TLP** | `power/tlp/99-hp-c640.conf` | ❌ 未安裝 — **與運作中的 `power-profiles-daemon` 衝突**（見下方） |
| **EC 控制與電池保護** | `ec/install-ec.sh`、`scripts/c640-ec-control.sh`、`ec/systemd/c640-battery-limit.service`、`ec/systemd/c640-ec-sleep.sh` | 🟢 2026-08-23 已安裝並實機驗證（standalone `ectool` LPC 通訊、健康度儀表板、90% 電池守護服務、0 mA 旁路斷充與 S3 喚醒鉤子皆通過實測） |
| **指紋 system-sleep hook** | `fingerprint/systemd/fprintd-sleep.sh` | 🟢 2026-08-19 已安裝並驗證（盒蓋測試：第一次解鎖即有指紋、喚醒零延遲、日誌無 retry 行） |
| **指紋 udev rule** | `fingerprint/60-cros-fp.rules` (plugdev/0660/uaccess) | 🟢 2026-08-18 已安裝，重開機後以 `getfacl` 驗證 |
| **keyd 鍵盤設定** | `keyboard/keyd/cros.conf` | 🟢 2026-10-31 已安裝；`overloadt2` 以虛擬 uinput 測試（輕點→CapsLock、長按→乾淨 Meta、Search+頂排→F1-F10）與同日實體按鍵被動擷取驗證 |
| **PipeWire phantom-jack 修補** | `audio/patches/acp-phantom-jack.patch` | ❌ 目前 PipeWire 1.6.2 已內建處理（patch 供舊版使用） |
| **觸控螢幕 / 觸控板** | 內建核心驅動（`elan_i2c`） | ⚠️ 模組存在（`i2c-ELAN0000/0001`），但**無手勢測試證據** |
| **鍵盤背光同步（ScreenBlank）** | `keyboard/c640-kbd-backlight-sync`、`61-chromeos-kbd-backlight.rules`、`c640-kbd-backlight-sync.service`、`c640-kbd-backlight-sleep.sh` | 🟢 2026-10-31 已安裝並實機驗證（事件驅動 `gdbus`/`ScreenSaver` 2→0→2、`--test-blank`/`--test-unblank` PASS、sysfs `0660 root:plugdev`、sleep hook 存還原 6→0→6——重構前的直接呼叫結果；現行 hook 為純 handoff 寫入者，見 §3）。CI 檢查部署的 daemon/unit/hook 與 repo 完全一致並執行 shell 單元測試（688 daemon + 234 hook + 2248 rollback，最後一項需 root）；**2026-11-22** 的完整真實 S3 freeze/thaw（鎖定延後 + 解鎖還原）是舊 hook 的歷史證據——**現行 HEAD 待目標機執行**（見 §3） |
| **按鍵/指紋喚醒休眠** | 內建 ACPI | ⚠️ 開蓋 S3 喚醒已驗證（journal `PM: suspend exit`）；按鍵/指紋喚醒未測試 |
| **已知問題 — 開蓋後黑屏** | i915 PSR/FBC/GuC 調校（見 §15） | 🟡 調校已安裝但**未解決**：開蓋 S3 喚醒後螢幕仍黑到按鍵才亮——使用者已接受，對策仍未定案 |
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
  解鎖即成功、喚醒零延遲、日誌無 retry 行；黑屏問題未解決，使用者已接受）、2026-08-23
  （EC 90% 電池守護服務 + `c640-ec-sleep.sh` 零空窗喚醒鉤子 + standalone `ectool` LPC
  通訊已實機驗證；打包迭代 2 `1.94.10-2` 中繼資料已備妥，驅動原始碼未異動）、
  2026-08-29（鍵盤背光同步已安裝——當時僅設定、CI smoke 通過；2026-10-31 起完整驗證，見下），
  2026-10-31（依據 hwdb 轉換後 `EVIOCGKEY` 對照標準 AT 表修正鍵盤頂排映射：
  hwdb 改映射 `0x3b`-`0x44`，`EVIOCGKEYCODE` 只確認核心映射表，原始 `MSC_SCAN`
  未捕獲；keyd `overloadt2` 雙重角色 Search 以 uinput 測試與實體按鍵被動擷取驗證；
  背光同步以 `--test-blank`、`ScreenSaver.ActiveChanged`、sleep hook 端到端驗證），
  2026-11-22（Phase 6 鍵盤背光 handoff 真實 S3 驗收：systemd 259 /
  gnome-settings-daemon 50 上以 `rtcwake -m no -s 20` + `systemctl suspend`；
  鎖定喚醒時延後並保留 `state=30`，再以 `loginctl unlock-session 2` 解鎖後
  亮度/gsd/UPower 皆還原至 30 且兩個 handoff 檔皆消耗），
  2026-11-23（第六至第十一次 re-review 單元測試重跑：結果碼、manifest fail-closed、
  熄滅前保存、單次取樣/無效 state 自我修復、manifest 欄位驗證、副作用前 rollback gate
  與 rollback 安全語意——安全欄位必填/unknown 即 fail closed、目標缺席時從第一份備份
  還原、systemctl 還原檢查 rc、群組先記錄後變更、原子還原不先 unlink 且找不到備份
  回 rc 1，加上跨程序 manifest 鎖與唯一 writer 暫存檔、0600 root-only holder 鎖與
  整個操作序列化、跨元件 plugdev 歸屬、PAM 原始行只由 rollback 還原、root 控管
  lock parent + fd 8 釘住與每次呼叫獨立的 PAM 故障注入——現行總數見上方
  「現況與測試總數」；無新增真實 S3 實測），
  2026-11-24（第十二次 re-review 單元測試重跑：canonical 無 symlink 的 manifest 鎖
  信任邊界與 holder 端 `FAILED:canonical` / `FAILED:ancestor` 重驗、all-true 過期
  群組紀錄零 gpasswd 消耗、Debian PAM profile selection 以直接行移除完整保留——
  現行總數見上方；無新增真實 S3 實測），
  2026-11-24（第十三次 re-review 單元測試重跑：PAM selection/已儲存模組 first-wins
  sidecar 搭配 `--package` 收斂與 uninstall 驗證還原，以及選用的逐次安裝
  `added_by_project` 群組證據，並含真實工具的 Ubuntu 24.04 container E2E——
  現行總數見上方；無新增真實 S3 實測），
  2026-11-24（第十四次 re-review——本次 fork：上方摘要的六個 commit；rollback suite
  1981 / daemon 460 / hook 84，0 失敗；2026-11-22 後仍無新真實 S3 run；keyd chord
  的 `LEFTCTRL` guard 現在視為預期，`MSC_SCAN` 仍為推論），
  2026-11-25（第十五次 re-review——本次 fork：上方摘要的五個 commit；**當時的歷史總數**：
  rollback suite 2137 / daemon 539 / hook 161，0 失敗；2026-11-22 後仍無新真實 S3 run；
  22 PASS keyd live run 仍為歷史結果，`MSC_SCAN` 仍為推論，Tier 2 未實作），
  2026-11-25（第十六次 re-review——本次 fork：五個 commit `b572f35`、`a0a8f00`、`fca53c2`、
  `4ac9b8f`、`a4a3fcc`（見上方摘要）；現行總數 rollback 2248 / daemon 688 / hook 234，
  0 失敗；本機 contract check `CONTRACT OK`；push 前 `2588eb5` 的 7 個 workflows 全綠，
  本輪 push 後需重跑；**新 selector／root 邊界尚未在目標機以真實 S3 驗證**；22 PASS keyd
  live run 仍為歷史結果，Tier 2 未實作）
* **OS / 核心**：Ubuntu 26.04 LTS；2026-10-31 鍵盤/背光 session 為 `7.0.0-38-generic`，2026-08 證據包為 `7.0.0-29-generic`
* **韌體**：MrChromebox `2606.1`
* **硬體**：HP Pro c640 Chromebook（`dratini`/`hatch`）
