[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# 🐧 Ubuntu & Debian 專屬配置指南

適用發行版：**Ubuntu 22.04 / 24.04 / 26.04 LTS**, **Debian 12 (Bookworm) / 13 (Trixie)**, **Linux Mint**, **Pop!_OS**。

---

## 1. 快速自動安裝

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git
cd hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

---

## 2. 手動分步指南 (透明可審查)

### (1) 安裝套件依賴

```bash
sudo apt update
sudo apt install -y build-essential meson ninja-build pkg-config \
                    libglib2.0-dev libgusb-dev libpixman-1-dev \
                    libgudev-1.0-dev libudev-dev libjson-glib-dev \
                    libgirepository1.0-dev gobject-introspection \
                    fprintd libpam-fprintd firmware-sof-signed \
                    pipewire wireplumber alsa-ucm-conf
```

### (2) 部署音訊 UCM 配置

```bash
sudo cp -r audio/ucm/ucm2/* /usr/share/alsa/ucm2/
sudo alsactl init
systemctl --user restart wireplumber
```

### (3) 部署鍵盤頂排映射＋背光同步

推薦（涵蓋 hwdb + `61-chromeos-kbd-backlight.rules` + daemon + user service + system-sleep）：

```bash
sudo ./keyboard/install-keyboard.sh          # hwdb + 背光同步（5 檔）
# 進階雙重角色：sudo ./keyboard/install-keyboard.sh --with-keyd
```

手動等價（5 檔，見 `keyboard/README.zh-TW.md`）：

```bash
sudo cp keyboard/90-chromebook-keyboard.hwdb /etc/udev/hwdb.d/
sudo cp keyboard/udev/61-chromeos-kbd-backlight.rules /etc/udev/rules.d/
sudo install -D -m 0755 keyboard/c640-kbd-backlight-sync /usr/local/bin/c640-kbd-backlight-sync
sudo install -D -m 0644 keyboard/systemd/c640-kbd-backlight-sync.service /etc/systemd/user/c640-kbd-backlight-sync.service
sudo install -D -m 0755 keyboard/systemd/c640-kbd-backlight-sleep.sh /usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh
sudo systemd-hwdb update
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=input
sudo udevadm trigger --subsystem-match=leds
sudo systemctl daemon-reload
sudo systemctl --global enable c640-kbd-backlight-sync.service
# keyd 雙重角色（Search 輕點=CapsLock 長按=Super）：
# sudo apt install keyd  # Ubuntu 25.04+ 原生，否則 PPA keyd-team/ppa 或 Copr/源碼
# sudo ./keyboard/install-keyboard.sh --with-keyd
```

> **Ubuntu 26.04 實測備註（2026-10-31）：** `keyd` 套件（2.5.0-5）安裝的是
> **`/usr/bin/keyd.rvaiya`**，直接輸入 `keyd ...` 會得到 command not found；
> systemd 服務名稱仍是 `keyd`。keyd 2.6 之前沒有 `keyd check` 子命令，設定語法
> 會在 daemon 啟動時驗證。keyd 2.5.x 也沒有熱插拔偵測，修改 `/etc/keyd/*.conf`
> 後必須 `sudo systemctl restart keyd`。`install-keyboard.sh --with-keyd` 已處理
> 這三種情況（執行檔偵測、可選 `check`、重新啟動）。
>
> udev 規則以 `RUN+=chgrp/chmod` 將鍵盤背光 brightness 屬性設為 `root:plugdev 0660`；
> 只寫 `MODE=`/`GROUP=` 對 sysfs 無效。可用
> `ls -l /sys/class/leds/chromeos::kbd_backlight/brightness` 確認。

### (4) 編譯並安裝指紋驅動

```bash
# 設定 udev 權限
sudo cp fingerprint/60-cros-fp.rules /etc/udev/rules.d/
sudo usermod -aG plugdev "$USER"
sudo udevadm control --reload-rules && sudo udevadm trigger

# 執行自動安裝腳本進行編譯與安裝
./fingerprint/install-fingerprint.sh
```

> [!IMPORTANT]
> 請**不要**自行執行 `pam-auth-update --enable fprintd`。該設定檔會把
> `pam_fprintd` 注入 `common-auth`（`gdm-password` 會引入它）；解鎖時 GDM
> 同時 fork `gdm-password` 與 `gdm-fingerprint` worker 爭搶唯一的 fprintd
> 裝置，鎖定畫面的指紋提示會消失（GNOME/gdm#1071）。安裝腳本只會在
> `/etc/pam.d/sudo` 啟用指紋，並在安裝時**直接**以 `sed -i '/pam_fprintd\.so/d'`
> 移除 `common-*` 中的 fp 行。
>
> **請勿自行執行 `pam-auth-update --remove fprintd`。** 該動作會直接刪除 debconf 的
> `libpam-runtime/profiles` selection。Debian/Ubuntu 上安裝器會先把該 selection 與
> `/var/lib/pam` 下每個已儲存的模組檔快照到 first-wins sidecar（`pam-selection` 檔案權限
> `0644`；`pam-selection.saved` 是 root 擁有、`0700` 的檔案副本目錄），並額外發布第三個
> root 擁有 `0700` 的 `pam-selection.common` half，記錄每個 `common-*`／sudo 目標的位元組、
> mode、owner、type、symlink target、absence 與 savedir 目錄中繼資料（外加具 checksum 的
> entry-set manifest，類別為 `absent`／`empty`／`nonempty`；任何非 regular 的 savedir
> entry 皆 fail closed）；對 symlink 目標記錄的是連結本身的 lstat owner，並以
> `chown -h` + `mv -T -f --` 還原（不解引用目標）。所有讀取/複製都經由 `sudo`，
> 因此搭配 passwordless `sudo` 的非 root 呼叫端也支援），再備份**所有**現有的 `common-*`
> 位元組（不只含 fp 者）、只移除 fp 模組行，然後自行執行一次
> `pam-auth-update --package`，讓 debconf 與 `/var/lib/pam` 收斂到穩定的「無
> fprintd」狀態，日後套件觸發的執行即為 no-op。uninstall 時，所有工具呼叫先結束，
> 才從 `.common` 重新套用原始 `common-*`／sudo 檔案，接著做最終驗證
> （bytes/mode/owner/type/link/absence、savedir 與 selection/seen）；通過後才一次消耗
> 三個 half——manifest record 已消耗加 selection 相等並不算成功。還原失敗保留全部 half
> 並回 rc 1。沒有 `.common` 的 legacy sidecar 會明確 WARN 且不宣稱位元組保證；
> `.saved` 缺失但 live savedir 非空則 fail closed（`manual recovery`）；對 `common-*`
> 的語意變更（`External content change detected`）回 rc 1 並保留全部 half。
>
> **symlinked `common-*` 中有生效 fprintd 模組時安裝 fail closed。** 在任何 snapshot、
> backup、`sed` 或外部工具呼叫之前，每個 `common-*` 都透過 `sudo` 探測：symlink 目標若
> 有生效（非註解）的 `pam_fprintd.so` 行，`sed -i` 不解引用就無法移除它，因此安裝以非 0
> 結束，且**PAM 檔與 debconf selection 完全不變**（不發布 first-wins snapshot）。
> 無法讀取的目標或 grep 錯誤也 fail closed；不存在或 dangling 目標視為沒有生效模組。
> 安裝後 postcondition 會檢查**實際的** `common-*` 位元組沒有生效 fprintd——selection 中
> 留有已停用記錄並不算數。請把 symlink 換成普通檔（或在其真實目標下手動移除 fp 行）
> 後重跑安裝。
> **取捨**：安裝期間變更的 selection 會在
> uninstall 時被覆寫，而手動 `--enable fprintd` 會讓 GDM 競賽恢復，直到 uninstall
> 為止。若舊安裝的 `common-auth` 仍有 fp 行，請只移除該行，或重跑
> `./fingerprint/install-fingerprint.sh`（腳本會處理）：

```bash
sudo sed -i '/pam_fprintd\.so/d' /etc/pam.d/common-auth
```
