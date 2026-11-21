[English](README.md) | [繁體中文](README.zh-TW.md)

# 鍵盤頂排映射（HP Pro c640 Chromebook）

多數 ChromeOS 裝置頂排為專用功能鍵而非傳統 F1-F12（這台 Dratini 則是直接送
AT `F1`-`F10`）。在標準 Linux 下，這些按鍵可透過核心/硬體層的 `systemd-hwdb`
或輸入層的 `keyd` 重新映射。

---

## 🎹 頂排按鍵對照表

| 實際位置 | ChromeOS 圖示 | 原始掃描碼 / hwdb 屬性 | Linux hwdb 鍵碼 | 建議功能 |
| :--- | :--- | :--- | :--- | :--- |
| **頂排 1 (F1)** | ◀ (返回) | `0x3b` / `KEYBOARD_KEY_3b` | `KEY_BACK` | 瀏覽器 / 應用程式返回 |
| **頂排 2 (F2)** | ▶ (前進) | `0x3c` / `KEYBOARD_KEY_3c` | `KEY_FORWARD` | 瀏覽器 / 應用程式前進 |
| **頂排 3 (F3)** | ⟳ (重新整理) | `0x3d` / `KEYBOARD_KEY_3d` | `KEY_REFRESH` | 重新載入頁面 |
| **頂排 4 (F4)** | ⛶ (全螢幕) | `0x3e` / `KEYBOARD_KEY_3e` | `KEY_F11` | 切換全螢幕 |
| **頂排 5 (F5)** | ⧉ (總覽) | `0x3f` / `KEYBOARD_KEY_3f` | `KEY_SCALE` | GNOME / 桌面工作切換 |
| **頂排 6 (F6)** | 🔅 (降低亮度) | `0x40` / `KEYBOARD_KEY_40` | `KEY_BRIGHTNESSDOWN` | 降低螢幕背光 |
| **頂排 7 (F7)** | 🔆 (提高亮度) | `0x41` / `KEYBOARD_KEY_41` | `KEY_BRIGHTNESSUP` | 提高螢幕背光 |
| **頂排 8 (F8)** | 🔇 (靜音) | `0x42` / `KEYBOARD_KEY_42` | `KEY_MUTE` | 音訊靜音 |
| **頂排 9 (F9)** | 🔉 (降低音量) | `0x43` / `KEYBOARD_KEY_43` | `KEY_VOLUMEDOWN` | 降低音量 |
| **頂排 10 (F10)** | 🔊 (提高音量) | `0x44` / `KEYBOARD_KEY_44` | `KEY_VOLUMEUP` | 提高音量 |
| **Search / Launcher** | 🔍 (搜尋) | `0xdb` / `KEYBOARD_KEY_db` | `KEY_LEFTMETA` | Super (Meta) 或 CapsLock |

> **掃描碼已於 2026-10-31 在實機 Dratini 上量測。** 這台頂排送出的是標準 AT
> 掃描碼 `0x3b`-`0x44`（`KEY_F1`-`KEY_F10`），**不是**部分 Chromebook 使用的
> ChromeOS action 掃描碼（`0xea`、`0xe9`、`0xe7`…）。因此 hwdb 必須映射
> `0x3b`-`0x44`；映射 action 掃描碼在這台機器上完全無效。量測表存於
> `keyboard/tests/hwdb-top-row-scancodes.tsv`，CI 會逐條斷言。
>
> **其他 Chromebook／其他 Hatch 機板：** 這份映射**只**套用於
> `keyboard/90-chromebook-keyboard.hwdb` 中明確列出的 Dratini / HP Pro c640
> DMI 條目；它**不匹配**其他 Hatch 機板（在實機 Dratini 上，「Hatch」是產品
> 家族而非產品名稱，因此不使用 `pn*Hatch*` 萬用字元）。其他機型會送各自的
> 掃描碼，需要建立自己的 hwdb 條目。沿用這張表前，請先停掉 keyd
> （`sudo systemctl stop keyd`），用 `check-top-row-hwdb.py --scan 60` 或
> 不加 `--grab` 的 `evtest` 讀 `EV_MSC/MSC_SCAN`，再對照標準 AT 表推論
> 掃描碼並建立自己的 hwdb 條目。未知機型或 `EVIOCGKEYCODE` 不支援時，改用
> `check-top-row-hwdb.py --scan-only 60`：它完全跳過表格檢查，因此 Dratini
> fixture 不符也不會擋住原始擷取。**擷取完成後請執行
> `sudo systemctl start keyd` 恢復服務**，否則 Search 輕點/長按與亮度重映射
> 會持續失效。`--listen` 只會顯示 hwdb 轉換後的 `KEY_*` 按鍵事件，不是原始
> 掃描碼。

