// ==============================================================================
// Hollis-Bit's OS — Таблица дескрипторов прерываний (IDT) и контроллер PIC
// Файл: src/kernel/idt.zig
// Архитектура: x86_64
// Назначение: Инициализация IDT, переназначение прерываний PIC 8259,
//             настройка таймера PIT (IRQ 0) и обработка исключений процессора.
// ==============================================================================

// --- 16-байтный дескриптор прерывания IDT для 64-битного режима ---
pub const IdtEntry = extern struct {
    offset_low: u16,   // Биты 0..15 адреса обработчика
    selector: u16,     // Селектор сегмента кода GDT (0x08)
    ist: u8,           // Индекс стека прерывания (0 = стандартный стек)
    type_attr: u8,     // Атрибуты (0x8E = Present, Ring 0, 64-bit Interrupt Gate)
    offset_mid: u16,   // Биты 16..31 адреса обработчика
    offset_high: u32,  // Биты 32..63 адреса обработчика
    zero: u32 = 0,     // Зарезервировано, строго 0

    pub fn setHandler(self: *IdtEntry, handler_addr: usize) void {
        self.offset_low = @truncate(handler_addr);
        self.selector = 0x08; // Кодовый сегмент ядра
        self.ist = 0;
        self.type_attr = 0x8E; // Шлюз прерывания Ring 0
        self.offset_mid = @truncate(handler_addr >> 16);
        self.offset_high = @truncate(handler_addr >> 32);
        self.zero = 0;
    }
};

// Структура регистра IDTR для инструкции lidt (ровно 10 байт без выравнивания)
pub const IdtPointer = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

// Стек контекста процессора, сохраненный в interrupts.asm
pub const InterruptFrame = extern struct {
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9: u64, r8: u64,
    rbp: u64, rdi: u64, rsi: u64, rdx: u64,
    rcx: u64, rbx: u64, rax: u64,
    int_num: u64,
    err_code: u64,
    rip: u64, cs: u64, rflags: u64, rsp: u64, ss: u64,
};

// Сама таблица на 256 шлюзов прерываний
var idt_table: [256]IdtEntry = undefined;
var idt_ptr: IdtPointer = undefined;

// Счетчик тиков аппаратного таймера PIT
pub var system_ticks: u64 = 0;

// Импорт внешних ассемблерных стабов из interrupts.asm
extern fn isr0() void;  extern fn isr1() void;  extern fn isr2() void;  extern fn isr3() void;
extern fn isr4() void;  extern fn isr5() void;  extern fn isr6() void;  extern fn isr7() void;
extern fn isr8() void;  extern fn isr9() void;  extern fn isr10() void; extern fn isr11() void;
extern fn isr12() void; extern fn isr13() void; extern fn isr14() void; extern fn isr15() void;
extern fn isr16() void; extern fn isr17() void; extern fn isr18() void; extern fn isr19() void;
extern fn isr20() void; extern fn isr21() void; extern fn isr22() void; extern fn isr23() void;
extern fn isr24() void; extern fn isr25() void; extern fn isr26() void; extern fn isr27() void;
extern fn isr28() void; extern fn isr29() void; extern fn isr30() void; extern fn isr31() void;

extern fn irq0() void;  extern fn irq1() void;  extern fn irq2() void;  extern fn irq3() void;
extern fn irq4() void;  extern fn irq5() void;  extern fn irq6() void;  extern fn irq7() void;
extern fn irq8() void;  extern fn irq9() void;  extern fn irq10() void; extern fn irq11() void;
extern fn irq12() void; extern fn irq13() void; extern fn irq14() void; extern fn irq15() void;

// Имена 32 стандартных исключений процессора
const exception_names = [32][]const u8{
    "#DE: Divide-by-Zero",
    "#DB: Debug",
    "NMI: Non-Maskable Interrupt",
    "#BP: Breakpoint",
    "#OF: Overflow",
    "#BR: Bound Range Exceeded",
    "#UD: Invalid Opcode",
    "#NM: Device Not Available",
    "#DF: Double Fault",
    "Coprocessor Segment Overrun",
    "#TS: Invalid TSS",
    "#NP: Segment Not Present",
    "#SS: Stack-Segment Fault",
    "#GP: General Protection Fault",
    "#PF: Page Fault",
    "Reserved",
    "#MF: x87 FPU Floating-Point Error",
    "#AC: Alignment Check",
    "#MC: Machine Check",
    "#XM: SIMD Floating-Point Exception",
    "#VE: Virtualization Exception",
    "#CP: Control Protection Exception",
    "Reserved", "Reserved", "Reserved", "Reserved",
    "Reserved", "Reserved",
    "#HV: Hypervisor Injection Exception",
    "#VC: VMM Communication Exception",
    "#SX: Security Exception",
    "Reserved",
};

