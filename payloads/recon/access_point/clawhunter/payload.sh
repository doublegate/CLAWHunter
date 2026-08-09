#!/bin/bash
# shellcheck disable=SC2034 # Shared-library runtime globals are set by this payload.
# Title: CLAWHunter (Recon)
# Description: RF-first OpenClaw discovery. Launch from the Recon UI after selecting a target AP — automatically reads AP context, connects, scans, and logs found instances.
# Author: doublegate
# =============================================================================
# CLAWHunter — Recon Payload Variant
# For the Hak5 WiFi Pineapple Pager — Runs from Recon UI against a selected AP
# =============================================================================
#
# PAYLOAD_VERSION: 3.4.0
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
#   Use scripts/install-pager.sh from the release bundle.
#
# LOG OUTPUT:
#   /root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log
#   /root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.json
#
# TRANSACTION CONTRACT:
#   Input  - one Recon-selected AP plus an in-memory passphrase when encrypted.
#   Work   - temporary wlan0cli association, DHCP, mDNS/ARP, sequential probes.
#   Output - confirmed results and evidence-rich local loot only.
#   Exit   - disconnect and clear the client configuration on every path.
# =============================================================================

readonly PAYLOAD_VERSION="3.4.0"
# 18789 is current; 18790 remains a bounded legacy secondary probe in Recon.
readonly OPENCLAW_DEFAULT_PORT=18789
readonly LOOT_BASE="/root/loot/clawhunter"
readonly WIFI_IF="wlan0cli"

# Resolve common.sh in three supported layouts: self-contained Portal payload,
# installed suite (/root/payloads/lib), and repository checkout for development.
# Locate this payload's own directory. The Pager firmware copies payload.sh to
# /tmp/payload-<random>.sh and executes the copy, so "$0" -- and BASH_SOURCE with
# it -- names a temp file with no payload resources beside it. Resolving from
# "$0" alone therefore fails on every UI launch, which is the one path operators
# actually use. The firmware compensates by exporting _PAYLOAD_HOME and by
# setting the working directory to the payload directory; prefer those, then
# fall back to "$0" so manual, repository, and staged invocations still work.
# A candidate only counts if it holds payload resources, so a stray PWD cannot
# silently win.
CLAWHUNTER_PAYLOAD_DIR=""
for _claw_cand in "${_PAYLOAD_HOME:-}" "${PAYLOAD_HOME:-}" "$PWD" "$(dirname "$0")"; do
    [ -n "$_claw_cand" ] && [ -d "$_claw_cand" ] || continue
    if [ -f "${_claw_cand}/common.sh" ] || [ -f "${_claw_cand}/payload.sh" ]; then
        CLAWHUNTER_PAYLOAD_DIR="$(cd "$_claw_cand" && pwd)"
        break
    fi
done
unset _claw_cand
# Last resort keeps the relative-layout probes below meaningful even when no
# candidate identified itself.
[ -n "$CLAWHUNTER_PAYLOAD_DIR" ] || CLAWHUNTER_PAYLOAD_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$CLAWHUNTER_PAYLOAD_DIR"
export CLAWHUNTER_PAYLOAD_DIR
_claw_lib=""
for _claw_try in \
    "${SCRIPT_DIR}/common.sh" \
    "${SCRIPT_DIR}/../../../lib/common.sh" \
    "${SCRIPT_DIR}/../../../../lib/common.sh" \
    /root/payloads/lib/common.sh; do
    # Portal self-contained, installed suite, repository checkout, then the
    # canonical install path for a payload executed from outside its directory.
    [ -f "$_claw_try" ] || continue
    _claw_lib="$_claw_try"
    break
done
unset _claw_try
if [ -n "$_claw_lib" ]; then
    # shellcheck source=/dev/null
    . "$_claw_lib"
    unset _claw_lib
else
    ERROR_DIALOG "Install Error" "CLAWHunter common.sh was not found"
    exit 1
fi

# ── Runtime state ─────────────────────────────────────────────────────────────

