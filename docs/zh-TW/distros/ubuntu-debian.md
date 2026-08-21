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

### (3) 部署鍵盤頂排映射

```bash
sudo cp keyboard/90-chromebook-keyboard.hwdb /etc/udev/hwdb.d/
sudo systemd-hwdb update
sudo udevadm trigger --subsystem-match=input
```

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
> 請**不要**執行 `pam-auth-update --enable fprintd`。該設定檔會把
> `pam_fprintd` 注入 `common-auth`（`gdm-password` 會引入它）；解鎖時 GDM
> 同時 fork `gdm-password` 與 `gdm-fingerprint` worker 爭搶唯一的 fprintd
> 裝置，鎖定畫面的指紋提示會消失（GNOME/gdm#1071）。安裝腳本只會在
> `/etc/pam.d/sudo` 啟用指紋；若你已在 `common-auth` 啟用，請移除：

```bash
sudo pam-auth-update --remove fprintd
```
