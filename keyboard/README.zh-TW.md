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

---

### 選項 2：`keyd` 常駐程式（進階多層與雙重角色）

若希望 **Search 鍵** 呈現 **輕點為 CapsLock、長按為 Super/Meta**，或希望 `Search + 頂排` 輸出傳統 `F1-F10`：

1. 安裝 `keyd`：

   ```bash
   # Ubuntu / Debian
   sudo apt install -y keyd  # 或從 https://github.com/rvaiya/keyd 自行編譯
   # Fedora
   sudo dnf install -y keyd
   # Arch Linux
   sudo pacman -S keyd
   ```

2. 複製設定檔：

   ```bash
   sudo cp keyboard/keyd/cros.conf /etc/keyd/default.conf
   sudo systemctl enable --now keyd
   ```

---

### 選項 3：鍵盤背光與螢幕熄滅/鎖定同步（新增）

螢幕熄滅/鎖定時自動關閉鍵盤背光，螢幕點亮時自動恢復。支援 GNOME Wayland
閒置（`org.gnome.ScreenSaver` + `org.freedesktop.login1 PrepareForSleep` 對應 S3 盒蓋）與 ChromeOS EC
`cros_kbd_led_backlight`（`/sys/class/leds/chromeos::kbd_backlight`）。

透過 `./keyboard/install-keyboard.sh` 自動安裝：

```bash
./keyboard/install-keyboard.sh          # 安裝 hwdb + 背光同步
./keyboard/install-keyboard.sh --check  # 驗證 daemon/service/udev 狀態
./keyboard/install-keyboard.sh --uninstall  # 移除所有鍵盤相關元件
```

**安裝內容：**

* `61-chromeos-kbd-backlight.rules` → `/etc/udev/rules.d/`（`TAG+="uaccess"`）
* `c640-kbd-backlight-sync` → `/usr/local/bin/`（bash daemon，`gdbus`/`dbus-monitor` 事件驅動，預設無輪詢）
* `c640-kbd-backlight-sync.service` → `/etc/systemd/user/`（全域啟用，`WantedBy=graphical-session.target`）
* `c640-kbd-backlight-sleep.sh` → `/usr/lib/systemd/system-sleep/`（S3 喚醒後恢復，
  0.6 秒 debounce 避免 `LED_CORE_SUSPENDRESUME` 競態）

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
