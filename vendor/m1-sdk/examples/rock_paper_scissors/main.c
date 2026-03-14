/*
 * Rock Paper Scissors — Play against the M1
 *
 * LEFT/RIGHT to choose, OK to play. Best of rounds with score tracking.
 * Tests: input, RNG, display, state machine, buzzer
 */

#include "m1app.h"

M1_APP_MANIFEST("RPS", 512);

/* Game state */
typedef enum { PICK_ROCK = 0, PICK_PAPER, PICK_SCISSORS } choice_t;
typedef enum { STATE_CHOOSE, STATE_REVEAL, STATE_RESULT } state_t;

static int player_score = 0;
static int cpu_score = 0;
static int draws = 0;

/* Draw a rock (circle with R) */
static void draw_rock(u8g2_t *u8g2, int x, int y, int selected)
{
    if (selected)
        u8g2_DrawDisc(u8g2, x + 12, y + 12, 12, U8G2_DRAW_ALL);
    else
        u8g2_DrawCircle(u8g2, x + 12, y + 12, 12, U8G2_DRAW_ALL);

    u8g2_SetDrawColor(u8g2, selected ? 0 : 1);
    u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
    u8g2_DrawStr(u8g2, x + 8, y + 16, "R");
    u8g2_SetDrawColor(u8g2, 1);
}

/* Draw paper (rectangle with P) */
static void draw_paper(u8g2_t *u8g2, int x, int y, int selected)
{
    if (selected)
        u8g2_DrawBox(u8g2, x, y, 24, 24);
    else
        u8g2_DrawFrame(u8g2, x, y, 24, 24);

    u8g2_SetDrawColor(u8g2, selected ? 0 : 1);
    u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
    u8g2_DrawStr(u8g2, x + 8, y + 16, "P");
    u8g2_SetDrawColor(u8g2, 1);
}

/* Draw scissors (X shape with S) */
static void draw_scissors(u8g2_t *u8g2, int x, int y, int selected)
{
    if (selected)
    {
        u8g2_DrawBox(u8g2, x, y, 24, 24);
        u8g2_SetDrawColor(u8g2, 0);
    }
    else
    {
        u8g2_DrawFrame(u8g2, x, y, 24, 24);
        /* Draw X lines */
        u8g2_DrawLine(u8g2, x + 4, y + 4, x + 20, y + 20);
        u8g2_DrawLine(u8g2, x + 20, y + 4, x + 4, y + 20);
    }

    u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
    u8g2_DrawStr(u8g2, x + 8, y + 16, "S");
    u8g2_SetDrawColor(u8g2, 1);
}

static void draw_choice(u8g2_t *u8g2, int x, int y, choice_t c, int selected)
{
    switch (c)
    {
        case PICK_ROCK:     draw_rock(u8g2, x, y, selected); break;
        case PICK_PAPER:    draw_paper(u8g2, x, y, selected); break;
        case PICK_SCISSORS: draw_scissors(u8g2, x, y, selected); break;
    }
}

static const char *choice_name(choice_t c)
{
    switch (c)
    {
        case PICK_ROCK:     return "Rock";
        case PICK_PAPER:    return "Paper";
        case PICK_SCISSORS: return "Scissors";
    }
    return "?";
}

/* Returns: 0=draw, 1=player wins, 2=cpu wins */
static int judge(choice_t player, choice_t cpu)
{
    if (player == cpu) return 0;
    if ((player == PICK_ROCK && cpu == PICK_SCISSORS) ||
        (player == PICK_PAPER && cpu == PICK_ROCK) ||
        (player == PICK_SCISSORS && cpu == PICK_PAPER))
        return 1;
    return 2;
}