# Recon is one transaction: selected AP -> temporary client association -> /24
# evidence scan -> local loot -> disconnect. Result arrays remain index-aligned
# and contain confirmed endpoints only, exactly like interactive mode.
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
ALL_PORTS="$TARGET_PORT 18790"
PORT_DESC="${TARGET_PORT}+legacy"
HOST_START=1
HOST_END=254
WIFI_CONNECTED=0

mkdir -p "$LOOT_BASE"

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
    # The trap runs for normal exit, UI cancellation, signals, and early errors.
    # Clear client configuration as well as disconnecting so an entered WPA/SAE
    # passphrase does not remain configured after this payload owns the session.
    led_off
    [ $WIFI_CONNECTED -eq 1 ] && WIFI_DISCONNECT "$WIFI_IF" &>/dev/null || true
    WIFI_CLEAR "$WIFI_IF" >/dev/null 2>&1 || true
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
HIDDEN="${_RECON_SELECTED_AP_HIDDEN:-false}"

# Current Recon context explicitly marks hidden APs, while older/current rows
# may expose an empty or literal `(hidden)` primary SSID. Prompt only for that
# missing public identifier; the passphrase prompt remains a separate step.
if [ "$HIDDEN" = "true" ] || [ "$HIDDEN" = "1" ] || \
   [ -z "$SSID" ] || [ "$SSID" = "(hidden)" ]; then
    SSID=$(TEXT_PICKER "SSID for hidden AP" "")
    case $? in
        "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR") exit 0 ;;
    esac
    if [ -z "$SSID" ]; then
        ERROR_DIALOG "SSID Required" "A hidden access point needs its exact SSID"
        exit 1
    fi
fi

# BSSID is expected from a selected Recon row and pins the association when
# present; it is never inferred from another AP sharing the entered SSID.
LOG blue "Target AP: $SSID"
[ -n "$BSSID" ] && LOG blue "BSSID: $BSSID"
LOG blue "Enc: ${ENC:-open}"
sleep 1

# ── Prompt for password if encrypted ─────────────────────────────────────────

# wlan0cli is the Pager's 2.4 GHz client interface. Firmware/context versions
# may provide either numeric frequency or channel, so validate before arithmetic
# and reject an unsupported selected band rather than timing out ambiguously.
AP_FREQ="${_RECON_SELECTED_AP_FREQ:-}"
AP_CHANNEL="${_RECON_SELECTED_AP_CHANNEL:-}"
if { [[ "$AP_FREQ" =~ ^[0-9]+$ ]] && [ "$AP_FREQ" -ge 5000 ]; } || \
   { [ -z "$AP_FREQ" ] && [[ "$AP_CHANNEL" =~ ^[0-9]+$ ]] && [ "$AP_CHANNEL" -ge 36 ]; }; then
    ERROR_DIALOG "Unsupported Band" "wlan0cli supports only 2.4 GHz access points"
    exit 1
fi

# These values and the five-argument call below mirror Hak5's current official
# Connect-To-AP payload. The operator-entered passphrase is held in memory only;
# it is never written to loot, config, command arguments, or UI history here.
case "$ENC" in
    *WPA3*|*SAE*|*sae*) WIFI_ENC="sae" ;;
    *WPA2*|*PSK2*|*psk2*) WIFI_ENC="psk2" ;;
    *WPA*|*PSK*|*psk*) WIFI_ENC="psk" ;;
    *Open*|*open*|*NONE*|*none*|"") WIFI_ENC="open" ;;
    *) ERROR_DIALOG "Unsupported Encryption" "$ENC"; exit 1 ;;
esac

if [ "$WIFI_ENC" = "open" ]; then
    # Hak5's current WIFI_CONNECT contract uses the literal NONE for open APs.
    PASS="NONE"
else
    # TEXT_PICKER returns status through `$?`; cancellation exits before any
    # client configuration or loot file is created.
    PASS=$(TEXT_PICKER "Password for ${SSID}" "")
    case $? in
        "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR") exit 0 ;;
    esac
    [ -n "$PASS" ] || { ERROR_DIALOG "Password Required" "Encrypted AP selected"; exit 1; }
fi

# ── Connect to AP ─────────────────────────────────────────────────────────────

