#!/bin/bash
# Title: CLAWHunter
# Description: Discover and exploit OpenClaw AI gateway instances on local networks. Full interactive experience with mDNS monitor, ARP discovery, WebSocket fingerprinting, scan speed profiles, watchdog mode, and integrated post-exploitation harvest engine.
# Author: doublegate
# =============================================================================
# CLAWHunter — OpenClaw Instance Discovery Payload (User / Interactive)
# For the Hak5 WiFi Pineapple Pager (480×222 px, 16-bit color, 221 PPI)
# =============================================================================
#
# PAYLOAD_VERSION: 3.2.0  (IPv6 candidates, scan resume/checkpoint, watchdog state)
# AUTHOR:  doublegate
# REPO:    https://github.com/doublegate/CLAWHunter
#
# FEATURES (v2.1.0 — all preserved):
#   1. Silent mode              — suppress all audio/haptic for covert ops
#   2. Progress counter         — live % in spinner + host index tracking
#   3. ARP host discovery       — Layer-2 host detection, ping fallback
#   4. Randomized scan order    — shuf() host list to reduce IDS signature
#   5. HTTPS probe              — try http:// then https:// per open port
#   6. Extended ports           — optionally sweep 80, 443, 3000, 8080, 8443
#   7. mDNS pre-scan            — avahi-browse zero-probe finds before scan
#   8. Deep fingerprinting      — headers, /health, /status, version/persona
#   9. WiFi client mode         — WIFI_CONNECT to target AP, auto-scan
#  10. Multiple subnet sweep    — loop after each scan for another subnet
#  11. Cross-run history/diff   — browse past finds, diff new/gone vs history
#
# FEATURES (v3.0.0 — new):
#   A1. WebSocket probe         — protocol-layer WS upgrade confirmation (~99%)
#   A2. Canvas path probe       — /__openclaw__/canvas/ + /__openclaw__/a2ui/
#   A3. /agent/status intel     — model, context%, tools, subagents, uptime
#   C1. Continuous mDNS monitor — timed loop with countdown (default 30s)
#   C2. ARP cache harvest       — /proc/net/arp + ip neigh before ARP scan
#   D1. JSON report output      — structured JSON alongside .log files
#   E1. MAC randomization       — randomize scanner MAC, restore on exit
#   F4. Scan speed profiles     — GHOST/QUIET/NORMAL/FAST/AGGRESSIVE
#   F5. Watchdog mode           — periodic rescan, alert on changes
#
# DEPLOY:
#   scp -r payloads/user/clawhunter lib \
#       root@pineapple.lan:/root/payloads/user/
#
# LOG OUTPUT:
#   /root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log
#   /root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.json
# =============================================================================

readonly PAYLOAD_VERSION="3.2.0"
readonly OPENCLAW_DEFAULT_PORT=18790
readonly OPENCLAW_RANGE_LOW=18780
readonly OPENCLAW_RANGE_HIGH=18800
readonly EXTENDED_PORTS="80 443 3000 8080 8443"
readonly LOOT_BASE="/root/loot/clawhunter"
readonly WIFI_IF="wlan0cli"

# ── Out-of-band exfil config (optional — fill in before deploying) ──────────
# EXFIL_BOT_TOKEN=""   # Telegram bot token for OOB exfil (from @BotFather)
# EXFIL_CHAT_ID=""     # Telegram chat_id to receive exfil data
# EXFIL_WEBHOOK_URL="" # Alternative: HTTPS webhook URL for OOB exfil

# Source shared library (../../lib/common.sh from this file's location)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../lib/common.sh
. "${SCRIPT_DIR}/../../lib/common.sh"

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

# v3 state
SCAN_PROFILE="NORMAL"   # GHOST | QUIET | NORMAL | FAST | AGGRESSIVE

# Timing dither — randomized inter-probe delay to reduce IDS timing signatures.
# Applied after each host probe. Values in milliseconds (base + 0..jitter).
# Set by apply_scan_profile(); overridden by --no-dither if added later.
DITHER_BASE_MS=0        # fixed floor delay (ms) between probes
DITHER_JITTER_MS=0      # additional random 0..JITTER_MS added per probe
MAC_RANDOMIZED=0
ORIG_MAC=""
SCAN_IF=""
MDNS_DWELL=30           # seconds for continuous mDNS monitor

mkdir -p "$LOOT_BASE"

# ── E1: MAC randomization helpers ─────────────────────────────────────────────

