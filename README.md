# CLAWHunter

<img src="images/pager-transparent.png" width="450" alt="WiFi Pineapple Pager">

CLAWHunter v3.4.0 is a Hak5 WiFi Pineapple Pager payload suite for finding and assessing OpenClaw gateways on an authorized local network. The interactive, recon-triggered, and client-connected alert payloads share one evidence-based fingerprinting library and integrate with the Pager display, LEDs, haptics, audio, and loot browser.

Use this project only on systems and networks you own or are explicitly authorized to assess.

![Platform](https://img.shields.io/badge/platform-WiFi%20Pineapple%20Pager-red)
![Language](https://img.shields.io/badge/language-Bash%20%2B%20Python3-yellow)
![Version](https://img.shields.io/badge/version-3.4.0-green)

![CLAWHunter architecture](images/architecture.png)

## Contents

1. [Compatibility](#compatibility)
2. [Repository structure](#repository-structure)
3. [Install](#install)
4. [Payloads](#payloads)
5. [Interactive workflow](#interactive-workflow)
6. [Detection](#detection)
7. [Scan profiles](#scan-profiles)
8. [Checkpoints and parallelism](#checkpoints-and-parallelism)
9. [Hardware feedback](#hardware-feedback)
10. [Assessment engine](#assessment-engine)
11. [Output](#output)
12. [Dependency fallbacks](#dependency-fallbacks)
13. [Troubleshooting](#troubleshooting)
14. [Development and release](#development-and-release)
15. [Research sources](#research-sources)

## Compatibility

- WiFi Pineapple Pager firmware 1.1.0 or newer is recommended.
- Bash and the Pager DuckyScript command library are required.
- Python 3 is optional and used only by the harvest/assessment engine.
- `avahi-utils` improves exact OpenClaw mDNS discovery.
- `arp-scan` improves Layer 2 discovery; ping/arping fallbacks remain available.
- IPv4 scanning is supported. IPv6 link-local neighbors are logged as candidates only.

Install larger optional packages to eMMC, not the small root overlay:

```bash
opkg update
opkg install -d mmc python3
opkg install -d mmc avahi-utils arp-scan
```

CLAWHunter bootstraps `/mmc/bin`, `/mmc/sbin`, `/mmc/usr/bin`, `/mmc/usr/sbin`, and `/mmc/usr/lib` at runtime.

### Firmware notes

| Firmware | CLAWHunter status | Relevant behavior |
| --- | --- | --- |
| 1.1.0+ | Recommended | Pager Portal payload management and monitor-interface stability fixes |
| 1.0.9 | Minimum research baseline | Corrected Recon client variables and user payload-home behavior |
| 1.0.8 | Not recommended for v3.3 | Added list picker, payload metadata, and line-ending rewriting, but predates later context fixes |
| 1.0.7 and older | Unsupported for v3.3 | Missing later payload-context and Portal fixes |

The payloads keep local/shared-library fallback resolution rather than relying on `_PAYLOAD_HOME`, so manual, Portal, and repository layouts remain testable. Firmware-specific details and every reviewed changelog are recorded in [docs/V3.3-RESEARCH.md](docs/V3.3-RESEARCH.md).

## Repository Structure

```text
CLAWHunter/
|-- .github/workflows/quality.yml
|-- docs/
|   |-- V3-RESEARCH.md
|   |-- V3.3-RESEARCH.md
|   |-- architecture.dot
|   `-- architecture.svg
|-- images/
|   |-- architecture.png
|   `-- pager-transparent.png
|-- lib/common.sh
|-- payloads/
|   |-- user/reconnaissance/clawhunter/
|   |   |-- payload.sh
|   |   `-- harvest.py
|   |-- recon/access_point/clawhunter/payload.sh
|   `-- alerts/pineapple_client_connected/clawhunter-watchdog/payload.sh
|-- scripts/
|   |-- check.sh
|   |-- install-pager.sh
|   `-- package-release.sh
|-- tests/
|   |-- test_common.sh
|   `-- test_harvest.py
|-- CHANGELOG.md
|-- CONTRIBUTING.md
`-- README.md
```

The repository stores one canonical `lib/common.sh`. The release packager embeds a byte-identical copy beside each payload because the official Hak5 Payload Library requires payload resources to be self-contained.

## Install

Download and unpack `clawhunter-v3.4.0-pager.tar.gz` from the GitHub release, transfer the directory to the Pager, then run:

```bash
./scripts/install-pager.sh
```

The installer places payloads in the category structure used by the official Hak5 Pager Payload Library:

```text
/root/payloads/
|-- lib/common.sh
|-- user/reconnaissance/clawhunter/
|   |-- payload.sh
|   |-- harvest.py
|   `-- common.sh
|-- recon/access_point/clawhunter/
|   |-- payload.sh
|   `-- common.sh
`-- alerts/pineapple_client_connected/clawhunter-watchdog/
    |-- payload.sh
    `-- common.sh
```

The release includes a `SHA256SUMS` manifest inside the archive and a separate `.sha256` file for the archive itself.

### Verify the release

```bash
sha256sum -c clawhunter-v3.4.0-pager.tar.gz.sha256
tar -xzf clawhunter-v3.4.0-pager.tar.gz
cd clawhunter-v3.4.0
sha256sum -c SHA256SUMS
```

The external checksum validates the downloaded archive. The internal manifest validates every runtime, documentation, and installer file after extraction.

### Transfer to the Pager

One manual transfer flow is:

```bash
scp -r clawhunter-v3.4.0 root@pineapple.lan:/tmp/
ssh root@pineapple.lan '/tmp/clawhunter-v3.4.0/scripts/install-pager.sh'
```

The installer accepts an alternate destination as its first argument. This is used by the automated gate and can also stage the exact Pager tree on another mounted filesystem:

```bash
./scripts/install-pager.sh /tmp/payload-staging
```

## Payloads

### Interactive

Path: `payloads/user/reconnaissance/clawhunter/`

Runs mDNS and ARP discovery, scans a selected IPv4 /24, supports Ghost through Aggressive profiles, writes JSON/log reports, checkpoints interrupted scans, browses results, and can launch the bounded assessment engine for a confirmed target.

### Recon

Path: `payloads/recon/access_point/clawhunter/`

Consumes the selected Recon access point context, prompts for an exact SSID when Recon marks the AP hidden, maps Open/WPA/WPA2/WPA3 to the current `WIFI_CONNECT` values, pins the selected BSSID, and scans after the client interface connects. `wlan0cli` is 2.4 GHz, so 5/6 GHz selections are rejected with a clear message.

### Alert

Path: `payloads/alerts/pineapple_client_connected/clawhunter-watchdog/`

Runs silently when a Pineapple client connects. It resolves that exact client's IP with `FIND_CLIENT_IP` and an exact-MAC ARP fallback, then performs a short evidence probe without selecting an unrelated ARP entry.

### Mode comparison

| Capability | Interactive | Recon | Alert |
| --- | ---: | ---: | ---: |
| Operator selects target IPv4 /24 | Yes | Automatic from DHCP | No |
| Connects to selected AP | No | Yes | No |
| mDNS observation | Timed | Short pre-scan | No |
| ARP/ping host discovery | Yes | Yes | Exact client only |
| Sequential scan | Yes | Yes | One host/port |
| Parallel scan | Fast/Aggressive | No | No |
| JSON report | Yes | Yes | No |
| Results browser | Yes | Yes | No |
| Assessment engine | From confirmed result | From confirmed result | No |
| Audio | Operator/profile controlled | Enabled | Never |
| Execution target | Active routed network | Selected 2.4 GHz AP | Triggering client |

## Interactive Workflow

1. Launch CLAWHunter from **Payloads > User > Reconnaissance**.
2. Choose whether to suppress audio and vibration.
3. Optionally randomize the active scanner interface MAC for the duration of the payload. The original MAC is restored by the exit trap.
4. Select `GHOST`, `QUIET`, `NORMAL`, `FAST`, or `AGGRESSIVE`.
5. Confirm the full target IPv4 address. The scanner derives that address's /24 prefix.
6. Confirm the primary OpenClaw port. The default is 18789.
7. For non-Aggressive profiles, optionally enable the 18780-18800 range, extended web ports, and randomized host order.
8. Choose a quick `.1-.50` or full `.1-.254` host range.
9. Set the mDNS dwell when `avahi-browse` is available.
10. Review confirmed results, optionally launch an authorized assessment with RIGHT, and optionally start watchdog mode.

### Controls

| Context | Control | Action |
| --- | --- | --- |
| Profile selection | UP / DOWN | Change profile |
| Profile selection | B | Confirm highlighted profile |
| Active scan | B | Abort and preserve completed-host checkpoint |
| Results/history | UP / DOWN | Navigate confirmed endpoints |
| Results | RIGHT | Run bounded assessment for selected endpoint |
| Results/history | B or LEFT | Exit browser |
| Dialogs/pickers | Pager theme controls | Confirm, reject, or cancel through Hak5 UI components |

The user payload scans the current routed network. Connecting to a Recon-selected access point is intentionally isolated in the Recon payload so interactive mode does not duplicate AP state, encryption mapping, or credential handling.

## Detection

The default OpenClaw gateway port is `18789`. Port `18790` remains available as a legacy compatibility probe.

The shared classifier combines:

- exact `_openclaw-gw._tcp` mDNS discovery, treated as an unauthenticated hint;
- TCP reachability;
- HTTP and HTTPS root evidence;
- `x-openclaw` headers or OpenClaw body markers;
- `/healthz` and `/readyz` responses;
- a WebSocket upgrade and the OpenClaw-specific `connect.challenge` event;
- legacy canvas paths as low-weight compatibility evidence.

`CONFIRMED` requires OpenClaw-specific evidence. A generic 401/403 response, generic health endpoint, or generic WebSocket upgrade cannot confirm a gateway by itself.

### Evidence model

| Signal | Score | OpenClaw-specific? | Notes |
| --- | ---: | ---: | --- |
| Any HTTP/S response | 1 | No | Establishes an HTTP transport only |
| `/healthz` returns 200 | 1 | No | Common endpoint shape; not confirmation |
| `/readyz` returns 200 | 1 | No | Common endpoint shape; not confirmation |
| Generic WebSocket upgrade | 1 | No | Many unrelated services upgrade |
| Non-404 legacy canvas path | 1 | No | Compatibility hint only |
| `x-openclaw` response header | 4 | Yes | Product-specific marker |
| OpenClaw/clawd root body marker | 4 | Yes | Product-specific marker |
| OpenClaw/clawd health body marker | 3 | Yes | Product-specific health evidence |
| `connect.challenge` event | 5 | Yes | Current gateway protocol evidence |

Classification rules:

- `CONFIRMED`: score 4 or higher and at least one OpenClaw-specific signal.
- `LIKELY`: score 3 or higher without specific confirmation.
- `CANDIDATE`: reachable endpoint with weaker evidence.
- `NONE`: no classifiable HTTP/S transport or invalid/unreachable target.

Every classification records its score and evidence string in the scan log. mDNS results are logged as hints and do not increment the confirmed finding count until active evidence validates the endpoint.

### Port behavior

| Port set | Contents | Use |
| --- | --- | --- |
| Default | Operator port plus 18790 legacy | Normal targeted scan |
| Wide | 18780 through 18800 | Aggressive/range discovery |
| Extended | 80, 443, 3000, 8080, 8443 | Reverse proxy or alternate web binding checks |
| Alert | 18789 only | Keeps event handling within the short budget |

All IP addresses and ports are validated before reaching `nc` or `curl`. HTTP bodies are capped at 8 KiB in the shell classifier; headers are capped at 4 KiB.

## Scan Profiles

| Profile | Active workers | Timing | Audio/haptic | Port behavior |
| --- | ---: | --- | --- | --- |
| Ghost | 0 | mDNS dwell only | Operator setting | No active port probes; ARP cache summary only |
| Quiet | 1 | 50-250 ms between hosts | Forced silent | Selected/default ports |
| Normal | 1 | 0-80 ms variation | Operator setting | Selected/default ports |
| Fast | 3 | 0-25 ms variation | Operator setting | Selected/default ports |
| Aggressive | 5 | No added delay | Operator setting | 18780-18800 plus extended ports |

Sequential and parallel paths share the same checkpoint contract. A host is recorded only after all selected ports finish, and checkpoint identity includes the subnet and port set.

## Checkpoints and Parallelism

Interactive checkpoints use:

```text
/tmp/clawhunter_checkpoint_<subnet>_<port-key>
```

The `port-key` is a checksum of the normalized selected port list. This prevents a completed quick scan from being treated as completed when the operator later selects a different port set.

Sequential behavior:

1. Skip hosts already present in the current checkpoint.
2. Probe every selected port for one host.
3. Record confirmed and candidate endpoints.
4. Append the host only after its full port loop completes.

Parallel behavior:

1. Filter checkpointed hosts before launching workers.
2. Give each worker a private result file under a secure `mktemp -d` directory.
3. Write every endpoint record, then one `DONE` record after the full port loop.
4. Let the parent process update UI, hardware, global result arrays, logs, and checkpoints.

An operator abort preserves completed-host records. Clean completion removes the checkpoint. The architecture avoids background workers mutating parent Bash arrays, which would otherwise be lost across subshell boundaries.

## Hardware Feedback

| State | Display/log | LEDs | Haptic/audio |
| --- | --- | --- | --- |
| Scanning | Host, progress, profile | Blue pulse | Profile/operator dependent |
| Confirmed OpenClaw | Endpoint and evidence | Green pulse | Strong vibration and found ringtone |
| Likely/candidate | Endpoint and class | Alternating blue/green | Soft vibration and short tone |
| mDNS hint | Resolved endpoint | Cyan pattern | Medium vibration and mDNS tone |
| WiFi connect | Selected SSID/BSSID | White pulse | Success vibration/ringtone |
| Watchdog | Run/change status | Magenta pulse | Alert pattern on change |
| Error | Error dialog/log | Solid red | Context dependent |
| Alert confirmed | Local alert log only | Green, then off | Strong vibration; no audio |
| Alert candidate | Local alert log only | Candidate pattern, then off | Soft vibration; no audio |

Missing hardware helpers are non-fatal in `lib/common.sh`: a feedback failure must not terminate discovery or corrupt loot. Haptic helpers pass complete RTTTL note patterns to the Pager's `VIBRATE` command. Quiet mode suppresses shared audio/haptic wrappers. The event-triggered alert never plays audio and does not open blocking dialogs.

## Assessment Engine

`harvest.py` is a Python standard-library-only, 180-second-bounded assessment client. It records root, liveness, readiness, and WebSocket challenge evidence. When an authorized gateway token or password is supplied, it calls only `sessions_list` and `memory_search` through the current `/tools/invoke` API.

The gateway secret is never passed on the command line. Set it in the environment or place one line in `/root/.config/clawhunter/gateway-token` with restrictive permissions:

```bash
mkdir -p /root/.config/clawhunter
chmod 700 /root/.config/clawhunter
printf '%s\n' 'authorized-gateway-secret' > /root/.config/clawhunter/gateway-token
chmod 600 /root/.config/clawhunter/gateway-token
```

OpenClaw treats this shared secret as full operator authority. Protect it accordingly. Without a credential, authentication-required targets are reported without bypass attempts. The obsolete unauthenticated agent-command and out-of-band exfiltration behavior is not present in v3.4.0.

### Assessment phases

1. Validate the IPv4 target and TCP port.
2. Discover HTTP or HTTPS from the root response.
3. Record root status, `x-openclaw` marker evidence, `/healthz`, and `/readyz`.
4. For HTTP, validate `Sec-WebSocket-Accept` and capture the first gateway event.
5. Record `connect.challenge` without forging an Ed25519 device identity or pairing request.
6. Call `sessions_list`; stop on 401/403 or rate limiting.
7. Call `memory_search` only when policy/authentication allowed the first read.
8. Write a JSON report even when the global deadline returns partial evidence.

The direct `/tools/invoke` allowlist is literal in code. Target responses and command-line input cannot select a different tool. Policy denials and unavailable tools are recorded and are not bypassed.

### Direct CLI use

```bash
OPENCLAW_GATEWAY_TOKEN='authorized-gateway-secret' \
python3 payloads/user/reconnaissance/clawhunter/harvest.py \
  --ip 192.0.2.10 \
  --port 18789 \
  --out /tmp/clawhunter-assessment.json \
  --timeout 180
```

`--timeout` is clamped to 1-180 seconds. `--legacy-protocol` performs one additional upgrade/challenge observation only; it never sends legacy agent commands.

| Exit | Meaning |
| ---: | --- |
| 0 | Assessed, including a useful partial report after deadline |
| 1 | Gateway authentication required or rejected |
| 2 | Target unreachable before a transport was established |
| 3 | Invalid/incomplete local execution or report-write failure |

## Output

Runtime output is written under `/root/loot/clawhunter/`:

```text
scan_YYYYMMDD_HHMMSS.log
scan_YYYYMMDD_HHMMSS.json
alert_YYYYMMDD_HHMMSS.log
harvest_IP_YYYYMMDD_HHMMSS.log
watchdog_state.json
```

Confirmed instances include their scheme, port, evidence class, confidence score, and evidence summary. mDNS and IPv6 hints are recorded separately from confirmed findings.

### Scan JSON shape

```json
{
  "scan_id": "20260806_120000",
  "payload_version": "3.4.0",
  "subnet": "192.0.2.1-254",
  "hosts_scanned": 12,
  "elapsed_seconds": 34,
  "timestamp": "2026-08-06T16:00:34Z",
  "instances": [
    {
      "ip": "192.0.2.10",
      "port": 18789,
      "detail": "http:// | OpenClaw Gateway | Class: CONFIRMED|Confidence: 11|Evidence: ..."
    }
  ]
}
```

Only confirmed instances appear in `instances`. Candidate, mDNS, IPv6, and per-path evidence remains in the text log. Assessment reports are separate JSON documents containing transport, health, WebSocket, tool-policy/authentication, elapsed-time, and partial-error fields.

### History, diff, and watchdog state

- History extracts confirmed endpoint strings from prior scan logs and de-duplicates them.
- Diff compares the current confirmed set with older logs and records new/gone counts.
- Watchdog persists its baseline to `watchdog_state.json` so a payload restart does not reclassify every known endpoint as new.
- Historical files are read-only inputs; CLAWHunter does not rewrite older scan reports.

## Dependency Fallbacks

| Capability | Preferred | Fallback | Degraded behavior |
| --- | --- | --- | --- |
| mDNS | `avahi-browse` from `avahi-utils` | None | Active scanning continues; Ghost reports limited mode |
| Layer 2 discovery | `arp-scan` | `arping`, then BusyBox `ping` | Slower host discovery |
| TCP/WS probe | `nc` | None | Endpoint cannot be actively classified |
| HTTP/S evidence | `curl` | None | Endpoint cannot be actively classified |
| Assessment | `python3` on eMMC | None | Discovery/results work; RIGHT reports Python requirement |
| MAC randomization | `macchanger` | `ip link` generated unicast MAC | Same restore trap remains active |
| Pager hardware API | Hak5 command helpers | Non-fatal no-op wrappers | Logs/reports continue without feedback |

The runtime intentionally avoids `jq`, third-party Python packages, `grep -P`, `shuf`, and predictable `mktemp -u` paths.

## Troubleshooting

### Payload does not appear in Pager Portal

- Confirm firmware 1.1.0 or newer.
- Confirm the exact category directory and executable `payload.sh` permissions.
- Re-run `scripts/install-pager.sh`; it creates all three current category paths.
- Confirm a local `common.sh` exists beside each installed payload when deploying a release bundle.

### Recon cannot connect

- Confirm the selected AP is 2.4 GHz; `wlan0cli` cannot join 5/6 GHz APs.
- Confirm the Recon context includes SSID, encryption type, and BSSID.
- Re-enter the passphrase. CLAWHunter does not persist it.
- Check whether DHCP assigned an IPv4 address to `wlan0cli` within 30 seconds.
- Open networks pass `NONE`; WPA, WPA2, and WPA3 map to `psk`, `psk2`, and `sae`.

### Alert produces only a skipped log

- DHCP or ARP may not have resolved the triggering client yet.
- Confirm `_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS` is present and valid.
- Check `/proc/net/arp` for that exact MAC. CLAWHunter will not probe a different client as a fallback.
- Firmware 1.1.0 is recommended because it includes monitor-interface stability work.

### No mDNS hints

- Install `avahi-utils` to eMMC and confirm `/mmc/usr/bin` is present.
- Confirm the gateway advertises `_openclaw-gw._tcp` on the same multicast domain.
- OpenClaw may have Bonjour disabled or may bind only to loopback/tailnet.
- Continue with active scanning; mDNS is a hint source, not a requirement.

### Generic service reported as a candidate

This is intentional. A reachable HTTP service, health endpoint, 401/403 response, or generic WebSocket upgrade lacks product-specific evidence. Inspect `Class`, `Confidence`, and `Evidence` in the text log before manual follow-up.

### Assessment says authentication required

- v3.4.0 does not guess or bypass credentials.
- Provide an explicitly authorized gateway secret through the protected file or environment.
- Treat the secret as full gateway operator authority.
- A 404 or `UNAVAILABLE` tool result may reflect OpenClaw tool policy rather than network failure.

### Python installed but not found

- Install it with `opkg install -d mmc python3`.
- Confirm `/mmc/usr/bin/python3` exists.
- Run `lib/common.sh` environment bootstrapping through the payload rather than invoking an incomplete copied file.
- Check `/mmc/usr/lib` when the interpreter reports missing shared libraries.

## Development and Release

Run the complete host-side gate:

```bash
scripts/check.sh
```

It runs Bash syntax checks, ShellCheck at warning severity, Python byte-compilation, shell and Python unit tests, version-unity validation, and reproducible-package verification. Build the release archive with:

```bash
scripts/package-release.sh
```

Host checks do not replace validation on a physical Pager. See [CONTRIBUTING.md](CONTRIBUTING.md) and [the v3.3 research record](docs/V3.3-RESEARCH.md).

### Gate coverage

- Bash syntax for shared library, all payloads, installer, packager, and shell tests.
- ShellCheck warnings across the same files.
- Python byte-compilation for `harvest.py` and its unit test.
- Strict IPv4/port validation and JSON escaping fixture checks.
- False-positive regression: generic 401 plus generic WebSocket stays `CANDIDATE`.
- Positive regression: OpenClaw markers plus `connect.challenge` become `CONFIRMED`.
- Exact avahi semicolon-record parsing.
- Standard and extended WebSocket frame decoding.
- `/tools/invoke` authentication-stop behavior.
- One unified runtime version across five load-bearing files.
- Two independent release builds compare byte-for-byte.
- Archive contains local payload resources.
- Installer stages byte-identical libraries in every category path.

### Physical Pager release checks

Host automation cannot validate RF conditions or physical UI behavior. Before promoting a later release, record:

- Pager firmware version;
- Portal discovery of all three payloads;
- user-mode picker/dialog rendering;
- Recon connection to open, WPA2, and WPA3 2.4 GHz fixtures where available;
- alert event variable delivery and exact client resolution;
- LED, haptic, audio, spinner, and button behavior;
- eMMC Python discovery;
- clean and aborted checkpoint behavior;
- loot/report retrieval through Pager Portal.

### Release artifact properties

`scripts/package-release.sh` normalizes archive entry order, modification time, numeric owner/group, and gzip timestamp. The quality gate builds twice in independent temporary directories and requires byte equality. It also dry-runs the installer into a temporary payload root and compares every embedded `common.sh` to the canonical library.

## Research Sources

- [Hak5 WiFi Pineapple Pager documentation](https://documentation.hak5.org/wifi-pineapple-pager)
- [Hak5 Pager firmware downloads and changelogs](https://downloads.hak5.org/pineapple/pager)
- [Official Hak5 Pager Payload Library](https://github.com/hak5/wifipineapplepager-payloads)
- [OpenClaw gateway protocol](https://docs.openclaw.ai/gateway/protocol)
- [OpenClaw Bonjour discovery](https://docs.openclaw.ai/gateway/bonjour)
- [OpenClaw tools invoke API](https://docs.openclaw.ai/gateway/tools-invoke-http-api)

## License

See [LICENSE](LICENSE).
