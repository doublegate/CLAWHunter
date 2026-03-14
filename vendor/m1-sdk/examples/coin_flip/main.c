/*
 * Coin Flip — Press OK to flip a coin
 *
 * Simple animated coin flip with heads/tails result.
 * Tests: display, input, RNG, buzzer, timing
 */

#include "m1app.h"

M1_APP_MANIFEST("Coin Flip", 512);

/* Simple coin bitmap data — drawn procedurally */

static void draw_coin(u8g2_t *u8g2, int frame, int result)
{
    int cx = 64;
    int cy = 28;

    if (frame < 0)
    {
        /* Static coin showing result */
        u8g2_DrawCircle(u8g2, cx, cy, 18, U8G2_DRAW_ALL);
        u8g2_DrawCircle(u8g2, cx, cy, 16, U8G2_DRAW_ALL);

        u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
        if (result == 0)
            u8g2_DrawStr(u8g2, cx - 6, cy + 4, "H");
        else
            u8g2_DrawStr(u8g2, cx - 5, cy + 4, "T");

        u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
        if (result == 0)
            u8g2_DrawStr(u8g2, 40, 54, "HEADS");
        else
            u8g2_DrawStr(u8g2, 42, 54, "TAILS");
    }
    else
    {
        /* Animated spinning coin — squish horizontally */
        /* Spin phases: full -> thin -> full -> thin ... */
        static const int widths[] = {18, 14, 8, 2, 8, 14, 18, 14, 8, 2, 8, 14};
        int num_phases = 12;
        int phase = frame % num_phases;
        int w = widths[phase];

        /* Draw ellipse approximation using lines */
        int h = 18;
        int x0 = cx - w;
        int x1 = cx + w;

        /* Top and bottom arcs */
        u8g2_DrawLine(u8g2, x0 + 2, cy - h + 2, x1 - 2, cy - h + 2);
        u8g2_DrawLine(u8g2, x0 + 2, cy + h - 2, x1 - 2, cy + h - 2);
        /* Sides */
        u8g2_DrawLine(u8g2, x0, cy - h + 6, x0, cy + h - 6);
        u8g2_DrawLine(u8g2, x1, cy - h + 6, x1, cy + h - 6);
        /* Corners */
        u8g2_DrawLine(u8g2, x0, cy - h + 6, x0 + 2, cy - h + 2);
        u8g2_DrawLine(u8g2, x1, cy - h + 6, x1 - 2, cy - h + 2);
        u8g2_DrawLine(u8g2, x0, cy + h - 6, x0 + 2, cy + h - 2);
        u8g2_DrawLine(u8g2, x1, cy + h - 6, x1 - 2, cy + h - 2);

        /* Show H or T flashing during spin */
        if (w > 6)
        {
            u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
            char c = (phase < 6) ? 'H' : 'T';
            char s[2] = { c, 0 };
            u8g2_DrawStr(u8g2, cx - 4, cy + 4, s);
        }

        /* "Flipping..." text */
        u8g2_SetFont(u8g2, u8g2_font_6x10_tr);
        u8g2_DrawStr(u8g2, 30, 60, "Flipping...");
    }
}

static int total_flips = 0;
static int heads_count = 0;

int32_t app_main(void *context)
{
    (void)context;

    u8g2_t *u8g2 = m1app_get_u8g2();
    game_rand_seed();

    int result = -1;  /* -1 = no result yet */
    int animating = 0;
    int anim_frame = 0;

    while (1)
    {
        m1app_button_t btn = game_poll_button(animating ? 60 : 200);

        if (btn == M1APP_BTN_BACK)
            break;

        if (btn == M1APP_BTN_OK && !animating)
        {
            animating = 1;
            anim_frame = 0;
            m1_buzzer_notification();
        }

        if (animating)
        {
            anim_frame++;
            if (anim_frame >= 18)
            {
                /* Done spinning — pick result */
                animating = 0;
                result = game_rand_range(0, 1);
                total_flips++;
                if (result == 0)
                    heads_count++;
                m1_buzzer_notification();
            }
        }

        /* Draw */
        m1app_display_begin();
        do {
            u8g2_SetDrawColor(u8g2, 1);

            /* Title bar */
            u8g2_DrawBox(u8g2, 0, 0, 128, 12);
            u8g2_SetDrawColor(u8g2, 0);
            u8g2_SetFont(u8g2, u8g2_font_6x10_tr);
            u8g2_DrawStr(u8g2, 30, 10, "Coin Flip");
            u8g2_SetDrawColor(u8g2, 1);

            if (animating)
            {
                draw_coin(u8g2, anim_frame, 0);
            }
            else if (result >= 0)
            {
                draw_coin(u8g2, -1, result);
            }
            else
            {
                /* Initial screen */
                u8g2_SetFont(u8g2, u8g2_font_6x10_tr);
                u8g2_DrawStr(u8g2, 16, 34, "Press OK to flip");

                /* Draw a static coin preview */
                u8g2_DrawCircle(u8g2, 64, 48, 8, U8G2_DRAW_ALL);
                u8g2_SetFont(u8g2, u8g2_font_5x8_tr);
                u8g2_DrawStr(u8g2, 62, 51, "?");
            }

            /* Stats line in title bar */
            if (total_flips > 0)
            {
                char stats[16];
                u8g2_SetDrawColor(u8g2, 0);
                u8g2_SetFont(u8g2, u8g2_font_5x8_tr);
                snprintf(stats, sizeof(stats), "H%d T%d",
                         heads_count, total_flips - heads_count);
                u8g2_DrawStr(u8g2, 2, 9, stats);
                u8g2_SetDrawColor(u8g2, 1);
            }

        } while (m1app_display_flush());
    }

    return 0;
}
