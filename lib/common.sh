#!/bin/bash
# shellcheck disable=SC2034 # Probe result globals are the library's caller API.
# CLAWHunter shared Pager library.
#
# This file is the single implementation point for behavior shared by the
# interactive, Recon, and alert entry points. Functions deliberately publish
# probe results through PROBE_* globals because Pager payloads are Bash scripts
# and callers need every evidence field without parsing subprocess output.
# VERSION: 3.3.0

# Hak5 ships its DuckyScript-backed shell helpers here. Host-side tests do not,
# so a missing file is non-fatal and the tests provide narrow fixture stubs.
. /lib/hak5/commands.sh 2>/dev/null || true

# Callers may define these before sourcing the library. The defaults allow the
# library to operate in a standalone Portal package as well as the suite layout.
: "${PAYLOAD_VERSION:=3.3.0}"
: "${LOOT_BASE:=/root/loot/clawhunter}"
: "${SILENT:=0}"
: "${FOUND_COUNT:=0}"
: "${LOG_FILE:=}"

# Loot records confirmed gateways, candidate hosts, and harvested evidence about
# third-party systems, so it is operator-sensitive even though the Pager is a
# single-root device. Restrict before the first write rather than after: a chmod
# that follows creation leaves a window where the file is world-readable, and on
# a device that may be shared, imaged, or exported that window is the whole risk.
# 077 also covers the checkpoint files and any child process the payload spawns,
# including harvest.py, which inherits this umask.
umask 077
mkdir -p "$LOOT_BASE"
# mkdir honours the umask only for directories it creates; an existing loot
# directory from an earlier release keeps its old mode, so set it explicitly.
# Fail closed and loudly: this is the boundary that keeps scan evidence off a
# shared or imaged device, and a swallowed failure here would leave a
# world-readable directory with nothing to indicate it. Exiting is deliberate --
# `return` would merely end the `source` and let the payload run on unprotected.
if ! chmod 0700 "$LOOT_BASE"; then
    printf 'CLAWHunter: refusing to run: cannot secure loot directory %s\n' \
        "$LOOT_BASE" >&2
    exit 1
fi
declare -ag MDNS_CANDIDATES=()

# -- Pager feedback -----------------------------------------------------------
#
# The three payload modes use the same visual language. Hardware API failures
# must never terminate a network assessment, so all LED/audio/haptic wrappers
# degrade to no-ops when invoked in a host test or degraded Pager environment.
_led() { HAK5_API_POST "system/led" "$1" >/dev/null 2>&1 || true; }
# Off: clear all four RGB emitters during cleanup and after transient alerts.
led_off() { _led '{"color":"custom","raw_pattern":[{"onms":100,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'; }
# Scanning: a slow blue pulse stays legible without dominating the Pager UI.
led_scanning() { _led '{"color":"custom","raw_pattern":[{"onms":600,"offms":400,"next":false,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,true],"4":[false,false,true]}}]}'; }
# Confirmed: rapid green clearly distinguishes product-specific evidence.
led_found() { _led '{"color":"custom","raw_pattern":[{"onms":120,"offms":120,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'; }
# Candidate: alternating blue/green communicates uncertainty, not success.
led_candidate() { _led '{"color":"custom","raw_pattern":[{"onms":250,"offms":150,"next":true,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,true],"4":[false,false,true]}},{"onms":250,"offms":150,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'; }
# mDNS: cyan marks a passive, unauthenticated discovery hint.
led_mdns() { _led '{"color":"custom","raw_pattern":[{"onms":150,"offms":100,"next":true,"rgb":{"1":[false,true,true],"2":[false,true,true],"3":[false,false,false],"4":[false,false,false]}},{"onms":150,"offms":300,"next":false,"rgb":{"1":[false,true,true],"2":[false,true,true],"3":[false,false,false],"4":[false,false,false]}}]}'; }
# Error: solid red persists long enough for a blocking error dialog to be read.
led_error() { _led '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[true,false,false],"2":[true,false,false],"3":[true,false,false],"4":[true,false,false]}}]}'; }
# Wi-Fi: white is reserved for client-interface association/DHCP work.
led_wifi_connect() { _led '{"color":"custom","raw_pattern":[{"onms":500,"offms":300,"next":false,"rgb":{"1":[true,true,true],"2":[true,true,true],"3":[true,true,true],"4":[true,true,true]}}]}'; }
# Completion reuses the same confirmed/candidate vocabulary shown during scans.
led_complete_ok() { led_found; }
led_complete_none() { led_candidate; }
# Passive mode intentionally reuses the mDNS color rather than implying a scan.
led_passive() { led_mdns; }
# Watchdog: magenta identifies long-lived periodic monitoring at a glance.
led_watchdog() { _led '{"color":"custom","raw_pattern":[{"onms":1000,"offms":800,"next":false,"rgb":{"1":[true,false,true],"2":[true,false,true],"3":[true,false,true],"4":[true,false,true]}}]}'; }