// ==============================================================================
// УПРАВЛЕНИЕ АППАРАТНЫМИ ПОРТАМИ (PIC 8259 И PIT ТАЙМЕР)
// ==============================================================================

inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[p]" : : [val] "{al}" (val), [p] "{dx}" (port));
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[ret]" : [ret] "={al}" (-> u8), : [p] "{dx}" (port));
}

/// Переназначение векторов контроллера прерываний PIC 8259
/// Master PIC: векторы 0x20..0x27 (32..39), Slave PIC: 0x28..0x2F (40..47)
fn remapPic() void {
    // Сохраняем маски прерываний
    const a1 = inb(0x21);
    const a2 = inb(0xA1);

    // ICW1: инициализация контроллера
    outb(0x20, 0x11);
    outb(0xA0, 0x11);

    // ICW2: смещение векторов прерываний (32 для Master, 40 для Slave)
    outb(0x21, 0x20);
    outb(0xA1, 0x28);

    // ICW3: связывание Master и Slave через IRQ 2
    outb(0x21, 0x04);
    outb(0xA1, 0x02);

    // ICW4: режим 8086
    outb(0x21, 0x01);
    outb(0xA1, 0x01);

    // Восстанавливаем маски: разрешаем IRQ 0 (таймер) и IRQ 1 (клавиатура)
    outb(0x21, a1 & ~@as(u8, 0x03));
    outb(0xA1, a2);
}

/// Отправка подтверждения обработки прерывания (End of Interrupt) в PIC
fn sendEoi(irq_num: u8) void {
    if (irq_num >= 8) {
        outb(0xA0, 0x20); // EOI в Slave PIC
    }
    outb(0x20, 0x20);     // EOI в Master PIC
}

/// Настройка системного таймера PIT (Programmable Interval Timer) на частоту 100 Гц (каждые 10 мс)
fn initPitTimer(frequency_hz: u32) void {
    const divisor: u16 = @truncate(1193180 / frequency_hz);
    outb(0x43, 0x36); // Канал 0, режим 3 (генератор меандра), двоичный счет
    outb(0x40, @truncate(divisor & 0xFF));
    outb(0x40, @truncate((divisor >> 8) & 0xFF));
}

// ==============================================================================
// ИНИЦИАЛИЗАЦИЯ ТАБЛИЦЫ IDT
// ==============================================================================

pub fn init() void {
    // 1. Заполняем 32 шлюза для исключений процессора
    const isrs = [_]usize{
        @intFromPtr(&isr0),  @intFromPtr(&isr1),  @intFromPtr(&isr2),  @intFromPtr(&isr3),
        @intFromPtr(&isr4),  @intFromPtr(&isr5),  @intFromPtr(&isr6),  @intFromPtr(&isr7),
        @intFromPtr(&isr8),  @intFromPtr(&isr9),  @intFromPtr(&isr10), @intFromPtr(&isr11),
        @intFromPtr(&isr12), @intFromPtr(&isr13), @intFromPtr(&isr14), @intFromPtr(&isr15),
        @intFromPtr(&isr16), @intFromPtr(&isr17), @intFromPtr(&isr18), @intFromPtr(&isr19),
        @intFromPtr(&isr20), @intFromPtr(&isr21), @intFromPtr(&isr22), @intFromPtr(&isr23),
        @intFromPtr(&isr24), @intFromPtr(&isr25), @intFromPtr(&isr26), @intFromPtr(&isr27),
        @intFromPtr(&isr28), @intFromPtr(&isr29), @intFromPtr(&isr30), @intFromPtr(&isr31),
    };

    for (isrs, 0..) |handler, i| {
        idt_table[i].setHandler(handler);
    }

    // 2. Переназначаем PIC контроллер
    remapPic();

    // 3. Заполняем 16 шлюзов для аппаратных IRQ прерываний (векторы 32..47)
    const irqs = [_]usize{
        @intFromPtr(&irq0),  @intFromPtr(&irq1),  @intFromPtr(&irq2),  @intFromPtr(&irq3),
        @intFromPtr(&irq4),  @intFromPtr(&irq5),  @intFromPtr(&irq6),  @intFromPtr(&irq7),
        @intFromPtr(&irq8),  @intFromPtr(&irq9),  @intFromPtr(&irq10), @intFromPtr(&irq11),
        @intFromPtr(&irq12), @intFromPtr(&irq13), @intFromPtr(&irq14), @intFromPtr(&irq15),
    };

    for (irqs, 0..) |handler, i| {
        idt_table[32 + i].setHandler(handler);
    }

    // 4. Загружаем указатель IDT в регистр процессора IDTR
    idt_ptr = IdtPointer{
        .limit = @sizeOf(@TypeOf(idt_table)) - 1,
        .base = @intFromPtr(&idt_table),
    };

    asm volatile ("lidt (%[p])" : : [p] "r" (&idt_ptr));

    // 5. Запускаем системный таймер PIT на частоту 100 Гц (100 тиков в секунду)
    initPitTimer(100);
}

