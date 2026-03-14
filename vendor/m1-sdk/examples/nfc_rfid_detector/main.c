/*
 * NFC/RFID Field Detector — M1 App (v2 with diagnostics)
 *
 * Detects whether a nearby card reader is NFC (13.56 MHz) or
 * LF RFID (125 kHz) using firmware-side field detection APIs.
 *
 * Shows diagnostic info on screen to help debug detection issues.
 *
 * Press BACK to exit.
 */

#include "m1app.h"

M1_APP_MANIFEST("Field Detector", 1024);

/* ---- Detection parameters ---- */

#define FIELD_PERSIST_TICKS 5       /* hysteresis: keep indicator for N cycles */
#define POLL_INTERVAL_MS    150     /* detection + draw interval */

/* ---- Display layout (128x64 screen) ---- */

#define TITLE_H       12
#define NFC_ICON_X    8
#define NFC_ICON_Y    18
#define RFID_ICON_X   68
#define RFID_ICON_Y   18
#define ICON_W        50

/* ---- NFC antenna icon (16x16 XBM) ---- */
static const uint8_t icon_nfc[] = {
    0x00, 0x00, 0xFC, 0x3F, 0x04, 0x20, 0xF4, 0x2F,
    0x14, 0x28, 0xD4, 0x2B, 0x54, 0x2A, 0x54, 0x2A,
    0x54, 0x2A, 0x54, 0x2A, 0xD4, 0x2B, 0x14, 0x28,
    0xF4, 0x2F, 0x04, 0x20, 0xFC, 0x3F, 0x00, 0x00,
};

/* ---- RFID coil icon (16x16 XBM) ---- */
static const uint8_t icon_rfid[] = {
    0xC0, 0x03, 0x30, 0x0C, 0xC8, 0x13, 0x24, 0x24,
    0x92, 0x49, 0x52, 0x4A, 0x4A, 0x52, 0x4A, 0x52,
    0x4A, 0x52, 0x4A, 0x52, 0x52, 0x4A, 0x92, 0x49,
    0x24, 0x24, 0xC8, 0x13, 0x30, 0x0C, 0xC0, 0x03,
};

/* ---- State ---- */

static uint8_t nfc_field_weight;
static uint8_t rfid_field_weight;
static uint32_t rfid_freq_hz;
static int init_result;
static int nfc_raw;       /* last nfc detect result */
static int nfc_aux;       /* last AUX_DISPLAY register value */
static int nfc_opctl;     /* last OP_CONTROL register value */
static int rfid_raw;      /* last raw transition count */
static int rfid_detect;   /* last rfid detect result */

/* ---- Draw the UI ---- */

static void draw_detected(u8g2_t *u8g2)
{
    char buf[32];

    /* NFC side (left) */
    if (nfc_field_weight)
    {
        u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
        u8g2_DrawStr(u8g2, NFC_ICON_X + 8, NFC_ICON_Y + 2, "NFC");
        u8g2_DrawXBM(u8g2, NFC_ICON_X + 10, NFC_ICON_Y + 6, 16, 16, icon_nfc);

        u8g2_DrawFrame(u8g2, NFC_ICON_X, NFC_ICON_Y + 26, ICON_W, 6);
        uint8_t fill_w = (uint8_t)((ICON_W - 2) * nfc_field_weight / FIELD_PERSIST_TICKS);
        u8g2_DrawBox(u8g2, NFC_ICON_X + 1, NFC_ICON_Y + 27, fill_w, 4);

        u8g2_SetFont(u8g2, u8g2_font_4x6_tr);
        u8g2_DrawStr(u8g2, NFC_ICON_X + 2, 62, "13.56 MHz");
    }

    /* RFID side (right) */
    if (rfid_field_weight)
    {
        u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
        u8g2_DrawStr(u8g2, RFID_ICON_X + 2, RFID_ICON_Y + 2, "LF RFID");
        u8g2_DrawXBM(u8g2, RFID_ICON_X + 10, RFID_ICON_Y + 6, 16, 16, icon_rfid);

        u8g2_DrawFrame(u8g2, RFID_ICON_X, RFID_ICON_Y + 26, ICON_W, 6);
        uint8_t fill_w = (uint8_t)((ICON_W - 2) * rfid_field_weight / FIELD_PERSIST_TICKS);
        u8g2_DrawBox(u8g2, RFID_ICON_X + 1, RFID_ICON_Y + 27, fill_w, 4);

        u8g2_SetFont(u8g2, u8g2_font_4x6_tr);
        if (rfid_freq_hz > 0)
        {
            snprintf(buf, sizeof(buf), "%lu.%02lu kHz",
                     rfid_freq_hz / 1000,
                     (rfid_freq_hz % 1000) / 10);
            u8g2_DrawStr(u8g2, RFID_ICON_X, 62, buf);
        }
        else
        {
            u8g2_DrawStr(u8g2, RFID_ICON_X, 62, "~125 kHz");
        }
    }

    /* Divider */
    if (nfc_field_weight && rfid_field_weight)
        u8g2_DrawVLine(u8g2, 64, TITLE_H + 2, M1APP_SCREEN_H - TITLE_H - 4);
}