---

## 🛠️ 實作選項

### 選項 1：systemd-hwdb（推薦預設）

零常駐開銷、低延遲、核心層原生映射。

```bash
chmod +x keyboard/install-keyboard.sh
./keyboard/install-keyboard.sh
```

**選項**：

* `./keyboard/install-keyboard.sh --check`：檢查 hwdb 是否已部署。
* `./keyboard/install-keyboard.sh --dry-run`：預覽操作。
* `./keyboard/install-keyboard.sh --uninstall`：移除頂排 hwdb、背光同步與（若已安裝的）keyd 設定。
* `./keyboard/install-keyboard.sh --with-keyd`：連 keyd 一起安裝（進階雙重角色）。若 keyd
  服務無法啟動會回傳非 0：只寫入設定檔但沒有 keyd binary 時回傳 3；設定被拒絕或重啟/回復失敗時回傳 1。
* `./keyboard/install-keyboard.sh --keyd-config-only`：隱含 `--with-keyd`，但明確接受「只有設定檔、沒有 keyd 服務」的結果（rc 0）；安裝器仍會標明雙重角色**未**生效。

**keyd 快照目錄（進階）：** `CROS_ENABLEMENT_KEYD_SNAPSHOT_DIR` 可覆寫預設的
`/var/lib/cros-enablement-keyd-snapshots`。自訂路徑必須是絕對路徑：base 需為 root 擁有且權限
`0700`，所有上層目錄也需 root 擁有，直接父目錄不得為群組/其他人可寫（即使有 sticky 位也一樣）。
家目錄下的路徑會被拒絕；任一檢查失敗時安裝器會拒絕部署 keyd 設定。

---

### 選項 2：`keyd` 常駐程式（進階多層與雙重角色）

若希望 **Search 鍵** 呈現 **輕點為 CapsLock、長按為 Super/Meta**，或希望 `Search + 頂排` 輸出傳統 `F1-F10`：

> **前置條件：** 需先安裝選項 1 `systemd-hwdb`。`keyd` 依賴 hwdb 已將實測的
> 頂排掃描碼 `0x3b`-`0x44` 轉為 `KEY_BACK`/`KEY_BRIGHTNESSDOWN`…，以及
> `0xDB`→`KEY_LEFTMETA`；`cros.conf` 使用這些名稱（`back`、`leftmeta`）。
> 可用 `sudo python3 keyboard/tests/check-top-row-hwdb.py` 確認核心映射。
> 建議：`sudo ./keyboard/install-keyboard.sh --with-keyd`（原子化安裝 hwdb+背光+keyd）。若系統尚未安裝 keyd，此指令現在會回傳
> rc 3，而不會宣稱雙重角色已生效；若刻意只想部署設定檔（例如 CI 容器），請改用 `--keyd-config-only`。

1. 安裝 `keyd`（CI 固定 `v2.6.0`，hash `7c0aecb8bfd34dc8642bf4eefd2e59c89e61cec3`）：

   ```bash
   # Ubuntu 25.04+ / Debian 13+（原生）
   sudo apt update && sudo apt install -y keyd

   # Ubuntu 22.04/24.04 或 Debian 12（PPA）
   sudo add-apt-repository ppa:keyd-team/ppa -y
   sudo apt update && sudo apt install -y keyd
   # 或從源碼固定編譯：
   git clone --depth 1 --branch v2.6.0 https://github.com/rvaiya/keyd /tmp/keyd
   test "$(git -C /tmp/keyd rev-parse HEAD)" = "7c0aecb8bfd34dc8642bf4eefd2e59c89e61cec3"
   make -C /tmp/keyd && sudo make -C /tmp/keyd install

   # Fedora（COPR）
   sudo dnf copr enable alternateved/keyd -y
   sudo dnf install -y keyd

   # Arch Linux（extra）
   sudo pacman -S keyd

   # NixOS
   # services.keyd.enable = true;  # 另需 environment.etc."keyd/cros.conf".source = ./keyboard/keyd/cros.conf
   ```

   > **各發行版執行檔名稱不同（Ubuntu 26.04 實測）：** Debian/Ubuntu 套件安裝的是
   > **`/usr/bin/keyd.rvaiya`**（2.5.0-5），而非 `/usr/bin/keyd`（`$PATH` 中沒有 `keyd`）；systemd 服務名稱
   > 仍是 `keyd`。請用實際存在的名稱，例如 `keyd.rvaiya --version`；安裝器會透過
   > `lib/syscheck.sh` 的 `keyd_bin()` 自動偵測。另外 **`keyd check` 僅存在於 keyd ≥ 2.6**，
   > 2.5.x 會直接印出用法並回傳 0。