mac_randomize() {
    local iface="${1:-}"
    [ -z "$iface" ] && return 1

    # Save original MAC
    ORIG_MAC=$(ip link show "$iface" 2>/dev/null \
        | grep 'link/ether' | awk '{print $2}' | head -1)
    [ -z "$ORIG_MAC" ] && return 1
    SCAN_IF="$iface"

    local new_mac
    if command -v macchanger >/dev/null 2>&1; then
        ip link set "$iface" down 2>/dev/null
        new_mac=$(macchanger -r "$iface" 2>/dev/null | grep 'New MAC' | awk '{print $3}')
        ip link set "$iface" up 2>/dev/null
    else
        # ip link method — clear multicast bit to keep it valid unicast
        local r1 r2 r3 r4 r5 r6
        r1=$(printf '%02x' $(( (RANDOM % 256) & 0xFE )))
        r2=$(printf '%02x' $((RANDOM % 256)))
        r3=$(printf '%02x' $((RANDOM % 256)))
        r4=$(printf '%02x' $((RANDOM % 256)))
        r5=$(printf '%02x' $((RANDOM % 256)))
        r6=$(printf '%02x' $((RANDOM % 256)))
        new_mac="${r1}:${r2}:${r3}:${r4}:${r5}:${r6}"
        ip link set "$iface" down 2>/dev/null
        ip link set "$iface" address "$new_mac" 2>/dev/null
        ip link set "$iface" up 2>/dev/null
    fi

    MAC_RANDOMIZED=1
    log_entry "E1: MAC randomized on ${iface}: ${ORIG_MAC} -> ${new_mac:-random}"
    LOG blue "MAC: randomized on $iface"
}

mac_restore() {
    [ $MAC_RANDOMIZED -eq 0 ] && return
    [ -z "$ORIG_MAC" ] || [ -z "$SCAN_IF" ] && return
    ip link set "$SCAN_IF" down 2>/dev/null
    ip link set "$SCAN_IF" address "$ORIG_MAC" 2>/dev/null
    ip link set "$SCAN_IF" up 2>/dev/null
    log_entry "E1: MAC restored on ${SCAN_IF}: ${ORIG_MAC}"
    MAC_RANDOMIZED=0
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────

cleanup() {
    led_off
    mac_restore
    [ $WIFI_CONNECTED -eq 1 ] && WIFI_DISCONNECT "$WIFI_IF" &>/dev/null || true
    [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] && \
        log_entry "Payload exited (cleanup trap)"
}
trap cleanup EXIT INT TERM

# ── F4: Scan speed profile → probe delay and parallelism settings ─────────────
# Returns: sets PROBE_DELAY_MS and PARALLEL_COUNT globals.

apply_scan_profile() {
    case "$SCAN_PROFILE" in
        GHOST)
            # Passive-only — no active port probes in run_scan(); handled by caller
            PROBE_DELAY_MS=0
            PARALLEL_COUNT=1
            DITHER_BASE_MS=0
            DITHER_JITTER_MS=0
            ;;
        QUIET)
            # 50ms fixed floor + up to 200ms jitter — mimics human-paced browsing,
            # very low IDS signature even on sensitive networks
            PROBE_DELAY_MS=50
            PARALLEL_COUNT=1
            SILENT=1   # force silent mode for QUIET profile
            DITHER_BASE_MS=50
            DITHER_JITTER_MS=200
            ;;
        NORMAL)
            # No fixed floor, but 0–80ms jitter breaks the metronomic
            # timing that stateful IDS engines key on
            PROBE_DELAY_MS=0
            PARALLEL_COUNT=1
            DITHER_BASE_MS=0
            DITHER_JITTER_MS=80
            ;;
        FAST)
            # Minimal 0–25ms jitter — enough to avoid exact-interval signatures
            # without meaningfully slowing down the scan
            PROBE_DELAY_MS=0
            PARALLEL_COUNT=3
            DITHER_BASE_MS=0
            DITHER_JITTER_MS=25
            ;;
        AGGRESSIVE)
            # No dither — speed is the priority; accept the IDS risk
            PROBE_DELAY_MS=0
            PARALLEL_COUNT=5
            WIDE_SCAN=1
            EXTRA_PORTS=1
            DITHER_BASE_MS=0
            DITHER_JITTER_MS=0
            ;;
    esac
}

# ── Timing dither helper ──────────────────────────────────────────────────────
# Sleeps for DITHER_BASE_MS + a random fraction of DITHER_JITTER_MS.
# Uses $RANDOM (bash builtin, 0–32767) so no external tools needed.

apply_dither() {
    local total_ms=$DITHER_BASE_MS
    if [ "$DITHER_JITTER_MS" -gt 0 ]; then
        # $RANDOM % (JITTER+1) gives 0..JITTER_MS
        total_ms=$(( DITHER_BASE_MS + (RANDOM % (DITHER_JITTER_MS + 1)) ))
    fi
    [ "$total_ms" -gt 0 ] && sleep "0.$(printf '%03d' "$((total_ms % 1000))")"
}

