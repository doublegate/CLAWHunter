#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include "main.h"
#include "m1_display.h"
#include "m1_menu.h"
#include "m1_wifi.h"
#include "m1_clawhunter.h"

#define LOG_TAG "CLAWHunter"

void clawhunter_recon(void);
void clawhunter_user(void);
void clawhunter_alert(void);

void clawhunter_recon(void) {
    m1_u8g2_firstpage();
    u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);
    u8g2_DrawStr(&m1_u8g2, 2, 15, "Recon Mode...");
    m1_u8g2_nextpage();
    vTaskDelay(pdMS_TO_TICKS(2000));
}

void clawhunter_user(void) {
    m1_u8g2_firstpage();
    u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);
    u8g2_DrawStr(&m1_u8g2, 2, 15, "User Mode...");
    m1_u8g2_nextpage();
    vTaskDelay(pdMS_TO_TICKS(2000));
}

void clawhunter_alert(void) {
    m1_u8g2_firstpage();
    u8g2_SetFont(&m1_u8g2, M1_DISP_MAIN_MENU_FONT_N);
    u8g2_DrawStr(&m1_u8g2, 2, 15, "Alert Mode...");
    m1_u8g2_nextpage();
    vTaskDelay(pdMS_TO_TICKS(2000));
}

void menu_clawhunter_init(void) {
    // Menu logic will go here
}
