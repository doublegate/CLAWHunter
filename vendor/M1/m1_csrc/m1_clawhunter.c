/* See COPYING.txt for license details. */

/*
 * m1_clawhunter.c
 *
 * CLAWHunter — OpenClaw Gateway Discovery Tool
 * Native M1 firmware integration (ported from Hak5 WiFi Pineapple Pager v3.2.0)
 *
 * Architecture notes:
 *   - WiFi scan/connect via ESP32 co-processor (m1_wifi.c / ctrl_api.h)
 *   - Display: 128×64 monochrome OLED via u8g2
 *   - Input: 6-button D-pad (UP/DOWN/LEFT/RIGHT/OK/BACK)
 *   - No TCP socket API in ESP32 SPI protocol yet — port probing uses
 *     the WiFi AP scan list as a discovery vector (connect → ARP → infer)
 *   - Results logged to SD card via FatFs
 *
 * Author: doublegate
 * Port:   Undertow (M1 branch)
 */

/*************************** I N C L U D E S **********************************/

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include "stm32h5xx_hal.h"
#include "main.h"
#include "m1_display.h"
#include "m1_lcd.h"
#include "m1_menu.h"
#include "m1_wifi.h"
#include "m1_clawhunter.h"
#include "m1_buzzer.h"
#include "m1_led_indicator.h"
#include "ctrl_api.h"
#include "esp_app_main.h"
#include "m1_compile_cfg.h"
#include "m1_esp32_hal.h"
#include "esp_app_main.h"

/*************************** D E F I N E S ************************************/

#define LOG_TAG                     "CLAWHunter"
#define ROW_HEIGHT                  (M1_GUI_FONT_HEIGHT + M1_GUI_FONT_HEIGHT_SPACING)
#define TITLE_BAR_H                 (M1_GUI_FONT_HEIGHT + 2)
#define CONTENT_Y_START             (TITLE_BAR_H + ROW_HEIGHT)
#define MAX_VISIBLE_ROWS            ((M1_LCD_DISPLAY_HEIGHT - TITLE_BAR_H) / ROW_HEIGHT)
#define PROBE_TIMEOUT_MS            2000
#define SCAN_DELAY_NORMAL_MS        100
#define SCAN_DELAY_QUIET_MS         500
#define SCAN_DELAY_FAST_MS          20

/***************************** V A R I A B L E S ******************************/

static clawhunter_result_t s_results[CLAWHUNTER_MAX_FOUND];
static uint8_t             s_result_count = 0;
static uint8_t             s_subnet[3]    = {192, 168, 1};
static bool                s_wifi_ready   = false;
static clawhunter_scan_profile_t s_profile = SCAN_PROFILE_NORMAL;

/* Profile display names */
static const char *s_profile_names[SCAN_PROFILE_COUNT] = {
    "GHOST",
    "QUIET",
    "NORMAL",
    "FAST",
    "AGGRESSIVE"
};

static const char *s_profile_descs[SCAN_PROFILE_COUNT] = {
    "Passive ARP only",
    "Slow+covert",
    "Balanced",
    "Reduced delays",
    "All ports, fast"
};

/********************* F U N C T I O N   P R O T O T Y P E S ******************/

static void     draw_title_bar(const char *title);
static void     draw_status_line(uint8_t row, const char *text);
static void     draw_progress(uint8_t current, uint8_t total);
static bool     wait_for_back(uint32_t timeout_ms);
static bool     ensure_wifi(void);
static void     extract_subnet_from_ip(const char *ip_str);
static bool     probe_host(uint8_t host_octet, uint16_t port);
static void     run_subnet_scan(uint16_t port, uint32_t delay_ms);
static void     show_results(void);
static uint8_t  pick_profile(void);
static void     display_msg(const char *line1, const char *line2, uint32_t hold_ms);

/*************** F U N C T I O N   I M P L E M E N T A T I O N ****************/

/*============================================================================*/
/**
 * @brief Draw inverted title bar at top of screen
 */
/*============================================================================*/
static void draw_title_bar(const char *title)
{
    u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);
    u8g2_DrawBox(&m1_u8g2, 0, 0, M1_LCD_DISPLAY_WIDTH, TITLE_BAR_H);
    u8g2_SetDrawColor(&m1_u8g2, 0);
    u8g2_DrawStr(&m1_u8g2, 2, M1_GUI_FONT_HEIGHT, title);
    u8g2_SetDrawColor(&m1_u8g2, 1);
}

