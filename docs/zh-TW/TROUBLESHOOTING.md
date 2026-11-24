[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# 🛠️ 疑難排解與避坑 FAQ (Troubleshooting & Pitfall Guide)

本文整理了在 **HP Pro c640 Chromebook (Google `dratini`)** 安裝與使用 Linux 時
最常遇到的十六大問題與根本解決之道。

---

## 🔊 音效問題 (Audio)

### 1. 系統音效顯示 "Dummy Output" (虛擬輸出)，完全無聲

* **根本原因**：標準發行版的 `alsa-ucm-conf` 尚未將 `sof-rt5682` 下游配置納入
  主幹。PipeWire ACP 機制因 ASoC 晶片缺乏 Phantom Jack kcontrol 而誤判所有輸出
  不可用， WirePlumber 只能選擇 off。
* **解決方法**：執行本專案一鍵安裝指令：

  ```bash
  ./setup.sh --audio
  ```

### 2. 核心日誌出現 `cl_dsp_init: timeout with rom_status_reg`，音效卡遺失

* **根本原因**：**Intel Management Engine (ME) 被關閉**。Intel Comet Lake SOF
  DSP 韌體在開機與時脈初始化時強烈依賴 Intel ME 通訊。
* **解決方法**：**嚴禁使用 me_cleaner 或在 UEFI 設定中停用 Intel ME**。請確保
  MrChromebox UEFI 韌體中的 Intel ME 為啟用狀態。

### 3. 耳機插入後喇叭仍出聲，或無法自動切換

* **解決方法**：重新啟動當前使用者的 WirePlumber 服務：

  ```bash
  systemctl --user restart wireplumber
  ```

### 4. 從休眠 (Sleep/Resume) 喚醒後音效啞音

* **解決方法**：

  ```bash
  systemctl --user restart wireplumber pipewire
  ```

---

## 🖐️ 指紋辨識問題 (Fingerprint)

### 5. 執行 `fprintd-enroll` 提示 `/dev/cros_fp: Permission denied`

* **根本原因**：當前使用者尚未加入 `plugdev` 群組，或 udev 權限規則未重新載入。
* **解決方法**：

  ```bash
  sudo usermod -aG plugdev "$USER"
  sudo cp fingerprint/60-cros-fp.rules /etc/udev/rules.d/
  sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=misc
  ```

  *(完成後請登出並重新登入)*

### 6. 開機登入時指紋無效，但鎖定螢幕與 `sudo` 可以用指紋解鎖

* **根本原因**：這是 Linux 桌面（如 GNOME / GDM）的安全性架構設計。**GNOME
  Keyring (儲存 Wi-Fi 密碼、瀏覽器密碼之鑰匙圈) 需要使用者的明文密碼進行解密**。
* **解決方法**：冷開機首次登入需輸入一次密碼以解鎖 Keyring，之後的所有鎖定螢幕
  (`Super + L`)、休眠喚醒、PAM 授權與 `sudo` 均可直接秒按指紋。

### 7. 重開機後指紋完全失效（`command failed: UNAVAILABLE` / `INVALID_PARAM`）

* **症狀**：重開機之後，GDM 登入、鎖定螢幕 (`Super + L`)、`sudo` 或任何
  `fprintd-verify` 都不再辨識指紋；`journalctl -u fprintd` 顯示
  `Device reported an error during verify: command failed: UNAVAILABLE`
  （首次嘗試有時會是 `INVALID_PARAM`）。
* **根本原因（分兩層）**：
  1. **協定層** —— FPC1025 Match-on-Chip 感應器由 ChromeOS FPMCU 驅動。FPMCU 上有兩個東西：
     **seed 與 user context (`user_id`)**，兩者都在 FPMCU 的 **RAM（不是 flash）** 裡：seed（與
     `SEED_SET` 旗標）只在*暖*重開機（FPMCU 持續供電）時保留，*冷*重開機會遺失、由主機從
     `/var/lib/fprint/crfpmoc.key` 重新送 `FP_SEED`。crfpmoc driver 的 keys 交握包含一個
     `FP_CONTEXT` 步驟，它會 (1) 重新建立加解密 context，並 (2) 觸發 FPMCU 感應器的
     reset/open（`fp_sensor_open`，約 175 ms）把感應器重新初始化。若該步驟在「seed 已設」時被跳過，
      重開機後感應器就停在未初始化狀態，所有模板操作都會回傳 `EC_RES_UNAVAILABLE`。此問題由某個舊版
      driver（「seed 已設時直接跳到 KEYS_DONE」的那一版）引入。另一個潛在 bug 是 `RESET_SENSOR` 與
     `FP_MODE_FINGER_UP` 的模式衝突（會噴 `INVALID_PARAM`），已在下 `FP_CONTEXT_ASYNC` 前先發
     `FP_MODE=0` 清除模式來修掉。兩者都已在目前的 driver 修好（`crfpmoc_keys_enc_status_cb` 現在
     跳到 `KEYS_CLEAR_MODE`，這是 `KEYS` 子狀態機新增的一步）。
  2. **資料層（為什麼必須重新註冊）** —— 每個模板的解密金鑰是由 seed + 每模板 salt 推導出來的，
     對應 Chromium 自己的設計：`HW_Key = HKDF(SBP_Src_Key, TPM_Seed, User_Salt, User_ID)`
     （<https://chromium.googlesource.com/chromiumos/platform/ec/+/HEAD/docs/fingerprint/fingerprint-authentication-design-doc.md>）。
     在**壞掉**的那版 driver 下註冊的模板，一旦感應器/context 的帶起流程——或
     `/var/lib/fprint/crfpmoc.key` 裡的 seed——改變，就可能無法解密。`user_id` **並不存在模板裡**，
     所以那些模板無論怎麼改 driver 都永遠無法復原。每次 open 都重新建立 context 是*正確*的修法
     （呼應 Chromium 的 `biod` 在每次上傳前都會 `SetContext`），但它意味著壞版 driver 的舊模板必須
     重新註冊。（註：目前的 crfpmoc driver 送的是 zero context，所以實際綁定只是 seed + 每模板 salt。）
* **解決方法**：
  1. 確認已安裝含兩項修復的 crfpmoc（driver 時間晚於 2026-08-15）；必要時重跑
     `fingerprint/install-fingerprint.sh`，再 `sudo systemctl restart fprintd`。
  2. **必須重新註冊指紋 —— 舊模板永久無法解密**：

     ```bash
     fprintd-delete "$USER"
     fprintd-enroll "$USER"
     ```

     （依提示重複按壓同一根手指；像之前一樣把兩隻拇指 / 食指都註冊起來。）
  3. 重新註冊後，跨重開機都能正常驗證，因為新模板是用目前穩定的 seed 檔加密的。
     **絕對不要刪除或重新產生 `/var/lib/fprint/crfpmoc.key`**（必須保持 `root:root`、`0600`）
     ——一旦遺失或權限錯誤，就得冷重開機或重新註冊才能恢復。

### 8. 兩套指紋程式搶佔 `/dev/cros_fp`

* **根本原因**：同一時間只應由一個程式驅動 FPMCU。本專案使用 crfpmoc libfprint driver
  （由 `fprintd` 使用）。另一套專案 **ChocolateLoverRaj/rust-fp**
  （`/usr/local/bin/rust-fp-dbus-interface` 及其 `rust-fp-dbus-interface.service`）
  也會開啟 `/dev/cros_fp`。由於 seed/context/模板是 FPMCU 上的單一全域狀態，兩個程式同時下達
  `EC_CMD_FP_SEED` / `EC_CMD_FP_CONTEXT` / enroll / verify 會互相汙染對方的加解密 context 與解鎖狀態。
* **解決方法**：只保留一套。若已安裝 rust-fp，停用它並改用 crfpmoc：

   ```bash
   sudo systemctl disable --now rust-fp-dbus-interface.service
   sudo systemctl restart fprintd
   ```

   （或移除 rust-fp 的 binary 與 service 後重開機。）

---

## ⌨️ 鍵盤與輸入問題 (Keyboard)

### 9. 頂排功能鍵（上一頁/重新整理/亮度/音量）按了無反應

* **根本原因**：系統缺少 `90-chromebook-keyboard.hwdb` 掃描碼映射，**或**映射的是這台機器根本不會送的掃描碼（例如直接複製別台 Chromebook 的 hwdb）。第二種情況重裝 hwdb 不會修好。
* **解決方法**：

  ```bash
  # 先驗證核心套用的 hwdb 鍵碼映射（唯讀 EVIOCGKEYCODE，不 grab）：
  sudo python3 keyboard/tests/check-top-row-hwdb.py
  # 若失敗，再安裝/重裝映射：
  ./setup.sh --keyboard
  ```

  > 本檔映射的是由 Dratini 的 post-hwdb `EVIOCGKEY` 按鍵狀態對照 AT 表推論的
  > AT 掃描碼 `0x3b`-`0x44`（證據中沒有原始 `MSC_SCAN` 捕獲），且只套用於
  > `keyboard/90-chromebook-keyboard.hwdb` 中明確列出的 Dratini / HP Pro c640
  > DMI 條目——**不匹配**其他 Hatch 機板。其他 Chromebook 可能送 ChromeOS
  > action 掃描碼（`0xea`、`0xe9`…），需要建立自己的 hwdb 條目。`--listen`
  > 只會顯示 hwdb 轉換後的 `KEY_*` 按鍵事件（EVIOCGKEY），不是原始掃描碼。
  > 請先停掉 keyd（`sudo systemctl stop keyd`），用
  > `check-top-row-hwdb.py --scan 60` 或不加 `--grab` 的 `evtest` 讀
  > `EV_MSC/MSC_SCAN`，再對照標準 AT 表推論掃描碼並建立自己的 hwdb 條目
  > （見 `CONTRIBUTING.md` → §2 的「New Chromebook model?」）。未知機型或
  > `EVIOCGKEYCODE` 不支援時，改用 `check-top-row-hwdb.py --scan-only 60`：
  > 它完全跳過表格檢查，fixture 不符或 ioctl 失敗都不會擋住原始擷取。
  > 完成後請執行
  > `sudo systemctl start keyd` 恢復服務，否則 Search 輕點/長按與亮度重映射會持續失效。
  >
  > `RESULT=` 只是 EVIOCGKEYCODE 映射的判定。使用 `--scan SECONDS` 時，
  > 若沒觀測到 `MSC_SCAN`（keyd 仍抓住裝置，或期間沒按鍵），仍會印出
  > `RESULT=PASS (mapping check only; raw capture FAILED)`，但結束碼非 0。
  > 判斷整體成功請看結束碼／`RAW_CAPTURE=`，不要只看 `RESULT=PASS`。

### 10. 想要將 Search 鍵設定為「短按 CapsLock、長按 Super」

* **解決方法**：安裝並啟用 `keyd`：

  ```bash
  sudo apt install -y keyd   # (或 dnf/pacman)
  sudo cp keyboard/keyd/cros.conf /etc/keyd/cros.conf
  sudo systemctl enable keyd
  sudo systemctl restart keyd   # 必要：keyd 2.5.x 只在啟動時讀取設定
  ```

  > Ubuntu 26.04 套件安裝的是 `/usr/bin/keyd.rvaiya`（2.5.0）；
  > `keyd check` 僅存在於 ≥ 2.6。建議直接執行
  > `sudo ./keyboard/install-keyboard.sh --with-keyd`，上述差異它都已處理。
  > 若頂排仍無反應，先驗證**掃描碼**而不是只看 hwdb 文字：
  > `sudo python3 keyboard/tests/check-top-row-hwdb.py` 必須印出
  > `RESULT=PASS`。這台機器送的是 AT 掃描碼 `0x3b`-`0x44`，不是部分
  > Chromebook 使用的 ChromeOS action 掃描碼。
  > 若 Search 輕點/長按異常，請用 `overloadt2(meta, capslock, 200)`，
  > 不要用 `overload`：後者放開時會插入 `LEFTCTRL` 防護，Mutter 就不會開總覽。
  > 驗證請用 `sudo python3 keyboard/tests/capture-keyd-output.py`（唯讀；
  > `keyd monitor` 無法開啟已被 keyd grab 的裝置），並確認 keyd 有 grab 內建
  > AT 鍵盤：`journalctl -u keyd | grep 'DEVICE: match'` 應出現 `0001:0001`。

### 11. 鍵盤背光不會隨螢幕熄滅/點亮而開關

* **症狀**：`c640-kbd-backlight-sync --check` 顯示 `brightness: 5/100` 但 `--test-blank`
  不會到 `0` 或不會恢復；`journalctl --user -u c640-kbd-backlight-sync` 空白或 `Daemon running: no`。
  另一相關症狀是**閃爍/震盪**：LED 在熄滅/點亮前後於已存值與最大亮度間反覆跳動，
  通常是 gsd-power 快取與 UPower 不一致，或 ScreenSaver 複查競態。

  > [!IMPORTANT]
  > 真實 S3 週期中，systemd 會在 sleep hook 的 `post` 階段前**凍結 `user.slice`**
  > （[systemd-sleep(7)](https://www.freedesktop.org/software/systemd/man/latest/systemd-sleep.html)）。
  > 因此從 root hook 查詢 session bus 必然失敗或 timeout；hook 現在是**純 handoff 寫入者**：`pre` 發佈
  > `c640-kbd-backlight.suspend`（單一整數，`0` 有效），`post` 發佈
  > `c640-kbd-backlight.resume`（`<epoch> <action>`），兩者皆 `0600` + chown 給
  > session user + 原子 `mv` 進 `$XDG_RUNTIME_DIR`（`C640_KBD_HANDOFF_DIR` 可覆寫）。
  > 它絕不寫 LED、不刪 state、不查 D-Bus。唯一寫入者是 thaw 後的**使用者 daemon**：
  > 它在 **system** bus（未被凍結）收到 `PrepareForSleep(false)` 時 adopt handoff，
  > 再經 gsd-power → UPower → legacy 還原。請勿把舊的 root 端 session bus 探測
  > 加回 hook——那就是當年第二寫入者的 bug。`pre` 寫入的 root
  > `/run/c640-kbd-backlight/state` 只是**本次開機第一次 suspend 的單次診斷快照**
  > （first-wins，保留到重開機），hook 與 daemon 都不消耗它，也從不用於還原。

* **排解**（以下 gdbus 查詢皆為唯讀）：

  ```bash
  c640-kbd-backlight-sync --check          # brightness、STATE_FILE、Daemon running、ScreenSaver available
  systemctl --global is-enabled c640-kbd-backlight-sync.service
  systemctl --user is-active c640-kbd-backlight-sync.service  # 需 graphical-session
  journalctl --user -u c640-kbd-backlight-sync.service -f
  loginctl show-user "$USER" -p State       # 使用中?
  udevadm test /sys/class/leds/chromeos::kbd_backlight  # 檢查 TAG+="uaccess" 規則
  ls -l /sys/class/leds/chromeos::kbd_backlight/brightness  # 0660 + plugdev?
  cat /sys/class/leds/chromeos::kbd_backlight/brightness
  # 唯讀 handoff 檔（僅在休眠/喚醒週期間存在）：
  cat "$XDG_RUNTIME_DIR/c640-kbd-backlight.suspend" 2>/dev/null  # 已存值，0 有效
  cat "$XDG_RUNTIME_DIR/c640-kbd-backlight.resume" 2>/dev/null   # "<epoch> <action>"
  # 唯讀 D-Bus 查詢（不寫入，daemon 執行中也能跑）：
  gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.GetActive
  gdbus call --session --dest org.freedesktop.ScreenSaver --object-path /org/freedesktop/ScreenSaver --method org.freedesktop.ScreenSaver.GetActive
  gdbus call --session --dest org.gnome.SettingsDaemon.Power --object-path /org/gnome/SettingsDaemon/Power --method org.freedesktop.DBus.Properties.Get org.gnome.SettingsDaemon.Power.Keyboard Brightness
  gdbus call --system --dest org.freedesktop.UPower --object-path /org/freedesktop/UPower/KbdBacklight --method org.freedesktop.UPower.KbdBacklight.GetBrightness
  # gsd 百分比應約等於 raw/max*100；不一致就可能閃爍
  # 非 GNOME（Sway/KDE）：org.gnome.ScreenSaver 不可用 -> daemon 僅靠 org.freedesktop.ScreenSaver + system-sleep 兜底
  # 最小映象缺 gdbus/dbus-monitor：sudo apt install dbus-x11 libglib2.0-bin
  # ectool 回退：ls -l /usr/local/bin/ectool && ectool pwmgetkblight
  # 三態：只有 ScreenSaver "inactive" 允許還原寫入（active/unknown 皆延後）
  ```

  **日誌驗證**：unit 設了 `StandardError=journal`，下列訊息應該可見；若沒有，
  代表安裝的是舊 unit 或 stderr 被導向別處：

  ```bash
  journalctl --user -u c640-kbd-backlight-sync.service --since "5 min ago" \
    | grep -E 'backends probed|RECOVERED|saved brightness|replacing invalid saved brightness|restoring brightness|restore verify|not completed|adoption deferred|restore deferred|resume deferred|unblank: restore deferred|ignoring blank-side|brightness NOT saved|deferred save attempt|restore failed|another restore is in progress|\[WARN\]'
  ```

* **常見修復**：
  * 安裝後**重新登入**（`plugdev`/`uaccess` ACL），或 `systemctl --user start c640-kbd-backlight-sync.service`。
  * 若未 enable：`sudo systemctl --global enable c640-kbd-backlight-sync.service && systemctl --user daemon-reload`。
  * KDE/Sway 上 `ScreenSaver available: no` 時，`system-sleep` 仍會在盒蓋
    `suspend` 時發佈 handoff 檔，但還原由 thaw 後的使用者 daemon 負責，請保持啟用；
    閒置熄屏需啟用 IdleMonitor：見 `keyboard/README.zh-TW.md` `C640_KBD_ENABLE_IDLEMONITOR=1`。
  * `brightness` 權限不足：檢查 `groups` 含 `plugdev`，或 `udevadm trigger --subsystem-match=leds`。
  * Ubuntu 26.04 上，LED 屬性只有在 udev 規則的 `RUN+=chgrp plugdev` +
    `RUN+=chmod 0660` 生效時才可寫（實測為 `-rw-rw---- root plugdev`）。
    `MODE=`/`GROUP=`/`uaccess` 無法 chmod sysfs；若
    `ls -l /sys/class/leds/chromeos::kbd_backlight/brightness` 顯示 `root root 0644`，
    請執行 `sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=leds`，
    daemon 才不會退回 `sudo -n tee`。
  * 根因判斷：使用者 service 無法互動輸入 sudo 密碼。若
    `journalctl --user -u c640-kbd-backlight-sync` 出現 `sudo: a password is required`，
    表示問題在上述權限路徑，而非 D-Bus 事件。
  * 閃爍/震盪：檢查上面的唯讀查詢。若 gsd-power 的 `Brightness` 百分比與
    UPower raw 值不一致，daemon 會記錄
    `[WARN] gsd-power set ... forcing UPower + property refresh`；請確認部署的
    daemon/unit 與 repo 完全一致（smoke 測試會檢查），並避免其他工具直接寫 LED。
    若還原時 ScreenSaver 為 `true` 或 `unknown`，延後是預期行為——等待
    `+0.5s/+1.5s/+3s` 重試或解鎖工作階段。hook 已完全不再探測 session bus。
  * `resume deferred: ScreenSaver still active`／`... unknown ... deferring restore`
    代表三態防護正常運作；請保留 state 並等待解鎖。
    `C640_KBD_RESUME_ALLOW_UNKNOWN=1` 是明確的**風險接受**（可能在仍鎖定的螢幕下
    點亮鍵盤），預設關閉；`C640_KBD_RESUME_PROBE_MAX` 限制 thaw 後的輪詢（預設 10 秒）。
  * `ignoring blank-side suspend handoff 0; keeping saved user brightness N` 代表
    休眠開始時螢幕已熄滅：hook 讀到的硬體 0 被正確忽略，解鎖後會還原使用者的亮度 N
    （已於真實 S3 週期驗證——見 [verification.md §3](verification.md)）。
  * `restore failed (... rc=1): keeping brightness N for retry` 或 `another restore is
    in progress` 代表 `c640-kbd-backlight.restore-pending` 中的暫存值會保留供重試；
    當機則在 daemon 啟動時復原。`RECOVERED (0 -> 1)` 代表先前缺失的 gsd-power/UPower
    D-Bus name 回來了，daemon 重新探測後切回 gsd 單一寫入者。
  * `blank: brightness NOT saved (rc=...)` / `blank: deferred save attempt N failed
    (rc=...)` 代表熄滅時無法保存新亮度。daemon 會**保持 LED 亮著**（不讓畫面全暗卻無值
    可還原），並把擷取值留在 last-user cache。請檢查 `C640_KBD_SAVE_LOCK_WAIT`
    （預設 2 秒）：緩慢的還原可能佔住 `STATE_LOCK` 導致 `save_state` 逾時。
    `save_state` 的 rc：`0` = 已保存、`1` = 鎖等待失敗、`2` = 選值/寫入失敗。熄滅時
    **只取樣一次**，第一次 `save_state "$captured"` 就直接使用該值（不會再取樣第二次而
    讀到 blank-side 的 `0`、存進過期快取值）；只有擷取值為空時才會讓 `save_state` 自行取樣。
  * `replacing invalid saved brightness with N` 代表 state 檔內容為空白、非數字、多列或
    二進位。first-wins 只保護**有效的**已存整數：在 `STATE_LOCK` 內，損毀的檔案已被以熄滅前
    擷取的亮度原子取代。真正寫入失敗仍回 rc `2` 並保持 LED 亮著；上述的 rc 與重試語意不變。
  * 喚醒路徑使用結果碼 `0 = RC_DONE`（寫入已驗證，`STATE`/`restore-pending` 已消耗）、
    `1 = RC_FAIL`（輸入無效／I/O 錯誤）、`2 = RC_DEFER`（鎖競爭、暫存還原仍在進行，
    或 ScreenSaver active/unknown）。只有 `RC_DONE` 會消耗 resume flag 與 handoff 檔；
    `RC_DEFER` 保留 flag/handoff/state 並排定重試供 sampler 或下次 unblank 使用；
    `RC_FAIL` 保留 resume flag，但 saved state 可能已被消耗（僅 last-user cache 留有
    擷取值）；寫入/finalize 失敗且 state 仍在時仍會重排 +0.5/+1.5/+3s 重試，而 verify 或 adoption 失敗則不排。`restore verify (gen=...): ... not
    completed`、`suspend handoff adoption deferred`、`unblank: restore deferred` 都是
    重試訊號而非失敗——等待下一次輪詢或解鎖工作階段即可。
  * `MANIFEST_INVALID ... original bytes left untouched` 來自**安裝器**而非 daemon：
    `/var/lib/cros-enablement/install-manifest.json` 已損毀，因此備份/寫入路徑 fail
    closed，原檔保持位元組不變。**欄位型別錯誤**現在也是 manifest 無效的原因，不只是
    JSON 格式錯誤：record 的 `target` 必須是無 NUL 的絕對路徑字串，`component`/
    `installed_at`/`version`/`scope` 若存在必須是字串；安全欄位
    `was_existing`/`was_enabled`/`was_active`/`was_member` 為**必填布林**（缺失代表
    未知，絕非 `false`；字串 `"false"` 與數字 `1` 會被拒絕，不轉換）。service 的
    `name`/`component` 與 group 的 `group`/`user`/`component` 為必填，其他選用欄位可
    缺席（legacy v1），未知 key 忽略。`groups[*].added_by_project` 是**選用**的逐次安裝
    布林（缺席＝legacy `false`，代表「沒有額外證據」）；出現但型別錯誤同樣是
    `MANIFEST_INVALID` 並 fail closed，絕不會被當成權限證據。重裝前請修復或明確移除它；
    切勿把無效的 manifest 當成空 manifest。
  * `skipping manifest entry with non-absolute target` 代表安裝器略過了無法作為 record
    `target` 的 pseudo-target（例如指紋的 `package:libfprint-crfpmoc`），這不是錯誤。
    `rollback of <component> failed; service/file state may be partial (retained records
    remain for retry)` 代表還原腳本執行到一半失敗（服務先於檔案還原）且 rollback 回傳
    rc 1——保留的紀錄可供下次重試。rollback、uninstall 與移除群組組成員都會在任何
    `systemctl disable keyd` / `gpasswd -d` / 檔案副作用**之前**先驗證 manifest，無效即
    fail closed。
  * `RECORD_STATE_UNKNOWN` / `SERVICE_STATE_UNKNOWN` 代表原始狀態快照缺失或不是布林。
    rollback 視之為**未知，絕非 false**：不刪除/不還原該檔、不啟用/停用/啟動/停止該服務，
    並保留紀錄且回 rc 1。keyd 也不會被停用——`_keyd_managed_by_us()` 需要有效的布林服務
    快照才會停用/停止 keyd。
  * `[WARN NO BACKUP]` 代表 `was_existing` 目標找不到第一份備份；紀錄會保留（不會憑空
    建立檔案），供日後重試還原。自第九次 re-review 起這是真正的失敗：會記錄
    `RECORD_BACKUP_MISSING` 問題並印出 `ROLLBACK_INCOMPLETE: N item(s) retained`，因此
    rollback 結束碼為 rc 1（不印 `finished!`），但其他可處理的項目仍會正常 rollback。
    RC/重試語意不變——備份可用後重跑 uninstall 即可。`[RESTORED PREVIOUS BACKUP] <backup>
    -> <target>` 代表即使安裝的檔案已不存在，仍從最早符合的備份重建原檔。
    `RECORD_RESTORE_FAILED` / `RECORD_REMOVE_FAILED` 代表檔案操作失敗，紀錄保留供重試。
    還原取代失敗時不會先 unlink 已安裝的目標（普通檔案/symlink 使用單次原子
    `os.replace()`）。
  * `SERVICE_RESTORE_FAILED` / `ROLLBACK_INCOMPLETE` 代表至少一個 `systemctl`
    enable/disable/start/stop 回傳非 0（或 timeout／spawn 失敗），或有像找不到備份的紀錄
    被保留；這些紀錄會保留供重試，rollback 回傳 rc 1。修好根本問題後重跑 uninstall
    即可——成功的還原會記錄 `[RESTORED SERVICE]`。
  * `Manifest lock wait failed (rc=... after ...s) ... (holder: ...)` 或 `flock not found`
    來自跨程序鎖。自第十次 re-review 起這是**操作級鎖**：`run_manifest_operation()` 在整個
    元件安裝/解除安裝（備份/紀錄 → 部署檔案與服務 → 完成/回滾）期間持有它，因此平行程序
    不會在目標檔缺席時消耗剛寫入的紀錄，留下沒有 manifest 紀錄的已部署檔案。等待上限為
    `CROS_ENABLEMENT_MANIFEST_LOCK_TIMEOUT`（預設 10 秒），鎖檔為 root 擁有的 `0600` 檔案
    `$MANIFEST_DIR/.install-manifest.lock`（fd 9，由短暫的 `coproc sudo bash -c` root helper
    持有）；逾時、缺少 `flock` 或任何驗證失敗都會 fail closed 且保持 manifest 位元組不變
    （回傳非 0）。`flock not found` 代表未安裝 `util-linux`。每個 writer 使用唯一的
    `.install-manifest.*.tmp` 暫存檔（fsync + `chmod 0644` + `os.replace`），平行程序不會
    互相遺失 first-wins 紀錄。等另一程序結束後重試；若
    `fingerprint/install-fingerprint.sh --source` 仍在建置並持鎖，請調高 timeout（例如 300）。
  * `Manifest directory ... must be an absolute path; refusing to lock` 代表
    `CROS_ENABLEMENT_MANIFEST_DIR` 是相對路徑。請改用絕對路徑（通常是
    `/var/lib/cros-enablement`）；信任邊界無法針對曖昧的 CWD 評估。
    `Manifest lock directory ... contains a symlink (...); untrusted symlink; refusing to
    lock` 代表路徑上有字面 symlink component。自第十二次 re-review 起，**任何**字面
    symlink component 一律拒絕，即使是 root 擁有、其他方面安全的 symlink：symlink 可能
    把真正的目標隱藏在使用者可寫的樹中，其擁有者能重新命名鎖。請改用真正的目錄
    （這是刻意採取的 fail-closed 取捨，比舊版「信任的 symlink」放行更嚴格）。
    `Manifest lock canonical path ... has an untrusted realpath ancestor; refusing to lock`
    （`untrusted realpath ancestor`）代表**真實**路徑——以 `realpath -e` 解析最深的存在
    前綴再加上缺少的層——有非 root 控管的祖先。請修正該真實祖先的擁有者/權限，
    不要用另一個 symlink 繞過。
  * `... (holder: FAILED:symlink)`、`FAILED:type`、`FAILED:open`、`FAILED:inode`、
    `FAILED:canonical`、`FAILED:ancestor`、`FAILED:parentdir` 或 `FAILED:flock` 是
    root helper 拒絕取鎖的原因。`FAILED:symlink` /
    `FAILED:type` / `FAILED:inode` 代表鎖路徑是 symlink、非普通檔（例如目錄或 FIFO），或在
    init 與 open 之間被替換：helper 會在**實際持有 fd 9 的行程內**以 `/proc/$$/fd/9` 比對
    路徑的 `(dev,ino)`，並檢查 owner 為 `0`、mode 為 `600` 與普通檔型別，因此非特權的
    inode 替換無法轉移 flock。`FAILED:flock` 是一般的鎖競爭。這些檢查若在 helper 啟動前
    就失敗，會記錄 `Manifest lock path ... is a symlink` / `is not a regular file` /
    `is not a root-owned 0600 regular file (uid=... mode=...)`。
    **`FAILED:canonical`** 代表 holder 在實際持有 fd 9 的行程內重新導出
    `realpath -e "$dir"`，結果不再等於 gate 交下的 canonical 目錄——gate 執行後有人換入
    symlink。**`FAILED:ancestor`** 代表直接父目錄之上的**真實**祖先不是 uid `0`，
    或為群組/其他可寫但不是 root 擁有的 sticky 世界可寫層（例如 `/tmp` `1777`）。
    兩者都會在任何 `flock` 前中止且保持 manifest 位元組不變；修正路徑後重試。
  * `FAILED:parentdir` 代表 root holder 以 fd 8 釘住鎖的**直接父目錄**失敗：父目錄不是
    root 擁有、群組/其他可寫、不是目錄，或其 `(dev,ino)` 與路徑不符。這防堵以下競態：
    A 持鎖中，父目錄擁有者把路徑重新命名，B 便對全新的 inode 取到第二把鎖。請檢查
    目錄的擁有者/權限後重試；manifest 位元組保持不變。
  * `Manifest lock parent ... is group/other-writable (mode ...)`、`is owned by uid ... (must
    be root-owned)`、`is a symlink or not a directory` 或 `Cannot stat manifest lock parent
    ...` 代表直接父目錄不受信任，安裝器不會對鎖做任何特權 chmod/chown/open。請讓
    `/var/lib/cros-enablement` **由 root 擁有**且權限為 `0755`；目前 EUID/UID 擁有不再接受
    （呼叫者擁有的父目錄可以重新命名有效的鎖），`0775` 群組可寫目錄會 fail closed，
    sticky bit 也不能豁免直接父目錄。每一層祖先目錄也都會檢查：`Manifest lock ancestor ...
    is not root-controlled (uid=... mode=...)` 拒絕非 root 擁有或群組/其他可寫但**沒有**
    sticky bit 的層（root 擁有且具 sticky 的世界可寫層，例如 `/tmp` `1777`，可通過）；
    `Manifest lock ancestor ... is an untrusted symlink` 拒絕 symlink，除非其所在目錄由
    root 擁有且不可群組/其他可寫。此外，字面路徑檢查現在會在正規化前拒絕**任何** symlink
    component（`contains a symlink`），canonical 路徑的祖先也一併檢查
    （`untrusted realpath ancestor`）。因此自訂在使用者可寫目錄下的 lock parent 即使鎖檔
    本身是 root 擁有，仍會被拒絕。
  * `Could not set manifest lock mode to 0600` / `Could not set manifest lock owner to root`
    代表鎖無法被設為 root 擁有的 `0600`（舊的 `0644` 鎖會自動升級），安裝器因此 fail closed。
    peer 帳號直接開啟 `$MANIFEST_DIR/.install-manifest.lock` 時看到 `permission denied` 是
    預期行為，正是 DoS 防護：只有短暫的 root holder（透過 passwordless `sudo`）會開啟 fd 9。
    請勿以非特權使用者手動 chmod/chown 鎖檔——修正 `sudo` helper 或父目錄權限後重試。
  * 群組 membership 現在**先記錄再執行 `usermod`**：安裝器先將原始 `plugdev` 成員資格
    寫入 manifest，再明確檢查 `usermod` 的 rc（移除 `|| true`）；若變更失敗且先前沒有
    紀錄，就移除剛寫入的紀錄。共用的歸屬探測在至少一筆明確為 `was_member=false`，**或任一
    紀錄帶有 `added_by_project=true`** 時回 rc 0（兩者都證明是我們加入的），**沒有紀錄**
    回 rc 1（`No group record for '<user>'@'<group>'; nothing to roll back.`），**全部皆為
    `was_member=true` 且沒有該 flag** 回 rc 3（原本就存在），欄位型別錯誤
    回 rc 2（`Cannot determine original membership of <user>@<group>; refusing to change it`，
    rc 1）。first-wins 不變：rc 0 才執行 `gpasswd -d`，而仍引用該 group 的 udev rule 會
    保留成員資格。**rc 3 時完全不呼叫 gpasswd**：若仍有 udev rule 引用該 group，會記錄
    `udev rules still reference group '<group>'; keeping '<user>' in it (all records
    pre-existing).` 並保留快照；一旦沒有 rule 引用它（所有使用該 group 的元件皆已卸載），
    會記錄 `All records pre-existing and no udev rule needs '<group>'; consuming stale
    records for '<user>'@'<group>' (membership unchanged).` 並以**零次 gpasswd** 消耗全部
    紀錄，讓下次安裝重新擷取真實的成員資格（例如管理員已變更）。消耗失敗會記錄
    `Could not consume stale group records for '<user>'@'<group>'; keeping them for retry.`
    （rc 1）。rc 0 時，uninstall 只有在 `gpasswd -d` 成功後才消耗該組的所有元件紀錄
    （`manifest_remove_group_all`），因此模組解除安裝順序不會留下過期的 `was_member` 紀錄。
    若重裝時原始 `was_member=true` 但使用者目前**不是**成員（管理員在元件仍安裝時移除了），
    writer 會在未變動的 first-wins 快照旁記錄 `added_by_project=true`，探測因此回 rc 0，讓
    uninstall 移除本次授予的成員資格。若 `usermod -aG` 失敗，`manifest_clear_group_added` 只清除
    **該 flag**（`Could not clear added-by-project evidence for <user>@<group>; kept for
    manual cleanup` 代表清除本身失敗）；consume-all 則連整列（含 flag）一起移除。
  * `Could not remove '<user>' from group '<group>'; keeping manifest records for retry.`
    代表 `gpasswd -d` 失敗。現在這是**真正的失敗**（log_error、rc 1）：三個元件 uninstaller
    會捕捉它並折進結束碼，因此完整的 `./setup.sh --uninstall` 不會在成員資格仍存在時回報
    成功。請修正群組/權限問題後重跑 uninstall；紀錄會保留供重試。移除成功後 manifest
    寫入失敗時，`Could not consume group records for '<user>'@'<group>'; keeping them for
    retry.` 有相同的 rc 1／重試語意。
  * `Manifest still records /etc/pam.d/sudo: rollback did not restore it. Uninstall did NOT
    modify this file; remove the project line manually if needed.` 來自唯讀的 rollback 後
    PAM 檢查：uninstall 絕不對 sudo PAM 執行 sed（所有檔案還原都由
    `rollback_component("fingerprint")` 負責），因此原本就存在的精確 `pam_fprintd` 行不會
    被刪除。若 manifest 損毀，則改為警告 `Manifest at ... is corrupt/invalid; cannot confirm
    rollback of /etc/pam.d/sudo. Uninstall did NOT modify this file.`——兩種情況都只警告。
    Debian/Ubuntu 上，原始 `common-*` 位元組會先備份（**所有**現有的檔，不只含 fp 者）並由
    rollback 還原。安裝時**直接**以 `sed -i '/pam_fprintd\.so/d'` 移除 fp 行（記錄
    `Removed pam_fprintd.so line(s) from ...`），**絕不呼叫** `pam-auth-update --remove
    fprintd`——該動作會直接刪除 debconf 的 `libpam-runtime/profiles` selection。由於日後
    `pam-auth-update --package` 會從當前的 `common-*` 內容推導 profile 清單，若不處理便會
    永久丟失 fprintd，安裝時會把 selection 與 `/var/lib/pam/*` 快照到 first-wins sidecar，
    並自行執行一次 `pam-auth-update --package` 收斂到穩定的「無 fprintd」狀態（日後套件
    觸發的執行即為 no-op）。uninstall 只有在 rollback 完成後才從該快照還原。Fedora 的
    `authselect` 與 openSUSE 的 `pam-config` profile 狀態不在 manifest 內，請依警告手動
    還原原本的 profile。
  * `Snapshotted the PAM profile selection to <path>` / `Keeping the existing PAM selection
    snapshot at <path> (first-wins).` 是安裝時的 sidecar 日誌。sidecar
    （`<manifest-dir>/pam-selection`）存放原始 debconf `libpam-runtime/profiles` multiselect；
    `<manifest-dir>/pam-selection.saved` 則是 root 擁有、`0700` 的目錄，存放 `/var/lib/pam`
    下每個檔案的副本。兩者都以 `sudo` 一次性、first-wins 發佈（`pam-selection` 檔為 `0644`），
    所有讀取/複製都經由 `sudo`，讓搭配 passwordless `sudo` 的非 root uninstall 也能還原；
    `Could not read debconf libpam-runtime/profiles; ... will be empty.`、
    `Could not write the PAM selection snapshot; ...` 與 `Could not snapshot every saved PAM
    profile file; ...` 代表快照不完整——uninstall 將無法完整還原原始狀態，請手動檢查這些檔案。
    `pam-auth-update --package converged the debconf selection and saved profiles (no
    fprintd).` 是預期的自我收斂日誌；`pam-auth-update --package failed; keeping the selection
    snapshot for uninstall convergence.` 則保留 sidecar。
  * `No PAM selection snapshot at <path>; nothing to restore.` 代表沒有支援 fprintd 的安裝
    留下 sidecar，因此沒有需要收斂回去的狀態。`Original PAM profile selection restored;
    snapshot consumed.` 是成功路徑：rollback 確認完成後，先複回 `.saved` 檔案，再以
    `debconf-set-selections` 寫入 multiselect、重跑 `--package` 並驗證線上 selection。
    `Manifest still records <path>: rollback is incomplete, leaving the PAM selection snapshot
    for retry.` 或 `Manifest at ... is corrupt/invalid; leaving the PAM selection snapshot
    for retry.` 代表刻意**沒有**更動 debconf；請完成 rollback（或修復 manifest）後重跑 uninstall。
  * `debconf-set-selections is unavailable; keeping <path> for retry.` 與
    `debconf-set-selections failed; keeping <path> for retry.` 代表 selection 無法寫入——
    sidecar 與 `.saved` 快照會保留供日後 uninstall；請安裝 `debconf`（或修好 `sudo` helper）
    後重試。`The PAM selection snapshot is empty; cannot restore the debconf selection.` 代表
    只有 `.saved` 檔案被還原。`Could not restore every saved PAM profile file from the
    snapshot.` 代表部分 `/var/lib/pam` 檔案可能仍停留在收斂後的無 fprintd 狀態；請重裝或
    手動還原。
  * `PAM selection restore verification failed: expected '<a>', got '<b>'. Keeping <path> for
    retry.` 是 fail closed 的比對失敗（rc 1，保留 sidecar）。比對接受**精確比對或忽略空白／
    順序的集合比對**：`pam-auth-update` 會把 multiselect 正規化為 "a, b, c"，因此原始值順序
    或空白不同沒關係，但 profile **集合**不同則不接受（管理員日後刻意的變更不會被悄悄接受）。
    **取捨**：快照具有最終權威，因此安裝期間變更 selection，會在 uninstall 時被覆寫；
    安裝期間手動啟用 fprintd profile（`pam-auth-update --enable fprintd`）會把 fp 行寫回
    `common-auth`，直至 uninstall 前都恢復 GDM 競賽。

---

## 🔋 電源管理與待機問題 (Power & Suspend)

### 12. 蓋螢幕休眠一整夜耗電過多 (超過 5~8%)

* **根本原因**：Intel AX201 Wi-Fi 背景喚醒 (WoWLAN) 或 PCIe ASPM 節能未完全
  啟用，導致 SoC 無法進入低功耗 Package C10 (SLP_S0#) 狀態。
* **解決方法**：
  1. 停用 Wi-Fi 睡眠喚醒：

     ```bash
     sudo iw phy phy0 wowlan disable
     ```

  2. 在 `/etc/default/grub` 中的 `GRUB_CMDLINE_LINUX_DEFAULT` 加上 `pcie_aspm=force`，並執行 `sudo update-grub`。
  3. 安裝 `tlp` 或 `power-profiles-daemon` 管理省電狀態。

### 13. 蓋上螢幕筆電不會休眠

* **解決方法**：確認 `/etc/systemd/logind.conf.d/99-hp-c640-lid.conf`
  （由 `./power/install-power.sh` 安裝）或 `/etc/systemd/logind.conf` 中設定：

  ```ini
  [Login]
  HandleLidSwitch=suspend
  HandleLidSwitchExternalPower=suspend
  ```

* **⚠️ 修改 logind 設定後請「重新開機」，不要執行 `systemctl restart
  systemd-logind`**：
  在桌面 session 進行中重啟 `systemd-logind` 會**登出所有已登入使用者**
  （session leader 在 deserialization 時遺失，導致整個 GNOME session 崩潰、
  使用者 manager 被強制結束，甚至看起來像系統當機）。而且新設定本來就要
  下次登入/開機才生效，所以重新開機（或登出再登入）才是正確且唯一安全的
  套用方式。

  ```bash
  # 不要這樣做：
  sudo systemctl restart systemd-logind

  # 請這樣做——重新開機後蓋螢幕規則即生效：
  sudo systemctl reboot
  ```

  *（2026-08-18 實測：重啟 systemd-logind 在 HP Pro c640 上引發完整登出風暴，
  外觀上如同系統當機。）*

### 14. 休眠喚醒後（或鎖定後立刻）鎖定畫面沒有指紋提示

* **症狀**：盒蓋休眠後打開（或鎖定後馬上操作），解鎖畫面**沒有指紋提示、
  碰觸感應器無效**。按 `Esc` 重新進入登入畫面後指紋恢復正常。
* **根因**：兩個 PAM worker 的裝置 Claim 競賽。解鎖時 GDM **同時** fork
  `gdm-password` worker 與 `gdm-fingerprint` worker，兩者的 PAM stack 原本都
  含 `pam_fprintd`：`gdm-password` 從 `common-auth` 引入（fprintd profile 經
  `pam-auth-update` 啟用時），`gdm-fingerprint` 則有
  `auth required pam_fprintd.so`。fprintd 一個裝置只允許**一個 Claim**；
  password worker 先 fork、先搶到，fingerprint worker 收到
  `Authorization denied ... Device was already claimed`，整個 fingerprint
  服務失敗，GNOME Shell 便隱藏指紋提示。休眠後重認證在喚醒後 ~400ms 就開始，
  使競賽結果變成必然。
* **證據**：

  ```text
  fprintd: Authorization denied to :1.142 to call method 'Claim' for device
  'ChromeOS Fingerprint Match-on-Chip': Device was already claimed
  ```

  上游追蹤：GNOME/gdm#1071、libfprint/fprintd#214、
  GNOME/gnome-shell#7791（至 2026-08 皆未修復）。
* **解決方法（2026-08-18 起本專案安裝器已內建）**：讓 `pam_fprintd` **不要
  出現在 `common-auth`**，指紋只在 sudo 啟用（`/etc/pam.d/sudo` 加入
  `auth sufficient pam_fprintd.so`）。GDM 登入畫面與鎖定畫面仍透過專屬的
  `gdm-fingerprint` PAM 服務運作，從此必定搶到 Claim。

  ```bash
  # Debian/Ubuntu 上安裝器實際執行的動作：
  # 先備份原始 common-* 位元組（Tier 2），再只移除 fp 模組行。
  # 切勿使用 `pam-auth-update --remove fprintd`：它會靜默刪除 debconf 的 profile
  # selection，而 manifest 無法還原。
  sudo sed -i '/pam_fprintd\.so/d' /etc/pam.d/common-auth
  sudo sed -i '/^@include common-auth$/i auth sufficient pam_fprintd.so max-tries=1 timeout=10' /etc/pam.d/sudo
  ```

  *（這也消除了 sudo 的競賽窗口——見第 8 節「單一 stack」原則。）*
* **手動復原（舊安裝適用）**：按 `Esc` 取消失敗的解鎖回合再重新解鎖——
  新 worker 會乾淨地重新 Claim。或先執行 `sudo systemctl restart fprintd`
  再解鎖。
* **PAM 修復後的殘留問題（喚醒後 FPMCU open 立即失敗）**：即使競賽已消除，
  喚醒後的**第一次**解鎖仍可能失敗：claim 成功但 crfpmoc 的**裝置 open 瞬間
  失敗**（S3 喚醒後頭 ~2 秒 EC/FPMCU 通道尚未就緒），`pam_fprintd` 回傳錯誤、
  Shell 不顯示指紋提示（此情況沒有 `already claimed` 日誌——2026-08-19 以
  `G_MESSAGES_DEBUG=fprintd` 證實：只有 `claiming the device: 0`、沒有
  `claimed device 0`）。本專案提供兩道互補的修復：
  1. **驅動層 open 重試（真正的修復，2026-08-19 起）**：audited `crfpmoc`
     驅動在喚醒後 EC 通道回報 I/O 或 EC 錯誤時，以有限預算
     （`CRFPMOC_OPEN_MAX_RETRIES` × 500ms）重試 open SSM。正常 open 第一次
     即成功、**零額外延遲**；只有失敗的 open 才會等待。
  2. **system-sleep hook 衛生機制**：`fingerprint/systemd/fprintd-sleep.sh`
     在睡前停止 fprintd，確保喚醒後一定是全新 daemon。

  盒蓋測試後驗證：

  ```bash
  journalctl -b -e -u fprintd | grep -E "claim|open|retry"
  # 預期：喚醒後第一次 claim 就出現 "claimed device 0"
  #       （若 EC 通道需要時間，才會看到 "retrying" 行）
  ```

  *（若仍失敗：在 fprintd.service drop-in 暫時加
  `Environment=G_MESSAGES_DEBUG=fprintd`，再重複盒蓋測試以捕捉驅動錯誤。）*

### 15. 開蓋喚醒後螢幕全黑（需按鍵/點擊才亮）

* **症狀**：盒蓋休眠（S3 `deep`）後打開，系統已喚醒（`PM: suspend exit`）
  但面板**全黑**，直到按鍵或點擊才亮。不是當機——輸入一到鎖定畫面即正常。

  > [!NOTE]
  > 開蓋後**鍵盤**背光偏暗也是預期行為：thaw 後的 daemon 會等到 ScreenSaver 明確為
  > `inactive` 才還原（`resume deferred: ScreenSaver still active`）。解鎖工作階段
  > 即會還原（例如 `restoring brightness 30`）。這是 §11 所述的 fail-closed 三態
  > 防護，不是上面的顯示面板問題。

* **根因（2026-08-18 兩個候選機制）**：
  1. **GNOME 使用者層再次黑屏**（最可能，符合「按鍵即恢復」特徵）：
     `gsd-power` 在休眠時關閉面板；螢幕護盾的鎖定動畫在顯示器關閉期間停滯，
     resume 後動畫完成、電源外掛又把螢幕**關回去**（GNOME/mutter#4111，
     修補候選 gnome-shell!3742——尚未合併）。
  2. **Comet Lake 的 i915 PSR resume bug**（gitlab.freedesktop.org/drm/i915），
     或 kernel 7.0 的 eDP 背光回歸（drm/i915/kernel#16791、#16825）。
     可能性較低——那些 bug 不會因按鍵而恢復。
* **解決方法（本專案）**：`power/install-power.sh` 的 modprobe 調校
  `options i915 enable_psr=0 enable_fbc=1 enable_guc=2` 是 repo 針對
  休眠/喚醒黑屏的候選對策。2026-08-19 已安裝並重開機，但**未解決本機的
  黑屏問題**（仍須按鍵才亮——使用者已接受此行為；見
  [VERIFICATION.md](verification.md)）。如想試用請套用後重開機：

  ```bash
  ./power/install-power.sh   # 或手動：
  sudo install -D -m 0644 power/modprobe.d/99-hp-c640-power.conf \
      /etc/modprobe.d/99-hp-c640-power.conf
  sudo update-initramfs -u
  sudo systemctl reboot
  ```

  > [!NOTE]
  > kernel ≥ 7.0 時安裝器會自動移除已刪除的 `iwlwifi d0i3_disable`
  > 參數（見該檔註解標頭）。
* **若 `enable_psr=0` 後面板仍黑**：在 `/etc/environment` 試
  `MUTTER_DEBUG_FORCE_KMS_MODE=simple`（隔離 atomic-KMS resume 路徑，見
  drm/i915/kernel#16825），或用 `busctl monitor` 監看
  `org.gnome.SettingsDaemon.Power` 是否有 resume 後再度關閉螢幕的事件
  （可證實使用者層再黑屏假說）。回報至 GNOME/mutter#4111。

### 16. 電池充過 90% 或出現 `ERROR: Old EC doesn't support sustainer`

* **症狀**：下達 `ectool chargecontrol normal 80 90` 出現 `ERROR: Old EC doesn't support sustainer`，
  或是系統在重開機、S3 休眠喚醒後充超過 90%。
* **根本原因**：
  1. HP Pro c640 (Dratini) 搭載 ChromeOS EC v1 韌體 (`dratini_v2.0.2851`)。EC v1 僅支援硬體狀態切換
     (`normal`, `idle`, `discharge`)，韌體內部不支援自動維持百分比區間的 Sustainer 演算法。
  2. 在 S3 休眠期間或剛開機時，缺乏喚醒鉤子與開機提早啟動會留下暫態空窗，導致短暫以預設 normal 模式充電。
* **解決方案**：
  1. 使用專案強化後的 `c640-battery-limit.service` 與 `c640-ec-sleep.sh`：

     ```bash
     ./ec/install-ec.sh --enable-battery-limit
     ```

  2. 該服務採用守護程式 (`battery-daemon 90`) 搭配 `sysinit.target` 開機提早啟動與 `systemd-sleep` 喚醒鉤子，
     主動下達 0 mA AC 旁路 (`idle` / `inhibit-charge`)，無需依賴 EC Sustainer 即可精準控電。
  3. 執行 `c640-ec-control status` 或 `ectool battery` 驗證（目前充電電流應為 `0 mA`）。