# SILENT applies centrally so individual callers cannot accidentally play a
# ringtone/vibration in Quiet mode. Background audio avoids blocking progress.
# Both firmware commands consume RTTTL, including VIBRATE: the vibration motor
# follows note timing and does not accept a millisecond duration argument.
_play() { [ "${SILENT:-0}" -eq 0 ] || return 0; RINGTONE "$1" & }
_vibrate() { [ "${SILENT:-0}" -eq 0 ] || return 0; VIBRATE "$1"; }
# Short/medium/strong RTTTL note patterns provide three stable severities. The
# names are unique so firmware diagnostics can identify CLAWHunter feedback.
vibrate_soft() { _vibrate "clawsoft:d=16,o=5,b=240:c"; }
vibrate_medium() { _vibrate "clawmedium:d=8,o=5,b=200:c,p,c"; }
vibrate_strong() { _vibrate "clawstrong:d=4,o=5,b=180:c,c"; }
# RTTTL identifiers and melodies are kept in one place so payload variants do
# not drift in audible state semantics. Alert mode bypasses these entirely.
ringtone_start() { _play "start:d=8,o=5,b=180:c,e,g"; }
ringtone_found() { _play "found:d=8,o=5,b=220:e,e,g,g,b,b"; }
ringtone_mdns_found() { _play "mdns:d=8,o=5,b=200:g,b,d6"; }
ringtone_candidate() { _play "ping:d=16,o=5,b=200:g"; }
ringtone_complete_ok() { _play "win:d=4,o=5,b=160:c,e,g,c6"; }
ringtone_complete_none() { _play "none:d=4,o=5,b=140:g,e,c"; }
ringtone_abort() { _play "abort:d=4,o=4,b=120:g,e"; }
ringtone_wifi_ok() { _play "wifi:d=8,o=5,b=200:c,g,c6"; }
ringtone_watchdog_alert() { _play "wdog:d=4,o=5,b=160:c,e,g,e,c6"; }

# -- Logging ------------------------------------------------------------------
# LOG_FILE is owned by each entry point. These helpers intentionally do nothing
# before a scan creates its log, which lets early mDNS/UI setup remain harmless.
# Prefixes are machine-searchable contracts used by history/diff/report tooling.
log_entry() { [ -n "$LOG_FILE" ] && printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1" >> "$LOG_FILE"; }
log_found() { [ -n "$LOG_FILE" ] && printf '[FOUND]     %s\n' "$1" >> "$LOG_FILE"; }
log_candidate() { [ -n "$LOG_FILE" ] && printf '[CANDIDATE] %s\n' "$1" >> "$LOG_FILE"; }
log_mdns() { [ -n "$LOG_FILE" ] && printf '[MDNS]      %s\n' "$1" >> "$LOG_FILE"; }
log_section() { [ -n "$LOG_FILE" ] && printf '\n-- %s --\n' "$1" >> "$LOG_FILE"; }

# Validate strict dotted-decimal IPv4 before using operator/device data in a
# network command. The 10# prefix prevents leading-zero octets being read as
# Bash octal values.
is_valid_ipv4() {
    local ip="$1" IFS=. octets=() octet
    read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        # Regex validation happens before arithmetic expansion to avoid syntax
        # errors or expression injection through environment/picker values.
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        [ "$((10#$octet))" -le 255 ] || return 1
    done
}

# Ports are checked centrally before nc/curl receive them. This also rejects
# whitespace, shell metacharacters, signs, and values outside TCP's range.
is_valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Return the first three octets used by CLAWHunter's intentionally bounded /24
# scan model. The caller retains responsibility for host start/end selection.
subnet_prefix_from_ip() {
    is_valid_ipv4 "$1" || return 1
    printf '%s\n' "${1%.*}"
}

# Build a stable resume path from a validated /24 prefix and normalized port
# string. Including `cksum` output keeps filenames short while making a changed
# port selection a different unit of completed work.
checkpoint_path() {
    local subnet="$1" ports="$2" port key
    is_valid_ipv4 "${subnet}.1" || return 1
    [ -n "$ports" ] || return 1
    for port in $ports; do is_valid_port "$port" || return 1; done
    key=$(printf '%s' "$ports" | cksum | awk '{print $1}')
    printf '/tmp/clawhunter_checkpoint_%s_%s\n' "${subnet//./_}" "$key"
}

# Append one completed IPv4 host. Both sequential and parallel parent paths call
# this exact helper, making validation and record format part of one contract.
checkpoint_mark() {
    local checkpoint_file="$1" ip="$2"
    is_valid_ipv4 "$ip" || return 1
    case "$checkpoint_file" in
        /tmp/clawhunter_checkpoint_*) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$ip" >> "$checkpoint_file"
}

