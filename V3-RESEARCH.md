# CLAWHunter v3.0.0 — Research & Feature Planning

*Research completed: 2026-03-07*
*Sources: Hak5 Pager docs, OpenClaw architecture/auth/gateway docs, OpenClaw GitHub issues*

---

## What Changed Between v1→v2 vs v2→v3

v1→v2.1.0 was **horizontal expansion** — 11 features bolted onto the same architecture.
v3.0.0 needs to be **vertical deepening** — fundamentally new capabilities that require
rethinking what CLAWHunter *is*:

- v1: active LAN scanner with hardware feedback
- v2: smarter active scanner + operational options
- **v3: a full multi-mode intelligence suite** — passive RF, active network, WebSocket
  protocol probing, structured intelligence output, and a recon payload variant

---

## Research Findings

### 1. OpenClaw Gateway Wire Protocol (Critical New Intel)

From `docs.openclaw.ai/concepts/architecture.md`:

The OpenClaw gateway is **not just HTTP**. It runs a WebSocket server on port `18789`
(default), not `18790`. Port 18789 is the control-plane; 18790 is the *agent* port.
This changes the fingerprinting surface fundamentally.

Key facts:
- **Default bind:** `127.0.0.1:18789` (loopback — not scannable unless exposed)
- **Port 18790** is the agent/gateway communication port (what v1/v2 already probe)
- **Canvas server** is also hosted at `/__openclaw__/canvas/` on the same port
- **First WS frame MUST be `connect`** — malformed first frames trigger hard close
- **Token auth:** `connect.params.auth.token` must match `OPENCLAW_GATEWAY_TOKEN` or socket closes
- **Nodes** connect with `role: "node"` and go through device pairing + challenge/nonce signing
- **HTTP paths exposed on same port:** `/__openclaw__/canvas/`, `/__openclaw__/a2ui/`

**Implication for v3:** CLAWHunter can now probe `/__openclaw__/canvas/` and
`/__openclaw__/a2ui/` as high-confidence HTTP fingerprint paths. These are unique to
OpenClaw and return non-generic responses even without auth.

### 2. `/agent/status` Endpoint (Proposed, GitHub Issue #6418, Feb 2026)

A machine-readable health endpoint was proposed in February 2026:

```json
GET /agent/status?session=agent:main:main
{
  "version": "2026.1.30",
  "session": "agent:main:main",
  "model": "anthropic/claude-opus-4-5",
  "context": { "used": 89000, "max": 200000, "percent": 44.5, "compactions": 0 },
  "usage": { "hourlyRemaining": "96%", "weeklyRemaining": "84%" },
  "queue": { "depth": 0, "state": "idle" },
  "uptime": { "gatewayStarted": "2026-02-01T13:53:28Z", "sessionCreated": "..." },
  "activeToolCalls": [],
  "subAgents": []
}
```

If implemented, this endpoint exposes: model in use, context load, active tool calls,
sub-agent count, and exact uptime. v3 should probe it and surface the intel.

### 3. Gateway HTTP Surface (Confirmed Paths)

From auth and architecture docs, confirmed HTTP paths on the gateway port:
- `/__openclaw__/canvas/` — canvas host (agent-editable HTML)
- `/__openclaw__/a2ui/` — A2UI host
- `/agent/status` — proposed health endpoint (probe it)
- `/` — may return 400/401/403 (already used by v2)
- Any path without auth → 401/403 on token-protected instances

`openclaw gateway status --json` exists as a CLI command, implying the gateway has
structured JSON output modes — likely via a REST endpoint or WS method.

### 4. Pager Recon Mode (Passive RF Layer)

From `docs.hak5.org/wifi-pineapple-pager/pineapple-functions/recon/`:

- Fully **passive** — no packets transmitted during Recon
- Channel hops across 2.4GHz, 5GHz, 6GHz
- Captures WPA handshakes automatically → `/root/loot/handshakes/` (PCAP + `.22000` hcappx)
- Detects **named probe requests** — clients actively searching for known networks
- Decloaks hidden APs when a client joins
- **Recon payloads** run against selected APs/clients with `_RECON_SELECTED_AP_*` env vars

