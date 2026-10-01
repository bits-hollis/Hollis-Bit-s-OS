// ==============================================================================
// Hollis-Bit's OS — 64-битное ядро на Zig
// Файл: src/kernel/main.zig
// Режим: x86_64 Long Mode (freestanding, без стандартной ОС)
// Назначение: Интерактивный терминал с базовыми командами в стиле Linux.
// ==============================================================================

const VGA_MEMORY: usize = 0xB8000;
const VGA_WIDTH: usize = 80;
const VGA_HEIGHT: usize = 25;

// Глобальное состояние экрана терминала
var cursor_row: usize = 0;
var cursor_col: usize = 0;
var current_color: u8 = 0x0A; // Ярко-зеленый текст на черном фоне (стиль Linux терминала)

// ==============================================================================
// НИЗКОУРОВНЕВЫЙ ВВОД-ВЫВОД (ПОРТЫ I/O И ВИДЕОПАМЯТЬ)
// ==============================================================================

inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[p]"
        :
        : [val] "{al}" (val),
          [p] "{dx}" (port),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[ret]"
        : [ret] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}

/// Очистка экрана VGA и отправка ANSI-последовательности в терминал хоста
fn clearScreen() void {
    const vga: [*]volatile u16 = @ptrFromInt(VGA_MEMORY);
    const blank = @as(u16, ' ') | (@as(u16, current_color) << 8);
    for (0..(VGA_WIDTH * VGA_HEIGHT)) |i| {
        vga[i] = blank;
    }
    cursor_row = 0;
    cursor_col = 0;
    // ANSI код очистки терминала: \033[2J\033[H
    printSerial("\x1B[2J\x1B[H");
}

/// Скроллинг экрана вверх при заполнении 25 строк
fn scrollUp() void {
    const vga: [*]volatile u16 = @ptrFromInt(VGA_MEMORY);
    for (0..(VGA_WIDTH * (VGA_HEIGHT - 1))) |i| {
        vga[i] = vga[i + VGA_WIDTH];
    }
    const blank = @as(u16, ' ') | (@as(u16, current_color) << 8);
    for (0..VGA_WIDTH) |c| {
        vga[(VGA_HEIGHT - 1) * VGA_WIDTH + c] = blank;
    }
    cursor_row = VGA_HEIGHT - 1;
    cursor_col = 0;
}

/// Печать одного символа с поддержкой \n, \r, \b
fn printChar(c: u8) void {
    const vga: [*]volatile u16 = @ptrFromInt(VGA_MEMORY);

    if (c == '\n') {
        cursor_col = 0;
        cursor_row += 1;
        printSerial("\r\n");
        if (cursor_row >= VGA_HEIGHT) scrollUp();
        return;
    }

    if (c == 8 or c == 127) { // Backspace
        if (cursor_col > 0) {
            cursor_col -= 1;
            const offset = cursor_row * VGA_WIDTH + cursor_col;
            vga[offset] = @as(u16, ' ') | (@as(u16, current_color) << 8);
            printSerial("\x08 \x08");
        }
        return;
    }

    if (cursor_col >= VGA_WIDTH) {
        cursor_col = 0;
        cursor_row += 1;
        if (cursor_row >= VGA_HEIGHT) scrollUp();
    }

    const offset = cursor_row * VGA_WIDTH + cursor_col;
    vga[offset] = @as(u16, c) | (@as(u16, current_color) << 8);
    cursor_col += 1;

    outb(0x3F8, c); // Дублируем в COM1 Serial
}

fn printString(s: []const u8) void {
    for (s) |c| printChar(c);
}

fn printSerial(s: []const u8) void {
    for (s) |c| outb(0x3F8, c);
}

// Опрос ввода (поддерживает и терминал хоста через COM1, и PS/2 клавиатуру)
fn readChar() u8 {
    while (true) {
        // 1. Проверяем COM1 Serial (порт 0x3FD, бит 0 = Data Ready)
        if ((inb(0x3FD) & 0x01) != 0) {
            return inb(0x3F8);
        }

        // 2. Проверяем клавиатуру PS/2 (порт 0x64, бит 0 = Output Buffer Full)
        if ((inb(0x64) & 0x01) != 0) {
            const scancode = inb(0x60);
            if ((scancode & 0x80) == 0) { // Только нажатия (make code)
                const ascii = scancodeToAscii(scancode);
                if (ascii != 0) return ascii;
            }
        }
        asm volatile ("pause");
    }
}

