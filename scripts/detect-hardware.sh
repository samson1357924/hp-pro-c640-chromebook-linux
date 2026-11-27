#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# scripts/detect-hardware.sh - Comprehensive Hardware Diagnostic Tool for HP Pro c640 (Dratini)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/logger.sh
source "$ROOT_DIR/lib/logger.sh"
# shellcheck source=lib/distro.sh
source "$ROOT_DIR/lib/distro.sh"
# shellcheck source=lib/syscheck.sh
source "$ROOT_DIR/lib/syscheck.sh"

# Keyboard/hwdb verification knobs. The sysfs roots and the query backend are
# overridable so --self-test can exercise the exact same code with stubs.
KB_FIXTURE="$ROOT_DIR/keyboard/tests/hwdb-top-row-scancodes.tsv"
KB_HWDB_FILE="${KB_HWDB_FILE:-/etc/udev/hwdb.d/90-chromebook-keyboard.hwdb}"
DMI_BASE="${DMI_BASE:-/sys/class/dmi/id}"
INPUT_BASE="${INPUT_BASE:-/sys/class/input}"
KB_HWDB_QUERY_FN="${KB_HWDB_QUERY_FN:-kb_hwdb_query_systemd}"
KB_UDEVADM_BIN="${KB_UDEVADM_BIN:-udevadm}"
KB_EVENT_BASE="${KB_EVENT_BASE:-/dev/input}"
KB_SUCCESS_MARKER="hwdb top-row verification PASSED"
# Real EVIOCGKEYCODE comparison is delegated to check-top-row-hwdb.py. The
# result-file backend lets --self-test exercise all three outcomes without a
# real event node. Return codes: 0 confirmed, 1 mismatch, 2 inconclusive.
KB_KEYCODE_CHECK_FN="${KB_KEYCODE_CHECK_FN:-kb_keycode_check_tool}"
KB_STUB_KEYCODE_RESULT="${KB_STUB_KEYCODE_RESULT:-}"

