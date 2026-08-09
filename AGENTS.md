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

> `CLAUDE.md` and `GEMINI.md` are **symlinks to this file**. Edit `AGENTS.md`; never
> replace either symlink with a real file or the three agents silently fork.

- **What it is:** Hak5 WiFi Pineapple **Pager** payload suite for discovering and assessing OpenClaw AI-gateway instances on authorized local networks. Three payload variants (interactive, recon-triggered, alert-fired) share one fingerprinting library, with full hardware integration (color display, RGB LEDs, haptics, audio, results browser, harvest engine).
- **Stack:** Bash (payloads + shared lib) + Python3 (`harvest.py`, stdlib-only). Runs on the Pager's OpenWRT userland; no build step — payloads execute in place.
- **Deploy:** copy payloads to the Pager; install larger deps (e.g. python3) to internal 4 GB eMMC with `-d mmc` — the root overlay has <32 MB free after firmware.
- **Test / lint:** `scripts/check.sh` is the deterministic host/release gate (Bash syntax, ShellCheck, Python compile/unit tests, loopback integration, invariants, reproducible packaging, checksums, and installer dry run). Physical Pager validation remains a separate recorded hardware gate.
- `CONTRIBUTING.md` holds the 11 numbered **architecture contracts** (regression coverage required when changed), the mandatory commenting standard, and the PR checklist. Read it before changing classification, checkpointing, parallelism, or packaging.
- CI: `.github/workflows/quality.yml` runs `scripts/check.sh` on every push/PR; `release.yml` fires on a `v*.*.*` tag, rebuilds from the tag (never local `dist/`), asserts the tag equals `package-release.sh`'s `VERSION`, and refuses to replace an already-published release.

### Architecture — load-bearing facts

- Three modes — **recon** (RF-first, auto-connect) / **user** (interactive, all features) / **alert** (auto-fires, <5s, silent watchdog) — all source one shared library, `lib/common.sh` (LED, audio, fingerprinting, harvest trigger). Add cross-cutting behavior there, not per-payload.
- Fingerprinting pipeline is IPv4 port-scan based, with mDNS + ARP-cache harvesting; IPv6 link-local (`fe80::/10`) neighbors are logged as candidates only (no port scan — scope-ID complexity).
- Scan speed is profile-driven (Ghost/Quiet/Normal/Fast/Aggressive); NORMAL/QUIET scan sequentially, FAST/AGGRESSIVE in parallel — both paths must honor checkpoint resume identically.

### Gotchas / institutional knowledge

