[English](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.md) | [繁體中文](https://github.com/samson1357924/hp-pro-c640-chromebook-linux/blob/main/README.zh-TW.md)

# 🔬 深度技術解析：Intel Comet Lake SOF DSP 與 ALSA UCM2 音訊拓撲

本文解析 **HP Pro c640 Chromebook** (Intel Comet Lake PCH-LP cAVS
`[8086:02c8]` / `sof-rt5682`) 之音訊硬體架構、ALSA UCM2 拓撲管理與 PipeWire
路由機制。

---

## 1. 音訊硬體拓撲圖

HP Pro c640 具備三組獨立的音訊晶片與通道：

```text
                             +----------------------------------------+
                             |    Intel Comet Lake cAVS SOF DSP       |
                             |      (snd_sof_pci_intel_cnl)           |
                             +----+-----------------+---------------+--+
                                  |                 |               |
              I2C4 + I2S          |                 | I2S           | PDM
                   +--------------+                 |               |
                   |                                |               |
                   v                                v               v
    +------------------------------+   +-----------------------+   +-------------------+
    |    Realtek RT5682 Codec      |   | Maxim MAX98357A Amp   |   | 2-ch Digital DMIC |
    |  - PCM 0: Headphone DAC      |   | - PCM 5: Internal     |   | - PCM 1: Stereo   |
    |  - PCM 0: Headset Mic ADC    |   |   Stereo Speakers     |   |   Microphone Array|
    |  - JD1: Jack Detection       |   +-----------------------+   +-------------------+
    +------------------------------+
```

---

## 2. "Dummy Output" 根本原因剖析

當 Linux 系統未安裝專屬 UCM2 設定檔時，PipeWire 會回退至傳統 PulseAudio 的 `alsa-card-profile` (ACP) 機制：

1. **Phantom Jack 探測盲點**：
   - MAX98357A 喇叭功放為直連裝置，設定檔中定義了 `[Jack Speaker Phantom]`。
   - 核心僅在 HDA 聲卡上建立 Phantom Jack kcontrol，ASoC 架構（如 SOF）**從不建立 Phantom Jack 的 ALSA kcontrol**。
   - ACP 的 `jack_probe()` 因找不到 kcontrol，將 `analog-output-speaker` 整個 mixer path 直接丟棄。
2. **Profile 癱瘓與 Dummy Output 降級**：
   - 唯一的類比輸出路徑僅剩耳機孔；在未插耳機時，耳機孔狀態為 `available: no`。
   - 所有 Analog Profile 全數變成 `available: no`，WirePlumber 的 `find-best-profile.lua` 只能選擇 `off`，降級為 `Dummy Output`。

---

## 3. UCM2 雙層防禦架構

本專案實施的雙層修復機制：

1. **第一層：部署完整的 ALSA UCM2 規範檔 (PR #832)**：
   - `sof-rt5682.conf` / `HiFi.conf` / `rt5682-headset.conf` / `max98357a/speaker.conf`
   - 精確指定耳機走 PCM 0，喇叭走 PCM 5，雙麥克風透過 `SplitPCM` 拆解 PCM 1。
   - 繞過 ACP 傳統探測，WirePlumber 直接套用 UCM HiFi Profile (Priority 9600)。
2. **第二層：PipeWire ACP Phantom Jack 補丁 (MR #5428)**：
   - 修正 `jack_probe()`，若缺乏 kcontrol 的 jack 名稱包含 `Phantom`，只要位於 `required-any` 內，即視為存在，將可用性保留為 `unknown`。
   - 即使在無 UCM 的 Live CD 或新裝環境下，也不會落入 Dummy Output 全機靜音的困境。