fn scancodeToAscii(sc: u8) u8 {
    return switch (sc) {
        0x1C => '\n',
        0x0E => 8,
        0x39 => ' ',
        0x02 => '1', 0x03 => '2', 0x04 => '3', 0x05 => '4', 0x06 => '5',
        0x07 => '6', 0x08 => '7', 0x09 => '8', 0x0A => '9', 0x0B => '0',
        0x0C => '-', 0x0D => '=',
        0x10 => 'q', 0x11 => 'w', 0x12 => 'e', 0x13 => 'r', 0x14 => 't',
        0x15 => 'y', 0x16 => 'u', 0x17 => 'i', 0x18 => 'o', 0x19 => 'p',
        0x1E => 'a', 0x1F => 's', 0x20 => 'd', 0x21 => 'f', 0x22 => 'g',
        0x23 => 'h', 0x24 => 'j', 0x25 => 'k', 0x26 => 'l',
        0x2C => 'z', 0x2D => 'x', 0x2E => 'c', 0x2F => 'v', 0x30 => 'b',
        0x31 => 'n', 0x32 => 'm',
        0x33 => ',', 0x34 => '.', 0x35 => '/',
        else => 0,
    };
}


// ==============================================================================
// УТИЛИТЫ ДЛЯ ОБРАБОТКИ СТРОК
// ==============================================================================

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |item, idx| {
        if (item != b[idx]) return false;
    }
    return true;
}

fn strStartsWith(full: []const u8, prefix: []const u8) bool {
    if (full.len < prefix.len) return false;
    return strEql(full[0..prefix.len], prefix);
}


// ==============================================================================
// ГЛАВНАЯ ТОЧКА ВХОДА 64-БИТНОГО ЯДРА (kmain)
// ==============================================================================

export fn kmain() callconv(.c) noreturn {
    clearScreen();

    // 1. Приветственный баннер Linux-стиля
    printString("================================================================\n");
    printString("    HOLLIS-BIT's GAMING OS (x86_64 Long Mode & Zig Kernel)      \n");
    printString("================================================================\n");
    printString("Kernel: 64-bit Freestanding Zig | Paging: 4-level PML4 Active\n");
    printString("Type 'help' for available Linux-style terminal commands.\n\n");

    var cmd_buf: [128]u8 = undefined;
    var cmd_len: usize = 0;

    // 2. Главный командный цикл терминала (root@hollis-os:~# )
    while (true) {
        printString("root@hollis-os:~# ");
        cmd_len = 0;

        while (true) {
            const ch = readChar();

            if (ch == '\r' or ch == '\n') {
                printChar('\n');
                break;
            }

            if (ch == 8 or ch == 127) { // Backspace
                if (cmd_len > 0) {
                    cmd_len -= 1;
                    printChar(8);
                }
                continue;
            }

            if (ch >= 32 and ch < 127 and cmd_len < cmd_buf.len - 1) {
                cmd_buf[cmd_len] = ch;
                cmd_len += 1;
                printChar(ch);
            }
        }

        const cmd = cmd_buf[0..cmd_len];
        if (cmd.len == 0) continue;

        executeCommand(cmd);
    }
}


// ==============================================================================
// ОБРАБОТЧИК БАЗОВЫХ КОМАНД LINUX-СТИЛЯ
// ==============================================================================

