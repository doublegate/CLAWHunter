#!/bin/bash
# =============================================================================
# CLAWHunter — Alert Payload Variant (Watchdog)
# For the Hak5 WiFi Pineapple Pager — Fires on client connect to Pager AP
# =============================================================================
#
# PAYLOAD_VERSION: 3.1.0
# AUTHOR:  doublegate
# REPO:    https://github.com/doublegate/CLAWHunter
#
# DESCRIPTION:
#   Lightweight alert-triggered variant. Fires automatically when a client
#   connects to the Pager's access point. Probes the connecting client IP
#   for an OpenClaw gateway signature — no subnet sweep, one host only.
#   Must complete in <5 seconds (alert payloads run repeatedly per event).
#   Silent by default — no audio that would reveal the device.
#
# ALERT CONTEXT VARIABLES (set by Pager alert system):
#   CLIENT_IP    Connecting client's IP address
#   CLIENT_MAC   Connecting client's MAC address (optional)
#
# DEPLOY:
#   scp -r payloads/alert/clawhunter-watchdog lib \
#       root@pineapple.lan:/root/payloads/alert/
#
# LOG OUTPUT:
#   /root/loot/clawhunter/alert_YYYYMMDD_HHMMSS.log
# =============================================================================

readonly PAYLOAD_VERSION="3.1.0"
readonly OPENCLAW_DEFAULT_PORT=18790
readonly LOOT_BASE="/root/loot/clawhunter"

# Alert variant: always silent — no audio that reveals the device
readonly SILENT=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../lib/common.sh
. "${SCRIPT_DIR}/../../lib/common.sh"

mkdir -p "$LOOT_BASE"

# ── Timestamp ─────────────────────────────────────────────────────────────────
readonly ALERT_TS="$(date +%Y%m%d_%H%M%S)"
readonly LOG_FILE="${LOOT_BASE}/alert_${ALERT_TS}.log"

# ── Validate client IP ────────────────────────────────────────────────────────
CLIENT_IP="${CLIENT_IP:-}"
CLIENT_MAC="${CLIENT_MAC:-unknown}"

if [ -z "$CLIENT_IP" ]; then
    # Fallback: try to get most recent ARP entry (newest connected client)
    CLIENT_IP=$(awk 'NR>1 && $4 != "00:00:00:00:00:00" { print $1 }' \
        /proc/net/arp 2>/dev/null | tail -1)
fi

if [ -z "$CLIENT_IP" ]; then
    printf "[%s] ALERT: no CLIENT_IP — skipping probe\n" \
        "$(date '+%H:%M:%S')" > "$LOG_FILE"
    exit 0
fi

# ── Log header ────────────────────────────────────────────────────────────────
{
    printf "================================================\n"
    printf "  CLAWHunter v%s — Alert Variant\n" "$PAYLOAD_VERSION"
    printf "  Hak5 WiFi Pineapple Pager\n"
    printf "================================================\n"
    printf "Alert TS  : %s\n" "$ALERT_TS"
    printf "Date/Time : %s\n" "$(date)"
    printf "Client IP : %s\n" "$CLIENT_IP"
    printf "Client MAC: %s\n" "$CLIENT_MAC"
    printf "================================================\n\n"
} > "$LOG_FILE"

# ── Single-host probe (must finish in <5s total) ───────────────────────────────
PROBE_CONFIRMED=0
PROBE_CANDIDATE=0
PROBE_HTTP_CODE=""
PROBE_BANNER=""
PROBE_SCHEME=""
PROBE_DETAIL=""
PROBE_WS_CONFIRMED=0
PROBE_CANVAS_CONFIRMED=0

# Primary port only — no sweep, no extended ports (speed constraint)
printf "[%s] Probing %s:%d\n" "$(date '+%H:%M:%S')" \
    "$CLIENT_IP" "$OPENCLAW_DEFAULT_PORT" >> "$LOG_FILE"

