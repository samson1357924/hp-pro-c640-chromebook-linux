# 🔬 Deep Dive: S0ix Sleep, ASPM Power Saving, and Power Management

This article provides an in-depth analysis of the **HP Pro c640 Chromebook**
(Comet Lake-U / `dratini`) S0ix Modern Standby mechanism, suspend power tuning,
and wake event management under Linux.

---

## 1. S0ix (s2idle) vs S3 (Deep Sleep)

Intel 10th Gen Comet Lake with Coreboot / MrChromebox UEFI firmware **only
supports S0ix (`s2idle`)**, not legacy ACPI S3 (`deep`).

```bash
cat /sys/power/mem_sleep
# Expected output format: [s2idle]
```

In the S0ix state, the CPU cores stop running and the SoC enters the Package
C10 (SLP_S0#) ultra-low-power state, achieving standby battery life comparable
to S3 while retaining the benefit of millisecond-level instant wake-up.

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
