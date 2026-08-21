[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# 🐧 openSUSE 專屬配置指南

適用發行版：**openSUSE Tumbleweed**, **openSUSE Leap 15.x**。

---

## 1. 快速自動安裝

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git
cd hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

---

## 2. 手動分步設定

### (1) 安裝套件依賴

```bash
sudo zypper install -y patterns-devel-base-devel_basis meson ninja pkg-config \
                       glib2-devel libgusb-devel libpixman-1-0-devel \
                       libgudev-1_0-devel json-glib-devel \
                       gobject-introspection-devel fprintd fprintd-pam \
                       sof-firmware pipewire wireplumber alsa-ucm-conf
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

### (4) 指紋 PAM 設定 (pam-config)

```bash
./fingerprint/install-fingerprint.sh
```

> [!IMPORTANT]
> 請**不要**執行 `pam-config -a --fprintd`：它會把 `pam_fprintd` 注入
> `common-auth`（`gdm-password` 會引入它）；解鎖時 GDM 同時 fork
> `gdm-password` 與 `gdm-fingerprint` worker 爭搶唯一的 fprintd 裝置，鎖定
> 畫面的指紋提示會消失（GNOME/gdm#1071）。只為 **sudo** 啟用指紋：

```bash
sudo cp /etc/pam.d/sudo /etc/pam.d/sudo.bak
sudo sed -i '1i auth sufficient pam_fprintd.so' /etc/pam.d/sudo
```
