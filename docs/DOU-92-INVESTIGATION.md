# DOU-92: 5 GHz Client Association Investigation

**Status:** Investigation phase — requires physical Hak5 Pager hardware  
**Created:** 2026-10-10  
**Issue:** https://linear.app/clawhunter/issue/DOU-92

## Executive Summary

CLAWHunter cannot scan networks accessible only via 5 GHz access points. The current implementation is correctly limited to 2.4 GHz due to hardware constraints of `wlan0`, the radio currently used for client connections. Evidence from Pager command-line diagnostics suggests `wlan1` may support 5 GHz, but critical questions about VIF creation, firmware interface management, and PineAP/recon trade-offs can only be answered with the physical device.

**This document does not propose a solution.** It catalogs what the codebase reveals and defines the hardware validation work needed before any code changes can be designed.

---

## Current Implementation Analysis

### 1. Hardcoded 2.4 GHz Interface

Both the recon and user payloads declare:

```bash
readonly WIFI_IF="wlan0cli"
```

**File locations:**
- `payloads/recon/access_point/clawhunter/payload.sh:44`
- `payloads/user/reconnaissance/clawhunter/payload.sh:44`

The `readonly` modifier prevents runtime changes, making `wlan0cli` a compile-time constant.

### 2. Band Guard Implementation

**Recon payload** (`payloads/recon/access_point/clawhunter/payload.sh:173-178`):

```bash
AP_FREQ="${_RECON_SELECTED_AP_FREQ:-}"
AP_CHANNEL="${_RECON_SELECTED_AP_CHANNEL:-}"
if { [[ "$AP_FREQ" =~ ^[0-9]+$ ]] && [ "$AP_FREQ" -ge 5000 ]; } || \
   { [ -z "$AP_FREQ" ] && [[ "$AP_CHANNEL" =~ ^[0-9]+$ ]] && [ "$AP_CHANNEL" -ge 36 ]; }; then
    ERROR_DIALOG "Unsupported Band" "wlan0cli supports only 2.4 GHz access points"
    exit 1
fi
```

**Guard characteristics:**
- Handles both frequency (≥5000 MHz) and channel (≥36) forms
- Tolerates missing `AP_FREQ` to support older firmware contexts
- Error message is radio-specific, not payload-specific
- Exit is clean — no loot files or state changes before rejection

**This guard is correct for `wlan0cli`**. Removing it would replace a clear message with a 30-second DHCP timeout and misleading "check password" error (line 246).

### 3. Firmware Integration Points

CLAWHunter depends on Hak5 firmware functions sourced from `/lib/hak5/commands.sh`:

```bash
WIFI_CONNECT "$WIFI_IF" "$SSID" "$WIFI_ENC" "$PASS" "${BSSID:-ANY}"
WIFI_DISCONNECT "$WIFI_IF"
WIFI_CLEAR "$WIFI_IF"
```

**Unknown:**
- Whether `WIFI_CONNECT` accepts non-`wlan0cli` interface names
- Whether firmware pre-creates a `wlan1cli` VIF
- Whether firmware will auto-create a client VIF on `wlan1` when passed to `WIFI_CONNECT`

### 4. Architecture Contracts

From `CONTRIBUTING.md`, contract 10:

> Recon handles hidden-SSID context, uses the official encryption values, and pins the selected BSSID **on the 2.4 GHz client interface**.

This contract is currently **load-bearing** and requires regression coverage if changed.

---

## Evidence from the Issue

The Linear issue quotes diagnostics captured from a physical Pager (OpenWrt 24.10.1, firmware unspecified):

### Hardware Capabilities

```
DISTRIB_TARGET='ramips/mt76x8'
iwinfo wlan0 → Type: nl80211  HW Mode(s): 802.11b/g/n
```

**Interpretation:** The MT7628/7688 SoC's primary radio (`wlan0`) lacks `802.11a/ac/ax` — no 5 GHz PHY.

### PineAP Command-Line Evidence

From `pineapd`'s invocation:

```
--interface wlan1mon --band wlan1mon:2,5
--interface wlan2mon --band wlan2mon:2,5
--interface wlan0mon --band wlan0mon:2
```

**Key observations:**
1. `wlan1mon` advertises bands **2 and 5**
2. Interfaces are in **monitor mode** (serving PineAP and recon scanning)
3. No `wlan1cli` or `wlan1` client VIF was observed via `ifconfig` at the time

---

## Open Questions (Hardware Required)

These questions **cannot** be answered from the repository:

### 1. VIF Enumeration
- Does the firmware expose a `wlan1cli` client VIF at boot?
- If not, can one be created with `iw phy` / `iw dev` / `ip link` without firmware support?
- What is the output of `iw phy` for the radio backing `wlan1mon`?
- What is the output of `iw list` showing supported interface-type combinations?

### 2. Firmware Interface Management
- Does `WIFI_CONNECT "wlan1cli" ...` work if a `wlan1cli` VIF exists?
- Does it create one on-demand if it doesn't?
- Does it reject non-`wlan0cli` names outright?
- What error message / return code does a failed `WIFI_CONNECT` produce?