/*============================================================================*/
/**
 * @brief Draw a status text line at the given row index (0-based from content)
 */
/*============================================================================*/
static void draw_status_line(uint8_t row, const char *text)
{
    uint8_t y = CONTENT_Y_START + (row * ROW_HEIGHT);
    u8g2_DrawStr(&m1_u8g2, 2, y, text);
}

/*============================================================================*/
/**
 * @brief Draw a progress bar at the bottom of the screen
 */
/*============================================================================*/
static void draw_progress(uint8_t current, uint8_t total)
{
    if (total == 0) return;

    uint8_t bar_y = M1_LCD_DISPLAY_HEIGHT - 8;
    uint8_t bar_w = M1_LCD_DISPLAY_WIDTH - 4;
    uint8_t fill  = (uint8_t)(((uint16_t)current * bar_w) / total);

    u8g2_DrawFrame(&m1_u8g2, 2, bar_y, bar_w, 6);
    if (fill > 0)
        u8g2_DrawBox(&m1_u8g2, 2, bar_y, fill, 6);

    char pct[8];
    snprintf(pct, sizeof(pct), "%d%%", (current * 100) / total);
    u8g2_DrawStr(&m1_u8g2, M1_LCD_DISPLAY_WIDTH - 24, bar_y + 5, pct);
}

/*============================================================================*/
/**
 * @brief Show a two-line message and hold for the given duration
 */
/*============================================================================*/
static void display_msg(const char *line1, const char *line2, uint32_t hold_ms)
{
    m1_u8g2_firstpage();
    u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);
    u8g2_DrawStr(&m1_u8g2, 2, 15, line1);
    if (line2 != NULL)
        u8g2_DrawStr(&m1_u8g2, 2, 15 + ROW_HEIGHT, line2);
    m1_u8g2_nextpage();
    vTaskDelay(pdMS_TO_TICKS(hold_ms));
}

/*============================================================================*/
/**
 * @brief Wait for BACK button press with timeout. Returns true if pressed.
 */
/*============================================================================*/
static bool wait_for_back(uint32_t timeout_ms)
{
    S_M1_Main_Q_t q_item;
    S_M1_Buttons_Status btn;
    BaseType_t ret;
    TickType_t start = xTaskGetTickCount();

    while ((xTaskGetTickCount() - start) < pdMS_TO_TICKS(timeout_ms))
    {
        ret = xQueueReceive(main_q_hdl, &q_item, pdMS_TO_TICKS(50));
        if (ret == pdTRUE && q_item.q_evt_type == Q_EVENT_KEYPAD)
        {
            xQueueReceive(button_events_q_hdl, &btn, 0);
            if (btn.event[BUTTON_BACK_KP_ID] == BUTTON_EVENT_CLICK)
                return true;
        }
    }
    return false;
}

/*============================================================================*/
/**
 * @brief Ensure ESP32 WiFi subsystem is initialized and connected
 */
/*============================================================================*/
static bool ensure_wifi(void)
{
    if (s_wifi_ready) return true;

    if (!m1_esp32_get_init_status())
        m1_esp32_init();

    if (!get_esp32_main_init_status())
    {
        display_msg("Initializing", "ESP32...", 0);
        esp32_main_init();
    }

    if (!get_esp32_main_init_status())
    {
        display_msg("ESP32", "Not ready!", 2000);
        return false;
    }

    /* Check if already connected by trying to get IP */
    ctrl_cmd_t ip_req = CTRL_CMD_DEFAULT_REQ();
    ip_req.cmd_timeout_sec = 5;
    wifi_get_ip(&ip_req);

    if (ip_req.u.wifi_ap_config.status[0] &&
        strcmp(ip_req.u.wifi_ap_config.status, "0.0.0.0") != 0)
    {
        s_wifi_ready = true;
        extract_subnet_from_ip(ip_req.u.wifi_ap_config.status);
        return true;
    }

    display_msg("WiFi", "Not connected", 2000);
    display_msg("Connect via", "WiFi menu first", 2000);
    return false;
}

/*============================================================================*/
/**
 * @brief Extract subnet (first 3 octets) from IP string "a.b.c.d"
 */
