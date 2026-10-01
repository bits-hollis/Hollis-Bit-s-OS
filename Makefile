# ==============================================================================
# Hollis-Bit's OS — Makefile сборки и запуска (64-bit Long Mode)
# ==============================================================================

BUILD_DIR = build
BOOT_SRC  = src/boot/boot.asm
STAGE2_SRC= src/boot/stage2_16.asm
ASM_ENTRY = src/kernel/entry.asm
ZIG_MAIN  = src/kernel/main.zig
LINKER_LD = src/linker.ld
IMG       = $(BUILD_DIR)/os.img

.PHONY: all run clean

all: $(IMG)

$(BUILD_DIR)/boot.bin: $(BOOT_SRC)
	@mkdir -p $(BUILD_DIR)
	nasm -f bin $(BOOT_SRC) -o $@

$(BUILD_DIR)/stage2_16.bin: $(STAGE2_SRC)
	@mkdir -p $(BUILD_DIR)
	nasm -f bin $(STAGE2_SRC) -o $@

$(BUILD_DIR)/entry.o: $(ASM_ENTRY)
	@mkdir -p $(BUILD_DIR)
	nasm -f elf64 $(ASM_ENTRY) -o $@

$(BUILD_DIR)/main.o: $(ZIG_MAIN)
	@mkdir -p $(BUILD_DIR)
	zig build-obj -target x86_64-freestanding-none -O ReleaseSmall $(ZIG_MAIN) -femit-bin=$@

$(BUILD_DIR)/kernel.bin: $(BUILD_DIR)/entry.o $(BUILD_DIR)/main.o $(LINKER_LD)
	ld -m elf_x86_64 -T $(LINKER_LD) $(BUILD_DIR)/entry.o $(BUILD_DIR)/main.o -o $(BUILD_DIR)/kernel.elf
	objcopy -O binary $(BUILD_DIR)/kernel.elf $@

$(IMG): $(BUILD_DIR)/boot.bin $(BUILD_DIR)/stage2_16.bin $(BUILD_DIR)/kernel.bin
	dd if=$(BUILD_DIR)/boot.bin of=$@ bs=512 count=1 conv=notrunc status=none
	dd if=$(BUILD_DIR)/stage2_16.bin of=$@ bs=512 seek=1 count=16 conv=notrunc status=none
	dd if=$(BUILD_DIR)/kernel.bin of=$@ bs=512 seek=17 count=64 conv=notrunc status=none
	dd if=/dev/zero of=$@ bs=512 count=20480 seek=81 conv=notrunc status=none

run: $(IMG)
	qemu-system-x86_64 -drive format=raw,file=$(IMG) -serial stdio -m 128M

clean:
	rm -rf $(BUILD_DIR)