# opkg's `-d mmc` destination places executables and shared libraries outside
# the root overlay. Firmware 1.0.7 adds the executable paths for normal payload
# launches, but Portal/alert contexts can differ, so make resolution explicit.
bootstrap_mmc_env() {
    local path
    for path in /mmc/bin /mmc/sbin /mmc/usr/bin /mmc/usr/sbin; do
        # Colon sentinels make membership exact: /bin must not match /sbin.
        case ":$PATH:" in *":$path:"*) ;; *) PATH="$path:$PATH" ;; esac
    done
    [ -d /mmc/usr/lib ] && LD_LIBRARY_PATH="/mmc/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export PATH LD_LIBRARY_PATH
}
bootstrap_mmc_env

# Perform a bounded, unauthenticated WebSocket upgrade. This function proves
# transport support only; probe_openclaw requires OpenClaw-specific evidence
# such as connect.challenge before treating the target as confirmed.
#
# Output: WS_PROBE_RESPONSE (maximum 8192 bytes). Return 0 on a valid upgrade.
ws_probe() {
    local ip="$1" port="$2" request
    is_valid_ipv4 "$ip" && is_valid_port "$port" || return 1
    # A fixed RFC example key is sufficient for fingerprinting because no
    # authenticated session follows; the Python assessment validates the hash.
    request="GET / HTTP/1.1\r\nHost: ${ip}:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nOrigin: http://${ip}:${port}\r\n\r\n"
    WS_PROBE_RESPONSE=$(printf '%b' "$request" | nc -w "${PROBE_WS_TIMEOUT:-2}" "$ip" "$port" 2>/dev/null | head -c 8192)
    printf '%s' "$WS_PROBE_RESPONSE" | grep -qiE '101 switching|sec-websocket-accept'
}

# Fetch one bounded HTTP path without exposing response data on stdout. A fresh
# private temporary directory prevents parallel workers from overwriting each
# other's headers/body. curl's -k is intentional for LAN appliances using a
# self-signed certificate; this is fingerprinting, not trust establishment.
#
# Output globals: HTTP_EVIDENCE_CODE, HTTP_EVIDENCE_HEADERS,
# HTTP_EVIDENCE_BODY. Bodies and headers are size-capped for Pager memory.
_http_evidence() {
    local ip="$1" port="$2" scheme="$3" path="$4" budget="${5:-2}" tmpdir
    tmpdir=$(mktemp -d /tmp/clawhunter_http_XXXXXX) || return 1
    # Headers and body are separated so an HTML body cannot impersonate a
    # response header during product-marker checks.
    HTTP_EVIDENCE_CODE=$(curl -ksS --max-time "$budget" --connect-timeout 1 \
        -H "User-Agent: CLAWHunter/${PAYLOAD_VERSION}" \
        -D "$tmpdir/headers" -o "$tmpdir/body" -w '%{http_code}' \
        "${scheme}://${ip}:${port}${path}" 2>/dev/null)
    HTTP_EVIDENCE_BODY=$(head -c 8192 "$tmpdir/body" 2>/dev/null)
    HTTP_EVIDENCE_HEADERS=$(head -c 4096 "$tmpdir/headers" 2>/dev/null)
    rm -rf "$tmpdir"
    [ -n "$HTTP_EVIDENCE_CODE" ] && [ "$HTTP_EVIDENCE_CODE" != "000" ]
}