static void draw_screen(u8g2_t *u8g2)
{
    char buf[40];

    /* Title bar */
    u8g2_DrawBox(u8g2, 0, 0, M1APP_SCREEN_W, TITLE_H);
    u8g2_SetDrawColor(u8g2, 0);
    u8g2_SetFont(u8g2, u8g2_font_6x10_tr);
    u8g2_DrawStr(u8g2, 16, 10, "Field Detector");
    u8g2_SetDrawColor(u8g2, 1);

    if (nfc_field_weight || rfid_field_weight)
    {
        draw_detected(u8g2);
    }
    else
    {
        /* No field — show diagnostic info */
        u8g2_SetFont(u8g2, u8g2_font_5x8_tr);

        /* Init status + OP_CONTROL register */
        snprintf(buf, sizeof(buf), "NFC:%s OP:0x%02X",
                 init_result == 0 ? "OK" : "FAIL", (unsigned)nfc_opctl);
        u8g2_DrawStr(u8g2, 2, 24, buf);

        /* NFC AUX_DISPLAY: efd_o and osc_ok bits */
        snprintf(buf, sizeof(buf), "AUX:0x%02X efd:%d osc:%d",
                 (unsigned)nfc_aux, (nfc_aux >> 6) & 1, (nfc_aux >> 4) & 1);
        u8g2_DrawStr(u8g2, 2, 34, buf);

        /* RFID ADC delta from baseline */
        snprintf(buf, sizeof(buf), "RFID delta:%d det:%d", rfid_raw, rfid_detect);
        u8g2_DrawStr(u8g2, 2, 44, buf);

        /* Instructions */
        u8g2_SetFont(u8g2, u8g2_font_4x6_tr);
        u8g2_DrawStr(u8g2, 2, 56, "Hold near reader. BACK=exit");
    }
}

/* ---- App entry point ---- */

int32_t app_main(void *context)
{
    (void)context;

    u8g2_t *u8g2 = m1app_get_u8g2();

    nfc_field_weight = 0;
    rfid_field_weight = 0;
    rfid_freq_hz = 0;
    nfc_raw = 0;
    nfc_aux = 0;
    nfc_opctl = 0;
    rfid_raw = 0;
    rfid_detect = 0;

    /* Initialize field detection hardware */
    init_result = m1_field_detect_start();

    /* Brief buzzer to confirm init */
    m1_buzzer_set(2000, 50);

    while (1)
    {
        /* --- Detect fields --- */
        uint32_t freq = 0;
        nfc_raw = m1_field_detect_nfc();       /* must call first — caches regs */
        nfc_aux = m1_field_detect_nfc_raw();   /* cached AUX_DISPLAY */
        nfc_opctl = m1_field_detect_nfc_opctl(); /* cached OP_CONTROL */
        rfid_detect = m1_field_detect_rfid(&freq);
        rfid_raw = m1_field_detect_rfid_raw();

        /* Update hysteresis counters */
        if (rfid_detect)
        {
            rfid_field_weight = FIELD_PERSIST_TICKS;
            rfid_freq_hz = freq;
        }
        else if (rfid_field_weight > 0)
        {
            rfid_field_weight--;
        }

        if (nfc_raw)
        {
            nfc_field_weight = FIELD_PERSIST_TICKS;
        }
        else if (nfc_field_weight > 0)
        {
            nfc_field_weight--;
        }

        /* --- LED feedback --- */
        if (nfc_raw || rfid_detect)
        {
            uint8_t g = 0, b = 0;
            if (nfc_raw)
                b = 80;
            if (rfid_detect)
                g = 80;
            lp5814_led_on_Red(0);
            lp5814_led_on_Green(g);
            lp5814_led_on_Blue(b);
        }
        else if (!nfc_field_weight && !rfid_field_weight)
        {
            lp5814_all_off_RGB();
        }

        /* --- Draw --- */
        m1app_display_begin();
        do {
            u8g2_SetDrawColor(u8g2, 1);
            draw_screen(u8g2);
        } while (m1app_display_flush());

        /* --- Input --- */
        m1app_button_t btn = game_poll_button(POLL_INTERVAL_MS);
        if (btn == M1APP_BTN_BACK)
            break;
    }

    /* Cleanup */
    lp5814_all_off_RGB();
    m1_field_detect_stop();

    return 0;
}
