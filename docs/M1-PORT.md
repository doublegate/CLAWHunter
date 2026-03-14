# CLAWHunter M1 Port — Technical Reference

## Overview

CLAWHunter v4.0.0-m1 is a native C port of the Hak5 WiFi Pineapple Pager v3.2.0 Bash/Python payload suite, compiled directly into the [Monstatek M1](https://github.com/Monstatek/M1) firmware. It runs on the STM32H573 (Cortex-M33) MCU with WiFi networking provided by the ESP32 co-processor over SPI.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  STM32H573 (Cortex-M33, FreeRTOS)                   │
│                                                      │
│  m1_clawhunter.c                                     │
│  ├── clawhunter_recon()  — Auto-scan subnet          │
│  ├── clawhunter_user()   — Interactive + profiles     │
│  └── clawhunter_alert()  — Single-host quick probe    │
│         │                                            │
│         ▼                                            │
│  probe_host() → tcp_connect_probe()                  │
│         │                                            │
│         ▼  (SPI AT commands)                         │
│  esp_app_main.c                                      │
│  ├── AT+CIPSTART="TCP","<ip>",<port>                 │
│  ├── AT+CIPSEND → HTTP GET / HTTP/1.0                │
│  ├── +IPD,<len>:<banner>  → signature check          │
│  └── AT+CIPCLOSE                                     │
├──────────────────────────────────────────────────────┤
│  ESP32 Co-processor (LwIP, WiFi, BLE)        [SPI]   │
└─────────────────────────────────────────────────────┘
```

## Hardware Differences vs. Pineapple Pager

| Feature | Pineapple Pager | Monstatek M1 |
|---------|----------------|-------------|
| Display | 480×222 px, 16-bit color | 128×64 px, monochrome OLED (u8g2) |
| Input | 5 buttons + DuckyScript | 6-button D-pad (UP/DOWN/LEFT/RIGHT/OK/BACK) |
| CPU | MIPS (OpenWRT Linux) | STM32H573 Cortex-M33 (FreeRTOS) |
| WiFi | Native Linux stack | ESP32 co-processor via SPI AT commands |
| Language | Bash + Python3 | C (compiled into firmware .bin) |
| Storage | eMMC + microSD | FatFs on microSD |
| Audio | RTTTL ringtones | Piezo buzzer (m1_buzzer_set) |
| LED | RGB array (4 LEDs) | LP5814 RGB LED controller |

## Payload Modes

### Recon
Auto-derives subnet from the connected WiFi AP (via `wifi_get_ip()` AT command), sweeps .1-.254 on port 18790 with a live progress bar, buzzer feedback on discovery, and a scrollable results list.

### User (Interactive)
Full scan profile picker using D-pad navigation:
- **GHOST** — Passive ARP cache only, no port probes
- **QUIET** — 500ms inter-probe delay, covert
- **NORMAL** — 100ms delay, balanced (default)
- **FAST** — 20ms delay, reduced latency
- **AGGRESSIVE** — No delay, maximum speed

After profile selection: WiFi connectivity check → subnet scan → results browser with scroll → rescan loop (OK to rescan, BACK to exit).

### Alert
Silent single-host quick probe of the gateway (.1). Instant result display. No buzzer (silent mode). Press BACK to exit.

## TCP Probe Pipeline

The probe pipeline mirrors the Pineapple Pager's fingerprinting stages but runs natively in C:

1. **tcp_connect_probe()** sends `AT+CIPSTART="TCP","<ip>",<port>` to the ESP32
2. If TCP connection succeeds → sends `AT+CIPSEND` with `GET / HTTP/1.0\r\nHost: openclaw\r\n\r\n`
3. Reads `+IPD,<len>:<data>` response → extracts up to 64 bytes of banner
4. Sends `AT+CIPCLOSE` to tear down
5. **probe_host()** checks banner for `openclaw`, `OpenClaw`, or `clawd` signatures
6. Result: **confirmed** (signature match) or **candidate** (open port, no signature) or **not found** (refused/timeout)

## Protocol Extension

The ESP32 SPI AT command protocol was extended with:

| Addition | Location |
|----------|----------|
| `CTRL_MSG_ID__Req_TCPConnect = 132` | `ctrl_api.h` enum |
| `CTRL_REQ_TCP_CONNECT` | `ctrl_api.h` enum alias |
| `tcp_connect_t` struct | `ctrl_api.h` (IP, port, timeout, result, 64-byte banner) |
| `tcp_connect` field | `ctrl_cmd_t` union |
| `tcp_connect_probe()` | `esp_app_main.c` (full AT+CIPSTART handler) |
| `ESP32C6_AT_REQ_CIPSTART` et al. | `esp_at_list.h` |

## UI Layout (128×64 OLED)

```
┌────────────────────────────────┐
│▓▓▓▓ CLAWHunter Scan ▓▓▓▓▓▓▓▓▓│  ← Inverted title bar
│ 192.168.1.42                   │  ← Current target
│ Port: 18790                    │  ← Scan port
│ Found: 2  [B]=stop             │  ← Status + hint
│ ┌────────────────────────┐     │
│ │████████░░░░░░░░░│ 45%  │     │  ← Progress bar
│ └────────────────────────┘     │
└────────────────────────────────┘
```

## Building

### Prerequisites
```bash
sudo pacman -S arm-none-eabi-gcc arm-none-eabi-newlib cmake ninja
```

### Build
```bash
cd vendor/M1
bash build.sh
```

### Output
```
vendor/M1/artifacts/M1_v0800_C3.1.elf       ← ELF (for debugging)
vendor/M1/artifacts/M1_v0800_C3.1.bin       ← Raw binary
vendor/M1/artifacts/M1_v0800_C3.1_wCRC.bin  ← CRC-stamped binary (flash this)
vendor/M1/artifacts/M1_v0800_C3.1.hex       ← Intel HEX
```

### Flashing
Flash `M1_v0800_C3.1_wCRC.bin` via:
- **USB DFU** (STM32CubeProgrammer)
- **J-Link** (`scripts/program.jlink`)
- **SD card update** (copy to SD root as firmware update file)

## Memory Footprint

```
   text      data     bss      total
   655,968   10,524   251,544  918,036  (49.9% of 1MB flash)
```

## File Manifest

| File | Description |
|------|-------------|
| `m1_csrc/m1_clawhunter.c` | Main CLAWHunter module (UI, scan logic, probe dispatch) |
| `m1_csrc/m1_clawhunter.h` | Public API, types, constants |
| `Esp_spi_at/.../esp_app_main.c` | TCP connect probe handler (`tcp_connect_probe()`) |
| `Esp_spi_at/.../esp_app_main.h` | Function declaration |
| `Esp_spi_at/.../ctrl_api.h` | Protocol extension (TCP connect struct + enum) |
| `Esp_spi_at/.../esp_at_list.h` | AT command string defines |
| `cmake/m1_01/CMakeLists.txt` | Build system (CLAWHunter source added) |

## Version Mapping

| M1 Branch | Pineapple Pager |
|-----------|-----------------|
| v4.0.0-m1 | v3.2.0 |

All three payload modes (recon, user, alert) are functionally equivalent to their Bash counterparts, adapted for the M1's hardware constraints (monochrome display, D-pad input, FreeRTOS threading, ESP32 AT command networking).
