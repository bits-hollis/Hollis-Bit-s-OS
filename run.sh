#!/usr/bin/env bash
# ==============================================================================
# Hollis-Bit's OS — Скрипт сборки и запуска в QEMU
# Эпоха: 64-битный Long Mode + Прерывания IDT + Таймер PIT + Linux Shell
# ==============================================================================
set -e

mkdir -p build

echo "[1/7] Сборка 16-битного загрузочного сектора MBR (boot.asm)..."
nasm -f bin src/boot/boot.asm -o build/boot.bin

echo "[2/7] Сборка стадии быстрого перехода 16->32->64 бит (stage2_16.asm)..."
nasm -f bin src/boot/stage2_16.asm -o build/stage2_16.bin

echo "[3/7] Сборка 64-битного ассемблерного стаба ядра (entry.asm)..."
nasm -f elf64 src/kernel/entry.asm -o build/entry.o

echo "[4/7] Сборка ассемблерных обработчиков прерываний IDT (interrupts.asm)..."
nasm -f elf64 src/kernel/interrupts.asm -o build/interrupts.o

echo "[5/7] Сборка 64-битного ядра на Zig (main.zig freestanding)..."
zig build-obj -target x86_64-freestanding-none -O ReleaseSmall src/kernel/main.zig -femit-bin=build/main.o

echo "[6/7] Линковка 64-битного ядра (ASM + Zig) по адресу 1 МБ (0x100000)..."
ld -m elf_x86_64 -T src/linker.ld build/entry.o build/interrupts.o build/main.o -o build/kernel.elf
objcopy -O binary build/kernel.elf build/kernel.bin

echo "[7/7] Создание загрузочного образа диска os.img (MBR + Stage 2 + 64-bit Kernel)..."
dd if=build/boot.bin of=build/os.img bs=512 count=1 conv=notrunc status=none
dd if=build/stage2_16.bin of=build/os.img bs=512 seek=1 count=16 conv=notrunc status=none
dd if=build/kernel.bin of=build/os.img bs=512 seek=17 count=64 conv=notrunc status=none
dd if=/dev/zero of=build/os.img bs=512 count=20480 seek=81 conv=notrunc status=none

echo "--------------------------------------------------------"
echo "Сборка завершена! Запуск ядра Hollis-Bit's OS в QEMU..."
echo "Для выхода из QEMU закройте окно или нажмите Ctrl+C"
echo "--------------------------------------------------------"
qemu-system-x86_64 \
    -drive format=raw,file=build/os.img \
    -serial stdio \
    -m 128M
