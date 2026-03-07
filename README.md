# ✦ CLAWHunter

A [Hak5 WiFi Pineapple Pager](https://docs.hak5.org/wifi-pineapple-pager/) payload that scans the local LAN for live [OpenClaw](https://docs.openclaw.ai) AI gateway instances. Full hardware integration: color display, RGB LEDs, haptic feedback, audio cues, and an interactive post-scan results browser.

![Platform](https://img.shields.io/badge/platform-Hak5%20WiFi%20Pineapple%20Pager-red)
![Language](https://img.shields.io/badge/script-DuckyScript%20%2F%20Bash-yellow)
![Category](https://img.shields.io/badge/category-Reconnaissance-blue)
![Version](https://img.shields.io/badge/version-2.1.0-green)

---

## What's new in v2.1.0

| # | Feature | Description |
|---|---------|-------------|
| 1 | **Silent mode** | Suppress all audio and haptic for covert operations |
| 2 | **Progress counter** | Live `%` in spinner with host index tracking (`n/total`) |
| 3 | **ARP host discovery** | Layer-2 host detection via `arp-scan` → `arping` → ping fallback |
| 4 | **Randomized scan order** | Shuffle host list to reduce IDS/IPS detection signature |
| 5 | **HTTPS probe** | Try `http://` then `https://` per open port for TLS-wrapped gateways |
| 6 | **Extended ports** | Optionally sweep 80, 443, 3000, 8080, 8443 (reverse proxy detection) |
| 7 | **mDNS pre-scan** | `avahi-browse` zero-probe discovery before the port sweep begins |
| 8 | **Deep fingerprinting** | Extract version, persona, and server headers from `/health`, `/status`, etc. |
| 9 | **WiFi client mode** | Connect to a target AP via Recon or manual SSID/password, auto-scan its subnet, disconnect on exit |
| 10 | **Multi-subnet sweep** | After each scan, loop back to scan another subnet without restarting the payload |
| 11 | **Cross-run history/diff** | Browse all past finds across scan logs; diff new vs. gone instances vs. prior runs |

---

## Hardware features used

| Hardware | Usage |
|----------|-------|
| **480×222 px 16-bit color display** | Color-coded LOG output, interactive pickers, ALERT popups, results browser, history browser |
| **RGB LED array (4 LEDs)** | Blue pulse = scanning, fast green = confirmed, alternating = candidate, cyan double-flash = mDNS hit, slow white = WiFi connecting, solid red = error |
| **Haptic (vibration)** | Soft (150ms) on candidate, medium (300ms) on mDNS/WiFi, strong (500ms) on confirmed find and scan complete |
| **Audio (RINGTONE / RTTTL)** | Startup, find, mDNS find, candidate ping, complete ok/none, abort, WiFi connected — all suppressed in silent mode |
| **5-button navigation** | UP/DOWN for pickers, results browser, and history browser; B to abort scan or exit panels |

---

## What it does

1. **Optional history browse** — if previous scan logs exist, offers to browse them on startup
2. **Silent mode prompt** — suppress all audio/haptic for covert fieldwork
3. **WiFi client mode** — optionally connect to a target AP (Recon-assisted or manual) before scanning
4. **mDNS pre-scan** — `avahi-browse` finds OpenClaw services via zero-config DNS before touching a single port
5. **ARP host discovery** — Layer-2 scan to build a live-host list (fast, works through ICMP filters)
6. **Randomized scan order** — optional host-list shuffle to reduce IDS signature
7. **Port sweep with HTTPS fallback** — probes target port(s) and optional extended ports; tries `http://` then `https://` per open port
8. **Deep fingerprinting** — on confirmed finds, extracts version, persona, and server info from response headers and status endpoints
9. **Diff vs previous runs** — after each scan, flags newly appeared and newly disappeared instances
10. **Interactive results browser** — navigate all confirmed finds with UP/DOWN; view full deep-fingerprint detail per host
11. **Multi-subnet loop** — after each scan, choose to sweep another subnet without restarting

---

## Deploy

```bash
# Via SSH:
ssh root@pineapple.lan "mkdir -p /root/payloads/user/reconnaissance/clawhunter"
scp payload.sh root@pineapple.lan:/root/payloads/user/reconnaissance/clawhunter/payload.sh

# Or via the Pager web UI: Payloads → Upload
```

---

## Usage

Launch from **Payloads → reconnaissance → clawhunter** in the Pager UI.

Follow the on-screen prompts in order:

| Prompt | Default | Description |
|--------|---------|-------------|
| View scan history? | No | Browse past finds (only shown if previous logs exist) |
| Silent mode? | No | Suppress all audio and vibration |
| Connect to AP first? | No | WiFi client mode — connect before scanning |
| Target Subnet | Auto-detected | First three octets (e.g. `192.168.1`) |
| OpenClaw Port | `18790` | Primary target port |
| Advanced options? | No | Gate for port range, extended ports, randomize |
| → Wide port range? | No | Sweep `18780–18800` instead of single port |
| → Extended ports? | No | Also probe 80, 443, 3000, 8080, 8443 |
| → Randomize order? | No | Shuffle host list |
| Full /24 scan? | Yes | 254 hosts (~90s) or quick scan `.1–.50` (~20s) |

---

## Controls

| Button | Context | Action |
|--------|---------|--------|
| UP/DOWN | Pickers | Adjust value |
| B | Any picker | Cancel |
| B | During scan | Abort scan cleanly |
| UP/DOWN | Results browser | Navigate found hosts |
| B or LEFT | Results browser | Exit browser |
| UP/DOWN | History browser | Navigate past finds |
| B or LEFT | History browser | Exit browser |
| Any | ALERT popup | Dismiss and continue scan |
| Any | Final PROMPT | Exit payload |

---

## Display behavior

**During scan (rolling log):**
```
  ✦ CLAWHunter v2.1.0        ← blue
  OpenClaw Discovery
  mDNS pre-scan...            ← blue
  mDNS: no OpenClaw services  ← blue
  Discovering hosts...        ← blue
  Live hosts: 47              ← blue
  12% — 192.168.4.6 (6/47)   ← blue   (progress counter)
  24% — 192.168.4.28 (11/47) ← blue
  ? Open: 192.168.4.50:18790  ← blue   (candidate)
  ✦ FOUND: 192.168.4.100:18790 (http)  ← green
    HTTP 401 — token-gated gateway      ← green
    Version: 2026.3.2 | Persona: assistant ← (deep fingerprint)
```

**On confirmed find — ALERT popup:**
```
┌────────────────────────────────┐
│  ✦ OpenClaw Found!             │
│  192.168.4.100:18790 (http)    │
│  HTTP 401 — token-gated gateway│
│  Version: 2026.3.2 | Persona:  │
│  assistant                     │
│  Press any key to resume scan  │
└────────────────────────────────┘
```

**Results browser (deep fingerprint per host):**
```
  Find 1/1                   ← green
    192.168.4.100            ← green
    port: 18790              ← blue
    http:// | HTTP 401 | Ver: 2026.3.2
    UP/DOWN=nav  B=done
```

**Diff display (if prior runs exist):**
```
  ─ vs last scan ─
  NEW:  1 instance(s)        ← green
  GONE: 0 instance(s)
```

---

## LED states

| State | Pattern | Color |
|-------|---------|-------|
| Scanning | Slow pulse (600ms / 400ms) | Blue |
| Candidate port open | Alternating 250ms | Blue ↔ Green |
| Confirmed OpenClaw | Fast flash (120ms) | Green |
| mDNS hit | Cyan double-flash (first 2 LEDs) | Cyan |
| WiFi connecting | Slow pulse (500ms / 300ms) | White |
| Error / abort | Solid 5s | Red |
| Complete — found | Slow pulse (700ms / 500ms) | Green |
| Complete — none | Slow pulse (700ms / 500ms) | Blue |
| Exiting | Off | — |

---

## OpenClaw fingerprinting

**Stage 1 — TCP connect** (`nc -z -w 1`): Fast closed-port filter.

**Stage 2 — HTTP/HTTPS probe** (`curl`, 3s timeout, tries `http://` then `https://`):

| Signal | Classification |
|--------|---------------|
| Body contains `openclaw`, `clawd`, or `gateway` | ✅ **Confirmed** |
| HTTP 400/401/403 on the primary target port | ✅ **Confirmed** (token-gated) |
| Any HTTP response on port range / extended ports | ⚠️ **Candidate** |

**Stage 3 — Deep fingerprint** (on confirmed finds): Probes `/health`, `/status`, `/api/status`, `/api/v1/info` for version and persona. Reads `Server:` and `X-Powered-By:` headers.

**Stage 0 — mDNS pre-scan** (`avahi-browse -a -t`): Zero-probe discovery. Any service record matching `openclaw` or `clawd` is treated as a confirmed find and added before the port sweep begins.

---

## Port reference

| Port | Description |
|------|-------------|
| `18790` | OpenClaw gateway default |
| `18780–18800` | Wide range (non-default configs) |
| `80, 443` | Common reverse proxy ports |
| `3000, 8080, 8443` | Common dev/alt proxy ports |

> **Note:** OpenClaw binds to `loopback` by default. This payload finds instances where `gateway.bind` has been changed to a network interface, or those running behind a reverse proxy — exactly the configurations relevant for network-level discovery.

---

## Log output

```
/root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log
```

Example:
```
==================================================
  CLAWHunter v2.1.0 — OpenClaw Discovery
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
ARP available  : YES
avahi available: YES
==================================================

── mDNS PRE-SCAN ──
[MDNS]      192.168.4.100 via mDNS | record: ...

── PORT SCAN ──
[14:35:14] Probing: 192.168.4.6 (1/47, 2%)
[14:35:19] Probing: 192.168.4.100 (12/47, 25%)
[FOUND]     192.168.4.100:18790 | http | HTTP 401 | HTTP 401 — token-gated gateway
[14:35:19]   Detail: Version: 2026.3.2 | Persona: assistant
[14:35:19]   └─ OpenClaw confirmed on 192.168.4.100

── DIFF vs PREVIOUS SCANS ──
  New instances : 1
  Gone instances: 0

==================================================
SUMMARY
  Hosts scanned  : 47
  OpenClaw found : 1
  Elapsed        : 62s
  Status         : COMPLETE

  DISCOVERED INSTANCES:
    ✦ 192.168.4.100:18790
==================================================
```

---

## License

MIT — see [LICENSE](LICENSE)