# Classify an IPv4 host/port using weighted, explainable evidence.
#
# Scoring rationale:
#   * any HTTP response: 1 (reachability only)
#   * /healthz or /readyz 200: 1 each (generic framework evidence)
#   * generic WebSocket upgrade: 1 (transport evidence)
#   * legacy canvas path: 1 (weak compatibility evidence)
#   * x-openclaw header or OpenClaw root marker: 4 (specific evidence)
#   * OpenClaw health marker: 3 (specific evidence)
#   * connect.challenge: 5 (current protocol-specific evidence)
#
# CONFIRMED requires at least one specific signal and a score >= 4. Generic
# 401/403 responses and generic upgrades can therefore never confirm a target.
# PROBE_FAST skips the preliminary TCP check and lower-value readiness/canvas
# paths so an event-triggered alert remains within its short execution budget.
#
# Output: PROBE_* globals consumed by all entry points. Return 2 for invalid
# input, 1 for unreachable, and 0 when evidence was collected/classified.
probe_openclaw() {
    local ip="$1" port="$2" scheme score=0 specific=0 transport=0 evidence="" root_body="" root_budget=2
    is_valid_ipv4 "$ip" && is_valid_port "$port" || return 2

    PROBE_CONFIRMED=0
    PROBE_CANDIDATE=0
    PROBE_CLASS="NONE"
    PROBE_CONFIDENCE=0
    PROBE_HTTP_CODE=""
    PROBE_BANNER=""
    PROBE_SCHEME=""
    PROBE_DETAIL=""
    PROBE_WS_CONFIRMED=0
    PROBE_CHALLENGE_CONFIRMED=0
    PROBE_HEALTH_CODE=""
    PROBE_READY_CODE=""
    PROBE_CANVAS_CONFIRMED=0

    # Normal scans avoid spending several HTTP timeouts on closed ports. Alert
    # mode skips this extra second and relies on its HTTP transport result.
    if [ "${PROBE_FAST:-0}" -ne 1 ]; then
        nc -z -w 1 "$ip" "$port" 2>/dev/null || return 1
        transport=1
    fi

    [ "${PROBE_FAST:-0}" -eq 1 ] && root_budget=1
    # Prefer clear HTTP because it also permits the raw challenge probe. HTTPS
    # remains fully classifiable through headers/body/health evidence.
    for scheme in http https; do
        if _http_evidence "$ip" "$port" "$scheme" / "$root_budget"; then
            transport=1
            PROBE_SCHEME="$scheme"
            PROBE_HTTP_CODE="$HTTP_EVIDENCE_CODE"
            root_body="$HTTP_EVIDENCE_BODY"
            PROBE_CANDIDATE=1
            score=1
            evidence="HTTP ${HTTP_EVIDENCE_CODE}"

            # Product-specific markers are the only signals that can satisfy
            # the confirmation gate; generic framework behavior stays weak.
            if printf '%s' "$HTTP_EVIDENCE_HEADERS" | grep -qi 'x-openclaw'; then
                score=$((score + 4)); specific=1; evidence="${evidence}; x-openclaw header"
            fi
            if printf '%s' "$root_body" | grep -qiE 'openclaw|clawd'; then
                score=$((score + 4)); specific=1
                PROBE_BANNER=$(printf '%s' "$root_body" | grep -ioE '(openclaw|clawd)[^"<]{0,60}' | head -1)
                evidence="${evidence}; OpenClaw body marker"
            fi

            # Failure of an optional evidence path must not discard root
            # evidence already collected for the endpoint.
            _http_evidence "$ip" "$port" "$scheme" /healthz "$root_budget" || true
            PROBE_HEALTH_CODE="$HTTP_EVIDENCE_CODE"
            if [ "$PROBE_HEALTH_CODE" = "200" ]; then
                score=$((score + 1)); evidence="${evidence}; /healthz=200"
            fi
            if printf '%s' "$HTTP_EVIDENCE_BODY" | grep -qiE 'openclaw|clawd'; then
                score=$((score + 3)); specific=1; evidence="${evidence}; health marker"
            fi

            # Alert mode omits these lower-value calls to preserve its event
            # budget. Interactive/Recon scans can afford richer diagnostics.
            if [ "${PROBE_FAST:-0}" -ne 1 ]; then
                _http_evidence "$ip" "$port" "$scheme" /readyz 2 || true
                PROBE_READY_CODE="$HTTP_EVIDENCE_CODE"
                if [ "$PROBE_READY_CODE" = "200" ]; then
                    score=$((score + 1)); evidence="${evidence}; /readyz=200"
                fi

                _http_evidence "$ip" "$port" "$scheme" /__openclaw__/canvas/ 1 || true
                if [ -n "$HTTP_EVIDENCE_CODE" ] && [ "$HTTP_EVIDENCE_CODE" != "000" ] && [ "$HTTP_EVIDENCE_CODE" != "404" ]; then
                    PROBE_CANVAS_CONFIRMED=1
                    score=$((score + 1)); evidence="${evidence}; legacy canvas=${HTTP_EVIDENCE_CODE}"
                fi
            fi
            break
        fi
    done

    # The shell probe cannot perform TLS WebSocket framing, so HTTPS targets are
    # confirmed through specific HTTP evidence and assessed later by Python.
    if [ "$PROBE_SCHEME" = "http" ] && ws_probe "$ip" "$port"; then
        PROBE_WS_CONFIRMED=1
        score=$((score + 1)); evidence="${evidence}; WS upgrade"
        if printf '%s' "$WS_PROBE_RESPONSE" | grep -q 'connect.challenge'; then
            PROBE_CHALLENGE_CONFIRMED=1
            score=$((score + 5)); specific=1; evidence="${evidence}; connect.challenge"
        fi
    fi

    # Fast alert mode omits the preliminary TCP check. If neither HTTP nor HTTPS
    # answered, there is no transport evidence and no candidate to report.
    [ "$transport" -eq 1 ] || return 1

    PROBE_CONFIDENCE="$score"
    # Classification order makes CONFIRMED impossible without the explicit
    # `specific` bit even when several generic endpoints accumulate points.
    if [ "$specific" -eq 1 ] && [ "$score" -ge 4 ]; then
        PROBE_CLASS="CONFIRMED"
        PROBE_CONFIRMED=1
    elif [ "$score" -ge 3 ]; then
        PROBE_CLASS="LIKELY"
        PROBE_CANDIDATE=1
    else
        PROBE_CLASS="CANDIDATE"
        PROBE_CANDIDATE=1
    fi

    [ -n "$PROBE_BANNER" ] || PROBE_BANNER="$PROBE_CLASS OpenClaw evidence"
    PROBE_DETAIL="Class: ${PROBE_CLASS}|Confidence: ${score}|Evidence: ${evidence}"
    [ "$PROBE_CHALLENGE_CONFIRMED" -eq 1 ] && PROBE_DETAIL="${PROBE_DETAIL}|Challenge: confirmed"
    [ "$PROBE_CANVAS_CONFIRMED" -eq 1 ] && PROBE_DETAIL="${PROBE_DETAIL}|Canvas: legacy"
    log_entry "Evidence ${ip}:${port}: ${PROBE_DETAIL}"
    return 0
}