2. 安裝設定檔（建議走安裝器）：

   ```bash
   sudo ./keyboard/install-keyboard.sh --with-keyd
   # 等價手動：
   # sudo install -D -m 0644 keyboard/keyd/cros.conf /etc/keyd/cros.conf
   # keyd check /etc/keyd/cros.conf     # 僅 keyd ≥ 2.6；2.5.x 於啟動時驗證
   # sudo systemctl enable keyd
   # sudo systemctl restart keyd         # keyd 2.5.x 只在啟動時讀取設定
   ```

3. 驗證與調校：

   ```bash
   keyd --version || keyd.rvaiya --version   # Ubuntu 26.04 為 keyd.rvaiya
   # 被動擷取 keyd 的輸出（安全，不會 grab 裝置）：
   sudo python3 keyboard/tests/capture-keyd-output.py --seconds 120
   # 短按 Search -> capslock；長按 -> 乾淨的 leftmeta；Search+頂排 -> F1
   sudo systemctl status keyd
   journalctl -eu keyd -f
   # 輕點/長按門檻是 /etc/keyd/cros.conf 裡 overloadt2() 的第三個參數
   # （目前 200 ms）。[global] 的 overload_tap_timeout 只影響 plain
   # overload()，對 overloadt2() 無效。改完數字後 restart keyd 生效。
   ```

   **GNOME Wayland 觸控板 quirk**（選用，修 `disable-while-typing` 卡頓）：

   ```bash
   sudo mkdir -p /etc/libinput
   printf '[Keyd]\nMatchName=keyd virtual keyboard\nAttrKeyboardIntegration=internal\n' | sudo tee /etc/libinput/local-overrides.quirks > /dev/null
   ```

    **備註：**
    * `[ids] 0001:0001` 將 `cros.conf` 限定在內建 AT 鍵盤。若用萬用字元 `*`，會一併
      grab ChromeOS 的 `Video Bus`（`0000:0006`）與外接 USB 鍵盤，造成亮度鍵重複處理、
      外接鍵盤按鍵被吞掉。若要一併映射外接鍵盤，請從 `sudo keyd monitor` 取得 ID 後加入。
    * 使用 `overloadt2(meta, capslock, 200)` 後，**輕點是乾淨的 `CAPSLOCK`**（不再送
      `leftmeta`），長按是 `Super`。單純的 `overload(meta, capslock)` 不行：它在按下時
      就啟動 Meta 層，放開時 keyd 的修飾鍵防護（`src/keyboard.c` 的 `clear_mod()`）
      會插入 `LEFTCTRL`，Mutter 會把這串當成 `Meta+Ctrl` 組合，因此長按永遠打不開
      GNOME 活動總覽。`overloadt2` 會延後判定，且圖層放開路徑會抑制防護，單純長按
      放開只送出乾淨的 `LEFTMETA` down/up。
    * 200 ms 是輕點/長按的分界：在這之內放開是 CapsLock，超過就是 Super；
      Search 按住期間按其他鍵會判定為長按。
    * 頂排鍵刻意不在 `[main]` 重新映射；keyd 對未映射的鍵會原樣放行，因此 hwdb
      轉出的媒體鍵在單按時仍有效，`[meta:M]` 則提供 F1-F10 層。
    * keyd 2.5.x 沒有裝置熱插拔偵測：修改 `/etc/keyd/*.conf` 後必須
      `sudo systemctl restart keyd`（`reload` 只會重新解析已被 grab 裝置的設定）。
    * `X11` 使用者：`setxkbmap` 會在 `keyd restart` 後重置，需重套。
    * `TTY` 由 `uinput` 支援；若設定鎖死，急救：`backspace+escape+enter`。

