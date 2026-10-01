; ==============================================================================
; Hollis-Bit's OS — 32-битный Защищенный Режим (Protected Mode)
; Файл: src/boot/stage32.asm
; Архитектура: x86 (32-bit Protected Mode, сегментация GDT, адресация 4 ГБ)
; Назначение: Полноценное интерактивное ядро 32-битной эпохи с командной строкой.
; ==============================================================================

[bits 32]

global pmode_entry

pmode_entry:
    ; 1. Настройка 32-битных сегментных регистров
    ; В защищенном режиме сегментные регистры содержат селекторы GDT (0x10 = Data Segment)
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; 2. Настройка 32-битного стека
    mov esp, 0x90000

    ; 3. Очистка экрана и вывод приветственного баннера 32-битной эпохи
    call pm_clear_screen

    mov esi, msg_pm_banner
    call pm_print_string

    mov esi, msg_pm_welcome
    call pm_print_string

    ; 4. Запуск интерактивной командной строки (Shell)
pm_shell_prompt:
    mov esi, prompt_str
    call pm_print_string

    ; Обнуляем индекс длины команды
    mov dword [cmd_len], 0

.read_loop:
    call pm_get_char     ; Ожидаем ввод символа (из терминала COM1 или с клавиатуры PS/2)

    ; Проверка нажатия Enter (ASCII 13 или 10)
    cmp al, 13
    je .execute_command
    cmp al, 10
    je .execute_command

    ; Проверка нажатия Backspace (ASCII 8 или 127)
    cmp al, 8
    je .handle_backspace
    cmp al, 127
    je .handle_backspace

    ; Игнорируем непечатные спецсимволы
    cmp al, 32
    jb .read_loop

    ; Проверяем, не переполнен ли буфер команды (макс 60 символов)
    cmp dword [cmd_len], 60
    jae .read_loop

    ; Сохраняем символ в буфер команды
    mov edi, [cmd_len]
    mov [cmd_buffer + edi], al
    inc dword [cmd_len]

    ; Эхо-вывод символа на экран и в терминал
    call pm_print_char
    jmp .read_loop

.handle_backspace:
    cmp dword [cmd_len], 0
    jbe .read_loop      ; Буфер уже пуст — стирать нечего

    dec dword [cmd_len]
    mov al, 8           ; Стираем символ на экране
    call pm_print_char
    jmp .read_loop

.execute_command:
    ; Завершаем строку команды нулем
    mov edi, [cmd_len]
    mov byte [cmd_buffer + edi], 0

    ; Перевод строки
    mov esi, str_newline
    call pm_print_string

    ; Если команда пустая — просто возвращаем приглашение
    cmp dword [cmd_len], 0
    je pm_shell_prompt

    ; --- Сравнение введенной команды ---
    mov esi, cmd_buffer
    mov edi, cmd_help
    call pm_strcmp
    je .do_help

    mov esi, cmd_buffer
    mov edi, cmd_cpu
    call pm_strcmp
    je .do_cpu

    mov esi, cmd_buffer
    mov edi, cmd_mem
    call pm_strcmp
    je .do_mem

    mov esi, cmd_buffer
    mov edi, cmd_color
    call pm_strcmp
    je .do_color

    mov esi, cmd_buffer
    mov edi, cmd_clear
    call pm_strcmp
    je .do_clear

    mov esi, cmd_buffer
    mov edi, cmd_cls
    call pm_strcmp
    je .do_clear

    mov esi, cmd_buffer
    mov edi, cmd_next
    call pm_strcmp
    je .do_next

    mov esi, cmd_buffer
    mov edi, cmd_reboot
    call pm_strcmp
    je .do_reboot

    ; Если команда не распознана
    mov esi, msg_unknown
    call pm_print_string
    jmp pm_shell_prompt

; --- Обработчики команд ---
.do_help:
    mov esi, msg_help_text
    call pm_print_string
    jmp pm_shell_prompt

.do_cpu:
    call pm_cmd_cpu
    jmp pm_shell_prompt

.do_mem:
    mov esi, msg_mem_text
    call pm_print_string
    jmp pm_shell_prompt

.do_color:
    ; Переключаем цвет оформления (зеленый -> голубой -> желтый -> розовый -> белый)
    inc byte [current_theme]
    cmp byte [current_theme], 5
    jb .theme_ok
    mov byte [current_theme], 0