# ── Core scan loop ────────────────────────────────────────────────────────────

run_scan() {
    # Reset per-scan state
    SCAN_ID="$(date +%Y%m%d_%H%M%S)"
    LOG_FILE="$LOOT_BASE/scan_${SCAN_ID}.log"
    FOUND_COUNT=0
    HOSTS_SCANNED=0
    ABORT=0
    FOUND_HOSTS=()
    FOUND_DETAILS=()

    # ── Log header ────────────────────────────────────────────────
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
        echo "Scan profile   : $SCAN_PROFILE"
        echo "MAC randomized : $([ $MAC_RANDOMIZED -eq 1 ] && echo YES || echo NO)"
        echo "ARP available  : $(command -v arp-scan >/dev/null 2>&1 && echo YES || echo NO)"
        echo "avahi available: $(command -v avahi-browse >/dev/null 2>&1 && echo YES || echo NO)"
        echo "=================================================="
        echo ""
    } > "$LOG_FILE"

    # ── C1: Continuous mDNS monitor (or one-shot prescan) ─────────
    if [ "$SCAN_PROFILE" = "GHOST" ]; then
        # GHOST profile: mDNS only, no port probes
        if command -v avahi-browse >/dev/null 2>&1; then
            mdns_monitor "$MDNS_DWELL"
        else
            LOG blue "avahi not available — GHOST mode limited"
            log_entry "avahi-browse not found; GHOST mode skipped mDNS"
        fi
        # Also check ARP cache (C2) for immediate targets
        LOG blue "ARP cache harvest..."
        local cache_hosts
        cache_hosts=$(arp_cache_harvest "$SUBNET")
        if [ -n "$cache_hosts" ]; then
            LOG blue "Cache: $(echo "$cache_hosts" | wc -l) known host(s)"
            log_entry "C2: ARP cache yielded $(echo "$cache_hosts" | wc -l) host(s)"
        fi
    else
        # All other profiles: continuous mDNS monitor
        if command -v avahi-browse >/dev/null 2>&1; then
            mdns_monitor "$MDNS_DWELL"
        else
            LOG blue "mDNS: avahi not available"
        fi
    fi

    # GHOST profile exits after passive discovery
    if [ "$SCAN_PROFILE" = "GHOST" ]; then
        log_entry "GHOST profile: passive-only scan complete"
    else
        log_section "PORT SCAN"
        _run_port_scan
    fi

    # ── D1: JSON report ───────────────────────────────────────────
    write_json_report "$SCAN_ID" "${SUBNET}.${HOST_START}-${HOST_END}" "$HOSTS_SCANNED" "$SECONDS"

    # ── Diff vs previous scans ────────────────────────────────────
    run_diff

    # ── Log footer ────────────────────────────────────────────────
    {
        echo ""
        echo "=================================================="
        echo "SUMMARY"
        printf "  Hosts scanned  : %d\n" "$HOSTS_SCANNED"
        printf "  OpenClaw found : %d\n" "$FOUND_COUNT"
        printf "  Elapsed        : %ds\n" "$SECONDS"
        printf "  Status         : %s\n" \
            "$([ $ABORT -eq 1 ] && echo ABORTED || echo COMPLETE)"
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

    # ── Results summary ───────────────────────────────────────────
    if [ $FOUND_COUNT -gt 0 ]; then
        led_complete_ok; ringtone_complete_ok; vibrate_strong
        LOG green "Complete!"
        LOG green "Found: $FOUND_COUNT OpenClaw"
        LOG blue  "Scanned: $HOSTS_SCANNED hosts"
    else
        led_complete_none; ringtone_complete_none
        LOG blue "Complete — none found"
        LOG blue "Scanned: $HOSTS_SCANNED hosts"
    fi
    sleep 1

    show_results_browser

    LOG blue "Log: $LOG_FILE"
    sleep 1
}

