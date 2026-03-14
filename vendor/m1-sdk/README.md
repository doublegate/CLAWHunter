# M1 App SDK

Build external apps for the Monstatek M1. Apps are ARM ELF executables loaded from SD card and run as FreeRTOS tasks on the M1's Cortex-M33 processor.

## Requirements

- **ARM GCC toolchain** (`arm-none-eabi-gcc`) — any recent version (10+)
  - Windows: [ARM GNU Toolchain Downloads](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads)
  - Linux: `sudo apt install gcc-arm-none-eabi`
  - macOS: `brew install arm-none-eabi-gcc`

## Quick Start

```bash
# Build the hello world example
make APP=examples/hello_world

# Build the game template
make APP=examples/game_template

# Build your own app
mkdir my_app
# create my_app/main.c (see examples)
make APP=my_app
```

## Creating an App

### 1. Create your source file

```c
#include "m1app.h"

// Declare app manifest (name shown in menu, stack size in 32-bit words)
M1_APP_MANIFEST("My App", 512);

// Entry point — called by the M1 loader
int32_t app_main(void *context) {
    u8g2_t *u8g2 = m1app_get_u8g2();

    while (1) {
        m1app_button_t btn = game_poll_button(50);
        if (btn == M1APP_BTN_BACK)
            break;

        m1app_display_begin();
        do {
            u8g2_SetDrawColor(u8g2, 1);
            u8g2_SetFont(u8g2, u8g2_font_6x10_tr);
            u8g2_DrawStr(u8g2, 10, 30, "Hello!");
        } while (m1app_display_flush());
    }
    return 0;
}
```

### 2. Build

```bash
make APP=my_app
```

### 3. Deploy

Copy `my_app/my_app.m1app` to `apps/` on the M1's SD card.

On the M1, go to **Apps** in the main menu to browse and run your app.

## API Reference

### Display

The M1 has a 128x64 monochrome display driven by u8g2. Apps share the firmware's display context.

```c
u8g2_t *u8g2 = m1app_get_u8g2();  // Get display handle

// Draw loop pattern:
m1app_display_begin();
do {
    u8g2_SetDrawColor(u8g2, 1);
    u8g2_DrawStr(u8g2, x, y, "text");
    u8g2_DrawBox(u8g2, x, y, w, h);
    u8g2_DrawFrame(u8g2, x, y, w, h);
    u8g2_DrawPixel(u8g2, x, y);
    u8g2_DrawLine(u8g2, x0, y0, x1, y1);
    u8g2_DrawCircle(u8g2, x, y, r, U8G2_DRAW_ALL);
} while (m1app_display_flush());
```

### Input

```c
m1app_button_t btn = game_poll_button(timeout_ms);
// Returns: M1APP_BTN_NONE, _UP, _DOWN, _LEFT, _RIGHT, _OK, _BACK
```

### Timing

```c
m1app_delay(100);                // sleep 100ms (yields to RTOS)
uint32_t now = m1app_get_tick(); // milliseconds since boot
```

### Memory

```c
void *p = m1app_malloc(size);    // allocate from FreeRTOS heap
m1app_free(p);                   // free
```

### Audio

```c
m1_buzzer_notification();                       // standard beep
m1_buzzer_notification2();                      // alternate beep (error)
m1_buzzer_set(2000, 100);                       // custom tone: freq Hz, duration ms
```

### File I/O

```c
M1_FIL file;
if (f_open(&file, "0:/data/myfile.txt", M1_FA_READ) == M1FR_OK) {
    char buf[64];
    unsigned int br;
    f_read(&file, buf, sizeof(buf), &br);
    f_close(&file);
}
```

### Random Numbers

```c
game_rand_seed();                    // seed once at startup
int val = game_rand_range(1, 100);   // random int in [1, 100]
```

### Available Fonts

**Only fonts listed below are available.** Using any other u8g2 font will cause a
`Load error missing symbol` at launch. All fonts are declared as `extern` in `m1app.h`.

| Font name | Size | Style | Notes |
|-----------|------|-------|-------|
| `u8g2_font_4x6_tr` | 4x6 | Regular | Tiny, good for dense info |
| `u8g2_font_finderskeepers_tf` | ~5px | Compact | Very small, narrow |
| `u8g2_font_squeezed_b7_tr` | ~5px | Bold | Compact bold |
| `u8g2_font_5x8_tr` | 5x8 | Regular | Good default small font |
| `u8g2_font_spleen5x8_mf` | 5x8 | Mono | Fixed-width small |
| `u8g2_font_NokiaSmallPlain_tf` | ~6px | Regular | Nokia style |
| `u8g2_font_resoledmedium_tr` | 5x10 | Regular | Clear, readable |
| `u8g2_font_nine_by_five_nbp_tf` | 9x5 | Regular | Wide, clear |
| `u8g2_font_pcsenior_8f` | 8px | Bold | Wide bold |
| `u8g2_font_6x10_tr` | 6x10 | Regular | Good general-purpose |
| `u8g2_font_helvB08_tr` | 8px | Helvetica Bold | ASCII only |
| `u8g2_font_helvB08_tf` | 8px | Helvetica Bold | Full charset |
| `u8g2_font_courB08_tf` | 8px | Courier Bold | Monospace bold |
| `u8g2_font_lubB08_tf` | 8px | Lucida Bold | Serif bold |
| `u8g2_font_Terminal_tr` | ~9px | Terminal | Terminal/console |
| `u8g2_font_10x20_mr` | 10x20 | Mono | Large monospace |
| `u8g2_font_profont17_tr` | 17px | Mono | Large fixed-width |
| `u8g2_font_spleen8x16_mf` | 8x16 | Mono | Medium-large |
| `u8g2_font_VCR_OSD_tu` | 12x17 | VCR | Large retro/bold |
| `u8g2_font_Pixellari_tu` | 10px | Pixel | Pixel art style |

```c
// Example: use a small font for HUD, large for titles
u8g2_SetFont(u8g2, u8g2_font_5x8_tr);        // small
u8g2_DrawStr(u8g2, 0, 8, "Score: 42");

u8g2_SetFont(u8g2, u8g2_font_VCR_OSD_tu);    // large
u8g2_DrawStr(u8g2, 10, 40, "GAME OVER");
```

## App Manifest

Every app must include a manifest using the `M1_APP_MANIFEST` macro:

```c
M1_APP_MANIFEST("App Name", stack_words);
```

- **App Name**: Up to 31 characters, displayed in the Apps browser
- **stack_words**: FreeRTOS task stack size in 32-bit words (512 = 2KB, 1024 = 4KB)

Recommended stack sizes:
- Simple apps: 512 (2KB)
- Games with moderate state: 768 (3KB)
- Apps with file I/O or complex logic: 1024 (4KB)

## Limitations

- No dynamic linking — all firmware symbols are resolved at load time via hash table
- No C++ exceptions or RTTI
- No heap beyond what `m1app_malloc` provides (shared FreeRTOS heap)
- No direct hardware access — use the provided API wrappers
- Maximum app size limited by available RAM (~100KB typical)
- Single app at a time — launching a new app stops the current one

## File Structure

```
sdk/
├── include/
│   └── m1app.h          # All API declarations
├── linker/
│   └── m1app.ld         # Linker script
├── examples/
│   ├── hello_world/     # Minimal app
│   │   └── main.c
│   └── game_template/   # Game starter template
│       └── main.c
├── Makefile             # Build system
└── README.md            # This file
```