### 3. Monitor/Client Coexistence
- Can a client VIF and monitor VIF coexist on `wlan1` via separate virtual interfaces?
- If so, are they subject to a shared-channel constraint?
  - Does the client association lock `wlan1mon` to the AP's channel?
  - Does that break PineAP beacon responses on other channels?
  - Does it break Recon handshake capture when the target is on a different channel?

### 4. PineAP / Recon Impact
- Which PineAP features rely on `wlan1mon` remaining in monitor mode?
- What breaks when a client VIF is up on the same radio?
- Can the payload temporarily disable `wlan1mon`, connect as a client, scan, then restore monitor mode?
- What is the restore latency, and does it affect the Pager's Recon/PineAP workflow?

### 5. Valid Channel List
- What is `iw phy` / `iwinfo wlan1 info` / `iwlist wlan1 channel` output?
- Does it match the band declaration in `pineapd` (`2,5`)?
- Are there regulatory restrictions (e.g., DFS channels) that would limit practical 5 GHz use?

---

## Hardware Validation Workflow

When a physical Pager becomes available:

### Phase 1: Capability Enumeration

```bash
# Identify the PHY backing wlan1mon
iw dev wlan1mon info

# List all PHYs and their capabilities
iw list

# Check supported interface combinations
iw phy phy1 info | grep -A 20 "valid interface combinations"

# Check advertised channels
iwinfo wlan1mon info
```

**Goal:** Confirm `wlan1`'s radio can do 5 GHz in client mode.

### Phase 2: VIF Creation Test

```bash
# Attempt to create a client VIF on the same PHY as wlan1mon
iw phy phy1 interface add wlan1cli type managed

# Check if it appeared
ip link show wlan1cli

# Try bringing it up
ip link set wlan1cli up
```

**Goal:** Determine if client and monitor VIFs can coexist without firmware help.

### Phase 3: WIFI_CONNECT Contract Test

**Test 1: Non-existent VIF**
```bash
# From a payload or shell, attempt:
WIFI_CONNECT "wlan1cli" "TestSSID" "open" "NONE" "ANY"
# Record: exit code, error message, whether it auto-creates wlan1cli
```

**Test 2: Pre-created VIF**
```bash
# Manually create wlan1cli, then:
WIFI_CONNECT "wlan1cli" "TestSSID5G" "psk2" "password123" "AA:BB:CC:DD:EE:FF"
# Record: success/failure, DHCP outcome, whether wlan1mon is affected
```

**Test 3: 5-argument signature**
The current call is:
```bash
WIFI_CONNECT "$WIFI_IF" "$SSID" "$WIFI_ENC" "$PASS" "${BSSID:-ANY}"
```
Confirm all five arguments work with a non-`wlan0cli` interface.

### Phase 4: Monitor-Mode Impact Measurement

**Baseline:**
1. Note active PineAP features (open SSID list, logging, etc.)
2. Note active Recon state (scanning APs, capturing handshakes)

**Client VIF Up:**
1. Create/connect `wlan1cli` to a test 5 GHz AP
2. Re-check PineAP functionality
3. Re-check Recon scanning on channels ≠ associated channel
4. Check Recon handshake capture while associated

**Disconnect and Restore:**
1. `WIFI_DISCONNECT wlan1cli`
2. Measure time until `wlan1mon` resumes normal monitor traffic
3. Confirm PineAP/Recon features return to baseline

**Goal:** Quantify what the operator sacrifices for 5 GHz scanning.

### Phase 5: Channel Lock Test

**Setup:**
- Associate `wlan1cli` to a 5 GHz AP on channel 36
- Confirm association via `iw dev wlan1cli link`

**Test:**
```bash
# Attempt to change wlan1mon to channel 149
iw dev wlan1mon set channel 149

# Check actual channel
iw dev wlan1mon info | grep channel

# Try capturing a handshake on a different channel while associated
# (requires a test AP on ch 149 and a client to trigger a handshake)
```

**Goal:** Confirm whether client association locks the entire radio.

---

## Risk Assessment (Pre-Implementation)

Assuming hardware validation confirms `wlan1` can do 5 GHz client mode:

### 1. Interface Selection

**Option A: Runtime picker**  
Let the operator choose `wlan0cli` (2.4 GHz) or `wlan1cli` (5 GHz) per scan.

- **Pros:** Preserves PineAP/Recon on `wlan1` when not scanning 5 GHz
- **Cons:** Adds UI complexity; operator must know band before scanning

**Option B: Automatic band matching**  
Parse Recon context `_RECON_SELECTED_AP_FREQ` / `_RECON_SELECTED_AP_CHANNEL` and select interface automatically.

- **Pros:** Zero new UI; existing band guard logic can drive interface selection
- **Cons:** Still breaks PineAP/Recon on `wlan1` during 5 GHz scans

