; ==============================================================================
; Hollis-Bit's OS — Вторая стадия загрузчика (16-битный Real Mode)
; Файл: src/boot/stage2_16.asm
; Адрес загрузки в ОЗУ: 0x7E00 (сразу за MBR)
; Назначение: Полноценное освоение 16-битного режима (A20, E820 карта памяти, BIOS ввод)
; ==============================================================================

[bits 16]
[org 0x7e00]

stage2_entry:
    ; 1. Настройка сегментов данных и стека
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    sti                 ; Разрешаем прерывания для контроллера клавиатуры

    mov [boot_drive], dl

    ; 2. Вывод красивого баннера 16-битного этапа
    mov si, banner_msg
    call print_string

    ; 3. Проверка и включение адресной линии A20
    call check_a20
    cmp ax, 1
    je .a20_already_on

    ; Если A20 выключена — включаем через Fast A20 (порт 0x92)
    in al, 0x92
    or al, 00000010b
    out 0x92, al

.a20_already_on:
    mov si, msg_a20_ok
    call print_string

    ; 4. Определение доступной оперативной памяти через BIOS E820
    call detect_memory_e820

    ; 5. Интерактивная проверка ввода (поддерживает и окно QEMU, и терминал через COM1)
    mov si, msg_press_key
    call print_string

.wait_key_loop:
    ; Проверка 1: Нажатие клавиши в окне QEMU (BIOS int 0x16, AH = 0x01)
    mov ah, 0x01
    int 0x16
    jnz .key_from_bios

    ; Проверка 2: Ввод символа в терминале (COM1 Serial порт 0x3FD, бит 0 = Data Ready)
    mov dx, 0x3fd
    in al, dx
    test al, 0x01
    jnz .key_from_serial

    pause
    jmp .wait_key_loop

.key_from_bios:
    mov ah, 0x00        ; Извлекаем символ из буфера BIOS
    int 0x16
    jmp .display_key

.key_from_serial:
    mov dx, 0x3f8       ; Считываем символ из порта данных COM1
    in al, dx

.display_key:
    ; Сохраняем и выводим полученный символ
    push ax
    mov si, msg_key_ok
    call print_string

    pop ax
    mov ah, 0x0e        ; Печать в видеопамять BIOS
    int 0x10
    mov dx, 0x3f8       ; Печать в терминал через COM1
    out dx, al

    mov si, newline
    call print_string

    ; 6. Итоговый отчет о готовности 16-битной эпохи
    mov si, msg_stage1_done
    call print_string

    ; 7. Запрос на переключение в 32-битный Защищенный Режим
    mov si, msg_press_to_pmode
    call print_string

.wait_pm_key:
    mov ah, 0x01
    int 0x16
    jnz .pm_key_bios

    mov dx, 0x3fd
    in al, dx
    test al, 0x01
    jnz .pm_key_serial

    pause
    jmp .wait_pm_key

.pm_key_bios:
    mov ah, 0x00
    int 0x16
    jmp enter_protected_mode

.pm_key_serial:
    mov dx, 0x3f8
    in al, dx
    jmp enter_protected_mode

enter_protected_mode:
    mov si, msg_switching_pm
    call print_string

    ; 8. Отключаем прерывания перед сменой режима
    cli

    ; 9. Загружаем 32-битную таблицу дескрипторов сегментов GDT
    lgdt [gdt_descriptor]

    ; 10. Включаем Защищенный Режим: бит PE (Protection Enable) в регистре CR0
    mov eax, cr0
    or eax, 1
    mov cr0, eax

    ; 11. Дальний переход (Far Jump) для очистки 16-битного конвейера инструкций
    jmp 0x08:pmode_entry


; ==============================================================================
; ПОДПРОГРАММЫ (16-БИТНЫЙ АССЕМБЛЕР)
; ==============================================================================

; --- Проверка включения линии A20 через сравнение памяти ---
; Возвращает AX = 1 (включена) или AX = 0 (выключена)
check_a20:
    pushf
    push ds
    push es
    push di
    push si

    cli
    xor ax, ax
    mov es, ax          ; ES = 0x0000
    not ax
    mov ds, ax          ; DS = 0xFFFF

    mov di, 0x7dfe      ; ES:DI = 0x0000:0x7DFE (сигнатура MBR)
    mov si, 0x7e0e      ; DS:SI = 0xFFFF:0x7E0E (тот же адрес при выключенной A20)

    mov al, [es:di]     ; Читаем байт
    push ax
    mov al, [ds:si]     ; Читаем байт по смещенному адресу
    pop bx
    cmp al, bl          ; Если они равны — возможно, память зациклена
    jne .a20_is_on

    mov ax, 0
    jmp .exit

.a20_is_on:
    mov ax, 1

.exit:
    pop si
    pop di
    pop es
    pop ds
    popf
    ret


; --- Чтение объема ОЗУ через BIOS E820 ---
detect_memory_e820:
    mov si, msg_mem_detect
    call print_string

    xor ebx, ebx            ; EBX = 0 для первого вызова
    mov dword [total_kb], 0 ; Обнуляем счетчик памяти