# ── Active port scan (inner loop) — called from run_scan() ───────────────────
_run_port_scan() {
    # ── Scan resume checkpoint setup ──────────────────────────────
    local CHECKPOINT_FILE="/tmp/clawhunter_checkpoint_${SUBNET//./_}"
    declare -A _scanned_set=()
    if [ -f "$CHECKPOINT_FILE" ]; then
        local _skip_count=0
        while IFS= read -r _h; do
            [ -n "$_h" ] && { _scanned_set["$_h"]=1; _skip_count=$((_skip_count + 1)); }
        done < "$CHECKPOINT_FILE"
        if [ "$_skip_count" -gt 0 ]; then
            LOG blue "Resume: skipping $_skip_count already-scanned hosts"
            log_entry "Checkpoint: resuming scan — skipping $_skip_count hosts from ${CHECKPOINT_FILE}"
        fi
    fi

    # ── C2: ARP cache harvest before full discovery ────────────────
    LOG blue "Checking ARP cache..."
    local cache_hosts
    cache_hosts=$(arp_cache_harvest "$SUBNET" 2>/dev/null)
    local cache_count=0
    if [ -n "$cache_hosts" ]; then
        cache_count=$(echo "$cache_hosts" | wc -l)
        LOG blue "Cache: $cache_count host(s) pre-known"
        log_entry "C2: ARP cache harvest: $cache_count host(s)"
    fi

    # ── ARP host discovery ─────────────────────────────────────────
    LOG blue "Discovering hosts..."
    local SID
    SID=$(START_SPINNER "ARP host discovery...")

    local raw_hosts=""
    raw_hosts=$(arp_discover_hosts "$SUBNET" "$HOST_START" "$HOST_END" 2>/dev/null)

    # Merge cache hosts with discovered hosts, deduplicate
    if [ -n "$cache_hosts" ]; then
        raw_hosts=$(printf '%s\n%s\n' "$cache_hosts" "$raw_hosts" \
            | sort -u -t. -k4 -n)
    fi

    STOP_SPINNER "$SID"

    # ── Randomize ──────────────────────────────────────────────────
    if [ $RANDOMIZE -eq 1 ] && [ -n "$raw_hosts" ]; then
        raw_hosts=$(echo "$raw_hosts" | awk 'BEGIN{srand()} {print rand() "\t" $0}' | sort -n | cut -f2-)
        log_entry "Scan order: randomized"
    fi

    local -a LIVE_HOSTS=()
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        # IPv6 link-local: log as candidate, do not port-scan
        if echo "$h" | grep -q "^fe80"; then
            LOG blue "[IPv6] candidate: $h (manual probe required)"
            log_entry "[IPv6] ${h} — IPv6 candidate (manual probe required)"
            continue
        fi
        LIVE_HOSTS+=("$h")
    done <<< "$raw_hosts"

    local TOTAL_LIVE=${#LIVE_HOSTS[@]}
    log_entry "Host discovery: $TOTAL_LIVE live hosts"

    if [ $TOTAL_LIVE -eq 0 ]; then
        LOG red "No live hosts found"
        log_entry "No live hosts — scan complete"
        return
    fi

    LOG blue "Live hosts: $TOTAL_LIVE"
    sleep 1

    led_scanning
    SID=$(START_SPINNER "Probing (0/${TOTAL_LIVE}, 0%)...")

    local probe_idx=0

    if [ "${PARALLEL_COUNT:-1}" -gt 1 ]; then
        # FAST/AGGRESSIVE: filter checkpoint-skipped hosts before launching parallel probes
        # _scanned_set and CHECKPOINT_FILE are in scope via bash dynamic scoping
        if [ ${#_scanned_set[@]} -gt 0 ]; then
            local _filtered_parallel=()
            for _ph in "${LIVE_HOSTS[@]}"; do
                if [ -n "${_scanned_set[$_ph]+_}" ]; then
                    continue  # already scanned in a previous run
                fi
                _filtered_parallel+=("$_ph")
            done
            _run_parallel_probe "${_filtered_parallel[@]}"
        else
            _run_parallel_probe "${LIVE_HOSTS[@]}"
        fi
    else
        # NORMAL/QUIET: sequential probes
        for IP in "${LIVE_HOSTS[@]}"; do
            local btn
            btn=$(timeout 0.05 sh -c 'WAIT_FOR_INPUT 2>/dev/null' 2>/dev/null || true)
            if [ "$btn" = "B" ]; then ABORT=1; break; fi

            # Resume: skip already-scanned hosts
            if [ -n "${_scanned_set[$IP]+_}" ]; then
                continue
            fi
            # Checkpoint: record this host before probing
            echo "$IP" >> "$CHECKPOINT_FILE"

            probe_idx=$((probe_idx + 1))
            HOSTS_SCANNED=$((HOSTS_SCANNED + 1))
            local pct=$(( (probe_idx * 100) / TOTAL_LIVE ))

            STOP_SPINNER "$SID"
            LOG blue "${pct}% — $IP ($probe_idx/${TOTAL_LIVE})"
            log_entry "Probing: $IP ($probe_idx/${TOTAL_LIVE}, ${pct}%)"
            SID=$(START_SPINNER "${pct}% — ${IP} ($probe_idx/${TOTAL_LIVE})...")

            # Timing dither — randomized inter-probe delay to reduce IDS signature
            apply_dither

            local HOST_HAD_FIND=0
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
                    HOST_HAD_FIND=1

                    ALERT "✦ OpenClaw Found!\n${IP}:${PORT} (${PROBE_SCHEME})\n${PROBE_BANNER}\n${PROBE_DETAIL:0:80}\nPress any key to resume scan"

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

            [ $HOST_HAD_FIND -eq 1 ] && log_entry "  └─ OpenClaw confirmed on $IP"
        done
    fi

    STOP_SPINNER "$SID"

    if [ $ABORT -eq 1 ]; then
        ringtone_abort
        LOG red "Scan aborted"
        log_entry "SCAN ABORTED BY USER"
        # Leave checkpoint in place so next run can resume
    else
        # Clean completion — remove checkpoint
        rm -f "$CHECKPOINT_FILE"
        log_entry "Checkpoint removed: scan complete"
    fi
}

# ── F4: Parallel probe worker (FAST/AGGRESSIVE profiles) ─────────────────────
# Spawns up to PARALLEL_COUNT background probe jobs. Results written to
# tmp files and harvested after all jobs complete.

_run_parallel_probe() {
    local -a hosts=("$@")
    local total=${#hosts[@]}
    local sem_dir
    sem_dir=$(mktemp -d /tmp/clawhunter_par_XXXXXX)
    local results_dir="${sem_dir}/results"
    mkdir -p "$results_dir"
    local active=0
    local probe_idx=0

    for IP in "${hosts[@]}"; do
        local btn
        btn=$(timeout 0.05 sh -c 'WAIT_FOR_INPUT 2>/dev/null' 2>/dev/null || true)
        if [ "$btn" = "B" ]; then ABORT=1; break; fi

        # Wait for a slot
        while [ $active -ge "${PARALLEL_COUNT:-3}" ]; do
            wait -n 2>/dev/null || sleep 0.1
            active=$(jobs -p | wc -l)
        done

        # Checkpoint: record host as scanned (parallel path)
        # CHECKPOINT_FILE is in scope via bash dynamic scoping from run_scan
        [ -n "${CHECKPOINT_FILE:-}" ] && echo "$IP" >> "$CHECKPOINT_FILE"

        probe_idx=$((probe_idx + 1))
        HOSTS_SCANNED=$((HOSTS_SCANNED + 1))
        local pct=$(( (probe_idx * 100) / total ))
        LOG blue "${pct}% — $IP ($probe_idx/$total) [parallel]"
        log_entry "Probing: $IP ($probe_idx/${total}, ${pct}%) [parallel]"

        # Background worker
        {
            local result_file="${results_dir}/${IP//\./_}"
            for PORT in $ALL_PORTS; do
                probe_openclaw "$IP" "$PORT" 2>/dev/null || continue
                if [ $PROBE_CONFIRMED -eq 1 ]; then
                    printf '%s\t%s\t%s\t%s\t%s\n' \
                        "${IP}:${PORT}" "$PROBE_SCHEME" "$PROBE_BANNER" \
                        "$PROBE_DETAIL" "CONFIRMED" > "$result_file"
                    break
                elif [ $PROBE_CANDIDATE -eq 1 ]; then
                    printf '%s\t%s\t%s\t%s\t%s\n' \
                        "${IP}:${PORT}" "$PROBE_SCHEME" "$PROBE_HTTP_CODE" \
                        "" "CANDIDATE" > "$result_file"
                fi
            done
        } &

        active=$((active + 1))
    done

    # Wait for all background workers
    wait

    # Harvest results
    for result_file in "${results_dir}"/*; do
        [ -f "$result_file" ] || continue
        local host scheme banner detail status
        IFS=$'\t' read -r host scheme banner detail status < "$result_file"
        if [ "$status" = "CONFIRMED" ]; then
            led_found; ringtone_found; vibrate_strong
            LOG green "✦ FOUND: ${host} (${scheme})"
            LOG green "  ${banner}"
            [ -n "$detail" ] && LOG "  ${detail:0:55}"
            log_found "${host} | ${scheme} | ${banner}"
            FOUND_HOSTS+=("$host")
            FOUND_DETAILS+=("${scheme}:// | ${banner} | ${detail}")
            FOUND_COUNT=$((FOUND_COUNT + 1))
            ALERT "✦ OpenClaw Found!\n${host} (${scheme})\n${banner}\n${detail:0:80}\nPress any key"
        elif [ "$status" = "CANDIDATE" ]; then
            led_candidate; ringtone_candidate; vibrate_soft
            LOG blue "? Open: ${host} (HTTP ${banner}, ${scheme})"
            log_candidate "${host} | ${scheme} | HTTP ${banner}"
        fi
    done

    rm -rf "$sem_dir"
}

# ── F5: Watchdog state helpers ───────────────────────────────────────────────

_watchdog_state_file() { echo "${LOOT_BASE}/watchdog_state.json"; }

_watchdog_write_state() {
    local run_counter="$1"
    local state_file
    state_file=$(_watchdog_state_file)
    {
        printf '{\n'
        printf '  "watchdog_run": %d,\n' "$run_counter"
        printf '  "payload_version": "%s",\n' "$PAYLOAD_VERSION"
        printf '  "timestamp": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '  "instances": [\n'
        local count=${#FOUND_HOSTS[@]}
        local i=0
        for h in "${FOUND_HOSTS[@]:-}"; do
            local comma=""
            [ $((i + 1)) -lt "$count" ] && comma=","
            printf '    "%s"%s\n' "$h" "$comma"
            i=$((i + 1))
        done
        printf '  ]\n'
        printf '}\n'
    } > "$state_file"
}

_watchdog_read_state() {
    # Reads instance strings from a previous watchdog_state.json.
    # Outputs one "ip:port" string per line.
    local state_file
    state_file=$(_watchdog_state_file)
    [ -f "$state_file" ] || return
    grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[^"]*"' "$state_file" | tr -d '"'
}

# ── F5: Watchdog mode ─────────────────────────────────────────────────────────
# Rescans every N minutes. Alerts only on changes (new/gone instances).
# B-button during the sleep countdown exits watchdog.

run_watchdog() {
    local interval_min="${1:-5}"
    LOG blue "Watchdog: every ${interval_min}min"
    LOG blue "B to exit watchdog"
    log_entry "Watchdog mode started: interval=${interval_min}min"

    # Load baseline from persisted state if available (survives reboots)
    declare -A baseline=()
    local _prev_state
    _prev_state=$(_watchdog_read_state)
    if [ -n "$_prev_state" ]; then
        LOG blue "Watchdog: restoring previous state..."
        log_entry "Watchdog: loaded previous state from watchdog_state.json"
        while IFS= read -r _ph; do
            [ -n "$_ph" ] && baseline["$_ph"]=1
        done <<< "$_prev_state"
    else
        for h in "${FOUND_HOSTS[@]:-}"; do baseline["$h"]=1; done
    fi

    local watchdog_run=0

    # Write initial state
    _watchdog_write_state "$watchdog_run"

    while true; do
        led_watchdog

        # Countdown with B-button exit check
        local wait_sec=$(( interval_min * 60 ))
        local elapsed_wait=0
        while [ $elapsed_wait -lt $wait_sec ]; do
            local btn
            btn=$(timeout 1 sh -c 'WAIT_FOR_INPUT 2>/dev/null' 2>/dev/null || true)
            if [ "$btn" = "B" ]; then
                LOG blue "Watchdog: exit"
                log_entry "Watchdog exited by user"
                rm -f "$(_watchdog_state_file)"
                return
            fi
            elapsed_wait=$((elapsed_wait + 1))
            local remaining=$(( wait_sec - elapsed_wait ))
            [ $((elapsed_wait % 10)) -eq 0 ] && \
                LOG blue "Watchdog: next scan in ${remaining}s"
        done

        LOG blue "Watchdog: rescanning..."
        log_entry "Watchdog: starting rescan"
        run_scan
        watchdog_run=$((watchdog_run + 1))

        # Persist state after each scan
        _watchdog_write_state "$watchdog_run"

        # Compare with baseline
        local new_count=0 gone_count=0
        declare -A current=()
        for h in "${FOUND_HOSTS[@]:-}"; do current["$h"]=1; done

        for h in "${!current[@]}"; do
            [ -z "${baseline[$h]+_}" ] && new_count=$((new_count + 1))
        done
        for h in "${!baseline[@]}"; do
            [ -z "${current[$h]+_}" ] && gone_count=$((gone_count + 1))
        done

        if [ $new_count -gt 0 ] || [ $gone_count -gt 0 ]; then
            ringtone_watchdog_alert; vibrate_strong
            ALERT "Watchdog: CHANGE!\nNEW: $new_count  GONE: $gone_count\nPress any key"
            log_entry "Watchdog: change detected — NEW=$new_count GONE=$gone_count"
            # Update baseline and persist
            declare -A baseline=()
            for h in "${!current[@]}"; do baseline["$h"]=1; done
            _watchdog_write_state "$watchdog_run"
        else
            LOG blue "Watchdog: no changes"
            log_entry "Watchdog: no changes detected"
        fi
    done
}

# =============================================================================
# MAIN ORCHESTRATION
# =============================================================================

LOG blue "  ✦ CLAWHunter v${PAYLOAD_VERSION}"
LOG      "  OpenClaw Discovery Suite"
LOG blue "  WiFi Pineapple Pager"
sleep 1
ringtone_start
sleep 1

# ── History check ─────────────────────────────────────────────────────────────
prev_count=$(find "$LOOT_BASE" -name 'scan_*.log' 2>/dev/null | wc -l)
if [ "$prev_count" -gt 0 ]; then
    resp=$(CONFIRMATION_DIALOG "View scan history?" "${prev_count} previous scan(s). YES=browse, NO=new scan")
    case "$resp" in
        $DUCKYSCRIPT_USER_CONFIRMED)
            show_history
            exit 0
            ;;
    esac
fi

# ── Feature 1: Silent mode ────────────────────────────────────────────────────
resp=$(CONFIRMATION_DIALOG "Silent mode?" "YES = suppress all audio and vibration")
case "$resp" in $DUCKYSCRIPT_USER_CONFIRMED) SILENT=1 ;; esac

# ── E1: MAC randomization ─────────────────────────────────────────────────────
resp=$(CONFIRMATION_DIALOG "Randomize MAC?" "Change scanner MAC before scan — restored on exit")
case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED)
        # Determine interface to randomize
        local_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' | head -1)
        [ -z "$local_iface" ] && local_iface="wlan0"
        mac_randomize "$local_iface"
        ;;
esac

# ── F4: Scan speed profile picker ─────────────────────────────────────────────
LOG blue "Select scan profile:"
LOG      "  UP/DOWN=select  B=cancel"
sleep 1

profiles=("GHOST" "QUIET" "NORMAL" "FAST" "AGGRESSIVE")
profile_descs=(
    "Passive only — mDNS+ARP cache, no port probes"
    "50ms delay, silent forced, covert"
    "Default — sequential, balanced"
    "Parallel probes (3 at a time)"
    "All ports + extended + max coverage"
)
profile_idx=2  # default: NORMAL

while true; do
    LOG green "Profile: ${profiles[$profile_idx]}"
    LOG       "  ${profile_descs[$profile_idx]}"
    LOG       "  UP/DOWN=change  B=confirm"
    btn=$(WAIT_FOR_INPUT)
    case "$btn" in
        UP)   [ $profile_idx -gt 0 ] && profile_idx=$((profile_idx - 1)) ;;
        DOWN) [ $profile_idx -lt $((${#profiles[@]} - 1)) ] && profile_idx=$((profile_idx + 1)) ;;
        B)    break ;;
    esac
done

SCAN_PROFILE="${profiles[$profile_idx]}"
apply_scan_profile
LOG blue "Profile: $SCAN_PROFILE"
sleep 1

# ── Feature 9: WiFi client mode ───────────────────────────────────────────────
resp=$(CONFIRMATION_DIALOG "Connect to AP first?" "Use Pager client mode — connect, then auto-scan subnet")
case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED)
        SSID="${_RECON_SELECTED_AP_SSID:-}"
        ENC="${_RECON_SELECTED_AP_ENCRYPTION_TYPE:-}"

        # Note: WiFi client mode without Recon context requires launching from
        # Recon UI with an AP selected (_RECON_SELECTED_AP_SSID populated).
        # Manual SSID/password entry is not supported — DuckyScript has no
        # free-text picker. Connect to the target AP via the Pager's WiFi
        # settings first, then run this payload.
        if [ -z "$SSID" ]; then
            LOG red "No Recon AP selected"
            LOG blue "Launch from Recon UI"
            LOG blue "or pre-connect via Settings"
            sleep 3
            # Fall through to non-WiFi-client path
            resp=""
        fi

        PASS=""
        ENC_LC=$(echo "${ENC:-open}" | tr '[:upper:]' '[:lower:]')
        if [ -n "$SSID" ] && ! echo "$ENC_LC" | grep -qE '^(open|none|)$'; then
            # Encrypted AP — ask if password is needed (can't type it in DuckyScript)
            resp2=$(CONFIRMATION_DIALOG "AP is encrypted" "Pre-connect via Pager Settings if needed — continue anyway?")
            case "$resp2" in
                $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
                    LOG red "Cancelled"; exit $DUCKYSCRIPT_CANCELLED ;;
            esac
            # WIFI_CONNECT with empty password attempts open/saved-credential join
            PASS=""
        fi

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
            ERROR_DIALOG "Connect Failed" "No IP on ${WIFI_IF} after 30s"
            exit 1
        fi
        ;;
    *)
        LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' | head -1)
        [ -z "$LOCAL_IP" ] && \
            LOCAL_IP=$(ip addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' \
                       | awk '{print $2}' | cut -d/ -f1 | head -1)
        ;;
esac

DEFAULT_SUBNET="192.168.1"
[ -n "$LOCAL_IP" ] && DEFAULT_SUBNET=$(echo "$LOCAL_IP" | cut -d. -f1-3)
LOG blue "Local IP: ${LOCAL_IP:-unknown}"
sleep 1

# ── Feature 10: Multi-subnet loop ─────────────────────────────────────────────
while true; do

    # ── Subnet picker ──────────────────────────────────────────────
    SUBNET=$(IP_PICKER "Target Subnet" "$DEFAULT_SUBNET")
    case $? in
        $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
            LOG red "Cancelled"; break ;;
    esac

    # ── Port picker ────────────────────────────────────────────────
    TARGET_PORT=$(NUMBER_PICKER "OpenClaw Port" $OPENCLAW_DEFAULT_PORT)
    case $? in
        $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
            LOG red "Cancelled"; break ;;
    esac

    # ── Advanced options (skip for AGGRESSIVE — already set by profile) ───────
    if [ "$SCAN_PROFILE" != "AGGRESSIVE" ]; then
        WIDE_SCAN=0; EXTRA_PORTS=0; RANDOMIZE=0
        resp=$(CONFIRMATION_DIALOG "Advanced options?" "Port range, extended ports, randomize")
        case "$resp" in
            $DUCKYSCRIPT_USER_CONFIRMED)
                resp=$(CONFIRMATION_DIALOG "Wide port range?" "Sweep ${OPENCLAW_RANGE_LOW}-${OPENCLAW_RANGE_HIGH}")
                case "$resp" in $DUCKYSCRIPT_USER_CONFIRMED) WIDE_SCAN=1 ;; esac

                resp=$(CONFIRMATION_DIALOG "Extended ports?" "Also probe 80, 443, 3000, 8080, 8443")
                case "$resp" in $DUCKYSCRIPT_USER_CONFIRMED) EXTRA_PORTS=1 ;; esac

                resp=$(CONFIRMATION_DIALOG "Randomize order?" "Shuffle host list")
                case "$resp" in $DUCKYSCRIPT_USER_CONFIRMED) RANDOMIZE=1 ;; esac
                ;;
        esac
    fi

    # ── Host range ─────────────────────────────────────────────────
    if [ "$SCAN_PROFILE" != "GHOST" ]; then
        resp=$(CONFIRMATION_DIALOG "Full /24 scan?" "254 hosts (~90s). NO = quick .1-.50 (~20s)")
        case "$resp" in
            $DUCKYSCRIPT_USER_CONFIRMED) HOST_START=1; HOST_END=254 ;;
            *)                           HOST_START=1; HOST_END=50  ;;
        esac
    fi

    # ── C1: mDNS dwell time (user-configurable) ───────────────────
    if command -v avahi-browse >/dev/null 2>&1; then
        MDNS_DWELL_RAW=$(NUMBER_PICKER "mDNS dwell (sec)" 30)
        case $? in
            $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR) ;;
            *) MDNS_DWELL="$MDNS_DWELL_RAW" ;;
        esac
    fi

    # ── Build port list ────────────────────────────────────────────
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
    ALL_PORTS=$(echo "$ALL_PORTS" | tr ' ' '\n' | sort -n | uniq | tr '\n' ' ')

    # ── Run scan ───────────────────────────────────────────────────
    run_scan

    # ── F5: Offer watchdog mode after scan ─────────────────────────
    if [ $FOUND_COUNT -gt 0 ]; then
        resp=$(CONFIRMATION_DIALOG "Watchdog mode?" "Rescan periodically, alert on changes")
        case "$resp" in
            $DUCKYSCRIPT_USER_CONFIRMED)
                WDOG_INTERVAL=$(NUMBER_PICKER "Rescan interval (min)" 5)
                case $? in
                    $DUCKYSCRIPT_CANCELLED | $DUCKYSCRIPT_REJECTED | $DUCKYSCRIPT_ERROR)
                        WDOG_INTERVAL=5 ;;
                esac
                run_watchdog "$WDOG_INTERVAL"
                ;;
        esac
    fi

    # ── WiFi disconnect ────────────────────────────────────────────
    if [ $WIFI_CONNECTED -eq 1 ]; then
        LOG blue "Disconnecting $WIFI_IF..."
        WIFI_DISCONNECT "$WIFI_IF" &>/dev/null || true
        WIFI_CONNECTED=0
        LOG blue "Disconnected"
        sleep 1
    fi

    # ── Feature 10: scan another subnet? ──────────────────────────
    resp=$(CONFIRMATION_DIALOG "Scan another subnet?" "Run a new scan on a different range")
    case "$resp" in
        $DUCKYSCRIPT_USER_CONFIRMED)
            DEFAULT_SUBNET="$SUBNET"
            SECONDS=0
            continue
            ;;
        *)
            break
            ;;
    esac

done

PROMPT "All done — press any key to exit"
led_off
exit 0