# Parse avahi's semicolon format for the exact OpenClaw service. DNS-SD and TXT
# records are unauthenticated, so entries are hints only and never increment the
# confirmed finding count until the active classifier validates them.
_record_mdns_candidates() {
    local results="$1" line ip port detail
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # Avahi `-p` output is semicolon-delimited: resolved address and service
        # port occupy fields 8 and 9 respectively.
        ip=$(printf '%s\n' "$line" | awk -F';' '{print $8}')
        port=$(printf '%s\n' "$line" | awk -F';' '{print $9}')
        is_valid_ipv4 "$ip" || continue
        is_valid_port "$port" || port=18789
        detail=$(printf '%s' "$line" | cut -c1-160)
        MDNS_CANDIDATES+=("${ip}:${port}")
        log_mdns "${ip}:${port} | LIKELY hint | ${detail}"
        LOG blue "mDNS hint: ${ip}:${port}"
    done <<< "$results"
}

# Browse for a bounded number of seconds while updating the Pager display. The
# hard 1..300 clamp prevents malformed picker/input data from creating an
# unbounded background process.
mdns_monitor() {
    local dwell="${1:-30}" tmpdir results remaining
    [[ "$dwell" =~ ^[0-9]+$ ]] && [ "$dwell" -ge 1 ] && [ "$dwell" -le 300 ] || dwell=30
    command -v avahi-browse >/dev/null 2>&1 || return 1
    tmpdir=$(mktemp -d /tmp/clawhunter_mdns_XXXXXX) || return 1
    log_section "mDNS MONITOR (${dwell}s)"
    led_passive
    # `timeout` owns the external process lifetime; the PID is still waited so
    # no browse process survives a completed payload.
    timeout "$dwell" avahi-browse -rtp _openclaw-gw._tcp > "$tmpdir/results" 2>/dev/null &
    local avahi_pid=$!
    remaining=$dwell
    while [ "$remaining" -gt 0 ]; do
        LOG blue "mDNS: ${remaining}s remaining"
        sleep 1
        remaining=$((remaining - 1))
    done
    wait "$avahi_pid" 2>/dev/null || true
    results=$(grep '_openclaw-gw._tcp' "$tmpdir/results" 2>/dev/null || true)
    rm -rf "$tmpdir"
    if [ -n "$results" ]; then
        led_mdns; ringtone_mdns_found; vibrate_medium
        _record_mdns_candidates "$results"
        return 0
    fi
    log_entry "mDNS monitor: no _openclaw-gw._tcp records"
    return 1
}

