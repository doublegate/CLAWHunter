# ✦ CLAWHunter

A [Hak5 WiFi Pineapple Pager](https://docs.hak5.org/wifi-pineapple-pager/) payload that scans the local LAN for live [OpenClaw](https://docs.openclaw.ai) AI gateway instances. Full hardware integration: color display, RGB LEDs, haptic feedback, audio cues, and an interactive post-scan results browser.

![Platform](https://img.shields.io/badge/platform-Hak5%20WiFi%20Pineapple%20Pager-red)
![Language](https://img.shields.io/badge/script-DuckyScript%20%2F%20Bash-yellow)
![Category](https://img.shields.io/badge/category-Reconnaissance-blue)
![Version](https://img.shields.io/badge/version-2.0.0-green)

---

## Hardware features used

| Hardware | Usage |
|----------|-------|
| **480×222 px 16-bit color display** | Color-coded LOG output (blue=info, green=found, red=error), interactive pickers, ALERT popups, results browser |
| **RGB LED array (4 LEDs)** | Blue pulse = scanning, fast green flash = confirmed find, alternating blue/green = candidate, solid red = error, slow green pulse = complete |
| **Haptic (vibration)** | Short 300ms on candidate, strong 500ms on confirmed find, extended 500ms on scan complete |
| **Audio (RINGTONE / RTTTL)** | Startup tone, ascending alert on find, ping on candidate, victory jingle on completion, descending on no results |
| **5-button navigation** | UP/DOWN for pickers and results browser, B to abort scan or exit browser |

---

## What it does

1. **Auto-detects** the current subnet from the Pager's network interface
2. **Prompts** for target subnet, port, and scan mode via the color display
3. **Scans** the host range — pings first (fast host filter), then port probes live hosts
4. **Fingerprints** open ports via HTTP to confirm or classify each discovery
5. **Alerts immediately** on each confirmed find: LED flash + vibration + audio + `ALERT` popup that pauses the scan until dismissed
6. **Saves logs** with timestamped entries to `/root/loot/clawhunter/`
7. **Opens a results browser** after the scan — navigate all found instances with UP/DOWN, exit with B

---

## Deploy

```bash
# Via SSH (replace pineapple.lan with your device IP):
ssh root@pineapple.lan "mkdir -p /root/payloads/user/reconnaissance/clawhunter"
scp payload.sh root@pineapple.lan:/root/payloads/user/reconnaissance/clawhunter/payload.sh

# Or via the Pager web UI: Payloads → Upload
```

---

## Usage

Launch from **Payloads → reconnaissance → clawhunter** in the Pager UI.

Follow the on-screen prompts:

| Prompt | Default | Description |
|--------|---------|-------------|
| Target Subnet | Auto-detected (e.g. `192.168.1`) | First three octets |
| OpenClaw Port | `18790` | Primary port to probe |
| Port range scan? | No | Sweep `18780–18800` instead of single port |
| Full /24 scan? | Yes | 254 hosts (~90s) or quick scan `.1–.50` (~20s) |

---

## Controls

| Button | Context | Action |
|--------|---------|--------|
| UP/DOWN | Pickers | Adjust value |
| B | Any picker | Cancel / exit |
| B | During scan | Abort scan cleanly |
| UP/DOWN | Results browser | Navigate found hosts |
| B or LEFT | Results browser | Exit browser |
| Any | ALERT popup | Dismiss and continue scan |
| Any | Final PROMPT | Exit payload |

---

## Display behavior

**During setup:**
```
  ✦ CLAWHunter v2.0.0       ← blue
  OpenClaw Discovery
  WiFi Pineapple Pager       ← blue
```

**During scan (rolling log — most recent ~10 lines visible):**
```
  Scanning: 192.168.4.1-254  ← green
  Ports: 18790               ← blue
  Live: 192.168.4.6          ← blue
  Live: 192.168.4.28         ← blue
  ? Open: 192.168.4.50:18790 ← blue    (candidate)
  Live: 192.168.4.100        ← blue
  ✦ FOUND: 192.168.4.100:18790 ← green (confirmed!)
    HTTP 401 — token-gated gateway ← green
```

**On confirmed find — ALERT popup (pauses scan):**
```
┌────────────────────────────┐
│  ✦ OpenClaw Found!         │
│  192.168.4.100:18790       │
│  HTTP 401 — token-gated    │
│  gateway                   │
│  Press any key to continue │
└────────────────────────────┘
```

**Scan complete:**
```
  Scan Complete!             ← green
  Found: 1 OpenClaw          ← green
  Scanned: 47 hosts          ← blue
```

**Results browser (if finds > 0):**
```
  Results 1/1                ← green
    192.168.4.100            ← green
    port: 18790              ← blue
    UP/DOWN=nav  B=exit
```

---

## LED states

| State | Pattern | Color |
|-------|---------|-------|
| Scanning | Slow pulse (600ms on / 400ms off) | Blue |
| Candidate port open | Alternating blue/green | Blue ↔ Green |
| Confirmed OpenClaw | Fast flash (150ms) | Green |
| Error / abort | Solid | Red |
| Complete — found | Slow pulse (800ms) | Green |
| Complete — none | Slow pulse (800ms) | Blue |
| Exiting | Off | — |

---

## OpenClaw fingerprinting

Two-stage detection:

**Stage 1 — TCP port check** (`nc -z -w 1`)
Fast, low-cost. Closed ports are skipped without an HTTP probe.

**Stage 2 — HTTP fingerprint** (`curl`, 3s timeout)

| Signal | Classification |
|--------|---------------|
| Response body contains `openclaw`, `clawd`, or `gateway` | ✅ **Confirmed** |
| HTTP 400/401/403 on the primary target port | ✅ **Confirmed** (token-gated gateway) |
| Any HTTP response on the port range | ⚠️ **Candidate** (logged in yellow) |

---

## Port reference

| Port | Description |
|------|-------------|
| `18790` | OpenClaw gateway default |
| `18780–18800` | Wide range (covers non-default configs) |

> **Note:** OpenClaw binds to `loopback` by default. This payload finds instances where `gateway.bind` has been changed to a network interface, or those running behind a reverse proxy — exactly the configurations relevant for network-level discovery.

---

## Log output

```
/root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log
```

Example:
```
==============================================
  CLAWHunter v2.0.0 — OpenClaw Discovery
==============================================
Scan ID     : 20260307_143512
Scanner IP  : 192.168.4.150
Subnet      : 192.168.4.1-254
Port(s)     : 18790
==============================================

── HOST SCAN ──
[14:35:14] Host alive: 192.168.4.6
[14:35:16] Host alive: 192.168.4.28
[14:35:19] Host alive: 192.168.4.100
[FOUND]     192.168.4.100:18790 | HTTP 401 | HTTP 401 — token-gated gateway
[14:35:19]   └─ OpenClaw confirmed on 192.168.4.100

==============================================
SUMMARY
  Hosts scanned  : 254
  OpenClaw found : 1
  Elapsed        : 87s
  Status         : COMPLETE

  DISCOVERED INSTANCES:
    ✦ 192.168.4.100:18790
==============================================
```

---

## License

MIT — see [LICENSE](LICENSE)
