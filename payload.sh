#!/bin/bash
# =============================================================================
# CLAWHunter — OpenClaw Instance Discovery Payload
# For the Hak5 WiFi Pineapple Pager (480×222 px, 16-bit color, 221 PPI)
# =============================================================================
#
# VERSION: 2.1.0
# AUTHOR:  doublegate (doublegate)
# REPO:    https://github.com/doublegate/CLAWHunter
#
# FEATURES:
#   1. Silent mode              — suppress all audio/haptic for covert ops
#   2. Progress counter         — live % in spinner + host index tracking
#   3. ARP host discovery       — Layer-2 host detection, ping fallback
#   4. Randomized scan order    — shuf() host list to reduce IDS signature
#   5. HTTPS probe              — try http:// then https:// per open port
#   6. Extended ports           — optionally sweep 80, 443, 3000, 8080, 8443
#   7. mDNS pre-scan            — avahi-browse for zero-probe finds before scan
#   8. Deep fingerprinting      — headers, /health, /status, version/persona
#   9. WiFi client mode         — WIFI_CONNECT to target AP, auto-scan, disconnect
#  10. Multiple subnet sweep    — loop after each scan for another subnet
#  11. Cross-run history/diff   — browse past finds, diff new/gone vs history
#
# HARDWARE INTEGRATION:
#   - RGB LED array: distinct patterns per state
#   - VIBRATE: soft/medium/strong per event type
#   - RINGTONE (RTTTL): audio cues per event (all suppressed in silent mode)
#   - ALERT popups: full-screen pause on confirmed finds
#   - WAIT_FOR_INPUT: interactive results browser + history browser
#   - WAIT_FOR_BUTTON_PRESS: B-button abort during scan
#
# CONTROLS:
#   B            — abort scan in progress
#   UP/DOWN      — navigate results browser and history browser
#   B or LEFT    — exit browser panels
#   Any button   — dismiss ALERT popups / PROMPT screens
#
# LOG OUTPUT:
#   /root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log
# =============================================================================

# ── Constants ─────────────────────────────────────────────────────────────────

readonly PAYLOAD_VERSION="2.1.0"
readonly OPENCLAW_DEFAULT_PORT=18790
readonly OPENCLAW_RANGE_LOW=18780
readonly OPENCLAW_RANGE_HIGH=18800
readonly EXTENDED_PORTS="80 443 3000 8080 8443"
readonly LOOT_BASE="/root/loot/clawhunter"
readonly WIFI_IF="wlan0cli"

# ── Runtime state (reset per scan in run_scan()) ──────────────────────────────

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
ALL_PORTS=""
PORT_DESC=""
HOST_START=1
HOST_END=254
WIDE_SCAN=0
EXTRA_PORTS=0
RANDOMIZE=0
WIFI_CONNECTED=0

mkdir -p "$LOOT_BASE"

# ── Cleanup trap ──────────────────────────────────────────────────────────────

cleanup() {
    led_off
    # Disconnect WiFi if we connected
    [ $WIFI_CONNECTED -eq 1 ] && WIFI_DISCONNECT "$WIFI_IF" &>/dev/null || true
    [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] && \
        log_entry "Payload exited (cleanup trap — exit code: $?)"
}
trap cleanup EXIT INT TERM

# ── Hardware: LED control ─────────────────────────────────────────────────────
# RGB LED array via HAK5_API_POST. 4 LEDs, each [R,G,B] boolean.
# onms/offms control blink timing; "next":true chains pattern frames.

. /lib/hak5/commands.sh 2>/dev/null || true

_led() { HAK5_API_POST "system/led" "$1" >/dev/null 2>&1 || true; }

