/*
 * Game Template — Starter template for M1 games
 *
 * Simple bouncing ball demo showing the game loop pattern:
 *   1. Poll input
 *   2. Update game state
 *   3. Draw frame
 *   4. Delay for frame timing
 */

#include "m1app.h"

M1_APP_MANIFEST("Bounce Demo", 512);

/* Game state */
static int ball_x = 64;
static int ball_y = 32;
static int ball_dx = 2;
static int ball_dy = 1;
static int paddle_y = 24;

#define PADDLE_X      4
#define PADDLE_W      3
#define PADDLE_H      16
#define BALL_SIZE     4
#define PADDLE_SPEED  3
#define FPS_DELAY     33   /* ~30 fps */

static void update(m1app_button_t btn)
{
    /* Move paddle */
    if (btn == M1APP_BTN_UP && paddle_y > 0)
        paddle_y -= PADDLE_SPEED;
    if (btn == M1APP_BTN_DOWN && paddle_y < M1APP_SCREEN_H - PADDLE_H)
        paddle_y += PADDLE_SPEED;

    /* Move ball */
    ball_x += ball_dx;
    ball_y += ball_dy;

    /* Bounce off walls */
    if (ball_y <= 0 || ball_y >= M1APP_SCREEN_H - BALL_SIZE)
        ball_dy = -ball_dy;
    if (ball_x >= M1APP_SCREEN_W - BALL_SIZE)
        ball_dx = -ball_dx;

    /* Bounce off paddle */
    if (ball_x <= PADDLE_X + PADDLE_W &&
        ball_y + BALL_SIZE >= paddle_y &&
        ball_y <= paddle_y + PADDLE_H &&
        ball_dx < 0)
    {
        ball_dx = -ball_dx;
        m1_buzzer_notification();
    }

    /* Reset if ball goes past paddle */
    if (ball_x < 0)
    {
        ball_x = 64;
        ball_y = 32;
        ball_dx = 2;
    }
}

static void draw(u8g2_t *u8g2)
{
    /* Clear and draw border */
    u8g2_DrawFrame(u8g2, 0, 0, M1APP_SCREEN_W, M1APP_SCREEN_H);

    /* Draw paddle */
    u8g2_DrawBox(u8g2, PADDLE_X, paddle_y, PADDLE_W, PADDLE_H);

    /* Draw ball */
    u8g2_DrawBox(u8g2, ball_x, ball_y, BALL_SIZE, BALL_SIZE);

    /* Draw instructions */
    u8g2_SetFont(u8g2, u8g2_font_4x6_tr);
    u8g2_DrawStr(u8g2, 40, 8, "UP/DOWN: move");
}

int32_t app_main(void *context)
{
    (void)context;

    u8g2_t *u8g2 = m1app_get_u8g2();
    game_rand_seed();

    while (1)
    {
        /* 1. Poll input (non-blocking, short timeout for frame timing) */
        m1app_button_t btn = game_poll_button(FPS_DELAY);
        if (btn == M1APP_BTN_BACK)
            break;

        /* 2. Update game state */
        update(btn);

        /* 3. Draw frame */
        m1app_display_begin();
        do {
            u8g2_SetDrawColor(u8g2, 1);
            draw(u8g2);
        } while (m1app_display_flush());
    }

    return 0;
}
