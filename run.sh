#!/usr/bin/env bash
# ==============================================================================
# Hollis-Bit's OS — Скрипт сборки и запуска в QEMU
# Эпоха: 64-битный Long Mode + Ядро на Zig + Linux-стиль Shell
# ==============================================================================
set -e

mkdir -p build

echo "[1/6] Сборка 16-битного загрузочного сектора MBR (boot.asm)..."
nasm -f bin src/boot/boot.asm -o build/boot.bin

echo "[2/6] Сборка стадии быстрого перехода 16->32->64 бит (stage2_16.asm)..."
nasm -f bin src/boot/stage2_16.asm -o build/stage2_16.bin

echo "[3/6] Сборка 64-битного ассемблерного стаба ядра (entry.asm)..."
nasm -f elf64 src/kernel/entry.asm -o build/entry.o

echo "[4/6] Сборка 64-битного ядра на Zig (main.zig freestanding)..."
zig build-obj -target x86_64-freestanding-none -O ReleaseSmall src/kernel/main.zig -femit-bin=build/main.o

echo "[5/6] Линковка 64-битного ядра (ASM + Zig) по адресу 1 МБ (0x100000)..."
ld -m elf_x86_64 -T src/linker.ld build/entry.o build/main.o -o build/kernel.elf
objcopy -O binary build/kernel.elf build/kernel.bin

echo "[6/6] Создание загрузочного образа диска os.img (MBR + Stage 2 + 64-bit Kernel)..."
# Сектор 1 (0..512 байт): MBR
dd if=build/boot.bin of=build/os.img bs=512 count=1 conv=notrunc status=none
# Секторы 2..17 (8 КБ): Переходник в 64-битный режим и пейджинг
dd if=build/stage2_16.bin of=build/os.img bs=512 seek=1 count=16 conv=notrunc status=none
# Секторы 18..81 (32 КБ): 64-битное ядро Hollis-Bit's OS
dd if=build/kernel.bin of=build/os.img bs=512 seek=17 count=64 conv=notrunc status=none
# Оставшееся пространство диска
dd if=/dev/zero of=build/os.img bs=512 count=20480 seek=81 conv=notrunc status=none

echo "--------------------------------------------------------"
echo "Сборка завершена! Запуск 64-битного ядра в QEMU..."
echo "Для выхода из QEMU закройте окно или нажмите Ctrl+C"
echo "--------------------------------------------------------"
qemu-system-x86_64 \
    -drive format=raw,file=build/os.img \
    -serial stdio \
    -m 128M
