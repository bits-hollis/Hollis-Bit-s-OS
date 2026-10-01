#!/usr/bin/env bash
# ==============================================================================
# Hollis-Bit's OS — Скрипт сборки и запуска в QEMU (Этап 0)
# Архитектура: ASM-основа ядра + Zig-модуль сложной логики
# ==============================================================================
set -e

# Создаем папку для собранных бинарных файлов
mkdir -p build

echo "[1/5] Сборка 16-битного загрузчика MBR (NASM)..."
nasm -f bin src/boot/boot.asm -o build/boot.bin

echo "[2/5] Сборка низкоуровневого ядра на Ассемблере (ELF64)..."
nasm -f elf64 src/kernel/entry.asm -o build/entry.o

echo "[3/5] Сборка тяжелого модуля логики на Zig (freestanding 64-bit)..."
zig build-obj -target x86_64-freestanding-none -O ReleaseSmall src/kernel/main.zig -femit-bin=build/main.o

echo "[4/5] Линковка ядра (ASM + Zig) в единый бинарный образ..."
ld -m elf_x86_64 -T src/linker.ld build/entry.o build/main.o -o build/kernel.elf
objcopy -O binary build/kernel.elf build/kernel.bin

echo "[5/5] Формирование загрузочного образа диска os.img..."
# Записываем MBR-загрузчик в 0-й сектор (первые 512 байт диска)
dd if=build/boot.bin of=build/os.img bs=512 count=1 conv=notrunc status=none
# Создаем пространство диска в 10 МБ для будущих секторов ядра и игровых данных
dd if=/dev/zero of=build/os.img bs=512 count=20480 seek=1 conv=notrunc status=none

echo "--------------------------------------------------------"
echo "Сборка завершена успешно! Запуск QEMU..."
echo "Для выхода из QEMU закройте окно или нажмите Ctrl+C"
echo "--------------------------------------------------------"
qemu-system-x86_64 \
    -drive format=raw,file=build/os.img \
    -serial stdio \
    -m 128M
