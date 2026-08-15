# 🔧 Firmware Flashing & Recovery Guide

This guide explains in detail how to flash **MrChromebox UEFI Full ROM**
firmware onto your **HP Pro c640 Chromebook (Google `dratini`)** to install
native Linux, and how to fully restore the original factory ChromeOS later.

---

## ⚠️ Important Concepts to Read Before Flashing

> [!IMPORTANT]
>
> 1. **The HP Pro c640 has no physical write-protect (WP) screw**: this device
>    uses Google's Cr50 security chip to protect the firmware.
> 2. **Easiest way to disable hardware write protection (HW WP): disconnect
>    the battery cable**. As long as you boot with the charger plugged in while
>    the battery cable is disconnected, Cr50 will automatically disable
>    hardware write protection!
> 3. **Always back up the stock ROM**: when running the MrChromebox firmware
>    utility, it will prompt you to back up the original firmware. **Make sure
>    to insert a USB drive and save `stock-firmware.rom`** to it.

---

## 🛠️ Phase 1: Disable Hardware Write Protection (HW WP)

### Steps (battery disconnect method)

1. Fully power off the Chromebook and unplug all USB cables and the charger.
2. Remove the bottom cover (unscrew all bottom screws and use a plastic spudger to release the clips).
3. **Locate the cable connector between the motherboard and the battery, and unplug the battery cable**.
4. While **keeping the battery cable disconnected**, plug the original USB-C
   PD charger into the laptop (it will power on automatically).
5. The system now boots with Cr50 detecting no battery power, so hardware write protection is fully disabled.

---

## 🚀 Phase 2: Enter Developer Mode and Flash MrChromebox UEFI Full ROM

1. **Enter ChromeOS Developer Mode**:
   - Hold `Esc + Refresh + Power` at boot to enter Recovery mode.
   - Press `Ctrl + D`, then press Enter to confirm wiping local data and switch to Developer Mode.
2. **Boot and connect to Wi-Fi**:
   - On the ChromeOS welcome screen, connect to a wireless network.
   - Press `Ctrl + Alt + T` to open the crosh terminal, type `shell` and press Enter to enter a Bash environment.
3. **Run the MrChromebox firmware utility script**:

   ```bash
   cd; curl -LO https://mrchromebox.tech/firmware-util.sh && sudo bash firmware-util.sh
   ```

4. **Select `Install / Update UEFI (Full ROM) Firmware` (option 2)**:
   - Follow the prompts to confirm flashing.
   - **When prompted to back up the Stock Firmware, insert a USB drive, enter
     the save path and back up `stock-firmware.rom` to the drive!**
5. **After flashing, reassemble the hardware**:
   - Power off after flashing, then unplug the charger.
   - **Reconnect the battery cable to the motherboard**, then screw the bottom cover back on.
   - Reboot and you will see the MrChromebox rabbit logo; insert any standard
     Linux installation USB drive (Ubuntu / Fedora / Arch, etc.) to start
     installing the OS!

---

## 🔄 Phase 3: Restore Stock ChromeOS (Restore Stock Firmware)

If you need to reset the laptop or restore stock ChromeOS later:

1. Boot a Linux Live USB into the desktop environment.
2. Connect to the network, open a terminal and run the MrChromebox utility:

   ```bash
   cd; curl -LO https://mrchromebox.tech/firmware-util.sh && sudo bash firmware-util.sh
   ```

3. Select **`Restore Stock Firmware`**.
4. Insert the USB drive holding your earlier `stock-firmware.rom` backup and
   follow the on-screen instructions to complete the restore.
5. Power off once the restore is complete.
6. On another computer, install the "**Chromebook Recovery Utility**" Chrome
   extension, and create a stock recovery USB drive for model
   `HP Pro c640 Chromebook` (or enter `DRATINI`).
7. Insert the recovery USB drive and boot; the system will automatically reinstall the official ChromeOS image.
