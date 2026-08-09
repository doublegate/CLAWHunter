#!/bin/bash
# Title: CLAWHunter
# Description: Discover and assess OpenClaw gateways on authorized local networks.
# Author: doublegate
# =============================================================================
# CLAWHunter — OpenClaw Instance Discovery Payload (User / Interactive)
# For the Hak5 WiFi Pineapple Pager (480×222 px, 16-bit color, 221 PPI)
# =============================================================================
#
# PAYLOAD_VERSION: 3.4.0
# AUTHOR:  doublegate
# REPO:    https://github.com/doublegate/CLAWHunter
#
# FEATURES:
#   - Evidence-scored HTTP/S and WebSocket fingerprinting
#   - Exact OpenClaw mDNS hints plus ARP/ping host discovery
#   - Sequential and parallel scan profiles with checkpoint parity
#   - JSON/log reports, history, diff, watchdog, and result browser
#   - Bounded current-protocol assessment for authorized gateways
#
# DEPLOY:
#   Use scripts/install-pager.sh from the release bundle.
#
# LOG OUTPUT:
#   /root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log
#   /root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.json
#
# INTERACTIVE CONTRACT:
#   Input  - operator-confirmed IPv4, port/profile/range, and local UI choices.
#   Work   - passive hints, bounded /24 discovery, evidence-scored port probes.
#   Output - local logs/JSON/history plus explicit confirmed-result assessment.
#   Safety - strict target validation, private temp dirs, resumable host records,
#            reversible MAC state, no staged code, and no implicit exfiltration.
# =============================================================================

readonly PAYLOAD_VERSION="3.4.0"
# Current and optional port sets are centralized here so UI labels, checkpoints,
# scan workers, and reports derive from one normalized selection.
readonly OPENCLAW_DEFAULT_PORT=18789
readonly OPENCLAW_RANGE_LOW=18780
readonly OPENCLAW_RANGE_HIGH=18800
readonly EXTENDED_PORTS="80 443 3000 8080 8443"
readonly LOOT_BASE="/root/loot/clawhunter"
readonly WIFI_IF="wlan0cli"

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
    ERROR_DIALOG "Install Error" "CLAWHunter common.sh was not found"
    exit 1
fi

# ── Runtime state (reset per scan in run_scan()) ──────────────────────────────

# Result arrays are index-aligned: FOUND_HOSTS[n] owns FOUND_DETAILS[n]. Only
# confirmed classifications may enter them; candidates remain log-only records.
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
WATCHDOG_ACTIVE=0      # suppresses blocking per-result UI during periodic scans

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
    # Input: interface name. Side effects: temporarily cycles the interface,
    # stores original address/interface globals, and arms cleanup restoration.
    local iface="${1:-}"
    [ -z "$iface" ] && return 1

    # Save original MAC before cycling the link. If state cannot be captured,
    # abort randomization so the exit trap never has to guess a restore value.
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
        # ip link fallback: clear the multicast bit. The address is temporary,
        # locally generated, and always restored by cleanup.
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
    # Idempotent exit-path restoration. Missing original state is treated as a
    # no-op so early failures cannot make cleanup itself fail recursively.
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
    # Shared EXIT/INT/TERM handler owns reversible device state. Loot is kept;
    # only LEDs, randomized MAC, and a payload-owned client connection change.
    led_off
    mac_restore
    [ $WIFI_CONNECTED -eq 1 ] && WIFI_DISCONNECT "$WIFI_IF" &>/dev/null || true
    [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] && \
        log_entry "Payload exited (cleanup trap)"
}
trap cleanup EXIT INT TERM

# ── F4: Scan speed profile → probe delay and parallelism settings ─────────────
# Returns: sets PARALLEL_COUNT and dither globals.