---

### 選項 3：鍵盤背光與螢幕熄滅/鎖定同步

螢幕熄滅/鎖定時自動關閉鍵盤背光，螢幕點亮時自動恢復。支援 GNOME Wayland
閒置（`org.gnome.ScreenSaver` + `org.freedesktop.login1 PrepareForSleep` 對應 S3 盒蓋）與 ChromeOS EC
`cros_kbd_led_backlight`（`/sys/class/leds/chromeos::kbd_backlight`）。

**寫入鏈（single-writer）**：daemon 先寫 gsd-power 屬性
`org.gnome.SettingsDaemon.Power.Keyboard.Brightness`（百分比）——它是唯一權威寫入者，
可同步 gsd-power 自己的快取並驅動 UPower/LED。只有 gsd-power 不可用時才降級到
UPower `KbdBacklight.SetBrightness`（raw），再降級到 `sysfs`/`ectool`。讀取走 UPower
`GetBrightness`。`C640_KBD_FORCE_LEGACY=1` 會停用兩個 D-Bus 後端，強制走
`sysfs`/`ectool`（便於 A/B 比較）。

透過 `./keyboard/install-keyboard.sh` 自動安裝：

```bash
./keyboard/install-keyboard.sh                          # 安裝 hwdb + 背光同步
./keyboard/install-keyboard.sh --with-keyd              # 加裝 keyd 雙重角色（選項 2）
./keyboard/install-keyboard.sh --check                  # 驗證 daemon/service/udev/keyd 狀態
./keyboard/install-keyboard.sh --uninstall              # 移除所有鍵盤相關元件（含 keyd）
./keyboard/install-keyboard.sh --with-keyd --dry-run    # 預覽全部
```

**安裝內容：**

* `61-chromeos-kbd-backlight.rules` → `/etc/udev/rules.d/`（`TAG+="uaccess"`，並以
  `RUN+=chgrp plugdev` / `RUN+=chmod 0660` 調整 brightness 屬性權限）
* `c640-kbd-backlight-sync` → `/usr/local/bin/`（bash daemon，`gdbus`/`dbus-monitor` 事件驅動，預設無輪詢）
* `c640-kbd-backlight-sync.service` → `/etc/systemd/user/`（全域啟用，`WantedBy=graphical-session.target`；
  `StandardError=journal` 讓所有 daemon 日誌出現在 `journalctl`）
* `c640-kbd-backlight-sleep.sh` → `/usr/lib/systemd/system-sleep/`（S3 喚醒後恢復，
  0.6 秒 debounce 避免 `LED_CORE_SUSPENDRESUME` 競態）

**儲存/還原語意**：亮度 `0` 也是有效的已存值。state 檔是否存在就是擁有權的依據：
解鎖/喚醒時 daemon 與 sleep hook 會用已存值覆寫目前亮度（即使核心留下非 0 的殘值），
然後清除 state；沒有 state 檔時完全不寫入，因此使用者手動調整會被保留。
還原前兩者都會再查 `org.gnome.ScreenSaver.GetActive`（freedesktop 為 fallback）；
若仍 active 就**延後**並保留 state，不會把已熄滅的螢幕點亮。sleep hook 以 root 執行，
因此用 `sudo -u "$user" env XDG_RUNTIME_DIR=... DBUS_SESSION_BUS_ADDRESS=... timeout 2
gdbus call --session ...` 探測 session bus；找不到 bus、timeout 或 D-Bus 錯誤都視為
**fail-open**（照常還原，絕不卡住 suspend）。

> **為何需要 `RUN+=chmod`？** `MODE=`、`GROUP=`、`uaccess` 只作用於 `/dev` 裝置節點。
> `/sys/class/leds/chromeos::kbd_backlight/brightness` 是沒有裝置節點的純 sysfs 屬性，
> udev 無法用那些欄位改權限，預設會維持 `root:root 0644`；因此規則額外執行
> `chgrp plugdev` + `chmod 0660`（Ubuntu 26.04 實測有效）。否則使用者服務會退回到
> `echo | sudo -n tee`，而 session service 通常無法回應 sudo。驗證：
>
> ```bash
> ls -l /sys/class/leds/chromeos::kbd_backlight/brightness   # 應為 root plugdev 0660
> sudo udevadm control --reload-rules
> sudo udevadm trigger --subsystem-match=leds                # 不重開機即可重套
> id -nG | tr ' ' '\n' | grep -qx plugdev && echo "使用者屬於 plugdev"
> ```