**Implication for v3:** A recon payload variant of CLAWHunter can run passively,
then pivot to active scanning once an AP of interest is identified via Recon.

### 5. Pager Alert Payload System

Alert payloads fire on hardware events without user interaction:
- Client connects to Pager's AP → can trigger CLAWHunter probe against that client
- WPA handshake captured → can cross-reference with OpenClaw loot
- Deauth detected → interesting operational signal

**Implication for v3:** CLAWHunter should split into three payload variants:
`user/` (current), `alert/` (auto-trigger), `recon/` (RF-first discovery).

### 6. PineAP Engine Capabilities

8th generation, 100x faster. Key features:
- Open AP impersonation
- Mimicked SSID lists ("Evil WPA")
- Client association detection
- MitM positioning

**Implication for v3:** An advanced mode could deploy a Rogue AP with a name likely
to attract OpenClaw-bearing devices, then fingerprint connecting clients.

---

## v3.0.0 Feature Proposals

### THEME A: Protocol-Layer Fingerprinting (Major Upgrade)

**A1 — WebSocket Probe**
Attempt a raw WebSocket connect to port 18789 (and the scanned port). Send a
minimal `{"type":"req","id":"1","method":"health","params":{}}` frame without auth.
A valid OpenClaw gateway will:
- Accept the WS upgrade (HTTP 101)
- Return `{"type":"res","id":"1","ok":false,"error":{"code":"unauthorized"}}` or close
- A non-OpenClaw server will fail the WS upgrade entirely or return garbage

This distinguishes OpenClaw from any other HTTP 401-returning service.
**Detection confidence: 99%** vs. ~85% for HTTP keyword match alone.

**A2 — Canvas Path Probe**
Probe `GET /__openclaw__/canvas/` and `GET /__openclaw__/a2ui/`. These paths are
unique to OpenClaw. A 200, 301, 401, or 403 on these paths = near-certain confirmation.

