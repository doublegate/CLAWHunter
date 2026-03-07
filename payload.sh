#!/bin/bash
# =============================================================================
# CLAWHunter — OpenClaw Instance Discovery Payload
# For the Hak5 WiFi Pineapple Pager (480×222 px, 16-bit color, 221 PPI)
# =============================================================================
#
# PURPOSE:
#   Scans the local LAN (or user-specified subnet) for live OpenClaw gateway
#   instances by probing port 18790 (default) with optional wide range sweep.
#   Confirms discoveries via HTTP fingerprinting. Provides full hardware
#   integration: color display, LED indicators, haptic feedback, audio cues,
#   and an interactive post-scan results browser.
#
# DEPLOY:
#   /root/payloads/user/reconnaissance/clawhunter/payload.sh
#
# CONTROLS:
#   Standard picker navigation (UP/DOWN/LEFT/RIGHT/B)
#   B button — abort scan in progress
#   Post-scan browser: UP/DOWN=navigate, B=exit
#
# LOG OUTPUT:
#   /root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log
#
# VERSION: 2.0.0
# AUTHOR:  doublegate (doublegate)
# REPO:    https://github.com/doublegate/CLAWHunter
# =============================================================================

# ── Constants ─────────────────────────────────────────────────────────────────

OPENCLAW_DEFAULT_PORT=18790
OPENCLAW_RANGE_LOW=18780
OPENCLAW_RANGE_HIGH=18800
LOOT_BASE="/root/loot/clawhunter"
PAYLOAD_VERSION="2.0.0"

# ── State ─────────────────────────────────────────────────────────────────────

FOUND_COUNT=0
HOSTS_SCANNED=0
ABORT=0
FOUND_HOSTS=()      # array of "IP:PORT" strings for results browser
SCAN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE=""

mkdir -p "$LOOT_BASE"

# ── Cleanup trap ──────────────────────────────────────────────────────────────

cleanup() {
    led_off
    [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] && {
        echo "" >> "$LOG_FILE"
        echo "[$(date '+%H:%M:%S')] Payload exited (cleanup trap)" >> "$LOG_FILE"
    }
}
trap cleanup EXIT INT TERM

# ── LED control ───────────────────────────────────────────────────────────────
# Uses the Pager's RGB LED array via HAK5_API_POST.
# 4 LEDs, each RGB as [R,G,B] booleans. onms/offms = blink timing.

. /lib/hak5/commands.sh 2>/dev/null || true

led_post() {
    HAK5_API_POST "system/led" "$1" >/dev/null 2>&1 || true
}