run_diagnostic() {
    log_section "HP Pro c640 Chromebook (Google Dratini) Full Diagnostic Report"

    # 1. System & Firmware Identification
    log_step 1 6 "System & OS Identification"
    log_info "OS / Distro  : $DISTRO_NAME ($DISTRO_FAMILY, ID: $DISTRO_ID)"
    log_info "Kernel       : $(uname -r)"
    check_dmi_board || true

    # 2. Audio Subsystem
    log_step 2 6 "Audio Subsystem (SOF DSP & UCM2)"
    check_sof_audio_modules || true
    check_sof_firmware_files || true

    if command -v aplay > /dev/null 2>&1; then
        log_info "ALSA Playback Sound Cards:"
        if LC_ALL=C aplay -l 2> /dev/null | grep -E "^card [0-9]+:"; then
            LC_ALL=C aplay -l 2> /dev/null | grep -E "^card [0-9]+:" | while read -r line; do
                log_success "  $line"
            done
        elif aplay -l 2> /dev/null | grep -E "(card|卡|裝置)"; then
            aplay -l 2> /dev/null | grep -E "(card|卡|裝置)" | while read -r line; do
                log_success "  $line"
            done
        else
            log_warn "  No ALSA sound cards detected."
        fi
    fi

    local ucm_files=(
        "conf.d/sof-rt5682/sof-rt5682.conf"
        "conf.d/sof-rt5682/HiFi.conf"
        "conf.d/sof-rt5682/rt5682-headset.conf"
        "conf.d/sof-rt5682/rt5682-init.conf"
        "platforms/intel-sof/platform.conf"
        "platforms/intel-sof/codecs.conf"
        "codecs/max98357a/speaker.conf"
        "codecs/hda/hdmi234.conf"
    )
    log_info "ALSA UCM2 Profile Status (/usr/share/alsa/ucm2/):"
    local missing_ucm=0
    for rel in "${ucm_files[@]}"; do
        if [ -f "/usr/share/alsa/ucm2/$rel" ]; then
            log_success "  [OK] $rel"
        else
            log_warn "  [MISSING] $rel"
            missing_ucm=1
        fi
    done
    [ "$missing_ucm" = 0 ] || log_info "  Tip: Run './setup.sh --audio-install' to deploy missing UCM profiles."

    if command -v wpctl > /dev/null 2>&1; then
        log_info "PipeWire Routing Status:"
        if wpctl status 2> /dev/null | grep -q "Speaker"; then
            log_success "  PipeWire Speaker sink is active!"
        else
            log_warn "  Speaker sink not found in wpctl status."
        fi
    fi

    # 3. Fingerprint Subsystem
    log_step 3 6 "Fingerprint Subsystem (ChromeOS MoC)"
    check_cros_fp_device || true

    local local_user
    local_user="$(get_real_user)"
    log_info "User '$local_user' group membership:"
    if id -nG "$local_user" 2> /dev/null | grep -qw "plugdev"; then
        log_success "  User '$local_user' is in 'plugdev' group."
    else
        log_warn "  User '$local_user' is NOT in 'plugdev' group. (Run: sudo usermod -aG plugdev $local_user)"
    fi

    log_info "Installed libfprint binaries in $LIBDIR:"
    ls -la "$LIBDIR"/libfprint-2.so* 2> /dev/null || log_warn "  No custom libfprint-2.so in $LIBDIR"

    if command -v fprintd-list > /dev/null 2>&1; then
        log_info "fprintd Enrolled Fingerprints for $local_user:"
        fprintd-list "$local_user" 2> /dev/null || log_warn "  fprintd returned non-zero. Device may not be registered yet."
    fi

    # 4. Keyboard & Function Keys (+ Backlight Sync)
    log_step 4 6 "Keyboard Top-Row Action Mapping & Backlight Sync"
    verify_keyboard_hwdb || true

    if [ -f /etc/udev/rules.d/61-chromeos-kbd-backlight.rules ]; then
        log_success "  61-chromeos-kbd-backlight.rules installed"
    else
        log_info "  Backlight udev rule not installed (optional, run './setup.sh --keyboard')"
    fi

    if [ -f /usr/local/bin/c640-kbd-backlight-sync ]; then
        log_success "  c640-kbd-backlight-sync daemon installed at /usr/local/bin/c640-kbd-backlight-sync"
        if [ -x /usr/local/bin/c640-kbd-backlight-sync ]; then
            /usr/local/bin/c640-kbd-backlight-sync --check 2> /dev/null | sed 's/^/    /' || true
        fi
        if systemctl --global is-enabled c640-kbd-backlight-sync.service > /dev/null 2>&1; then
            log_success "  Backlight user service enabled (global)"
        else
            log_warn "  Backlight user service not enabled (global)"
        fi
        if [ -f /etc/systemd/user/c640-kbd-backlight-sync.service ]; then
            log_success "  Backlight user service file present"
        fi
    else
        log_info "  Backlight daemon not installed (run './setup.sh --keyboard')"
    fi

    if [ -f /usr/lib/systemd/system-sleep/c640-kbd-backlight-sleep.sh ]; then
        log_success "  Backlight sleep hook present at /usr/lib/systemd/system-sleep/"
    else
        log_info "  Backlight sleep hook not installed"
    fi

    if [ -f /sys/class/leds/chromeos::kbd_backlight/brightness ]; then
        local curr max
        curr="$(cat /sys/class/leds/chromeos::kbd_backlight/brightness 2> /dev/null || echo "?")"
        max="$(cat /sys/class/leds/chromeos::kbd_backlight/max_brightness 2> /dev/null || echo "?")"
        log_info "  Current kbd backlight: $curr / $max"
    else
        log_warn "  No kbd backlight sysfs (/sys/class/leds/chromeos::kbd_backlight) - is this a hatch device?"
    fi

    if systemctl is-active --quiet keyd 2> /dev/null; then
        log_success "  keyd daemon is running for advanced dual-role (Search tap=CapsLock hold=Super)"
    elif systemctl is-enabled --quiet keyd 2> /dev/null; then
        log_warn "  keyd is enabled but not active"
    else
        if [ -f /etc/keyd/cros.conf ] || [ -f /etc/keyd/default.conf ] || [ -L /etc/keyd/default.conf ]; then
            log_info "  keyd config present but keyd not active (sudo systemctl enable --now keyd)"
        else
            log_info "  keyd not installed (optional, use --with-keyd)"
        fi
    fi
    if [ -f /etc/keyd/cros.conf ]; then
        log_success "  keyd config at /etc/keyd/cros.conf"
        local kd_bin="" kd_rc=0
        kd_bin="$(keyd_bin 2> /dev/null || true)"
        if [ -n "$kd_bin" ]; then
            log_info "  keyd binary: $kd_bin"
            keyd_check_config /etc/keyd/cros.conf || kd_rc=$?
            case "$kd_rc" in
                0) log_success "  keyd config syntax valid" ;;
                3) log_info "  keyd < 2.6 has no 'check' subcommand; validated on reload" ;;
                *) log_warn "  keyd config syntax check failed for /etc/keyd/cros.conf" ;;
            esac
        fi
    fi
    if [ -L /etc/keyd/default.conf ]; then
        local kd_target
        kd_target="$(readlink /etc/keyd/default.conf 2> /dev/null || echo "?")"
        log_info "  keyd default.conf -> $kd_target"
        if [ ! -e /etc/keyd/default.conf ]; then
            log_warn "  keyd default.conf is dangling symlink"
        fi
    fi

    # 5. Power & Battery Management
    log_step 5 6 "Power Management & S0ix Sleep"
    if [ -f /sys/power/mem_sleep ]; then
        log_info "Supported mem_sleep modes: $(cat /sys/power/mem_sleep)"
    fi

    if [ -d /sys/class/power_supply/BAT0 ]; then
        local bat_status bat_cap
        bat_status="$(cat /sys/class/power_supply/BAT0/status 2> /dev/null || echo Unknown)"
        bat_cap="$(cat /sys/class/power_supply/BAT0/capacity 2> /dev/null || echo Unknown)"
        log_success "Battery BAT0 detected: ${bat_cap}% ($bat_status)"
    fi

    # 6. Summary
    log_step 6 6 "Diagnostic Summary"
    log_info "Hardware diagnostic run complete! Log saved to $LOG_FILE."
}

