# Changelog

All notable changes to CLAWHunter are documented here.

---

## [v4.0.0-m1] — 2026-03-14

### Added — Native Monstatek M1 Port (`M1` branch)
- **Full native C port** of all three CLAWHunter payload modes (recon, user, alert) compiled directly into the M1 firmware (`m1_csrc/m1_clawhunter.c`, `m1_clawhunter.h`).
- **ESP32 TCP probe handler** (`tcp_connect_probe()` in `esp_app_main.c`) — implements `AT+CIPSTART` → `AT+CIPSEND` (HTTP GET) → `+IPD` banner read → `AT+CIPCLOSE` flow over the SPI AT command interface.
- **SPI protocol extension** — `CTRL_REQ_TCP_CONNECT` enum, `tcp_connect_t` struct (IP, port, timeout, result code, 64-byte banner buffer), and `ctrl_cmd_t` union field added to `ctrl_api.h`.
- **AT command defines** — `ESP32C6_AT_REQ_CIPSTART`, `CIPCLOSE`, `CIPSEND`, `IPD` response prefix added to `esp_at_list.h`.
- **M1 main menu integration** — CLAWHunter appears as a top-level menu item (after Sub-GHz) with Recon/User/Alert sub-menu, item counts corrected across all 4 preprocessor branches.
- **Scan profile picker** — D-pad-driven UI for selecting Ghost/Quiet/Normal/Fast/Aggressive profiles on the 128×64 monochrome OLED.
- **Progress bar** — real-time scan progress with percentage display at screen bottom during subnet sweeps.
- **Scrollable results list** — UP/DOWN to scroll through discovered instances, BACK to exit.
- **OpenClaw signature detection** — banner checked for `openclaw`, `OpenClaw`, and `clawd` keywords; confirmed vs. candidate classification.
- **Buzzer feedback** — dual-tone alert (2000 Hz + 2500 Hz) via `m1_buzzer_set()` on confirmed discovery.
- **Graceful fallback** — if ESP32 firmware doesn't support TCP connect yet, falls through to ARP-level candidate marking.
- **Technical documentation** — `docs/M1-PORT.md` covering architecture, hardware differences, build instructions, memory footprint, protocol extension details, and file manifest.
- **Build system** — `m1_clawhunter.c` added to `cmake/m1_01/CMakeLists.txt`; path fixes for FatFs, Infrared, and Middlewares directories.
- **Vendored dependencies** — M1 firmware (`Monstatek/M1`) and SDK (`Monstatek/m1-sdk`) vendored in `vendor/` with `.git` directories removed.

### Build
- Compiles clean with `arm-none-eabi-gcc 14.2.0` on Linux (CachyOS/Arch)
- Final firmware: 655,968 bytes text, 10,524 data, 251,544 BSS (49.9% of 1MB flash)
- Output: `vendor/M1/artifacts/M1_v0800_C3.1_wCRC.bin` (CRC-stamped, ready to flash)

---

## [v3.2.0] — 2026-03-07

### Added
- **IPv6 link-local harvest** — `arp_cache_harvest()` now checks `ip -6 neigh show` for `fe80::/10` neighbors. Results are logged as candidates with a `[IPv6]` prefix; full port scanning remains IPv4-only (scope ID complexity).
- **Scan resume / checkpoint** — at scan start, if `/tmp/clawhunter_checkpoint_<subnet>` exists, already-scanned hosts are skipped and a resume count is displayed. Works in both sequential (NORMAL/QUIET) and parallel (FAST/AGGRESSIVE) scan paths. Checkpoint is preserved on abort, removed on clean completion.
- **Harvest global timeout** — `harvest.py` enforces a 180-second ceiling across all 5 agent turns. Partial results are returned rather than hanging indefinitely.
- **Watchdog state persistence** — `watchdog_state.json` written to `/root/loot/clawhunter/` captures the last known instance list. On restart, watchdog loads this as its baseline so previously-found instances don't re-trigger as "new".

### Fixed
- **IPv6/IPv4 sort collision** — `arp_cache_harvest()` previously piped IPv6 addresses (`fe80::...`) through `sort -t. -k4 -n` (IPv4 dot-field sort). IPv6 addresses are now sorted separately with `sort -u` to avoid malformed output.
- **Parallel checkpoint gap** — `_run_parallel_probe()` (FAST/AGGRESSIVE profiles) neither skipped checkpoint-recorded hosts nor wrote new ones. Both behaviours now match the sequential path.
- Version numbers unified to 3.2.0 across `lib/common.sh`, all three `payload.sh` files, and `harvest.py`.

---

## [v3.1.0] — 2026-03-07

### Added
- **Multi-turn agent session** — Phase 3 rewritten: a single persistent WebSocket connection drives up to 5 sequential turns. The agent maintains full conversation context across turns; each turn builds on what the previous discovered.
- **Agent-native tool exploitation** — turns invoke the victim agent's own built-in tools (`exec`, `Read`, `memory_search`, `sessions_list`, `sessions_history`, `nodes`) rather than plain natural-language requests. Deeper access, structured output.
- **Out-of-band exfil (Turn 5, optional)** — instructs the victim agent to `curl` harvested data directly to an attacker-controlled Telegram bot or HTTPS webhook. Data flows victim → attacker endpoint independently of the Pager.
- **OOB pre-config constants** — `EXFIL_BOT_TOKEN`, `EXFIL_CHAT_ID`, `EXFIL_WEBHOOK_URL` in payload header (commented out; fill before deploying).
- **Improved streaming parser** — handles both `event.payload.delta` (str and list-of-blocks) and `event.payload.content` shapes, plus all terminal `res` statuses: `done`, `error`, `complete`, `cancelled`.