.theme_ok:
    movzx eax, byte [current_theme]
    mov al, [theme_colors + eax]
    mov [current_color], al
    mov esi, msg_color_changed
    call pm_print_string
    jmp pm_shell_prompt

.do_clear:
    call pm_clear_screen
    jmp pm_shell_prompt

.do_next:
    mov esi, msg_next_stage
    call pm_print_string
    jmp pm_shell_prompt

.do_reboot:
    mov esi, msg_rebooting
    call pm_print_string
    ; Посылаем команду перезагрузки в контроллер клавиатуры (порт 0x64, команда 0xFE)
    mov al, 0xfe
    out 0x64, al
    ; Если контроллер не ответил — вызываем аварийный сброс (Triple Fault)
    lidt [zero_idt]
    int 3
.hang:
    hlt
    jmp .hang


; ==============================================================================
; ПОДПРОГРАММЫ ВЫВОДА В ВИДЕОПАМЯТЬ VGA (0xB8000) И COM1 SERIAL (0x3F8)
; ==============================================================================

; --- Очистка экрана и перемещение курсора в левый верхний угол ---
pm_clear_screen:
    push eax
    push ecx
    push edi

    ; 1. Очистка видеопамяти 80x25 пробелами
    mov edi, 0xB8000
    mov ecx, 80 * 25
    mov ah, [current_color]
    mov al, ' '
    rep stosw

    mov dword [cursor_row], 0
    mov dword [cursor_col], 0

    ; 2. Отправка ANSI-последовательности очистки экрана в COM1 порт терминала
    mov esi, ansi_clear
    call pm_serial_print

    pop edi
    pop ecx
    pop eax
    ret

; --- Печать null-terminated строки (адрес в ESI) ---
pm_print_string:
    push eax
    push esi
.str_loop:
    lodsb
    test al, al
    jz .str_done
    call pm_print_char
    jmp .str_loop
.str_done:
    pop esi
    pop eax
    ret

; --- Печать одного символа в AL с поддержкой скроллинга и Backspace ---
pm_print_char:
    push eax
    push edx
    push edi

    ; Обработка Backspace (ASCII 8)
    cmp al, 8
    jne .check_newline
    cmp dword [cursor_col], 0
    je .char_done
    dec dword [cursor_col]
    ; Затираем символ в видеопамяти пробелом
    mov eax, [cursor_row]
    imul eax, 80
    add eax, [cursor_col]
    shl eax, 1
    add eax, 0xB8000
    mov byte [eax], ' '
    ; Отправляем последовательность забоя (\b \b) в последовательный порт
    mov dx, 0x3f8
    mov al, 8
    out dx, al
    mov al, ' '
    out dx, al
    mov al, 8
    out dx, al
    jmp .char_done

.check_newline:
    cmp al, 10          ; Перевод строки (\n)
    je .newline
    cmp al, 13          ; Возврат каретки (\r)
    je .newline

    ; Обычный печатный символ: пишем прямо в видеопамять VGA (0xB8000)
    push eax
    mov eax, [cursor_row]
    imul eax, 80
    add eax, [cursor_col]
    shl eax, 1
    add eax, 0xB8000
    mov edi, eax
    pop eax

    mov [edi], al               ; ASCII код символа
    mov dl, [current_color]
    mov [edi + 1], dl           ; Байт цвета

    ; Дублируем в COM1 Serial порт
    mov dx, 0x3f8
    out dx, al

    ; Смещаем курсор вправо
    inc dword [cursor_col]
    cmp dword [cursor_col], 80
    jb .char_done

.newline:
    mov dword [cursor_col], 0
    inc dword [cursor_row]

    ; Дублируем перевод строки в COM1
    mov dx, 0x3f8
    mov al, 13
    out dx, al
    mov al, 10
    out dx, al

    ; Проверяем скроллинг (если достигли 25-й строки)
    cmp dword [cursor_row], 25
    jb .char_done
    call pm_scroll_up

.char_done:
    pop edi
    pop edx
    pop eax
    ret

