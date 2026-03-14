/*
 * Flappy Bird — Tap OK to flap, avoid the pipes
 *
 * Tests: game loop timing, collision detection, scrolling, score, buzzer
 */

#include "m1app.h"

M1_APP_MANIFEST("Flappy Bird", 768);

/* Constants */
#define SCREEN_W      128
#define SCREEN_H      64
#define PIPE_W        8
#define PIPE_GAP      26
#define PIPE_SPEED    2
#define BIRD_X        20
#define BIRD_W        6
#define BIRD_H        5
#define MAX_PIPES     3
#define GROUND_H      4
#define PLAY_H        (SCREEN_H - GROUND_H)
#define FRAME_MS      50   /* ~20 fps */

/* Scaled physics: positions are multiplied by PHYS_SCALE.
 * This allows fractional gravity (1/4 pixel per frame²). */
#define PHYS_SCALE    4
#define GRAVITY       1           /* 0.25 px/frame² */
#define FLAP_FORCE    (-8)        /* -2.0 px/frame upward */
#define VY_MAX        (3 * PHYS_SCALE)  /* terminal velocity */

typedef struct {
    int x;
    int gap_y;    /* top of the gap */
    int scored;   /* already counted for score */
    int active;
} pipe_t;

static int bird_y_s;   /* scaled position (multiply by PHYS_SCALE) */
static int bird_vy;    /* scaled velocity */
static pipe_t pipes[MAX_PIPES];
static int score;
static int best_score;
static int alive;
static int ground_scroll;

static void reset_game(void)
{
    bird_y_s = (PLAY_H / 2) * PHYS_SCALE;
    bird_vy = 0;
    score = 0;
    alive = 1;
    ground_scroll = 0;

    for (int i = 0; i < MAX_PIPES; i++)
    {
        pipes[i].x = SCREEN_W + i * 50;
        pipes[i].gap_y = game_rand_range(10, PLAY_H - PIPE_GAP - 10);
        pipes[i].scored = 0;
        pipes[i].active = 1;
    }
}

static void update(int flap)
{
    /* Bird physics (scaled coordinates) */
    if (flap)
        bird_vy = FLAP_FORCE;

    bird_vy += GRAVITY;
    if (bird_vy > VY_MAX)
        bird_vy = VY_MAX;
    bird_y_s += bird_vy;

    /* Convert to screen pixels for checks */
    int bird_y = bird_y_s / PHYS_SCALE;

    /* Clamp to play area */
    if (bird_y < 0)
    {
        bird_y_s = 0;
        bird_vy = 0;
        bird_y = 0;
    }
    if (bird_y > PLAY_H - BIRD_H)
    {
        bird_y_s = (PLAY_H - BIRD_H) * PHYS_SCALE;
        bird_y = PLAY_H - BIRD_H;
        alive = 0;
    }

    /* Move pipes */
    for (int i = 0; i < MAX_PIPES; i++)
    {
        if (!pipes[i].active)
            continue;

        pipes[i].x -= PIPE_SPEED;

        /* Score check */
        if (!pipes[i].scored && pipes[i].x + PIPE_W < BIRD_X)
        {
            pipes[i].scored = 1;
            score++;
            m1_buzzer_notification();
        }

        /* Recycle pipe */
        if (pipes[i].x < -PIPE_W)
        {
            pipes[i].x = SCREEN_W + game_rand_range(10, 30);
            pipes[i].gap_y = game_rand_range(10, PLAY_H - PIPE_GAP - 10);
            pipes[i].scored = 0;
        }

        /* Collision check */
        if (pipes[i].x < BIRD_X + BIRD_W && pipes[i].x + PIPE_W > BIRD_X)
        {
            /* Bird overlaps pipe column horizontally */
            if (bird_y < pipes[i].gap_y || bird_y + BIRD_H > pipes[i].gap_y + PIPE_GAP)
            {
                alive = 0;
            }
        }
    }

    /* Ground scroll */
    ground_scroll = (ground_scroll + PIPE_SPEED) % 4;
}

static void draw_bird(u8g2_t *u8g2)
{
    int by = bird_y_s / PHYS_SCALE;

    /* Simple bird shape */
    u8g2_DrawBox(u8g2, BIRD_X, by, BIRD_W, BIRD_H);

    /* Wing (flap animation based on velocity) */
    if (bird_vy < 0)
    {
        /* Wing up */
        u8g2_DrawPixel(u8g2, BIRD_X + 1, by - 1);
        u8g2_DrawPixel(u8g2, BIRD_X + 2, by - 1);
    }
    else
    {
        /* Wing down */
        u8g2_DrawPixel(u8g2, BIRD_X + 1, by + BIRD_H);
        u8g2_DrawPixel(u8g2, BIRD_X + 2, by + BIRD_H);
    }

    /* Eye */
    u8g2_SetDrawColor(u8g2, 0);
    u8g2_DrawPixel(u8g2, BIRD_X + BIRD_W - 2, by + 1);
    u8g2_SetDrawColor(u8g2, 1);

    /* Beak */
    u8g2_DrawPixel(u8g2, BIRD_X + BIRD_W, by + 2);
    u8g2_DrawPixel(u8g2, BIRD_X + BIRD_W + 1, by + 2);
}

