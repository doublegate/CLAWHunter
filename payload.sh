#!/bin/bash
# =============================================================================
# CLAWHunter — OpenClaw Instance Discovery Payload
# For the Hak5 WiFi Pineapple Pager
# =============================================================================
#
# PURPOSE:
#   Scans the local LAN (or a user-specified subnet) for live OpenClaw gateway
#   instances by probing the default port (18790) and optional wide range.
#   Confirms discovered ports are actually OpenClaw via HTTP fingerprinting.
#   Displays live results on the Pager display, logs all findings to loot.
#
# DEPLOY:
#   Copy this file to /root/payloads/user/reconnaissance/clawhunter/payload.sh
#   on the WiFi Pineapple Pager.
#
# CONTROLS (during scan):
#   B button — abort scan in progress
#
# NAVIGATION:
#   Standard Pager picker navigation for subnet, port, and options.
#
# LOG OUTPUT:
#   /root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log
#
# OPENCLAW PORTS:
#   Default: 18790
#   Wide range: 18780–18800 (user selectable)
#   Custom: user can specify any port via NUMBER_PICKER
#
# FINGERPRINTING:
#   Port open + HTTP 400/401/403 on port 18790 = likely OpenClaw gateway
#   Response body containing "openclaw" or "gateway" = confirmed
#   Any HTTP response on the OpenClaw port range = flagged as candidate
#
# DEPENDENCIES:
#   nmap, curl, nc (all present on Pager firmware)
#
# VERSION: 1.0.0
# AUTHOR:  doublegate (doublegate)
# REPO:    https://github.com/doublegate/CLAWHunter
# =============================================================================

# ── Constants ─────────────────────────────────────────────────────────────────

OPENCLAW_DEFAULT_PORT=18790
OPENCLAW_RANGE_LOW=18780
OPENCLAW_RANGE_HIGH=18800
LOOT_BASE="/root/loot/clawhunter"
PAYLOAD_VERSION="1.0.0"

# ── Setup loot directory ──────────────────────────────────────────────────────

mkdir -p "$LOOT_BASE"
SCAN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOOT_BASE/scan_${SCAN_ID}.log"
FOUND_COUNT=0
HOSTS_SCANNED=0
ABORT=0

# ── Logging helpers ───────────────────────────────────────────────────────────

log_entry() {
    # Append a timestamped entry to the log file
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

log_found() {
    # Format: [FOUND] IP:PORT | HTTP_CODE | banner snippet
    echo "[FOUND] $1" >> "$LOG_FILE"
    FOUND_COUNT=$((FOUND_COUNT + 1))
}

log_candidate() {
    # Port open but unconfirmed as OpenClaw
    echo "[CANDIDATE] $1" >> "$LOG_FILE"
}

# ── Banner ────────────────────────────────────────────────────────────────────

LOG cyan "  ✦ CLAWHunter v${PAYLOAD_VERSION}"
LOG "  OpenClaw Discovery"
LOG dim "  WiFi Pineapple Pager"
sleep 2

# ── Auto-detect local subnet ──────────────────────────────────────────────────

LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
if [ -z "$LOCAL_IP" ]; then
    # Fallback: grab first non-loopback address
    LOCAL_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)
fi

DEFAULT_SUBNET="192.168.1"
if [ -n "$LOCAL_IP" ]; then
    DEFAULT_SUBNET=$(echo "$LOCAL_IP" | cut -d. -f1-3)
fi

LOG dim "Local IP: ${LOCAL_IP:-unknown}"
LOG dim "Default subnet: ${DEFAULT_SUBNET}.0/24"
sleep 1

# ── User: select target subnet ────────────────────────────────────────────────

IP_PICKER "Target Subnet" "$DEFAULT_SUBNET"
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG red "Cancelled"
        exit $DUCKYSCRIPT_CANCELLED
        ;;
esac
SUBNET="$DUCKYSCRIPT_RESULT"

# ── User: select primary port ─────────────────────────────────────────────────

NUMBER_PICKER "OpenClaw Port" $OPENCLAW_DEFAULT_PORT
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG red "Cancelled"
        exit $DUCKYSCRIPT_CANCELLED
        ;;