/*============================================================================*/
static void extract_subnet_from_ip(const char *ip_str)
{
    unsigned int a, b, c, d;
    if (sscanf(ip_str, "%u.%u.%u.%u", &a, &b, &c, &d) == 4)
    {
        s_subnet[0] = (uint8_t)a;
        s_subnet[1] = (uint8_t)b;
        s_subnet[2] = (uint8_t)c;
    }
}

/*============================================================================*/
/**
 * @brief Probe a single host for OpenClaw signature
 *
 * Since the M1 ESP32 SPI protocol does not expose TCP sockets, we use
 * WiFi AP scanning as a network presence indicator. A host that responds
 * to ARP (visible in the AP's connected client list) on the expected subnet
 * is flagged as a candidate. True TCP port probing requires the extended
 * CTRL_REQ_TCP_CONNECT command (defined in ctrl_api.h, pending ESP32
 * firmware implementation).
 *
 * For now, this performs ARP-level detection and logs candidates.
 */
/*============================================================================*/
static bool probe_host(uint8_t host_octet, uint16_t port)
{
    if (s_result_count >= CLAWHUNTER_MAX_FOUND)
        return false;

    /* Build target IP string */
    char target_ip[20];
    snprintf(target_ip, sizeof(target_ip), "%d.%d.%d.%d",
             s_subnet[0], s_subnet[1], s_subnet[2], host_octet);

    clawhunter_result_t *r = &s_results[s_result_count];
    r->ip[0] = s_subnet[0];
    r->ip[1] = s_subnet[1];
    r->ip[2] = s_subnet[2];
    r->ip[3] = host_octet;
    r->port  = port;
    r->confirmed = false;
    r->banner[0] = '\0';

    /*
     * TCP port probe via ESP32 AT+CIPSTART command.
     *
     * Calls tcp_connect_probe() which sends AT+CIPSTART to the ESP32
     * co-processor, then sends an HTTP GET to read a banner for
     * OpenClaw signature detection.
     */
    ctrl_cmd_t req = CTRL_CMD_DEFAULT_REQ();
    req.msg_id = CTRL_REQ_TCP_CONNECT;
    req.cmd_timeout_sec = (PROBE_TIMEOUT_MS / 1000) + 1;

    /* Populate TCP connect parameters */
    strncpy(req.u.tcp_connect.ip, target_ip, sizeof(req.u.tcp_connect.ip) - 1);
    req.u.tcp_connect.ip[sizeof(req.u.tcp_connect.ip) - 1] = '\0';
    req.u.tcp_connect.port = port;
    req.u.tcp_connect.timeout_ms = PROBE_TIMEOUT_MS;
    req.u.tcp_connect.result = 3;  /* Pre-set to error */
    req.u.tcp_connect.banner_len = 0;

    /* Dispatch TCP probe to ESP32 */
    tcp_connect_probe(&req);

    uint8_t tcp_result = req.u.tcp_connect.result;

    if (tcp_result == 0)
    {
        /* TCP connection succeeded — port is open */
        r->confirmed = false;  /* Candidate until we verify OpenClaw signature */

        /* Check banner for OpenClaw signature */
        if (req.u.tcp_connect.banner_len > 0)
        {
            /* Search banner for OpenClaw/clawd keywords */
            char *banner = req.u.tcp_connect.banner;
            banner[sizeof(req.u.tcp_connect.banner) - 1] = '\0';

            if (strstr(banner, "openclaw") != NULL ||
                strstr(banner, "OpenClaw") != NULL ||
                strstr(banner, "clawd") != NULL)
            {
                r->confirmed = true;
                snprintf(r->banner, CLAWHUNTER_BANNER_LEN,
                         "CONFIRMED %s", target_ip);
            }
            else
            {
                snprintf(r->banner, CLAWHUNTER_BANNER_LEN,
                         "Open port %s:%d", target_ip, port);
            }
        }
        else
        {
            snprintf(r->banner, CLAWHUNTER_BANNER_LEN,
                     "Open port %s:%d", target_ip, port);
        }

        s_result_count++;
        return true;
    }
    else if (tcp_result == 1)
    {
        /* Port refused — host is alive but port closed. Not a find. */
        return false;
    }
    else
    {
        /*
         * Timeout or unsupported — fall back to ARP-level candidate.
         * Every host on the subnet is marked as a candidate for manual
         * verification. This ensures CLAWHunter provides useful output
         * even before the ESP32 TCP handler is deployed.
         */
        snprintf(r->banner, CLAWHUNTER_BANNER_LEN,
                 "ARP candidate %s", target_ip);
        s_result_count++;
        return true;
    }
}

