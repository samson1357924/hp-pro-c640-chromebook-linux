[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# 🐧 Arch Linux & EndeavourOS 專屬配置指南

適用發行版：**Arch Linux**, **EndeavourOS**, **CachyOS**, **Manjaro**。

---

## 1. 快速自動安裝

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git
cd hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

---

## 2. Arch 原生 PKGBUILD 打包安裝 (最推薦)

本專案提供原生 PKGBUILD 模板，讓 `libfprint-crfpmoc` 可以由 `pacman` 完整接管：

```bash
cd fingerprint/packaging
makepkg -si
```

---

## 3. 手動分步設定

### (1) 安裝套件依賴

```bash
sudo pacman -S --needed base-devel meson ninja pkgconf glib2 \
                        libgusb pixman libgudev json-glib \
                        gobject-introspection fprintd \
                        sof-firmware pipewire pipewire-pulse wireplumber alsa-ucm-conf
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
# keyd：sudo pacman -S keyd && sudo ./keyboard/install-keyboard.sh --with-keyd
```

### (4) 設定 PAM 指紋驗證

> [!IMPORTANT]
> 請**不要**把 `pam_fprintd` 加入 `/etc/pam.d/system-auth`。`system-auth`
> 會被 `gdm-password` 引入；解鎖時 GDM 會同時 fork `gdm-password` 與
> `gdm-fingerprint` worker，兩者爭搶唯一的 fprintd 裝置，失敗的一方會得到
> "Device was already claimed"，鎖定畫面就不會出現指紋提示
> （GNOME/gdm#1071）。只為 **sudo** 啟用指紋即可：

編輯 `/etc/pam.d/sudo` — 於 `system-auth` 引入前插入（先備份）：

```bash
sudo cp /etc/pam.d/sudo /etc/pam.d/sudo.bak
sudo sed -i '/^auth[[:space:]].*pam_fprintd.so/d' /etc/pam.d/sudo
sudo sed -i '0,/^auth[[:space:]]\+include[[:space:]]\+system-auth/s//auth sufficient pam_fprintd.so max-tries=1 timeout=10\n&/' /etc/pam.d/sudo
```