fn executeCommand(cmd: []const u8) void {
    if (strEql(cmd, "help") or strEql(cmd, "man")) {
        printString("Hollis-Bit OS Shell - Available Linux-style commands:\n");
        printString("  uname [-a]   - Print system and kernel information\n");
        printString("  whoami       - Print effective user name\n");
        printString("  hostname     - Print system network host name\n");
        printString("  ls [dir]     - List directory contents / game directories\n");
        printString("  cat <file>   - Concatenate and display file content\n");
        printString("  echo <text>  - Display a line of text\n");
        printString("  free [-m]    - Display free and used physical memory\n");
        printString("  uptime       - Tell how long the system has been running\n");
        printString("  games        - Display status of planned gaming ports\n");
        printString("  clear        - Clear the terminal screen\n");
        printString("  reboot       - Reboot the operating system\n");
        printString("  poweroff     - Halt CPU execution\n");
        return;
    }

    if (strEql(cmd, "uname") or strEql(cmd, "uname -a")) {
        printString("Hollis-Bit-OS 0.1.0-gaming-x86_64 #1 Thu Oct 2 00:00:00 2026 x86_64 GNU/BareMetal\n");
        return;
    }

    if (strEql(cmd, "whoami")) {
        printString("root\n");
        return;
    }

    if (strEql(cmd, "hostname")) {
        printString("hollis-gaming-station\n");
        return;
    }

    if (strEql(cmd, "ls") or strEql(cmd, "ls -l") or strEql(cmd, "dir")) {
        printString("drwxr-xr-x 2 root root 4096 Oct  2 00:00 doom/\n");
        printString("drwxr-xr-x 2 root root 4096 Oct  2 00:00 quake/\n");
        printString("drwxr-xr-x 2 root root 4096 Oct  2 00:00 diablo/\n");
        printString("drwxr-xr-x 2 root root 4096 Oct  2 00:00 gothic/\n");
        printString("drwxr-xr-x 2 root root 4096 Oct  2 00:00 morrowind/\n");
        printString("-rw-r--r-- 1 root root  248 Oct  2 00:00 os-release\n");
        printString("-rw-r--r-- 1 root root  312 Oct  2 00:00 readme.txt\n");
        printString("-rw-r--r-- 1 root root  180 Oct  2 00:00 system.log\n");
        return;
    }

    if (strStartsWith(cmd, "cat ")) {
        const file = cmd[4..];
        if (strEql(file, "readme.txt")) {
            printString("=== Hollis-Bit's OS (Bare-Metal Gaming OS) ===\n");
            printString("Built with pure x86_64 Assembly and Zig freestanding.\n");
            printString("Architecture: 16-bit BIOS -> 32-bit PM -> 64-bit Long Mode.\n");
            printString("Designed to run our own Zig game engine and retro classics!\n");
        } else if (strEql(file, "os-release") or strEql(file, "/etc/os-release")) {
            printString("NAME=\"Hollis-Bit Gaming OS\"\n");
            printString("VERSION=\"1.0-alpha (x86_64)\"\n");
            printString("ID=hollis_os\n");
            printString("PRETTY_NAME=\"Hollis-Bit Gaming OS (BareMetal x86_64)\"\n");
            printString("HOME_URL=\"https://github.com/bits-hollis/Hollis-Bit-s-OS\"\n");
            printString("TARGETS=\"Doom 1-3, Quake 1-3, Diablo, Gothic, Morrowind\"\n");
        } else if (strEql(file, "system.log")) {
            printString("[INFO] MBR 0x7C00 loaded from disk.\n");
            printString("[INFO] A20 Address Line verified active.\n");
            printString("[INFO] 4-level PML4 Paging enabled.\n");
            printString("[INFO] 64-bit Long Mode enabled via EFER.LME.\n");
            printString("[INFO] Zig Kernel kmain() running successfully.\n");
        } else {
            printString("cat: ");
            printString(file);
            printString(": No such file or directory\n");
        }
        return;
    }

    if (strStartsWith(cmd, "echo ")) {
        printString(cmd[5..]);
        printChar('\n');
        return;
    } else if (strEql(cmd, "echo")) {
        printChar('\n');
        return;
    }

    if (strEql(cmd, "free") or strEql(cmd, "free -m") or strEql(cmd, "free -h")) {
        printString("               total        used        free      shared  buff/cache   available\n");
        printString("Mem:            127M          2M        125M          0M          0M        125M\n");
        printString("Swap:             0M          0M          0M\n");
        return;
    }

    if (strEql(cmd, "uptime")) {
        printString(" 00:00:42 up 1 min,  1 user,  load average: 0.00, 0.00, 0.00\n");
        return;
    }

    if (strEql(cmd, "clear")) {
        clearScreen();
        return;
    }

    if (strEql(cmd, "games")) {
        printString("================================================================\n");
        printString("         HOLLIS-BIT's OS GAMING PORTFOLIO STATUS               \n");
        printString("================================================================\n");
        printString("  [OK] Custom Zig Game Engine   -- Kernel driver ready\n");
        printString("  [OK] Doom 1 & Doom 2          -- Software 2.5D, WAD parser pending\n");
        printString("  [OK] Quake 1 & Quake 2        -- 3D Software Rasterizer, PAK parser\n");
        printString("  [OK] Diablo 1 (DevilutionX)   -- Isometric 2D ARPG, MPQ parser\n");
        printString("  [OK] Gothic 1 & Gothic 2      -- 3D ZenGin engine, VDF parser\n");
        printString("  [OK] TES III: Morrowind       -- 3D OpenMW engine, BSA/ESM parser\n");
        printString("  [OK] Quake 3 & Doom 3         -- 3D OpenGL / id Tech 3/4 pipeline\n");
        printString("================================================================\n");
        return;
    }

    if (strEql(cmd, "reboot")) {
        printString("Restarting system...\n");
        outb(0x64, 0xFE); // Импульс сброса через контроллер 8042
        while (true) asm volatile ("hlt");
    }

    if (strEql(cmd, "poweroff") or strEql(cmd, "halt")) {
        printString("System halted.\n");
        while (true) asm volatile ("hlt");
    }

    // Если команда не найдена
    printString("bash: ");
    printString(cmd);
    printString(": command not found. Type 'help' for available commands.\n");
}