- **A version bump touches 11 files.** Six carry runtime declarations that `check.sh` parses into one unified value (`lib/common.sh`, the three `payload.sh` files, `harvest.py`, `scripts/package-release.sh`); four are user-facing surfaces asserted as exact strings (`README.md`'s `version-3.4.0-green` badge, `CHANGELOG.md`'s `^## [v3.4.0] - <date>$` **including the date**, `scripts/install-pager.sh`, `docs/architecture.dot`); and `check.sh` itself hard-codes the expected value so an accidental *unified* downgrade still fails. Count files, not occurrences — several files hold more than one (`check.sh` has 10, `README.md` 11). Bumping only the runtime declarations fails the gate.
- **The gate is not BusyBox-constrained.** `scripts/check.sh` needs `shellcheck`, `rg` (ripgrep), `curl`, and `nc` (netcat) on the *host*. The stdlib-only / BusyBox-compatible rule governs shipped payload code, not the gate. A missing `nc` surfaces only as `FAIL: loopback classifier probe failed` — `probe_openclaw` gates on `nc -z` (`lib/common.sh:229`) — which reads like a classifier bug rather than an absent tool. CI never hits this because `ubuntu-latest` ships netcat.
- **Checkpoint parity:** sequential and parallel scan paths must both skip and write `/tmp/clawhunter_checkpoint_<subnet>_<port-key>` entries only after every selected port finishes (CONTRIBUTING contract 6).
- **How that parity is enforced.** `check.sh:46` asserts *exactly two* literal `checkpoint_mark "$CHECKPOINT_FILE"` call sites in the user `payload.sh` — a textual proxy for the rule above, and one that fails *silently*: `set -e` on a bare `[ ]` prints nothing, so the gate just stops after the unit tests and reads like a truncated pass. Any refactor that moves those calls trips it, and the count cannot tell a harmless one from a harmful one. Funnelling both through a wrapper that reads `CHECKPOINT_FILE` from an enclosing scope, for instance, passes every existing test while silently dropping resume records for any future caller outside that scope. Deciding which kind you have is a human's job, which is the whole point of pinning it structurally. Outside a release you may re-point the assertion at the new call sites in the same commit; loosening it to `-eq 1` or deleting it is never a resolution. **During a release, do neither** — see `.claude/skills/release/SKILL.md`; a gate that fails while cutting a version is a finding to report.
- **The firmware does not run your payload file — it runs a rewritten copy.** Verified on a Pager (OpenWrt 24.10.1) by capturing a real UI launch. `/pineapple/pineapple` prepends a prelude and writes the result to `/tmp/payload-<random>.sh`, then executes that:
  ```bash
  #!/bin/bash
  PATH="$PATH:/mmc/bin:/mmc/sbin:/mmc/usr/bin:/mmc/usr/sbin"
  . /lib/hak5/commands.sh
  . /lib/hak5/pineapple.sh
  ```
  Three consequences. **(1)** `$0` *and* `BASH_SOURCE[0]` both name the temp file, so a payload cannot locate its own `common.sh`/`harvest.py` from either — resolve from `_PAYLOAD_HOME` (exported) or `PWD` (set to the payload directory) instead. **(2)** The `DUCKYSCRIPT_*` status constants (`USER_DENIED=0`, `USER_CONFIRMED=1`, `CANCELLED=2`, `REJECTED=3`, `ERROR=4`) come from that prelude as **non-exported shell variables** — they are real and comparisons against them work, but `env` will not show them, so don't conclude from an `env` dump that they are missing. **(3)** eMMC paths are already on `PATH` before the payload starts.
- **The device's `ip` is BusyBox, not iproute2.** Its usage is `ip route list|flush|add|del|change|append|replace|test` with options `-f family` and `-o oneline` only — there is no `route get`, no `-4`, and no `-br`. Those idioms fail silently (empty output, not an error), so code that "works on my machine" degrades to a wrong default on device rather than complaining. Use `detect_local_ipv4` / `detect_default_iface` in `lib/common.sh`, which try full iproute2 first and fall back to `ip -o -f inet`, `ip route` parsing, and `ifconfig`. `ip neigh show` and `ip link set` are supported.
- **Never `continue` unbounded after a rejected picker value.** The device's only surface is the screen; an unbounded retry loop redraws a dialog forever and is indistinguishable from a hardware lockup, escapable only by power-cycling. Cap consecutive rejections and exit cleanly (`MAX_BAD_INPUT` in the user payload).
- **IPv6/IPv4 sort collision:** never pipe IPv6 addresses through the IPv4 dot-field sort (`sort -t. -k4 -n`); sort IPv6 separately with `sort -u`.
- `harvest.py` enforces one 180s global ceiling across transport discovery, health/readiness, WebSocket challenge, authorized read-only tools, and reporting; it returns partial results rather than hanging.

### Where things live

- `payloads/user/reconnaissance/clawhunter/` — interactive payload (`payload.sh`) + harvest engine (`harvest.py`)
- `payloads/recon/access_point/clawhunter/` — recon variant (RF-first, auto-connect)
- `payloads/alerts/pineapple_client_connected/clawhunter-watchdog/` — alert/watchdog variant (auto-fires, silent)
- `lib/common.sh` — shared library (LED, audio, mDNS/ARP fingerprinting, harvest trigger)

### Status / next

- `main` is the Pager suite at **v3.4.0**.
<<< MC-PROJECT-END >>>