# Short one-shot form used by the Recon payload, where an AP was already chosen
# and keeping the operator in the Recon workflow is more important than dwell.
mdns_prescan() {
    local results=""
    command -v avahi-browse >/dev/null 2>&1 || return 1
    results=$(timeout 5 avahi-browse -rtp _openclaw-gw._tcp 2>/dev/null | grep '_openclaw-gw._tcp' || true)
    if [ -n "$results" ]; then
        _record_mdns_candidates "$results"
        return 0
    fi
    log_entry "mDNS pre-scan: no _openclaw-gw._tcp records"
    return 1
}

# Return IPv4 neighbors belonging to the selected /24. IPv6 never enters this
# dot-field sort; that separation fixes the v3.2.0 IPv4/IPv6 collision class.
arp_cache_harvest() {
    local subnet="$1"
    {
        # `/proc/net/arp` and `ip neigh` may overlap. Sort once after merging so
        # every IPv4 host is probed at most once per scan.
        awk -v sub="$subnet" 'NR>1 && $1 ~ "^"sub"\\." && $4 != "00:00:00:00:00:00" {print $1}' /proc/net/arp 2>/dev/null
        ip neigh show 2>/dev/null | awk -v sub="$subnet" '$1 ~ "^"sub"\\." && $NF !~ /FAILED/ {print $1}'
    } | sort -u -t. -k4,4n
}

# Link-local IPv6 requires an interface scope identifier for reliable probing.
# Record stable/reachable neighbors for manual follow-up instead of attempting
# an ambiguous scan from the IPv4-oriented engine.
ipv6_neighbor_candidates() {
    ip -6 neigh show 2>/dev/null | awk 'tolower($1) ~ /^fe[89ab]/ && $NF ~ /REACHABLE|STALE|DELAY/ {split($1,a,"%"); print a[1]}' | sort -u
}