LOG blue "Connecting to $SSID..."
led_wifi_connect
SID=$(START_SPINNER "Connecting to ${SSID}...")

# Pin the selected BSSID so a duplicate SSID cannot redirect the assessment to a
# different access point. ANY is used only when older context omits the BSSID.
WIFI_CLEAR "$WIFI_IF" >/dev/null 2>&1 || true
if ! WIFI_CONNECT "$WIFI_IF" "$SSID" "$WIFI_ENC" "$PASS" "${BSSID:-ANY}" >/dev/null 2>&1; then
    STOP_SPINNER "$SID"
    ERROR_DIALOG "Connect Failed" "WIFI_CONNECT rejected the selected AP"
    exit 1
fi

# WIFI_CONNECT can return before DHCP completes. Poll only the selected client
# interface for at most 30 seconds and derive the scan network from its address.
READY=0
for _i in $(seq 1 30); do
    # Query only wlan0cli. An address on management/PineAP interfaces must not
    # be mistaken for successful association to the selected target AP.
    CIDR=$(ip -4 -o addr show dev "$WIFI_IF" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -n "$CIDR" ]; then READY=1; break; fi
    sleep 1
done

STOP_SPINNER "$SID"

if [ $READY -eq 1 ]; then
    LOCAL_IP="${CIDR%%/*}"
    if ! is_valid_ipv4 "$LOCAL_IP"; then
        ERROR_DIALOG "Connect Failed" "Client interface returned invalid IPv4 data"
        exit 1
    fi
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

# CLAWHunter deliberately bounds Recon work to the connected IPv4 /24 rather
# than interpreting an arbitrary route/prefix from untrusted network metadata.
SUBNET=$(subnet_prefix_from_ip "$LOCAL_IP")
LOG blue "Subnet: ${SUBNET}.0/24"
sleep 1

# ── Initialize evidence log and run one-shot discovery ────────────────────────
# The file must exist before mdns_prescan emits entries. Active discovery and
# the sequential port sweep then append to the same chronological evidence log.

SCAN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOOT_BASE/scan_${SCAN_ID}.log"

{
    # The header records all non-secret context needed to reproduce the run.
    # PASS is intentionally absent; ENC documents only the public AP mode.
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

# Create the log before mDNS so passive hints are retained rather than displayed
# transiently and overwritten by the later scan header.
mdns_prescan

log_section "PORT SCAN"

# ── ARP cache harvest (C2) before discovery ───────────────────────────────────
LOG blue "Checking ARP cache..."
cache_hosts=$(arp_cache_harvest "$SUBNET" 2>/dev/null)

# ── Host discovery ────────────────────────────────────────────────────────────
LOG blue "Discovering hosts..."
SID=$(START_SPINNER "ARP host discovery...")
raw_hosts=$(arp_discover_hosts "$SUBNET" "$HOST_START" "$HOST_END" 2>/dev/null)

if [ -n "$cache_hosts" ]; then
    # Both sources are IPv4-only; de-duplicate with the numeric final octet so
    # cached and actively discovered entries share one deterministic work list.
    raw_hosts=$(printf '%s\n%s\n' "$cache_hosts" "$raw_hosts" | sort -u -t. -k4 -n)
fi

STOP_SPINNER "$SID"

declare -a LIVE_HOSTS=()
while IFS= read -r h; do
    # arp_cache_harvest/arp_discover_hosts already constrain results to IPv4;
    # retain a simple array so progress denominators remain stable.
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

# Recon remains sequential to minimize interference with the UI's selected-AP
# workflow. Each host can produce multiple confirmed endpoints (one per port).
for IP in "${LIVE_HOSTS[@]}"; do
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
        # One host may expose multiple gateway bindings, so do not stop after a
        # confirmed default port; record every selected-port classification.
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
            # Candidates receive transient operator feedback but never enter
            # FOUND_HOSTS, JSON instances, history, or assessment selection.
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
# JSON contains only confirmed results; text loot retains candidate evidence.
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

# Assessment remains an explicit RIGHT-button action on a confirmed endpoint.
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
