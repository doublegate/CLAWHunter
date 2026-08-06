#!/bin/bash
# shellcheck disable=SC2034 # Test fixtures set globals consumed by sourced functions.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMPDIR_TEST=$(mktemp -d /tmp/clawhunter-test-XXXXXX)
FIXTURE_PID=""
CHECKPOINT_TEST=""
# This trap owns only paths/processes created by this test. Tracking the two
# optional resources separately keeps cleanup valid after any early assertion.
cleanup_test() {
    # Stop the loopback fixture before removing its port/report files.
    [ -z "$FIXTURE_PID" ] || kill "$FIXTURE_PID" 2>/dev/null || true
    [ -z "$FIXTURE_PID" ] || wait "$FIXTURE_PID" 2>/dev/null || true
    [ -z "$CHECKPOINT_TEST" ] || rm -f "$CHECKPOINT_TEST"
    rm -rf "$TMPDIR_TEST"
}
trap cleanup_test EXIT

LOOT_BASE="$TMPDIR_TEST/loot"
LOG_FILE="$TMPDIR_TEST/test.log"
SILENT=1
# Host tests replace Pager-only hardware/UI commands with no-ops. Network tools
# remain real except inside the two explicit classifier fixture sections.
LOG() { :; }
HAK5_API_POST() { :; }
RINGTONE() { :; }
# Capture vibration input so the test can enforce the documented RTTTL contract.
LAST_VIBRATION=""
VIBRATE() { LAST_VIBRATION="$1"; }

# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"

