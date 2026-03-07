# ✦ CLAWHunter

A [Hak5 WiFi Pineapple Pager](https://docs.hak5.org/wifi-pineapple-pager/) payload **suite** for discovering [OpenClaw](https://docs.openclaw.ai) AI gateway instances on local networks. Three payload variants — interactive, recon-triggered, and alert-fired — sharing a common fingerprinting library. Full hardware integration: color display, RGB LEDs, haptic feedback, audio cues, and an interactive results browser.

![Platform](https://img.shields.io/badge/platform-Hak5%20WiFi%20Pineapple%20Pager-red)
![Language](https://img.shields.io/badge/script-Bash-yellow)
![Category](https://img.shields.io/badge/category-Reconnaissance-blue)
![Version](https://img.shields.io/badge/version-3.1.0-green)

---

## What's new in v3.1.0

| Change | Detail |
|--------|--------|
| **Multi-turn agent session** | Phase 3 completely rewritten: instead of 15 independent one-shot agent queries, a single persistent WebSocket session drives up to 5 sequential turns. The agent maintains full conversation context across turns. |
| **Agent-native tool exploitation** | Turns now invoke the agent's own built-in tools — `exec`, `Read`, `memory_search`, `sessions_list`, `sessions_history`, and `nodes` — rather than plain natural-language commands. Deeper access, more structured output. |
| **Out-of-band exfil** | New `--exfil-telegram <bot_token>:<chat_id>` and `--exfil-webhook <URL>` flags. Turn 5 instructs the victim agent to `curl` the harvested summary directly to the attacker endpoint — data never touches the Pager log. |
| **OOB UI prompts in results browser** | `_do_harvest()` in `lib/common.sh` now asks whether to activate OOB exfil and which method before launching harvest. Operator pre-configures `EXFIL_BOT_TOKEN`, `EXFIL_CHAT_ID`, or `EXFIL_WEBHOOK_URL` in `payload.sh`. |
| **Improved streaming parser** | `recv_until_done()` now handles both `event.payload.delta` (str and list-of-blocks) and `event.payload.content` shapes, plus all final `res` statuses (`done`, `error`, `complete`, `cancelled`). |

### Turn breakdown (v3.1.0 agent session)

| Turn | Label | Agent tools used | Timeout |
|------|-------|-----------------|---------|
| 1 | System enumeration | `exec` (uname, id, env, ps, ls, find, grep), `Read` (openclaw.json, secrets.json, .env, MEMORY.md, USER.md, TOOLS.md) | 60s |
| 2 | Memory semantic search | `memory_search` — 16 credential/secret keywords | 30s |
| 3 | Session history | `sessions_list`, `sessions_history` (last 20 msgs × 5 sessions) | 30s |
| 4 | Paired nodes | `nodes` action=status, action=describe | 20s |
| 5 | OOB exfil *(optional)* | `exec` — curl to Telegram bot or webhook URL | 20s |

### OOB exfil configuration

Uncomment and fill in the constants near the top of `payloads/user/clawhunter/payload.sh`:

```bash
# ── Out-of-band exfil config (optional — fill in before deploying) ──────────
# EXFIL_BOT_TOKEN=""   # Telegram bot token for OOB exfil (from @BotFather)
# EXFIL_CHAT_ID=""     # Telegram chat_id to receive exfil data
# EXFIL_WEBHOOK_URL="" # Alternative: HTTPS webhook URL for OOB exfil
```

When the results browser launches a harvest, it will prompt:
1. **"Out-of-band exfil?"** — YES activates it, NO skips Turn 5 entirely.
2. **"Exfil method?"** — YES = Telegram, NO = Webhook.

The victim agent then uses its own `exec` tool to transmit the data directly to the attacker endpoint — the exfil path never crosses the Pager.

---

## What's new in v3.0.3

| Change | Detail |
|--------|--------|
| **Timing dither** | Each scan profile now applies a randomized inter-probe delay (base + jitter). Breaks the metronomic timing signature that stateful IDS engines key on. Works alongside the existing randomized host order (Feature 4) for a two-axis evasion approach: *what* is scanned is shuffled, *when* it is probed is dithered. |
| **Dead import removed** | `hashlib` was imported but never called in `harvest.py`. Removed. |

### Dither values per profile

| Profile | Base delay | Max jitter | Total max | Intent |
|---------|-----------|-----------|-----------|--------|
| GHOST | 0 ms | 0 ms | 0 ms | Passive only — no probes |
| QUIET | 50 ms | 200 ms | 250 ms | Mimics human-paced browsing; very low IDS signature |
| NORMAL | 0 ms | 80 ms | 80 ms | Breaks metronomic timing without slowing scan |
| FAST | 0 ms | 25 ms | 25 ms | Minimal — enough to avoid exact-interval detection |
| AGGRESSIVE | 0 ms | 0 ms | 0 ms | Speed priority; IDS risk accepted |

Jitter uses `$RANDOM % (max+1)` — bash builtin, no external tools.

---

## What's new in v3.0.0

| # | Feature | Description |
|---|---------|-------------|
| A1 | **WebSocket probe** | Raw WS upgrade via `/dev/tcp` — protocol-layer confirmation (~99% accuracy) |
| A2 | **Canvas path probe** | `/__openclaw__/canvas/` + `/__openclaw__/a2ui/` — OpenClaw-unique HTTP paths |
| A3 | **`/agent/status` intel** | Extract model, context%, active tool calls, sub-agent count, uptime |
| B1 | **Recon payload variant** | RF-first: reads Recon context vars, connects, scans — no pickers needed |
| B2 | **Alert payload variant** | Auto-fires on client connect — single-host probe, <5s, silent |
| C1 | **Continuous mDNS monitor** | Timed mDNS loop with countdown (configurable dwell, default 30s) |
| C2 | **ARP cache harvest** | `/proc/net/arp` + `ip neigh` check before ARP scan — known hosts skip discovery |
| D1 | **JSON report output** | Structured `scan_YYYYMMDD_HHMMSS.json` alongside `.log` files |
| E1 | **MAC randomization** | Randomize scanner MAC (macchanger or ip link), restore on exit |
| F4 | **Scan speed profiles** | GHOST / QUIET / NORMAL / FAST / AGGRESSIVE — replaces binary fast/slow |
| F5 | **Watchdog mode** | Periodic rescan with configurable interval, alerts only on changes |

---

## v2.1.0 features (all preserved)

| # | Feature | Description |
|---|---------|-------------|
| 1 | **Silent mode** | Suppress all audio and haptic for covert operations |
| 2 | **Progress counter** | Live `%` in spinner with host index tracking (`n/total`) |
| 3 | **ARP host discovery** | Layer-2 host detection via `arp-scan` → `arping` → ping fallback |
| 4 | **Randomized scan order** | Shuffle host list to reduce IDS/IPS detection signature |
| 5 | **HTTPS probe** | Try `http://` then `https://` per open port for TLS-wrapped gateways |
| 6 | **Extended ports** | Optionally sweep 80, 443, 3000, 8080, 8443 (reverse proxy detection) |
| 7 | **mDNS pre-scan** | `avahi-browse` zero-probe discovery (now continuous in user payload) |
| 8 | **Deep fingerprinting** | Extract version, persona, server headers from `/health`, `/status`, etc. |
| 9 | **WiFi client mode** | Connect to a target AP via Recon or manual SSID/password, auto-scan |
| 10 | **Multi-subnet sweep** | After each scan, loop back to scan another subnet without restarting |
| 11 | **Cross-run history/diff** | Browse all past finds; diff new vs. gone instances vs. prior runs |

---

## Repository structure

```
CLAWHunter/
├── lib/
│   └── common.sh                     ← Shared library (LED, audio, probing, fingerprinting)
├── payloads/
│   ├── user/clawhunter/
│   │   └── payload.sh                ← Interactive payload (all features, Pager UI)
│   ├── recon/clawhunter/
│   │   └── payload.sh                ← Recon variant (RF-first, auto-connect)
│   └── alert/clawhunter-watchdog/
│       └── payload.sh                ← Alert variant (auto-fires, <5s, silent)
├── payload.sh                        ← Legacy v2.1.0 (kept for reference)
└── README.md
```

---

## Hardware features used

| Hardware | Usage |
|----------|-------|
| **480×222 px 16-bit color display** | Color-coded LOG output, interactive pickers, ALERT popups, results browser, history browser, mDNS countdown |
| **RGB LED array (4 LEDs)** | Blue pulse = scanning, fast green = confirmed, alternating = candidate, cyan = mDNS/passive, white = WiFi connecting, magenta = watchdog sleep, red = error |
| **Haptic (vibration)** | Soft (150ms) on candidate, medium (300ms) on mDNS/WiFi, strong (500ms) on confirmed; alert variant uses vibrate-only (SILENT forced) |
| **Audio (RINGTONE / RTTTL)** | Startup, find, mDNS find, candidate ping, complete ok/none, abort, WiFi connected, watchdog alert — all suppressed in silent mode |
| **5-button navigation** | UP/DOWN for pickers and profile selection; B to abort scan, exit browsers, exit watchdog |

---

## Payload variants

### User payload — `payloads/user/clawhunter/`
Full interactive experience. Launched from **Payloads → user → clawhunter** in the Pager UI. All 11 v2.1.0 features plus all v3.0.0 features. The primary payload for manual field ops.

### Recon payload — `payloads/recon/clawhunter/`
RF-first workflow. Launched from the **Recon UI** after selecting a target AP. Reads `_RECON_SELECTED_AP_*` context variables automatically — no manual subnet or port pickers. Prompts for password only if the AP is encrypted. Connects, scans, shows results, disconnects.

**Flow:** Recon UI selects AP → payload launches → reads AP context → password prompt (if WPA) → connect → one-shot mDNS prescan → ARP discovery → port sweep → results → disconnect

### Alert payload — `payloads/alert/clawhunter-watchdog/`
Zero-interaction auto-trigger. Fires whenever a client connects to the Pager's AP. Probes the connecting client's IP for an OpenClaw signature — no subnet sweep. Completes in <5 seconds. Silent by default. Vibrates on confirmed finds. Logs to `/root/loot/clawhunter/alert_YYYYMMDD_HHMMSS.log`.

---

## Deploy

### lib/ directory (required by all variants)

```bash
# Copy shared library to Pager
scp -r lib root@pineapple.lan:/root/payloads/

# Result on Pager:
# /root/payloads/lib/common.sh
```

### User payload

```bash
ssh root@pineapple.lan "mkdir -p /root/payloads/user/clawhunter"
scp payloads/user/clawhunter/payload.sh \
    root@pineapple.lan:/root/payloads/user/clawhunter/payload.sh
```

### Recon payload

```bash
ssh root@pineapple.lan "mkdir -p /root/payloads/recon/clawhunter"
scp payloads/recon/clawhunter/payload.sh \
    root@pineapple.lan:/root/payloads/recon/clawhunter/payload.sh
```

### Alert payload

```bash
ssh root@pineapple.lan "mkdir -p /root/payloads/alert/clawhunter-watchdog"
scp payloads/alert/clawhunter-watchdog/payload.sh \
    root@pineapple.lan:/root/payloads/alert/clawhunter-watchdog/payload.sh
```

### Deploy all at once

```bash
scp -r lib payloads root@pineapple.lan:/root/payloads/
```

**Directory layout on Pager after deploy:**
```
/root/payloads/
├── lib/
│   └── common.sh
├── user/clawhunter/payload.sh
├── recon/clawhunter/payload.sh
└── alert/clawhunter-watchdog/payload.sh
```

---

## Usage — User payload

Launch from **Payloads → user → clawhunter** in the Pager UI.

| Prompt | Default | Description |
|--------|---------|-------------|
| View scan history? | No | Browse past finds across all scan logs |
| Silent mode? | No | Suppress all audio and vibration |
| Randomize MAC? | No | Randomize scanner MAC, restore on exit (E1) |
| Scan profile | NORMAL | GHOST / QUIET / NORMAL / FAST / AGGRESSIVE (F4) |
| Connect to AP first? | No | WiFi client mode — connect before scanning |
| Target Subnet | Auto-detected | First three octets (e.g. `192.168.4`) |
| OpenClaw Port | `18790` | Primary target port |
| Advanced options? | No | Gate for port range, extended ports, randomize |
| → Wide port range? | No | Sweep `18780–18800` instead of single port |
| → Extended ports? | No | Also probe 80, 443, 3000, 8080, 8443 |
| → Randomize order? | No | Shuffle host list |
| Full /24 scan? | Yes | 254 hosts (~90s) or quick `.1–.50` (~20s) |
| mDNS dwell (sec) | 30 | Continuous mDNS monitor duration before port sweep |
| Watchdog mode? | No | After scan: periodic rescan with change alerts (F5) |
| → Rescan interval (min) | 5 | Minutes between watchdog rescans |

---

## Scan speed profiles (F4)

| Profile | Behavior | Dither (base + jitter) | Notes |
|---------|----------|----------------------|-------|
| **GHOST** | Passive only — mDNS monitor + ARP cache harvest, no port probes | none | Zero active traffic |
| **QUIET** | Sequential probes, 50ms floor, silent forced | 50ms + 0–200ms | Mimics human-paced browsing |
| **NORMAL** | Sequential probes, default behavior | 0ms + 0–80ms | Breaks metronomic timing |
| **FAST** | Parallel probes (3 hosts at a time) | 0ms + 0–25ms | Minimal jitter, ~3× throughput |
| **AGGRESSIVE** | All ports + extended, 5 parallel probes | none | Speed priority, IDS risk accepted |

---

## Controls

| Button | Context | Action |
|--------|---------|--------|
| UP/DOWN | Pickers, profile selector | Adjust value / change selection |
| B | Profile selector | Confirm selection |
| B | Any picker | Cancel |
| B | During scan | Abort scan cleanly |
| B | mDNS countdown | Abort mDNS monitor early |
| UP/DOWN | Results browser | Navigate found hosts |
| RIGHT (or any unhandled key) | Results browser | Launch harvest against current find |
| B or LEFT | Results browser | Exit browser |
| UP/DOWN | History browser | Navigate past finds |
| B or LEFT | History browser | Exit browser |
| B | Watchdog countdown | Exit watchdog mode |
| Any | ALERT popup | Dismiss and continue scan |
| Any | Final PROMPT | Exit payload |

---

## OpenClaw fingerprinting (v3.0.0)

### Stage 0 — mDNS monitor (C1)
Continuous `avahi-browse` for a configurable dwell period (default 30s). Countdown visible on display. LED pulses cyan. Any service record matching `openclaw` or `clawd` = confirmed find, added before port sweep.

### Stage 1 — TCP connect
Fast closed-port filter via `nc -z -w 1`.

### Stage 2 — HTTP/HTTPS probe (features 5+6)
`curl` with 3s timeout. Tries `http://` then `https://`. Confirmed if: body contains `openclaw|clawd|gateway` keywords, or HTTP 400/401/403 on the primary target port.

### Stage 3 — Protocol-layer confirmation (A1)

WebSocket upgrade via `/dev/tcp`:
```
GET / HTTP/1.1
Upgrade: websocket
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
```
A valid OpenClaw gateway accepts the WS upgrade (HTTP 101). Detection confidence: **~99%**.

### Stage 4 — Canvas path probe (A2)
`GET /__openclaw__/canvas/` and `GET /__openclaw__/a2ui/`. These paths are unique to OpenClaw. Any non-404 HTTP response = near-certain confirmation.

### Stage 5 — `/agent/status` intel (A3)
`GET /agent/status?session=agent:main:main`. If the endpoint is live, extracts:
- Model in use (e.g. `anthropic/claude-opus-4-6`)
- Context usage percent
- Active tool calls count
- Sub-agent count
- Gateway uptime timestamp

---

## Harvest module (v3.1.0)

The integrated post-exploitation module triggers directly from the **Results Browser** after a confirmed OpenClaw find. No separate tool invocation required.

### What it does

Three-phase harvest against a confirmed target:

| Phase | Name | What it does |
|-------|------|--------------|
| 1 | **Auth probe** | WebSocket connect attempt — classifies target as OPEN, TOKEN_GATED, or UNREACHABLE |
| 2 | **HTTP harvest** | Probes `/__openclaw__/canvas/`, `/__openclaw__/a2ui/`, `/agent/status`, and `/` — records status codes, headers, and body content |
| 3 | **Multi-turn agent session** | OPEN portals only — single persistent WebSocket session drives 4–5 turns exploiting the agent's native tools (`exec`, `Read`, `memory_search`, `sessions_list`, `sessions_history`, `nodes`). Optional Turn 5 directs the agent to exfil data out-of-band to attacker Telegram or webhook. |

### Requirement

Python3 must be installed on the Pager:

```bash
opkg install -d mmc python3
```

harvest.py is stdlib-only — no pip, no third-party packages required.

### How to trigger

1. Run CLAWHunter until a confirmed OpenClaw instance appears in the Results Browser
2. Navigate to the target with **UP/DOWN**
3. Press **RIGHT** (or any key other than UP/DOWN/B/LEFT) to launch harvest

Display during harvest:
```
  Find 1/1                        ← green
    192.168.4.100                 ← green
    port: 18790                   ← blue
    http:// | HTTP 401 | ...
    UP/DOWN=nav  B=done  >=harvest
```

### What it collects

**On OPEN portals (no token required):**

*Turn 1 — System enumeration:*
- System identity: `uname -a`, `id`, `whoami`, `hostname`, `uptime`, `/etc/os-release`
- Network: `ip addr`, `ip route`, `/etc/hosts`
- Running processes: `ps aux`
- Full environment dump: `env | sort` — includes `ANTHROPIC_API_KEY` and other secrets
- Workspace listings: `~/`, `~/clawd/`, `~/.openclaw/`
- `~/.openclaw/openclaw.json` — full gateway config
- `~/.openclaw/secrets.json` — all gateway credentials
- `~/.openclaw/credentials/` — all credential JSON files
- `~/.openclaw/.env` — environment secrets file
- `~/.ssh/` listing + `id_rsa`, `id_ed25519`, `id_ecdsa`, `authorized_keys`
- `~/clawd/MEMORY.md`, `USER.md`, `TOOLS.md` — persona and knowledge files
- Token grep across `~/.openclaw/` and `~/clawd/`

*Turn 2 — Memory semantic search:*
- `memory_search` over 16 keywords: api_key, password, token, secret, credential, ssh, telegram, discord, webhook, database, postgres, mysql, redis, aws, openai, anthropic

*Turn 3 — Session history:*
- Full message content from the 5 most recent agent sessions (last 20 messages each)

*Turn 4 — Paired nodes:*
- All paired devices: names, types, capabilities, last-seen timestamps

*Turn 5 — OOB exfil (optional):*
- Agent curls secrets + memory to attacker Telegram bot or webhook — direct exfil from victim system, never via Pager

**On TOKEN_GATED portals:**
- HTTP harvest only (canvas, a2ui, agent/status, root path)
- No agent exploitation without a valid token

### Log location

```
/root/loot/clawhunter/harvest_<IP>_<YYYYMMDD_HHMMSS>.log
```

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Harvest complete — agent data collected |
| 1 | Token-gated — HTTP harvest only, no agent access |
| 2 | Unreachable — target went offline |
| 3 | Error — unexpected failure (check log) |

---

## Display behavior

**During scan:**
```
  ✦ CLAWHunter v3.0.0      ← blue
  OpenClaw Discovery Suite
  mDNS monitoring (30s)...  ← cyan (C1 countdown)
  mDNS: 25s remaining...
  Checking ARP cache...     ← blue (C2)
  Cache: 3 host(s) pre-known
  Discovering hosts...      ← blue
  Live hosts: 47
  12% — 192.168.4.6 (6/47)  ← blue
  ✦ FOUND: 192.168.4.100:18790 (http)  ← green
    HTTP 401 — token-gated gateway
    Model: claude-opus-4-6 | Ctx: 44%  ← (A3 intel)
```

**Profile selector:**
```
  Profile: FAST             ← green
    Parallel probes (3 at a time)
    UP/DOWN=change  B=confirm
```

**Watchdog sleeping:**
```
  Watchdog: next scan in 240s   ← magenta LED pulsing
  B to exit watchdog
```

---

## LED states

| State | Pattern | Color |
|-------|---------|-------|
| Scanning | Slow pulse (600ms / 400ms) | Blue |
| Candidate port open | Alternating 250ms | Blue ↔ Green |
| Confirmed OpenClaw | Fast flash (120ms) | Green |
| mDNS hit | Cyan double-flash (first 2 LEDs) | Cyan |
| Passive mDNS monitor | Slow pulse (800ms / 600ms) | Cyan |
| WiFi connecting | Slow pulse (500ms / 300ms) | White |
| Watchdog sleeping | Slow pulse (1000ms / 800ms) | Magenta |
| Error / abort | Solid 5s | Red |
| Complete — found | Slow pulse (700ms / 500ms) | Green |
| Complete — none | Slow pulse (700ms / 500ms) | Blue |
| Exiting | Off | — |

---

## Port reference

| Port | Description |
|------|-------------|
| `18790` | OpenClaw gateway default (agent port) |
| `18789` | OpenClaw control-plane (WebSocket probe target) |
| `18780–18800` | Wide range (non-default configs) |
| `80, 443` | Common reverse proxy ports |
| `3000, 8080, 8443` | Common dev/alt proxy ports |

> **Note:** OpenClaw binds to `loopback` by default. This payload finds instances where `gateway.bind` has been changed to a network interface, or those running behind a reverse proxy — exactly the configurations relevant for network-level discovery.

---

## Log output

### Text log (`.log`) — v2.1.0 format preserved

```
/root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log
/root/loot/clawhunter/alert_YYYYMMDD_HHMMSS.log   ← alert variant
```

Example:
```
==================================================
  CLAWHunter v3.0.0 — OpenClaw Discovery
  Hak5 WiFi Pineapple Pager
==================================================
Scan ID        : 20260307_143512
Date/Time      : Sat Mar  7 14:35:12 UTC 2026
Scanner IP     : 192.168.4.150
Subnet         : 192.168.4.1-254
Port(s)        : 18790
Wide range     : NO
Extended ports : NO
Randomized     : NO
Silent mode    : NO
Scan profile   : NORMAL
MAC randomized : YES
ARP available  : YES
avahi available: YES
==================================================

── mDNS MONITOR (30s) ──
[MDNS]      192.168.4.100 via mDNS | record: ...

── PORT SCAN ──
[14:35:42] C2: ARP cache harvest: 3 host(s)
[14:35:44] Probing: 192.168.4.100 (12/47, 25%)
[FOUND]     192.168.4.100:18790 | http | HTTP 401 | HTTP 401 — token-gated gateway
[14:35:44]   A1: WebSocket upgrade accepted — protocol-layer confirmed
[14:35:44]   A2: canvas path HTTP 200 — OpenClaw-unique path confirmed
[14:35:45]   A3: model=anthropic/claude-opus-4-6 ctx=44.5% tools=2 subagents=1
[14:35:45]   Detail: Version: 2026.3.2 | Persona: assistant | Model: anthropic/claude-opus-4-6 | Ctx: 44.5%

── DIFF vs PREVIOUS SCANS ──
  New instances : 1
  Gone instances: 0

==================================================
SUMMARY
  Hosts scanned  : 47
  OpenClaw found : 1
  Elapsed        : 95s
  Status         : COMPLETE

  DISCOVERED INSTANCES:
    ✦ 192.168.4.100:18790
==================================================
  Log : /root/loot/clawhunter/scan_20260307_143512.log
  JSON: /root/loot/clawhunter/scan_20260307_143512.json
==================================================
```

### JSON report (`.json`) — v3.0.0 new (D1)

```json
{
  "scan_id": "20260307_143512",
  "payload_version": "3.0.0",
  "subnet": "192.168.4.1-254",
  "hosts_scanned": 47,
  "elapsed_seconds": 95,
  "timestamp": "2026-03-07T14:37:47Z",
  "instances": [
    {
      "ip": "192.168.4.100",
      "port": "18790",
      "detail": "http:// | HTTP 401 — token-gated gateway | Version: 2026.3.2 | Persona: assistant | Model: anthropic/claude-opus-4-6 | Ctx: 44.5% | Canvas: confirmed | WS: confirmed",
      "fingerprint": {
        "version": "2026.3.2",
        "persona": "assistant",
        "model": "anthropic/claude-opus-4-6",
        "context_percent": "44.5%",
        "canvas_confirmed": true,
        "websocket_confirmed": true
      }
    }
  ]
}
```

---

## License

MIT — see [LICENSE](LICENSE)
