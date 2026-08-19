# ❄️ NixOS Declarative Configuration Guide

NixOS uses an immutable and purely declarative system architecture. Integrate
the following settings into your `/etc/nixos/configuration.nix` or Nix Flake.

---

## 1. Complete Hardware Enablement Example (`hp-pro-c640.nix`)

```nix
{ config, pkgs, ... }:

let
  # libfprint built from the public 3v1n0/libfprint `feature/crfpmoc`
  # branch (pinned commit), with the audited driver overlay from this repo
  # applied. The overlay is fetched via builtins.fetchGit (works inside the
  # Nix build sandbox — `postUnpack` cannot see files outside /nix/store),
  # pinned to a repo commit that contains fingerprint/driver/.
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
    # Nix single-quoted strings keep `\n` as a literal backslash-n, which is
    # exactly what sed expects here (insert a new line in the substitution).
    postPatch = ''
      sed -i "s|'drivers/crfpmoc/crfpmoc-ec-transfer.c',|'drivers/crfpmoc/crfpmoc-ec-transfer.c',\n        'drivers/crfpmoc/crfpmoc-proto.c',|" libfprint/meson.build
    '';
  });
in
{
  # 1. Enable the audio server (PipeWire + WirePlumber)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;

  # 2. Enable Intel SOF firmware
  hardware.firmware = [ pkgs.sof-firmware ];

  # 3. Enable the fingerprint service with the crfpmoc driver
  services.fprintd = {
    enable = true;
    package = pkgs.fprintd.override { libfprint = libfprint-crfpmoc; };
  };

  # 4. ChromeOS /dev/cros_fp udev permissions
  #    (add your user to `plugdev`: `users.users.<you>.extraGroups = [ "plugdev" ];`)
  users.groups.plugdev = {};
  services.udev.extraRules = ''
    KERNEL=="cros_fp", SUBSYSTEM=="misc", GROUP="plugdev", MODE="0660", TAG+="uaccess"
  '';

  # 5. Fingerprint for sudo only (NOT for GDM login: the GDM unlock claim
  # race makes the lock-screen prompt disappear, GNOME/gdm#1071)
  security.pam.services.sudo.fprintAuth = true;

  # 6. Keyboard top-row mapping (udev hwdb)
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

  # 7. S0ix sleep and power management
  boot.kernelParams = [ "pcie_aspm=force" ];
  services.logind = {
    lidSwitch = "suspend";
    lidSwitchExternalPower = "suspend";
  };
}
```

> [!NOTE]
> The `crfpmoc` driver source is vendored in this repository
> (`fingerprint/driver/`), so the overlay is applied at build time; only the
> public upstream `libfprint` base is fetched. If the pinned commit moves,
> update `src` and re-prefetch the tarball hash with
> `nix-prefetch-url <archive-url>`.
