[English](../../README.md) | [繁體中文](../../README.zh-CN.md)

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

### (3) 部署鍵盤頂排映射

```bash
sudo cp keyboard/90-chromebook-keyboard.hwdb /etc/udev/hwdb.d/
sudo systemd-hwdb update
sudo udevadm trigger --subsystem-match=input
```

### (4) 指紋驅動編譯與 PAM 設定 (authselect)

```bash
# 使用本專案腳本編譯並安裝至 /usr/lib64
./fingerprint/install-fingerprint.sh

# 啟用 Fedora PAM 指紋模組
sudo authselect enable-feature with-fingerprint
sudo authselect apply-changes
```
