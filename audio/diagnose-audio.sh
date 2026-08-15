#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# HP Pro c640 Chromebook (Google Dratini) Audio Diagnostic Script

SIM_NO_UCM=0
OUTPUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sim-no-ucm) SIM_NO_UCM=1 ;;
        -o|--output)  OUTPUT="$2"; shift ;;
        -h|--help)
            echo "Usage: $0 [--sim-no-ucm] [-o FILE]"
            echo ""
            echo "  --sim-no-ucm   Simulate a machine WITHOUT UCM using spa-acp-tool"
            echo "                 (restarts your PipeWire session; run from a normal login)"
            echo "  -o FILE        Also append the report to FILE"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done
if [ -n "$OUTPUT" ]; then
    exec > >(tee -a "$OUTPUT") 2>&1
fi

UCM_FILES=(
    "conf.d/sof-rt5682/sof-rt5682.conf"
    "conf.d/sof-rt5682/HiFi.conf"
    "conf.d/sof-rt5682/rt5682-headset.conf"
    "conf.d/sof-rt5682/rt5682-init.conf"
    "platforms/intel-sof/platform.conf"
    "platforms/intel-sof/codecs.conf"
    "codecs/max98357a/speaker.conf"
    "codecs/hda/hdmi234.conf"
)

echo "==========================================================="
echo "   HP Pro c640 Chromebook Audio Diagnostic Report          "
echo "==========================================================="
echo ""

echo "--- [1/5] System & DMI ---"
echo "Product Name : $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 'Unknown')"
echo "Sys Vendor   : $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo 'Unknown')"
echo "Board Name   : $(cat /sys/class/dmi/id/board_name 2>/dev/null || echo 'Unknown')"
echo "Product Fam. : $(cat /sys/class/dmi/id/product_family 2>/dev/null || echo 'Unknown')"
echo "Kernel       : $(uname -r)"
echo ""

echo "--- [2/5] Sound Cards & PCM Map ---"
if command -v aplay >/dev/null 2>&1; then
    aplay -l 2>/dev/null | grep -E "^card|^[[:space:]]+device" || echo "  [INFO] No playback devices found."
else
    echo "  [INFO] aplay not installed."
fi
if command -v arecord >/dev/null 2>&1; then
    arecord -l 2>/dev/null | grep -E "^card|^[[:space:]]+device" || echo "  [INFO] No capture devices found."
fi
echo ""

echo "--- [3/5] UCM Installation Status (/usr/share/alsa/ucm2/) ---"
COUNT=0
for rel in "${UCM_FILES[@]}"; do
    if [ -f "/usr/share/alsa/ucm2/$rel" ]; then
        echo "  [OK] $rel"
        COUNT=$((COUNT + 1))
    else
        echo "  [MISSING] $rel"
    fi
done
echo "  $COUNT/8 UCM files installed."
[ "$COUNT" = 8 ] || echo "  [INFO] Missing UCM files = root cause of Dummy Output. Run ./audio/install-audio-ucm.sh"
echo ""

echo "--- [4/5] PipeWire Status ---"
if command -v wpctl >/dev/null 2>&1; then
    wpctl status 2>/dev/null | sed -n '/^Audio/,/^Streams/p' || echo "  [INFO] PipeWire not running."
fi
if command -v pw-dump >/dev/null 2>&1; then
    echo "ALSA card names (pw-dump):"
    pw-dump 2>/dev/null | grep -o '"alsa.card_name" : "[^"]*"' | sort -u || true
fi
if command -v systemctl >/dev/null 2>&1; then
    echo "User services:"
    systemctl --user is-active pipewire wireplumber 2>/dev/null || true
fi
echo ""

echo "--- [5/5] SOF Kernel Logs ---"
if command -v dmesg >/dev/null 2>&1; then
    if dmesg 2>/dev/null | grep -i "sof" | tail -n 20; then
        :
    else
        echo "  [INFO] dmesg restricted; retrying with sudo:"
        sudo dmesg 2>/dev/null | grep -i "sof" | tail -n 20 || echo "  [INFO] No SOF dmesg lines available."
    fi
fi
echo ""

sim_no_ucm() {
    echo ">>> [SIM] Testing profile-set discovery WITHOUT UCM ..."
    systemctl --user stop wireplumber pipewire 2>/dev/null || true
    trap 'systemctl --user start pipewire wireplumber 2>/dev/null || true' EXIT
    export ACP_PATHS_DIR="/usr/share/alsa-card-profile/mixer/paths"
    export ACP_PROFILES_DIR="/usr/share/alsa-card-profile/mixer/profile-sets"
    systemctl --user start pipewire
    sleep 1
    CARD="$(aplay -l 2>/dev/null | grep -oP 'card \K[0-9]+(?=.*sofrt5682)' | head -n1)"
    if command -v spa-acp-tool >/dev/null 2>&1 && [ -n "$CARD" ]; then
        spa-acp-tool -c "$CARD" list-profiles 2>&1 || true
    else
        echo "  [INFO] spa-acp-tool unavailable or card not found; skipping simulation."
        echo "  [INFO] Install pipewire-tools and re-run."
    fi
}
[ "$SIM_NO_UCM" = 1 ] && sim_no_ucm

echo "Diagnostic complete!"