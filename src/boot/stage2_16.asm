; ==============================================================================
; Hollis-Bit's OS — Вторая стадия загрузчика (16-бит -> 32-бит -> 64-бит Long Mode)
; Файл: src/boot/stage2_16.asm
; Адрес загрузки: 0x7E00
; Назначение: Быстрый, бесшовный переход от 16-битного BIOS через 32-битный PM
;             прямо в 64-битный Long Mode с пейджингом PML4 и передачей управления ядру.
; ==============================================================================

[bits 16]
[org 0x7e00]

stage2_entry:
    ; 1. Настройка сегментов и стека в 16-битном режиме
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    sti

    mov [boot_drive], dl

    ; 2. Вывод быстрого стартового статуса
    mov si, msg_boot_start
    call print_string_16

    ; 3. Проверка и включение адресной линии A20
    call check_a20
    cmp ax, 1
    je .a20_ready
    in al, 0x92
    or al, 00000010b    ; Fast A20
    out 0x92, al
.a20_ready:

    ; 4. Определение ОЗУ через BIOS E820
    call detect_memory_e820

    ; 5. Сообщение о переходе в 64-битный режим (без искусственных пауз)
    mov si, msg_jumping_64
    call print_string_16

    ; 6. Отключаем прерывания перед переходом в Защищенный Режим
    cli

    ; 7. Загружаем временную 32-битную GDT
    lgdt [gdt32_descriptor]

    ; 8. Включаем Protection Enable (PE) в CR0
    mov eax, cr0
    or eax, 1
    mov cr0, eax

    ; 9. Дальний переход в 32-битный Защищенный Режим
    jmp 0x08:pmode_32_entry


; ==============================================================================
; 16-БИТНЫЕ ПОДПРОГРАММЫ
; ==============================================================================

check_a20:
    pushf
    push ds
    push es
    push di
    push si
    cli
    xor ax, ax
    mov es, ax
    not ax
    mov ds, ax
    mov di, 0x7dfe
    mov si, 0x7e0e
    mov al, [es:di]
    push ax
    mov al, [ds:si]
    pop bx
    cmp al, bl
    jne .a20_on
    mov ax, 0
    jmp .a20_done
.a20_on:
    mov ax, 1
.a20_done:
    pop si
    pop di
    pop es
    pop ds
    popf
    ret

detect_memory_e820:
    xor ebx, ebx
    mov dword [total_mb], 0
.e820_loop:
    mov eax, 0xe820
    mov edx, 0x534d4150
    mov ecx, 24
    mov di, e820_buf
    int 0x15
    jc .done
    cmp dword [e820_buf + 16], 1   ; Usable RAM
    jne .next
    mov eax, [e820_buf + 8]         ; Длина блока
    shr eax, 20                     ; Байты в Мегабайты
    add [total_mb], eax
.next:
    test ebx, ebx
    jz .done
    jmp .e820_loop
.done:
    ret

print_string_16:
    push ax
    push dx
.loop:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0e
    mov bh, 0x00
    mov bl, 0x07
    int 0x10
    mov dx, 0x3f8
    out dx, al
    jmp .loop
.done:
    pop dx
    pop ax
    ret


; ==============================================================================
; 32-БИТНЫЙ МОСТ: НАСТРОЙКА 4-УРОВНЕВОГО ПЕЙДЖИНГА (PML4) И ПРЫЖОК В 64-БИТ
; ==============================================================================
[bits 32]

pmode_32_entry:
    ; 1. Настройка 32-битных сегментов данных
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    ; 2. Проверка поддержки Long Mode через CPUID
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb .cpu_halt

    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29       ; Бит 29 = Long Mode поддержка
    jz .cpu_halt

    ; 3. Построение 4-уровневых таблиц страниц (PML4)
    ; Обнуляем область памяти под таблицы страниц (0x1000 .. 0x4000 = 12 КБ)
    mov edi, 0x1000
    mov cr3, edi            ; Адрес корневой таблицы PML4 = 0x1000
    xor eax, eax
    mov ecx, 3072           ; 12 КБ / 4 байта = 3072 DWORD
    rep stosd

    ; Корневая таблица PML4 (0x1000): указывает на PDPT (0x2000)
    ; Атрибуты 0x03 = Present (присутствует) | Writable (запись разрешена)
    mov dword [0x1000], 0x2000 | 0x03

    ; Таблица PDPT (0x2000): указывает на Page Directory (0x3000)
    mov dword [0x2000], 0x3000 | 0x03

    ; Каталог страниц Page Directory (0x3000): отображает первые 32 МБ ОЗУ (2MB Huge Pages)
    ; Атрибуты 0x83 = Present | Writable | Page Size 2MB (Huge Page)
    mov edi, 0x3000
    mov eax, 0x000000 | 0x83
    mov ecx, 16             ; 16 записей по 2 МБ = 32 МБ виртуальной памяти 1-в-1
