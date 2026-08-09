# Changelog

All notable changes to CLAWHunter are documented here.

---

## [v3.4.0] - 2026-08-09

Security and release-integrity maintenance. No new operator-facing features and
no protocol changes; the fingerprinting, scan, and assessment behaviour of
v3.3.0 is unchanged. Two of the three fixes alter how files are written on the
device, so an upgrade is recommended for anyone whose Pager stores loot.

### Security
- **Loot is no longer world-readable.** Scan output names third-party hosts and
  records harvested evidence about them, but reports and logs were created 0644
  in a 0755 directory. `lib/common.sh` now sets `umask 077` before the first
  write, covering logs, JSON reports, checkpoint files, and any child process
  the payload spawns. A loot directory inherited from an earlier release is
  additionally `chmod 0700`, and that call fails closed: the library refuses to
  run rather than write evidence into a directory it could not secure.
- **`harvest.py` writes its report atomically at 0600.** It creates an `O_EXCL`
  temporary file and `os.replace()`s it over the destination, rather than
  opening the destination directly — `O_CREAT`'s mode applies only when a file
  is created, so a report left by an earlier run would otherwise have been
  written at its existing mode and only restricted afterwards. The rename also
  makes the write crash-safe: losing power mid-scan now leaves the previous
  report intact instead of truncated.

### Fixed
- Made release packaging reproducible across hosts. `scripts/package-release.sh`
  generated `SHA256SUMS` with a bare `sort -z`, which honours `LC_COLLATE`, so a
  builder on `en_US.UTF-8` emitted the manifest in a different order than a
  C-locale CI runner and therefore a different archive hash. Every per-file hash
  still verified, so nothing reported a problem — but rebuilding from source to
  confirm a published checksum failed. Manifest generation now pins `LC_ALL=C`.
  Found while verifying the published v3.3.0 archive; those assets are correct
  and unaffected, having been built in the C locale.

### Changed
- `scripts/check.sh` now asserts the release manifest is in C-locale byte order.
  Its existing two-build comparison runs on one host under one locale and so
  cannot detect collation drift by construction.

### Validated
- v3.3.0 was validated on physical hardware for the first time (WiFi Pineapple
  Pager, OpenWrt 24.10.1, `ramips/mt76x8`, kernel 6.6.86). 14 checks pass on
  device, including detection reaching `CONFIRMED` with the full evidence chain
  and the harvest engine reaching `ASSESSED` through both authorized read-only
  tools. Portal rendering, button navigation, alert delivery, RF association,
  and audio remain unvalidated. See `docs/V3.4-RELEASE-CHECKLIST.md`.

---

## [v3.3.0] - 2026-08-06

### Release engineering
- Added one deterministic release gate covering Bash syntax, ShellCheck,
  Python compilation/unit tests, loopback HTTP/WebSocket integration, version
  parity, checkpoint parity, two byte-identical package builds, checksums, and
  a staged installer dry run.
- Added a tag-driven GitHub Actions release workflow with a guarded manual
  recovery trigger; both paths rebuild and validate the artifact from the
  immutable release tag before publishing it.
- Added an internal file manifest and adjacent archive checksum, and made the
  release archive self-contained by including all documentation and images
  referenced by its README.
- Added detailed release notes, a PASS/FAIL/WARN evidence checklist, expanded
  firmware/protocol research, and implementation-level rationale comments
  throughout every generated or modified source and automation file.

### Added
- Official Payload Library-compatible category paths for user, recon, and alert payloads.
- Evidence-scored OpenClaw classification (`CONFIRMED`, `LIKELY`, and `CANDIDATE`) with explicit evidence in logs and reports.
- Current OpenClaw gateway checks for port 18789, `_openclaw-gw._tcp`, `/healthz`, `/readyz`, WebSocket upgrade, and `connect.challenge`.
- Device-local installer, reproducible Pager release archive, embedded manifest, and archive checksum.
- Host-side tests and GitHub Actions checks covering syntax, ShellCheck warnings, classifiers, mDNS parsing, JSON, harvest protocol helpers, version unity, and packaging reproducibility.
- A local protocol fixture exercising real HTTP readiness, WebSocket challenge handling, bearer authentication, and authenticated read-only tool calls.
- `docs/V3.3-RESEARCH.md`, recording the Hak5 firmware, official payload, OpenClaw, GitHub, and community research used for this release.

### Changed
- User payload now scans the active IPv4 network and accepts a full target IP through `IP_PICKER`; AP selection remains the recon payload's responsibility.
- Recon payload uses the current `WIFI_CONNECT` signature, encryption names, selected BSSID, and refuses unsupported 5/6 GHz selections on `wlan0cli`.
- Recon payload prompts for the exact SSID when current Recon context identifies a hidden access point.
- Alert payload consumes the documented client-connected event variables and resolves only that client's IP with `FIND_CLIENT_IP` or exact-MAC ARP lookup.
- Harvest engine now uses the current bounded HTTP and WebSocket surfaces and only invokes two read-only tools when the operator supplies an authorized gateway secret.
- eMMC-installed binaries and libraries are discovered through `/mmc` PATH and library bootstrapping.
- Checkpoint names include the selected port set; sequential and parallel paths mark a host only after all its ports finish.
- IPv6 link-local neighbors remain separate, logged candidates and never enter the IPv4 scan/sort path.
- Periodic watchdog scans suppress per-target display/audio/browser output and surface only changes to the detected gateway set.
- Recon mDNS candidates are retained in the scan log instead of being erased when the post-association result file is initialized.

### Fixed
- Removed generic HTTP 401/403 and generic WebSocket upgrades as false-positive confirmation signals.
- Removed the obsolete unauthenticated agent-turn protocol, credential prompts, and out-of-band exfiltration flow.
- Eliminated unsafe command interpolation and predictable temporary paths in probes.
- Corrected the legacy 18790 default to the current OpenClaw gateway default, 18789, while retaining 18790 as an optional legacy probe.
- Unified all runtime version declarations at 3.3.0.
- Replaced obsolete numeric `VIBRATE` arguments with documented RTTTL haptic patterns in shared and alert feedback paths.

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
- `/dev/tcp` TCP probes — guard condition removed; `/dev/tcp` attempted directly with `nc` fallback on empty response
- `TEXT_PICKER` replaced with instructional messages — the command exists and is valid DuckyScript, but character-by-character 5-button entry is impractical for passwords and API tokens

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