# Stage 1: TCP check (1s timeout)
if nc -z -w 1 "$CLIENT_IP" "$OPENCLAW_DEFAULT_PORT" 2>/dev/null; then

    # Stage 2: HTTP probe (2s timeout max — tight budget)
    response=$(curl -s \
        --max-time 2 --connect-timeout 1 -k \
        -w "\n__CODE__:%{http_code}" \
        -H "User-Agent: CLAWHunter/${PAYLOAD_VERSION}" \
        "http://${CLIENT_IP}:${OPENCLAW_DEFAULT_PORT}/" 2>/dev/null)

    http_code=$(echo "$response" | grep '__CODE__:' | cut -d: -f2)
    body=$(echo "$response" | grep -v '__CODE__:')
    body_lower=$(echo "$body" | tr '[:upper:]' '[:lower:]')

    if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
        PROBE_CANDIDATE=1
        PROBE_HTTP_CODE="$http_code"
        PROBE_SCHEME="http"

        if echo "$body_lower" | grep -qE 'openclaw|clawd|gateway'; then
            PROBE_CONFIRMED=1
            PROBE_BANNER=$(echo "$body" \
                | grep -ioE '(openclaw|clawd)[^"<]{0,50}' | head -1 | tr -d '\n')
            [ -z "$PROBE_BANNER" ] && PROBE_BANNER="keyword match in body"

        elif echo "$http_code" | grep -qE '^(400|401|403)$'; then
            PROBE_CONFIRMED=1
            PROBE_BANNER="HTTP ${http_code} — token-gated gateway"
        fi
    fi

    # A1: WebSocket probe (only if initial HTTP confirmed or 401-gated)
    if [ $PROBE_CONFIRMED -eq 1 ]; then
        if ws_probe "$CLIENT_IP" "$OPENCLAW_DEFAULT_PORT"; then
            PROBE_WS_CONFIRMED=1
            printf "[%s] A1: WebSocket upgrade accepted\n" \
                "$(date '+%H:%M:%S')" >> "$LOG_FILE"
        fi
    fi
fi

# ── Log result ────────────────────────────────────────────────────────────────
{
    printf "\n── PROBE RESULT ──\n"
    if [ $PROBE_CONFIRMED -eq 1 ]; then
        printf "[FOUND]     %s:%d | %s | %s\n" \
            "$CLIENT_IP" "$OPENCLAW_DEFAULT_PORT" "$PROBE_SCHEME" "$PROBE_BANNER"
        printf "            WS: %s | Canvas: %s\n" \
            "$([ $PROBE_WS_CONFIRMED -eq 1 ] && echo confirmed || echo no)" \
            "$([ $PROBE_CANVAS_CONFIRMED -eq 1 ] && echo confirmed || echo no)"
    elif [ $PROBE_CANDIDATE -eq 1 ]; then
        printf "[CANDIDATE] %s:%d | HTTP %s\n" \
            "$CLIENT_IP" "$OPENCLAW_DEFAULT_PORT" "$PROBE_HTTP_CODE"
    else
        printf "[NONE]      %s — no OpenClaw signature detected\n" "$CLIENT_IP"
    fi
    printf "\n================================================\n"
    printf "  Status: %s\n" \
        "$([ $PROBE_CONFIRMED -eq 1 ] && echo FOUND || \
           [ $PROBE_CANDIDATE -eq 1 ] && echo CANDIDATE || echo NONE)"
    printf "  Log: %s\n" "$LOG_FILE"
    printf "================================================\n"
} >> "$LOG_FILE"

# ── Hardware feedback (only on confirmed find — vibrate, no audio) ─────────────
if [ $PROBE_CONFIRMED -eq 1 ]; then
    led_found
    # Strong vibrate — haptic-only (SILENT is set, no audio)
    VIBRATE 500
    sleep 0.5
    VIBRATE 500
    led_off
elif [ $PROBE_CANDIDATE -eq 1 ]; then
    led_candidate
    VIBRATE 200
    led_off
fi

exit 0