apply_scan_profile() {
    # Translate the operator-facing profile into worker count, dither bounds,
    # silence, and port-range flags consumed later by the scan loop.
    case "$SCAN_PROFILE" in
        GHOST)
            # Passive-only — no active port probes in run_scan(); handled by caller
            PARALLEL_COUNT=1
            DITHER_BASE_MS=0
            DITHER_JITTER_MS=0
            ;;
        QUIET)
            # 50ms fixed floor + up to 200ms jitter — mimics human-paced browsing,
            # very low IDS signature even on sensitive networks
            PARALLEL_COUNT=1
            SILENT=1   # force silent mode for QUIET profile
            DITHER_BASE_MS=50
            DITHER_JITTER_MS=200
            ;;
        NORMAL)
            # No fixed floor, but 0–80ms jitter breaks the metronomic
            # timing that stateful IDS engines key on
            PARALLEL_COUNT=1
            DITHER_BASE_MS=0
            DITHER_JITTER_MS=80
            ;;
        FAST)
            # Minimal 0–25ms jitter — enough to avoid exact-interval signatures
            # without meaningfully slowing down the scan
            PARALLEL_COUNT=3
            DITHER_BASE_MS=0
            DITHER_JITTER_MS=25
            ;;
        AGGRESSIVE)
            # No dither — speed is the priority; accept the IDS risk
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
    # Bash RANDOM avoids an unavailable BusyBox dependency. All configured
    # ranges remain below one second, so the fractional sleep format is stable.
    local total_ms=$DITHER_BASE_MS
    if [ "$DITHER_JITTER_MS" -gt 0 ]; then
        # $RANDOM % (JITTER+1) gives 0..JITTER_MS
        total_ms=$(( DITHER_BASE_MS + (RANDOM % (DITHER_JITTER_MS + 1)) ))
    fi
    [ "$total_ms" -gt 0 ] && sleep "0.$(printf '%03d' "$((total_ms % 1000))")"
}

# ── Core scan loop ────────────────────────────────────────────────────────────

run_scan() {
    # One complete scan transaction: reset state, open a new loot pair, collect
    # hints/evidence, report/diff, and present only confirmed results.
    # Reset per-scan state
    SCAN_ID="$(date +%Y%m%d_%H%M%S)"
    LOG_FILE="$LOOT_BASE/scan_${SCAN_ID}.log"
    FOUND_COUNT=0
    HOSTS_SCANNED=0
    ABORT=0
    FOUND_HOSTS=()
    FOUND_DETAILS=()

    # ── Log header ────────────────────────────────────────────────
    # Snapshot every operator/profile input into the log before network work.
    # This makes later evidence reproducible without persisting AP credentials.
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
        if [ "$WATCHDOG_ACTIVE" -eq 0 ]; then
            led_complete_ok; ringtone_complete_ok; vibrate_strong
        else
            led_watchdog
        fi
        LOG green "Complete!"
        LOG green "Found: $FOUND_COUNT OpenClaw"
        LOG blue  "Scanned: $HOSTS_SCANNED hosts"
    else
        if [ "$WATCHDOG_ACTIVE" -eq 0 ]; then
            led_complete_none; ringtone_complete_none
        else
            led_watchdog
        fi
        LOG blue "Complete — none found"
        LOG blue "Scanned: $HOSTS_SCANNED hosts"
    fi
    # Watchdog owns its own change dialog and must never pause for browsing.
    if [ "$WATCHDOG_ACTIVE" -eq 0 ]; then
        sleep 1
        show_results_browser
    fi

    LOG blue "Log: $LOG_FILE"
    [ "$WATCHDOG_ACTIVE" -eq 1 ] || sleep 1
}