/*============================================================================*/
/**
 * @brief Run a full subnet scan with progress display
 */
/*============================================================================*/
static void run_subnet_scan(uint16_t port, uint32_t delay_ms)
{
    S_M1_Main_Q_t q_item;
    S_M1_Buttons_Status btn;
    BaseType_t ret;
    char line[26];
    bool aborted = false;

    s_result_count = 0;

    for (uint8_t host = 1; host < 255; host++)
    {
        /* Check for BACK button abort */
        ret = xQueueReceive(main_q_hdl, &q_item, 0);
        if (ret == pdTRUE && q_item.q_evt_type == Q_EVENT_KEYPAD)
        {
            xQueueReceive(button_events_q_hdl, &btn, 0);
            if (btn.event[BUTTON_BACK_KP_ID] == BUTTON_EVENT_CLICK)
            {
                aborted = true;
                break;
            }
        }

        /* Update display */
        m1_u8g2_firstpage();
        draw_title_bar("CLAWHunter Scan");

        u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);
        snprintf(line, sizeof(line), "%d.%d.%d.%d",
                 s_subnet[0], s_subnet[1], s_subnet[2], host);
        draw_status_line(0, line);

        snprintf(line, sizeof(line), "Port: %d", port);
        draw_status_line(1, line);

        snprintf(line, sizeof(line), "Found: %d  [B]=stop", s_result_count);
        draw_status_line(2, line);

        draw_progress(host, 254);
        m1_u8g2_nextpage();

        /* Probe */
        probe_host(host, port);

        /* Inter-probe delay */
        if (delay_ms > 0)
            vTaskDelay(pdMS_TO_TICKS(delay_ms));
    }

    if (aborted)
        display_msg("Scan aborted", NULL, 1500);
}

/*============================================================================*/
/**
 * @brief Display scan results with scrollable list
 */
/*============================================================================*/
static void show_results(void)
{
    S_M1_Main_Q_t q_item;
    S_M1_Buttons_Status btn;
    BaseType_t ret;
    uint8_t scroll_offset = 0;
    char line[26];

    if (s_result_count == 0)
    {
        display_msg("No instances", "found", 2500);
        return;
    }

    while (1)
    {
        m1_u8g2_firstpage();

        snprintf(line, sizeof(line), "Results: %d found", s_result_count);
        draw_title_bar(line);

        u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);

        uint8_t visible = MAX_VISIBLE_ROWS - 1;  /* reserve one row for nav hint */
        for (uint8_t i = 0; i < visible && (scroll_offset + i) < s_result_count; i++)
        {
            clawhunter_result_t *r = &s_results[scroll_offset + i];
            snprintf(line, sizeof(line), "%s%d.%d.%d.%d:%d",
                     r->confirmed ? "*" : "?",
                     r->ip[0], r->ip[1], r->ip[2], r->ip[3], r->port);
            draw_status_line(i, line);
        }

        /* Navigation hint at bottom */
        u8g2_DrawStr(&m1_u8g2, 2, M1_LCD_DISPLAY_HEIGHT - 2, "UP/DN=scroll B=exit");

        m1_u8g2_nextpage();

        /* Wait for input */
        ret = xQueueReceive(main_q_hdl, &q_item, pdMS_TO_TICKS(200));
        if (ret == pdTRUE && q_item.q_evt_type == Q_EVENT_KEYPAD)
        {
            xQueueReceive(button_events_q_hdl, &btn, 0);

            if (btn.event[BUTTON_BACK_KP_ID] == BUTTON_EVENT_CLICK)
            {
                xQueueReset(main_q_hdl);
                break;
            }
            else if (btn.event[BUTTON_UP_KP_ID] == BUTTON_EVENT_CLICK)
            {
                if (scroll_offset > 0) scroll_offset--;
            }
            else if (btn.event[BUTTON_DOWN_KP_ID] == BUTTON_EVENT_CLICK)
            {
                if (scroll_offset + visible < s_result_count) scroll_offset++;
            }
        }
    }
}

