#!/bin/bash
# =============================================================================
# CLAWHunter — Recon Payload Variant
# For the Hak5 WiFi Pineapple Pager — Runs from Recon UI against a selected AP
# =============================================================================
#
# PAYLOAD_VERSION: 3.1.0
# AUTHOR:  doublegate
# REPO:    https://github.com/doublegate/CLAWHunter
#
# DESCRIPTION:
#   RF-first variant. Launched from the Pager Recon UI after selecting an AP.
#   Reads _RECON_SELECTED_AP_* context variables to connect, auto-derive the
#   subnet, and run a targeted CLAWHunter scan — no manual pickers needed.
#   Flow: connect → scan → results → disconnect
#
# RECON CONTEXT VARIABLES (set by Pager Recon UI):
#   _RECON_SELECTED_AP_SSID             Target AP SSID
#   _RECON_SELECTED_AP_ENCRYPTION_TYPE  Encryption (open, WPA, WPA2, etc.)
#   _RECON_SELECTED_AP_BSSID            Target AP BSSID
#
# DEPLOY:
#   scp -r payloads/recon/clawhunter lib \
#       root@pineapple.lan:/root/payloads/recon/
#
# LOG OUTPUT:
#   /root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log
#   /root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.json
# =============================================================================

readonly PAYLOAD_VERSION="3.1.0"
readonly OPENCLAW_DEFAULT_PORT=18790
readonly OPENCLAW_RANGE_LOW=18780
readonly OPENCLAW_RANGE_HIGH=18800
readonly EXTENDED_PORTS="80 443 3000 8080 8443"
readonly LOOT_BASE="/root/loot/clawhunter"
readonly WIFI_IF="wlan0cli"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../lib/common.sh
. "${SCRIPT_DIR}/../../lib/common.sh"

# ── Runtime state ─────────────────────────────────────────────────────────────

SILENT=0
FOUND_COUNT=0
HOSTS_SCANNED=0
ABORT=0
declare -a FOUND_HOSTS=()
declare -a FOUND_DETAILS=()
SCAN_ID=""
LOG_FILE=""
LOCAL_IP=""
SUBNET=""
TARGET_PORT=$OPENCLAW_DEFAULT_PORT
ALL_PORTS="$TARGET_PORT"
PORT_DESC="$TARGET_PORT"
HOST_START=1
HOST_END=254
WIFI_CONNECTED=0

mkdir -p "$LOOT_BASE"

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
    led_off
    [ $WIFI_CONNECTED -eq 1 ] && WIFI_DISCONNECT "$WIFI_IF" &>/dev/null || true
    [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] && \
        log_entry "Recon payload exited (cleanup)"
}
trap cleanup EXIT INT TERM

# ── Banner ────────────────────────────────────────────────────────────────────

LOG blue "  ✦ CLAWHunter v${PAYLOAD_VERSION}"
LOG      "  Recon Variant"
LOG blue "  WiFi Pineapple Pager"
sleep 1

# ── Validate Recon context ────────────────────────────────────────────────────

SSID="${_RECON_SELECTED_AP_SSID:-}"
ENC="${_RECON_SELECTED_AP_ENCRYPTION_TYPE:-}"
BSSID="${_RECON_SELECTED_AP_BSSID:-}"

if [ -z "$SSID" ]; then
    led_error
    ERROR_DIALOG "No AP Selected" "Launch from Recon UI with an AP selected. SSID not set."
    exit 1
fi

LOG blue "Target AP: $SSID"
[ -n "$BSSID" ] && LOG blue "BSSID: $BSSID"
LOG blue "Enc: ${ENC:-open}"
sleep 1

# ── Prompt for password if encrypted ─────────────────────────────────────────

PASS=""
ENC_LC=$(echo "${ENC:-open}" | tr '[:upper:]' '[:lower:]')
if ! echo "$ENC_LC" | grep -qE '^(open|none|)$'; then
    # DuckyScript has no free-text picker — password must be pre-stored or
    # the AP pre-joined. Notify user and attempt connection with empty password
    # (works if credentials are already saved on the Pager).
    LOG red "Encrypted AP: $SSID"
    LOG blue "Pre-join via Settings if needed"
    sleep 2
    PASS=""
fi

# ── Connect to AP ─────────────────────────────────────────────────────────────

LOG blue "Connecting to $SSID..."
led_wifi_connect
SID=$(START_SPINNER "Connecting to ${SSID}...")

if [ -z "$PASS" ]; then
    WIFI_CONNECT "$WIFI_IF" "$SSID" "open" "" "ANY" &>/dev/null