**免熄屏手動測試：**

```bash
c640-kbd-backlight-sync --check          # 顯示目前亮度與狀態
c640-kbd-backlight-sync --test-blank     # 模擬螢幕熄滅 -> 儲存並設為 0
cat /sys/class/leds/chromeos::kbd_backlight/brightness  # 應為 0
c640-kbd-backlight-sync --test-unblank   # 模擬螢幕點亮 -> 恢復
```

**選用 IdleMonitor 輪詢**（預設關閉，用於「先變暗再熄滅」）：

```bash
# 透過 drop-in 啟用 Mutter IdleMonitor 輪詢（idle-delay + 5 秒閾值）：
sudo mkdir -p /etc/systemd/user/c640-kbd-backlight-sync.service.d
echo -e "[Service]\nEnvironment=C640_KBD_ENABLE_IDLEMONITOR=1" | sudo tee /etc/systemd/user/c640-kbd-backlight-sync.service.d/override.conf > /dev/null
sudo systemctl daemon-reload
sudo systemctl --global daemon-reload 2> /dev/null || true
systemctl --user daemon-reload 2> /dev/null || true
systemctl --user restart c640-kbd-backlight-sync.service 2> /dev/null || true
# 停用：sudo rm /etc/systemd/user/c640-kbd-backlight-sync.service.d/override.conf && daemon-reload
```

**Wayland/X11 相容性：** 主要路徑為 `org.gnome.ScreenSaver`（GNOME Wayland
原生，事件驅動，無輪詢）。`IdleMonitor` 為選用。非 GNOME 工作階段由 `system-sleep` hook 覆蓋 S3 盒蓋情境。

**日誌：** daemon 訊息全部寫到 stderr；unit 設了 `StandardError=journal`，因此
（含 `backends probed: gsd=... upower=...`、`saved brightness`、`restoring
brightness` 與 `[WARN]` 降級訊息）都可在使用者 journal 看到：

```bash
journalctl --user -u c640-kbd-backlight-sync.service -f
journalctl --user -u c640-kbd-backlight-sync.service --since "5 min ago" | cat
```

**僅供測試的環境變數**（不碰系統檔案）：daemon 接受 `C640_KBD_SYSFS_BRIGHTNESS` /
`C640_KBD_SYSFS_MAX` 指向假 LED 節點；sleep hook 接受 `C640_KBD_SLEEP_SYSFS`、
`C640_KBD_SLEEP_STATE_DIR`，以及 bus 探測用的 `C640_KBD_SLEEP_USER` /
`C640_KBD_SLEEP_UID` / `C640_KBD_SLEEP_BUS` / `C640_KBD_SLEEP_DELAY`。

**單元測試（不需 root、不碰真實 sysfs/D-Bus）**：stub 工具放在 `PATH` 最前，
所有狀態都在暫存目錄。

```bash
bash keyboard/tests/kbd-backlight-daemon-test.sh
bash keyboard/tests/kbd-backlight-sleep-hook-test.sh
```

---

## 🧪 驗證與測試

### 先驗證 hwdb 掃描碼映射

hwdb 只有在映射到硬體真正送出的掃描碼時才有效。這支唯讀腳本會比對核心的
`EVIOCGKEYCODE` 映射與 `keyboard/tests/hwdb-top-row-scancodes.tsv`（不下 grab，
keyd 執行中也能跑）。它證明的是核心套用了哪份映射，不是硬體實際送什麼：
原始掃描碼是另外取得的——先停掉 keyd，再用不加 `--grab` 的 `evtest` 或
`check-top-row-hwdb.py --scan` 讀 `EV_MSC/MSC_SCAN`，並對照標準 AT 表推論。
`--listen` 模式只透過 `EVIOCGKEY` 觀察 hwdb 轉換後的 `KEY_*` 按鍵事件；
修正前每次實體按鍵都仍以 `KEY_F1`-`KEY_F10` 抵達，而 action 掃描碼的
hwdb 完全沒作用。

