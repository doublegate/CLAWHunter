#!/bin/bash
# =============================================================================
# CLAWHunter — lib/common.sh
# Shared library: LED control, audio/haptic, logging, fingerprinting,
# WebSocket probe, results browser, history browser, diff.
#
# Sourced by all three payload variants:
#   payloads/user/clawhunter/payload.sh
#   payloads/recon/clawhunter/payload.sh
#   payloads/alert/clawhunter-watchdog/payload.sh
#
# VERSION: 3.0.0
# REPO:    https://github.com/doublegate/CLAWHunter
# =============================================================================

# Source Pager HAK5 commands (safe if not present — alert/recon load it too)
. /lib/hak5/commands.sh 2>/dev/null || true

# ── Constants (set in payload if not already defined) ─────────────────────────
: "${PAYLOAD_VERSION:=3.0.0}"
: "${LOOT_BASE:=/root/loot/clawhunter}"
: "${SILENT:=0}"
: "${FOUND_COUNT:=0}"
: "${LOG_FILE:=}"

mkdir -p "$LOOT_BASE"

# ── LED control ───────────────────────────────────────────────────────────────

_led() { HAK5_API_POST "system/led" "$1" >/dev/null 2>&1 || true; }

led_off() {
    _led '{"color":"custom","raw_pattern":[{"onms":100,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}
led_scanning() {
    _led '{"color":"custom","raw_pattern":[{"onms":600,"offms":400,"next":false,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,true],"4":[false,false,true]}}]}'
}
led_found() {
    _led '{"color":"custom","raw_pattern":[{"onms":120,"offms":120,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}
led_candidate() {
    _led '{"color":"custom","raw_pattern":[{"onms":250,"offms":150,"next":true,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,true],"4":[false,false,true]}},{"onms":250,"offms":150,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}
led_mdns() {
    _led '{"color":"custom","raw_pattern":[{"onms":150,"offms":100,"next":true,"rgb":{"1":[false,true,true],"2":[false,true,true],"3":[false,false,false],"4":[false,false,false]}},{"onms":150,"offms":300,"next":false,"rgb":{"1":[false,true,true],"2":[false,true,true],"3":[false,false,false],"4":[false,false,false]}}]}'
}
led_error() {
    _led '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[true,false,false],"2":[true,false,false],"3":[true,false,false],"4":[true,false,false]}}]}'
}
led_wifi_connect() {
    _led '{"color":"custom","raw_pattern":[{"onms":500,"offms":300,"next":false,"rgb":{"1":[true,true,true],"2":[true,true,true],"3":[true,true,true],"4":[true,true,true]}}]}'
}
led_complete_ok() {
    _led '{"color":"custom","raw_pattern":[{"onms":700,"offms":500,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}
led_complete_none() {
    _led '{"color":"custom","raw_pattern":[{"onms":700,"offms":500,"next":false,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,true],"4":[false,false,true]}}]}'
}
led_passive() {
    # Cyan slow pulse — passive mDNS monitoring phase
    _led '{"color":"custom","raw_pattern":[{"onms":800,"offms":600,"next":false,"rgb":{"1":[false,true,true],"2":[false,true,true],"3":[false,true,true],"4":[false,true,true]}}]}'
}
led_watchdog() {
    # Magenta slow pulse — watchdog mode sleeping between scans
    _led '{"color":"custom","raw_pattern":[{"onms":1000,"offms":800,"next":false,"rgb":{"1":[true,false,true],"2":[true,false,true],"3":[true,false,true],"4":[true,false,true]}}]}'
}

# ── Audio/haptic (all gated on $SILENT) ───────────────────────────────────────

_play()    { [ "${SILENT:-0}" -eq 0 ] || return 0; RINGTONE "$1" & }
_vibrate() { [ "${SILENT:-0}" -eq 0 ] || return 0; VIBRATE "$1"; }

vibrate_soft()   { _vibrate 150; }
vibrate_medium() { _vibrate 300; }
vibrate_strong() { _vibrate 500; }

ringtone_start()         { _play "start:d=8,o=5,b=180:c,e,g"; }
ringtone_found()         { _play "found:d=8,o=5,b=220:e,e,g,g,b,b"; }
ringtone_mdns_found()    { _play "mdns:d=8,o=5,b=200:g,b,d6"; }
ringtone_candidate()     { _play "ping:d=16,o=5,b=200:g"; }
ringtone_complete_ok()   { _play "win:d=4,o=5,b=160:c,e,g,c6"; }
ringtone_complete_none() { _play "none:d=4,o=5,b=140:g,e,c"; }
ringtone_abort()         { _play "abort:d=4,o=4,b=120:g,e"; }
ringtone_wifi_ok()       { _play "wifi:d=8,o=5,b=200:c,g,c6"; }
ringtone_watchdog_alert(){ _play "wdog:d=4,o=5,b=160:c,e,g,e,c6"; }

# ── Logging helpers ───────────────────────────────────────────────────────────

log_entry()     { [ -n "$LOG_FILE" ] && printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1" >> "$LOG_FILE"; }
log_found()     { [ -n "$LOG_FILE" ] && printf "[FOUND]     %s\n" "$1" >> "$LOG_FILE"; }
log_candidate() { [ -n "$LOG_FILE" ] && printf "[CANDIDATE] %s\n" "$1" >> "$LOG_FILE"; }
log_mdns()      { [ -n "$LOG_FILE" ] && printf "[MDNS]      %s\n" "$1" >> "$LOG_FILE"; }
log_section()   { [ -n "$LOG_FILE" ] && printf "\n── %s ──\n" "$1" >> "$LOG_FILE"; }

# ── A1: WebSocket probe ───────────────────────────────────────────────────────
# Sends a raw WS upgrade request via /dev/tcp. A genuine OpenClaw gateway
# accepts the WS upgrade (HTTP 101) even without auth before closing.
# A non-OpenClaw HTTP server fails the upgrade entirely.
# Returns 0 (true) if WS upgrade accepted, 1 if not.
#
# Usage: ws_probe <ip> <port>

ws_probe() {
    local ip="$1" port="$2"
    local WS_REQ="GET / HTTP/1.1\r\nHost: ${ip}:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    local resp=""

    # Try /dev/tcp first (no subprocess overhead) — may be disabled in some OpenWRT bash builds
    if [ -e /dev/tcp ] || (exec 3<>/dev/tcp/127.0.0.1/1 2>/dev/null); then
        resp=$(timeout 3 bash -c "
            exec 3<>/dev/tcp/${ip}/${port} 2>/dev/null || exit 1
            printf '${WS_REQ}' >&3
            timeout 2 cat <&3 2>/dev/null
            exec 3>&-
        " 2>/dev/null)
    fi

    # Fallback: nc (always available on the Pager — used by v2.x already)
    if [ -z "$resp" ] && command -v nc >/dev/null 2>&1; then
        resp=$(printf "${WS_REQ}" | nc -w 3 "$ip" "$port" 2>/dev/null)
    fi

    echo "$resp" | grep -qi '101 switching\|sec-websocket-accept'
}

# ── A2 + A3 + Stage 3: Deep fingerprint ──────────────────────────────────────
# Called after PROBE_CONFIRMED=1.
# A2: probes /__openclaw__/canvas/ and /__openclaw__/a2ui/ (OpenClaw-unique paths)
# A3: probes /agent/status?session=agent:main:main for runtime intelligence
# Also probes /health /status etc. for version and persona.
# Populates: PROBE_DETAIL, PROBE_CANVAS_CONFIRMED, PROBE_WS_CONFIRMED,
#            PROBE_AGENT_MODEL, PROBE_AGENT_CONTEXT_PCT, PROBE_AGENT_UPTIME,
#            PROBE_AGENT_TOOLS, PROBE_AGENT_SUBAGENTS

deep_fingerprint() {
    local ip="$1" port="$2" scheme="$3"
    PROBE_DETAIL=""
    PROBE_CANVAS_CONFIRMED=0
    PROBE_AGENT_MODEL=""
    PROBE_AGENT_CONTEXT_PCT=""
    PROBE_AGENT_UPTIME=""
    PROBE_AGENT_TOOLS=""
    PROBE_AGENT_SUBAGENTS=""

    # ── Headers ───────────────────────────────────────────────────────────────
    local headers
    headers=$(curl -sI \
        --max-time 3 --connect-timeout 2 -k \
        -H "User-Agent: CLAWHunter/${PAYLOAD_VERSION}" \
        "${scheme}://${ip}:${port}/" 2>/dev/null)

    local server x_powered_by
    server=$(echo       "$headers" | grep -i '^server:'       | cut -d: -f2- | tr -d ' \r\n' | cut -c1-40)
    x_powered_by=$(echo "$headers" | grep -i '^x-powered-by:' | cut -d: -f2- | tr -d ' \r\n' | cut -c1-40)

    # ── A2: Canvas path probe ─────────────────────────────────────────────────
    # /__openclaw__/canvas/ and /__openclaw__/a2ui/ are unique to OpenClaw.
    # Any non-000 HTTP response (200, 301, 401, 403) = near-certain confirmation.
    local canvas_code a2ui_code
    canvas_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 2 --connect-timeout 1 -k \
        -H "User-Agent: CLAWHunter/${PAYLOAD_VERSION}" \
        "${scheme}://${ip}:${port}/__openclaw__/canvas/" 2>/dev/null)
    a2ui_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 2 --connect-timeout 1 -k \
        -H "User-Agent: CLAWHunter/${PAYLOAD_VERSION}" \
        "${scheme}://${ip}:${port}/__openclaw__/a2ui/" 2>/dev/null)

    if [ -n "$canvas_code" ] && [ "$canvas_code" != "000" ] && [ "$canvas_code" != "404" ]; then
        PROBE_CANVAS_CONFIRMED=1
        log_entry "  A2: canvas path HTTP ${canvas_code} — OpenClaw-unique path confirmed"
    fi
    if [ -n "$a2ui_code" ] && [ "$a2ui_code" != "000" ] && [ "$a2ui_code" != "404" ]; then
        PROBE_CANVAS_CONFIRMED=1
        log_entry "  A2: a2ui path HTTP ${a2ui_code} — OpenClaw-unique path confirmed"
    fi

    # ── A3: /agent/status structured intel ───────────────────────────────────
    # Proposed in GitHub issue #6418 — probe and extract runtime intelligence.
    # Parse with grep/sed only — no jq dependency.
    local agent_status_body
    agent_status_body=$(curl -s \
        --max-time 3 --connect-timeout 2 -k \
        -H "User-Agent: CLAWHunter/${PAYLOAD_VERSION}" \
        "${scheme}://${ip}:${port}/agent/status?session=agent:main:main" 2>/dev/null)

    if [ -n "$agent_status_body" ]; then
        PROBE_AGENT_MODEL=$(echo "$agent_status_body" \
            | grep -oE '"model"\s*:\s*"[^"]{1,60}"' | head -1 \
            | sed 's/.*: *"//;s/"//')
        PROBE_AGENT_CONTEXT_PCT=$(echo "$agent_status_body" \
            | grep -oE '"percent"\s*:\s*[0-9.]+' | head -1 \
            | grep -oE '[0-9.]+$')
        # uptime: extract gatewayStarted or sessionCreated timestamp
        PROBE_AGENT_UPTIME=$(echo "$agent_status_body" \
            | grep -oE '"gatewayStarted"\s*:\s*"[^"]{1,40}"' | head -1 \
            | sed 's/.*: *"//;s/"//')
        # activeToolCalls: count items in array
        PROBE_AGENT_TOOLS=$(echo "$agent_status_body" \
            | grep -oE '"activeToolCalls"\s*:\s*\[[^]]*\]' | head -1 \
            | grep -oE '"[^"]+":' | wc -l | tr -d ' ')
        # subAgents: count items
        PROBE_AGENT_SUBAGENTS=$(echo "$agent_status_body" \
            | grep -oE '"subAgents"\s*:\s*\[[^]]*\]' | head -1 \
            | grep -oE '\{' | wc -l | tr -d ' ')

        if [ -n "$PROBE_AGENT_MODEL" ]; then
            log_entry "  A3: model=${PROBE_AGENT_MODEL} ctx=${PROBE_AGENT_CONTEXT_PCT}% tools=${PROBE_AGENT_TOOLS} subagents=${PROBE_AGENT_SUBAGENTS}"
        fi
    fi

    # ── Version and persona from standard endpoints ───────────────────────────
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

    # ── Assemble PROBE_DETAIL string ──────────────────────────────────────────
    local -a parts=()
    [ -n "$server"               ] && parts+=("Server: $server")
    [ -n "$x_powered_by"         ] && parts+=("X-Powered-By: $x_powered_by")
    [ -n "$version"              ] && parts+=("Version: $version")
    [ -n "$persona"              ] && parts+=("Persona: $persona")
    [ -n "$PROBE_AGENT_MODEL"    ] && parts+=("Model: $PROBE_AGENT_MODEL")
    [ -n "$PROBE_AGENT_CONTEXT_PCT" ] && parts+=("Ctx: ${PROBE_AGENT_CONTEXT_PCT}%")
    [ "$PROBE_CANVAS_CONFIRMED" -eq 1 ] && parts+=("Canvas: confirmed")
    [ "${PROBE_WS_CONFIRMED:-0}" -eq 1 ] && parts+=("WS: confirmed")

    if [ ${#parts[@]} -gt 0 ]; then
        local IFS="|"; PROBE_DETAIL="${parts[*]}"
        IFS=$' \t\n'
    else
        PROBE_DETAIL="No additional intel from headers/endpoints"
    fi
}

# ── Features 5+6: Port probe with HTTPS + extended ports ─────────────────────
# Stage 1: nc TCP check.
# Stage 2: curl HTTP/HTTPS probe.
# Stage 3: deep_fingerprint on confirmed finds.
# v3 addition: ws_probe (A1) on confirmed finds for WS confirmation.
#
# Sets: PROBE_CONFIRMED, PROBE_CANDIDATE, PROBE_HTTP_CODE,
#       PROBE_BANNER, PROBE_SCHEME, PROBE_DETAIL, PROBE_WS_CONFIRMED,
#       PROBE_CANVAS_CONFIRMED

probe_openclaw() {
    local ip="$1" port="$2"
    PROBE_CONFIRMED=0
    PROBE_CANDIDATE=0
    PROBE_HTTP_CODE=""
    PROBE_BANNER=""
    PROBE_SCHEME=""
    PROBE_DETAIL=""
    PROBE_WS_CONFIRMED=0
    PROBE_CANVAS_CONFIRMED=0

    # Stage 1: fast TCP connect
    nc -z -w 1 "$ip" "$port" 2>/dev/null || return 1

    # Stage 2: HTTP then HTTPS
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

        if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
            PROBE_CANDIDATE=1
            PROBE_HTTP_CODE="$http_code"
            PROBE_SCHEME="$scheme"

            # Keyword match in body
            if echo "$body_lower" | grep -qE 'openclaw|clawd|gateway'; then
                PROBE_CONFIRMED=1
                PROBE_BANNER=$(echo "$body" \
                    | grep -ioE '(openclaw|clawd)[^"<]{0,50}' | head -1 | tr -d '\n')
                [ -z "$PROBE_BANNER" ] && PROBE_BANNER="keyword match in body (${scheme})"
                # A1: WebSocket upgrade probe
                if ws_probe "$ip" "$port"; then
                    PROBE_WS_CONFIRMED=1
                    log_entry "  A1: WebSocket upgrade accepted — protocol-layer confirmed"
                fi
                deep_fingerprint "$ip" "$port" "$scheme"
                return 0
            fi

            # Auth rejection on primary target port
            if [ "${TARGET_PORT:-18790}" -eq "$port" ] \
               && echo "$http_code" | grep -qE '^(400|401|403)$'; then
                PROBE_CONFIRMED=1
                PROBE_BANNER="HTTP ${http_code} on ${scheme}:// — token-gated gateway"
                # A1: WebSocket upgrade probe
                if ws_probe "$ip" "$port"; then
                    PROBE_WS_CONFIRMED=1
                    log_entry "  A1: WebSocket upgrade accepted — protocol-layer confirmed"
                fi
                deep_fingerprint "$ip" "$port" "$scheme"
                return 0
            fi

            return 0
        fi
    done

    return 0
}

# ── C1: Continuous mDNS monitor ───────────────────────────────────────────────
# Monitors mDNS for a configurable dwell period (default 30s).
# Shows a countdown on screen. LED pulses cyan during monitoring.
# Returns 0 if any hits found; populates FOUND_HOSTS/FOUND_DETAILS/FOUND_COUNT.

mdns_monitor() {
    local dwell="${1:-30}"
    log_section "mDNS MONITOR (${dwell}s)"
    LOG blue "mDNS monitoring (${dwell}s)..."
    led_passive

    local hit_count=0
    local tmp_fifo
    tmp_fifo=$(mktemp -u /tmp/clawhunter_mdns_XXXXXX)
    mkfifo "$tmp_fifo"

    # Run avahi-browse continuously in background, write to fifo
    timeout "$dwell" avahi-browse -a -r -p 2>/dev/null > "$tmp_fifo" &
    local avahi_pid=$!

    local start_ts
    start_ts=$(date +%s)

    # Read from fifo while countdown runs
    while true; do
        local now
        now=$(date +%s)
        local elapsed=$(( now - start_ts ))
        local remaining=$(( dwell - elapsed ))
        [ $remaining -le 0 ] && break

        # Non-blocking read from fifo (1s timeout)
        if IFS= read -r -t 1 line < "$tmp_fifo" 2>/dev/null; then
            if echo "$line" | grep -iqE 'openclaw|clawd'; then
                local mdns_ip
                mdns_ip=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
                if [ -n "$mdns_ip" ]; then
                    led_mdns
                    ringtone_mdns_found
                    vibrate_medium
                    LOG green "mDNS: $mdns_ip"
                    log_mdns "${mdns_ip} | record: $(echo "$line" | cut -c1-80)"

                    # Add to found list if not already there
                    local already=0
                    for h in "${FOUND_HOSTS[@]:-}"; do
                        [ "${h%%:*}" = "$mdns_ip" ] && already=1 && break
                    done
                    if [ $already -eq 0 ]; then
                        FOUND_HOSTS+=("${mdns_ip}:mDNS")
                        FOUND_DETAILS+=("mDNS discovery — service record match")
                        FOUND_COUNT=$((FOUND_COUNT + 1))
                        hit_count=$((hit_count + 1))
                        ALERT "mDNS Find!\n${mdns_ip}\nPress any key to continue"
                    fi
                fi
            fi
        fi

        # Update countdown display
        LOG blue "mDNS: ${remaining}s remaining..."
    done

    kill "$avahi_pid" 2>/dev/null || true
    wait "$avahi_pid" 2>/dev/null || true
    rm -f "$tmp_fifo"

    if [ $hit_count -eq 0 ]; then
        LOG blue "mDNS: no OpenClaw services found"
        log_entry "mDNS monitor: no matches (${dwell}s)"
    else
        LOG green "mDNS: $hit_count find(s)"
    fi

    return $([ $hit_count -gt 0 ] && echo 0 || echo 1)
}

# Legacy one-shot mDNS prescan (used by recon + alert variants for speed)
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
        led_mdns; ringtone_mdns_found; vibrate_medium
        LOG green "mDNS: OpenClaw service found!"
        log_mdns "Raw: $results"

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

        ALERT "mDNS Find!\n${results:0:120}\nPress any key to continue"
    else
        LOG blue "mDNS: no OpenClaw services"
        log_entry "mDNS: no matches found"
        sleep 1
    fi
}

# ── C2: ARP cache harvest ─────────────────────────────────────────────────────
# Checks /proc/net/arp and ip neigh show for already-known hosts on the target
# subnet. Returns them on stdout; discovered hosts skip the full ARP discovery.
# Usage: arp_cache_harvest <subnet_prefix>  (e.g. "192.168.4")

arp_cache_harvest() {
    local subnet="$1"
    {
        # /proc/net/arp
        awk -v sub="$subnet" 'NR>1 && $1 ~ "^"sub"\." && $4 != "00:00:00:00:00:00" { print $1 }' \
            /proc/net/arp 2>/dev/null

        # ip neigh show (also catches IPv4 neigh not in arp table)
        ip neigh show 2>/dev/null \
            | awk -v sub="$subnet" '$1 ~ "^"sub"\." && $NF !~ "FAILED" { print $1 }'
    } | sort -u -t. -k4 -n
}

# ── Feature 3: ARP host discovery ─────────────────────────────────────────────

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

    for i in $(seq "$start" "$end"); do
        ping -c 1 -W 1 "${subnet}.${i}" &>/dev/null && echo "${subnet}.${i}"
    done
}

# ── D1: JSON report writer ────────────────────────────────────────────────────
# Writes a machine-readable JSON summary after each scan.
# No jq dependency — uses printf/echo for construction.
# Usage: write_json_report <scan_id> <subnet> <hosts_scanned> <elapsed>

write_json_report() {
    local scan_id="$1" subnet="$2" hosts_scanned="$3" elapsed="$4"
    local json_file="${LOOT_BASE}/scan_${scan_id}.json"

    {
        printf '{\n'
        printf '  "scan_id": "%s",\n'           "$scan_id"
        printf '  "payload_version": "%s",\n'   "$PAYLOAD_VERSION"
        printf '  "subnet": "%s",\n'             "$subnet"
        printf '  "hosts_scanned": %d,\n'        "$hosts_scanned"
        printf '  "elapsed_seconds": %d,\n'      "$elapsed"
        printf '  "timestamp": "%s",\n'          "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '  "instances": [\n'

        local count=${#FOUND_HOSTS[@]}
        local i=0
        for h in "${FOUND_HOSTS[@]:-}"; do
            local detail="${FOUND_DETAILS[$i]:-}"
            local host_ip="${h%%:*}"
            local host_port="${h##*:}"
            local comma=""
            [ $((i + 1)) -lt "$count" ] && comma=","

            # Parse detail fields (pipe-delimited from deep_fingerprint)
            local ver="" persona="" model="" ctx="" canvas="" ws=""
            ver=$(    echo "$detail" | grep -oE 'Version: [^|]+' | sed 's/Version: //')
            persona=$(echo "$detail" | grep -oE 'Persona: [^|]+' | sed 's/Persona: //')
            model=$(  echo "$detail" | grep -oE 'Model: [^|]+'   | sed 's/Model: //')
            ctx=$(    echo "$detail" | grep -oE 'Ctx: [^|]+'     | sed 's/Ctx: //')
            canvas=$( echo "$detail" | grep -oE 'Canvas: [^|]+'  | sed 's/Canvas: //')
            ws=$(     echo "$detail" | grep -oE 'WS: [^|]+'      | sed 's/WS: //')

            printf '    {\n'
            printf '      "ip": "%s",\n'               "$host_ip"
            printf '      "port": "%s",\n'             "$host_port"
            printf '      "detail": "%s",\n'           "$(echo "$detail" | tr '"' "'")"
            printf '      "fingerprint": {\n'
            printf '        "version": "%s",\n'        "$ver"
            printf '        "persona": "%s",\n'        "$persona"
            printf '        "model": "%s",\n'          "$model"
            printf '        "context_percent": "%s",\n' "$ctx"
            printf '        "canvas_confirmed": %s,\n' "$([ "$canvas" = "confirmed" ] && echo true || echo false)"
            printf '        "websocket_confirmed": %s\n' "$([ "$ws" = "confirmed" ] && echo true || echo false)"
            printf '      }\n'
            printf '    }%s\n' "$comma"

            i=$((i + 1))
        done

        printf '  ]\n'
        printf '}\n'
    } > "$json_file"

    log_entry "JSON report: $json_file"
}

# ── Feature 11: Cross-run history browser ─────────────────────────────────────

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

# ── Feature 11: Diff vs previous scans ────────────────────────────────────────

run_diff() {
    [ "${#FOUND_HOSTS[@]}" -eq 0 ] && return

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

    [ ${#prev_seen[@]} -eq 0 ] && return

    local new_count=0 gone_count=0

    for h in "${FOUND_HOSTS[@]}"; do
        [[ "$h" == *"mDNS"* ]] && continue
        if [ -z "${prev_seen[$h]+_}" ]; then
            new_count=$((new_count + 1))
            log_entry "DIFF NEW: $h"
        fi
    done

    declare -A current_set=()
    for h in "${FOUND_HOSTS[@]}"; do current_set["$h"]=1; done

    for prev_h in "${!prev_seen[@]}"; do
        local prev_sub
        prev_sub=$(echo "$prev_h" | cut -d. -f1-3)
        [ "$prev_sub" = "${SUBNET:-}" ] || continue
        if [ -z "${current_set[$prev_h]+_}" ]; then
            gone_count=$((gone_count + 1))
            log_entry "DIFF GONE: $prev_h"
        fi
    done

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

show_results_browser() {
    [ "${FOUND_COUNT:-0}" -eq 0 ] && return
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