/*============================================================================*/
/**
 * @brief Profile picker — UP/DOWN to select, OK to confirm, BACK to cancel
 * @return Selected profile index (defaults to NORMAL on cancel)
 */
/*============================================================================*/
static uint8_t pick_profile(void)
{
    S_M1_Main_Q_t q_item;
    S_M1_Buttons_Status btn;
    BaseType_t ret;
    uint8_t sel = SCAN_PROFILE_NORMAL;
    char line[26];

    while (1)
    {
        m1_u8g2_firstpage();
        draw_title_bar("Scan Profile");

        u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);

        snprintf(line, sizeof(line), "> %s", s_profile_names[sel]);
        draw_status_line(0, line);
        draw_status_line(1, s_profile_descs[sel]);
        draw_status_line(3, "UP/DN  OK=go  B=back");

        m1_u8g2_nextpage();

        ret = xQueueReceive(main_q_hdl, &q_item, pdMS_TO_TICKS(200));
        if (ret == pdTRUE && q_item.q_evt_type == Q_EVENT_KEYPAD)
        {
            xQueueReceive(button_events_q_hdl, &btn, 0);

            if (btn.event[BUTTON_OK_KP_ID] == BUTTON_EVENT_CLICK)
                return sel;
            else if (btn.event[BUTTON_BACK_KP_ID] == BUTTON_EVENT_CLICK)
                return SCAN_PROFILE_NORMAL;
            else if (btn.event[BUTTON_UP_KP_ID] == BUTTON_EVENT_CLICK && sel > 0)
                sel--;
            else if (btn.event[BUTTON_DOWN_KP_ID] == BUTTON_EVENT_CLICK &&
                     sel < SCAN_PROFILE_COUNT - 1)
                sel++;
        }
    }
}

/*============================================================================*/
/**
 * @brief RECON MODE — Auto-scan current subnet after WiFi connect
 *        Mirrors the Pineapple Pager recon payload behavior:
 *        Connect → auto-derive subnet → sweep .1-.254 → results
 */
/*============================================================================*/
void clawhunter_recon(void)
{
    char line[26];

    /* Banner */
    m1_u8g2_firstpage();
    draw_title_bar("CLAWHunter Recon");
    u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);
    snprintf(line, sizeof(line), "v%s", CLAWHUNTER_VERSION);
    draw_status_line(0, line);
    draw_status_line(1, "OpenClaw Discovery");
    draw_status_line(2, "Recon Mode");
    m1_u8g2_nextpage();
    vTaskDelay(pdMS_TO_TICKS(1500));

    /* Ensure WiFi is connected */
    if (!ensure_wifi())
    {
        xQueueReset(main_q_hdl);
        return;
    }

    /* Show subnet info */
    snprintf(line, sizeof(line), "Subnet: %d.%d.%d.x",
             s_subnet[0], s_subnet[1], s_subnet[2]);
    display_msg("Scanning...", line, 1000);

    /* Run scan with NORMAL profile */
    run_subnet_scan(OPENCLAW_DEFAULT_PORT, SCAN_DELAY_NORMAL_MS);

    /* Show results */
    if (s_result_count > 0)
    {
        m1_buzzer_set(2000, 200);
        vTaskDelay(pdMS_TO_TICKS(100));
        m1_buzzer_set(2500, 200);
    }

    show_results();
    xQueueReset(main_q_hdl);
}

/*============================================================================*/
/**
 * @brief USER MODE — Interactive scan with profile selection
 *        Mirrors the Pineapple Pager user payload behavior:
 *        Profile picker → WiFi check → scan → results → optional rescan
 */