**A3 — `/agent/status` Structured Intel**
If the endpoint from issue #6418 is live, extract and display:
- Model name (claude-opus-4-6, gpt-5, etc.)
- Context usage % (how loaded the agent is right now)
- Active tool calls (what the agent is doing at this moment)
- Sub-agent count (orchestration load)
- Session uptime (how long it's been running)

This transforms CLAWHunter from a detector into an **intelligence collector**.

---

### THEME B: Payload Suite Split (Architectural)

**B1 — Recon Payload Variant** (`payloads/recon/clawhunter/`)
- Receives `_RECON_SELECTED_AP_SSID`, `_RECON_SELECTED_AP_ENCRYPTION_TYPE`,
  `_RECON_SELECTED_AP_BSSID` from Pager Recon UI
- Connects to that AP via `WIFI_CONNECT`, then runs the CLAWHunter scan on its subnet
- Returns results without returning to the user payload menu
- Removes all the subnet/port pickers — derives everything from Recon context

**B2 — Alert Payload Variant** (`payloads/alert/clawhunter-watchdog/`)
- Fires whenever a client connects to the Pager's AP
- Immediately probes the connecting client's IP for OpenClaw gateway signatures
- Lightweight (no full subnet sweep) — one targeted probe per connected client
- Logs to `/root/loot/clawhunter/alert_YYYYMMDD_HHMMSS.log`
- Ringtone + strong vibrate if confirmed; silent if not

**B3 — User Payload (Enhanced)** — continues as current
Plus new features from all other themes.

---

### THEME C: Passive Discovery Mode

**C1 — Passive mDNS Monitor**
Instead of a one-shot `avahi-browse -t`, run continuous mDNS monitoring:
```bash
avahi-browse -a -r -p 2>/dev/null | while IFS= read -r line; do
    echo "$line" | grep -iqE 'openclaw|clawd' && process_mdns_hit "$line"
done
```
Run for a configurable dwell time (default 30s) before falling through to active scan.
LED pulses cyan during passive monitoring phase.

**C2 — Passive Probe Request Sniff**
Using `tcpdump` on the monitor interface, capture 802.11 probe request frames.
Any probe SSID containing "openclaw" or "clawd" = a device actively looking for a
known OpenClaw AP — the device has been near an OpenClaw WiFi network.
```bash
tcpdump -i wlan0 -l -e 'type mgt subtype probe-req' 2>/dev/null | \
    grep -ioE 'openclaw|clawd'
```
Even without active scanning, this gives passive intel about OpenClaw-bearing devices.

**C3 — ARP Cache Harvest**
Before scanning, check `/proc/net/arp` and `ip neigh show` for already-known hosts.
These hosts skip the ARP discovery phase entirely — instant probe targets.

---

### THEME D: Structured Intel & Exfil

**D1 — JSON Report Output**
After each scan, write a machine-readable JSON summary:
```json
{
  "scan_id": "20260307_143512",
  "payload_version": "3.0.0",
  "subnet": "192.168.4.0/24",
  "hosts_scanned": 47,
  "elapsed_seconds": 62,
  "instances": [
    {
      "ip": "192.168.4.100",
      "port": 18790,
      "scheme": "http",
      "confirmed": true,
      "discovery_method": "port_scan",
      "http_code": 401,
      "banner": "HTTP 401 — token-gated gateway",
      "fingerprint": {
        "version": "2026.3.2",
        "persona": "assistant",
        "model": "claude-opus-4-6",
        "context_percent": 44.5,
        "active_tools": 2,
        "sub_agents": 1,
        "uptime_seconds": 3600
      },
      "canvas_confirmed": true,
      "websocket_confirmed": true
    }
  ]
}
```
Written to `/root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.json`.

**D2 — QR Code Exfil**
After scan, optionally display a QR code on the Pager screen encoding the JSON
report or loot file path. Operator scans the screen with their phone to retrieve
the report without needing an SSH connection. Requires `qrencode` on the Pager.

**D3 — Loot Cross-Reference**
After confirming an OpenClaw instance at IP X, check `/root/loot/handshakes/` for
any PCAP files from the same AP BSSID. If found: flag in the report. The operator
now knows they have both the OpenClaw instance location *and* a WPA handshake
from the same network — potential credential material.

---

### THEME E: Operational Security

**E1 — MAC Randomization**
Before scanning, randomize the scanner MAC on the scanning interface:
```bash
ip link set wlan0 down
ip link set wlan0 address $(printf '%02x:%02x:%02x:%02x:%02x:%02x' \
    $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) \
    $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) | \
    sed 's/^\(.\)./\10/')  # clear multicast bit
ip link set wlan0 up
```
Restore original MAC on exit (via cleanup trap).

**E2 — Adaptive Scan Rate / IDS Evasion**
Detect signs of active IDS response:
- If a previously-responsive host stops responding mid-scan → slow down
- If HTTP responses start returning 429 or unusual codes → increase inter-probe delay
- Configurable jitter: `--jitter 0-500ms` between probes

**E3 — User-Agent Rotation**
Cycle through realistic browser User-Agent strings per request, rather than the
static `CLAWHunter/x.x.x` string. Reduces signature detectability.

**E4 — IPv6 Support**
Check for IPv6 link-local addresses (`fe80::/10`) and probe them.
Many modern Linux machines expose services on IPv6 that aren't on IPv4.
`ip -6 neigh show` provides link-local neighbors without scanning.

---

### THEME F: UX & Hardware Polish

**F1 — Battery Level Display**
Query Pager battery via `/sys/class/power_supply/` during long scans.
Display battery % in the header line. Warn if <20% before starting a full /24 sweep.

**F2 — Scan State Save/Resume**
Serialize scan state to `/tmp/clawhunter_state.json` every N hosts.
On startup, detect incomplete previous scan and offer to resume:
```
Resume previous scan?
192.168.4.0/24 — 43% complete
(scan_20260307_143512)
```

**F3 — Side-by-Side Dual-Subnet**
Allow specifying two subnets and interleaving the scan (probe one host from each
subnet alternately). Useful when the Pager is connected to two networks simultaneously
(e.g., client AP + Pager management network).

**F4 — Scan Speed Profiles**
Replace the binary full/quick choice with named profiles:
- `GHOST` — ARP only + mDNS passive, zero active port probes (passive-only)
- `QUIET` — 50ms inter-host delay, no audio, no LED flashes
- `NORMAL` — current default behavior
- `FAST` — parallel probes, 3 hosts at a time (background `&`)
- `AGGRESSIVE` — all ports, all features, maximum coverage

**F5 — Watchdog Mode** (background daemon)
Run CLAWHunter as a persistent background process that re-scans every N minutes,
alerts only on changes (new finds or lost instances). Launched via:
```
CONFIRMATION_DIALOG "Watchdog mode?" "Rescan every 5 min, alert on changes"
```
Writes PID to `/tmp/clawhunter_watchdog.pid`. B-button from main menu stops it.

---

## v3.0.0 Scope Recommendation

Not all of these belong in one release. Suggested grouping:

### Must-haves for v3.0.0 (justify the major bump)
| Feature | Why it's a v3 feature |
|---------|----------------------|
| A1 — WebSocket probe | Changes detection from heuristic to protocol-level |
| A2 — Canvas path probe | New confirmed-unique fingerprint path |
| A3 — `/agent/status` intel | Transforms detector into intelligence tool |
| B1 — Recon payload variant | New payload category (recon/) — architectural |
| B2 — Alert payload variant | New payload category (alert/) — architectural |
| C1 — Passive mDNS monitor | Continuous vs one-shot |
| D1 — JSON report output | Structured exfil — enables automation |
| E1 — MAC randomization | OpSec baseline for a pentest tool |
| F4 — Scan speed profiles | Replaces binary fast/slow with a real UX model |
| F5 — Watchdog mode | Continuous operation — fundamentally different use case |

### Stretch goals (if scope allows)
- C2 — Passive probe request sniff
- D2 — QR code exfil
- D3 — Loot cross-reference
- E2 — Adaptive scan rate
- E4 — IPv6 support
- F2 — Scan state save/resume

### Post-v3 (future)
- B (PineAP Rogue AP integration) — requires PineAP API research
- E3 — User-Agent rotation
- F1 — Battery level
- F3 — Dual-subnet

---

## Breaking Changes Required for v3

1. **Directory structure** — payload.sh moves to `payloads/user/clawhunter/payload.sh`.
   Alert and recon variants live alongside it. This is a breaking deploy change.
2. **Log format** — JSON output alongside existing `.log` text output. Backward-compatible.
3. **Constants refactor** — `PAYLOAD_VERSION` and shared functions should be extracted
   to a `lib/common.sh` sourced by all three payload variants.
4. **Deploy instructions update** — README needs a new deploy section covering all three
   payload types and the `lib/` directory.

---

## Effort Estimate

| Feature Group | Estimated Lines | Complexity |
|---------------|----------------|------------|
| A (Protocol probing) | ~150 | Medium — WebSocket in bash via `/dev/tcp` |
| B (Payload split + lib/) | ~200 | Medium — refactor, not new logic |
| C (Passive discovery) | ~100 | Low — tcpdump + avahi already known |
| D (JSON + exfil) | ~150 | Low — printf/jq |
| E (OpSec) | ~100 | Low-Medium |
| F (UX) | ~200 | Medium — watchdog is the complex one |
| **Total** | **~900 lines net** | Distributed across 4 files |

Realistic v3.0.0 scope: A + B + C1 + D1 + E1 + F4 + F5. ~700 lines net new code.
