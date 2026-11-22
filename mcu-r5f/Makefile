CROSS   ?= arm-none-eabi-
CC      := $(CROSS)gcc
READELF := $(CROSS)readelf

CFLAGS  := -mcpu=cortex-r5 -marm -mfloat-abi=soft -O2 -g \
           -ffreestanding -nostdlib -nostartfiles -fno-builtin \
           -Wall -Wextra
LDFLAGS := -T r5fw.ld -Wl,--build-id=none -Wl,-Map=r5fw.map

all: r5fw.elf
	@echo
	@$(READELF) -h r5fw.elf | grep -E 'Entry|Type|Machine'
	@echo
	@$(READELF) -l r5fw.elf | sed -n '/Program Headers/,$$p'
	@echo
	@$(CROSS)size r5fw.elf

r5fw.elf: start.S r5fw.c r5fw.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S r5fw.c

clean:
	rm -f r5fw.elf r5fw.map

.PHONY: all clean