# ---------------------------------------------------------------------------
# Keyboard / hwdb verification
#
# The old code queried `systemd-hwdb query` with a *hardcoded* Dratini
# modalias. That only proves the DATABASE contains an entry; it says nothing
# about the machine we are running on, so unrelated hardware got a false
# "all fixture present" success. It also still probed the long-removed
# `pnHatch` rule and only checked `db=leftmeta` for the HP stanza.
#
# We now separate two independent checks and require BOTH for success:
#   STATIC  - all 11 fixture mappings exist in the hwdb source file AND in the
#             compiled database, for the Dratini *and* HP/c640 DMI patterns.
#   DYNAMIC - an actual AT keyboard device exists, and the modalias that udev
#             would use for THAT device matches an entry with all 11 mappings.
#             On THAT device's event node, udevadm info is consulted for
#             applied KEYBOARD_KEY_* properties. That only proves the
#             *properties are present*, NOT that the kernel translation table
#             was actually changed, so it is reported as a neutral info line.
#             A second, independent check delegates EVIOCGKEYCODE comparison to
#             keyboard/tests/check-top-row-hwdb.py on the SAME event node; only
#             a matching kernel map allows a full-success claim. Missing
#             udevadm/event node, a mismatch, or an unavailable ioctl is a
#             warning and never a full success.
# ---------------------------------------------------------------------------

# Real backend: query the compiled hwdb with a modalias (the same operation
# udev performs for a matched device).
kb_hwdb_query_systemd() {
    local modalias="$1"
    if ! command -v systemd-hwdb > /dev/null 2>&1; then
        return 127
    fi
    systemd-hwdb query "$modalias" 2> /dev/null
}

# Test backend: emulate `systemd-hwdb query` against a stub hwdb text file.
# Consecutive modalias pattern lines share the following property block, just
# like a real hwdb stanza.
kb_hwdb_query_stub() {
    local modalias="$1"
    local db="${KB_STUB_HWDB:-}"
    local line group_matched=0 in_props=0
    [ -n "$db" ] && [ -f "$db" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '' | \#*)
                continue
                ;;
            [[:space:]]*)
                in_props=1
                if [ "$group_matched" -eq 1 ]; then
                    printf '%s\n' "${line#"${line%%[![:space:]]*}"}"
                fi
                ;;
            *)
                if [ "$in_props" -eq 1 ]; then
                    group_matched=0
                    in_props=0
                fi
                # Unquoted RHS is intentional: glob-match like hwdb patterns.
                # shellcheck disable=SC2053
                if [[ "$modalias" == $line ]]; then
                    group_matched=1
                fi
                ;;
        esac
    done < "$db"
}

kb_read_dmi_value() {
    local file="$1"
    local value=""
    if [ -r "$file" ]; then
        value="$(cat "$file" 2> /dev/null || true)"
    fi
    # DMI files are single-line; strip line breaks (a tab/space is legal inside
    # a product name and must be preserved for hwdb pattern matching).
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    printf '%s' "$value"
}

# Compose the modalias udev's 60-evdev.rules uses for an AT keyboard:
#   IMPORT{builtin}="hwdb 'evdev:atkbd:$attr{[dmi/id]modalias}'"
# using the six requested DMI/id fields (bvn/bvr/bd/svn/pn/pvr).
kb_compose_dmi_modalias() {
    local dmi_base="$1"
    local bvn bvr bd svn pn pvr
    bvn="$(kb_read_dmi_value "$dmi_base/bios_vendor")"
    bvr="$(kb_read_dmi_value "$dmi_base/bios_version")"
    bd="$(kb_read_dmi_value "$dmi_base/bios_date")"
    svn="$(kb_read_dmi_value "$dmi_base/sys_vendor")"
    pn="$(kb_read_dmi_value "$dmi_base/product_name")"
    pvr="$(kb_read_dmi_value "$dmi_base/product_version")"
    printf 'evdev:atkbd:dmi:bvn%s:bvr%s:bd%s:svn%s:pn%s:pvr%s\n' \
        "$bvn" "$bvr" "$bd" "$svn" "$pn" "$pvr"
}

# Normalize the TSV fixture to three tab-separated fields: scancode, key, label.
# Rows in the fixture mix 3 and 4 columns (an empty third field for short key
# names), so parse with awk and drop empty columns instead of relying on
# `IFS=$'\t' read -r sc key name`, which mis-assigns the label.
kb_fixture_rows() {
    local fixture="$1"
    awk -F'\t' '
        /^[[:space:]]*($|#)/ { next }
        {
            sc = $1; key = $2; label = ""
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", sc)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            for (i = 3; i <= NF; i++) {
                f = $i
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", f)
                if (f != "") label = (label == "" ? f : label " " f)
            }
            if (sc != "" && key != "") printf "%s\t%s\t%s\n", sc, key, label
        }
    ' "$fixture"
}

# Print fixture rows whose KEYBOARD_KEY_<sc>=<key> is absent from TEXT.
kb_missing_in_text() {
    local text="$1"
    local fixture="$2"
    local sc key label
    while IFS=$'\t' read -r sc key label; do
        grep -qE "KEYBOARD_KEY_${sc}=${key}([[:space:]]|$)" <<< "$text" \
            || printf '%s|%s|%s\n' "$sc" "$key" "$label"
    done < <(kb_fixture_rows "$fixture")
}

