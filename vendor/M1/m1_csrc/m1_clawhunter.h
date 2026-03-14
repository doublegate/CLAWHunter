/* See COPYING.txt for license details. */

/*
 * m1_clawhunter.h
 *
 * CLAWHunter — OpenClaw Gateway Discovery Tool
 * Native M1 firmware integration (ported from Hak5 WiFi Pineapple Pager v3.2.0)
 *
 * Three payload modes:
 *   - Recon:  Auto-scan connected AP subnet for OpenClaw instances
 *   - User:   Interactive scan with profile selection and watchdog
 *   - Alert:  Single-host probe triggered from menu (silent, fast)
 *
 * Author: doublegate
 * Port:   Undertow (M1 branch)
 */

#ifndef M1_CLAWHUNTER_H
#define M1_CLAWHUNTER_H

#include <stdint.h>
#include <stdbool.h>

/* ── Version ─────────────────────────────────────────────────────────────── */
#define CLAWHUNTER_VERSION          "4.0.0-m1"
#define CLAWHUNTER_PAGER_VERSION    "3.2.0"

/* ── OpenClaw default ports ──────────────────────────────────────────────── */
#define OPENCLAW_DEFAULT_PORT       18790
#define OPENCLAW_RANGE_LOW          18780
#define OPENCLAW_RANGE_HIGH         18800

/* ── Scan profiles ───────────────────────────────────────────────────────── */
typedef enum {
    SCAN_PROFILE_GHOST      = 0,   /* Passive only — ARP cache, no probes    */
    SCAN_PROFILE_QUIET      = 1,   /* Slow sequential, covert                */
    SCAN_PROFILE_NORMAL     = 2,   /* Default balanced                       */
    SCAN_PROFILE_FAST       = 3,   /* Reduced delays                         */
    SCAN_PROFILE_AGGRESSIVE = 4,   /* All ports, no delays                   */
    SCAN_PROFILE_COUNT      = 5
} clawhunter_scan_profile_t;

/* ── Discovery result ────────────────────────────────────────────────────── */
#define CLAWHUNTER_MAX_FOUND        16
#define CLAWHUNTER_BANNER_LEN       48

typedef struct {
    uint8_t  ip[4];
    uint16_t port;
    bool     confirmed;             /* true = confirmed OpenClaw, false = candidate */
    char     banner[CLAWHUNTER_BANNER_LEN];
} clawhunter_result_t;

/* ── Menu entry points (called from m1_menu.c) ───────────────────────────── */
void menu_clawhunter_init(void);
void clawhunter_recon(void);
void clawhunter_user(void);
void clawhunter_alert(void);

#endif /* M1_CLAWHUNTER_H */
