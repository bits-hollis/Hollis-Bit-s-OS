#!/usr/bin/env bash
# ==============================================================================
# Hollis-Bit's OS — Скрипт сборки и запуска в QEMU (Этап 0)
# Архитектура: ASM-основа ядра + Zig-модуль сложной логики
# ==============================================================================
set -e

# Создаем папку для собранных бинарных файлов
mkdir -p build

echo "[1/6] Сборка 16-битного загрузочного сектора MBR (boot.asm)..."
nasm -f bin src/boot/boot.asm -o build/boot.bin

echo "[2/6] Сборка второй стадии 16-битного режима (stage2_16.asm)..."
nasm -f bin src/boot/stage2_16.asm -o build/stage2_16.bin

echo "[3/6] Сборка низкоуровневого ядра на Ассемблере (ELF64)..."
nasm -f elf64 src/kernel/entry.asm -o build/entry.o

echo "[4/6] Сборка тяжелого модуля логики на Zig (freestanding 64-bit)..."
zig build-obj -target x86_64-freestanding-none -O ReleaseSmall src/kernel/main.zig -femit-bin=build/main.o

echo "[5/6] Линковка ядра (ASM + Zig) в единый бинарный образ..."
ld -m elf_x86_64 -T src/linker.ld build/entry.o build/main.o -o build/kernel.elf
objcopy -O binary build/kernel.elf build/kernel.bin

echo "[6/6] Формирование загрузочного образа диска os.img..."
# Записываем MBR-загрузчик в сектор 1 (первые 512 байт диска)
dd if=build/boot.bin of=build/os.img bs=512 count=1 conv=notrunc status=none
# Записываем Stage 2 (16-бит + 32-бит ядро) в секторы 2..17 (8192 байта = 16 секторов)
dd if=build/stage2_16.bin of=build/os.img bs=512 seek=1 count=16 conv=notrunc status=none
# Создаем пространство диска в 10 МБ для будущих секторов ядра и игровых данных
dd if=/dev/zero of=build/os.img bs=512 count=20480 seek=17 conv=notrunc status=none

echo "--------------------------------------------------------"
echo "Сборка завершена успешно! Запуск QEMU..."
echo "Для выхода из QEMU закройте окно или нажмите Ctrl+C"
echo "--------------------------------------------------------"
qemu-system-x86_64 \
    -drive format=raw,file=build/os.img \
    -serial stdio \
    -m 128M
