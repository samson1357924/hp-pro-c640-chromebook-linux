[English](../../README.md) | [繁體中文](../../README.zh-CN.md)

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

### (3) 部署鍵盤頂排映射

```bash
sudo cp keyboard/90-chromebook-keyboard.hwdb /etc/udev/hwdb.d/
sudo systemd-hwdb update
sudo udevadm trigger --subsystem-match=input
```

### (4) 設定 PAM 指紋驗證

編輯 `/etc/pam.d/system-auth`，在 `pam_unix.so` 上方加入：

```text
auth      sufficient pam_fprintd.so
```

編輯 `/etc/pam.d/sudo`，在頂端加入：

```text
auth      sufficient pam_fprintd.so
```
