# ✦ CLAWHunter

A [Hak5 WiFi Pineapple Pager](https://docs.hak5.org/wifi-pineapple-pager/) payload **suite** for discovering and exploiting [OpenClaw](https://docs.openclaw.ai) AI gateway instances on local networks. Three payload variants — interactive, recon-triggered, and alert-fired — share a common fingerprinting library. Full hardware integration: color display, RGB LEDs, haptic feedback, audio cues, interactive results browser, and an integrated post-exploitation harvest engine.

![Platform](https://img.shields.io/badge/platform-Hak5%20WiFi%20Pineapple%20Pager-red)
![Language](https://img.shields.io/badge/script-Bash%20%2B%20Python3-yellow)
![Category](https://img.shields.io/badge/category-Reconnaissance%20%2F%20Exploitation-blue)
![Version](https://img.shields.io/badge/version-3.1.0-green)

---

## Version history at a glance

| Version | What it added |
|---------|--------------|
| v1.0.0 | Initial LAN scanner — ARP discovery, port probe, hardware feedback |
| v2.1.0 | Silent mode, progress counter, ARP L2 discovery, randomized scan order, HTTPS probe, extended ports, mDNS pre-scan, deep fingerprinting, WiFi client mode, multi-subnet sweep, cross-run history/diff |
| v3.0.0 | Three-payload suite, shared lib, WS probe, canvas path probe, `/agent/status` intel, ARP cache harvest, continuous mDNS monitor, JSON reports, MAC randomization, scan speed profiles, watchdog mode |
| v3.0.1 | OpenWRT compatibility fixes: `grep -oP` → `awk`, `shuf` → awk PRNG, `/dev/tcp` + `nc` fallback, `TEXT_PICKER` removed (DuckyScript limitation) |
| v3.0.2 | Integrated harvest module (Option A): `harvest.py` triggered from results browser |
| v3.0.3 | Timing dither per scan profile; dead `hashlib` import removed from harvest.py |
| v3.1.0 | Multi-turn agent session, agent-native tool exploitation (`memory_search`, `sessions_history`, `nodes`), out-of-band exfil (Telegram / webhook) |

---

## What's new in v3.1.0

| Change | Detail |
|--------|--------|
| **Multi-turn agent session** | Phase 3 rewritten: a single persistent WebSocket session drives up to 5 sequential turns. The agent maintains full conversation context across turns — each turn builds on what the previous turn discovered. |
| **Agent-native tool exploitation** | Turns invoke the agent's own built-in tools: `exec`, `Read`, `memory_search`, `sessions_list`, `sessions_history`, `nodes` — rather than plain natural-language requests. Deeper access, structured output. |
| **Out-of-band exfil** | Turn 5 (optional): instructs the victim agent to `curl` the harvested summary directly to an attacker-controlled Telegram bot or webhook. Data flows from victim system to attacker endpoint — never via the Pager. |
| **OOB UI prompts** | `_do_harvest()` asks whether to activate OOB exfil and which method before launching. Operator pre-configures `EXFIL_BOT_TOKEN`/`EXFIL_CHAT_ID` or `EXFIL_WEBHOOK_URL` in `payload.sh`. |
| **Improved streaming parser** | `recv_until_done()` handles both `event.payload.delta` (str and list-of-blocks) and `event.payload.content` shapes, plus all final `res` statuses: `done`, `error`, `complete`, `cancelled`. |

### Agent session turns (v3.1.0)

| Turn | Label | Agent tools used | Per-turn timeout |
|------|-------|-----------------|-----------------|
| 1 | System enumeration | `exec` (uname, id, env, ps, ls, find, grep), `Read` (openclaw.json, secrets.json, .env, MEMORY.md, USER.md, TOOLS.md) | 60s |
| 2 | Memory semantic search | `memory_search` — 16 credential/secret keywords | 30s |
| 3 | Session history | `sessions_list`, `sessions_history` (last 20 msgs × 5 sessions) | 30s |
| 4 | Paired nodes | `nodes` action=status, action=describe | 20s |
| 5 | OOB exfil *(optional)* | `exec` — curl POST to Telegram bot API or webhook URL | 20s |

### OOB exfil configuration

Uncomment and fill in the constants near the top of `payloads/user/clawhunter/payload.sh` **before deploying** to the Pager:

```bash
# ── Out-of-band exfil config (optional — fill in before deploying) ──────────
# EXFIL_BOT_TOKEN=""   # Telegram bot token for OOB exfil (from @BotFather)
# EXFIL_CHAT_ID=""     # Telegram chat_id to receive exfil data
# EXFIL_WEBHOOK_URL="" # Alternative: HTTPS webhook URL for OOB exfil
```

When harvest is triggered from the results browser, two prompts appear:
1. **"Out-of-band exfil?"** — YES activates Turn 5, NO skips it entirely
2. **"Exfil method?"** — YES = Telegram bot, NO = Webhook URL

---

## What's new in v3.0.3

| Change | Detail |
|--------|--------|
| **Timing dither** | Each scan profile now applies a randomized inter-probe delay (base + jitter). Breaks the metronomic timing signature stateful IDS engines fingerprint. Works alongside randomized host order (Feature 4) for two-axis evasion: *what* is scanned is shuffled, *when* each probe fires is dithered. |
| **Dead import removed** | `hashlib` was imported but never called in `harvest.py`. Removed. |

### Dither values per profile

| Profile | Base delay | Max jitter | Total max | Intent |
|---------|-----------|-----------|-----------|--------|
| GHOST | 0 ms | 0 ms | 0 ms | Passive only — no probes |
| QUIET | 50 ms | 200 ms | 250 ms | Mimics human-paced browsing; very low IDS signature |
| NORMAL | 0 ms | 80 ms | 80 ms | Breaks metronomic timing without slowing scan |
| FAST | 0 ms | 25 ms | 25 ms | Minimal — enough to avoid exact-interval detection |
| AGGRESSIVE | 0 ms | 0 ms | 0 ms | Speed priority; IDS risk accepted |

Jitter is computed via `$RANDOM % (max+1)` — bash builtin, no external tools required.

---

## What's new in v3.0.0

| # | Feature | Description |
|---|---------|-------------|
| A1 | **WebSocket probe** | Raw WS upgrade via `/dev/tcp` (+ `nc` fallback) — protocol-layer confirmation (~99% accuracy) |
| A2 | **Canvas path probe** | `/__openclaw__/canvas/` + `/__openclaw__/a2ui/` — OpenClaw-unique HTTP paths |
| A3 | **`/agent/status` intel** | Extract model, context%, active tool calls, sub-agent count, uptime |
| B1 | **Recon payload variant** | RF-first: reads Recon context vars, connects, scans — no manual pickers needed |
| B2 | **Alert payload variant** | Auto-fires on client connect — single-host probe, <5s, silent forced |
| C1 | **Continuous mDNS monitor** | Timed `avahi-browse` loop with live countdown (configurable dwell, default 30s) |
| C2 | **ARP cache harvest** | `/proc/net/arp` + `ip neigh` checked before ARP scan — known hosts skip discovery |
| D1 | **JSON report output** | Structured `scan_YYYYMMDD_HHMMSS.json` alongside `.log` files |
| E1 | **MAC randomization** | Randomize scanner MAC (`macchanger` or `ip link`), restored on exit via trap |
| F4 | **Scan speed profiles** | GHOST / QUIET / NORMAL / FAST / AGGRESSIVE — replaces binary fast/slow |
| F5 | **Watchdog mode** | Post-scan periodic rescan; alerts only on new or gone instances |

---

## v2.1.0 features (all preserved)

| # | Feature | Description |
|---|---------|-------------|
| 1 | **Silent mode** | Suppress all audio and haptic for covert operations |
| 2 | **Progress counter** | Live `%` in spinner with host index tracking (`n/total`) |
| 3 | **ARP host discovery** | Layer-2 host detection via `arp-scan` → `arping` → ping fallback |
| 4 | **Randomized scan order** | Shuffle host list (awk PRNG — busybox compatible) to reduce IDS signature |
| 5 | **HTTPS probe** | Try `http://` then `https://` per open port for TLS-wrapped gateways |
| 6 | **Extended ports** | Optionally sweep 80, 443, 3000, 8080, 8443 (reverse proxy detection) |
| 7 | **mDNS pre-scan** | `avahi-browse` zero-probe discovery (continuous in user payload via C1) |
| 8 | **Deep fingerprinting** | Extract version, persona, server headers from `/health`, `/status`, etc. |
| 9 | **WiFi client mode** | Connect to a target AP via Recon UI context vars; auto-scan the AP subnet |
| 10 | **Multi-subnet sweep** | After each scan, loop back to scan another subnet without restarting |
| 11 | **Cross-run history/diff** | Browse all past finds; diff new vs. gone instances vs. prior runs |

---

## Repository structure

```
CLAWHunter/
├── lib/
│   └── common.sh                     ← Shared library (LED, audio, fingerprinting, harvest trigger)
├── payloads/
│   ├── user/clawhunter/
│   │   ├── payload.sh                ← Interactive payload (all features)
│   │   └── harvest.py                ← Post-exploitation harvest engine (Python3, stdlib-only)
│   ├── recon/clawhunter/
│   │   └── payload.sh                ← Recon variant (RF-first, auto-connect)
│   └── alert/clawhunter-watchdog/
│       └── payload.sh                ← Alert variant (auto-fires, <5s, silent)
└── payload.sh                        ← Legacy v2.1.0 single-file payload (reference only)
```

---

## Hardware features used

| Hardware | Usage |
|----------|-------|
| **480×222 px 16-bit color display** | Color-coded LOG output, interactive pickers, profile selector, ALERT popups, results browser, history browser, mDNS countdown, watchdog countdown |
| **RGB LED array (4 LEDs)** | Blue = scanning, fast green = confirmed, alternating = candidate, cyan = mDNS/passive, white = WiFi connecting, magenta = watchdog sleeping, red = error |
| **Haptic (vibration)** | Soft (150ms) on candidate, medium (300ms) on mDNS/WiFi, strong (500ms) on confirmed find, harvest complete, and scan complete; alert variant uses vibrate-only (SILENT forced) |
| **Audio (RINGTONE / RTTTL)** | Startup, find, mDNS find, candidate ping, complete ok/none, abort, WiFi connected, watchdog alert — all suppressed in silent mode |
| **5-button navigation** | UP/DOWN for pickers and profile selection; B to abort scan, exit browsers, exit watchdog; RIGHT to trigger harvest from results browser |

---

## Payload variants

### User payload — `payloads/user/clawhunter/`

Full interactive experience. Launched from **Payloads → user → clawhunter** in the Pager UI. All 11 v2.1.0 features plus all v3.0.0 features, timing dither, and the integrated harvest module. The primary payload for manual field ops.

### Recon payload — `payloads/recon/clawhunter/`

RF-first workflow. Launched from the **Recon UI** after selecting a target AP. Reads `_RECON_SELECTED_AP_SSID`, `_RECON_SELECTED_AP_ENCRYPTION_TYPE`, and `_RECON_SELECTED_AP_BSSID` context variables automatically — no manual subnet or port pickers. If the AP is encrypted but credentials are not pre-saved on the Pager, a notice is shown and the connection is attempted using saved credentials. Connects, scans, shows results, disconnects.

**Flow:** Recon UI selects AP → payload reads AP context → pre-saved credential notice (if WPA) → connect → mDNS prescan → ARP discovery → port sweep → results browser → disconnect

### Alert payload — `payloads/alert/clawhunter-watchdog/`

Zero-interaction auto-trigger. Fires whenever a client connects to the Pager's AP. Probes the connecting client's IP for an OpenClaw gateway signature — no subnet sweep. Completes in <5 seconds. Silent forced. Vibrates on confirmed finds. Logs to `/root/loot/clawhunter/alert_YYYYMMDD_HHMMSS.log`.

---

## Deploy

### Prerequisites

The shared library must be present at `/root/payloads/lib/common.sh` on the Pager. The harvest module (`harvest.py`) must be deployed alongside the user payload. All paths are hardcoded to `/root/` which is the Pager's standard layout.

**Optional — install python3 for harvest module:**
```bash
# Run on the Pager via SSH:
opkg update && opkg install -d mmc python3
```

### Deploy all at once (recommended)

```bash
# From repo root — deploy lib + all three payload directories:
ssh root@pineapple.lan "mkdir -p /root/payloads/lib \
    /root/payloads/user/clawhunter \
    /root/payloads/recon/clawhunter \
    /root/payloads/alert/clawhunter-watchdog"

scp lib/common.sh \
    root@pineapple.lan:/root/payloads/lib/common.sh

scp payloads/user/clawhunter/payload.sh \
    payloads/user/clawhunter/harvest.py \
    root@pineapple.lan:/root/payloads/user/clawhunter/

scp payloads/recon/clawhunter/payload.sh \
    root@pineapple.lan:/root/payloads/recon/clawhunter/

scp payloads/alert/clawhunter-watchdog/payload.sh \
    root@pineapple.lan:/root/payloads/alert/clawhunter-watchdog/
```

Or with rsync (preserves structure automatically):
```bash
rsync -av lib/ root@pineapple.lan:/root/payloads/lib/
rsync -av payloads/ root@pineapple.lan:/root/payloads/
```

### Expected layout on Pager after deploy

```
/root/payloads/
├── lib/
│   └── common.sh
├── user/clawhunter/
│   ├── payload.sh
│   └── harvest.py          ← required for harvest module
├── recon/clawhunter/
│   └── payload.sh
└── alert/clawhunter-watchdog/
    └── payload.sh
```

---

## Usage — User payload

Launch from **Payloads → user → clawhunter** in the Pager UI.

### Upfront prompts (before scan)

| Prompt | Default | Description |
|--------|---------|-------------|
| View scan history? | No | Browse past finds across all scan logs (only shown if prior logs exist) |
| Silent mode? | No | Suppress all audio and vibration |
| Randomize MAC? | No | Randomize scanner MAC, restore on exit via cleanup trap (E1) |
| Scan profile | NORMAL | GHOST / QUIET / NORMAL / FAST / AGGRESSIVE (F4) |
| Connect to AP first? | No | WiFi client mode — requires Recon UI AP selection or pre-saved credentials |
| Target subnet | Auto-detected | First three octets (e.g. `192.168.4`) |
| OpenClaw port | `18790` | Primary target port |
| Advanced options? | No | Gate for port range, extended ports, randomize order |
| → Wide port range? | No | Sweep `18780–18800` instead of single port |
| → Extended ports? | No | Also probe 80, 443, 3000, 8080, 8443 |
| → Randomize order? | No | Shuffle host list with awk PRNG |
| Full /24 scan? | Yes | 254 hosts (~90s NORMAL) or quick `.1–.50` (~20s) |
| mDNS dwell (sec) | 30 | Continuous mDNS monitor duration before port sweep *(only shown if `avahi-browse` is installed)* |

### Post-scan prompts (after scan completes with finds)

| Prompt | Default | Description |
|--------|---------|-------------|
| Watchdog mode? | No | Periodic rescan, alerts only on new/gone instances (F5) *(only offered if ≥1 instance found)* |
| → Rescan interval (min) | 5 | Minutes between watchdog rescans |

---

## Scan speed profiles (F4)

| Profile | Behavior | Dither (base + jitter) | Notes |
|---------|----------|----------------------|-------|
| **GHOST** | Passive only — mDNS monitor + ARP cache harvest, no port probes | none | Zero active traffic |
| **QUIET** | Sequential probes, 50ms floor, silent mode forced | 50ms + 0–200ms | Mimics human-paced browsing |
| **NORMAL** | Sequential probes, default behavior | 0ms + 0–80ms | Breaks metronomic timing |
| **FAST** | Parallel probes (3 hosts at a time) | 0ms + 0–25ms | Minimal jitter, ~3× throughput |
| **AGGRESSIVE** | All ports + extended, 5 parallel probes | none | Speed priority, IDS risk accepted |

Dither applies `$RANDOM % (jitter+1)` — bash builtin, no external tools.

---

## Controls

| Button | Context | Action |
|--------|---------|--------|
| UP/DOWN | Pickers | Adjust value |
| UP/DOWN | Profile selector | Change profile |
| B | Profile selector | Confirm selection |
| B | Any picker | Cancel / use default |
| B | During scan | Abort scan cleanly |
| B | mDNS countdown | Abort mDNS monitor early, proceed to scan |
| UP/DOWN | Results browser | Navigate found hosts |
| RIGHT *(or any key ≠ UP/DOWN/B/LEFT)* | Results browser | Launch harvest against current find |
| B or LEFT | Results browser | Exit results browser |
| UP/DOWN | History browser | Navigate past finds |
| B or LEFT | History browser | Exit history browser |
| B | Watchdog countdown | Exit watchdog mode |
| Any | ALERT popup | Dismiss and continue |
| Any | Final PROMPT | Exit payload |

---

## OpenClaw fingerprinting pipeline

Detection runs in stages per host:port. Each stage gates the next.

### Stage 0 — mDNS monitor (C1)
Continuous `avahi-browse -a -r -p` for the configured dwell (default 30s). Countdown shown on display. LED pulses cyan. Any record matching `openclaw` or `clawd` = confirmed find, added before port sweep. Requires `avahi-browse` (`opkg install -d mmc avahi-utils`).

### Stage 1 — ARP cache harvest (C2)
Before active discovery, checks `/proc/net/arp` and `ip neigh show`. Known hosts skip ARP scanning entirely, speeding up the discovery phase.

### Stage 2 — Host discovery (Feature 3)
`arp-scan` → `arping` → `ping` fallback. Builds the live-host list for the sweep. Falls back gracefully if `arp-scan` or `arping` are not installed.

### Stage 3 — TCP connect (Feature 1 gating)
`nc -z -w 1` fast closed-port filter. Skips curl probe on closed ports.

### Stage 4 — HTTP/HTTPS probe (Features 5+6)
`curl` with 3s timeout. Tries `http://` then `https://` per port. **Confirmed** if: body contains `openclaw`, `clawd`, or `gateway` keyword, OR HTTP 400/401/403 on the primary target port. **Candidate** if: any HTTP response on extended ports.

### Stage 5 — WebSocket upgrade probe (A1)
Raw WS upgrade handshake via `/dev/tcp` with `nc` fallback:
```
GET / HTTP/1.1
Upgrade: websocket
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
```
A valid OpenClaw gateway accepts the WS upgrade (HTTP 101) before requiring auth. Any other HTTP server either fails the upgrade or returns a non-101 response. Detection confidence: **~99%**.

### Stage 6 — Canvas path probe (A2)
`GET /__openclaw__/canvas/` and `GET /__openclaw__/a2ui/`. These URL paths are unique to OpenClaw (served by the gateway's built-in HTTP server). Any non-404 response is near-certain confirmation, even without auth.

### Stage 7 — `/agent/status` intel (A3)
`GET /agent/status?session=agent:main:main`. If live, extracts and displays:
- Model in use (e.g. `anthropic/claude-opus-4-6`)
- Context usage percentage
- Active tool calls count
- Sub-agent count
- Gateway uptime timestamp

---

## Harvest module

The integrated post-exploitation engine. Triggered from the **Results Browser** — no separate tool or shell access required.

### Requirements

- **python3** on the Pager: `opkg install -d mmc python3`
- **harvest.py** deployed at `/root/payloads/user/clawhunter/harvest.py`
- `harvest.py` uses Python3 stdlib only — no pip, no third-party packages

### How to trigger

1. Run the user payload until a confirmed OpenClaw instance appears in the Results Browser
2. Navigate to the target with **UP/DOWN**
3. Press **RIGHT** (or any key other than UP/DOWN/B/LEFT)
4. Respond to the **"Out-of-band exfil?"** and **"Exfil method?"** prompts
5. Harvest runs — spinner active — completes with ALERT on success

Results Browser display:
```
  Find 1/1                        ← green
    192.168.4.100                 ← green
    port: 18790                   ← blue
    http:// | HTTP 401 | ...
    UP/DOWN=nav  B=done  >=harvest
```

### Three-phase harvest

| Phase | Name | Auth required | What it collects |
|-------|------|--------------|-----------------|
| 1 | Auth probe | None | Classifies target: OPEN / TOKEN_GATED / UNREACHABLE |
| 2 | HTTP harvest | None | `/__openclaw__/canvas/`, `/__openclaw__/a2ui/`, `/agent/status`, `/` — status codes, headers, body content |
| 3 | Multi-turn agent session | **Open portal only** | 4–5 sequential turns using the agent's native tools |

### Agent session turns (OPEN portals only)

**Turn 1 — System enumeration**

Uses `exec` and `Read` tools to collect:
- System identity: `uname -a`, `id`, `whoami`, `hostname`, `uptime`, `/etc/os-release`
- Network: `ip addr`, `ip route`, `/etc/hosts`
- Running processes: `ps aux`
- Full environment: `env | sort` — includes `ANTHROPIC_API_KEY` and other injected secrets
- Directory listings: `~/`, `~/clawd/`, `~/.openclaw/`
- `~/.openclaw/openclaw.json` — gateway config
- `~/.openclaw/secrets.json` — all stored credentials
- `~/.openclaw/credentials/*/` — per-service credential files
- `~/.openclaw/.env` — environment secrets
- `~/.ssh/` listing + `id_rsa`, `id_ed25519`, `id_ecdsa`, `authorized_keys`
- `~/clawd/MEMORY.md`, `USER.md`, `TOOLS.md` — agent persona and knowledge
- Token/key grep across `~/.openclaw/` and `~/clawd/`

**Turn 2 — Memory semantic search**

Uses `memory_search` to sweep the agent's entire memory index for 16 keywords: `api_key`, `password`, `token`, `secret`, `credential`, `ssh`, `telegram`, `discord`, `webhook`, `database`, `postgres`, `mysql`, `redis`, `aws`, `openai`, `anthropic`. Returns matched snippets with source file paths and line numbers — surfaces sensitive data that a filesystem crawl would miss.

**Turn 3 — Session history**

Uses `sessions_list` to enumerate all agent sessions, then `sessions_history` to pull the last 20 messages from each of the 5 most recent sessions. Returns session keys, message counts, and full conversation content across all channels (Telegram, Discord, Signal, etc.).

**Turn 4 — Paired nodes**

Uses `nodes` with `action=status` and `action=describe` to enumerate every device paired to the gateway: phones, tablets, cameras. Returns device names, types, capabilities, and last-seen timestamps.

**Turn 5 — Out-of-band exfil** *(optional — requires pre-configuration)*

Uses `exec` to `curl` the harvested secrets and memory directly from the victim system to the attacker's Telegram bot or webhook. Data flows victim → attacker endpoint independently of the Pager. The Pager log still receives everything from Turns 1–4.

### Token-gated portals

If the target requires a bearer token, only Phases 1 and 2 run. No agent session. The HTTP harvest still yields canvas content, a2ui content, agent status JSON (if reachable), and response headers.

### Harvest log

```
/root/loot/clawhunter/harvest_<IP>_<YYYYMMDD_HHMMSS>.log
```

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Harvest complete — agent session data collected |
| 1 | Token-gated — HTTP harvest only, no agent access |
| 2 | Unreachable — target went offline |
| 3 | Unexpected error (check log for details) |

---

## Display behavior

**During scan:**
```
  ✦ CLAWHunter v3.0.0       ← blue header
  OpenClaw Discovery Suite
  mDNS monitoring (30s)...   ← cyan (C1)
  mDNS: 25s remaining...
  Checking ARP cache...      ← blue (C2)
  Cache: 3 host(s) pre-known
  Discovering hosts...       ← blue
  Live hosts: 47
  12% — 192.168.4.6 (6/47)   ← blue (progress, F2)
  ? Open: 192.168.4.50:18790  ← blue (candidate)
  ✦ FOUND: 192.168.4.100:18790 (http)        ← green
    HTTP 401 — token-gated gateway
    Model: claude-opus-4-6 | Ctx: 44%        ← A3 intel
```

**Profile selector:**
```
  Profile: NORMAL            ← green
    Sequential probes, default behavior
    UP/DOWN=change  B=confirm
```

**Results browser:**
```
  Find 1/1                   ← green
    192.168.4.100            ← green
    port: 18790              ← blue
    http:// | HTTP 401 | Model: claude-opus-4-6
    UP/DOWN=nav  B=done  >=harvest
```

**Watchdog sleeping:**
```
  Watchdog: next scan in 240s  ← magenta LED pulsing
  B to exit watchdog
```

---

## LED states

| State | Pattern | Color |
|-------|---------|-------|
| Scanning / probing | Slow pulse 600ms/400ms | Blue |
| Passive mDNS monitor | Slow pulse 800ms/600ms | Cyan |
| Candidate port open | Alternating 250ms | Blue ↔ Green |
| mDNS confirmed find | Double-flash, LEDs 1+2 | Cyan |
| Confirmed OpenClaw | Fast flash 120ms | Green |
| WiFi connecting | Slow pulse 500ms/300ms | White |
| Watchdog sleeping | Slow pulse 1000ms/800ms | Magenta |
| Error / abort | Solid 5s | Red |
| Scan complete — found | Slow pulse 700ms/500ms | Green |
| Scan complete — none | Slow pulse 700ms/500ms | Blue |
| Exiting / off | Off | — |

---

## Port reference

| Port | Description |
|------|-------------|
| `18790` | OpenClaw agent/gateway default (primary scan target) |
| `18789` | OpenClaw control-plane WebSocket (probed on confirmed HTTP finds via Stage 5 WS upgrade) |
| `18780–18800` | Wide port range (non-default and custom configs) |
| `80, 443` | Common reverse proxy front-ends |
| `3000, 8080, 8443` | Common dev/alt proxy ports |

> **Note:** OpenClaw binds to `127.0.0.1` (loopback) by default. CLAWHunter finds instances where `gateway.bind` has been changed to a LAN interface, or those running behind a reverse proxy — exactly the configurations exposed at network level.

---

## External tools — availability and fallbacks

| Tool | Used for | Default on Pager? | Fallback |
|------|----------|------------------|---------|
| `nc` | TCP probe, WS fallback | ✅ Yes | — |
| `curl` | HTTP fingerprinting | ✅ Yes | — |
| `awk` | Shuffle, field extract | ✅ Yes (busybox) | — |
| `arping` | L2 host discovery | ✅ Usually | ping sweep |
| `arp-scan` | L2 host discovery | ❌ No | arping → ping |
| `avahi-browse` | mDNS discovery | ❌ No | skipped gracefully |
| `macchanger` | MAC randomization | ❌ No | `ip link` method |
| `python3` | Harvest module | ❌ No | `opkg install -d mmc python3` |

---

## Log output

### Scan text log

```
/root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log   ← user + recon payloads
/root/loot/clawhunter/alert_YYYYMMDD_HHMMSS.log  ← alert variant
```

```
==================================================
  CLAWHunter v3.1.0 — OpenClaw Discovery
  Hak5 WiFi Pineapple Pager
==================================================
Scan ID        : 20260307_143512
Date/Time      : Sat Mar  7 14:35:12 UTC 2026
Scanner IP     : 192.168.4.150
Subnet         : 192.168.4.1-254
Port(s)        : 18790
Wide range     : NO
Extended ports : NO
Randomized     : YES
Silent mode    : NO
Scan profile   : NORMAL
MAC randomized : YES
ARP available  : YES
avahi available: YES
==================================================

── mDNS MONITOR (30s) ──
[MDNS]      192.168.4.100 via mDNS | record: _openclaw._tcp ...

── PORT SCAN ──
[14:35:44] C2: ARP cache harvest: 3 host(s) pre-known
[14:35:46] Probing: 192.168.4.100 (12/47, 25%)
[FOUND]     192.168.4.100:18790 | http | HTTP 401 | HTTP 401 — token-gated gateway
[14:35:46]   A1: WebSocket upgrade accepted — protocol-layer confirmed
[14:35:46]   A2: canvas path HTTP 200 — OpenClaw-unique path confirmed
[14:35:47]   A3: model=anthropic/claude-opus-4-6 ctx=44.5% tools=2 subagents=1
[14:35:47]   Detail: Version: 2026.3.2 | Persona: assistant | Model: anthropic/claude-opus-4-6 | Ctx: 44.5%

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

### JSON report (D1)

```json
{
  "scan_id": "20260307_143512",
  "payload_version": "3.1.0",
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
        "canvas_confirmed": "confirmed",
        "websocket_confirmed": "confirmed"
      }
    }
  ]
}
```

### Harvest log

```
/root/loot/clawhunter/harvest_<IP>_<YYYYMMDD_HHMMSS>.log
```

---

## WiFi client mode — note on password entry

DuckyScript has no free-text input primitive, so SSID and password cannot be typed interactively. To use WiFi client mode:

- **SSID:** Launch from the **Recon UI** with a target AP selected — the payload reads `_RECON_SELECTED_AP_SSID` automatically
- **Password:** Pre-save the AP credentials via the Pager's WiFi Settings before running the payload. The payload will attempt to join using saved credentials. If credentials are not saved and the AP is encrypted, a notice is shown and the connection is attempted anyway (may fail)

---

## License

MIT — see [LICENSE](LICENSE)