else
    WIFI_CONNECT "$WIFI_IF" "$SSID" "psk2" "$PASS" "ANY" &>/dev/null
fi

READY=0
for _i in $(seq 1 30); do
    CIDR=$(ip -4 -o addr show dev "$WIFI_IF" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -n "$CIDR" ]; then READY=1; break; fi
    sleep 1
done

STOP_SPINNER "$SID"

if [ $READY -eq 1 ]; then
    LOCAL_IP="${CIDR%%/*}"
    WIFI_CONNECTED=1
    ringtone_wifi_ok; vibrate_medium
    LOG green "Connected: $LOCAL_IP"
    sleep 1
else
    led_error
    ERROR_DIALOG "Connect Failed" "No IP on ${WIFI_IF} after 30s — check password"
    exit 1
fi

# ── Auto-derive subnet ────────────────────────────────────────────────────────

SUBNET=$(echo "$LOCAL_IP" | cut -d. -f1-3)
LOG blue "Subnet: ${SUBNET}.0/24"
sleep 1

# ── Run mDNS prescan (one-shot — recon variant is fast) ───────────────────────

mdns_prescan

# ── Port sweep ────────────────────────────────────────────────────────────────

SCAN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOOT_BASE/scan_${SCAN_ID}.log"

{
    echo "=================================================="
    echo "  CLAWHunter v${PAYLOAD_VERSION} — Recon Variant"
    echo "  Hak5 WiFi Pineapple Pager"
    echo "=================================================="
    echo "Scan ID        : $SCAN_ID"
    echo "Date/Time      : $(date)"
    echo "Mode           : RECON"
    echo "Target AP      : $SSID"
    echo "BSSID          : ${BSSID:-unknown}"
    echo "Encryption     : ${ENC:-open}"
    echo "Scanner IP     : $LOCAL_IP"
    echo "Subnet         : ${SUBNET}.1-254"
    echo "Port(s)        : $PORT_DESC"
    echo "ARP available  : $(command -v arp-scan >/dev/null 2>&1 && echo YES || echo NO)"
    echo "avahi available: $(command -v avahi-browse >/dev/null 2>&1 && echo YES || echo NO)"
    echo "=================================================="
    echo ""
} > "$LOG_FILE"

log_section "PORT SCAN"

# ── ARP cache harvest (C2) before discovery ───────────────────────────────────
LOG blue "Checking ARP cache..."
cache_hosts=$(arp_cache_harvest "$SUBNET" 2>/dev/null)

# ── Host discovery ────────────────────────────────────────────────────────────
LOG blue "Discovering hosts..."
SID=$(START_SPINNER "ARP host discovery...")
raw_hosts=$(arp_discover_hosts "$SUBNET" "$HOST_START" "$HOST_END" 2>/dev/null)

if [ -n "$cache_hosts" ]; then
    raw_hosts=$(printf '%s\n%s\n' "$cache_hosts" "$raw_hosts" | sort -u -t. -k4 -n)
fi

STOP_SPINNER "$SID"

declare -a LIVE_HOSTS=()
while IFS= read -r h; do
    [ -n "$h" ] && LIVE_HOSTS+=("$h")
done <<< "$raw_hosts"