# True when DEV shows any of the three AT-keyboard sysfs signals:
#   1. a modalias already starting with evdev:atkbd: (stubs / newer udev),
#   2. the device name "AT Translated Set 2 keyboard" (real hardware),
#   3. a driver symlink whose basename is "atkbd" (DRIVERS=="atkbd" in udev).
kb_is_atkbd_dev() {
    local dev="$1"
    local modalias name driver
    modalias=""
    [ -r "$dev/modalias" ] && modalias="$(cat "$dev/modalias" 2> /dev/null || true)"
    case "$modalias" in
        evdev:atkbd:*) return 0 ;;
    esac
    name=""
    [ -r "$dev/name" ] && name="$(cat "$dev/name" 2> /dev/null || true)"
    driver=""
    [ -e "$dev/device/driver" ] && driver="$(basename "$(readlink -f "$dev/device/driver" 2> /dev/null || echo "")")"
    [ "$name" = "AT Translated Set 2 keyboard" ] || [ "$driver" = "atkbd" ]
}

# Find an AT keyboard under INPUT_BASE and print the evdev:atkbd: modalias udev
# would use for it. Signal (1) returns the device's modalias verbatim, but the
# caller STILL queries the hwdb with it: a non-target DMI therefore cannot turn
# into a false success. For signals (2)/(3) the modalias is built from DMI,
# because the kernel's `input:b0011v...` modalias is NOT what hwdb matches for
# atkbd; 60-evdev.rules substitutes the DMI modalias instead. A real AT
# keyboard device is still required before ever claiming success.
kb_find_atkbd_modalias() {
    local input_base="$1"
    local dmi_base="$2"
    local dev modalias
    for dev in "$input_base"/input*; do
        [ -d "$dev" ] || continue
        kb_is_atkbd_dev "$dev" || continue
        modalias=""
        [ -r "$dev/modalias" ] && modalias="$(cat "$dev/modalias" 2> /dev/null || true)"
        case "$modalias" in
            evdev:atkbd:*)
                printf '%s\n' "$modalias"
                return 0
                ;;
        esac
        kb_compose_dmi_modalias "$dmi_base"
        return 0
    done
    return 1
}

# Print the basename of the event node (e.g. event2) that belongs to the AT
# keyboard found under INPUT_BASE, so the udevadm check can be scoped to that
# one device. Prefer the sysfs inputN/eventM child; fall back to deriving M
# from the inputN number for minimal/stub sysfs trees.
kb_atkbd_event_node() {
    local input_base="$1"
    local dev ev num
    for dev in "$input_base"/input*; do
        [ -d "$dev" ] || continue
        kb_is_atkbd_dev "$dev" || continue
        for ev in "$dev"/event*; do
            [ -e "$ev" ] || continue
            printf '%s\n' "${ev##*/}"
            return 0
        done
        num="${dev##*/input}"
        case "$num" in
            '' | *[!0-9]*) ;;
            *)
                printf 'event%s\n' "$num"
                return 0
                ;;
        esac
    done
    return 1
}

# Real backend: ask check-top-row-hwdb.py to compare EVIOCGKEYCODE on the SAME
# event node the udevadm check used. It opens the node via os.open() and needs
# neither python3-evdev nor a grab. Return: 0 PASS, 1 FAIL/MISMATCH, 2 anything
# inconclusive (no python3, permission/ioctl failure, missing RESULT, ...).
kb_keycode_check_tool() {
    local dev="$1"
    local fixture="${2:-$KB_FIXTURE}"
    local tool="$ROOT_DIR/keyboard/tests/check-top-row-hwdb.py"
    local output
    if ! command -v python3 > /dev/null 2>&1; then
        return 2
    fi
    if [ ! -f "$tool" ]; then
        return 2
    fi
    # `|| true` keeps set -e from aborting on a failed/inaccessible device;
    # the RESULT line below is the sole verdict contract.
    output="$(python3 "$tool" --device "$dev" --fixture "$fixture" 2>&1 || true)"
    case "$output" in
        *RESULT=PASS*) return 0 ;;
        *RESULT=FAIL* | *MISMATCH*) return 1 ;;
        *) return 2 ;;
    esac
}

# Test backend: read ok|mismatch|inconclusive from KB_STUB_KEYCODE_RESULT.
kb_keycode_check_stub() {
    local result_file="${KB_STUB_KEYCODE_RESULT:-}"
    local value=""
    if [ -z "$result_file" ] || [ ! -r "$result_file" ]; then
        return 2
    fi
    value="$(cat "$result_file" 2> /dev/null || true)"
    case "$value" in
        ok) return 0 ;;
        mismatch) return 1 ;;
        inconclusive) return 2 ;;
        *) return 2 ;;
    esac
}