led_off() {
    led_post '{"color":"custom","raw_pattern":[{"onms":100,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}

led_scanning() {
    # Slow blue pulse — scanning in progress
    led_post '{"color":"custom","raw_pattern":[{"onms":600,"offms":400,"next":false,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,true],"4":[false,false,true]}}]}'
}

led_found() {
    # Fast green flash — confirmed discovery
    led_post '{"color":"custom","raw_pattern":[{"onms":150,"offms":150,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}

led_candidate() {
    # Slow blue/green alternate — candidate (unconfirmed)
    led_post '{"color":"custom","raw_pattern":[{"onms":300,"offms":200,"next":true,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,true],"4":[false,false,true]}},{"onms":300,"offms":200,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}

led_error() {
    # Solid red — error state
    led_post '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[true,false,false],"2":[true,false,false],"3":[true,false,false],"4":[true,false,false]}}]}'
}

led_complete_ok() {
    # Slow green pulse — scan done, found something
    led_post '{"color":"custom","raw_pattern":[{"onms":800,"offms":400,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}

led_complete_none() {
    # Slow blue pulse — scan done, nothing found
    led_post '{"color":"custom","raw_pattern":[{"onms":800,"offms":400,"next":false,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,true],"4":[false,false,true]}}]}'
}

# ── Audio (RTTTL) ─────────────────────────────────────────────────────────────
# RINGTONE uses RTTTL format: "Name:d=dur,o=oct,b=bpm:notes"
# Run in background (&) to not block execution.

ringtone_start() {
    RINGTONE "start:d=8,o=5,b=180:c,e,g" &
}

ringtone_found() {
    # Ascending alert — confirmed OpenClaw found
    RINGTONE "found:d=8,o=5,b=220:e,e,g,g,b,b" &
}

ringtone_candidate() {
    # Single short beep — port open, unconfirmed
    RINGTONE "ping:d=16,o=5,b=200:g" &
}

ringtone_complete_ok() {
    # Victory jingle
    RINGTONE "win:d=4,o=5,b=160:c,e,g,c6" &
}

ringtone_complete_none() {
    # Descending close
    RINGTONE "none:d=4,o=5,b=140:g,e,c" &
}

ringtone_abort() {
    RINGTONE "abort:d=4,o=4,b=120:g,e" &
}

# ── Logging helpers ───────────────────────────────────────────────────────────

log_entry() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

log_found() {
    echo "[FOUND]     $1" >> "$LOG_FILE"
}

log_candidate() {
    echo "[CANDIDATE] $1" >> "$LOG_FILE"
}

log_section() {
    echo "" >> "$LOG_FILE"
    echo "── $1 ──" >> "$LOG_FILE"
}

# ── Banner ────────────────────────────────────────────────────────────────────

LOG blue "  ✦ CLAWHunter v${PAYLOAD_VERSION}"
LOG "  OpenClaw Discovery"
LOG blue "  WiFi Pineapple Pager"
sleep 1
ringtone_start
sleep 1

# ── Auto-detect local subnet ──────────────────────────────────────────────────

LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP=$(ip addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' \
               | awk '{print $2}' | cut -d/ -f1 | head -1)
fi

DEFAULT_SUBNET="192.168.1"
if [ -n "$LOCAL_IP" ]; then
    DEFAULT_SUBNET=$(echo "$LOCAL_IP" | cut -d. -f1-3)
fi

LOG blue "Local: ${LOCAL_IP:-unknown}"
sleep 1

# ── User: target subnet ───────────────────────────────────────────────────────

SUBNET=$(IP_PICKER "Target Subnet" "$DEFAULT_SUBNET")
case $? in
    $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
        LOG red "Cancelled"
        exit $DUCKYSCRIPT_CANCELLED
        ;;
esac

# ── User: primary port ────────────────────────────────────────────────────────

TARGET_PORT=$(NUMBER_PICKER "OpenClaw Port" $OPENCLAW_DEFAULT_PORT)
case $? in
    $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
        LOG red "Cancelled"
        exit $DUCKYSCRIPT_CANCELLED
        ;;
esac

# ── User: wide port range ─────────────────────────────────────────────────────

resp=$(CONFIRMATION_DIALOG "Port range scan?" "Sweep ${OPENCLAW_RANGE_LOW}-${OPENCLAW_RANGE_HIGH} instead of port ${TARGET_PORT} only")
WIDE_SCAN=0
case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED) WIDE_SCAN=1 ;;
esac

# ── User: host range ──────────────────────────────────────────────────────────

resp=$(CONFIRMATION_DIALOG "Full /24 scan?" "254 hosts — takes ~90s. NO = quick scan (.1-.50)")
case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED)
        HOST_START=1
        HOST_END=254
        ;;
    *)
        HOST_START=1
        HOST_END=50
        ;;
esac

# ── Build port list ───────────────────────────────────────────────────────────

if [ $WIDE_SCAN -eq 1 ]; then
    PORTS=$(seq $OPENCLAW_RANGE_LOW $OPENCLAW_RANGE_HIGH)
    PORT_DESC="${OPENCLAW_RANGE_LOW}-${OPENCLAW_RANGE_HIGH}"
else
    PORTS="$TARGET_PORT"
    PORT_DESC="$TARGET_PORT"
fi

# ── Write log header ──────────────────────────────────────────────────────────

LOG_FILE="$LOOT_BASE/scan_${SCAN_ID}.log"

{
    echo "=============================================="
    echo "  CLAWHunter v${PAYLOAD_VERSION} — OpenClaw Discovery"
    echo "  Hak5 WiFi Pineapple Pager"
    echo "=============================================="
    echo "Scan ID     : $SCAN_ID"
    echo "Date/Time   : $(date)"
    echo "Scanner IP  : ${LOCAL_IP:-unknown}"
    echo "Subnet      : ${SUBNET}.${HOST_START}-${HOST_END}"
    echo "Port(s)     : $PORT_DESC"
    echo "Wide range  : $([ $WIDE_SCAN -eq 1 ] && echo YES || echo NO)"
    echo "=============================================="
    echo ""
} > "$LOG_FILE"

# ── Scan start ────────────────────────────────────────────────────────────────

RANGE_DESC="${SUBNET}.${HOST_START}-${HOST_END}"
LOG green "Scanning: $RANGE_DESC"
LOG blue "Ports: $PORT_DESC"
sleep 1

led_scanning

SPINNER_ID=$(START_SPINNER "Scanning ${RANGE_DESC}...")

log_section "HOST SCAN"

# ── OpenClaw fingerprint probe ────────────────────────────────────────────────
#
# Stage 1: nc TCP handshake (fast, low cost)
# Stage 2: curl HTTP probe — check body/headers for OpenClaw identifiers,
#           or HTTP 400/401/403 on the exact target port (token-gated gateway)
#
# Sets: PROBE_CONFIRMED, PROBE_CANDIDATE, PROBE_HTTP_CODE, PROBE_BANNER

probe_openclaw() {
    local ip="$1"
    local port="$2"
    PROBE_CONFIRMED=0
    PROBE_CANDIDATE=0
    PROBE_HTTP_CODE=""
    PROBE_BANNER=""

    # Stage 1: fast TCP check
    nc -z -w 1 "$ip" "$port" 2>/dev/null || return 1

    # Stage 2: HTTP fingerprint
    local response http_code body body_lower
    response=$(curl -s \
        --max-time 3 \
        --connect-timeout 2 \
        -w "\n__CODE__:%{http_code}" \
        -H "User-Agent: CLAWHunter/${PAYLOAD_VERSION}" \
        "http://${ip}:${port}/" 2>/dev/null)

    http_code=$(echo "$response" | grep '__CODE__:' | cut -d: -f2)
    body=$(echo "$response" | grep -v '__CODE__:')
    body_lower=$(echo "$body" | tr '[:upper:]' '[:lower:]')

    if [ -n "$http_code" ]; then
        PROBE_CANDIDATE=1
        PROBE_HTTP_CODE="$http_code"

        # Explicit keyword confirmation
        if echo "$body_lower" | grep -qE 'openclaw|clawd|gateway'; then
            PROBE_CONFIRMED=1
            PROBE_BANNER=$(echo "$body" | grep -ioE 'openclaw[^"<]*|clawd[^"<]*' | head -1 | cut -c1-50)
            [ -z "$PROBE_BANNER" ] && PROBE_BANNER="keyword match in response body"
            return 0
        fi

        # Port-specific auth rejection — strong signal on the default port
        if [ "$port" -eq "$TARGET_PORT" ] && \
           echo "$http_code" | grep -qE '^(400|401|403)$'; then
            PROBE_CONFIRMED=1
            PROBE_BANNER="HTTP ${http_code} — token-gated gateway"
            return 0
        fi
    fi

    return 0
}

# ── Main scan loop ─────────────────────────────────────────────────────────────

for i in $(seq $HOST_START $HOST_END); do
    # Non-blocking B-button abort check via WAIT_FOR_INPUT with 0 timeout
    btn=$(timeout 0.05 sh -c 'WAIT_FOR_INPUT 2>/dev/null' 2>/dev/null || true)
    if [ "$btn" = "B" ]; then
        ABORT=1
        break
    fi

    IP="${SUBNET}.${i}"
    HOSTS_SCANNED=$((HOSTS_SCANNED + 1))

    ping -c 1 -W 1 "$IP" &>/dev/null || continue

    # Live host — update display
    STOP_SPINNER "$SPINNER_ID"
    LOG blue "Live: $IP"
    log_entry "Host alive: $IP"
    SPINNER_ID=$(START_SPINNER "Probing $IP...")

    HOST_HAD_FIND=0

    for PORT in $PORTS; do
        probe_openclaw "$IP" "$PORT" || continue

        if [ $PROBE_CONFIRMED -eq 1 ]; then
            STOP_SPINNER "$SPINNER_ID"

            # ── Confirmed find: full hardware alert ───────────────────────────
            led_found
            ringtone_found
            VIBRATE 300

            LOG green "✦ FOUND: ${IP}:${PORT}"
            LOG green "  ${PROBE_BANNER}"
            log_found "${IP}:${PORT} | HTTP ${PROBE_HTTP_CODE} | ${PROBE_BANNER}"

            FOUND_HOSTS+=("${IP}:${PORT}")
            FOUND_COUNT=$((FOUND_COUNT + 1))
            HOST_HAD_FIND=1

            # ── Pause on find (user-requested) ────────────────────────────────
            ALERT "✦ OpenClaw Found!\n${IP}:${PORT}\n${PROBE_BANNER}\nPress any key to continue scan"

            led_scanning
            SPINNER_ID=$(START_SPINNER "Scanning...")

        elif [ $PROBE_CANDIDATE -eq 1 ]; then
            STOP_SPINNER "$SPINNER_ID"
            led_candidate
            ringtone_candidate

            LOG blue "? Open: ${IP}:${PORT} (HTTP ${PROBE_HTTP_CODE})"
            log_candidate "${IP}:${PORT} | HTTP ${PROBE_HTTP_CODE} (unconfirmed)"

            sleep 1
            led_scanning
            SPINNER_ID=$(START_SPINNER "Scanning...")
        fi
    done

    if [ $HOST_HAD_FIND -eq 1 ]; then
        log_entry "  └─ OpenClaw confirmed on $IP"
    fi
done

STOP_SPINNER "$SPINNER_ID"

# ── Abort handling ────────────────────────────────────────────────────────────

if [ $ABORT -eq 1 ]; then
    ringtone_abort
    LOG red "Scan aborted by user"
    log_entry "SCAN ABORTED BY USER"
fi

# ── Log footer ────────────────────────────────────────────────────────────────

{
    echo ""
    echo "=============================================="
    echo "SUMMARY"
    echo "  Hosts scanned  : $HOSTS_SCANNED"
    echo "  OpenClaw found : $FOUND_COUNT"
    echo "  Elapsed        : ${SECONDS}s"
    echo "  Status         : $([ $ABORT -eq 1 ] && echo 'ABORTED' || echo 'COMPLETE')"
    if [ $FOUND_COUNT -gt 0 ]; then
        echo ""
        echo "  DISCOVERED INSTANCES:"
        for h in "${FOUND_HOSTS[@]}"; do
            echo "    ✦ $h"
        done
    fi
    echo "=============================================="
    echo "  Log: $LOG_FILE"
    echo "=============================================="
} >> "$LOG_FILE"

# ── Results summary screen ────────────────────────────────────────────────────

if [ $FOUND_COUNT -gt 0 ]; then
    led_complete_ok
    ringtone_complete_ok
    VIBRATE 500
    LOG green "Scan Complete!"
    LOG green "Found: $FOUND_COUNT OpenClaw"
    LOG blue  "Scanned: $HOSTS_SCANNED hosts"
else
    led_complete_none
    ringtone_complete_none
    LOG blue "Scan Complete"
    LOG red  "No instances found"
    LOG blue "Scanned: $HOSTS_SCANNED hosts"
fi

sleep 1

# ── Interactive results browser ───────────────────────────────────────────────
# Allows navigating discovered hosts one at a time with UP/DOWN,
# then exit with B. Only shown if at least one host was found.

if [ $FOUND_COUNT -gt 0 ]; then
    PROMPT "Press any key to browse results"

    idx=0
    while true; do
        host="${FOUND_HOSTS[$idx]}"
        host_ip="${host%%:*}"
        host_port="${host##*:}"

        LOG green "Results ${idx+1}/${FOUND_COUNT}"
        LOG green "  $host_ip"
        LOG blue  "  port: $host_port"
        LOG       "  UP/DOWN=nav  B=exit"

        btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            UP)
                if [ $idx -gt 0 ]; then
                    idx=$((idx - 1))
                fi
                ;;
            DOWN)
                if [ $idx -lt $((FOUND_COUNT - 1)) ]; then
                    idx=$((idx + 1))
                fi
                ;;
            B | LEFT)
                break
                ;;
        esac
    done
fi

# ── Final screen ──────────────────────────────────────────────────────────────

LOG blue "Log saved:"
LOG      "$LOG_FILE"
sleep 1

PROMPT "Done — press any key to exit"

led_off
exit 0