### Changed
- `harvest.py` Phase 3 completely rewritten from 15 one-shot requests to a single 5-turn persistent session.

---

## [v3.0.3] — 2026-03-06

### Added
- **Timing dither per scan profile** — randomized inter-probe delay (base + jitter via `$RANDOM`) applied after each host probe. Breaks the metronomic timing signature stateful IDS engines fingerprint. Works alongside randomized host order for two-axis evasion.

### Fixed
- Removed dead `import hashlib` from `harvest.py` (imported but never used).

### Dither values
| Profile | Base | Max jitter | Intent |
|---------|------|-----------|--------|
| GHOST | 0 ms | 0 ms | Passive only |
| QUIET | 50 ms | 200 ms | Human-paced browsing |
| NORMAL | 0 ms | 80 ms | Break metronomic timing |
| FAST | 0 ms | 25 ms | Minimal evasion |
| AGGRESSIVE | 0 ms | 0 ms | Speed priority |

---

## [v3.0.2] — 2026-03-05

### Added
- **Integrated harvest module** (`harvest.py`) — stdlib-only Python3 post-exploitation engine. Three-phase: auth probe → HTTP harvest → multi-turn agent session.
- **Results browser harvest trigger** — RIGHT key (or any key ≠ UP/DOWN/B/LEFT) in the results browser launches harvest against the selected find.
- **OOB exfil prompts** — operator is prompted for Telegram or webhook exfil method at harvest launch time.

---

## [v3.0.1] — 2026-03-04

### Fixed (OpenWRT/busybox compatibility)
- `grep -oP` → `awk` (busybox grep has no PCRE `-P` flag)
- `shuf` → awk PRNG (`awk -v seed=$RANDOM 'BEGIN{srand(seed)}…'`) — `shuf` not present on OpenWRT
- `/dev/tcp` TCP probes → `nc -w 3` fallback (Pager kernel may have `/dev/tcp` disabled)
- Removed `TEXT_PICKER` usage — DuckyScript has no free-text input primitive; replaced with instructional display messages

---

## [v3.0.0] — 2026-03-03

### Added
- **Three-payload suite** — `payloads/user/`, `payloads/recon/`, `payloads/alert/` replacing single-file payload
- **`lib/common.sh`** — shared library centralizing all LED, audio, haptic, logging, fingerprinting, results browser, history, and diff logic
- **WebSocket upgrade probe (A1)** — raw WS handshake via `/dev/tcp` + `nc` fallback; ~99% accuracy
- **Canvas path probe (A2)** — `/__openclaw__/canvas/` + `/__openclaw__/a2ui/` unique path detection
- **`/agent/status` intel (A3)** — extracts model, context%, active tools, sub-agent count, uptime
- **Recon payload variant (B1)** — reads `_RECON_SELECTED_AP_*` context vars; no manual pickers needed
- **Alert payload variant (B2)** — auto-fires on client connect, <5s, silent forced
- **Continuous mDNS monitor (C1)** — timed `avahi-browse` loop with live countdown
- **ARP cache harvest (C2)** — `/proc/net/arp` + `ip neigh` pre-check; known hosts skip discovery
- **JSON report output (D1)** — structured `scan_YYYYMMDD_HHMMSS.json` alongside `.log` files
- **MAC randomization (E1)** — `macchanger` or `ip link`; restored on exit via trap
- **Scan speed profiles (F4)** — GHOST / QUIET / NORMAL / FAST / AGGRESSIVE
- **Watchdog mode (F5)** — periodic rescan; alerts on new or gone instances

---

## [v2.1.0] — 2026-02-28

### Added
1. **Silent mode** — suppress all audio and haptic for covert operations
2. **Progress counter** — live `%` in spinner + host index tracking (`n/total`)
3. **ARP host discovery** — Layer-2 detection via `arp-scan` → `arping` → ping fallback
4. **Randomized scan order** — awk PRNG host shuffle (busybox compatible) to reduce IDS signature
5. **HTTPS probe** — try `http://` then `https://` per open port for TLS-wrapped gateways
6. **Extended ports** — optionally sweep 80, 443, 3000, 8080, 8443 (reverse proxy detection)
7. **mDNS pre-scan** — `avahi-browse` zero-probe discovery before port sweep
8. **Deep fingerprinting** — version, persona, model from `/health`, `/status` endpoints
9. **WiFi client mode** — connect to target AP via Recon UI context vars; auto-scan the AP subnet
10. **Multi-subnet sweep** — loop back to scan another subnet without restarting payload
11. **Cross-run history/diff** — browse all past finds; diff new vs. gone vs. prior runs

---

## [v1.0.0] — 2026-02-20

### Added
- Initial release — ARP discovery, port probe, basic OpenClaw HTTP fingerprint, hardware feedback (LED, haptic, audio)