# Confirm the kernel map on the AT keyboard's OWN event node (not just any
# /dev/input/event*). udevadm KEYBOARD_KEY_* properties only prove presence;
# the delegated EVIOCGKEYCODE comparison is the independent proof. Return:
#   0 = confirmed by EVIOCGKEYCODE (udev properties also present)
#   1 = udev properties missing, or EVIOCGKEYCODE mismatch
#   2 = inconclusive (no udevadm/event node, or EVIOCGKEYCODE unavailable)
kb_check_kernel_applied() {
    local fixture="$1"
    local event_node="${2:-}"
    local udevadm_bin="${KB_UDEVADM_BIN:-udevadm}"
    local event_base="${KB_EVENT_BASE:-/dev/input}"
    local keycode_fn="${KB_KEYCODE_CHECK_FN:-kb_keycode_check_tool}"
    local dev info missing keycode_rc=0
    if ! command -v "$udevadm_bin" > /dev/null 2>&1; then
        log_warn "  kernel-applied check inconclusive: udevadm unavailable"
        return 2
    fi
    if [ -z "$event_node" ]; then
        log_warn "  kernel-applied check inconclusive: no event node for the AT keyboard"
        return 2
    fi
    dev="$event_base/$event_node"
    if [ ! -e "$dev" ]; then
        log_warn "  kernel-applied check inconclusive: $dev missing"
        return 2
    fi
    info="$("$udevadm_bin" info "$dev" 2> /dev/null || true)"
    missing="$(kb_missing_in_text "$info" "$fixture")"
    if [ -n "$missing" ]; then
        log_warn "  kernel-applied check: $dev is missing KEYBOARD_KEY_* properties:"
        printf '%s\n' "$missing" | sed 's/^/    /' >&2
        return 1
    fi
    log_info "  udev properties present on $dev (not an independent kernel-map proof)"

    "$keycode_fn" "$dev" "$fixture" || keycode_rc=$?
    case "$keycode_rc" in
        0)
            log_success "  kernel map confirmed on $dev (EVIOCGKEYCODE matches fixture)"
            return 0
            ;;
        1)
            log_warn "  kernel map on $dev MISMATCHES expected scancode->keycode table"
            return 1
            ;;
        2)
            log_warn "  kernel map check inconclusive (EVIOCGKEYCODE unavailable); udev properties only"
            return 2
            ;;
        *)
            log_warn "  kernel map check inconclusive (EVIOCGKEYCODE unavailable); udev properties only"
            return 2
            ;;
    esac
}

verify_keyboard_hwdb() {
    local fixture="${1:-$KB_FIXTURE}"
    local dmi_base="${2:-$DMI_BASE}"
    local input_base="${3:-$INPUT_BASE}"
    local hwdb_file="${4:-$KB_HWDB_FILE}"
    local query_fn="${5:-$KB_HWDB_QUERY_FN}"

    if [ ! -f "$fixture" ]; then
        log_warn "  Fixture $fixture not found; cannot verify keyboard hwdb"
        return 2
    fi
    local row_count
    row_count="$(kb_fixture_rows "$fixture" | wc -l)"
    log_info "  Fixture: $fixture ($row_count scancode mappings)"

    # ---- STATIC: database/source file must contain all mappings ----
    local static_ok=1
    if [ ! -f "$hwdb_file" ]; then
        log_warn "  Custom keyboard hwdb not deployed at $hwdb_file (run './setup.sh --keyboard')"
        static_ok=0
    else
        local file_missing
        file_missing="$(kb_missing_in_text "$(cat "$hwdb_file" 2> /dev/null || true)" "$fixture")"
        if [ -n "$file_missing" ]; then
            log_warn "  static: $hwdb_file is missing expected mappings:"
            printf '%s\n' "$file_missing" | sed 's/^/    /' >&2
            static_ok=0
        else
            log_success "  static: $hwdb_file contains all $row_count mappings"
        fi
    fi

    # Probe both supported device families with CONCRETE modaliases (never a
    # wildcard-only query). This checks the DB contents, not the local device.
    local family label concrete query_out missing
    for family in dratini hp; do
        if [ "$family" = dratini ]; then
            label="Dratini"
            concrete="evdev:atkbd:dmi:bvnGoogle:bvrSTATIC:bdSTATIC:svnGoogle:pnDratini:pvrSTATIC"
        else
            label="HP Pro c640"
            concrete="evdev:atkbd:dmi:bvnHP:bvrSTATIC:bdSTATIC:svnHP:pnHP Pro c640 Chromebook:pvrSTATIC"
        fi
        query_out="$("$query_fn" "$concrete" || true)"
        missing="$(kb_missing_in_text "$query_out" "$fixture")"
        if [ -n "$missing" ]; then
            log_warn "  static: compiled hwdb is missing $label mappings:"
            printf '%s\n' "$missing" | sed 's/^/    /' >&2
            static_ok=0
        else
            log_success "  static: compiled hwdb has all $row_count mappings for $label"
        fi
    done

    # ---- DYNAMIC: an AT keyboard must exist and match the DB ----
    local atkbd_modalias event_node applied_rc
    if ! atkbd_modalias="$(kb_find_atkbd_modalias "$input_base" "$dmi_base")"; then
        log_warn "  no AT keyboard detected (no evdev:atkbd: device under $input_base): cannot verify live mapping"
        return 3
    fi
    event_node="$(kb_atkbd_event_node "$input_base" || true)"
    local dmi_modalias
    dmi_modalias="$(kb_compose_dmi_modalias "$dmi_base")"
    log_info "  DMI-composed modalias : $dmi_modalias"
    log_info "  AT keyboard modalias  : $atkbd_modalias"
    log_info "  AT keyboard event node: ${event_node:-<unknown>}"

    # Prefer the device's own evdev:atkbd: modalias when present; otherwise use
    # the DMI-composed one produced by kb_find_atkbd_modalias (same value as
    # udev's atkbd branch of 60-evdev.rules).
    local live_query_modalias="$atkbd_modalias"
    local live_out live_missing
    live_out="$("$query_fn" "$live_query_modalias" || true)"
    live_missing="$(kb_missing_in_text "$live_out" "$fixture")"
    if [ -n "$live_missing" ]; then
        log_warn "  device not matched / unknown scancode configuration: current AT keyboard modalias has no complete top-row mapping"
        printf '%s\n' "$live_missing" | sed 's/^/    /' >&2
        return 4
    fi
    log_success "  dynamic: current AT keyboard matched by hwdb (all $row_count mappings present)"

    applied_rc=0
    kb_check_kernel_applied "$fixture" "$event_node" || applied_rc=$?
    case "$applied_rc" in
        0) ;;
        1)
            log_warn "  dynamic: kernel application not confirmed; refusing to claim full success"
            return 5
            ;;
        2)
            log_warn "  dynamic: kernel application inconclusive; refusing to claim full success"
            return 7
            ;;
        *)
            log_warn "  dynamic: kernel application check failed (rc=$applied_rc); refusing to claim full success"
            return 5
            ;;
    esac

    if [ "$static_ok" -ne 1 ]; then
        log_warn "  static check incomplete; refusing to claim full success"
        return 6
    fi
    log_success "  $KB_SUCCESS_MARKER (static database + live AT-keyboard device)"
    return 0
}