```bash
sudo apt install -y python3-evdev
sudo python3 keyboard/tests/check-top-row-hwdb.py
# 0x3b  back             KEY_BACK             KEY_BACK             OK
# 0x40  brightnessdown   KEY_BRIGHTNESSDOWN   KEY_BRIGHTNESSDOWN   OK
# 0xdb  leftmeta         KEY_LEFTMETA         KEY_LEFTMETA         OK
# RESULT=PASS
```

`RESULT=` 只報告 EVIOCGKEYCODE 映射的判定。若加上 `--scan SECONDS`，
也必須觀測到原始 `MSC_SCAN`：沒看到時（keyd 仍抓住裝置，或期間沒按鍵），
工具會印出 `RESULT=PASS (mapping check only; raw capture FAILED)`，
但**結束碼非 0**。判斷整體成功請看結束碼與 `RAW_CAPTURE=` 行，
不要只 grep `RESULT=PASS`。

若出現 `MISMATCH ... KEY_F1`，代表 hwdb 沒套用（或映射錯掃描碼），請重跑
`sudo ./keyboard/install-keyboard.sh --with-keyd`。

### 自動化 keyd 雙重角色測試（虛擬鍵盤，不需人手按鍵）

`keyboard/tests/keyd-dualrole-uinput.py` 會建立 AT ID `0001:0001` 的虛擬鍵盤、
重啟 keyd 讓它被 grab，注入按鍵後讀取 keyd 虛擬鍵盤的輸出並斷言：

```bash
sudo apt install -y python3-evdev
sudo python3 keyboard/tests/keyd-dualrole-uinput.py
# PASS: tap Search -> CAPSLOCK only (no META, no guard)
# PASS: hold Search + <每個頂排鍵> -> F1 ... F10（共 10 個）
# PASS: <每個頂排鍵> 單按 -> 對應媒體鍵（共 10 個）
# PASS: hold Search alone -> bare META release (no guard)
# RESULT=PASS
```

> 這支測試注入的是 **hwdb 轉換後**的鍵碼，無法抓出掃描碼錯誤。2026-10-31 之前
> 就是因為這樣，整段死碼 hwdb 仍讓測試全綠。請務必搭配上面的掃描碼檢查。
>
> 測試過程會重啟 keyd 兩次，實體鍵盤會中斷約 1 秒；請從 TTY/SSH 執行，或接受
> 短暫中斷。

### 被動擷取實體按鍵（安全，不會搶走鍵盤）

`keyboard/tests/capture-keyd-output.py` 以唯讀方式讀取 keyd 虛擬鍵盤，執行時桌面仍可正常輸入：

```bash
sudo apt install -y python3-evdev
sudo python3 keyboard/tests/capture-keyd-output.py --seconds 120
# 18:14:47 KEY_LEFTMETA 1     <- 長按 Search（Super），2026-10-31
# 18:14:47 KEY_LEFTMETA 2     <- 按住時的 autorepeat
# 18:14:50 KEY_LEFTMETA 0     <- 乾淨放開：沒有 LEFTCTRL 防護
# 18:14:52 KEY_CAPSLOCK 1     <- 輕點 Search（只送 CAPSLOCK）
# 18:14:52 KEY_CAPSLOCK 0
# 18:15:18 KEY_F1 1           <- 長按 Search + Back（F2-F10 同理）
```

**絕對不要對 keyd 虛擬鍵盤下 grab**（`evtest --grab`、`evemu-record
--grab`、raw `EVIOCGRAB`）：一旦獨占，compositor 就收不到鍵盤，整個桌面
會失去輸入，直到程式結束為止。不加 `--grab` 的一般 `evtest` 是唯讀且安全的。
實體鍵盤一旦被 keyd grab，其它 reader 完全讀不到它的事件——這正是本擷取工具
改讀 keyd 虛擬鍵盤的原因。`keyd monitor` 也不能取代：keyd 2.5.x 無法開啟
已被自己 grab 的裝置，所以內建鍵盤不會出現在那裡。

### 怎麼看 `udevadm test` 的輸出

`udevadm test /sys/class/input/event2` 對泛用查詢（`evdev:`、`evdev:name:`、
`evdev:name:...:phys:...`）都會印 `No entry found from hwdb`，這是正常的。
只有 `evdev:atkbd:$attr{[dmi/id]modalias}` 那一行才是重點；只要它套用了
`KEYBOARD_KEY_*`，映射就是生效的。實機 Dratini 的 modalias 在 `bd*` 與 `svn*`
之間多了 `br0.0:efr0.0` 欄位，`bd*:svnGoogle*` 仍可命中（2026-10-31 驗證）。