int32_t app_main(void *context)
{
    (void)context;

    u8g2_t *u8g2 = m1app_get_u8g2();
    game_rand_seed();

    state_t state = STATE_CHOOSE;
    choice_t selection = PICK_ROCK;
    choice_t player_choice = PICK_ROCK;
    choice_t cpu_choice = PICK_ROCK;
    int outcome = 0;
    int reveal_timer = 0;

    while (1)
    {
        m1app_button_t btn = game_poll_button(state == STATE_REVEAL ? 80 : 200);

        if (btn == M1APP_BTN_BACK)
            break;

        /* State machine */
        switch (state)
        {
        case STATE_CHOOSE:
            if (btn == M1APP_BTN_LEFT)
            {
                selection = (selection == PICK_ROCK) ? PICK_SCISSORS : (choice_t)(selection - 1);
                m1_buzzer_notification();
            }
            else if (btn == M1APP_BTN_RIGHT)
            {
                selection = (selection == PICK_SCISSORS) ? PICK_ROCK : (choice_t)(selection + 1);
                m1_buzzer_notification();
            }
            else if (btn == M1APP_BTN_OK)
            {
                player_choice = selection;
                cpu_choice = (choice_t)game_rand_range(0, 2);
                state = STATE_REVEAL;
                reveal_timer = 0;
                m1_buzzer_notification();
            }
            break;

        case STATE_REVEAL:
            reveal_timer++;
            if (reveal_timer >= 10)
            {
                outcome = judge(player_choice, cpu_choice);
                if (outcome == 1) player_score++;
                else if (outcome == 2) cpu_score++;
                else draws++;

                if (outcome == 1)
                    m1_buzzer_notification();
                else if (outcome == 2)
                    m1_buzzer_notification2();
                else
                    m1_buzzer_notification();

                state = STATE_RESULT;
            }
            break;

        case STATE_RESULT:
            if (btn == M1APP_BTN_OK)
            {
                state = STATE_CHOOSE;
            }
            break;
        }

        /* Draw */
        m1app_display_begin();
        do {
            u8g2_SetDrawColor(u8g2, 1);
            u8g2_SetFont(u8g2, u8g2_font_5x8_tr);

            /* Score bar */
            char score[32];
            snprintf(score, sizeof(score), "You:%d  CPU:%d  Draw:%d",
                     player_score, cpu_score, draws);
            u8g2_DrawStr(u8g2, 2, 8, score);
            u8g2_DrawHLine(u8g2, 0, 10, 128);

            switch (state)
            {
            case STATE_CHOOSE:
            {
                /* Draw three choices side by side */
                int base_x = 8;
                int base_y = 16;
                int spacing = 40;

                for (int i = 0; i < 3; i++)
                {
                    draw_choice(u8g2, base_x + i * spacing, base_y,
                               (choice_t)i, (int)selection == i);
                }

                /* Labels */
                u8g2_SetFont(u8g2, u8g2_font_4x6_tr);
                u8g2_DrawStr(u8g2, 10, 46, "Rock");
                u8g2_DrawStr(u8g2, 47, 46, "Paper");
                u8g2_DrawStr(u8g2, 82, 46, "Sciss");

                /* Arrow indicator */
                int arrow_x = base_x + (int)selection * spacing + 10;
                u8g2_DrawStr(u8g2, arrow_x, 54, "^");

                u8g2_SetFont(u8g2, u8g2_font_5x8_tr);
                u8g2_DrawStr(u8g2, 10, 63, "<LEFT/RIGHT> OK:Play");
                break;
            }

            case STATE_REVEAL:
            {
                /* Countdown animation — show "3..2..1.." */
                u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
                char countdown[8];
                int n = 3 - (reveal_timer / 3);
                if (n < 1) n = 1;
                snprintf(countdown, sizeof(countdown), "%d...", n);
                u8g2_DrawStr(u8g2, 50, 40, countdown);

                /* Flash random symbols */
                choice_t flash = (choice_t)(reveal_timer % 3);
                draw_choice(u8g2, 10, 20, flash, 0);
                draw_choice(u8g2, 94, 20, (choice_t)((reveal_timer + 1) % 3), 0);
                break;
            }

            case STATE_RESULT:
            {
                /* Show both choices */
                u8g2_SetFont(u8g2, u8g2_font_5x8_tr);
                u8g2_DrawStr(u8g2, 8, 20, "You:");
                u8g2_DrawStr(u8g2, 80, 20, "CPU:");

                draw_choice(u8g2, 10, 22, player_choice, 0);
                draw_choice(u8g2, 90, 22, cpu_choice, 0);

                /* VS */
                u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
                u8g2_DrawStr(u8g2, 55, 38, "VS");

                /* Result text */
                u8g2_SetFont(u8g2, u8g2_font_6x10_tr);
                if (outcome == 1)
                    u8g2_DrawStr(u8g2, 34, 58, "You WIN!");
                else if (outcome == 2)
                    u8g2_DrawStr(u8g2, 30, 58, "You LOSE!");
                else
                    u8g2_DrawStr(u8g2, 40, 58, "DRAW!");

                u8g2_SetFont(u8g2, u8g2_font_4x6_tr);
                u8g2_DrawStr(u8g2, 34, 64, "OK: Again");
                break;
            }
            }

        } while (m1app_display_flush());
    }

    return 0;
}
