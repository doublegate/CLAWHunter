# ✦ CLAWHunter

A [Hak5 WiFi Pineapple Pager](https://docs.hak5.org/wifi-pineapple-pager/) payload that scans the local LAN for live [OpenClaw](https://docs.openclaw.ai) AI agent gateway instances. Probes the default OpenClaw port, optionally sweeps a wider range, fingerprints HTTP responses to confirm discovery, and logs all findings to loot.

![Platform](https://img.shields.io/badge/platform-Hak5%20WiFi%20Pineapple%20Pager-red)
![Language](https://img.shields.io/badge/script-DuckyScript%20%2F%20Bash-yellow)
![Category](https://img.shields.io/badge/category-Reconnaissance-blue)

---

## What it does

1. **Auto-detects** the current subnet from the Pager's network interface
2. **Prompts** for target subnet, port, and scan options via the display + buttons
3. **Scans** the selected host range with a live-host check (ping) before port probing
4. **Probes** each live host on the selected port(s) using `nc` (fast TCP check) then `curl` (HTTP fingerprint)
5. **Fingerprints** HTTP responses to confirm OpenClaw vs. any other service on the port
6. **Displays** real-time results on the Pager screen as hosts are found
7. **Logs** all discoveries, candidates, and summary to `/root/loot/clawhunter/`

---

## Deploy

Copy the payload to the Pager:

```bash
# From the Pager's web UI: Payloads → Upload
# Or via SSH:
scp payload.sh root@pineapple.lan:/root/payloads/user/reconnaissance/clawhunter/payload.sh
```

The payload must live at:
```
/root/payloads/user/reconnaissance/clawhunter/payload.sh
```

---

## Usage

1. Launch from the Pager UI (Payloads → reconnaissance → clawhunter) or from the device menu
2. Follow the on-screen prompts:

| Prompt | Default | Description |
|--------|---------|-------------|
| Target Subnet | Auto-detected (e.g. `192.168.1`) | First three octets of target range |
| OpenClaw Port | `18790` | Primary port to probe |
| Scan port range? | No | Sweep ports `18780–18800` instead of single port |
| Full scan? | Yes | `/24` (254 hosts) or quick scan (`.1–.50`) |

3. Watch live results on the display as hosts are found
4. Press **B** at any time to abort the scan cleanly
5. Press any button on the final screen to exit

---

## Controls

| Button | Action |
|--------|--------|
| Standard navigation | Picker navigation (up/down/select) |
| **B** | Abort scan in progress (mid-scan) |
| Any button | Dismiss final results screen |

---

## OpenClaw fingerprinting

CLAWHunter uses a two-stage confirmation strategy:

**Stage 1 — TCP port check** (`nc -z -w 1`)
Fast connection attempt. Closed ports are skipped immediately.

**Stage 2 — HTTP fingerprint** (`curl`)
For open ports, an HTTP GET is sent with a `CLAWHunter/1.0` User-Agent. The response is checked for:

| Signal | Confidence |
|--------|-----------|
| Body contains `openclaw`, `clawd`, or `gateway` | ✅ **Confirmed** |
| HTTP 401/403/400 on the primary target port (18790) | ✅ **Confirmed** (token-gated gateway) |
| Any HTTP response on port range | ⚠️ **Candidate** (logged, displayed in yellow) |

---

## Port reference

| Port | Description |
|------|-------------|
| `18790` | OpenClaw gateway default (token-authenticated HTTP) |
| `18780–18800` | Wide range sweep (covers non-default configs) |

OpenClaw's gateway binds to `loopback` by default (`127.0.0.1`). Instances visible on the network have either changed `gateway.bind` to a network interface or are running behind a reverse proxy. This payload finds exactly those.

---

## Log output

Logs are written to:
```
/root/loot/clawhunter/scan_YYYYMMDD_HHMMSS.log
```

Example log:
```
==================================================
  CLAWHunter v1.0.0 — OpenClaw Discovery
==================================================
Scan ID    : 20260307_143512
Subnet     : 192.168.4.1-254
Primary Port: 18790
Wide Range  : NO
==================================================

[14:35:14] Host alive: 192.168.4.6
[14:35:15] Host alive: 192.168.4.28
[14:35:16] Host alive: 192.168.4.100
[FOUND] 192.168.4.100:18790 | HTTP 401 | HTTP 401 (auth required)
  └─ OpenClaw found on 192.168.4.100
[14:35:22] Host alive: 192.168.4.216

==================================================
SUMMARY
  Hosts scanned : 254
  OpenClaw found: 1
  Status        : COMPLETE
  Elapsed       : 87 seconds
==================================================
```

---

## Notes

- Full `/24` scans take approximately 60–120 seconds depending on network size and response times
- Quick scan (`.1–.50`) covers most common gateway/server address ranges and completes faster
- Wide range mode (`18780–18800`) increases scan time proportionally — 21× more port probes per host
- OpenClaw instances with `gateway.bind: loopback` (the default) will **not** appear in network scans — only instances explicitly bound to a network interface or behind a proxy

---

## License

MIT — see [LICENSE](LICENSE)