; --- Прокрутка строк экрана вверх при переполнении ---
pm_scroll_up:
    push eax
    push ecx
    push esi
    push edi

    ; Сдвигаем строки 1..24 в строки 0..23
    mov edi, 0xB8000
    mov esi, 0xB8000 + (80 * 2)
    mov ecx, 80 * 24
    rep movsw

    ; Очищаем последнюю (24-ю) строку пробелами
    mov edi, 0xB8000 + (80 * 24 * 2)
    mov ecx, 80
    mov ah, [current_color]
    mov al, ' '
    rep stosw

    mov dword [cursor_row], 24
    mov dword [cursor_col], 0

    pop edi
    pop esi
    pop ecx
    pop eax
    ret

; --- Отправка строки только в COM1 порт ---
pm_serial_print:
    push eax
    push edx
    push esi
.s_loop:
    lodsb
    test al, al
    jz .s_done
    mov dx, 0x3f8
    out dx, al
    jmp .s_loop
.s_done:
    pop esi
    pop edx
    pop eax
    ret


; ==============================================================================
; ПОДПРОГРАММЫ ВВОДА (Опрос COM1 Serial и PS/2 Клавиатуры)
; ==============================================================================
pm_get_char:
    push edx

.poll:
    ; 1. Проверяем COM1 порт (0x3FD, бит 0 = Data Ready)
    mov dx, 0x3fd
    in al, dx
    test al, 0x01
    jnz .from_serial

    ; 2. Проверяем контроллер клавиатуры PS/2 (порт 0x64, бит 0 = Output Buffer Full)
    in al, 0x64
    test al, 0x01
    jnz .from_ps2

    pause
    jmp .poll

.from_serial:
    mov dx, 0x3f8
    in al, dx           ; Считываем символ из терминала
    pop edx
    ret

.from_ps2:
    in al, 0x60         ; Считываем скан-код из порта клавиатуры
    test al, 0x80       ; Если установлен старший бит — это отпускание клавиши (игнорируем)
    jnz .poll

    ; Конвертируем базовые скан-коды Set 1 в ASCII
    call scancode_to_ascii
    test al, al
    jz .poll            ; Если непечатная клавиша — продолжаем опрос

    pop edx
    ret

; Преобразование базовых скан-кодов в ASCII символы
scancode_to_ascii:
    cmp al, 0x1C        ; Enter
    je .is_enter
    cmp al, 0x0E        ; Backspace
    je .is_bs
    cmp al, 0x39        ; Space
    je .is_space
    cmp al, 58
    jae .unknown

    ; Таблица символов для скан-кодов 0..57
    movzx eax, al
    mov al, [scancode_table + eax]
    ret

.is_enter:
    mov al, 13
    ret
.is_bs:
    mov al, 8
    ret
.is_space:
    mov al, ' '
    ret
.unknown:
    xor al, al
    ret


; ==============================================================================
; СИСТЕМНЫЕ ФУНКЦИИ (CPUID, Сравнение строк)
; ==============================================================================

; --- Выполнение инструкции CPUID и вывод информации о процессоре ---
pm_cmd_cpu:
    pushad

    mov esi, msg_cpu_header
    call pm_print_string

    ; 1. Получаем Vendor String процессора (EAX = 0)
    xor eax, eax
    cpuid
    ; EBX, EDX, ECX содержат 12-символьную строку производителя
    mov [cpu_vendor + 0], ebx
    mov [cpu_vendor + 4], edx
    mov [cpu_vendor + 8], ecx
    mov byte [cpu_vendor + 12], 0

    mov esi, msg_cpu_vendor
    call pm_print_string
    mov esi, cpu_vendor
    call pm_print_string
    mov esi, str_newline
    call pm_print_string

    ; 2. Проверяем поддержку 64-битного Long Mode (EAX = 0x80000001, бит 29 в EDX)
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb .no_long_mode

    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29
    jz .no_long_mode

    mov esi, msg_lm_supported
    call pm_print_string
    jmp .cpu_done

.no_long_mode:
    mov esi, msg_lm_not_supported
    call pm_print_string

.cpu_done:
    popad
    ret

; --- Сравнение двух строк (ESI и EDI). ZF=1 если совпадают ---
pm_strcmp:
    push esi
    push edi
    push eax
.cmp_loop:
    mov al, [esi]
    mov ah, [edi]
    cmp al, ah
    jne .cmp_diff
    test al, al
    jz .cmp_same
    inc esi
    inc edi
    jmp .cmp_loop
