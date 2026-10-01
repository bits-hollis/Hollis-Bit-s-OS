; ==============================================================================
; Hollis-Bit's OS — Главная точка входа ядра на Ассемблере
; Файл: src/kernel/entry.asm
; Архитектура: 64-бит (x86_64 ELF)
; ==============================================================================

[bits 64]

; Экспортируем глобальную точку входа для компоновщика (линкера)
global _start

; Импортируем тяжелые функции из Zig
extern zig_heavy_init

section .text

_start:
    ; 1. Настройка стека ядра в 64-битном режиме
    ; Выделяем вершину стека по безопасному адресу 0x90000
    mov rsp, 0x90000

    ; 2. Вывод приветствия на экран напрямую на ASM через видеопамять VGA (0xB8000)
    call asm_clear_screen
    mov rsi, asm_banner
    mov rdi, 1          ; Строка 1
    mov rdx, 10         ; Столбец 10
    mov bl, 0x0A        ; Зеленый цвет текста
    call asm_print_at

    mov rsi, asm_subtext
    mov rdi, 3          ; Строка 3
    mov rdx, 2          ; Столбец 2
    mov bl, 0x0F        ; Белый цвет текста
    call asm_print_at

    ; 3. Вызов тяжелой подсистемы, написанной на Zig
    ; Ассемблер передает управление Zig-коду для сложных расчетов и логики
    call zig_heavy_init

    ; 4. Бесконечный цикл ожидания прерываний процессора (hlt)
.halt:
    hlt
    jmp .halt


; --- Очистка экрана VGA 80x25 пробелами на чистом ASM ---
asm_clear_screen:
    mov rdi, 0xB8000
    mov rcx, 80 * 25
    mov ax, 0x0720      ; 0x20 = пробел, 0x07 = светло-серый цвет на черном фоне
    rep stosw           ; Заполняем весь экран 16-битными словами
    ret

; --- Печать строки на ASM (RSI: адрес строки, RDI: строка, RDX: столбец, BL: цвет) ---
asm_print_at:
    push rbx
    imul rdi, 80        ; Вычисляем смещение: строка * 80
    add rdi, rdx        ; + столбец
    shl rdi, 1          ; Умножаем на 2 (каждое знакоместо занимает 2 байта)
    add rdi, 0xB8000    ; Прибавляем базовый адрес видеопамяти VGA

.loop:
    lodsb               ; Читаем символ из [RSI] в AL
    test al, al         ; Конец строки (ноль)?
    jz .done
    mov ah, bl          ; Байт цвета в AH
    mov [rdi], ax       ; Записываем символ + цвет прямо в видеопамять
    add rdi, 2          ; Переходим к следующему знакоместу
    jmp .loop

.done:
    pop rbx
    ret


section .data
asm_banner:
    db "=== HOLLIS-BIT's OS -- 64-BIT ASM CORE ACTIVE ===", 0

asm_subtext:
    db "[ASM-CORE] Low-level engine & hardware control handled by Assembly.", 0