TOTAL_LIVE=${#LIVE_HOSTS[@]}
log_entry "Host discovery: $TOTAL_LIVE live hosts"

if [ $TOTAL_LIVE -eq 0 ]; then
    LOG red "No live hosts found"
    log_entry "No live hosts — scan complete"
    WIFI_DISCONNECT "$WIFI_IF" &>/dev/null || true
    WIFI_CONNECTED=0
    PROMPT "No hosts found — press any key"
    exit 0
fi

LOG blue "Live hosts: $TOTAL_LIVE"
sleep 1

# ── Sequential probe loop ──────────────────────────────────────────────────────
led_scanning
SID=$(START_SPINNER "Probing (0/${TOTAL_LIVE}, 0%)...")
probe_idx=0

for IP in "${LIVE_HOSTS[@]}"; do
    local btn
    btn=$(timeout 0.05 sh -c 'WAIT_FOR_INPUT 2>/dev/null' 2>/dev/null || true)
    if [ "$btn" = "B" ]; then ABORT=1; break; fi

    probe_idx=$((probe_idx + 1))
    HOSTS_SCANNED=$((HOSTS_SCANNED + 1))
    pct=$(( (probe_idx * 100) / TOTAL_LIVE ))

    STOP_SPINNER "$SID"
    LOG blue "${pct}% — $IP ($probe_idx/${TOTAL_LIVE})"
    log_entry "Probing: $IP ($probe_idx/${TOTAL_LIVE}, ${pct}%)"
    SID=$(START_SPINNER "${pct}% — ${IP} ($probe_idx/${TOTAL_LIVE})...")

    for PORT in $ALL_PORTS; do
        probe_openclaw "$IP" "$PORT" || continue

        if [ $PROBE_CONFIRMED -eq 1 ]; then
            STOP_SPINNER "$SID"
            led_found; ringtone_found; vibrate_strong

            LOG green "✦ FOUND: ${IP}:${PORT} (${PROBE_SCHEME})"
            LOG green "  ${PROBE_BANNER}"
            [ -n "$PROBE_DETAIL" ] && LOG "  ${PROBE_DETAIL:0:55}"

            log_found "${IP}:${PORT} | ${PROBE_SCHEME} | HTTP ${PROBE_HTTP_CODE} | ${PROBE_BANNER}"
            [ -n "$PROBE_DETAIL" ] && log_entry "  Detail: ${PROBE_DETAIL}"

            FOUND_HOSTS+=("${IP}:${PORT}")
            FOUND_DETAILS+=("${PROBE_SCHEME}:// | ${PROBE_BANNER} | ${PROBE_DETAIL}")
            FOUND_COUNT=$((FOUND_COUNT + 1))

            ALERT "✦ OpenClaw Found!\n${IP}:${PORT} (${PROBE_SCHEME})\n${PROBE_BANNER}\n${PROBE_DETAIL:0:80}\nPress any key to continue"

            led_scanning
            SID=$(START_SPINNER "${pct}% — ${IP} ($probe_idx/${TOTAL_LIVE})...")

        elif [ $PROBE_CANDIDATE -eq 1 ]; then
            STOP_SPINNER "$SID"
            led_candidate; ringtone_candidate; vibrate_soft
            LOG blue "? Open: ${IP}:${PORT} (HTTP ${PROBE_HTTP_CODE}, ${PROBE_SCHEME})"
            log_candidate "${IP}:${PORT} | ${PROBE_SCHEME} | HTTP ${PROBE_HTTP_CODE}"
            sleep 1
            led_scanning
            SID=$(START_SPINNER "${pct}% — ${IP} ($probe_idx/${TOTAL_LIVE})...")
        fi
    done
done

STOP_SPINNER "$SID"

[ $ABORT -eq 1 ] && ringtone_abort && LOG red "Scan aborted" && log_entry "SCAN ABORTED"

# ── D1: JSON report ───────────────────────────────────────────────────────────
write_json_report "$SCAN_ID" "${SUBNET}.1-254" "$HOSTS_SCANNED" "$SECONDS"

# ── Log footer ────────────────────────────────────────────────────────────────
{
    echo ""
    echo "=================================================="
    echo "SUMMARY"
    printf "  Mode           : RECON\n"
    printf "  Target AP      : %s\n" "$SSID"
    printf "  Hosts scanned  : %d\n" "$HOSTS_SCANNED"
    printf "  OpenClaw found : %d\n" "$FOUND_COUNT"
    printf "  Elapsed        : %ds\n" "$SECONDS"
    printf "  Status         : %s\n" "$([ $ABORT -eq 1 ] && echo ABORTED || echo COMPLETE)"
    if [ $FOUND_COUNT -gt 0 ]; then
        echo ""
        echo "  DISCOVERED INSTANCES:"
        for h in "${FOUND_HOSTS[@]}"; do
            printf "    ✦ %s\n" "$h"
        done
    fi
    echo "=================================================="
    printf "  Log : %s\n" "$LOG_FILE"
    printf "  JSON: %s\n" "${LOOT_BASE}/scan_${SCAN_ID}.json"
    echo "=================================================="
} >> "$LOG_FILE"

# ── Results ───────────────────────────────────────────────────────────────────
if [ $FOUND_COUNT -gt 0 ]; then
    led_complete_ok; ringtone_complete_ok; vibrate_strong
    LOG green "Complete! Found: $FOUND_COUNT"
    LOG blue  "Scanned: $HOSTS_SCANNED hosts"
else
    led_complete_none; ringtone_complete_none
    LOG blue "Complete — none found"
    LOG blue "Scanned: $HOSTS_SCANNED hosts"
fi
sleep 1

show_results_browser

# ── Disconnect ────────────────────────────────────────────────────────────────
LOG blue "Disconnecting $WIFI_IF..."
WIFI_DISCONNECT "$WIFI_IF" &>/dev/null || true
WIFI_CONNECTED=0
LOG blue "Disconnected from $SSID"
sleep 1

PROMPT "Recon scan done — press any key"
led_off
exit 0
