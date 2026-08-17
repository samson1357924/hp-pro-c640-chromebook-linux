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
