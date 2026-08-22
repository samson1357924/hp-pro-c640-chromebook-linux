# 🔬 Deep Dive: S0ix Sleep, ASPM Power Saving, and Power Management

This article provides an in-depth analysis of the **HP Pro c640 Chromebook**
(Comet Lake-U / `dratini`) S0ix Modern Standby mechanism, suspend power tuning,
and wake event management under Linux.

---

## 1. s2idle (S0ix) vs S3 (Deep Sleep)

On this machine (Ubuntu, kernel 7.0) **both** suspend modes are advertised by
the firmware, and the default is **S3 deep sleep**:

```bash
cat /sys/power/mem_sleep
# Output on the Dratini with the current firmware: s2idle [deep]
```

The bracket marks the current default. A recent suspend cycle confirms deep
sleep is actually used and functional:

```text
PM: suspend entry (deep)
```

This contradicts the older assumption that Coreboot / MrChromebox UEFI
firmware only exposes s2idle: check `/sys/power/mem_sleep` on your own
installation instead of assuming, because the available modes depend on the
exact firmware build and kernel.

The two modes differ as follows:

* **S3 (`deep`)**: the platform performs a true system sleep (SPM
  transitions, memory kept in self-refresh). Low power, but resume takes a
  few seconds.
* **s2idle (S0ix Modern Standby)**: the kernel does not suspend to a
  firmware-defined state; the CPU cores halt and the SoC attempts to reach
  the Package C10 (SLP_S0#) ultra-low-power state, with millisecond-level
  instant wake-up.

To switch the default at runtime:

```bash
echo deep | sudo tee /sys/power/mem_sleep
# or, for S0ix Modern Standby:
echo s2idle | sudo tee /sys/power/mem_sleep
```

To make the choice persistent, add `mem_sleep_default=deep` (or `=s2idle`)
to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` and run
`sudo update-grub`.

---

## 2. Checklist to Avoid Excessive Suspend Power Drain

If overnight standby with the lid closed drains more than 5~8% of battery, check the following three items in order:

### (1) Disable Wi-Fi Background Network Wake (WoWLAN)

The Intel AX201 Wi-Fi may repeatedly wake the SoC when it receives multicast packets during sleep:

```bash
sudo iw phy phy0 wowlan disable
```

You can write this command to `/etc/rc.local` or a systemd sleep hook.

### (2) Force Enable PCIe ASPM (Active State Power Management)

Ensure the NVMe SSD and PCIe bus can enter the L1 power-saving state:
Edit `/etc/default/grub`:

```ini
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pcie_aspm=force"
```

Update the bootloader: `sudo update-grub`.

### (3) Inspect ACPI Wake Sources (`/proc/acpi/wakeup`)

The Dratini touchpad (`GPE0_DW0_21`) and fingerprint reader (`GPE0_DW0_23`)
are wake-capable. If pressure in a backpack causes unexpected wake-ups, inspect
and optionally disable wake sources with the following commands:

```bash
cat /proc/acpi/wakeup
# Disable wake for a specific device (e.g. TPAD):
# echo TPAD | sudo tee /proc/acpi/wakeup
```

---

## 3. ChromeOS EC v1 (Dratini) Power & Charge Control Architecture

The **HP Pro c640 Chromebook** (Comet Lake-U / `dratini`) features a Nuvoton NPCX796F Embedded
Controller (EC) running ChromeOS EC firmware (version `dratini_v2.0.2851`).

### EC API Generations & Hardware AC Bypass

* **EC v2/v3 (Newer Chromebooks & Framework)**: Supports firmware-level battery sustainer
  (`chargecontrol normal <lower> <upper>`), where the EC autonomously holds a percentage window in hardware.
* **EC v1 (HP Pro c640 Dratini)**: Implements standard 3-state charge control:
  * `normal` (0): Charges battery up to 100%.
  * `idle` (1): **Hardware AC Bypass Mode** (stops charging, battery draws **0 mA**,
    motherboard is powered directly by AC).
  * `discharge` (2): Forces discharge from battery while plugged in.

Because EC v1 rejects autonomous sustainer commands (`ERROR: Old EC doesn't support sustainer`),
the Linux operating system must manage the percentage threshold.

### Dual-Track Control: sysfs + ectool

This project implements a dual-track fail-safe mechanism:

1. **Linux Kernel sysfs (`cros_charge_control`)**: Writing `inhibit-charge` or `auto` to
   `/sys/class/power_supply/BAT0/charge_behaviour`.
2. **Direct EC Host Command (`ectool`)**: Issuing `ectool chargecontrol idle` or `normal`
   over the `/dev/cros_ec` LPC interface.

---

## 4. Zero-Window Gap Protection (Boot & Suspend)

A common issue with battery threshold scripts is overcharging during system boot and S3 sleep transitions:

1. **Cold Boot Window**: Standard systemd services running `After=multi-user.target` start ~18-20 seconds
   after kernel initialization, leaving a brief charging window on boot.
2. **S3 Sleep & Polling Freeze**: During S3 suspend, user-space polling processes (`sleep 30`) are frozen
   by the cgroup freezer. If AC is connected during sleep or state resets, overcharging can occur.

### Solution: sysinit Target + systemd-sleep Resume Hook

* **Early Boot Service**: `c640-battery-limit.service` is configured with `After=sysinit.target`,
  starting within ~1.5 seconds of boot.
* **Resume Hook**: `/usr/lib/systemd/system-sleep/c640-ec-sleep.sh` immediately re-evaluates battery capacity
  upon S3/S0ix resume (`post` hook), asserting `inhibit-charge` / `idle` in <0.05 seconds.
* **Hardware S3 Persistence**: Measured in hardware verification tests: an EC placed in `idle` (0 mA)
  maintains 0 mA AC bypass throughout S3 deep sleep without dropping state.

---

## 5. Standalone `ectool` Build & Usage Guide

To communicate directly with the ChromeOS EC on standard Linux (Ubuntu, Debian, Fedora, Arch):

### Build from Source (`DHowett/ectool`)

```bash
# Install dependencies
sudo apt install -y cmake build-essential pkg-config libftdi1-dev libusb-1.0-0-dev

# Clone and compile
git clone --depth=1 https://github.com/DHowett/ectool.git
cd ectool
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc)

# Install
sudo install -D -m 0755 src/ectool /usr/local/bin/ectool
```

### Quick Commands with `c640-ec-control`

```bash
# View complete EC status (Battery, Fan RPM, 3x Board Thermals, Keyboard Backlight)
c640-ec-control status

# Set battery limit to 90%
c640-ec-control battery-limit 90

# Force immediate pure AC bypass (0 mA battery draw)
c640-ec-control battery-idle

# Restore 100% full charging
c640-ec-control battery-full

# Fan silent mode (0 RPM for quiet typing) / restore auto
c640-ec-control fan-silent
c640-ec-control fan-auto
```