# ── Active port scan (inner loop) — called from run_scan() ───────────────────
_run_port_scan() {
    # The port-set checksum prevents an interrupted narrow scan from suppressing
    # work in a later wide scan. A line means every selected port for that IPv4
    # host completed; both execution paths obey the same record contract.
    # ── Scan resume checkpoint setup ──────────────────────────────
    local CHECKPOINT_FILE
    CHECKPOINT_FILE=$(checkpoint_path "$SUBNET" "$ALL_PORTS") || {
        ABORT=1
        log_entry "Checkpoint: invalid subnet or port set"
        return 1
    }
    declare -A _scanned_set=()
    if [ -f "$CHECKPOINT_FILE" ]; then
        # Associative membership makes resume checks O(1). Only non-empty lines
        # written after a complete host port-loop are trusted as completed work.
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
    local ipv6_candidates
    ipv6_candidates=$(ipv6_neighbor_candidates 2>/dev/null)
    if [ -n "$ipv6_candidates" ]; then
        # Link-local addresses need an interface scope ID. Preserve visibility in
        # loot without feeding them into IPv4 dot sorting or active port loops.
        while IFS= read -r _v6; do
            [ -n "$_v6" ] && log_candidate "IPv6 ${_v6} | not port-scanned"
        done <<< "$ipv6_candidates"
    fi
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

    # Merge cache and active discovery before randomization. Both producers are
    # IPv4-only, making numeric final-octet sorting correct and deterministic.
    if [ -n "$cache_hosts" ]; then
        raw_hosts=$(printf '%s\n%s\n' "$cache_hosts" "$raw_hosts" \
            | sort -u -t. -k4 -n)
    fi

    STOP_SPINNER "$SID"

    # ── Randomize ──────────────────────────────────────────────────
    if [ $RANDOMIZE -eq 1 ] && [ -n "$raw_hosts" ]; then
        # BusyBox lacks shuf. Prefix with awk PRNG values, sort, then discard the
        # prefix while preserving one entry per previously de-duplicated host.
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
            # A short non-blocking poll keeps B responsive without pausing every
            # network iteration for interactive input.
            btn=$(timeout 0.05 sh -c 'WAIT_FOR_INPUT 2>/dev/null' 2>/dev/null || true)
            if [ "$btn" = "B" ]; then ABORT=1; break; fi

            # Resume: skip already-scanned hosts
            if [ -n "${_scanned_set[$IP]+_}" ]; then
                continue
            fi
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
                # Probe every normalized port. Confirmation of one binding does
                # not suppress another valid OpenClaw listener on the same host.
                probe_openclaw "$IP" "$PORT" || continue

                if [ $PROBE_CONFIRMED -eq 1 ]; then
                    STOP_SPINNER "$SID"
                    # Periodic watchdog scans are unattended. Preserve all logs
                    # and result arrays, but reserve disruptive feedback/dialogs
                    # for the later set-change notification.
                    if [ "$WATCHDOG_ACTIVE" -eq 0 ]; then
                        led_found; ringtone_found; vibrate_strong
                    fi

                    LOG green "✦ FOUND: ${IP}:${PORT} (${PROBE_SCHEME})"
                    LOG green "  ${PROBE_BANNER}"
                    [ -n "$PROBE_DETAIL" ] && LOG "  ${PROBE_DETAIL:0:55}"

                    log_found "${IP}:${PORT} | ${PROBE_SCHEME} | HTTP ${PROBE_HTTP_CODE} | ${PROBE_BANNER}"
                    [ -n "$PROBE_DETAIL" ] && log_entry "  Detail: ${PROBE_DETAIL}"

                    FOUND_HOSTS+=("${IP}:${PORT}")
                    FOUND_DETAILS+=("${PROBE_SCHEME}:// | ${PROBE_BANNER} | ${PROBE_DETAIL}")
                    FOUND_COUNT=$((FOUND_COUNT + 1))
                    HOST_HAD_FIND=1

                    if [ "$WATCHDOG_ACTIVE" -eq 0 ]; then
                        ALERT "✦ OpenClaw Found!\n${IP}:${PORT} (${PROBE_SCHEME})\n${PROBE_BANNER}\n${PROBE_DETAIL:0:80}\nPress any key to resume scan"
                    fi

                    led_scanning
                    SID=$(START_SPINNER "${pct}% — ${IP} ($probe_idx/${TOTAL_LIVE})...")

                elif [ $PROBE_CANDIDATE -eq 1 ]; then
                    STOP_SPINNER "$SID"
                    if [ "$WATCHDOG_ACTIVE" -eq 0 ]; then
                        led_candidate; ringtone_candidate; vibrate_soft
                    fi

                    LOG blue "? ${PROBE_CLASS}: ${IP}:${PORT}"
                    log_candidate "${IP}:${PORT} | ${PROBE_SCHEME} | ${PROBE_DETAIL}"

                    # Interactive mode holds the candidate state briefly for the
                    # operator; watchdog mode avoids one second per weak endpoint.
                    [ "$WATCHDOG_ACTIVE" -eq 1 ] || sleep 1
                    led_scanning
                    SID=$(START_SPINNER "${pct}% — ${IP} ($probe_idx/${TOTAL_LIVE})...")
                fi
            done

            # A host is resumable only after every selected port completed.
            # Append is intentionally after the entire port loop. A power loss
            # during a host causes that host, not the whole scan, to be retried.
            checkpoint_mark "$CHECKPOINT_FILE" "$IP"

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
    # Each worker writes all endpoint results followed by exactly one DONE row.
    # The parent alone updates global arrays, hardware, UI, logs, and checkpoint,
    # avoiding cross-process state loss and concurrent writes to those resources.
    local -a hosts=("$@")
    local total=${#hosts[@]}
    local sem_dir
    # A private directory provides collision-free worker IPC and is removed only
    # after the parent consumes every result. Failure aborts without checkpointing.
    sem_dir=$(mktemp -d /tmp/clawhunter_par_XXXXXX) || {
        ABORT=1
        log_entry "Parallel scan: unable to allocate result directory"
        return 1
    }
    local results_dir="${sem_dir}/results"
    mkdir -p "$results_dir"
    local active=0
    local probe_idx=0

    for IP in "${hosts[@]}"; do
        local btn
        btn=$(timeout 0.05 sh -c 'WAIT_FOR_INPUT 2>/dev/null' 2>/dev/null || true)
        if [ "$btn" = "B" ]; then ABORT=1; break; fi

        # Bash `wait -n` releases one worker slot without serializing the batch.
        # Recount jobs because completion order is intentionally nondeterministic.
        while [ $active -ge "${PARALLEL_COUNT:-3}" ]; do
            wait -n 2>/dev/null || sleep 0.1
            active=$(jobs -p | wc -l)
        done

        probe_idx=$((probe_idx + 1))
        HOSTS_SCANNED=$((HOSTS_SCANNED + 1))
        local pct=$(( (probe_idx * 100) / total ))
        LOG blue "${pct}% — $IP ($probe_idx/$total) [parallel]"
        log_entry "Probing: $IP ($probe_idx/${total}, ${pct}%) [parallel]"

        # Background worker result schema (tab-delimited):
        # CONFIRMED host:port scheme banner detail
        # CANDIDATE host:port scheme class  detail
        # DONE      host-ip
        # Fields produced by probes contain pipes/spaces, not tabs.
        {
            local result_file="${results_dir}/${IP//\./_}"
            : > "$result_file"
            apply_dither
            for PORT in $ALL_PORTS; do
                probe_openclaw "$IP" "$PORT" 2>/dev/null || continue
                if [ $PROBE_CONFIRMED -eq 1 ]; then
                    printf 'CONFIRMED\t%s\t%s\t%s\t%s\n' \
                        "${IP}:${PORT}" "$PROBE_SCHEME" "$PROBE_BANNER" \
                        "$PROBE_DETAIL" >> "$result_file"
                elif [ $PROBE_CANDIDATE -eq 1 ]; then
                    printf 'CANDIDATE\t%s\t%s\t%s\t%s\n' \
                        "${IP}:${PORT}" "$PROBE_SCHEME" "$PROBE_CLASS" \
                        "$PROBE_DETAIL" >> "$result_file"
                fi
            done
            # DONE is emitted only after every port loop iteration completes.
            printf 'DONE\t%s\n' "$IP" >> "$result_file"
        } &

        active=$((active + 1))
    done

    # Wait for every launched worker, including those active when B was pressed;
    # completed hosts remain valid resume records while unlaunched hosts do not.
    wait

    # Harvest result files in the parent so Bash arrays, hardware state, log
    # descriptors, and the dynamically scoped checkpoint remain authoritative.
    for result_file in "${results_dir}"/*; do
        [ -f "$result_file" ] || continue
        local host scheme banner detail status
        while IFS=$'\t' read -r status host scheme banner detail; do
            if [ "$status" = "CONFIRMED" ]; then
                if [ "$WATCHDOG_ACTIVE" -eq 0 ]; then
                    led_found; ringtone_found; vibrate_strong
                fi
                LOG green "✦ FOUND: ${host} (${scheme})"
                LOG green "  ${banner}"
                log_found "${host} | ${scheme} | ${banner}"
                FOUND_HOSTS+=("$host")
                FOUND_DETAILS+=("${scheme}:// | ${banner} | ${detail}")
                FOUND_COUNT=$((FOUND_COUNT + 1))
                if [ "$WATCHDOG_ACTIVE" -eq 0 ]; then
                    ALERT "✦ OpenClaw Found!\n${host} (${scheme})\n${banner}\n${detail:0:80}\nPress any key"
                fi
            elif [ "$status" = "CANDIDATE" ]; then
                if [ "$WATCHDOG_ACTIVE" -eq 0 ]; then
                    led_candidate; ringtone_candidate; vibrate_soft
                fi
                LOG blue "? ${banner}: ${host}"
                log_candidate "${host} | ${scheme} | ${detail}"
            elif [ "$status" = "DONE" ] && [ -n "${CHECKPOINT_FILE:-}" ]; then
                checkpoint_mark "$CHECKPOINT_FILE" "$host"
            fi
        done < "$result_file"
    done

    rm -rf "$sem_dir"
}

# ── F5: Watchdog state helpers ───────────────────────────────────────────────

# Keep state-path construction centralized so read/write/removal cannot diverge.
_watchdog_state_file() { echo "${LOOT_BASE}/watchdog_state.json"; }

_watchdog_write_state() {
    # Persist only confirmed endpoint identities. This compact state is a
    # restart baseline, not a substitute for evidence-rich scan reports.
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
    # Parse the narrow JSON shape written above without requiring jq on OpenWrt.
    # Output one validated-looking IPv4:port string per line; probe_openclaw
    # still performs strict validation before any later network operation.
    local state_file
    state_file=$(_watchdog_state_file)
    [ -f "$state_file" ] || return
    grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[^"]*"' "$state_file" | tr -d '"'
}

# ── F5: Watchdog mode ─────────────────────────────────────────────────────────
# Rescans every N minutes. Alerts only on changes (new/gone instances).
# B-button during the sleep countdown exits watchdog.

run_watchdog() {
    # Re-run the configured scan at a bounded minute interval, compare endpoint
    # sets, persist a restart baseline, and allow B to leave the loop.
    local interval_min="${1:-5}"
    # Picker values are still untrusted shell data. Clamp invalid/extreme values
    # before multiplication so watchdog cannot busy-loop or overflow a wait.
    [[ "$interval_min" =~ ^[0-9]+$ ]] && \
        [ "$interval_min" -ge 1 ] && [ "$interval_min" -le 1440 ] || interval_min=5
    WATCHDOG_ACTIVE=1
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

        # Countdown in one-second input windows. This keeps B responsive without
        # an additional background reader competing with Pager UI commands.
        local wait_sec=$(( interval_min * 60 ))
        local elapsed_wait=0
        while [ $elapsed_wait -lt $wait_sec ]; do
            local btn
            btn=$(timeout 1 sh -c 'WAIT_FOR_INPUT 2>/dev/null' 2>/dev/null || true)
            if [ "$btn" = "B" ]; then
                LOG blue "Watchdog: exit"
                log_entry "Watchdog exited by user"
                rm -f "$(_watchdog_state_file)"
                WATCHDOG_ACTIVE=0
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

        # Compare sets by associative membership. Endpoint order is irrelevant,
        # which avoids false changes when host order is randomized or parallel.
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
            # Promote the changed set only after notifying the operator. A later
            # scan compares against this acknowledged state, not the stale set.
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
# History is offered before changing MAC/network state, so browsing old loot has
# no side effects and exits cleanly through the same restoration trap.
prev_count=$(find "$LOOT_BASE" -name 'scan_*.log' 2>/dev/null | wc -l)
if [ "$prev_count" -gt 0 ]; then
    resp=$(CONFIRMATION_DIALOG "View scan history?" "${prev_count} previous scan(s). YES=browse, NO=new scan")
    case "$resp" in
        "$DUCKYSCRIPT_USER_CONFIRMED")
            show_history
            exit 0
            ;;
    esac
fi

# ── Feature 1: Silent mode ────────────────────────────────────────────────────
resp=$(CONFIRMATION_DIALOG "Silent mode?" "YES = suppress all audio and vibration")
case "$resp" in "$DUCKYSCRIPT_USER_CONFIRMED") SILENT=1 ;; esac

# ── E1: MAC randomization ─────────────────────────────────────────────────────
resp=$(CONFIRMATION_DIALOG "Randomize MAC?" "Change scanner MAC before scan — restored on exit")
case "$resp" in
    "$DUCKYSCRIPT_USER_CONFIRMED")
        # Use the routed interface rather than assuming wlan0; fall back only
        # when route inspection provides no device name.
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
# Descriptions are kept parallel to profiles by index for the compact Pager UI.
profile_descs=(
    "Passive only — mDNS+ARP cache, no port probes"
    "50ms delay, silent forced, low-noise"
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
# Derive a convenient picker default from the active route without assuming a
# fixed Pineapple/client subnet. The operator still explicitly confirms the full
# target IPv4 address; CLAWHunter then bounds scanning to that address's /24.
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' | head -1)
if ! is_valid_ipv4 "$LOCAL_IP"; then
    LOCAL_IP=$(ip -4 -o addr show 2>/dev/null | awk '$4 !~ /^127\./ {split($4,a,"/"); print a[1]; exit}')
fi
DEFAULT_TARGET_IP="192.168.1.1"
is_valid_ipv4 "$LOCAL_IP" && DEFAULT_TARGET_IP="$LOCAL_IP"
LOG blue "Local IP: ${LOCAL_IP:-unknown}"
sleep 1

# ── Feature 10: Multi-subnet loop ─────────────────────────────────────────────
while true; do

    # ── Subnet picker ──────────────────────────────────────────────
    # IP_PICKER returns a complete dotted-decimal value. Validate again because
    # firmware/theme components are input sources, not a security boundary.
    TARGET_NETWORK_IP=$(IP_PICKER "Target network IP" "$DEFAULT_TARGET_IP")
    case $? in
        "$DUCKYSCRIPT_CANCELLED" | "$DUCKYSCRIPT_REJECTED" | "$DUCKYSCRIPT_ERROR")
            LOG red "Cancelled"; break ;;
    esac
    if ! is_valid_ipv4 "$TARGET_NETWORK_IP"; then
        ERROR_DIALOG "Invalid IPv4" "$TARGET_NETWORK_IP"
        continue
    fi
    SUBNET=$(subnet_prefix_from_ip "$TARGET_NETWORK_IP")

    # ── Port picker ────────────────────────────────────────────────
    # NUMBER_PICKER is likewise followed by a strict 1..65535 check before the
    # value reaches port normalization or any network command.
    TARGET_PORT=$(NUMBER_PICKER "OpenClaw Port" "$OPENCLAW_DEFAULT_PORT")
    case $? in
        "$DUCKYSCRIPT_CANCELLED" | "$DUCKYSCRIPT_REJECTED" | "$DUCKYSCRIPT_ERROR")
            LOG red "Cancelled"; break ;;
    esac
    if ! is_valid_port "$TARGET_PORT"; then
        ERROR_DIALOG "Invalid Port" "$TARGET_PORT"
        continue
    fi

    # ── Advanced options (skip for AGGRESSIVE — already set by profile) ───────
    if [ "$SCAN_PROFILE" != "AGGRESSIVE" ]; then
        WIDE_SCAN=0; EXTRA_PORTS=0; RANDOMIZE=0
        resp=$(CONFIRMATION_DIALOG "Advanced options?" "Port range, extended ports, randomize")
        case "$resp" in
            "$DUCKYSCRIPT_USER_CONFIRMED")
                resp=$(CONFIRMATION_DIALOG "Wide port range?" "Sweep ${OPENCLAW_RANGE_LOW}-${OPENCLAW_RANGE_HIGH}")
                case "$resp" in "$DUCKYSCRIPT_USER_CONFIRMED") WIDE_SCAN=1 ;; esac

                resp=$(CONFIRMATION_DIALOG "Extended ports?" "Also probe 80, 443, 3000, 8080, 8443")
                case "$resp" in "$DUCKYSCRIPT_USER_CONFIRMED") EXTRA_PORTS=1 ;; esac

                resp=$(CONFIRMATION_DIALOG "Randomize order?" "Shuffle host list")
                case "$resp" in "$DUCKYSCRIPT_USER_CONFIRMED") RANDOMIZE=1 ;; esac
                ;;
        esac
    fi

    # ── Host range ─────────────────────────────────────────────────
    if [ "$SCAN_PROFILE" != "GHOST" ]; then
        resp=$(CONFIRMATION_DIALOG "Full /24 scan?" "254 hosts (~90s). NO = quick .1-.50 (~20s)")
        case "$resp" in
            "$DUCKYSCRIPT_USER_CONFIRMED") HOST_START=1; HOST_END=254 ;;
            *)                           HOST_START=1; HOST_END=50  ;;
        esac
    fi

    # ── C1: mDNS dwell time (user-configurable) ───────────────────
    if command -v avahi-browse >/dev/null 2>&1; then
        MDNS_DWELL_RAW=$(NUMBER_PICKER "mDNS dwell (sec)" 30)
        case $? in
            "$DUCKYSCRIPT_CANCELLED" | "$DUCKYSCRIPT_REJECTED" | "$DUCKYSCRIPT_ERROR") ;;
            *) MDNS_DWELL="$MDNS_DWELL_RAW" ;;
        esac
    fi

    # ── Build port list ────────────────────────────────────────────
    if [ $WIDE_SCAN -eq 1 ]; then
        ALL_PORTS=$(seq $OPENCLAW_RANGE_LOW $OPENCLAW_RANGE_HIGH)
        PORT_DESC="${OPENCLAW_RANGE_LOW}-${OPENCLAW_RANGE_HIGH}"
    else
        ALL_PORTS="$TARGET_PORT 18790"
        PORT_DESC="${TARGET_PORT}+legacy"
    fi
    if [ $EXTRA_PORTS -eq 1 ]; then
        ALL_PORTS="$ALL_PORTS $EXTENDED_PORTS"
        PORT_DESC="${PORT_DESC}+ext"
    fi
    # Normalize ordering and duplicates before hashing the checkpoint identity;
    # semantically identical selections must resume from the same file.
    ALL_PORTS=$(echo "$ALL_PORTS" | tr ' ' '\n' | sort -n | uniq | tr '\n' ' ')

    # ── Run scan ───────────────────────────────────────────────────
    run_scan

    # ── F5: Offer watchdog mode after scan ─────────────────────────
    if [ $FOUND_COUNT -gt 0 ]; then
        resp=$(CONFIRMATION_DIALOG "Watchdog mode?" "Rescan periodically, alert on changes")
        case "$resp" in
            "$DUCKYSCRIPT_USER_CONFIRMED")
                WDOG_INTERVAL=$(NUMBER_PICKER "Rescan interval (min)" 5)
                case $? in
                    "$DUCKYSCRIPT_CANCELLED" | "$DUCKYSCRIPT_REJECTED" | "$DUCKYSCRIPT_ERROR")
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
        "$DUCKYSCRIPT_USER_CONFIRMED")
            DEFAULT_TARGET_IP="${SUBNET}.1"
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
