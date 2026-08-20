[English](README.md) | [繁體中文](README.zh-TW.md)

# 指紋辨識配置 (ChromeOS Match-on-Chip `crfpmoc`)

本模組提供針對 **HP Pro c640 Chromebook** (Google `dratini` / `hatch`) 上 **FPC1025 Match-on-Chip (MoC)** 指紋感測器的完整說明、驅動源碼參考、跨發行版原生打包模板以及自動化安裝管理工具。

---

## 🔍 工作原理

HP Pro c640 上的指紋感測器透過專屬 SPI 連接至 ChromeOS 指紋微控制器（FPMCU），並經由 Linux 核心的 `/dev/cros_fp` 字元裝置介面暴露給使用者空間。

### 標準 Linux 環境下的技術難題

1. **缺失 ACPI GPIO 中斷**：在一般通用 Linux 發行版中，FPMCU 的 ACPI 中斷線未綁定至 `cros_ec_chardev` 事件等待佇列。因此，使用標準 `epoll` 或 `GPollableInputStream` 監聽手指觸控時永遠不會觸發事件。
2. **金鑰加密與 Seed 管理**：Match-on-Chip 感測器需要啟動中的加密 Seed 與使用者 Context 才能解密存放在 MCU RAM 中的指紋特徵模板。
3. **特徵模板序列化**：主機驅動必須以 Little-Endian `FP_TEMPLATE_COMMIT` 旗標對指紋模板進行分塊傳輸。

### `crfpmoc` 的加固解決方案

* **50ms 延遲狀態機輪詢迴圈 (SSM Polling)**：在 GLib 狀態機中採用非阻塞單次 `poll(&pfd, 1, 0)` + `read(fd)` 輪詢，徹底解決無中斷環境下的 epoll 卡死問題。
* **弱指標狀態機保護 (Weak-pointer Guard)**：在取消註冊或逾時期間防止 Use-After-Free (UAF) 記憶體崩潰。
* **持久化金鑰衍生**：於 `/var/lib/fprint/crfpmoc.key` 生成並維持 32 位元組獨立隨機金鑰（權限 `0600`）。
* **零繞過身分驗證**：確保驗證與比對作業在遇到非預期硬體回應或錯誤時絕不誤報成功。

---

## 🛠️ 安裝與管理

### 自動化安裝（混合 A+C 架構）

內建的安裝腳本會自動偵測您的 Linux 發行版（Ubuntu/Debian、Fedora、Arch Linux、openSUSE），優先從 GitHub Releases 取得快速的**預編譯安裝包（Plan C）**，並在離線或未提供預編譯包的系統上自動無縫切換為**本地源碼編譯（Plan A）**：

```bash
chmod +x install-fingerprint.sh
# 預設混合模式（優先檢查預編譯包，失敗自動 fallback 至源碼編譯）：
./install-fingerprint.sh

# 強制從源碼編譯（Plan A：拉取鎖定 Commit + 覆蓋加固驅動）：
./install-fingerprint.sh --source
```

**支援的 CLI 參數**：

* `./install-fingerprint.sh --install`（或 `-i`）：預設混合安裝模式。
* `./install-fingerprint.sh --source`（或 `--build`）：強制從原始碼編譯安裝（Plan A）。
* `./install-fingerprint.sh --prebuilt`（或 `--pkg`）：強制僅使用預編譯安裝包（Plan C）。
* `./install-fingerprint.sh --release-tag <TAG>`：指定下載預編譯包的 GitHub Release 版本標籤。
* `./install-fingerprint.sh --check`（或 `-c`）：檢查指紋硬體節點、驅動與已註冊指紋狀態。
* `./install-fingerprint.sh --dry-run`（或 `-n`）：預覽安裝流程，不改動系統檔案。
* `./install-fingerprint.sh --uninstall`（或 `-u`）：移除驅動、清理設定並還原發行版官方套件。

---

## 📦 發行版原生套件打包

對於偏好使用發行版套件管理器（APT / DNF / Pacman）的使用者：

* **Debian / Ubuntu**：執行 [`packaging/build-deb.sh`](packaging/build-deb.sh) 構建 `.deb` 安裝包（使用 `dpkg -i` 安裝）。
* **Arch Linux / EndeavourOS**：使用提供的 [`packaging/PKGBUILD`](packaging/PKGBUILD) 搭配 `makepkg -si`。
* **Fedora / openSUSE**：使用 [`packaging/libfprint-crfpmoc.spec`](packaging/libfprint-crfpmoc.spec) 搭配 `rpmbuild`。
* **獨立完整原始碼包**：執行 [`packaging/create-source-tarball.sh`](packaging/create-source-tarball.sh) 生成已內建加固驅動的完整源碼壓縮檔。

