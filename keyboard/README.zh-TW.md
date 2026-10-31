[English](README.md) | [繁體中文](README.zh-TW.md)

# 鍵盤頂排映射（HP Pro c640 Chromebook）

ChromeOS 裝置頂排為專用功能鍵而非傳統 F1-F12。在標準 Linux 下，這些按鍵可透過核心/硬體層的 `systemd-hwdb` 或輸入層的 `keyd` 重新映射。

---

## 🎹 頂排按鍵對照表

| 實際位置 | ChromeOS 圖示 | AT 掃描碼 | Linux hwdb 鍵碼 | 建議功能 |
| :--- | :--- | :--- | :--- | :--- |
| **頂排 1 (F1)** | ◀ (返回) | `KEYBOARD_KEY_ea` | `KEY_BACK` | 瀏覽器 / 應用程式返回 |
| **頂排 2 (F2)** | ▶ (前進) | `KEYBOARD_KEY_e9` | `KEY_FORWARD` | 瀏覽器 / 應用程式前進 |
| **頂排 3 (F3)** | ⟳ (重新整理) | `KEYBOARD_KEY_e7` | `KEY_REFRESH` | 重新載入頁面 |
| **頂排 4 (F4)** | ⛶ (全螢幕) | `KEYBOARD_KEY_91` | `KEY_F11` | 切換全螢幕 |
| **頂排 5 (F5)** | ⧉ (總覽) | `KEYBOARD_KEY_92` | `KEY_SCALE` | GNOME / 桌面工作切換 |
| **頂排 6 (F6)** | 🔅 (降低亮度) | `KEYBOARD_KEY_ee` | `KEY_BRIGHTNESSDOWN` | 降低螢幕背光 |
| **頂排 7 (F7)** | 🔆 (提高亮度) | `KEYBOARD_KEY_ef` | `KEY_BRIGHTNESSUP` | 提高螢幕背光 |
| **頂排 8 (F8)** | 🔇 (靜音) | `KEYBOARD_KEY_a0` | `KEY_MUTE` | 音訊靜音 |
| **頂排 9 (F9)** | 🔉 (降低音量) | `KEYBOARD_KEY_ae` | `KEY_VOLUMEDOWN` | 降低音量 |
| **頂排 10 (F10)** | 🔊 (提高音量) | `KEYBOARD_KEY_b0` | `KEY_VOLUMEUP` | 提高音量 |
| **Search / Launcher** | 🔍 (搜尋) | `KEYBOARD_KEY_db` | `KEY_LEFTMETA` | Super (Meta) 或 CapsLock |

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
* `./keyboard/install-keyboard.sh --uninstall`：還原 hwdb 變更。
* `./keyboard/install-keyboard.sh --with-keyd`：連 keyd 一起安裝（進階雙重角色）。

---

### 選項 2：`keyd` 常駐程式（進階多層與雙重角色）

若希望 **Search 鍵** 呈現 **輕點為 CapsLock、長按為 Super/Meta**，或希望 `Search + 頂排` 輸出傳統 `F1-F10`：

> **前置條件：** 需先安裝選項 1 `systemd-hwdb`。`keyd` 依賴 hwdb 已將
> `0xEA/0xE9/0xE7/0x91/0x92/0xEE/0xEF/0xA0/0xAE/0xB0/0xDB` 轉為
> `KEY_BACK`/`KEY_LEFTMETA` 等，`cros.conf` 使用這些名稱（`back`、`leftmeta`）。
> 建議：`sudo ./keyboard/install-keyboard.sh --with-keyd`（原子化安裝 hwdb+背光+keyd）。