// ==============================================================================
// ГЛАВНЫЙ ДИСПЕТЧЕР ПРЕРЫВАНИЙ (ВЫЗЫВАЕТСЯ ИЗ INTERRUPTS.ASM)
// ==============================================================================

export fn interrupt_dispatch(frame: *const InterruptFrame) callconv(.c) void {
    // 1. Аппаратное прерывание IRQ 0 (Таймер PIT)
    if (frame.int_num == 32) {
        system_ticks += 1;
        sendEoi(0);
        return;
    }

    // 2. Аппаратное прерывание IRQ 1 (Клавиатура)
    if (frame.int_num == 33) {
        // Подтверждаем получение сигнала
        sendEoi(1);
        return;
    }

    // 3. Остальные аппаратные прерывания IRQ
    if (frame.int_num >= 32 and frame.int_num < 48) {
        sendEoi(@truncate(frame.int_num - 32));
        return;
    }

    // 4. Исключение процессора (0..31): КРИТИЧЕСКИЙ СБОЙ (Kernel Panic)
    handlePanic(frame);
}

/// Вывод экрана аварийного останова ядра (Kernel Panic) с дампом регистров
fn handlePanic(frame: *const InterruptFrame) noreturn {
    const vga: [*]volatile u16 = @ptrFromInt(0xB8000);
    const panic_color: u16 = 0x4F00; // Белый текст на красном фоне (Red Screen of Death)

    // Очищаем экран красным цветом
    for (0..(80 * 25)) |i| {
        vga[i] = panic_color | ' ';
    }

    printPanicAt(1, 22, "!!! KERNEL PANIC: CPU EXCEPTION !!!");

    const exc_name = if (frame.int_num < 32) exception_names[frame.int_num] else "Unknown Exception";
    printPanicAt(3, 4, "Exception: ");
    printPanicString(exc_name);

    printPanicAt(5, 4, "--- CPU REGISTER DUMP ---");

    var buf: [32]u8 = undefined;
    printPanicAt(7, 4, "RIP: 0x");
    printPanicHex(frame.rip, &buf);

    printPanicAt(8, 4, "RSP: 0x");
    printPanicHex(frame.rsp, &buf);

    printPanicAt(9, 4, "RAX: 0x");
    printPanicHex(frame.rax, &buf);

    printPanicAt(10, 4, "RBX: 0x");
    printPanicHex(frame.rbx, &buf);

    printPanicAt(11, 4, "RCX: 0x");
    printPanicHex(frame.rcx, &buf);

    printPanicAt(12, 4, "RDX: 0x");
    printPanicHex(frame.rdx, &buf);

    printPanicAt(14, 4, "Error Code: ");
    printPanicHex(frame.err_code, &buf);

    printPanicAt(16, 4, "System halted. Please reboot virtual machine.");

    // Отправляем лог ошибки в COM1 Serial
    outb(0x3F8, '\r');
    outb(0x3F8, '\n');
    for ("\r\n[KERNEL PANIC] CPU Exception triggered: ") |c| outb(0x3F8, c);
    for (exc_name) |c| outb(0x3F8, c);
    for ("\r\n") |c| outb(0x3F8, c);

    while (true) {
        asm volatile ("cli; hlt");
    }
}

var panic_row: usize = 0;
var panic_col: usize = 0;

fn printPanicAt(row: usize, col: usize, text: []const u8) void {
    panic_row = row;
    panic_col = col;
    printPanicString(text);
}

fn printPanicString(text: []const u8) void {
    const vga: [*]volatile u16 = @ptrFromInt(0xB8000);
    const panic_color: u16 = 0x4F00;
    for (text) |c| {
        vga[panic_row * 80 + panic_col] = panic_color | c;
        panic_col += 1;
        outb(0x3F8, c);
    }
}

fn printPanicHex(val: u64, buf: *[32]u8) void {
    const hex_digits = "0123456789ABCDEF";
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex_digits[@truncate(v & 0x0F)];
        v >>= 4;
    }
    printPanicString(buf[0..16]);
}