# Minimal assertion helpers keep this test runnable with the same Bash tooling
# used for payload development; no external shell test framework is required.
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    # Include both values because most failures involve a classifier/report
    # contract whose actual state would otherwise be lost when `set -e` exits.
    [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

# Input validation is a security boundary because values flow to nc and curl.
is_valid_ipv4 192.168.1.1 || fail "valid IPv4 rejected"
is_valid_ipv4 255.255.255.255 || fail "upper IPv4 boundary rejected"
! is_valid_ipv4 192.168.1.256 || fail "out-of-range IPv4 accepted"
! is_valid_ipv4 '192.168.1.1;id' || fail "unsafe IPv4 accepted"
is_valid_port 18789 || fail "valid port rejected"
! is_valid_port 0 || fail "zero port accepted"
! is_valid_port 65536 || fail "out-of-range port accepted"
assert_eq "$(subnet_prefix_from_ip 10.20.30.40)" "10.20.30"
# Reporter escaping must preserve literal backslash/quote data as valid JSON.
assert_eq "$(json_escape 'a\b"c')" 'a\\b\"c'

# Pager firmware interprets vibration as RTTTL note timing, not milliseconds.
# Exercise one wrapper with feedback enabled and restore silent test mode.
SILENT=0
vibrate_soft
[[ "$LAST_VIBRATION" =~ ^clawsoft:.*: ]] || fail "vibration is not RTTTL"
SILENT=1

# Checkpoint identity includes port semantics, and the shared marker accepts
# only validated IPv4 records under CLAWHunter's private /tmp filename prefix.
checkpoint_one=$(checkpoint_path 198.51.100 '65001 65002')
checkpoint_same=$(checkpoint_path 198.51.100 '65001 65002')
checkpoint_other=$(checkpoint_path 198.51.100 '65001')
CHECKPOINT_TEST="$checkpoint_one"
assert_eq "$checkpoint_one" "$checkpoint_same"
[ "$checkpoint_one" != "$checkpoint_other" ] || fail "port sets shared checkpoint identity"
checkpoint_mark "$checkpoint_one" 198.51.100.40
assert_eq "$(cat "$checkpoint_one")" "198.51.100.40"
rm -f "$checkpoint_one"
CHECKPOINT_TEST=""
! checkpoint_mark /tmp/not-clawhunter 192.0.2.41 || fail "unsafe checkpoint path accepted"

# Fixture 1: a generic protected web service with a generic WebSocket upgrade.
# It must remain a candidate even though several weak signals are present.
# Stub transport reachability independently from HTTP/WebSocket evidence. This
# fixture proves that open TCP plus generic application responses stays weak.
nc() { return 0; }
_http_evidence() {
    # All generic paths respond; canvas is explicitly absent to avoid adding its
    # low-weight point. The 401 itself must not become product confirmation.
    local path="$4"
    HTTP_EVIDENCE_HEADERS="Server: fixture"
    HTTP_EVIDENCE_BODY="generic response"
    HTTP_EVIDENCE_CODE=401
    [ "$path" != "/__openclaw__/canvas/" ] || HTTP_EVIDENCE_CODE=404
    return 0
}
# A generic successful upgrade is deliberately missing connect.challenge.
ws_probe() { WS_PROBE_RESPONSE='HTTP/1.1 101 Switching Protocols'; return 0; }
probe_openclaw 192.0.2.10 18789 || fail "generic fixture probe failed"
assert_eq "$PROBE_CLASS" "CANDIDATE"
assert_eq "$PROBE_CONFIRMED" "0"

# Fixture 1b: fast alert mode skips nc, so two failed HTTP transports must not
# become a zero-score candidate or trigger candidate hardware feedback.
PROBE_FAST=1
# No response in fast mode represents an event target with no gateway service.
_http_evidence() { return 1; }
! probe_openclaw 192.0.2.20 18789 || fail "silent fast probe became a candidate"
assert_eq "$PROBE_CLASS" "NONE"
assert_eq "$PROBE_CANDIDATE" "0"
PROBE_FAST=0

# Fixture 2: OpenClaw-specific headers/body plus connect.challenge. This crosses
# both the specific-evidence and score thresholds required for confirmation.
_http_evidence() {
    # Return current product evidence consistently for root and health. Canvas
    # stays absent so confirmation depends on strong, documented signals.
    local path="$4"
    HTTP_EVIDENCE_HEADERS="X-OpenClaw-Version: 2026.8"
    HTTP_EVIDENCE_BODY="OpenClaw Gateway"
    HTTP_EVIDENCE_CODE=200
    [ "$path" != "/__openclaw__/canvas/" ] || HTTP_EVIDENCE_CODE=404
    return 0
}
ws_probe() {
    # Product-specific challenge evidence is the decisive transport signal.
    WS_PROBE_RESPONSE='HTTP/1.1 101 Switching Protocols connect.challenge'
    return 0
}
probe_openclaw 192.0.2.11 18789 || fail "OpenClaw fixture probe failed"
assert_eq "$PROBE_CLASS" "CONFIRMED"
assert_eq "$PROBE_CHALLENGE_CONFIRMED" "1"

# Validate that shell-generated loot remains parseable by a strict JSON parser.
FOUND_HOSTS=("192.0.2.11:18789")
FOUND_DETAILS=('http:// | fixture')
write_json_report fixture 192.0.2 1 2
python3 -m json.tool "$LOOT_BASE/scan_fixture.json" >/dev/null

# Avahi rows are hints only, but the resolved IPv4/port must be parsed exactly.
MDNS_CANDIDATES=()
_record_mdns_candidates '=;eth0;IPv4;gateway;_openclaw-gw._tcp;local;gateway.local;192.0.2.12;18789;txt'
assert_eq "${MDNS_CANDIDATES[0]}" "192.0.2.12:18789"

# Integration fixture: restore the real library network functions, then verify
# actual curl/nc classification and the harvest CLI against one loopback server.
unset -f nc _http_evidence ws_probe
. "$ROOT/lib/common.sh"
port_file="$TMPDIR_TEST/fixture.port"
# The server publishes its kernel-selected ephemeral port through a file, which
# avoids fixed-port collisions in developer machines and parallel CI jobs.
python3 "$ROOT/tests/fixtures/openclaw_server.py" --port-file "$port_file" &
FIXTURE_PID=$!
for _attempt in $(seq 1 50); do
    [ -s "$port_file" ] && break
    sleep 0.05
done
[ -s "$port_file" ] || fail "loopback fixture did not start"
fixture_port=$(cat "$port_file")
probe_openclaw 127.0.0.1 "$fixture_port" || fail "loopback classifier probe failed"
assert_eq "$PROBE_CLASS" "CONFIRMED"
assert_eq "$PROBE_CHALLENGE_CONFIRMED" "1"

harvest_report="$TMPDIR_TEST/harvest.json"
# Use a fixed fixture token solely on the child process environment; the test
# also verifies the resulting report shows tool availability without the token.
OPENCLAW_GATEWAY_TOKEN=fixture-token python3 \
    "$ROOT/payloads/user/reconnaissance/clawhunter/harvest.py" \
    --ip 127.0.0.1 --port "$fixture_port" --out "$harvest_report" --timeout 10
python3 -m json.tool "$harvest_report" >/dev/null
grep -q '"status": "ASSESSED"' "$harvest_report" || fail "harvest was not assessed"
grep -q '"status": "AVAILABLE"' "$harvest_report" || fail "read-only tools unavailable"

printf 'test_common.sh: ok\n'