1. 安裝 `keyd`（CI 固定 `v2.6.0` `7c0aecb8...`）：

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
   # services.keyd.enable = true;
   ```

   > **各發行版執行檔名稱不同（Ubuntu 26.04 實測）：** Debian/Ubuntu 套件安裝的是
   > **`/usr/bin/keyd.rvaiya`**（2.5.0-5），`$PATH` 中沒有 `keyd`；systemd 服務名稱
   > 仍是 `keyd`。請用實際存在的名稱，例如 `keyd.rvaiya --version`；安裝器會透過
   > `lib/syscheck.sh` 的 `keyd_bin()` 自動偵測。另外 **`keyd check` 僅存在於 keyd ≥ 2.6**，
   > 2.5.x 會直接印出用法並回傳 0。

2. 安裝設定檔（建議走安裝器）：

   ```bash
   sudo ./keyboard/install-keyboard.sh --with-keyd
   # 等價手動：
   # sudo install -D -m 0644 keyboard/keyd/cros.conf /etc/keyd/cros.conf
   # sudo ln -sf cros.conf /etc/keyd/default.conf
   # keyd check /etc/keyd/cros.conf     # 僅 keyd ≥ 2.6；2.5.x 於啟動時驗證
   # sudo systemctl enable keyd
   # sudo systemctl restart keyd         # keyd 2.5.x 只在啟動時讀取設定
   ```

3. 驗證與調校：

   ```bash
   keyd --version || keyd.rvaiya --version   # Ubuntu 26.04 為 keyd.rvaiya
   sudo keyd monitor || sudo keyd.rvaiya monitor
   # 短按 Search -> capslock，長按 -> leftmeta；Search+頂排 -> F1
   sudo systemctl status keyd
   journalctl -eu keyd -f
   # 若輕點/長按太靈敏，於 /etc/keyd/cros.conf [global] 加入：
   # overload_tap_timeout = 200  # ms，見 man keyd
   # sudo systemctl restart keyd
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
    * keyd 2.5.x 輕點 Search 時會先送出一組短暫的 `leftmeta` + `leftctrl`，再送 `capslock`。
      這是 keyd 的修飾鍵防護（`src/keyboard.c` 的 `clear_mod()`），避免 GNOME 把單獨的
      Meta 解讀成「活動總覽」快捷鍵；屬預期行為，寫測試時請以 `KEY_CAPSLOCK` 判斷。
    * keyd 2.5.x 沒有裝置熱插拔偵測：修改 `/etc/keyd/*.conf` 後必須
      `sudo systemctl restart keyd`（`reload` 只會重新解析已被 grab 裝置的設定）。
    * `X11` 使用者：`setxkbmap` 會在 `keyd restart` 後重置，需重套。
    * `TTY` 由 `uinput` 支援；若設定鎖死，急救：`backspace+escape+enter`。

---

### 選項 3：鍵盤背光與螢幕熄滅/鎖定同步

螢幕熄滅/鎖定時自動關閉鍵盤背光，螢幕點亮時自動恢復。支援 GNOME Wayland
閒置（`org.gnome.ScreenSaver` + `org.freedesktop.login1 PrepareForSleep` 對應 S3 盒蓋）與 ChromeOS EC
`cros_kbd_led_backlight`（`/sys/class/leds/chromeos::kbd_backlight`）。

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
* `c640-kbd-backlight-sync.service` → `/etc/systemd/user/`（全域啟用，`WantedBy=graphical-session.target`）
* `c640-kbd-backlight-sleep.sh` → `/usr/lib/systemd/system-sleep/`（S3 喚醒後恢復，
  0.6 秒 debounce 避免 `LED_CORE_SUSPENDRESUME` 競態）

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

**日誌：**

```bash
journalctl --user -u c640-kbd-backlight-sync.service -f
journalctl --user -u c640-kbd-backlight-sync.service --since "5 min ago" | cat
```

---

## 🧪 驗證與測試

驗證按鍵事件是否正確識別：

```bash
sudo evtest
# 選擇「AT Translated Set 2 keyboard」並按下頂排按鍵。
```

### 自動化 keyd 雙重角色測試（不需人手按鍵）

`keyboard/tests/keyd-dualrole-uinput.py` 會建立 AT ID `0001:0001` 的虛擬鍵盤、
重啟 keyd 讓它被 grab，注入按鍵後讀取 keyd 虛擬鍵盤的輸出並斷言：

```bash
sudo apt install -y python3-evdev
sudo python3 keyboard/tests/keyd-dualrole-uinput.py
# PASS: tap Search -> CAPSLOCK
# PASS: hold Search + Back -> META + F1
# PASS: hold Search + BrightnessDown -> F6
# PASS: BrightnessDown alone -> brightnessdown
# RESULT=PASS
```

### 被動擷取實體按鍵（安全，不會搶走鍵盤）

`keyboard/tests/capture-keyd-output.py` 以唯讀方式讀取 keyd 虛擬鍵盤，執行時桌面仍可正常輸入：

```bash
sudo apt install -y python3-evdev
sudo python3 keyboard/tests/capture-keyd-output.py --seconds 120
# 12:49:15 KEY_LEFTMETA 1     <- 輕點 Search
# 12:49:16 KEY_CAPSLOCK 1
# 12:49:18 KEY_LEFTMETA 1     <- 長按 Search（Super）
# 12:49:26 KEY_F6 1           <- 按住 Search + 降低亮度
```

**絕對不要對 keyd 虛擬鍵盤下 `EVIOCGRAB`**（`evtest`、`evemu-record` 等）：
一旦獨占，compositor 就收不到鍵盤，整個桌面會失去輸入，直到程式結束為止。
`keyd monitor` 也不能取代：keyd 2.5.x 無法開啟已被自己 grab 的裝置，所以內建鍵盤不會出現在那裡。

### 怎麼看 `udevadm test` 的輸出

`udevadm test /sys/class/input/event2` 對泛用查詢（`evdev:`、`evdev:name:`、
`evdev:name:...:phys:...`）都會印 `No entry found from hwdb`，這是正常的。
只有 `evdev:atkbd:$attr{[dmi/id]modalias}` 那一行才是重點；只要它套用了
`KEYBOARD_KEY_*`，映射就是生效的。實機 Dratini 的 modalias 在 `bd*` 與 `svn*`
之間多了 `br0.0:efr0.0` 欄位，`bd*:svnGoogle*` 仍可命中（2026-10-31 驗證）。