### 實機驗證記錄（HP Pro c640 / Dratini，2026-10-31）

環境：Ubuntu 26.04 LTS、kernel `7.0.0-38-generic`、`keyd 2.5.0-5`
（執行檔 `/usr/bin/keyd.rvaiya`）、`python3-evdev 1.9.3`、GNOME Wayland。

> 標示 **uinput** 的列使用虛擬鍵盤、注入的是 hwdb **之後**的鍵碼，只能證明 keyd
> 設定正確，不能證明實體鍵盤送出那些掃描碼。標示 **被動擷取** 的列是實際按下
> 實體鍵時，唯讀側錄 keyd 虛擬鍵盤的輸出。

| 檢查項目 | 結果 | 證據 |
| :--- | :---: | :--- |
| hwdb 即時轉譯 | 🟢 | `check-top-row-hwdb.py`（2026-10-31 19:45:29，對實體鍵盤做 `EVIOCGKEYCODE`）：11 條全部 OK — `0x3b`→`KEY_BACK`、`0x40`→`KEY_BRIGHTNESSDOWN`、`0x42`→`KEY_MUTE`、`0xdb`→`KEY_LEFTMETA` |
| keyd 只 grab 內建鍵盤 | 🟢 | journal：`match 0001:0001 ... (AT Translated Set 2 keyboard)`；`ignoring 0000:0006 (Video Bus)` |
| 輕點 Search（uinput） | 🟢 | uinput 測試（2026-10-31 19:45:37）：只有 `CAPSLOCK` down/up，沒有 `META`、沒有防護組 |
| 純長按 Search（uinput） | 🟢 | uinput 測試（19:45:37）：`LEFTMETA` down、autorepeat、乾淨的 `LEFTMETA` up，沒有 `LEFTCTRL` 防護，Mutter 可開總覽 |
| 長按 Search + 頂排（uinput） | 🟢 | uinput 測試（19:45:37）：10 組全部通過 — `Back`→`F1`、`Forward`→`F2`、`Refresh`→`F3`、`F11`→`F4`、`Scale`→`F5`、`BrightnessDown`→`F6`、`BrightnessUp`→`F7`、`Mute`→`F8`、`VolumeDown`→`F9`、`VolumeUp`→`F10` |
| 單按頂排（uinput） | 🟢 | uinput 測試（19:45:37）：10 個鍵全部原樣送出媒體鍵碼（`KEY_BACK` … `KEY_VOLUMEUP`） |
| 實體長按 Search 後放開（被動擷取） | 🟢 | `18:14:47-18:14:50`：`LEFTMETA` down + autorepeat、乾淨的 `LEFTMETA` up（**沒有 `LEFTCTRL`**）；GNOME 活動總覽確實開啟（畫面確認） |
| 實體輕點 Search（被動擷取） | 🟢 | `18:14:52`：只有 `CAPSLOCK` down/up |
| 實體單按亮度/靜音/音量（被動擷取） | 🟢 | `18:14:59-18:15:07`：`KEY_BRIGHTNESSDOWN`/`KEY_BRIGHTNESSUP`/`KEY_MUTE`/`KEY_VOLUMEDOWN`/`KEY_VOLUMEUP`；螢幕亮度與音量確實改變（畫面確認） |
| 實體長按 Search + Back（被動擷取） | 🟢 | `18:15:18`：`KEY_F1` down/up（meta 層）；keyd 圖層在組合鍵時會夾帶 `LEFTCTRL` 防護，屬預期行為，不影響單獨長按 |
| LED 節點權限 | 🟢 | `udevadm trigger --subsystem-match=leds` 後 `chromeos::kbd_backlight/brightness` 為 `-rw-rw---- root plugdev`；一般使用者可直接寫入，無需 sudo |
| daemon 熄滅/恢復 | 🟢 | `--test-blank` 2 → 0、`--test-unblank` 0 → 2，state 檔 `0600` 且會清除 |
| daemon 事件路徑 | 🟢 | `gdbus emit ... ScreenSaver.ActiveChanged true/false` → 亮度 2 → 0 → 2，使用者 journal **完全沒有 sudo 呼叫** |
| sleep hook | 🟢 | `pre suspend` 存下 6，模擬 0，`post suspend` 還原 6，state 檔清除（本次以直接呼叫驗證；自動化 session 無法做真實盒蓋 S3 循環） |
| `--check` | 🟢 | 全綠，含「backlight node writable by group plugdev (mode 660)」 |

