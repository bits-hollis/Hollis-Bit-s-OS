# ==============================================================================
# Hollis-Bit's OS — Makefile сборки и запуска
# ==============================================================================

BUILD_DIR = build
BOOT_SRC  = src/boot/boot.asm
ASM_ENTRY = src/kernel/entry.asm
ZIG_MAIN  = src/kernel/main.zig
LINKER_LD = src/linker.ld
IMG       = $(BUILD_DIR)/os.img

.PHONY: all run clean

# Главная цель: собрать загрузочный образ диска
all: $(IMG)

# 1. Сборка 16-битного загрузочного сектора (MBR)
$(BUILD_DIR)/boot.bin: $(BOOT_SRC)
	@mkdir -p $(BUILD_DIR)
	nasm -f bin $(BOOT_SRC) -o $@

# 2. Сборка ассемблерной точки входа ядра в объектный файл ELF64
$(BUILD_DIR)/entry.o: $(ASM_ENTRY)
	@mkdir -p $(BUILD_DIR)
	nasm -f elf64 $(ASM_ENTRY) -o $@

# 3. Сборка Zig-модуля сложной логики в объектный файл
$(BUILD_DIR)/main.o: $(ZIG_MAIN)
	@mkdir -p $(BUILD_DIR)
	zig build-obj -target x86_64-freestanding-none -O ReleaseSmall $(ZIG_MAIN) -femit-bin=$@

# 4. Линковка ассемблерного ядра и Zig-модуля в бинарный файл
$(BUILD_DIR)/kernel.bin: $(BUILD_DIR)/entry.o $(BUILD_DIR)/main.o $(LINKER_LD)
	ld -m elf_x86_64 -T $(LINKER_LD) $(BUILD_DIR)/entry.o $(BUILD_DIR)/main.o -o $(BUILD_DIR)/kernel.elf
	objcopy -O binary $(BUILD_DIR)/kernel.elf $@

# 5. Упаковка загрузочного образа диска
$(IMG): $(BUILD_DIR)/boot.bin $(BUILD_DIR)/kernel.bin
	dd if=$(BUILD_DIR)/boot.bin of=$@ bs=512 count=1 conv=notrunc status=none
	dd if=/dev/zero of=$@ bs=512 count=20480 seek=1 conv=notrunc status=none

# Запуск в эмуляторе QEMU
run: $(IMG)
	qemu-system-x86_64 -drive format=raw,file=$(IMG) -serial stdio -m 128M

# Очистка временных файлов сборки
clean:
	rm -rf $(BUILD_DIR)
