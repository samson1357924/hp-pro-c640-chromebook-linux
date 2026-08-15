# Third-Party Credits & Copyright Attributions

This project incorporates, adapts, or interfaces with several open-source
projects. We gratefully acknowledge the substantial contributions of the
original authors, maintainers, and community projects.

All upstream copyright notices, licenses, and conditions are strictly preserved
in accordance with open-source licensing standards.

---

## 1. ChromeOS Match-on-Chip Fingerprint Driver (`crfpmoc`)

* **Target Directory**: `fingerprint/driver/`, `fingerprint/tests/`
* **License**: [GNU Lesser General Public License v2.1 or later (LGPL-2.1-or-later)](LICENSES/LGPL-2.1-or-later.txt)
* **Upstream Projects**:
  * [libfprint (freedesktop.org)](https://gitlab.freedesktop.org/libfprint/libfprint)
  * [crfpmoc-driver by Abhinav Baid (libfprint MR #493)](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/493)
  * [libfprint cros-fp branch by Marco Trevisan (Treviño)](https://github.com/3v1n0/libfprint)
* **Copyright Holders**:
  * Copyright (C) 2024 Abhinav Baid `<abhinavbaid@gmail.com>`
  * Copyright (C) 2024 Felix Niederer `<felix@niederer.dev>`
  * Copyright (C) 2025 Michael Evans `<mike.67.442@gmail.com>`
  * Copyright (C) 2026 Marco Trevisan (Treviño) `<mail@3v1n0.net>`
  * Copyright (C) 2026 Samson `<samson1357924@users.noreply.github.com>` (Hardening & Polling fixes)
* **Summary of Derivative Modifications in this Repository**:
  * Implemented a 50ms periodic state machine polling loop (`G_SOURCE_CONTINUE`)
    to eliminate epoll event starvation on kernels without hardware GPIO
    interrupt endpoints.
  * Added weak-pointer safety guards (`g_weak_ref_init` / `g_weak_ref_get`) to
    eliminate Use-After-Free crashes during asynchronous enrollment cancellation.
  * Implemented dynamic random seed storage in `/var/lib/fprint/crfpmoc.key` with strict `0600` permissions.
  * Created standalone C unit test suite (`fingerprint/tests/test-crfpmoc-unit.c`)
    validating Protocol v3/v1 packet sizes, LE conversions, and bitmasks.

---

## 2. ALSA Use Case Manager (UCM2) Configurations for Chromebooks

* **Target Directory**: `audio/ucm/`
* **License**: [BSD 3-Clause "New" or "Revised" License (BSD-3-Clause)](LICENSES/BSD-3-Clause.txt)
* **Upstream Projects**:
  * [alsa-ucm-conf-cros by WeirdTreeThing](https://github.com/WeirdTreeThing/alsa-ucm-conf-cros)
  * [ALSA Project alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf)
* **Copyright Holders**:
  * Copyright (c) 2019-2026 Advanced Linux Sound Architecture (ALSA) project
  * Copyright (c) 2022-2026 WeirdTreeThing `<https://github.com/WeirdTreeThing>` and alsa-ucm-conf-cros contributors
* **Attribution & BSD Conditions**:
  * Redistribution and use in source and binary forms are permitted provided
    that the copyright notices, conditions, and disclaimers are retained.
  * Neither the name of the ALSA Project nor WeirdTreeThing is used to endorse or promote products derived from this repository.

---

## 3. PipeWire ACP Phantom Jack Patch

* **Target Directory**: `audio/patches/acp-phantom-jack.patch`
* **License**: [MIT License](LICENSES/MIT.txt)
* **Upstream Target**: [PipeWire](https://gitlab.freedesktop.org/pipewire/pipewire) (`spa/plugins/alsa/acp/alsa-mixer.c`)
* **Author / Submitter**: Samson `<samson1357924>`
* **Status**: Submitted upstream via PipeWire Merge Request #5428 under Developer Certificate of Origin (DCO).

---

## 4. ChromiumOS Embedded Controller (EC) Protocols

* **Target Directory**: `ec/`, `scripts/c640-ec-control.sh`
* **License**: [BSD 3-Clause License (BSD-3-Clause)](LICENSES/BSD-3-Clause.txt)
* **Upstream Project**: [ChromiumOS Platform EC](https://chromium.googlesource.com/chromiumos/platform/ec/)
* **Copyright Holders**:
  * Copyright (c) 2010-2026 The ChromiumOS Authors

---

## 5. Ecosystem & Community Acknowledgments

We express our sincere gratitude to the broader Linux on Chromebook community:

* **MrChromebox** ([mrchromebox.tech](https://mrchromebox.tech/)): For UEFI Full ROM coreboot firmware builds.
* **Chrultrabook Project**: For pioneering Linux documentation and hardware exploration across Google Chromebook platforms.
* **Sound Open Firmware (SOF) Project**: For the open-source audio DSP firmware stack enabling Intel Comet Lake audio.
* **Linux Surface Team**: For architectural inspiration regarding clean hardware enablement scripts and diagnostic tooling.