esac
TARGET_PORT="$DUCKYSCRIPT_RESULT"

# ── User: wide range scan option ──────────────────────────────────────────────

CONFIRMATION_DIALOG "Scan port range? (${OPENCLAW_RANGE_LOW}-${OPENCLAW_RANGE_HIGH})"
WIDE_SCAN=0
if [ $? -eq $DUCKYSCRIPT_USER_CONFIRMED ]; then
    WIDE_SCAN=1
fi

# ── User: host range (full /24 vs custom) ─────────────────────────────────────

CONFIRMATION_DIALOG "Full scan? (/24 = 254 hosts)"
if [ $? -eq $DUCKYSCRIPT_USER_DENIED ]; then
    # Narrow scan: .1–.50 (quick, covers most routers + a few clients)
    HOST_START=1
    HOST_END=50
    LOG yellow "Quick scan (.1-.50)"
else
    HOST_START=1
    HOST_END=254
    LOG yellow "Full scan (.1-.254)"
fi
sleep 1

# ── Write log header ──────────────────────────────────────────────────────────

{
    echo "=================================================="
    echo "  CLAWHunter v${PAYLOAD_VERSION} — OpenClaw Discovery"
    echo "  Hak5 WiFi Pineapple Pager"
    echo "=================================================="
    echo "Scan ID    : $SCAN_ID"
    echo "Date/Time  : $(date)"
    echo "Subnet     : ${SUBNET}.${HOST_START}-${HOST_END}"
    echo "Primary Port: $TARGET_PORT"
    echo "Wide Range  : $([ $WIDE_SCAN -eq 1 ] && echo 'YES ('${OPENCLAW_RANGE_LOW}'-'${OPENCLAW_RANGE_HIGH}')' || echo 'NO')"
    echo "=================================================="
    echo ""
} > "$LOG_FILE"

# ── Build port list ───────────────────────────────────────────────────────────

if [ $WIDE_SCAN -eq 1 ]; then
    # Include primary port + full range (deduped)
    PORTS=$(seq $OPENCLAW_RANGE_LOW $OPENCLAW_RANGE_HIGH)
else
    PORTS="$TARGET_PORT"
fi

# ── Fingerprinting function ───────────────────────────────────────────────────

# Probe a single IP:PORT for OpenClaw.
# Sets PROBE_CONFIRMED=1 if confirmed OpenClaw, PROBE_CANDIDATE=1 if port open
# but unconfirmed, PROBE_HTTP_CODE to the HTTP status code.
probe_openclaw() {
    local ip="$1"
    local port="$2"
    PROBE_CONFIRMED=0
    PROBE_CANDIDATE=0
    PROBE_HTTP_CODE=""
    PROBE_BANNER=""

    # Quick TCP port check first (faster than curl timeout)
    if ! nc -z -w 1 "$ip" "$port" 2>/dev/null; then
        return 1   # Port closed — no point continuing
    fi

    # Port is open — attempt HTTP fingerprint
    local response
    response=$(curl -s \
        --max-time 3 \
        --connect-timeout 2 \
        -w "\n__HTTP_CODE__:%{http_code}" \
        -H "User-Agent: CLAWHunter/1.0" \
        "http://${ip}:${port}/" 2>/dev/null)

    local curl_exit=$?
    PROBE_HTTP_CODE=$(echo "$response" | grep '__HTTP_CODE__:' | cut -d: -f2)
    local body
    body=$(echo "$response" | grep -v '__HTTP_CODE__:')

    if [ -n "$PROBE_HTTP_CODE" ]; then
        PROBE_CANDIDATE=1

        # Confirmed if body or headers mention openclaw/clawd/gateway
        local body_lower
        body_lower=$(echo "$body" | tr '[:upper:]' '[:lower:]')
        if echo "$body_lower" | grep -qE 'openclaw|clawd|gateway'; then
            PROBE_CONFIRMED=1
            PROBE_BANNER=$(echo "$body" | head -1 | cut -c1-60)
            return 0
        fi

        # Also confirmed if port matches our primary target and HTTP auth rejected
        # (401/403 on port 18790 is a very strong signal — it's a token-gated gateway)
        if [ "$port" -eq "$TARGET_PORT" ] && \
           echo "$PROBE_HTTP_CODE" | grep -qE '^(401|403|400)$'; then
            PROBE_CONFIRMED=1
            PROBE_BANNER="HTTP ${PROBE_HTTP_CODE} (auth required)"
            return 0
        fi
    elif [ $curl_exit -eq 0 ]; then
        # TCP connected, no HTTP response — note as candidate (might be different protocol)
        PROBE_CANDIDATE=1
    fi

    return 0
}

