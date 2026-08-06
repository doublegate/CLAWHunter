<!-- Managed by Master-Claude. Universal rules come from the imported/inlined core.
     Edit only inside the MC-PROJECT block; mc-sync overwrites everything else. -->
<!-- mc-core: 0.2.0 | mode=import | lang=generic -->
# AGENTS.md — CLAWHunter

@/home/parobek/.claude/master-core/AGENTS.base.md
@/home/parobek/.claude/master-core/lang/generic.md
@/home/parobek/.claude/master-core/modules/10-commits-and-versioning.md
@/home/parobek/.claude/master-core/modules/20-testing-and-accuracy.md
@/home/parobek/.claude/master-core/modules/30-quality-gates.md
@/home/parobek/.claude/master-core/modules/40-docs-and-adrs.md
@/home/parobek/.claude/master-core/modules/50-architecture-patterns.md
@/home/parobek/.claude/master-core/modules/60-security.md
@/home/parobek/.claude/master-core/modules/70-release-ceremony.md
@/home/parobek/.claude/master-core/modules/80-phase-sprint-workflow.md
@/home/parobek/.claude/master-core/modules/90-multi-language-integration.md
@/home/parobek/.claude/master-core/modules/91-agent-system-architecture.md
@/home/parobek/.claude/master-core/modules/95-named-pattern-library.md

<<< MC-PROJECT-START >>>

## Project: CLAWHunter

> Hand-authored. `mc-sync` never overwrites content between the MC-PROJECT markers.
> Per-project truth only — universal rules come from the imported core above.

> This is the **`main`** branch — the Hak5 Pager payload suite. The native **Monstatek M1** C
> port is a **separate device** and lives only on the **`M1`** branch (`vendor/`, `docs/M1-PORT.md`).
> Do not describe or reintroduce M1 specifics here.

- **What it is:** Hak5 WiFi Pineapple **Pager** payload suite for discovering/exploiting OpenClaw AI-gateway instances on local networks. Three payload variants (interactive, recon-triggered, alert-fired) share one fingerprinting library, with full hardware integration (color display, RGB LEDs, haptics, audio, results browser, harvest engine). Internal-only tooling — **keep private** (workspace strategy anti-recommendation §2.4).
- **Stack:** Bash (payloads + shared lib) + Python3 (`harvest.py`, stdlib-only). Runs on the Pager's OpenWRT userland; no build step — payloads execute in place.
- **Deploy:** copy payloads to the Pager; install larger deps (e.g. python3) to internal 4 GB eMMC with `-d mmc` — the root overlay has <32 MB free after firmware.
- **Test / lint:** no formal automated gate (shell + Python payloads). Validate on-hardware; syntax-check Bash with `bash -n` / `shellcheck`, Python with `python3 -m py_compile`.

### Architecture — load-bearing facts

- Three modes — **recon** (RF-first, auto-connect) / **user** (interactive, all features) / **alert** (auto-fires, <5s, silent watchdog) — all source one shared library, `lib/common.sh` (LED, audio, fingerprinting, harvest trigger). Add cross-cutting behavior there, not per-payload.
- Fingerprinting pipeline is IPv4 port-scan based, with mDNS + ARP-cache harvesting; IPv6 link-local (`fe80::/10`) neighbors are logged as candidates only (no port scan — scope-ID complexity).
- Scan speed is profile-driven (Ghost/Quiet/Normal/Fast/Aggressive); NORMAL/QUIET scan sequentially, FAST/AGGRESSIVE in parallel — both paths must honor checkpoint resume identically.

### Gotchas / institutional knowledge

- **Version must stay unified** across `lib/common.sh`, all three `payload.sh` files, and `harvest.py` — v3.2.0 unified these; a mismatch is a known past bug.
- **Checkpoint parity:** sequential and parallel scan paths must both skip and write `/tmp/clawhunter_checkpoint_<subnet>` entries; the parallel path once silently didn't (fixed in v3.2.0).
- **IPv6/IPv4 sort collision:** never pipe IPv6 addresses through the IPv4 dot-field sort (`sort -t. -k4 -n`); sort IPv6 separately with `sort -u`.
- `harvest.py` enforces a 180s global ceiling across its 5 agent turns — returns partial results rather than hanging.

### Where things live

- `payloads/user/clawhunter/` — interactive payload (`payload.sh`) + harvest engine (`harvest.py`)
- `payloads/recon/clawhunter/` — recon variant (RF-first, auto-connect)
- `payloads/alert/clawhunter-watchdog/` — alert/watchdog variant (auto-fires, silent)
- `lib/common.sh` — shared library (LED, audio, mDNS/ARP fingerprinting, harvest trigger)
- `docs/V3-RESEARCH.md` — protocol research, feature specs, stretch goals
- `CHANGELOG.md` — authoritative per-version history (read the top entry first)

### Status / next

- `main` is the Pager suite at **v3.2.0** (latest tagged release). The M1 native port is on the **`M1`** branch (v4.0.0-m1, documented but not yet git-tagged) — a different target device; keep the two branches' recon logic conceptually in step but don't merge M1's `vendor/` tree here.
- See `CLAUDE.local.md` for volatile session state.
<<< MC-PROJECT-END >>>