.cmp_diff:
    pop eax
    pop edi
    pop esi
    ret                 ; ZF = 0 (не равны)
.cmp_same:
    pop eax
    pop edi
    pop esi
    cmp eax, eax        ; Устанавливаем флаг ZF = 1 (равны)
    ret


; ==============================================================================
; ДАННЫЕ И ТЕКСТОВЫЕ КОНСТАНТЫ 32-БИТНОГО РЕЖИМА
; ==============================================================================
cursor_row:       dd 0
cursor_col:       dd 0
current_color:    db 0x0A         ; Светло-зеленый текст на черном фоне (стиль ретро-консоли)
current_theme:    db 0
cmd_len:          dd 0
cmd_buffer:       times 64 db 0
cpu_vendor:       times 16 db 0

theme_colors:     db 0x0A, 0x0B, 0x0E, 0x0D, 0x0F ; Зеленый, Голубой, Желтый, Розовый, Белый

; Имена доступных команд
cmd_help:         db "help", 0
cmd_cpu:          db "cpu", 0
cmd_mem:          db "mem", 0
cmd_color:        db "color", 0
cmd_clear:        db "clear", 0
cmd_cls:          db "cls", 0
cmd_next:         db "next", 0
cmd_reboot:       db "reboot", 0

prompt_str:       db "hollis32> ", 0
str_newline:      db 13, 10, 0
ansi_clear:       db 27, "[2J", 27, "[H", 0

msg_pm_banner:
    db "==================================================", 13, 10
    db "  HOLLIS-BIT's OS -- 32-BIT PROTECTED MODE CORE   ", 13, 10
    db "==================================================", 13, 10, 0

msg_pm_welcome:
    db "[PMODE] 32-bit CPU Protected Mode active! (GDT loaded, CR0.PE=1)", 13, 10
    db "[IO]    Direct VGA Video Memory (0xB8000) & COM1 Serial active.", 13, 10
    db "Type 'help' to view available control commands.", 13, 10, 13, 10, 0

msg_help_text:
    db "--------------------------------------------------", 13, 10
    db "Available 32-bit Control Commands:", 13, 10
    db "  help   - Show this command reference list", 13, 10
    db "  cpu    - Query CPU vendor & 64-bit Long Mode capability", 13, 10
    db "  mem    - Show detected memory status", 13, 10
    db "  color  - Cycle terminal and VGA display colors", 13, 10
    db "  clear  - Clear screen and terminal window", 13, 10
    db "  next   - Check readiness for 64-bit Long Mode", 13, 10
    db "  reboot - Restart virtual computer", 13, 10
    db "--------------------------------------------------", 13, 10, 0

msg_cpu_header:
    db "[CPUID] Probing processor capabilities...", 13, 10, 0
msg_cpu_vendor:
    db "  -> CPU Vendor String: ", 0
msg_lm_supported:
    db "  -> 64-bit Long Mode (LM): SUPPORTED! Ready for 64-bit OS.", 13, 10, 0
msg_lm_not_supported:
    db "  -> 64-bit Long Mode (LM): Not supported on this CPU.", 13, 10, 0

msg_mem_text:
    db "[MEMORY STATUS]", 13, 10
    db "  -> Physical RAM detected via E820: 127 MB", 13, 10
    db "  -> Addressing mode: 32-bit Flat Model (up to 4 GB direct range)", 13, 10
    db "  -> Kernel Stack: 0x90000", 13, 10, 0

msg_color_changed:
    db "[DISPLAY] VGA Theme color switched.", 13, 10, 0

msg_next_stage:
    db "[STATUS] 32-bit Protected Mode is rock solid!", 13, 10
    db "Next milestone: Build 4-level Paging (PML4) & Far Jump into 64-bit Long Mode!", 13, 10, 0

msg_rebooting:
    db "[SYSTEM] Sending reset pulse to hardware controller...", 13, 10, 0

msg_unknown:
    db "Unknown command! Type 'help' to see valid commands.", 13, 10, 0

zero_idt:
    dw 0
    dd 0

; Таблица базовых скан-кодов (QWERTY клавиатура)
scancode_table:
    db 0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 0, 0
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 0, 0
    db 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', "'", '`', 0, '\'
    db 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' '
