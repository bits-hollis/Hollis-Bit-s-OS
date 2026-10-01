; ==============================================================================
; Hollis-Bit's OS — Загрузочный сектор MBR (Сектор 0, адрес 0x7C00)
; Эпоха: 16-битный реальный режим BIOS (Real Mode)
; Задача: Инициализировать процессор и загрузить с диска Stage 2 (16-битное ядро).
; ==============================================================================

[bits 16]
[org 0x7c00]

start:
    ; 1. Нормализация CS и базовых сегментов
    ; Некоторые BIOS передают управление как 0x07C0:0x0000, другие как 0x0000:0x7C00.
    ; Дальний переход (jmp 0x0000:...) гарантирует, что CS строго равен 0.
    jmp 0x0000:.init_segments

.init_segments:
    cli                 ; Запрещаем прерывания на время настройки стека
    xor ax, ax
    mov ds, ax          ; DS = 0
    mov es, ax          ; ES = 0
    mov ss, ax          ; SS = 0
    mov sp, 0x7c00      ; Стек растет от 0x7C00 вниз к 0x0000
    sti                 ; Разрешаем прерывания

    ; 2. Сохраняем номер загрузочного диска
    ; BIOS при старте кладет номер диска в регистр DL (0x80 = первый жесткий диск / USB).
    mov [boot_drive], dl

    ; 3. Выводим стартовое сообщение MBR
    mov si, msg_mbr
    call print_string

    ; 4. Сброс дискового контроллера перед чтением
    ; Функция BIOS int 0x13 (AH = 0x00) калибрует контроллер диска
    xor ax, ax
    mov dl, [boot_drive]
    int 0x13
    jc disk_error       ; Флаг переноса (CF = 1) означает ошибку оборудования

    ; 5. Чтение Stage 2 с диска в оперативную память
    ; Загружаем 4 сектора (2048 байт), начиная со 2-го сектора диска (LBA 1, CHS: C=0, H=0, S=2).
    ; Адрес назначения в ОЗУ: 0x0000:0x7E00 (сразу за 512 байтами MBR).
    mov bx, 0x7e00      ; ES:BX = 0x0000:0x7E00
    mov ah, 0x02        ; Функция: чтение секторов
    mov al, 4           ; Количество считываемых секторов (4 сектора = 2 КБ)
    mov ch, 0           ; Номер цилиндра (0)
    mov cl, 2           ; Начальный сектор (сектор 2, так как сектор 1 — это сам MBR)
    mov dh, 0           ; Номер головки (0)
    mov dl, [boot_drive]; Номер диска
    int 0x13
    jc disk_error       ; Если ошибка — переходим на обработчик

    ; 6. Успешно считано! Передаем управление во 2-й этап (Stage 2)
    mov si, msg_loaded
    call print_string

    ; Передаем номер диска в DL и прыгаем на 0x7E00
    mov dl, [boot_drive]
    jmp 0x0000:0x7e00

; --- Обработчик ошибки чтения диска ---
disk_error:
    mov si, msg_disk_err
    call print_string
.halt:
    hlt
    jmp .halt

; --- Процедура печати строки через BIOS Teletype (int 0x10) и дублирование в COM1 ---
print_string:
    push ax
    push dx
.loop:
    lodsb
    test al, al
    jz .done
    ; 1. Вывод на экран через BIOS
    mov ah, 0x0e
    mov bh, 0x00
    mov bl, 0x07        ; Серый цвет
    int 0x10
    ; 2. Дублирование в COM1 Serial (0x3F8) для терминала
    mov dx, 0x3f8
    out dx, al
    jmp .loop
.done:
    pop dx
    pop ax
    ret

; --- Данные MBR ---
boot_drive:    db 0
msg_mbr:       db "[MBR] 16-bit Stage 0 active. Reading Stage 2 from disk...", 13, 10, 0
msg_loaded:    db "[MBR] Stage 2 loaded successfully! Jumping to 0x7E00...", 13, 10, 13, 10, 0
msg_disk_err:  db "[ERROR] BIOS disk read failed! System halted.", 13, 10, 0

; --- Сигнатура загрузочного сектора (512 байт) ---
times 510 - ($ - $$) db 0
dw 0xAA55