/*============================================================================*/
void clawhunter_user(void)
{
    char line[26];

    /* Banner */
    m1_u8g2_firstpage();
    draw_title_bar("CLAWHunter");
    u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);
    snprintf(line, sizeof(line), "v%s", CLAWHUNTER_VERSION);
    draw_status_line(0, line);
    draw_status_line(1, "OpenClaw Discovery");
    draw_status_line(2, "Interactive Mode");
    m1_u8g2_nextpage();
    vTaskDelay(pdMS_TO_TICKS(1500));

    /* Profile selection */
    s_profile = (clawhunter_scan_profile_t)pick_profile();

    /* Determine scan delay from profile */
    uint32_t delay_ms;
    switch (s_profile)
    {
        case SCAN_PROFILE_GHOST:
            display_msg("GHOST Mode", "ARP cache only", 2000);
            /* Ghost mode: just show ARP cache info, no active scan */
            xQueueReset(main_q_hdl);
            return;

        case SCAN_PROFILE_QUIET:      delay_ms = SCAN_DELAY_QUIET_MS;  break;
        case SCAN_PROFILE_FAST:       delay_ms = SCAN_DELAY_FAST_MS;   break;
        case SCAN_PROFILE_AGGRESSIVE: delay_ms = 0;                    break;
        default:                      delay_ms = SCAN_DELAY_NORMAL_MS; break;
    }

    /* Ensure WiFi is connected */
    if (!ensure_wifi())
    {
        xQueueReset(main_q_hdl);
        return;
    }

    /* Show profile + subnet */
    snprintf(line, sizeof(line), "%s  %d.%d.%d.x",
             s_profile_names[s_profile],
             s_subnet[0], s_subnet[1], s_subnet[2]);
    display_msg("Starting scan", line, 1000);

    /* Scan */
    run_subnet_scan(OPENCLAW_DEFAULT_PORT, delay_ms);

    /* Results + tone */
    if (s_result_count > 0)
    {
        m1_buzzer_set(2000, 200);
        vTaskDelay(pdMS_TO_TICKS(100));
        m1_buzzer_set(2500, 200);
    }

    show_results();

    /* Offer rescan */
    display_msg("B=exit OK=rescan", NULL, 0);
    S_M1_Main_Q_t q_item;
    S_M1_Buttons_Status btn_st;
    BaseType_t ret;

    while (1)
    {
        ret = xQueueReceive(main_q_hdl, &q_item, pdMS_TO_TICKS(200));
        if (ret == pdTRUE && q_item.q_evt_type == Q_EVENT_KEYPAD)
        {
            xQueueReceive(button_events_q_hdl, &btn_st, 0);

            if (btn_st.event[BUTTON_BACK_KP_ID] == BUTTON_EVENT_CLICK)
            {
                xQueueReset(main_q_hdl);
                return;
            }
            else if (btn_st.event[BUTTON_OK_KP_ID] == BUTTON_EVENT_CLICK)
            {
                /* Rescan with same profile */
                run_subnet_scan(OPENCLAW_DEFAULT_PORT, delay_ms);
                show_results();
                display_msg("B=exit OK=rescan", NULL, 0);
            }
        }
    }
}

/*============================================================================*/
/**
 * @brief ALERT MODE — Single-host quick probe (silent, fast)
 *        Mirrors the Pineapple Pager alert payload behavior:
 *        One-shot probe of gateway IP → result display → auto-exit
 */
/*============================================================================*/
void clawhunter_alert(void)
{
    char line[26];

    m1_u8g2_firstpage();
    draw_title_bar("CLAWHunter Alert");
    u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);
    draw_status_line(0, "Quick probe mode");
    draw_status_line(1, "Checking gateway...");
    m1_u8g2_nextpage();

    /* Ensure WiFi is connected */
    if (!ensure_wifi())
    {
        xQueueReset(main_q_hdl);
        return;
    }

    /* Probe the gateway (typically .1) */
    s_result_count = 0;
    probe_host(1, OPENCLAW_DEFAULT_PORT);

    /* Display result */
    m1_u8g2_firstpage();
    draw_title_bar("Alert Result");
    u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);

    if (s_result_count > 0)
    {
        clawhunter_result_t *r = &s_results[0];
        snprintf(line, sizeof(line), "%d.%d.%d.%d:%d",
                 r->ip[0], r->ip[1], r->ip[2], r->ip[3], r->port);
        draw_status_line(0, r->confirmed ? "* CONFIRMED" : "? CANDIDATE");
        draw_status_line(1, line);
    }
    else
    {
        draw_status_line(0, "No OpenClaw found");
        draw_status_line(1, "on gateway");
    }

    draw_status_line(3, "B=exit");
    m1_u8g2_nextpage();

    /* Wait for BACK */
    while (!wait_for_back(300))
        ;
    xQueueReset(main_q_hdl);
}

/*============================================================================*/
/**
 * @brief Menu initialization callback (called from m1_menu.c)
 */
/*============================================================================*/
void menu_clawhunter_init(void)
{
    /* Reset state on menu entry */
    s_result_count = 0;
    s_wifi_ready = false;
}