.map_pd:
    mov [edi], eax
    add eax, 0x200000       ; Следующий блок 2 МБ
    add edi, 8              ; Каждая запись 64-битная (8 байт)
    loop .map_pd

    ; 4. Включение физического расширения адресов (PAE) в регистре CR4
    mov eax, cr4
    or eax, 1 << 5          ; Бит 5 = PAE
    mov cr4, eax

    ; 5. Активация Long Mode (LME) в регистре EFER MSR (0xC0000080)
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8          ; Бит 8 = LME (Long Mode Enable)
    wrmsr

    ; 6. Включение пейджинга (PG) и защиты (PE) в регистре CR0
    mov eax, cr0
    or eax, 0x80000001      ; Бит 31 = Paging (PG), Бит 0 = Protected Mode (PE)
    mov cr0, eax

    ; 7. Загрузка финальной 64-битной GDT
    lgdt [gdt64_descriptor]

    ; 8. Дальний переход в чистый 64-битный Long Mode!
    jmp 0x08:long_mode_entry

.cpu_halt:
    hlt
    jmp .cpu_halt


; ==============================================================================
; 64-БИТНЫЙ LONG MODE: ПЕРЕДАЧА ЭСТАФЕТЫ ЯДРУ
; ==============================================================================
[bits 64]

long_mode_entry:
    ; 1. Настройка 64-битных сегментов данных
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; 2. Вершина 64-битного стека ядра
    mov rsp, 0x90000

    ; 3. Копирование бинарника ядра из буфера 0x20000 по базовому адресу 0x100000 (1 МБ)
    cld
    mov rsi, 0x20000        ; Откуда: куда BIOS считал kernel.bin
    mov rdi, 0x100000       ; Куда: базовый адрес ядра из linker.ld (1 МБ)
    mov rcx, 4096           ; 4096 * 8 байт = 32 КБ
    rep movsq

    ; 4. Прыжок на точку входа ядра (entry.asm -> _start -> kmain в Zig)!
    mov rax, 0x100000
    jmp rax


; ==============================================================================
; ТАБЛИЦЫ GDT И ДАННЫЕ
; ==============================================================================
boot_drive:         db 0
total_mb:           dd 0
e820_buf:           times 24 db 0

msg_boot_start:
    db "[BOOT] Hollis-Bit's OS: 16-bit BIOS active.", 13, 10, 0
msg_jumping_64:
    db "[BOOT] Fast switch: 16-bit -> 32-bit PM -> 64-bit Long Mode (PML4)...", 13, 10, 0

; --- 32-битная временная GDT ---
align 8
gdt32_start:
    dd 0, 0
    ; Селектор 0x08: Code 32-bit (Ring 0)
    dw 0xffff, 0x0000
    db 0x00, 10011010b, 11001111b, 0x00
    ; Селектор 0x10: Data 32-bit (Ring 0)
    dw 0xffff, 0x0000
    db 0x00, 10010010b, 11001111b, 0x00
gdt32_end:

gdt32_descriptor:
    dw gdt32_end - gdt32_start - 1
    dd gdt32_start

; --- 64-битная постоянная GDT ---
align 8
gdt64_start:
    dd 0, 0
    ; Селектор 0x08: 64-битный Code Segment (L = 1, D = 0)
    dw 0x0000, 0x0000
    db 0x00, 10011010b, 00100000b, 0x00
    ; Селектор 0x10: 64-битный Data Segment
    dw 0x0000, 0x0000
    db 0x00, 10010010b, 00000000b, 0x00
gdt64_end:

gdt64_descriptor:
    dw gdt64_end - gdt64_start - 1
    dd gdt64_start

; Выравниваем размер Stage 2 до ровно 16 секторов (8192 байта)
times 8192 - ($ - $$) db 0