# Discover live IPv4 hosts using the best available Pager utility. arp-scan is
# preferred; arping and ping are progressively slower BusyBox-safe fallbacks.
arp_discover_hosts() {
    local subnet="$1" start="$2" end="$3"
    if command -v arp-scan >/dev/null 2>&1; then
        # Restrict arp-scan output back to the operator-selected host interval;
        # devices outside quick `.1-.50` mode must not leak into the work list.
        arp-scan "${subnet}.0/24" 2>/dev/null \
            | grep -oE "${subnet//./[.]}\.[0-9]+" \
            | awk -F. -v s="$start" -v e="$end" '{if ($4>=s && $4<=e) print}' \
            | sort -u -t. -k4,4n
        return
    fi
    local i host
    for i in $(seq "$start" "$end"); do
        host="${subnet}.${i}"
        if command -v arping >/dev/null 2>&1; then
            arping -c 1 -w 1 "$host" >/dev/null 2>&1 && printf '%s\n' "$host"
        else
            ping -c 1 -W 1 "$host" >/dev/null 2>&1 && printf '%s\n' "$host"
        fi
    done
}

# Escape values written by the shell JSON reporter. Runtime evidence is already
# single-line and size-capped, so escaping control characters used by probes is
# sufficient without depending on jq on the device.
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g'
}

