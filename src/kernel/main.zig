// ==============================================================================
// Hollis-Bit's OS — Модуль сложной логики ядра на Zig
// Файл: src/kernel/main.zig
// Назначение: Вызывается из ассемблера (entry.asm) для тяжелых вычислений,
//             управления памятью, парсеров файлов (WAD/PAK) и логики игр.
// ==============================================================================

const VGA_MEMORY: usize = 0xB8000;
const VGA_WIDTH: usize = 80;

// --- Вывод байта в аппаратный порт (COM1 Serial 0x3F8) ---
inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[val], %[p]"
        :
        : [val] "{al}" (value),
          [p] "{dx}" (port),
    );
}

fn serialPrint(text: []const u8) void {
    for (text) |ch| outb(0x3F8, ch);
}

// --- Вывод строки на экран VGA по координатам (строка, колонка, цвет) ---
fn printVgaAt(row: usize, col: usize, text: []const u8, color_attr: u8) void {
    const buffer: [*]volatile u16 = @ptrFromInt(VGA_MEMORY);
    var c = col;
    for (text) |ch| {
        if (c >= VGA_WIDTH) break;
        const entry = @as(u16, ch) | (@as(u16, color_attr) << 8);
        buffer[row * VGA_WIDTH + c] = entry;
        c += 1;
    }
}

// --- Экспортируемая функция тяжелой инициализации для вызова из ASM ---
export fn zig_heavy_init() callconv(.c) void {
    // 1. Вывод информации о подключении подсистемы Zig
    const color_cyan: u8 = 0x0B;  // Ярко-голубой
    const color_yellow: u8 = 0x0E; // Желтый

    printVgaAt(5, 2, "[ZIG-HEAVY] Logic subsystem connected to ASM core!", color_cyan);
    printVgaAt(6, 2, "[GAMING]    Preparing Doom/Quake C-runtime & Game Engine.", color_yellow);

    // 2. Отладочный лог в COM1 последовательный порт (терминал хоста)
    serialPrint("\r\n[Hollis-Bit OS] ASM Core -> Zig Heavy Subsystem Bridge OK!\r\n");
    serialPrint("[Hollis-Bit OS] Stage 0 Ready for Stage 1 Boot sequence.\r\n");
}
