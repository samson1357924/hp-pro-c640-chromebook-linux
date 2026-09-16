[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# 🐧 Fedora 專屬配置指南

適用發行版：**Fedora Workstation 39 / 40 / 41**, **Fedora Silverblue**, **Nobara**, **RHEL 9**。

---

## 1. 快速自動安裝

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git
cd hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

---

## 2. 手動分步指南

### (1) 安裝套件依賴

```bash
sudo dnf install -y gcc meson ninja-build pkgconf-pkg-config \
                    glib2-devel libgusb-devel pixman-devel \
                    libgudev-devel json-glib-devel \
                    gobject-introspection-devel fprintd fprintd-pam \
                    alsa-sof-firmware pipewire wireplumber alsa-ucm
```

### (2) 部署音訊 UCM 配置

```bash
sudo cp -r audio/ucm/ucm2/* /usr/share/alsa/ucm2/
sudo alsactl init
systemctl --user restart wireplumber
```

### (3) 部署鍵盤頂排映射＋背光同步

推薦：

```bash
sudo ./keyboard/install-keyboard.sh          # hwdb + 背光同步（5 檔）
# 進階雙重角色：sudo ./keyboard/install-keyboard.sh --with-keyd
```

手動等價（見 `keyboard/README.zh-TW.md`）：

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
# keyd：sudo dnf copr enable alternateved/keyd -y && sudo dnf install -y keyd
# sudo ./keyboard/install-keyboard.sh --with-keyd
```

### (4) 指紋驅動編譯與 PAM 設定 (authselect)

```bash
# 使用本專案腳本編譯並安裝至 /usr/lib64
./fingerprint/install-fingerprint.sh
```

> [!IMPORTANT]
> 請**不要**執行 `authselect enable-feature with-fingerprint`。該 feature
> 會把 `pam_fprintd` 注入 `system-auth`（`gdm-password` 會引入它）；解鎖時
> GDM 同時 fork `gdm-password` 與 `gdm-fingerprint` worker 爭搶唯一的
> fprintd 裝置，鎖定畫面的指紋提示會消失（GNOME/gdm#1071）。只為
> **sudo** 啟用指紋：

```bash
# 確認 with-fingerprint feature 保持停用
sudo authselect disable-feature with-fingerprint
sudo authselect apply-changes

# 僅為 sudo 啟用指紋（保留原有 stack）
sudo cp /etc/pam.d/sudo /etc/pam.d/sudo.bak
sudo sed -i '/^auth[[:space:]].*pam_fprintd.so/d' /etc/pam.d/sudo
sudo sed -i '0,/^auth[[:space:]]\+include[[:space:]]\+system-auth/s//auth sufficient pam_fprintd.so max-tries=1 timeout=10\n&/' /etc/pam.d/sudo
```