led_off() {
    _led '{"color":"custom","raw_pattern":[{"onms":100,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}
led_scanning() {
    # Slow blue pulse — actively scanning
    _led '{"color":"custom","raw_pattern":[{"onms":600,"offms":400,"next":false,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,true],"4":[false,false,true]}}]}'
}
led_found() {
    # Fast green flash — confirmed OpenClaw discovered
    _led '{"color":"custom","raw_pattern":[{"onms":120,"offms":120,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}
led_candidate() {
    # Alternating blue/green — port open, awaiting confirmation
    _led '{"color":"custom","raw_pattern":[{"onms":250,"offms":150,"next":true,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,true],"4":[false,false,true]}},{"onms":250,"offms":150,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}
led_mdns() {
    # Cyan double-flash — mDNS hit (first two LEDs only for distinction)
    _led '{"color":"custom","raw_pattern":[{"onms":150,"offms":100,"next":true,"rgb":{"1":[false,true,true],"2":[false,true,true],"3":[false,false,false],"4":[false,false,false]}},{"onms":150,"offms":300,"next":false,"rgb":{"1":[false,true,true],"2":[false,true,true],"3":[false,false,false],"4":[false,false,false]}}]}'
}
led_error() {
    # Solid red — error state
    _led '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[true,false,false],"2":[true,false,false],"3":[true,false,false],"4":[true,false,false]}}]}'
}
led_wifi_connect() {
    # Slow white pulse — connecting to AP
    _led '{"color":"custom","raw_pattern":[{"onms":500,"offms":300,"next":false,"rgb":{"1":[true,true,true],"2":[true,true,true],"3":[true,true,true],"4":[true,true,true]}}]}'
}
led_complete_ok() {
    # Slow green pulse — done, found something
    _led '{"color":"custom","raw_pattern":[{"onms":700,"offms":500,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}
led_complete_none() {
    # Slow blue pulse — done, nothing found
    _led '{"color":"custom","raw_pattern":[{"onms":700,"offms":500,"next":false,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,true],"4":[false,false,true]}}]}'
}

# ── Hardware: audio/haptic (all gated on $SILENT) ─────────────────────────────

_play()    { [ $SILENT -eq 0 ] || return 0; RINGTONE "$1" & }
_vibrate() { [ $SILENT -eq 0 ] || return 0; VIBRATE "$1"; }

vibrate_soft()   { _vibrate 150; }
vibrate_medium() { _vibrate 300; }
vibrate_strong() { _vibrate 500; }

# RTTTL ringtones — name:defaults:notes
ringtone_start()         { _play "start:d=8,o=5,b=180:c,e,g"; }
ringtone_found()         { _play "found:d=8,o=5,b=220:e,e,g,g,b,b"; }
ringtone_mdns_found()    { _play "mdns:d=8,o=5,b=200:g,b,d6"; }
ringtone_candidate()     { _play "ping:d=16,o=5,b=200:g"; }
ringtone_complete_ok()   { _play "win:d=4,o=5,b=160:c,e,g,c6"; }
ringtone_complete_none() { _play "none:d=4,o=5,b=140:g,e,c"; }
ringtone_abort()         { _play "abort:d=4,o=4,b=120:g,e"; }
ringtone_wifi_ok()       { _play "wifi:d=8,o=5,b=200:c,g,c6"; }

# ── Logging helpers ───────────────────────────────────────────────────────────

log_entry()     { [ -n "$LOG_FILE" ] && printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1" >> "$LOG_FILE"; }
log_found()     { [ -n "$LOG_FILE" ] && printf "[FOUND]     %s\n" "$1" >> "$LOG_FILE"; }
log_candidate() { [ -n "$LOG_FILE" ] && printf "[CANDIDATE] %s\n" "$1" >> "$LOG_FILE"; }
log_mdns()      { [ -n "$LOG_FILE" ] && printf "[MDNS]      %s\n" "$1" >> "$LOG_FILE"; }
log_section()   { [ -n "$LOG_FILE" ] && printf "\n── %s ──\n" "$1" >> "$LOG_FILE"; }

# ── Feature 7: mDNS pre-scan ──────────────────────────────────────────────────
# Runs avahi-browse before the port sweep. Any service record containing
# "openclaw" or "clawd" (case-insensitive) is treated as a confirmed find,
# logged, and added to FOUND_HOSTS — without needing a port probe.

mdns_prescan() {
    log_section "mDNS PRE-SCAN"
    LOG blue "mDNS pre-scan..."

    local SID
    SID=$(START_SPINNER "mDNS discovery (5s)...")

    local results=""
    if command -v avahi-browse >/dev/null 2>&1; then
        results=$(timeout 5 avahi-browse -a -t -p 2>/dev/null \
                  | grep -iE 'openclaw|clawd' | head -20)
    fi

    STOP_SPINNER "$SID"

    if [ -n "$results" ]; then
        led_mdns
        ringtone_mdns_found
        vibrate_medium

        LOG green "mDNS: OpenClaw service found!"
        log_mdns "Raw: $results"

        # Extract IP from each matching avahi record and add as a confirmed find
        while IFS= read -r line; do
            local mdns_ip
            mdns_ip=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            if [ -n "$mdns_ip" ]; then
                FOUND_HOSTS+=("${mdns_ip}:mDNS")
                FOUND_DETAILS+=("mDNS discovery — service record match")
                FOUND_COUNT=$((FOUND_COUNT + 1))
                LOG green "  mDNS: $mdns_ip"
                log_found "${mdns_ip} via mDNS | record: $(echo "$line" | cut -c1-80)"
            fi
        done <<< "$results"

        ALERT "mDNS Find!\n${results:0:120}\nPress any key to continue to port scan"
    else
        LOG blue "mDNS: no OpenClaw services"
        log_entry "mDNS: no matches found"
        sleep 1
    fi
}

# ── Feature 3: ARP host discovery ─────────────────────────────────────────────
# Uses arp-scan if available (fast, L2, works through ping filters).
# Falls back to arping, then to ping sweep if neither is installed.
# Outputs one live IP per line; caller captures into an array.

arp_discover_hosts() {
    local subnet="$1" start="$2" end="$3"

    if command -v arp-scan >/dev/null 2>&1; then
        arp-scan "${subnet}.0/24" 2>/dev/null \
            | grep -oE "${subnet//./[.]}\.[0-9]+" \
            | awk -F. -v s="$start" -v e="$end" '{ n=$4; if (n>=s && n<=e) print }' \
            | sort -t. -k4 -n
        return 0
    fi

    if command -v arping >/dev/null 2>&1; then
        for i in $(seq "$start" "$end"); do
            arping -c 1 -w 1 "${subnet}.${i}" &>/dev/null && echo "${subnet}.${i}"
        done
        return 0
    fi

    # Fallback: standard ICMP ping sweep
    for i in $(seq "$start" "$end"); do
        ping -c 1 -W 1 "${subnet}.${i}" &>/dev/null && echo "${subnet}.${i}"
    done
}

# ── Feature 8: Deep fingerprinting ───────────────────────────────────────────
# Called after PROBE_CONFIRMED=1. Probes headers, /health, /status,
# and common OpenClaw API paths to extract version, persona, and server info.
# Populates PROBE_DETAIL string.

deep_fingerprint() {
    local ip="$1" port="$2" scheme="$3"
    PROBE_DETAIL=""

    # Grab response headers only (cheap)
    local headers
    headers=$(curl -sI \
        --max-time 3 --connect-timeout 2 -k \
        -H "User-Agent: CLAWHunter/${PAYLOAD_VERSION}" \
        "${scheme}://${ip}:${port}/" 2>/dev/null)

    local server x_powered_by
    server=$(echo       "$headers" | grep -i '^server:'       | cut -d: -f2- | tr -d ' \r\n' | cut -c1-40)
    x_powered_by=$(echo "$headers" | grep -i '^x-powered-by:' | cut -d: -f2- | tr -d ' \r\n' | cut -c1-40)

    # Try well-known status/health endpoints for version and persona
    local version="" persona="" status_body
    for endpoint in /health /status /api/status /api/v1/status /api/v1/info; do
        status_body=$(curl -s \
            --max-time 2 --connect-timeout 1 -k \
            -H "User-Agent: CLAWHunter/${PAYLOAD_VERSION}" \
            "${scheme}://${ip}:${port}${endpoint}" 2>/dev/null)

        [ -z "$status_body" ] && continue

        [ -z "$version" ] && \
            version=$(echo "$status_body" \
                | grep -oiE '"version"\s*:\s*"[^"]{1,30}"' | head -1 \
                | grep -oE '"[^"]{1,30}"$' | tr -d '"')

        [ -z "$persona" ] && \
            persona=$(echo "$status_body" \
                | grep -oiE '"(name|agent|persona|identity)"\s*:\s*"[^"]{1,30}"' | head -1 \
                | grep -oE '"[^"]{1,30}"$' | tr -d '"')

        ( [ -n "$version" ] || [ -n "$persona" ] ) && break
    done

    # Assemble detail string
    local -a parts=()
    [ -n "$server"      ] && parts+=("Server: $server")
    [ -n "$x_powered_by"] && parts+=("X-Powered-By: $x_powered_by")
    [ -n "$version"     ] && parts+=("Version: $version")
    [ -n "$persona"     ] && parts+=("Persona: $persona")

    if [ ${#parts[@]} -gt 0 ]; then
        # Join with " | "
        local IFS="|"; PROBE_DETAIL="${parts[*]}"
        IFS=$' \t\n'
    else
        PROBE_DETAIL="No additional intel from headers/endpoints"
    fi
}

# ── Features 5+6: Port probe with HTTPS + extended ports ─────────────────────
# Stage 1: nc TCP check (fast).
# Stage 2: curl HTTP probe, then HTTPS if HTTP returns no response.
# Confirmed if: body contains openclaw/clawd/gateway keywords,
#               or HTTP 400/401/403 on the primary target port.
# Sets: PROBE_CONFIRMED, PROBE_CANDIDATE, PROBE_HTTP_CODE,
#       PROBE_BANNER, PROBE_SCHEME, PROBE_DETAIL

probe_openclaw() {
    local ip="$1" port="$2"
    PROBE_CONFIRMED=0
    PROBE_CANDIDATE=0
    PROBE_HTTP_CODE=""
    PROBE_BANNER=""
    PROBE_SCHEME=""
    PROBE_DETAIL=""

    # Stage 1: fast TCP connect
    nc -z -w 1 "$ip" "$port" 2>/dev/null || return 1

    # Stage 2: HTTP then HTTPS (feature 5)
    local scheme response http_code body body_lower
    for scheme in http https; do
        response=$(curl -s \
            --max-time 3 --connect-timeout 2 -k \
            -w "\n__CODE__:%{http_code}" \
            -H "User-Agent: CLAWHunter/${PAYLOAD_VERSION}" \
            "${scheme}://${ip}:${port}/" 2>/dev/null)

        http_code=$(echo "$response" | grep '__CODE__:' | cut -d: -f2)
        body=$(echo "$response" | grep -v '__CODE__:')
        body_lower=$(echo "$body" | tr '[:upper:]' '[:lower:]')

        # Valid HTTP response received
        if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
            PROBE_CANDIDATE=1
            PROBE_HTTP_CODE="$http_code"
            PROBE_SCHEME="$scheme"

            # Keyword match in body — confirmed
            if echo "$body_lower" | grep -qE 'openclaw|clawd|gateway'; then
                PROBE_CONFIRMED=1
                PROBE_BANNER=$(echo "$body" \
                    | grep -ioE '(openclaw|clawd)[^"<]{0,50}' | head -1 | tr -d '\n')
                [ -z "$PROBE_BANNER" ] && PROBE_BANNER="keyword match in body (${scheme})"
                deep_fingerprint "$ip" "$port" "$scheme"
                return 0
            fi

            # Auth rejection on primary target port — strong signal
            if [ "$port" -eq "$TARGET_PORT" ] \
               && echo "$http_code" | grep -qE '^(400|401|403)$'; then
                PROBE_CONFIRMED=1
                PROBE_BANNER="HTTP ${http_code} on ${scheme}:// — token-gated gateway"
                deep_fingerprint "$ip" "$port" "$scheme"
                return 0
            fi

            # Got a valid HTTP response — don't fall through to HTTPS probe
            return 0
        fi
        # No HTTP response — try HTTPS next iteration
    done

    return 0
}

# ── Feature 11: Cross-run history browser ─────────────────────────────────────
# Reads all past scan logs, deduplicates [FOUND] entries, and presents
# an interactive WAIT_FOR_INPUT browser of every unique instance ever seen.

show_history() {
    LOG blue "Loading history..."
    log_section "HISTORY BROWSER"

    local total_scans=0
    declare -A all_inst_map=()

    for logfile in "$LOOT_BASE"/scan_*.log; do
        [ -f "$logfile" ] || continue
        total_scans=$((total_scans + 1))
        while IFS= read -r line; do
            if echo "$line" | grep -q '^\[FOUND\]\|\[MDNS\]'; then
                local inst
                inst=$(echo "$line" \
                    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9mDNSa-zA-Z]+' \
                    | head -1)
                [ -n "$inst" ] && all_inst_map["$inst"]="$(echo "$line" | cut -c1-80)"
            fi
        done < "$logfile"
    done

    local total_unique=${#all_inst_map[@]}

    LOG blue "History: $total_scans scan(s)"
    if [ $total_unique -gt 0 ]; then
        LOG green "Unique instances: $total_unique"
    else
        LOG blue "No instances found yet"
        sleep 2
        PROMPT "Press any key to exit history"
        return
    fi
    sleep 1
    PROMPT "Press any key to browse"

    local -a inst_keys=("${!all_inst_map[@]}")
    local idx=0

    while true; do
        local inst="${inst_keys[$idx]}"
        local inst_ip="${inst%%:*}"
        local inst_port="${inst##*:}"

        LOG green "History $((idx+1))/${total_unique}"
        LOG green "  IP: $inst_ip"
        LOG blue  "  Port: $inst_port"
        LOG       "  UP/DOWN=nav  B=done"

        local btn
        btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            UP)   [ $idx -gt 0 ] && idx=$((idx - 1)) ;;
            DOWN) [ $idx -lt $((total_unique - 1)) ] && idx=$((idx + 1)) ;;
            B|LEFT) break ;;
        esac
    done

    PROMPT "History done — press any key"
}

# ── Feature 11: Diff against previous scans ───────────────────────────────────
# After a scan completes, compares FOUND_HOSTS against all previous scan logs
# to identify: NEW (not seen before) and GONE (seen before, not in this scan).
# Results are logged and displayed on screen.

run_diff() {
    [ ${#FOUND_HOSTS[@]} -eq 0 ] && return

    # Load all previously known instances (excluding current log)
    declare -A prev_seen=()
    for logfile in "$LOOT_BASE"/scan_*.log; do
        [ -f "$logfile" ] || continue
        [ "$logfile" = "$LOG_FILE" ] && continue
        while IFS= read -r line; do
            if echo "$line" | grep -q '^\[FOUND\]'; then
                local inst
                inst=$(echo "$line" \
                    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' | head -1)
                [ -n "$inst" ] && prev_seen["$inst"]=1
            fi
        done < "$logfile"
    done

    [ ${#prev_seen[@]} -eq 0 ] && return   # No previous data — skip diff

    local new_count=0 gone_count=0

    # NEW: in current scan but not in any previous log
    for h in "${FOUND_HOSTS[@]}"; do
        [[ "$h" == *"mDNS"* ]] && continue
        if [ -z "${prev_seen[$h]+_}" ]; then
            new_count=$((new_count + 1))
            log_entry "DIFF NEW: $h"
        fi
    done

    # GONE: in previous logs on same subnet, not in current results
    declare -A current_set=()
    for h in "${FOUND_HOSTS[@]}"; do current_set["$h"]=1; done

    for prev_h in "${!prev_seen[@]}"; do
        local prev_sub
        prev_sub=$(echo "$prev_h" | cut -d. -f1-3)
        [ "$prev_sub" = "$SUBNET" ] || continue
        if [ -z "${current_set[$prev_h]+_}" ]; then
            gone_count=$((gone_count + 1))
            log_entry "DIFF GONE: $prev_h"
        fi
    done

    # Only surface to display if there's a meaningful delta
    if [ $new_count -gt 0 ] || [ $gone_count -gt 0 ]; then
        LOG blue "─ vs last scan ─"
        [ $new_count  -gt 0 ] && LOG green "  NEW:  $new_count instance(s)"
        [ $gone_count -gt 0 ] && LOG red   "  GONE: $gone_count instance(s)"

        {
            echo ""
            echo "── DIFF vs PREVIOUS SCANS ──"
            printf "  New instances : %d\n" "$new_count"
            printf "  Gone instances: %d\n" "$gone_count"
        } >> "$LOG_FILE"

        sleep 2
    fi
}

# ── Results browser ───────────────────────────────────────────────────────────
# Post-scan interactive browser. Shows each confirmed find with deep
# fingerprint detail. UP/DOWN to navigate, B to exit.

show_results_browser() {
    [ $FOUND_COUNT -eq 0 ] && return
    PROMPT "Press any key to browse finds"

    local idx=0
    while true; do
        local host="${FOUND_HOSTS[$idx]}"
        local detail="${FOUND_DETAILS[$idx]:-}"
        local host_ip="${host%%:*}"
        local host_port="${host##*:}"

        LOG green "Find $((idx+1))/${FOUND_COUNT}"
        LOG green "  $host_ip"
        LOG blue  "  port: $host_port"
        [ -n "$detail" ] && LOG "  ${detail:0:55}"
        LOG "  UP/DOWN=nav  B=done"

        local btn
        btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            UP)   [ $idx -gt 0 ] && idx=$((idx - 1)) ;;
            DOWN) [ $idx -lt $((FOUND_COUNT - 1)) ] && idx=$((idx + 1)) ;;
            B|LEFT) break ;;
        esac
    done
}

# ── Core scan loop ────────────────────────────────────────────────────────────
# Orchestrates mDNS pre-scan → ARP/ping host discovery → port sweep →
# HTTP/HTTPS fingerprinting → deep fingerprint → diff → results browser.
# All 11 features wire through here.

run_scan() {
    # Reset per-scan state (supports multi-subnet looping)
    SCAN_ID="$(date +%Y%m%d_%H%M%S)"
    LOG_FILE="$LOOT_BASE/scan_${SCAN_ID}.log"
    FOUND_COUNT=0
    HOSTS_SCANNED=0
    ABORT=0
    FOUND_HOSTS=()
    FOUND_DETAILS=()

    # ── Write log header ──────────────────────────────────────────
    {
        echo "=================================================="
        echo "  CLAWHunter v${PAYLOAD_VERSION} — OpenClaw Discovery"
        echo "  Hak5 WiFi Pineapple Pager"
        echo "=================================================="
        echo "Scan ID        : $SCAN_ID"
        echo "Date/Time      : $(date)"
        echo "Scanner IP     : ${LOCAL_IP:-unknown}"
        echo "Subnet         : ${SUBNET}.${HOST_START}-${HOST_END}"
        echo "Port(s)        : $PORT_DESC"
        echo "Wide range     : $([ $WIDE_SCAN  -eq 1 ] && echo YES || echo NO)"
        echo "Extended ports : $([ $EXTRA_PORTS -eq 1 ] && echo YES || echo NO)"
        echo "Randomized     : $([ $RANDOMIZE  -eq 1 ] && echo YES || echo NO)"
        echo "Silent mode    : $([ $SILENT     -eq 1 ] && echo YES || echo NO)"
        echo "ARP available  : $(command -v arp-scan >/dev/null 2>&1 && echo YES || echo NO)"
        echo "avahi available: $(command -v avahi-browse >/dev/null 2>&1 && echo YES || echo NO)"
        echo "=================================================="
        echo ""
    } > "$LOG_FILE"

    # ── Feature 7: mDNS pre-scan ─────────────────────────────────
    mdns_prescan

    log_section "PORT SCAN"

    # ── Feature 3: ARP host discovery ────────────────────────────
    LOG blue "Discovering hosts..."
    local SID
    SID=$(START_SPINNER "ARP host discovery...")

    local raw_hosts=""
    raw_hosts=$(arp_discover_hosts "$SUBNET" "$HOST_START" "$HOST_END" 2>/dev/null)

    STOP_SPINNER "$SID"

    # ── Feature 4: randomize scan order ──────────────────────────
    if [ $RANDOMIZE -eq 1 ] && [ -n "$raw_hosts" ]; then
        raw_hosts=$(echo "$raw_hosts" | shuf)
        log_entry "Scan order: randomized"
    fi

    # Build live-host array
    local -a LIVE_HOSTS=()
    while IFS= read -r h; do
        [ -n "$h" ] && LIVE_HOSTS+=("$h")
    done <<< "$raw_hosts"

    local TOTAL_LIVE=${#LIVE_HOSTS[@]}
    log_entry "Host discovery: $TOTAL_LIVE live hosts (method: $(command -v arp-scan >/dev/null 2>&1 && echo arp-scan || command -v arping >/dev/null 2>&1 && echo arping || echo ping))"

    if [ $TOTAL_LIVE -eq 0 ]; then
        LOG red "No live hosts found"
        log_entry "No live hosts — scan complete"
        return
    fi

    LOG blue "Live hosts: $TOTAL_LIVE"
    [ $RANDOMIZE -eq 1 ] && LOG blue "Order: randomized"
    sleep 1

    # ── Main probe loop ───────────────────────────────────────────
    led_scanning
    SID=$(START_SPINNER "Probing (0/${TOTAL_LIVE}, 0%)...")

    local probe_idx=0
    for IP in "${LIVE_HOSTS[@]}"; do

        # ── B-button abort check (non-blocking) ──────────────────
        local btn
        btn=$(timeout 0.05 sh -c 'WAIT_FOR_INPUT 2>/dev/null' 2>/dev/null || true)
        if [ "$btn" = "B" ]; then
            ABORT=1
            break
        fi

        probe_idx=$((probe_idx + 1))
        HOSTS_SCANNED=$((HOSTS_SCANNED + 1))
        local pct=$(( (probe_idx * 100) / TOTAL_LIVE ))

        # ── Feature 2: progress counter in spinner ────────────────
        STOP_SPINNER "$SID"
        LOG blue "${pct}% — $IP ($probe_idx/${TOTAL_LIVE})"
        log_entry "Probing: $IP ($probe_idx/${TOTAL_LIVE}, ${pct}%)"
        SID=$(START_SPINNER "${pct}% — ${IP} ($probe_idx/${TOTAL_LIVE})...")

        local HOST_HAD_FIND=0

        for PORT in $ALL_PORTS; do
            probe_openclaw "$IP" "$PORT" || continue

            if [ $PROBE_CONFIRMED -eq 1 ]; then
                # ── Confirmed find ────────────────────────────────
                STOP_SPINNER "$SID"

                led_found
                ringtone_found
                vibrate_strong

                LOG green "✦ FOUND: ${IP}:${PORT} (${PROBE_SCHEME})"
                LOG green "  ${PROBE_BANNER}"
                [ -n "$PROBE_DETAIL" ] && LOG "  ${PROBE_DETAIL:0:55}"

                log_found "${IP}:${PORT} | ${PROBE_SCHEME} | HTTP ${PROBE_HTTP_CODE} | ${PROBE_BANNER}"
                [ -n "$PROBE_DETAIL" ] && log_entry "  Detail: ${PROBE_DETAIL}"

                FOUND_HOSTS+=("${IP}:${PORT}")
                FOUND_DETAILS+=("${PROBE_SCHEME}:// | ${PROBE_BANNER} | ${PROBE_DETAIL}")
                FOUND_COUNT=$((FOUND_COUNT + 1))
                HOST_HAD_FIND=1

                # ALERT pauses scan — user must acknowledge before continuing
                ALERT "✦ OpenClaw Found!\n${IP}:${PORT} (${PROBE_SCHEME})\n${PROBE_BANNER}\n${PROBE_DETAIL:0:80}\nPress any key to resume scan"

                led_scanning
                SID=$(START_SPINNER "${pct}% — ${IP} ($probe_idx/${TOTAL_LIVE})...")

            elif [ $PROBE_CANDIDATE -eq 1 ]; then
                # ── Candidate: port open, unconfirmed ─────────────
                STOP_SPINNER "$SID"

                led_candidate
                ringtone_candidate
                vibrate_soft

                LOG blue "? Open: ${IP}:${PORT} (HTTP ${PROBE_HTTP_CODE}, ${PROBE_SCHEME})"
                log_candidate "${IP}:${PORT} | ${PROBE_SCHEME} | HTTP ${PROBE_HTTP_CODE}"

                sleep 1
                led_scanning
                SID=$(START_SPINNER "${pct}% — ${IP} ($probe_idx/${TOTAL_LIVE})...")
            fi
        done

        [ $HOST_HAD_FIND -eq 1 ] && log_entry "  └─ OpenClaw confirmed on $IP"
    done

    STOP_SPINNER "$SID"

    # ── Abort handling ────────────────────────────────────────────
    if [ $ABORT -eq 1 ]; then
        ringtone_abort
        LOG red "Scan aborted"
        log_entry "SCAN ABORTED BY USER"
    fi

    # ── Feature 11: diff vs previous scans ───────────────────────
    run_diff

    # ── Write log footer ──────────────────────────────────────────
    {
        echo ""
        echo "=================================================="
        echo "SUMMARY"
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
        printf "  Log: %s\n" "$LOG_FILE"
        echo "=================================================="
    } >> "$LOG_FILE"

    # ── Results summary screen ────────────────────────────────────
    if [ $FOUND_COUNT -gt 0 ]; then
        led_complete_ok
        ringtone_complete_ok
        vibrate_strong
        LOG green "Complete!"
        LOG green "Found: $FOUND_COUNT OpenClaw"
        LOG blue  "Scanned: $HOSTS_SCANNED hosts"
    else
        led_complete_none
        ringtone_complete_none
        LOG blue "Complete — none found"
        LOG blue "Scanned: $HOSTS_SCANNED hosts"
    fi
    sleep 1

    # ── Results browser ───────────────────────────────────────────
    show_results_browser

    LOG blue "Log: $LOG_FILE"
    sleep 1
}

# =============================================================================
# MAIN ORCHESTRATION
# =============================================================================

# ── Banner (startup ringtone always plays — before silent mode is set) ────────
LOG blue "  ✦ CLAWHunter v${PAYLOAD_VERSION}"
LOG      "  OpenClaw Discovery"
LOG blue "  WiFi Pineapple Pager"
sleep 1
ringtone_start
sleep 1

# ── Feature 11: history check at startup ─────────────────────────────────────
# If previous scan logs exist, offer to browse them instead of starting a scan.
prev_count=$(find "$LOOT_BASE" -name 'scan_*.log' 2>/dev/null | wc -l)
if [ "$prev_count" -gt 0 ]; then
    resp=$(CONFIRMATION_DIALOG "View scan history?" "${prev_count} previous scan(s) found. YES = browse history, NO = new scan")
    case "$resp" in
        $DUCKYSCRIPT_USER_CONFIRMED)
            show_history
            exit 0
            ;;
    esac
fi

# ── Feature 1: silent mode ────────────────────────────────────────────────────
resp=$(CONFIRMATION_DIALOG "Silent mode?" "YES = suppress all audio and vibration (covert ops)")
case "$resp" in $DUCKYSCRIPT_USER_CONFIRMED) SILENT=1 ;; esac

# ── Feature 9: WiFi client mode ───────────────────────────────────────────────
# If Pager launched from Recon with an AP selected, offer to connect to it.
# Otherwise, offer a manual SSID/password flow.
resp=$(CONFIRMATION_DIALOG "Connect to AP first?" "Use Pager client mode: connect to AP, then auto-scan its subnet")
case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED)
        # Prefer Recon-selected AP vars if available
        SSID="${_RECON_SELECTED_AP_SSID:-}"
        ENC="${_RECON_SELECTED_AP_ENCRYPTION_TYPE:-}"

        if [ -z "$SSID" ]; then
            SSID=$(TEXT_PICKER "AP SSID" "")
            case $? in
                $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
                    LOG red "Cancelled"
                    exit $DUCKYSCRIPT_CANCELLED
                    ;;
            esac
        fi

        PASS=""
        ENC_LC=$(echo "${ENC:-open}" | tr '[:upper:]' '[:lower:]')
        if ! echo "$ENC_LC" | grep -qE '^(open|none|)$'; then
            PASS=$(TEXT_PICKER "Password for: $SSID" "")
            case $? in
                $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
                    LOG red "Cancelled"
                    exit $DUCKYSCRIPT_CANCELLED
                    ;;
            esac
        fi

        LOG blue "Connecting to $SSID..."
        led_wifi_connect
        SID=$(START_SPINNER "Connecting to ${SSID}...")

        if [ -z "$PASS" ]; then
            WIFI_CONNECT "$WIFI_IF" "$SSID" "open" "" "ANY" &>/dev/null
        else
            WIFI_CONNECT "$WIFI_IF" "$SSID" "psk2" "$PASS" "ANY" &>/dev/null
        fi

        # Wait up to 30s for a client IP
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
            ringtone_wifi_ok
            vibrate_medium
            LOG green "Connected: $LOCAL_IP"
            sleep 1
        else
            led_error
            ERROR_DIALOG "Connect Failed" "No IP on ${WIFI_IF} after 30s — check SSID and password"
            exit 1
        fi
        ;;
    *)
        # No WiFi client mode — detect local IP from routing table
        LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
        [ -z "$LOCAL_IP" ] && \
            LOCAL_IP=$(ip addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' \
                       | awk '{print $2}' | cut -d/ -f1 | head -1)
        ;;
esac

# Derive default subnet from detected IP
DEFAULT_SUBNET="192.168.1"
[ -n "$LOCAL_IP" ] && DEFAULT_SUBNET=$(echo "$LOCAL_IP" | cut -d. -f1-3)
LOG blue "Local IP: ${LOCAL_IP:-unknown}"
sleep 1

# ── Feature 10: multi-subnet loop ─────────────────────────────────────────────
# The entire scan runs inside this loop. After each scan, user can choose
# to scan another subnet without restarting the payload.

while true; do

    # ── Subnet picker ─────────────────────────────────────────────
    SUBNET=$(IP_PICKER "Target Subnet" "$DEFAULT_SUBNET")
    case $? in
        $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
            LOG red "Cancelled"
            break
            ;;
    esac

    # ── Port picker ───────────────────────────────────────────────
    TARGET_PORT=$(NUMBER_PICKER "OpenClaw Port" $OPENCLAW_DEFAULT_PORT)
    case $? in
        $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
            LOG red "Cancelled"
            break
            ;;
    esac

    # ── Advanced options (batched — one dialog gate for features 4,5,6) ──────
    WIDE_SCAN=0; EXTRA_PORTS=0; RANDOMIZE=0
    resp=$(CONFIRMATION_DIALOG "Advanced options?" "Configure port range, extended ports, randomize order")
    case "$resp" in
        $DUCKYSCRIPT_USER_CONFIRMED)
            resp=$(CONFIRMATION_DIALOG "Wide port range?" "Sweep ${OPENCLAW_RANGE_LOW}-${OPENCLAW_RANGE_HIGH} instead of port $TARGET_PORT only")
            case "$resp" in $DUCKYSCRIPT_USER_CONFIRMED) WIDE_SCAN=1 ;; esac

            resp=$(CONFIRMATION_DIALOG "Extended ports?" "Also probe 80, 443, 3000, 8080, 8443 (reverse proxies)")
            case "$resp" in $DUCKYSCRIPT_USER_CONFIRMED) EXTRA_PORTS=1 ;; esac

            resp=$(CONFIRMATION_DIALOG "Randomize scan order?" "Shuffle host list — lower IDS signature")
            case "$resp" in $DUCKYSCRIPT_USER_CONFIRMED) RANDOMIZE=1 ;; esac
            ;;
    esac

    # ── Host range ────────────────────────────────────────────────
    resp=$(CONFIRMATION_DIALOG "Full /24 scan?" "254 hosts (~90s). NO = quick scan .1-.50 (~20s)")
    case "$resp" in
        $DUCKYSCRIPT_USER_CONFIRMED) HOST_START=1; HOST_END=254 ;;
        *)                           HOST_START=1; HOST_END=50  ;;
    esac

    # ── Build deduplicated port list ──────────────────────────────
    if [ $WIDE_SCAN -eq 1 ]; then
        ALL_PORTS=$(seq $OPENCLAW_RANGE_LOW $OPENCLAW_RANGE_HIGH)
        PORT_DESC="${OPENCLAW_RANGE_LOW}-${OPENCLAW_RANGE_HIGH}"
    else
        ALL_PORTS="$TARGET_PORT"
        PORT_DESC="$TARGET_PORT"
    fi
    if [ $EXTRA_PORTS -eq 1 ]; then
        ALL_PORTS="$ALL_PORTS $EXTENDED_PORTS"
        PORT_DESC="${PORT_DESC}+ext"
    fi
    # Sort and deduplicate
    ALL_PORTS=$(echo "$ALL_PORTS" | tr ' ' '\n' | sort -n | uniq | tr '\n' ' ')

    # ── Run the scan ──────────────────────────────────────────────
    run_scan

    # ── WiFi disconnect after scan if we connected ────────────────
    if [ $WIFI_CONNECTED -eq 1 ]; then
        LOG blue "Disconnecting $WIFI_IF..."
        WIFI_DISCONNECT "$WIFI_IF" &>/dev/null || true
        WIFI_CONNECTED=0
        LOG blue "Disconnected"
        sleep 1
    fi

    # ── Feature 10: offer to scan another subnet ──────────────────
    resp=$(CONFIRMATION_DIALOG "Scan another subnet?" "Run a new scan on a different range")
    case "$resp" in
        $DUCKYSCRIPT_USER_CONFIRMED)
            DEFAULT_SUBNET="$SUBNET"    # carry last subnet as new default
            SECONDS=0                   # reset elapsed timer
            continue
            ;;
        *)
            break
            ;;
    esac

done

# ── Final exit ────────────────────────────────────────────────────────────────
PROMPT "All done — press any key to exit"
led_off
exit 0
