#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
# loginctl-contract-check.sh - read-only check of the loginctl schema the
# system-sleep hook relies on (PR #39 finding #1).
#
# On a running systemd host this checks, with the REAL loginctl binary:
#   * Session properties use `User=<numeric uid>`, never a `UID=` key
#     (UID= belongs to the User object / logind private state);
#   * the uid extracted by the SAME _session_prop function as the hook equals
#     `loginctl show-user <Name> -p UID --value`;
#   * show-seat ActiveSession values are alphanumeric session IDs.
# No S3 cycle and no writes to the repo or to /run/user.  A non-systemd host
# must print an explicit SKIP rather than silently "passing".
set -uo pipefail

if [ "$(cat /proc/1/comm 2> /dev/null || echo '')" != systemd ] \
    || ! command -v loginctl > /dev/null 2>&1; then
    printf 'SKIP: not a running systemd host with loginctl (PID 1=%s, loginctl=%s)\n' \
        "$(cat /proc/1/comm 2> /dev/null || echo '?')" \
        "$(command -v loginctl 2> /dev/null || echo absent)"
    exit 0
fi

# Identical to _session_prop in c640-kbd-backlight-sleep.sh. Values may
# contain '=', so slice from the original line instead of using -F=$N.
_session_prop() {
    printf '%s\n' "$1" | awk -F= -v key="$2" '$1 == key { print substr($0, length($1) + 2); exit }'
}

bad=0
sessions=0
with_user=0
compared=0
uid_keys=0
nonnumeric=0
seats=0
bad_seats=0

_ids="$(loginctl list-sessions --no-legend 2> /dev/null \
    | awk 'NF >= 1 && $1 != "SESSION" { print $1 }' 2> /dev/null || true)"

printf 'session ids: %s\n' "$(printf '%s' "$_ids" | tr '\n' ' ')"
while IFS= read -r id; do
    [ -n "$id" ] || continue
    sessions=$((sessions + 1))
    props="$(loginctl show-session "$id" 2> /dev/null || true)"
    # show-session suppresses empty properties: do NOT require Seat/State.
    if printf '%s\n' "$props" | grep -Eq '^UID='; then
        bad=$((bad + 1))
        uid_keys=$((uid_keys + 1))
        printf 'FAIL: session %s exposes a UID= key\n' "$id"
    fi
    user="$(_session_prop "$props" User)"
    name="$(_session_prop "$props" Name)"
    if [ -z "$user" ]; then
        printf '  session %-4s User=<missing> (suppressed or absent)\n' "$id"
        continue
    fi
    with_user=$((with_user + 1))
    case "$user" in
        '' | *[!0-9]*)
            bad=$((bad + 1))
            nonnumeric=$((nonnumeric + 1))
            printf 'FAIL: session %s User=<%s> is not numeric\n' "$id" "$user"
            continue
            ;;
    esac
    printf '  session %-4s User=%s Name=%s\n' "$id" "$user" "${name:-<missing>}"
    if [ -z "$name" ]; then
        bad=$((bad + 1))
        printf 'FAIL: session %s has no Name for show-user cross-check\n' "$id"
        continue
    fi
    show_user_uid="$(loginctl show-user "$name" -p UID --value 2> /dev/null || true)"
    if [ "$show_user_uid" != "$user" ]; then
        bad=$((bad + 1))
        printf 'FAIL: session %s User=%s but show-user %s -p UID --value = <%s>\n' \
            "$id" "$user" "$name" "$show_user_uid"
    else
        compared=$((compared + 1))
    fi
done <<< "$_ids"

_seats="$(loginctl list-seats --no-legend 2> /dev/null \
    | awk 'NF >= 1 && $1 != "SEAT" { print $1 }' 2> /dev/null || true)"
printf 'seats: %s\n' "$(printf '%s' "$_seats" | tr '\n' ' ')"
while IFS= read -r seat; do
    [ -n "$seat" ] || continue
    seats=$((seats + 1))
    seat_props="$(loginctl show-seat "$seat" -p ActiveSession 2> /dev/null || true)"
    active="$(_session_prop "$seat_props" ActiveSession)"
    case "$active" in
        '' | *[!A-Za-z0-9]*)
            bad=$((bad + 1))
            bad_seats=$((bad_seats + 1))
            printf 'FAIL: seat %s ActiveSession=<%s> is not an alphanumeric session id\n' \
                "$seat" "$active"
            ;;
        *)
            printf '  seat %-8s ActiveSession=%s\n' "$seat" "$active"
            ;;
    esac
done <<< "$_seats"

if [ "$sessions" -eq 0 ] || [ "$with_user" -eq 0 ] || [ "$compared" -eq 0 ] \
    || [ "$seats" -eq 0 ]; then
    bad=$((bad + 1))
    printf 'FAIL: contract could not be verified (sessions=%d with_User=%d compared=%d seats=%d)\n' \
        "$sessions" "$with_user" "$compared" "$seats"
fi

printf 'summary: sessions=%d with_User=%d compared=%d seats=%d UID_keys=%d nonnumeric_User=%d bad_seats=%d\n' \
    "$sessions" "$with_user" "$compared" "$seats" "$uid_keys" "$nonnumeric" "$bad_seats"
if [ "$bad" -ne 0 ]; then
    printf 'CONTRACT UNEXPECTED (%d failure(s))\n' "$bad"
    exit 1
fi
printf 'CONTRACT OK: loginctl uses numeric User= on Session, UID= only on User object; IDs are alphanumeric\n'
exit 0
