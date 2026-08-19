[English](../../README.md) | [繁體中文](../../README.zh-TW.md)

# 🔄 系統復原與解除安裝指南 (Uninstallation & Rollback)

本專案具備完整的**無損撤銷（Idempotent & Reversible）**機制。所有透過
`setup.sh` 或各子模組安裝的檔案均受到 `/var/lib/cros-enablement/install-manifest.json`
與 `/var/backups/cros-enablement/` 的保護。

---

## ⚡ 一鍵全自動解除安裝

在專案目錄下執行：

```bash
./setup.sh --uninstall
```

該指令會全自動執行：

1. 移除 `/usr/share/alsa/ucm2/` 中的 `sof-rt5682` 自訂 UCM 設定檔。
2. 移除 `/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb` 並重整硬體資料庫。
3. 移除 `/etc/udev/rules.d/60-cros-fp.rules`。
4. 移除電源管理調校（logind 設定與休眠輔助）。
5. 移除 EC 工具與 80% 電池保護服務。
6. 從**本專案首次安裝前的最早備份**還原每個檔案（重裝會保留第一次備份，
   因此 rollback 永遠還原到專案介入前的狀態）。
7. 還原安裝器曾修改的 systemd 服務啟用/運作狀態（`thermald`、`tlp`、
   `c640-battery-limit.service` 等），並移除**安裝器新增的 plugdev 群組成員**
   （安裝前已存在、或仍被其他 udev 規則引用的成員資格會被保留）。
8. 移除指紋加密種子 `/var/lib/fprint/crfpmoc.key`，並提示發行版重裝原生
   `libfprint` 套件的指令。

---

## 🛠️ 單一模組獨立解除安裝

* **僅移除音訊 UCM 配置**：

  ```bash
  ./audio/install-audio.sh --uninstall
  ```

* **僅移除指紋 udev 規則、PAM 設定與 system-sleep hook**：

  ```bash
  ./fingerprint/install-fingerprint.sh --uninstall
  ```

  *（會還原備份的 `libfprint` 函式庫與 `60-cros-fp.rules`、將
  `pam_fprintd` 的 PAM 變更還原（`/etc/pam.d/sudo` 回到 stock、fprintd
  移出 `common-auth`）、移除 `fprintd-sleep.sh` system-sleep hook、移除
  `/var/lib/fprint/crfpmoc.key` 與安裝器新增的 plugdev 成員資格，並還原
  服務狀態。）*

* **僅移除鍵盤頂排映射**：

  ```bash
  ./keyboard/install-keyboard.sh --uninstall
  ```

* **僅移除電源管理調校**（logind 設定、休眠輔助、TLP 設定、thermald 服務啟用）：

  ```bash
  ./power/install-power.sh --uninstall
  ```

  > [!WARNING]
  > 移除電源模組後請**重新開機**（或登出再登入）——**不要**執行
  > `systemctl restart systemd-logind`。在有登入 session 的桌面環境中重啟
  > `systemd-logind` 會登出所有人（session leader 在 deserialization 時遺失），
  > 外觀上與系統當機完全相同（HP Pro c640 實測，2026-08-18）。

* **僅移除 EC 工具與服務**（含 80% 電池保護 `c640-battery-limit.service`）：

  ```bash
  ./ec/install-ec.sh --uninstall
  ```

---

## 🔋 附註：80% 電池保護服務

`./ec/install-ec.sh --enable-battery-limit` 會安裝並啟動 `c640-battery-limit.service`，
將電池充電上限維持在 80% 以延長壽命。執行 `./ec/install-ec.sh --uninstall` 或
`./setup.sh --uninstall` 時會一併移除。

> [!NOTE]
> **解除安裝後仍會留下的狀態**：電池保護服務寫入 EC 的充電上限會持續存在，
> 直到你手動重置（`./scripts/c640-ec-control.sh battery-full`）。`plugdev`
> 群組本身不會被移除（其他元件或系統套件可能仍依賴它），只會移除安裝器
> 新增的成員資格。`/dev/cros_ec` 會維持 `0660` 權限直到裝置重新插拔或重開機。

## 📦 發行版原生套件還原

若您曾編譯並安裝過 `crfpmoc` 的 `libfprint`，可透過系統套件管理員重新安裝發行版
原生版本：

* **Ubuntu / Debian**:

  ```bash
  sudo apt install --reinstall -y libfprint-2-2
  ```

* **Fedora**:

  ```bash
  sudo dnf reinstall -y libfprint
  ```

* **Arch Linux**:

  ```bash
  sudo pacman -S --overwrite='*' libfprint
  ```

* **openSUSE**:

  ```bash
  sudo zypper install --force libfprint-2-2
  ```
