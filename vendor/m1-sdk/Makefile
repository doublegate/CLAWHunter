# M1 App SDK — Build template
#
# Usage:
#   make APP=examples/hello_world      # builds hello_world.m1app
#   make APP=examples/game_template    # builds game_template.m1app
#   make APP=my_app                    # builds from my_app/ directory
#
# Requirements:
#   ARM GCC toolchain (arm-none-eabi-gcc) in PATH
#
# Output:
#   $(APP)/$(notdir $(APP)).m1app — copy this to 0:/apps/ on the M1 SD card

# ---- Toolchain ----
PREFIX  ?= arm-none-eabi-
CC       = $(PREFIX)gcc
OBJCOPY  = $(PREFIX)objcopy
SIZE     = $(PREFIX)size

# ---- App directory ----
APP     ?= examples/hello_world
APP_NAME = $(notdir $(APP))
OUTPUT   = $(APP)/$(APP_NAME).m1app

# ---- SDK paths ----
SDK_DIR   = $(dir $(lastword $(MAKEFILE_LIST)))
INC_DIR   = $(SDK_DIR)include
LINK_DIR  = $(SDK_DIR)linker

# ---- Source files ----
SRCS     = $(wildcard $(APP)/*.c)
OBJS     = $(SRCS:.c=.o)

# ---- Compiler flags ----
CFLAGS   = -mcpu=cortex-m33 -mthumb -mfloat-abi=soft
CFLAGS  += -mword-relocations -mlong-calls
CFLAGS  += -fno-common -fdata-sections -ffunction-sections
CFLAGS  += -Os -g -Wall -Wextra
CFLAGS  += -I$(INC_DIR)
CFLAGS  += -nostdlib -nostartfiles

# ---- Linker flags ----
# -Ur: output relocatable ELF with symbol resolution
# -e app_main: set entry point
LDFLAGS  = -mcpu=cortex-m33 -mthumb -mfloat-abi=soft
LDFLAGS += -nostdlib -nostartfiles
LDFLAGS += -Wl,-Ur
LDFLAGS += -Wl,--gc-sections
LDFLAGS += -Wl,-e,app_main
LDFLAGS += -T$(LINK_DIR)/m1app.ld

# ---- Rules ----

all: $(OUTPUT)
	@echo ""
	@echo "Built: $(OUTPUT)"
	@echo "Copy to SD card: 0:/apps/$(APP_NAME).m1app"
	@$(SIZE) $(OUTPUT)

$(OUTPUT): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(OUTPUT)

.PHONY: all clean