# Materialize the confirmed-finding array as stable JSON beside the text log.
# Candidate and mDNS evidence remains in the text log to avoid representing
# unauthenticated hints as discovered instances to downstream tooling.
write_json_report() {
    local scan_id="$1" subnet="$2" hosts_scanned="$3" elapsed="$4"
    local json_file="${LOOT_BASE}/scan_${scan_id}.json" count i=0 h detail host_ip host_port comma
    count=${#FOUND_HOSTS[@]}
    {
        printf '{\n'
        printf '  "scan_id": "%s",\n' "$(json_escape "$scan_id")"
        printf '  "payload_version": "%s",\n' "$(json_escape "$PAYLOAD_VERSION")"
        printf '  "subnet": "%s",\n' "$(json_escape "$subnet")"
        printf '  "hosts_scanned": %d,\n' "$hosts_scanned"
        printf '  "elapsed_seconds": %d,\n' "$elapsed"
        printf '  "timestamp": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '  "instances": [\n'
        for h in "${FOUND_HOSTS[@]:-}"; do
            # FOUND_HOSTS is populated only by PROBE_CONFIRMED branches. Splitting
            # the final colon is safe because scanning is intentionally IPv4-only.
            detail="${FOUND_DETAILS[$i]:-}"
            host_ip="${h%%:*}"; host_port="${h##*:}"; comma=""
            [ $((i + 1)) -lt "$count" ] && comma=","
            printf '    {"ip":"%s","port":%d,"detail":"%s"}%s\n' \
                "$(json_escape "$host_ip")" "$host_port" "$(json_escape "$detail")" "$comma"
            i=$((i + 1))
        done
        printf '  ]\n}\n'
    } > "$json_file"
    log_entry "JSON report: $json_file"
}

# Build a de-duplicated, read-only view of confirmed endpoints from prior logs.
# This function uses Pager input helpers only after at least one entry exists.
show_history() {
    local -a instances=() files=() logfile inst idx=0 btn
    shopt -s nullglob
    files=("$LOOT_BASE"/scan_*.log)
    shopt -u nullglob
    for logfile in "${files[@]}"; do
        # Consume only the stable [FOUND] record prefix; candidates and mDNS
        # hints are deliberately excluded from historical confirmed state.
        while IFS= read -r inst; do [ -n "$inst" ] && instances+=("$inst"); done < <(
            grep '^\[FOUND\]' "$logfile" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}:[0-9]+' || true
        )
    done
    [ "${#instances[@]}" -gt 0 ] || { PROMPT "No confirmed history"; return; }
    mapfile -t instances < <(printf '%s\n' "${instances[@]}" | sort -u)
    while true; do
        LOG green "History $((idx + 1))/${#instances[@]}"
        LOG green "  ${instances[$idx]}"
        LOG "  UP/DOWN=nav B=done"
        btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            UP) [ "$idx" -gt 0 ] && idx=$((idx - 1)) ;;
            DOWN) [ "$idx" -lt $((${#instances[@]} - 1)) ] && idx=$((idx + 1)) ;;
            B|LEFT) break ;;
        esac
    done
}

# Compare this scan's confirmed endpoint set with older scan logs. Counts are
# written to the active log; the function never mutates historical artifacts.
run_diff() {
    [ "${#FOUND_HOSTS[@]}" -gt 0 ] || return
    local -A previous=() current=()
    local logfile inst new_count=0 gone_count=0
    for logfile in "$LOOT_BASE"/scan_*.log; do
        [ -f "$logfile" ] && [ "$logfile" != "$LOG_FILE" ] || continue
        while IFS= read -r inst; do [ -n "$inst" ] && previous["$inst"]=1; done < <(
            grep '^\[FOUND\]' "$logfile" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}:[0-9]+' || true
        )
    done
    for inst in "${FOUND_HOSTS[@]}"; do
        current["$inst"]=1
        [ -n "${previous[$inst]+x}" ] || new_count=$((new_count + 1))
    done
    for inst in "${!previous[@]}"; do [ -n "${current[$inst]+x}" ] || gone_count=$((gone_count + 1)); done
    log_entry "Diff: new=${new_count} gone=${gone_count}"
}

# Support both self-contained Portal packages (harvest.py beside payload.sh)
# and the canonical suite installation path.
_resolve_harvest_py() {
    local candidate
    for candidate in \
        "${CLAWHUNTER_PAYLOAD_DIR:-}/harvest.py" \
        /root/payloads/user/reconnaissance/clawhunter/harvest.py; do
        [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

# Launch the bounded Python assessment for a confirmed result. Gateway secrets
# come only from a protected local file or inherited environment and are never
# placed in argv, UI text, or logs. Exit codes map to operator-visible outcomes.
_do_harvest() {
    local host_ip="$1" host_port="$2" harvest_py log_path exit_code sid
    bootstrap_mmc_env
    command -v python3 >/dev/null 2>&1 || { ALERT "python3 required on eMMC"; return; }
    harvest_py=$(_resolve_harvest_py) || { ALERT "harvest.py not installed"; return; }
    log_path="${LOOT_BASE}/harvest_${host_ip}_$(date +%Y%m%d_%H%M%S).log"
    # A protected file takes precedence over an inherited value because it is
    # the documented on-device configuration mechanism. The value stays local.
    if [ -r /root/.config/clawhunter/gateway-token ]; then
        OPENCLAW_GATEWAY_TOKEN=$(head -n 1 /root/.config/clawhunter/gateway-token)
        export OPENCLAW_GATEWAY_TOKEN
    fi
    LOG blue "Harvesting ${host_ip}:${host_port}"
    sid=$(START_SPINNER "Harvesting ${host_ip}...")
    python3 "$harvest_py" --ip "$host_ip" --port "$host_port" --out "$log_path" --timeout 180
    exit_code=$?
    STOP_SPINNER "$sid"
    case "$exit_code" in
        0) led_found; ringtone_found; vibrate_strong; ALERT "Harvest complete\n$(basename "$log_path")" ;;
        1) LOG red "Authentication required"; led_complete_none ;;
        2) LOG red "Target unreachable" ;;
        *) LOG red "Harvest incomplete (${exit_code})" ;;
    esac
}

# Navigate confirmed findings without changing scan state. Only RIGHT launches
# assessment; unrelated buttons no longer trigger network activity implicitly.
show_results_browser() {
    [ "${FOUND_COUNT:-0}" -gt 0 ] || return
    local idx=0 host detail host_ip host_port btn
    PROMPT "Press any key to browse finds"
    while true; do
        host="${FOUND_HOSTS[$idx]}"; detail="${FOUND_DETAILS[$idx]:-}"
        host_ip="${host%%:*}"; host_port="${host##*:}"
        LOG green "Find $((idx + 1))/${FOUND_COUNT}"
        LOG green "  ${host_ip}:${host_port}"
        LOG "  ${detail:0:55}"
        LOG "  UP/DOWN=nav B=done RIGHT=harvest"
        btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            UP) [ "$idx" -gt 0 ] && idx=$((idx - 1)) ;;
            DOWN) [ "$idx" -lt $((FOUND_COUNT - 1)) ] && idx=$((idx + 1)) ;;
            B|LEFT) break ;;
            RIGHT) _do_harvest "$host_ip" "$host_port" ;;
        esac
    done
}
