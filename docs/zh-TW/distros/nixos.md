[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# ❄️ NixOS 宣告式配置指南

NixOS 採用不可變（Immutable）與純宣告式（Declarative）系統架構，請將以下設定整合至您的 `/etc/nixos/configuration.nix` 或 Nix Flake。

---

## 1. 完整硬體啟用配置範例 (`hp-pro-c640.nix`)

```nix
{ config, pkgs, ... }:

let
  # 以公開的 3v1n0/libfprint `feature/crfpmoc` 分支（固定 commit）建置
  # libfprint，並套用本 repo 的審核版 driver overlay。overlay 以
  # builtins.fetchGit 取得（Nix build sandbox 內無法讀取 /nix/store 以外的
  # 路徑，`postUnpack` 看不到你的 clone），並固定在本 repo 包含
  # fingerprint/driver/ 的 commit。
  overlaySrc = builtins.fetchGit {
    url = "https://github.com/samson1357924/hp-pro-c640-chromebook-linux";
    rev = "648a4d08fe6bf7128c515b8097217d9612356b6a";
  };
  libfprint-crfpmoc = pkgs.libfprint.overrideAttrs (old: {
    pname = "libfprint-crfpmoc";
    version = "1.94.10-crfpmoc";
    src = builtins.fetchTarball {
      url = "https://gitlab.freedesktop.org/3v1n0/libfprint/-/archive/56442591a5c302a906289f30988fb50fc3d82ed6/libfprint-56442591a5c302a906289f30988fb50fc3d82ed6.tar.gz";
      sha256 = "2ef9a45508259e09bc92e0f5fd4ea1f2271f3a9235a2cfbc76c9ca27a9ee71f4";
    };
    postUnpack = ''
      cp -r ${overlaySrc}/fingerprint/driver/. "$sourceRoot/libfprint/drivers/crfpmoc/"
    '';
    # Nix 單引號字串會保留 `\n`（反斜線+n 原樣），正是 sed 此處需要的
    # （在取代式中插入新行）。
    postPatch = ''
      sed -i "s|'drivers/crfpmoc/crfpmoc-ec-transfer.c',|'drivers/crfpmoc/crfpmoc-ec-transfer.c',\n        'drivers/crfpmoc/crfpmoc-proto.c',|" libfprint/meson.build
    '';
  });
in
{
  # 1. 啟用音訊伺服器 (PipeWire + WirePlumber)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;

  # 2. 啟用 Intel SOF 韌體
  hardware.firmware = [ pkgs.sof-firmware ];

  # 3. 啟用指紋識別服務（含 crfpmoc 驅動）
  services.fprintd = {
    enable = true;
    package = pkgs.fprintd.override { libfprint = libfprint-crfpmoc; };
  };

  # 4. ChromeOS /dev/cros_fp + 鍵盤背光 udev 權限
  #    （把使用者加入 `plugdev`：`users.users.<you>.extraGroups = [ "plugdev" ];`）
  #    注意：MODE=/GROUP=/uaccess 只作用於 /dev 節點；LED 亮度是純 sysfs
  #    檔案，必須用 RUN+= 明確 chgrp/chmod（與 repo 的
  #    61-chromeos-kbd-backlight.rules 相同）。
  users.groups.plugdev = {};
  services.udev.extraRules = ''
    KERNEL=="cros_fp", SUBSYSTEM=="misc", GROUP="plugdev", MODE="0660", TAG+="uaccess"
    SUBSYSTEM=="leds", KERNEL=="chromeos::kbd_backlight", TAG+="uaccess", RUN+="${pkgs.coreutils}/bin/chgrp plugdev /sys/class/leds/chromeos::kbd_backlight/brightness", RUN+="${pkgs.coreutils}/bin/chmod 0660 /sys/class/leds/chromeos::kbd_backlight/brightness"
  '';

  # 5. 只為 sudo 啟用指紋（不要加入 GDM：解鎖時 GDM 的 claim race
  # 會讓鎖定畫面指紋提示消失，GNOME/gdm#1071）
  security.pam.services.sudo.fprintAuth = true;

  # 6. 鍵盤頂排映射 (udev hwdb)
  #    以下是 Dratini（HP Pro c640）實測的掃描碼。pn*Hatch* 那行也會匹配
  #    其他 Hatch 系列 Chromebook，它們可能送不同掃描碼——直接複製前請先
  #    自行擷取驗證。
  services.udev.extraHwdb = ''
    evdev:atkbd:dmi:bvn*:bvr*:bd*:svnGoogle*:pn*Dratini*:pvr*
    evdev:atkbd:dmi:bvn*:bvr*:bd*:svnGoogle*:pn*dratini*:pvr*
    evdev:atkbd:dmi:bvn*:bvr*:bd*:svnGoogle*:pn*Hatch*:pvr*
    evdev:atkbd:dmi:bvn*:bvr*:bd*:svnHP*:pnHP*Pro*c640*Chromebook*:pvr*
    evdev:atkbd:dmi:bvn*:bvr*:bd*:svnHP*:pn*c640*:pvr*
     KEYBOARD_KEY_3b=back
     KEYBOARD_KEY_3c=forward
     KEYBOARD_KEY_3d=refresh
     KEYBOARD_KEY_3e=f11
     KEYBOARD_KEY_3f=scale
     KEYBOARD_KEY_40=brightnessdown
     KEYBOARD_KEY_41=brightnessup
     KEYBOARD_KEY_42=mute
     KEYBOARD_KEY_43=volumedown
     KEYBOARD_KEY_44=volumeup
     KEYBOARD_KEY_db=leftmeta
  '';
  # 6b. keyd 雙重角色 Search（選用；設定檔在 keyboard/keyd/cros.conf）
  #     NixOS 各版本的 keyd module schema 不同，本指南不自動產生設定。請把
  #     keyboard/keyd/cros.conf 部署到 /etc/keyd/cros.conf（含
  #     [ids] 0001:0001 與 leftmeta = overloadt2(meta, capslock, 200)）並啟用
  #     keyd 服務。沒有 keyd 時，頂排仍可透過上面的 hwdb 當媒體鍵使用。

  # 鍵盤背光同步 daemon（user service + system-sleep）
  # 選項 A：以 repo 安裝器作為 imperative 步驟：sudo /path/to/keyboard/install-keyboard.sh
  # 選項 B：宣告式範例（自行調整路徑）：
  # systemd.user.services.c640-kbd-backlight-sync = {
  #   Unit.Description = "HP Pro c640 Keyboard Backlight Sync";
  #   Unit.After = [ "graphical-session.target" ];
  #   Unit.PartOf = [ "graphical-session.target" ];
  #   Install.WantedBy = [ "graphical-session.target" ];
  #   Service.ExecStart = "/usr/local/bin/c640-kbd-backlight-sync";
  #   Service.Restart = "on-failure";
  # };
  # environment.systemPackages = [ (pkgs.writeShellScriptBin "c640-kbd-backlight-sync" (builtins.readFile ./keyboard/c640-kbd-backlight-sync)) ];
  # 完整手動步驟見 keyboard/README.zh-TW.md 選項 3。

  # 7. S0ix 睡眠與電源管理
  boot.kernelParams = [ "pcie_aspm=force" ];
  services.logind = {
    lidSwitch = "suspend";
    lidSwitchExternalPower = "suspend";
  };
}
```

> [!NOTE]
> `crfpmoc` 驅動原始碼已內建於本 repo（`fingerprint/driver/`），建置時只
> 需抓取公開的 `libfprint` 基底。若固定 commit 有變動，請更新 `src` 並用
> `nix-prefetch-url <archive-url>` 重新取得 tarball 雜湊。