# ── Main scan loop ─────────────────────────────────────────────────────────────

LOG cyan "Starting scan..."
LOG dim "${SUBNET}.${HOST_START}-${HOST_END}"
sleep 1

SPINNER_ID=$(START_SPINNER "Scanning hosts...")

for i in $(seq $HOST_START $HOST_END); do
    # Check for B-button abort between hosts
    if WAIT_FOR_BUTTON_PRESS B 0 2>/dev/null; then
        ABORT=1
        break
    fi

    IP="${SUBNET}.${i}"
    HOSTS_SCANNED=$((HOSTS_SCANNED + 1))

    # Quick ping to avoid wasting time on dead hosts
    if ! ping -c 1 -W 1 "$IP" &>/dev/null; then
        continue
    fi

    # Host is alive — stop spinner to log, then restart
    STOP_SPINNER "$SPINNER_ID"
    LOG dim "Live: $IP"
    log_entry "Host alive: $IP"

    SPINNER_ID=$(START_SPINNER "Probing $IP...")

    HOST_FOUND=0
    for PORT in $PORTS; do
        probe_openclaw "$IP" "$PORT"

        if [ $PROBE_CONFIRMED -eq 1 ]; then
            STOP_SPINNER "$SPINNER_ID"
            LOG green "✦ FOUND: ${IP}:${PORT}"
            LOG green "  ${PROBE_BANNER}"
            log_found "${IP}:${PORT} | HTTP ${PROBE_HTTP_CODE} | ${PROBE_BANNER}"
            HOST_FOUND=1
            SPINNER_ID=$(START_SPINNER "Scanning...")
        elif [ $PROBE_CANDIDATE -eq 1 ]; then
            STOP_SPINNER "$SPINNER_ID"
            LOG yellow "? PORT OPEN: ${IP}:${PORT} (HTTP ${PROBE_HTTP_CODE})"
            log_candidate "${IP}:${PORT} | HTTP ${PROBE_HTTP_CODE} (unconfirmed)"
            SPINNER_ID=$(START_SPINNER "Scanning...")
        fi
    done

    if [ $HOST_FOUND -eq 1 ]; then
        log_entry "  └─ OpenClaw found on $IP"
    fi
done

STOP_SPINNER "$SPINNER_ID"

# ── Handle abort ──────────────────────────────────────────────────────────────

if [ $ABORT -eq 1 ]; then
    LOG red "Scan aborted"
    log_entry "SCAN ABORTED by user"
fi

# ── Write log footer ──────────────────────────────────────────────────────────

{
    echo ""
    echo "=================================================="
    echo "SUMMARY"
    echo "  Hosts scanned : $HOSTS_SCANNED"
    echo "  OpenClaw found: $FOUND_COUNT"
    echo "  Status        : $([ $ABORT -eq 1 ] && echo 'ABORTED' || echo 'COMPLETE')"
    echo "  Elapsed       : $SECONDS seconds"
    echo "  Log saved     : $LOG_FILE"
    echo "=================================================="
} >> "$LOG_FILE"

# ── Results screen ────────────────────────────────────────────────────────────

if [ $FOUND_COUNT -gt 0 ]; then
    LOG green "Scan Complete"
    LOG green "Found: $FOUND_COUNT OpenClaw"
    LOG dim "Scanned: $HOSTS_SCANNED hosts"
else
    LOG yellow "Scan Complete"
    LOG yellow "No instances found"
    LOG dim "Scanned: $HOSTS_SCANNED hosts"
fi

LOG dim "Log: $LOG_FILE"
sleep 1

PROMPT "Done — press any key"

exit 0
