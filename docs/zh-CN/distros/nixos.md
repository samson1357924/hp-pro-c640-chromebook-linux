[English](../../../README.md) | [繁體中文](../../../README.zh-CN.md)

# ❄️ NixOS 宣告式配置指南

NixOS 採用不可變（Immutable）與純宣告式（Declarative）系統架構，請將以下設定整合至您的 `/etc/nixos/configuration.nix` 或 Nix Flake。

---

## 1. 完整硬體啟用配置範例 (`hp-pro-c640.nix`)

```nix
{ config, pkgs, ... }:

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

  # 3. 啟用指紋識別服務與 PAM 整合
  services.fprintd = {
    enable = true;
    package = pkgs.fprintd.override {
      # 覆寫 libfprint 為包含 crfpmoc 補丁之版本
    };
  };

  # 4. ChromeOS /dev/cros_fp udev 權限
  services.udev.extraRules = ''
    KERNEL=="cros_fp", SUBSYSTEM=="misc", GROUP="plugdev", MODE="0660", TAG+="uaccess"
  '';

  # 5. 鍵盤頂排映射 (udev hwdb)
  services.udev.extraHwdb = ''
    evdev:atkbd:dmi:bvn*:bvr*:bd*:svnGoogle*:pn*Dratini*:pvr*
    evdev:atkbd:dmi:bvn*:bvr*:bd*:svnGoogle*:pn*dratini*:pvr*
    evdev:atkbd:dmi:bvn*:bvr*:bd*:svnGoogle*:pn*Hatch*:pvr*
    evdev:atkbd:dmi:bvn*:bvr*:bd*:svnHP*:pnHP*Pro*c640*Chromebook*:pvr*
     KEYBOARD_KEY_ea=back
     KEYBOARD_KEY_e9=forward
     KEYBOARD_KEY_e7=refresh
     KEYBOARD_KEY_91=f11
     KEYBOARD_KEY_92=scale
     KEYBOARD_KEY_a0=mute
     KEYBOARD_KEY_ae=volumedown
     KEYBOARD_KEY_b0=volumeup
     KEYBOARD_KEY_ee=brightnessdown
     KEYBOARD_KEY_ef=brightnessup
  '';

  # 6. S0ix 睡眠與電源管理
  boot.kernelParams = [ "pcie_aspm=force" ];
  services.logind = {
    lidSwitch = "suspend";
    lidSwitchExternalPower = "suspend";
  };
}
```
