#!/bin/bash
# shellcheck disable=SC2034 # SILENT is consumed dynamically by common.sh.
# Title: CLAWHunter Watchdog
# Description: Silently assess a newly connected Pineapple client for a current OpenClaw gateway signature.
# Author: doublegate
# Version: 3.4.0
# Category: pineapple_client_connected
#
# Event contract:
#   Input  - Hak5 client MAC and SSID environment variables.
#   Work   - resolve only that client and probe current port 18789 in fast mode.
#   Output - one local alert log plus brief LED/haptic state; never audio/dialog.
#   Budget - no subnet discovery, picker, readiness, canvas, or legacy-port work.

readonly PAYLOAD_VERSION="3.4.0"
readonly OPENCLAW_DEFAULT_PORT=18789
readonly LOOT_BASE="/root/loot/clawhunter"
# SILENT suppresses shared feedback helpers. The two direct VIBRATE calls below
# are the alert payload's intentional, audio-free notification channel.
readonly SILENT=1

# Resolve common.sh in three supported layouts: self-contained Portal payload,
# installed suite (/root/payloads/lib), and repository checkout for development.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAWHUNTER_PAYLOAD_DIR="$SCRIPT_DIR"
export CLAWHUNTER_PAYLOAD_DIR
if [ -f "${SCRIPT_DIR}/common.sh" ]; then
    # Release/Portal layout: payload resources are self-contained.
    . "${SCRIPT_DIR}/common.sh"
elif [ -f "${SCRIPT_DIR}/../../../lib/common.sh" ]; then
    # Installed suite layout: /root/payloads/lib/common.sh.
    . "${SCRIPT_DIR}/../../../lib/common.sh"
elif [ -f "${SCRIPT_DIR}/../../../../lib/common.sh" ]; then
    # Repository layout: top-level lib/common.sh for development checks.
    . "${SCRIPT_DIR}/../../../../lib/common.sh"
else
    # Alert hooks have no operator present to acknowledge an installation dialog;
    # fail closed and silently rather than executing without validation helpers.
    exit 1
fi

mkdir -p "$LOOT_BASE"
# Hak5 supplies these exact variables for the pineapple_client_connected event.
# Never infer a target from an unrelated/global "last client" value.
ALERT_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOOT_BASE}/alert_${ALERT_TS}.log"
CLIENT_MAC="${_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS:-}"
CLIENT_SSID="${_ALERT_CLIENT_CONNECTED_SSID:-unknown}"
CLIENT_IP=""

# FIND_CLIENT_IP is authoritative when available. The ARP fallback matches the
# event MAC exactly and therefore cannot select another recently active client.
if [[ "$CLIENT_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
    if command -v FIND_CLIENT_IP >/dev/null 2>&1; then
        CLIENT_IP=$(FIND_CLIENT_IP "$CLIENT_MAC" 1 2>/dev/null | head -n 1)
    fi
    if ! is_valid_ipv4 "$CLIENT_IP"; then
        CLIENT_IP=$(awk -v mac="$CLIENT_MAC" 'NR>1 && tolower($4)==tolower(mac) {print $1; exit}' /proc/net/arp 2>/dev/null)
    fi
fi

# Alert payloads must exit quietly when DHCP/ARP has not resolved the new client;
# waiting or scanning an entire subnet would violate the event execution model.
if ! is_valid_ipv4 "$CLIENT_IP"; then
    printf '[%s] No IP for exact client MAC %s; probe skipped\n' "$(date '+%H:%M:%S')" "${CLIENT_MAC:-unset}" > "$LOG_FILE"
    exit 0
fi

{
    # Capture event identity before probing. No gateway response data can alter
    # which client appears in the audit record.
    printf 'CLAWHunter v%s - client-connected watchdog\n' "$PAYLOAD_VERSION"
    printf 'Timestamp : %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Client IP : %s\n' "$CLIENT_IP"
    printf 'Client MAC: %s\n' "$CLIENT_MAC"
    printf 'SSID      : %s\n\n' "$CLIENT_SSID"
} > "$LOG_FILE"

# Fast mode uses one-second operations and omits readiness/canvas probes. Only
# the current default port is attempted so worst-case execution remains bounded
# near four seconds; interactive/recon modes retain optional legacy-port scans.
PROBE_FAST=1
PROBE_WS_TIMEOUT=1
export PROBE_FAST PROBE_WS_TIMEOUT
start_seconds=$SECONDS
result_port=""
if probe_openclaw "$CLIENT_IP" "$OPENCLAW_DEFAULT_PORT"; then
    # Persist the classifier's full score/evidence contract, not merely a binary
    # found flag, so weak signals can be reviewed after the transient event.
    printf '[%s] %s:%s %s\n' \
        "$PROBE_CLASS" "$CLIENT_IP" "$OPENCLAW_DEFAULT_PORT" "$PROBE_DETAIL" >> "$LOG_FILE"
    [ "$PROBE_CONFIRMED" -eq 1 ] && result_port="$OPENCLAW_DEFAULT_PORT"
fi

# Elapsed time makes the short alert-budget assumption observable on hardware.
elapsed=$((SECONDS - start_seconds))
printf 'Elapsed: %ss\n' "$elapsed" >> "$LOG_FILE"

# Alert mode is audio-silent by contract. Haptics distinguish a confirmed find
# from weak candidate evidence without opening a blocking dialog.
if [ -n "$result_port" ]; then
    # Direct haptics intentionally bypass SILENT while still avoiding a
    # ringtone. VIBRATE consumes an RTTTL pattern, not a numeric duration.
    led_found
    VIBRATE "clawalert:d=4,o=5,b=180:c,c"
    led_off
elif [ "${PROBE_CANDIDATE:-0}" -eq 1 ]; then
    led_candidate
    VIBRATE "clawhint:d=16,o=5,b=240:c"
    led_off
fi

exit 0