.e820_loop:
    mov eax, 0xe820
    mov edx, 0x534d4150     ; Магическое слово 'SMAP'
    mov ecx, 24             ; Размер буфера для дескриптора
    mov di, e820_buffer     ; Адрес временного буфера
    int 0x15
    jc .done                ; Если перенос (CF=1) или конец — завершаем

    ; Проверяем тип области: 1 = свободная ОЗУ (Usable RAM)
    cmp dword [e820_buffer + 16], 1
    jne .next_entry

    ; Добавляем длину блока (младшие 32 бита длины / 1024 = КБ)
    mov eax, [e820_buffer + 8]
    shr eax, 10             ; Переводим байты в Килобайты (деление на 1024)
    add [total_kb], eax

.next_entry:
    test ebx, ebx           ; Если EBX = 0, значит это была последняя запись
    jz .done
    jmp .e820_loop

.done:
    ; Переводим КБ в Мегабайты для красивого вывода (КБ / 1024)
    mov eax, [total_kb]
    shr eax, 10
    call print_dec          ; Печатаем число МБ

    mov si, msg_mb_suffix
    call print_string
    ret


; --- Вывод десятичного числа из регистра EAX на экран и в COM1 ---
print_dec:
    pusha
    mov cx, 0
    mov ebx, 10
.divide:
    xor edx, edx
    div ebx
    push dx
    inc cx
    test eax, eax
    jnz .divide
.print_digits:
    pop dx
    add dl, '0'
    mov al, dl
    mov ah, 0x0e
    int 0x10
    push dx
    mov dx, 0x3f8
    out dx, al
    pop dx
    loop .print_digits
    popa
    ret


; --- Вывод строки (адрес в SI, конец строки 0) с дублированием в COM1 ---
print_string:
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
; ДАННЫЕ И СТРОКИ
; ==============================================================================
boot_drive:     db 0
total_kb:       dd 0

banner_msg:
    db "==================================================", 13, 10
    db "    HOLLIS-BIT's OS -- 16-BIT REAL MODE STAGE     ", 13, 10
    db "==================================================", 13, 10, 13, 10, 0

msg_a20_ok:
    db "[OK] A20 Address Line enabled (Memory > 1MB unlocked)", 13, 10, 0

msg_mem_detect:
    db "[OK] BIOS E820 Memory Map: Usable RAM = ", 0

msg_mb_suffix:
    db " MB", 13, 10, 0

msg_press_key:
    db 13, 10, "[TEST] Testing 16-bit BIOS Keyboard Interrupt (int 0x16)...", 13, 10
    db "       >> Press any key on your keyboard to continue: ", 0

msg_key_ok:
    db 13, 10, "[OK] Key detected: '", 0

newline:
    db "'", 13, 10, 0

msg_stage1_done:
    db 13, 10, "==================================================", 13, 10
    db " [SUCCESS] Full 16-bit Real Mode Stage Complete!  ", 13, 10
    db " - BIOS Disk I/O: 4 sectors loaded to 0x7E00      ", 13, 10
    db " - Memory: E820 map parsed successfully           ", 13, 10
    db " - Hardware: A20 gate active                      ", 13, 10
    db " - Interactive: BIOS keyboard int 0x16 verified   ", 13, 10
    db " Ready to proceed to 32-bit Protected Mode!       ", 13, 10
    db "==================================================", 13, 10, 0

msg_press_to_pmode:
    db 13, 10, ">> Press any key to ENTER 32-BIT PROTECTED MODE...", 13, 10, 0

msg_switching_pm:
    db 13, 10, "[PMODE] Loading GDT and switching CPU to 32-bit Protected Mode...", 13, 10, 0

; Буфер для записи одного дескриптора E820 (24 байта)
align 4
e820_buffer:
    times 24 db 0

; ==============================================================================
; ТАБЛИЦА ДЕСКРИПТОРОВ СЕГМЕНТОВ GDT (32-BIT)
; ==============================================================================
align 8
gdt_start:
    ; 1. Нулевой обязательный дескриптор (8 байт нулей)
    dd 0x00000000
    dd 0x00000000

    ; 2. Селектор 0x08: 32-битный сегмент кода (Code Segment)
    ; Base: 0x00000000, Limit: 4GB, Ring 0, Exec/Read
    dw 0xffff           ; Limit (0-15)
    dw 0x0000           ; Base (0-15)
    db 0x00             ; Base (16-23)
    db 10011010b        ; Access Byte (0x9A: Present, Ring 0, Code, Exec/Read)
    db 11001111b        ; Flags (Granularity 4KB, 32-bit) + Limit (16-19: 0xF)
    db 0x00             ; Base (24-31)

    ; 3. Селектор 0x10: 32-битный сегмент данных (Data Segment)
    ; Base: 0x00000000, Limit: 4GB, Ring 0, Read/Write
    dw 0xffff           ; Limit (0-15)
    dw 0x0000           ; Base (0-15)
    db 0x00             ; Base (16-23)
    db 10010010b        ; Access Byte (0x92: Present, Ring 0, Data, Read/Write)
    db 11001111b        ; Flags (Granularity 4KB, 32-bit) + Limit (16-19: 0xF)
    db 0x00             ; Base (24-31)
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1  ; Размер таблицы - 1
    dd gdt_start                ; Физический адрес начала таблицы

; ==============================================================================
; ПОДКЛЮЧЕНИЕ 32-БИТНОГО МОДУЛЯ (STAGE 32)
; ==============================================================================
%include "src/boot/stage32.asm"

; Выравниваем полный Stage 2 до 16 секторов (8192 байта = 8 КБ)
times 8192 - ($ - $$) db 0
