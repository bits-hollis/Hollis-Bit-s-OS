// ==============================================================================
// Hollis-Bit's OS — build.zig
// Сборка и запуск Этапа 2 (Прерывания IDT, таймер PIT, ядро Zig)
// ==============================================================================

const std = @import("std");

pub fn build(b: *std.Build) void {
    // 1. Шаг сборки по умолчанию (команда: zig build)
    const build_cmd = b.addSystemCommand(&.{
        "bash", "-c",
        \\mkdir -p build && \
        \\nasm -f bin src/boot/boot.asm -o build/boot.bin && \
        \\nasm -f bin src/boot/stage2_16.asm -o build/stage2_16.bin && \
        \\nasm -f elf64 src/kernel/entry.asm -o build/entry.o && \
        \\nasm -f elf64 src/kernel/interrupts.asm -o build/interrupts.o && \
        \\zig build-obj -target x86_64-freestanding-none -O ReleaseSmall src/kernel/main.zig -femit-bin=build/main.o && \
        \\ld -m elf_x86_64 -T src/linker.ld build/entry.o build/interrupts.o build/main.o -o build/kernel.elf && \
        \\objcopy -O binary build/kernel.elf build/kernel.bin && \
        \\dd if=build/boot.bin of=build/os.img bs=512 count=1 conv=notrunc status=none && \
        \\dd if=build/stage2_16.bin of=build/os.img bs=512 seek=1 count=16 conv=notrunc status=none && \
        \\dd if=build/kernel.bin of=build/os.img bs=512 seek=17 count=64 conv=notrunc status=none && \
        \\dd if=/dev/zero of=build/os.img bs=512 count=20480 seek=81 conv=notrunc status=none
    });

    b.default_step.dependOn(&build_cmd.step);

    // 2. Шаг запуска (команда: zig build run)
    const run_step = b.step("run", "Запуск Hollis-Bit's OS (Stage 2: Interrupts & PIT) в QEMU");
    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-drive", "format=raw,file=build/os.img",
        "-serial", "stdio",
        "-m", "128M",
    });

    run_cmd.step.dependOn(&build_cmd.step);
    run_step.dependOn(&run_cmd.step);
}