---

## 🧪 使用與驗證

### 1. 註冊指紋

```bash
# 註冊預設手指（右手食指）
fprintd-enroll "$USER"

# 或指定特定手指：
fprintd-enroll -f right-thumb "$USER"
fprintd-enroll -f left-index-finger "$USER"
```

### 2. 驗證已註冊指紋

```bash
fprintd-verify "$USER"
```

### 3. 列出已註冊指紋

```bash
fprintd-list "$USER"
```

### 4. 刪除已註冊指紋

```bash
fprintd-delete "$USER"
```

### 5. 系統身分驗證測試

* **Sudo 授權**：清除時間戳快取進行測試：

  ```bash
  sudo -k && sudo whoami
  ```

  *（`-k` 參數會重置 sudo 快取，確保必定彈出指紋辨識提示）。*
* **螢幕鎖定解鎖**：按下 `Super + L` 鎖定，輕觸指紋感測器即可瞬間解鎖。

> [!NOTE]
> **PAM 配置策略（單一堆疊無競爭）**：安裝程式刻意將 `pam_fprintd` **移出 `common-auth`**，僅在 **`/etc/pam.d/sudo`** 中啟用。GDM 登入與鎖定畫面則由專屬的 `gdm-fingerprint` PAM 服務處理。若在 `common-auth` 中也啟用指紋，解鎖時 `gdm-password` 與 `gdm-fingerprint` 會同時搶佔設備（Claim Race），導致指紋提示消失（詳見 [TROUBLESHOOTING.md §13](../docs/TROUBLESHOOTING.md) 與 GNOME/gdm#1071）。

> [!NOTE]
> **休眠喚醒處理**：安裝程式內建 system-sleep hook（`systemd/fprintd-sleep.sh` → `/usr/lib/systemd/system-sleep/`），在休眠前主動停止 fprintd；同時加固後的 `crfpmoc` 驅動在喚醒後提供有限次數的開啟重試預算（因 S3 喚醒後 EC/FPMCU 通道需要約 2 秒穩定）。如此可保證喚醒後的第一次解鎖必定能正常感應指紋。

> [!NOTE]
> **冷開機登入 vs 鎖定畫面（GNOME Keyring 機制）**：
> 在 Linux 桌面環境（如 GNOME/GDM）中，冷開機首次登入需要輸入使用者密碼以解密 GNOME Keyring（儲存 Wi-Fi 與瀏覽器密碼之金鑰環）。登入後的螢幕鎖定解鎖（`Super + L`）、PAM 授權與 `sudo` 均可直接透過指紋快速驗證。

---

## ❓ 常見問題與疑難排解

### 1. `/dev/cros_fp: Permission denied`

請確認 udev 規則已載入且使用者已加入 `plugdev` 群組：

```bash
sudo cp 60-cros-fp.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=misc
sudo usermod -aG plugdev "$USER"
```

### 2. 加密金鑰權限 (`crfpmoc.key`)

持久化加密 Seed 必須屬於 `root:root` 且具備嚴格權限：

```bash
sudo chmod 0600 /var/lib/fprint/crfpmoc.key
```

### 3. `fprintd` 服務偵錯

檢視即時驅動日誌與狀態轉換：

```bash
sudo journalctl -u fprintd -f
```

---

## 📁 驅動源碼與單元測試

* [`driver/crfpmoc.c`](driver/crfpmoc.c)：核心驅動狀態機、50ms 輪詢迴圈與弱指標記憶體防護。
* [`driver/crfpmoc.h`](driver/crfpmoc.h)：ChromeOS EC Host Command 結構、MKBP 位元遮罩與封包定義。
* [`driver/crfpmoc-ec-transfer.c`](driver/crfpmoc-ec-transfer.c)：透過 `/dev/cros_fp` 執行的非同步 `ioctl` 傳輸。
* [`driver/crfpmoc-ec-transfer.h`](driver/crfpmoc-ec-transfer.h)：傳輸生命週期與回呼標頭檔。
* [`tests/test-crfpmoc-unit.c`](tests/test-crfpmoc-unit.c)：獨立的純 C 語言單元測試套件。

---

## 🙏 致謝 (Credits)

* **Abhinav Baid**、**Felix Niederer**、**Michael Evans**、**[Marco Trevisan (Treviño)](https://github.com/3v1n0)** 及 **libfprint 團隊**。
* **[ChromiumOS EC 團隊](https://chromium.googlesource.com/chromiumos/platform/ec/)** 與 **[Chrultrabook 專案社群](https://chrultrabook.com/)**。
