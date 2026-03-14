/*
 * Hello World — Minimal M1 app example
 *
 * Displays "Hello from M1!" on screen, waits for BACK button to exit.
 */

#include "m1app.h"

/* App manifest — the loader reads this to get the app name and stack size */
M1_APP_MANIFEST("Hello World", 512);

int32_t app_main(void *context)
{
    (void)context;

    u8g2_t *u8g2 = m1app_get_u8g2();

    while (1)
    {
        m1app_display_begin();
        do {
            u8g2_SetFont(u8g2, u8g2_font_6x10_tr);
            u8g2_SetDrawColor(u8g2, 1);

            /* Title bar */
            u8g2_DrawBox(u8g2, 0, 0, 128, 12);
            u8g2_SetDrawColor(u8g2, 0);
            u8g2_DrawStr(u8g2, 20, 10, "Hello World");
            u8g2_SetDrawColor(u8g2, 1);

            /* Body text */
            u8g2_DrawStr(u8g2, 10, 30, "Hello from M1!");
            u8g2_DrawStr(u8g2, 10, 44, "Press BACK to exit");

            /* Decorative frame */
            u8g2_DrawFrame(u8g2, 4, 18, 120, 42);

        } while (m1app_display_flush());

        /* Wait for button press */
        m1app_button_t btn = game_poll_button(100);
        if (btn == M1APP_BTN_BACK)
        {
            break;
        }
    }

    return 0;
}
