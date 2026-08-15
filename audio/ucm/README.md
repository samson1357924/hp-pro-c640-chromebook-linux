# Vendored ALSA UCM Profiles (sof-rt5682 / Dratini)

This directory mirrors the 8 UCM profiles required for the `sofrt5682` sound card
(rt5682 headset codec + max98357a speakers) on the HP Pro c640 Chromebook.
They are **not** shipped by the Ubuntu `alsa-ucm-conf` package, which is the root
cause of the "Dummy Output" issue (see [audio/docs/root-cause.md](../docs/root-cause.md)).

## Source

* **Repository**: https://github.com/WeirdTreeThing/alsa-ucm-conf-cros
* **Branch**: `standalone`
* **Vendored commit**: `a46dd193ab81ed71c4465453f5297f21e413769f`
* **License**: BSD 3-Clause (ALSA project), see [LICENSE](LICENSE)

The vendored files are byte-identical to the installed copies on a working
machine (verified via `md5sum`, Ubuntu 26.04 LTS, alsa-ucm-conf 1.2.15.3-1ubuntu1.5).

## Layout

The directory structure mirrors `/usr/share/alsa/ucm2/` so the overlay can be
installed directly:

```
ucm2/
├── conf.d/sof-rt5682/          # card configs (Driver=sof-rt5682, HiFi use-case)
├── platforms/intel-sof/        # platform.conf (Google_Hatch regex) + codec probing
└── codecs/
    ├── max98357a/speaker.conf  # speaker amplifier
    └── hda/hdmi234.conf        # HDMI/DP output (2, 3, 4)
```

## Installation

Run the installer script (handles `alsactl init` + WirePlumber restart):

```bash
chmod +x audio/install-audio-ucm.sh
./audio/install-audio-ucm.sh
```

Manual equivalent:

```bash
sudo cp -r audio/ucm/ucm2/* /usr/share/alsa/ucm2/
sudo alsactl init
systemctl --user restart wireplumber
```

## md5 Verification

```bash
cd audio/ucm && find ucm2 -type f -exec md5sum {} + | sort
```

Reference values (matches source commit `a46dd19`):

```
c327bb86234e0397c40a5247dca634a5  ucm2/codecs/hda/hdmi234.conf
12748e7c945b97ce47629d88a329871f  ucm2/codecs/max98357a/speaker.conf
62e21d4d807b6e7a4f99bc49252a4151  ucm2/conf.d/sof-rt5682/sof-rt5682.conf
ef5cf96e838a33f95d0ea16f38829c55  ucm2/conf.d/sof-rt5682/HiFi.conf
8e28a4ad8f8963a394b5f2e19d963d42  ucm2/conf.d/sof-rt5682/rt5682-headset.conf
13983fb646428aae418184260b1ed612  ucm2/conf.d/sof-rt5682/rt5682-init.conf
a9f7ade6168746c283544480e04d8537  ucm2/platforms/intel-sof/codecs.conf
73c9e80c8d4305a65d0035243aca5180  ucm2/platforms/intel-sof/platform.conf
```

## Updating

1. Re-clone (full) `https://github.com/WeirdTreeThing/alsa-ucm-conf-cros` and check out `standalone`.
2. Compare the 8 files (`diff -r`) against `audio/ucm/ucm2/`.
3. Update the vendored files and this README's commit hash.
4. Upstream tracking: upstreaming via alsa-ucm-conf
   [PR #832](https://github.com/alsa-project/alsa-ucm-conf/pull/832) was
   **withdrawn** 2026-08-15 (needs coordination with the downstream author
   first). Until then, prefer this mirror over distro packages.