# ---------------------------------------------------------------------------
# --self-test: run the exact verification code against stub sysfs trees and a
# stub hwdb query backend. Stub files live in a mktemp directory under
# ${TMPDIR:-/tmp} and are removed on exit; no developer-specific path needed.
# ---------------------------------------------------------------------------
run_self_test() {
    set +e
    local saved_log_file="$LOG_FILE"
    local root="" rc=0 scenario=0
    local sc key label d
    LOG_FILE=""
    root="$(mktemp -d "${TMPDIR:-/tmp}/detect-hwdb-selftest.XXXXXX")"
    if [ -z "$root" ] || [ ! -d "$root" ]; then
        log_error "self-test: could not create stub directory under ${TMPDIR:-/tmp}"
        LOG_FILE="$saved_log_file"
        set -e
        return 1
    fi

    local fixture="$KB_FIXTURE"
    local db="$root/hwdb.db"
    local out="$root/out.txt"

    # Build the stub hwdb from the SAME fixture so static checks stay in sync.
    {
        printf '%s\n' \
            'evdev:atkbd:dmi:bvn*:bvr*:bd*:svnGoogle*:pn*Dratini*:pvr*' \
            'evdev:atkbd:dmi:bvn*:bvr*:bd*:svnGoogle*:pn*dratini*:pvr*' \
            'evdev:atkbd:dmi:bvn*:bvr*:bd*:svnHP*:pnHP*Pro*c640*Chromebook*:pvr*' \
            'evdev:atkbd:dmi:bvn*:bvr*:bd*:svnHP*:pn*c640*:pvr*'
        while IFS=$'\t' read -r sc key label; do
            printf ' KEYBOARD_KEY_%s=%s\n' "$sc" "$key"
        done < <(kb_fixture_rows "$fixture")
    } > "$db"

    # Stub udevadm: report the applied properties from a generated file.
    local bindir="$root/bin" evdir="$root/dev/input"
    mkdir -p "$bindir" "$evdir"
    local udev_info="$root/udev-info.txt"
    : > "$udev_info"
    while IFS=$'\t' read -r sc key label; do
        printf 'E: KEYBOARD_KEY_%s=%s\n' "$sc" "$key" >> "$udev_info"
    done < <(kb_fixture_rows "$fixture")
    cat > "$bindir/udevadm" << EOF
#!/usr/bin/env bash
[ "\$1" = info ] || exit 0
cat "$udev_info"
EOF
    chmod +x "$bindir/udevadm"
    : > "$evdir/event2"

    # Result files for the delegated EVIOCGKEYCODE check (one per outcome).
    local keycode_ok="$root/keycode-ok"
    local keycode_mismatch="$root/keycode-mismatch"
    local keycode_inconclusive="$root/keycode-inconclusive"
    printf 'ok\n' > "$keycode_ok"
    printf 'mismatch\n' > "$keycode_mismatch"
    printf 'inconclusive\n' > "$keycode_inconclusive"

    KB_STUB_HWDB="$db"
    local query_stub="kb_hwdb_query_stub"

    # Optional fields let a scenario pin every DMI value used by
    # kb_compose_dmi_modalias, so an exact-string assertion catches a field
    # sourced from the wrong DMI file (a bd* wildcard alone would not).
    make_scenario() {
        local name="$1" bvn="$2" svn="$3" pn="$4" with_kbd="$5" modalias="${6:-}" \
            bios_date="${7:-01/01/2020}" bvr="${8:-TEST}" pvr="${9:-1.0}"
        local dir="$root/$name"
        mkdir -p "$dir/dmi" "$dir/input/input2/event2"
        printf '%s\n' "$bvn" > "$dir/dmi/bios_vendor"
        printf '%s\n' "$bvr" > "$dir/dmi/bios_version"
        printf '%s\n' "$bios_date" > "$dir/dmi/bios_date"
        printf '%s\n' "$svn" > "$dir/dmi/sys_vendor"
        printf '%s\n' "$pn" > "$dir/dmi/product_name"
        printf '%s\n' "$pvr" > "$dir/dmi/product_version"
        if [ "$with_kbd" = 1 ]; then
            printf 'AT Translated Set 2 keyboard\n' > "$dir/input/input2/name"
            if [ -n "$modalias" ]; then
                printf '%s\n' "$modalias" > "$dir/input/input2/modalias"
            else
                printf 'input:b0011v0001p0001eAB83-e0,1,4,k71,ram4,l0,1,2,sfw\n' > "$dir/input/input2/modalias"
            fi
        fi
        printf '%s\n' "$dir"
    }

    run_scenario() {
        local dir="$1"
        verify_keyboard_hwdb "$fixture" "$dir/dmi" "$dir/input" "$db" "$query_stub" > "$out" 2>&1
    }

    expect() {
        local should="$1" needle="$2" desc="$3"
        scenario=$((scenario + 1))
        if grep -qF -- "$needle" "$out"; then
            local found=1
        else
            local found=0
        fi
        if { [ "$should" = present ] && [ "$found" -eq 1 ]; } \
            || { [ "$should" = absent ] && [ "$found" -eq 0 ]; }; then
            printf '  PASS  %s\n' "$desc"
        else
            printf '  FAIL  %s (wanted %s: %s)\n' "$desc" "$should" "$needle"
            sed 's/^/        /' "$out"
            rc=1
        fi
    }

    # Exact full-line assertion for the composed modalias. A plain substring
    # match would still PASS if a suffix (:br0.0:efr0.0, :ZZLEAK, ...) leaked
    # after pvr, leaving a seven-field composition undetected. logger writes
    # ANSI-coloured "[LEVEL] " prefixes, so normalise those before comparing
    # the message body as a whole line.
    expect_line() {
        local line="$1" desc="$2" normalized="$root/normalized-out.txt"
        scenario=$((scenario + 1))
        sed -E $'s/\x1b\[[0-9;]*m//g; s/^\[[A-Z-]+\] //' "$out" > "$normalized"
        if grep -qxF -- "$line" "$normalized"; then
            printf '  PASS  %s\n' "$desc"
        else
            printf '  FAIL  %s (wanted exact line: %s)\n' "$desc" "$line"
            sed 's/^/        /' "$out"
            rc=1
        fi
    }

    export KB_UDEVADM_BIN="$bindir/udevadm" KB_EVENT_BASE="$evdir"
    export KB_KEYCODE_CHECK_FN="kb_keycode_check_stub" KB_STUB_KEYCODE_RESULT="$keycode_ok"

    printf 'self-test: keyboard hwdb verification\n'

    d="$(make_scenario dratini Google Google Dratini 1)"
    run_scenario "$d"
    expect present "$KB_SUCCESS_MARKER" "Dratini: device matched -> success"
    expect absent "cannot verify" "Dratini: AT keyboard detected"
    expect present "$evdir/event2" "Dratini: udevadm bound to AT keyboard event node"
    expect present "EVIOCGKEYCODE matches fixture" "Dratini: kernel map independently confirmed"
    expect present "not an independent kernel-map proof" "Dratini: udev properties reported as presence-only"

    d="$(make_scenario c640 HP 'HP' 'HP Pro c640 Chromebook' 1)"
    run_scenario "$d"
    expect present "$KB_SUCCESS_MARKER" "HP c640: device matched -> success"
    expect absent "device not matched" "HP c640: all 11 scancodes verified"
    expect present "EVIOCGKEYCODE matches fixture" "HP c640: kernel map independently confirmed"

    d="$(make_scenario hatch Google Google Hatch 1)"
    run_scenario "$d"
    expect present "device not matched" "other Hatch product: not matched"
    expect absent "$KB_SUCCESS_MARKER" "other Hatch product: no false success"

    d="$(make_scenario noatk Google Google Dratini 0)"
    run_scenario "$d"
    expect present "cannot verify" "no AT keyboard: cannot verify"
    expect absent "$KB_SUCCESS_MARKER" "no AT keyboard: no false success"

    # Signal (1) shortcut: an evdev:atkbd: modalias alone must not bypass the
    # hwdb lookup. A non-target DMI still yields "not matched", never success.
    d="$(make_scenario atkbd-other Foo Foo OtherBook 1 'evdev:atkbd:dmi:bvnFoo:bvrTEST:bd01/01/2020:svnFoo:pnOtherBook:pvr1.0')"
    run_scenario "$d"
    expect present "device not matched" "atkbd modalias + non-target DMI: not matched"
    expect absent "$KB_SUCCESS_MARKER" "atkbd modalias + non-target DMI: no false success"

    # DMI modalias composition must be asserted EXACTLY, not with a bd*
    # wildcard: a wildcard could span ':' and hide a field read from the wrong
    # DMI file. All six fields are pinned to distinct values here.
    local composed='evdev:atkbd:dmi:bvnGoogle:bvrBV-42:bd11/22/2026:svnGoogleCo:pnDratiniPro:pvrPV-9'
    d="$(make_scenario dmi-compose Google GoogleCo DratiniPro 1 '' 11/22/2026 BV-42 PV-9)"
    run_scenario "$d"
    expect_line "  DMI-composed modalias : $composed" "DMI modalias: exact six-field composition from DMI files"
    expect_line "  AT keyboard modalias  : $composed" "DMI modalias: composed value is the one queried against hwdb"
    expect present "$KB_SUCCESS_MARKER" "DMI modalias: composite query still matches the target hwdb entry"

    # Real firmware appends br/efr after pvr. The device modalias is used
    # verbatim for the live query, while the DMI-composed string must stay at
    # six fields and must not leak br/efr into the composition.
    d="$(make_scenario atkbd-br-efr Google Google Dratini 1 'evdev:atkbd:dmi:bvnGoogle:bvrTEST:bd01/01/2020:svnGoogle:pnDratini:pvr1.0:br0.0:efr0.0')"
    run_scenario "$d"
    expect present "AT keyboard modalias  : evdev:atkbd:dmi:bvnGoogle:bvrTEST:bd01/01/2020:svnGoogle:pnDratini:pvr1.0:br0.0:efr0.0" "br/efr modalias: device verbatim value used for the live query"
    expect_line "  DMI-composed modalias : evdev:atkbd:dmi:bvnGoogle:bvrTEST:bd01/01/2020:svnGoogle:pnDratini:pvr1.0" "br/efr modalias: DMI composition stays six fields"
    expect present "$KB_SUCCESS_MARKER" "br/efr modalias: still matches the target hwdb entry"

    # bd must come from bios_date (kernel dmi-id.c uses bvn/bvr/bd from the
    # BIOS vendor/version/date), not from a hardcoded value or another file.
    d="$(make_scenario dmi-bios-date Google Google Dratini 1 '' 12/31/2025 BY-77 PV-8)"
    run_scenario "$d"
    expect_line "  DMI-composed modalias : evdev:atkbd:dmi:bvnGoogle:bvrBY-77:bd12/31/2025:svnGoogle:pnDratini:pvrPV-8" "DMI modalias: bd/bvr/pvr track their DMI files"
    expect absent 'bd01/01/2020:svnGoogle:pnDratini:pvrPV-8' "DMI modalias: no stale default bios_date leaks into composition"

    # No udevadm -> explicit inconclusive (warn), never a full-success claim.
    KB_UDEVADM_BIN="$root/bin/no-such-udevadm"
    d="$(make_scenario dratini-no-udevadm Google Google Dratini 1)"
    run_scenario "$d"
    expect present "inconclusive" "udevadm unavailable: kernel check inconclusive"
    expect absent "$KB_SUCCESS_MARKER" "udevadm unavailable: no false success"
    KB_UDEVADM_BIN="$bindir/udevadm"

    # EVIOCGKEYCODE mismatch: udev properties look fine, but the kernel table
    # does not match the fixture -> warning, never the success marker.
    KB_STUB_KEYCODE_RESULT="$keycode_mismatch"
    d="$(make_scenario dratini-keycode-mismatch Google Google Dratini 1)"
    run_scenario "$d"
    expect present "MISMATCHES expected scancode->keycode table" "keycode mismatch: reported"
    expect absent "$KB_SUCCESS_MARKER" "keycode mismatch: no false success"
    KB_STUB_KEYCODE_RESULT="$keycode_ok"

    # EVIOCGKEYCODE inconclusive (permission/ioctl unavailable) -> warning,
    # never the success marker.
    KB_STUB_KEYCODE_RESULT="$keycode_inconclusive"
    d="$(make_scenario dratini-keycode-inconclusive Google Google Dratini 1)"
    run_scenario "$d"
    expect present "kernel map check inconclusive" "keycode check inconclusive: reported"
    expect absent "$KB_SUCCESS_MARKER" "keycode check inconclusive: no false success"
    KB_STUB_KEYCODE_RESULT="$keycode_ok"

    printf 'SELF-TEST=%s (%d assertions)\n' "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" "$scenario"

    unset KB_UDEVADM_BIN KB_EVENT_BASE KB_STUB_HWDB KB_KEYCODE_CHECK_FN KB_STUB_KEYCODE_RESULT
    LOG_FILE="$saved_log_file"
    rm -rf "$root"
    set -e
    return "$rc"
}

main() {
    case "${1:-}" in
        --self-test)
            run_self_test
            ;;
        '')
            run_diagnostic
            ;;
        *)
            log_error "Unknown option: $1 (supported: --self-test)"
            return 2
            ;;
    esac
}

main "$@"