static void draw_pipes(u8g2_t *u8g2)
{
    for (int i = 0; i < MAX_PIPES; i++)
    {
        if (!pipes[i].active)
            continue;

        int px = pipes[i].x;
        int gy = pipes[i].gap_y;

        if (px > SCREEN_W || px + PIPE_W < 0)
            continue;

        /* Top pipe */
        if (gy > 0)
            u8g2_DrawBox(u8g2, px, 0, PIPE_W, gy);

        /* Top pipe lip */
        if (gy >= 3)
        {
            u8g2_DrawBox(u8g2, px - 1, gy - 3, PIPE_W + 2, 3);
        }

        /* Bottom pipe */
        int bot_y = gy + PIPE_GAP;
        if (bot_y < PLAY_H)
            u8g2_DrawBox(u8g2, px, bot_y, PIPE_W, PLAY_H - bot_y);

        /* Bottom pipe lip */
        if (bot_y + 3 <= PLAY_H)
        {
            u8g2_DrawBox(u8g2, px - 1, bot_y, PIPE_W + 2, 3);
        }
    }
}

static void draw_ground(u8g2_t *u8g2)
{
    /* Ground line */
    u8g2_DrawHLine(u8g2, 0, PLAY_H, SCREEN_W);

    /* Ground pattern */
    for (int x = -ground_scroll; x < SCREEN_W; x += 4)
    {
        u8g2_DrawPixel(u8g2, x, PLAY_H + 2);
    }
}

int32_t app_main(void *context)
{
    (void)context;

    u8g2_t *u8g2 = m1app_get_u8g2();
    game_rand_seed();

    int game_started = 0;

    reset_game();

    while (1)
    {
        m1app_button_t btn = game_poll_button(FRAME_MS);

        if (btn == M1APP_BTN_BACK)
            break;

        if (!game_started)
        {
            /* Title screen */
            if (btn == M1APP_BTN_OK)
            {
                game_started = 1;
                reset_game();
                m1_buzzer_notification();
            }

            m1app_display_begin();
            do {
                u8g2_SetDrawColor(u8g2, 1);
                u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
                u8g2_DrawStr(u8g2, 18, 20, "Flappy Bird");

                u8g2_SetFont(u8g2, u8g2_font_6x10_tr);
                u8g2_DrawStr(u8g2, 16, 38, "Press OK to fly");

                if (best_score > 0)
                {
                    char best[20];
                    u8g2_SetFont(u8g2, u8g2_font_5x8_tr);
                    snprintf(best, sizeof(best), "Best: %d", best_score);
                    u8g2_DrawStr(u8g2, 42, 52, best);
                }

                /* Draw a little bird preview */
                u8g2_DrawBox(u8g2, 60, 42, BIRD_W, BIRD_H);

                draw_ground(u8g2);
            } while (m1app_display_flush());

            continue;
        }

        if (alive)
        {
            int flap = (btn == M1APP_BTN_OK || btn == M1APP_BTN_UP);
            update(flap);

            if (!alive)
            {
                if (score > best_score)
                    best_score = score;
                m1_buzzer_notification2();
            }
        }
        else
        {
            /* Dead — OK to restart */
            if (btn == M1APP_BTN_OK)
            {
                reset_game();
                m1_buzzer_notification();
            }
        }

        /* Draw */
        m1app_display_begin();
        do {
            u8g2_SetDrawColor(u8g2, 1);

            draw_pipes(u8g2);
            draw_bird(u8g2);
            draw_ground(u8g2);

            /* Score */
            char sc[8];
            u8g2_SetFont(u8g2, u8g2_font_helvB08_tr);
            snprintf(sc, sizeof(sc), "%d", score);
            u8g2_DrawStr(u8g2, 60, 10, sc);

            if (!alive)
            {
                /* Game over overlay */
                u8g2_DrawFrame(u8g2, 20, 18, 88, 30);
                u8g2_SetDrawColor(u8g2, 0);
                u8g2_DrawBox(u8g2, 21, 19, 86, 28);
                u8g2_SetDrawColor(u8g2, 1);

                u8g2_SetFont(u8g2, u8g2_font_6x10_tr);
                u8g2_DrawStr(u8g2, 30, 30, "Game Over!");

                char final_sc[24];
                snprintf(final_sc, sizeof(final_sc), "Score:%d Best:%d", score, best_score);
                u8g2_SetFont(u8g2, u8g2_font_5x8_tr);
                u8g2_DrawStr(u8g2, 24, 42, final_sc);
            }

        } while (m1app_display_flush());
    }

    return 0;
}
