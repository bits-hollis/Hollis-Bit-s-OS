// ==============================================================================
// Hollis-Bit's OS — build.zig
// Автоматизация сборки и запуска ядра через стандартные команды Zig
// ==============================================================================

const std = @import("std");

pub fn build(b: *std.Build) void {
    // 1. Шаг сборки по умолчанию (команда: zig build)
    // Собирает загрузчик MBR, ассемблерное ядро, модуль Zig и упаковывает образ os.img
    const build_cmd = b.addSystemCommand(&.{
        "bash", "-c",
        \\mkdir -p build && \
        \\nasm -f bin src/boot/boot.asm -o build/boot.bin && \
        \\nasm -f elf64 src/kernel/entry.asm -o build/entry.o && \
        \\zig build-obj -target x86_64-freestanding-none -O ReleaseSmall src/kernel/main.zig -femit-bin=build/main.o && \
        \\ld -m elf_x86_64 -T src/linker.ld build/entry.o build/main.o -o build/kernel.elf && \
        \\objcopy -O binary build/kernel.elf build/kernel.bin && \
        \\dd if=build/boot.bin of=build/os.img bs=512 count=1 conv=notrunc status=none && \
        \\dd if=/dev/zero of=build/os.img bs=512 count=20480 seek=1 conv=notrunc status=none
    });

    b.default_step.dependOn(&build_cmd.step);

    // 2. Шаг запуска (команда: zig build run)
    // Запускает QEMU с полученным загрузочным образом диска
    const run_step = b.step("run", "Собрать и запустить Hollis-Bit's OS в эмуляторе QEMU");
    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-drive", "format=raw,file=build/os.img",
        "-serial", "stdio",
        "-m", "128M",
    });

    run_cmd.step.dependOn(&build_cmd.step);
    run_step.dependOn(&run_cmd.step);
}