### 實機驗證記錄（HP Pro c640 / Dratini，2026-10-31）

環境：Ubuntu 26.04.1 LTS、kernel `7.0.0-38-generic`、`keyd 2.5.0-5`
（執行檔 `/usr/bin/keyd.rvaiya`）、`python3-evdev 1.9.3`、GNOME Wayland。

| 檢查項目 | 結果 | 證據 |
| :--- | :---: | :--- |
| hwdb 即時轉譯 | 🟢 | `udevadm info /dev/input/event2` → `KEYBOARD_KEY_db=leftmeta`、`ea=back`、`ef=brightnessup` |
| keyd 只 grab 內建鍵盤 | 🟢 | journal：`match 0001:0001 ... (AT Translated Set 2 keyboard)`；`ignoring 0000:0006 (Video Bus)` |
| 輕點 Search | 🟢 | uinput 測試：`LEFTMETA+LEFTCTRL` 防護組，接著 `CAPSLOCK` down/up |
| 長按 Search + Back | 🟢 | `META` 持續按住 → `F1` down/up |
| 長按 Search + BrightnessDown | 🟢 | `F6` down/up（Search+頂排 = F1-F10 層） |
| 單按 BrightnessDown | 🟢 | `KEY_BRIGHTNESSDOWN` down/up（媒體層保留） |
| 實體輕點 Search（被動擷取） | 🟢 | `13:26:02` 被動擷取（無 grab）：`LEFTMETA` + `LEFTCTRL` 防護組，接著 `CAPSLOCK` down/up |
| 實體長按 Search + 降低亮度 | 🟢 | `12:49:26` 被動擷取：`KEY_F6` ×4（Search+頂排層） |
| 實體長按 Search + Back | 🟢 | `13:25:56` 被動擷取（無 grab）：`LEFTMETA` 按住 → `KEY_F1` down/up |
| LED 節點權限 | 🟢 | `udevadm trigger --subsystem-match=leds` 後為 `-rw-rw---- root plugdev`；一般使用者可直接寫入，無需 sudo |
| daemon 熄滅/恢復 | 🟢 | `--test-blank` 2 → 0、`--test-unblank` 0 → 2，state 檔 `0600` 且會清除 |
| daemon 事件路徑 | 🟢 | `gdbus emit ... ScreenSaver.ActiveChanged true/false` → 亮度 2 → 0 → 2，使用者 journal **完全沒有 sudo 呼叫** |
| sleep hook | 🟢 | `pre suspend` 存下 6，模擬 0，`post suspend` 還原 6，state 檔清除（本次以直接呼叫驗證；自動化 session 無法做真實盒蓋 S3 循環） |
| `--check` | 🟢 | 全綠，含「backlight node writable by group plugdev (mode 660)」 |

**實機發現的坑（repo 已修）：**

1. Ubuntu 26.04 的 `keyd` 套件執行檔是 `/usr/bin/keyd.rvaiya`，`$PATH` 沒有 `keyd`；
   請用 `keyd_bin()` / `command -v keyd keyd.rvaiya`。
2. keyd 2.5.x 沒有 `check` 子命令，也沒有裝置熱插拔偵測：安裝器部署
   `/etc/keyd/cros.conf` 後必須 `systemctl restart keyd`，否則仍是舊映射（或完全沒映射）。
3. `[ids] *` 會一併 grab ChromeOS `Video Bus`；應限定 `0001:0001`。
4. udev 的 `MODE=`/`GROUP=`/`uaccess` **不會**改 sysfs LED 屬性；背光 daemon 需要
   `61-chromeos-kbd-backlight.rules` 裡的 `RUN+=chgrp plugdev` + `RUN+=chmod 0660`，
   否則會退回 `sudo -n tee`，而使用者服務無法回應 sudo。
5. keyd 的修飾鍵防護會在單獨 Meta 放開時插入無害的 `LEFTCTRL` 點擊；測試請斷言
   「含有 `CAPSLOCK`」，不要寫成「只有 `CAPSLOCK`」。
6. 使用者端 `uinput` 裝置必須提供完整 `keyboard_mask`（`KEY_1..0`、`Q..Y`）或
   `KEY_BRIGHTNESSUP`，keyd 才會視為鍵盤；只給 `KEY_LEFTMETA` 會被忽略。
7. 對 keyd 虛擬鍵盤下 `EVIOCGRAB`（或跑 `evtest`）會把它從 compositor 手上搶走，
   整個桌面鍵盤會失效到程式結束為止。請改用被動的 `capture-keyd-output.py`。
8. `udevadm test` 對泛用 `evdev:` 查詢印 `No entry found from hwdb` 是正常現象；
   只有 `evdev:atkbd:` 那條會套用 `KEYBOARD_KEY_*`。
