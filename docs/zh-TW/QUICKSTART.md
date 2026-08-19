[English](../../README.md) | [繁體中文](../../README.zh-TW.md)

# 🚀 快速上手指南 (Quick Start Guide)

本指南將在幾分鐘內引導您（指紋驅動編譯時間較長）在 **HP Pro c640 Chromebook** (Google `dratini` / `hatch`) 上完成所有硬體驅動配置。

---

## ⚡ 一鍵全自動安裝 (One-Liner Setup)

複製並執行以下指令，全自動安裝頂排鍵盤映射、ALSA UCM2 音效配置與 `crfpmoc` 指紋驅動：

```bash
git clone https://github.com/samson1357924/hp-pro-c640-chromebook-linux.git ~/projects/hp-pro-c640-chromebook-linux
cd ~/projects/hp-pro-c640-chromebook-linux
chmod +x setup.sh
./setup.sh --all
```

---

## 🧭 常用指令一覽

| 目的 | 指令 |
| :--- | :--- |
| **一鍵全功能安裝** | `./setup.sh --all` |
| **僅安裝音訊 UCM 配置** | `./setup.sh --audio` 或 `./audio/install-audio.sh` |
| **僅安裝指紋驅動與 PAM** | `./setup.sh --fingerprint` 或 `./fingerprint/install-fingerprint.sh` |
| **僅安裝鍵盤頂排映射** | `./setup.sh --keyboard` 或 `./keyboard/install-keyboard.sh` |
| **僅安裝電源管理調校** | `./power/install-power.sh` |
| **啟用 80% 電池保護服務** | `./ec/install-ec.sh --enable-battery-limit` |
| **系統硬體綜合診斷** | `./setup.sh --check` 或 `./scripts/detect-hardware.sh` |
| **預覽所有變更 (Dry-Run)** | `./setup.sh --all --dry-run` |
| **一鍵解除安裝與還原** | `./setup.sh --uninstall` |

---

## 🖐️ 指紋快速登錄

安裝完成後，使用標準 `fprintd` 工具登錄指紋：

```bash
# 1. 登錄預設手指 (右手食指)
fprintd-enroll "$USER"

# 2. 驗證指紋
fprintd-verify "$USER"

# 3. 測試 sudo 認證 (使用 -k 清除現有 sudo 快取)
sudo -k && sudo whoami
```

---

## 🔊 音效即時測試

```bash
# 測試立體聲喇叭輸出
speaker-test -c 2 -t wav

# 查看當前音效設備狀態
wpctl status
```

---

## 📖 下一步閱讀

* 遇到任何疑難雜症？請參閱 [疑難排解與避坑 FAQ (TROUBLESHOOTING.md)](TROUBLESHOOTING.md)。
* 想了解 MrChromebox 刷機與硬體寫入保護解除？請參閱 [韌體刷機與還原指南 (FIRMWARE.md)](FIRMWARE.md)。
* 特定發行版 (Fedora/Arch/NixOS)？請參閱 [發行版專屬指南 (distros/)](distros/ubuntu-debian.md)。