**沿革（2026-10-31 已修）：** 先前 `12:49`、`13:25`、`13:26` 的被動擷取出現
`KEY_F1`／`KEY_F6`，一度被當成 keyd meta 層有效的證據。事實並非如此：當時頂排送的是
原始 `F1`-`F10`，hwdb 映射的是硬體不會送的掃描碼，單按媒體鍵完全沒作用。
以 `EV_MSC/MSC_SCAN` 讀到真實掃描碼後，已移除那些列，並以上方修正後的擷取取代。

**實機發現的坑（repo 已修）：**

1. Ubuntu 26.04 的 `keyd` 套件執行檔是 `/usr/bin/keyd.rvaiya`，`$PATH` 沒有 `keyd`；
   請用 `keyd_bin()` / `command -v keyd keyd.rvaiya`。
2. keyd 2.5.x 沒有 `check` 子命令，也沒有裝置熱插拔偵測：安裝器部署
   `/etc/keyd/cros.conf` 後必須 `systemctl restart keyd`，否則仍是舊映射（或完全沒映射）。
3. `[ids] *` 會一併 grab ChromeOS `Video Bus`；應限定 `0001:0001`。
4. udev 的 `MODE=`/`GROUP=`/`uaccess` **不會**改 sysfs LED 屬性；背光 daemon 需要
   `61-chromeos-kbd-backlight.rules` 裡的 `RUN+=chgrp plugdev` + `RUN+=chmod 0660`，
   否則會退回 `sudo -n tee`，而使用者服務無法回應 sudo。
5. 單純的 `overload(meta, ...)` 不適合 GNOME 總覽：keyd 的修飾鍵防護會在單獨
   Meta 放開時插入 `LEFTCTRL`，Mutter 會視為 `Meta+Ctrl` 而不開 Activities。
   改用 `overloadt2(meta, capslock, 200)` 後，圖層放開不插防護，輕點也不再送
   `META`，測試可以直接斷言「只有 `CAPSLOCK`」。
6. 使用者端 `uinput` 裝置必須提供完整 `keyboard_mask`（`KEY_1..0`、`Q..Y`）或
   `KEY_BRIGHTNESSUP`，keyd 才會視為鍵盤；只給 `KEY_LEFTMETA` 會被忽略。
7. 對 keyd 虛擬鍵盤下 grab（`EVIOCGRAB`、`evtest --grab`、`evemu-record
   --grab`）會把它從 compositor 手上搶走，整個桌面鍵盤會失效到程式結束為止；
   不加 `--grab` 的一般 `evtest` 是唯讀且安全的。實體鍵盤一旦被 keyd grab，
   其它 reader 完全讀不到它的事件，因此改用被動的 `capture-keyd-output.py`
   讀 keyd 虛擬鍵盤。
8. `udevadm test` 對泛用 `evdev:` 查詢印 `No entry found from hwdb` 是正常現象；
   只有 `evdev:atkbd:` 那條會套用 `KEYBOARD_KEY_*`。
9. 這台頂排送出的是標準 AT 掃描碼 `0x3b`-`0x44`（`KEY_F1`-`KEY_F10`），不是
   ChromeOS action 掃描碼（`0xea`、`0xe9`…）。從別台 Chromebook 抄來的 hwdb
   可能看起來正確、`udevadm info` 也顯示 `KEYBOARD_KEY_ea=back`，但每顆實體鍵
   仍是單純的 `F` 鍵。請用 `check-top-row-hwdb.py` 驗證，不要只看映射表。
10. `EVIOCGKEYCODE` 只顯示「映射表」；不代表硬體會送那些掃描碼。`EVIOCGKEY`
    （腳本的 `--listen`，或 `active_keys()` 探針）顯示的是實際按下後 hwdb
    轉換出的 `KEY_*` 鍵碼，不是原始掃描碼。請先停掉 keyd，再用不加 `--grab`
    的 `evtest` 或 `--scan` 讀 `EV_MSC/MSC_SCAN` 取得原始掃描碼，
    再對照標準 AT 表推論。