**Option C: Dual-radio mode**  
Always try both interfaces (2.4 GHz via `wlan0cli`, 5 GHz via `wlan1cli`).

- **Pros:** Covers both bands without operator input
- **Cons:** Most complex; doubles association attempts; likely firmware conflicts

### 2. PineAP Impact

If `wlan1` leaving monitor mode disables:
- Beacon response on 5 GHz channels → **acceptable** (client is off scanning)
- Rogue AP functionality → **moderate** (Pager's signature feature)
- Handshake capture → **severe** (Recon's forensic value)

A payload disrupting core Pineapple functionality may not be acceptable to the user base, even if technically feasible.

### 3. Firmware Coupling

Any solution depends on `WIFI_CONNECT` accepting `wlan1cli`. If firmware hardcodes `wlan0cli`, a code change cannot fix this — it requires a firmware update from Hak5.

### 4. Regression Surface

Changing interface selection affects:
- Architecture contract 10 (CONTRIBUTING.md)
- Recon hidden-SSID/encryption/BSSID flow (tested in v3.3.0)
- Interactive WiFi client mode (Feature 9, user payload line 920+)
- Alert watchdog client targeting (contract 9)

All would require regression testing on hardware.

---

## Explicitly Out of Scope

Per the issue:

> Relaxing or deleting the band guard on `wlan0cli`. That radio will never do 5 GHz, and the current error message is the correct behaviour for it.

The 5 GHz capability check **must remain**. Any fix changes *which radio* carries the client role, not whether the check exists.

---

## Next Steps

1. **Obtain physical Pager** with firmware 1.0.7+ (current release) or 1.0.1+ (earliest validated).
2. **Execute Phase 1-5** validation workflow above.
3. **Document findings** in this file or a new `DOU-92-HARDWARE-RESULTS.md`.
4. **Only then:** design a code change (if feasible) or escalate to Hak5 (if firmware-blocked).

**No code changes should be made until the open questions are answered.**

---

## References

- Linear issue: DOU-92
- Recon payload: `payloads/recon/access_point/clawhunter/payload.sh`
- User payload: `payloads/user/reconnaissance/clawhunter/payload.sh`
- Architecture contracts: `CONTRIBUTING.md` (lines 30-42)
- Release v3.3.0 Recon research: `docs/V3.3-RESEARCH.md` (lines 187, 205)
- Current version: v3.4.0 (main branch)

---

## Appendix: Code Locations

| Artifact | File | Line(s) |
|----------|------|---------|
| `WIFI_IF` declaration (recon) | `payloads/recon/access_point/clawhunter/payload.sh` | 44 |
| `WIFI_IF` declaration (user) | `payloads/user/reconnaissance/clawhunter/payload.sh` | 44 |
| Band guard (recon) | `payloads/recon/access_point/clawhunter/payload.sh` | 173-178 |
| WIFI_CONNECT call (recon) | `payloads/recon/access_point/clawhunter/payload.sh` | 213 |
| DHCP timeout message | `payloads/recon/access_point/clawhunter/payload.sh` | 246 |
| Firmware source location | Both payloads | `. /lib/hak5/commands.sh` |
| Architecture contract 10 | `CONTRIBUTING.md` | 41 |

---

## Testing Considerations

### Current Test Coverage

The repository's test suite (`tests/test_common.sh`, 173 lines) validates:
- Input sanitization (IPv4, port, subnet prefix)
- JSON escaping for loot reports
- Checkpoint path generation and marking
- Classifier fixtures (generic vs. OpenClaw-specific evidence)
- RTTTL vibration contract

**Notable absence:** No tests for `WIFI_CONNECT`, `WIFI_DISCONNECT`, or `WIFI_CLEAR` because these are Hak5 firmware functions unavailable in the host test environment.

### Future Test Requirements

If `wlan1` support is implemented, the following would require **on-device regression testing**:

1. **Recon 5 GHz association** — select a 5 GHz AP, verify correct interface selection, confirm DHCP
2. **Recon 2.4 GHz association** — select a 2.4 GHz AP, verify `wlan0cli` remains the default
3. **Band guard on wrong interface** — attempt to connect `wlan0cli` to 5 GHz, confirm rejection
4. **Hidden SSID + 5 GHz** — test SSID prompt flow with 5 GHz selection
5. **BSSID pinning** — verify `WIFI_CONNECT` fifth argument works with `wlan1cli`
6. **Interactive WiFi mode** — Feature 9 (user payload line 920+) with multi-subnet 5 GHz targets
7. **PineAP/Recon impact** — confirm monitor-mode features degrade predictably during 5 GHz scans

The test gate (`scripts/check.sh`) would need to be updated to:
- Parse `WIFI_IF` declarations if they become dynamic
- Validate band guard logic against both interface capabilities
- Preserve the checkpoint-mark assertion (currently hardcoded to expect 2 call sites in user payload)

**No test infrastructure changes should be made until hardware validation is complete.**

---

**Investigation status:** Awaiting physical hardware access.
