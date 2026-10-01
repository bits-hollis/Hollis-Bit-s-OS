; ==============================================================================
; Hollis-Bit's OS — Ассемблерные обработчики прерываний (ISR Stubs)
; Файл: src/kernel/interrupts.asm
; Архитектура: x86_64
; Назначение: Низкоуровневые точки входа для 32 исключений процессора (0..31)
;             и 16 аппаратных прерываний IRQ (32..47). Сохраняют все регистры
;             и передают управление диспетчеру прерываний на Zig.
; ==============================================================================

[bits 64]

; Функция диспетчера прерываний в Zig
extern interrupt_dispatch

; Макрос для исключений БЕЗ кода ошибки (процессор не кладет ошибку в стек)
%macro ISR_NOERRCODE 1
global isr%1
isr%1:
    push qword 0        ; Кладем фиктивный код ошибки 0
    push qword %1       ; Кладем номер прерывания
    jmp isr_common_stub
%endmacro

; Макрос для исключений С кодом ошибки (процессор САМ кладет ошибку в стек)
%macro ISR_ERRCODE 1
global isr%1
isr%1:
    push qword %1       ; Кладем номер прерывания (код ошибки уже в стеке)
    jmp isr_common_stub
%endmacro

; Макрос для аппаратных прерываний IRQ (IRQ 0..15 -> векторы 32..47)
%macro IRQ 2
global irq%1
irq%1:
    push qword 0        ; Фиктивный код ошибки
    push qword %2       ; Вектор прерывания (32 + %1)
    jmp isr_common_stub
%endmacro

section .text

; --- 32 Исключения процессора x86_64 ---
ISR_NOERRCODE 0   ; #DE: Divide-by-zero
ISR_NOERRCODE 1   ; #DB: Debug
ISR_NOERRCODE 2   ; NMI: Non-maskable Interrupt
ISR_NOERRCODE 3   ; #BP: Breakpoint
ISR_NOERRCODE 4   ; #OF: Overflow
ISR_NOERRCODE 5   ; #BR: Bound Range Exceeded
ISR_NOERRCODE 6   ; #UD: Invalid Opcode
ISR_NOERRCODE 7   ; #NM: Device Not Available
ISR_ERRCODE   8   ; #DF: Double Fault (с кодом ошибки)
ISR_NOERRCODE 9   ; Coprocessor Segment Overrun
ISR_ERRCODE   10  ; #TS: Invalid TSS (с кодом ошибки)
ISR_ERRCODE   11  ; #NP: Segment Not Present (с кодом ошибки)
ISR_ERRCODE   12  ; #SS: Stack-Segment Fault (с кодом ошибки)
ISR_ERRCODE   13  ; #GP: General Protection Fault (с кодом ошибки)
ISR_ERRCODE   14  ; #PF: Page Fault (с кодом ошибки)
ISR_NOERRCODE 15  ; Reserved
ISR_NOERRCODE 16  ; #MF: x87 Floating-Point Exception
ISR_ERRCODE   17  ; #AC: Alignment Check
ISR_NOERRCODE 18  ; #MC: Machine Check
ISR_NOERRCODE 19  ; #XM: SIMD Floating-Point Exception
ISR_NOERRCODE 20  ; #VE: Virtualization Exception
ISR_ERRCODE   21  ; #CP: Control Protection Exception
ISR_NOERRCODE 22  ; Reserved
ISR_NOERRCODE 23  ; Reserved
ISR_NOERRCODE 24  ; Reserved
ISR_NOERRCODE 25  ; Reserved
ISR_NOERRCODE 26  ; Reserved
ISR_NOERRCODE 27  ; Reserved
ISR_NOERRCODE 28  ; #HV: Hypervisor Injection Exception
ISR_ERRCODE   29  ; #VC: VMM Communication Exception
ISR_ERRCODE   30  ; #SX: Security Exception
ISR_NOERRCODE 31  ; Reserved

; --- 16 Аппаратных прерываний PIC (IRQ 0..15) ---
IRQ 0,  32  ; IRQ 0: Таймер PIT (Programmable Interval Timer)
IRQ 1,  33  ; IRQ 1: Клавиатура PS/2
IRQ 2,  34  ; IRQ 2: Каскад для Slave PIC
IRQ 3,  35  ; IRQ 3: COM2 порт
IRQ 4,  36  ; IRQ 4: COM1 порт
IRQ 5,  37  ; IRQ 5: LPT2 / Звуковая карта Sound Blaster
IRQ 6,  38  ; IRQ 6: Контроллер дискет
IRQ 7,  39  ; IRQ 7: LPT1 / Спуриус
IRQ 8,  40  ; IRQ 8: RTC часы реального времени
IRQ 9,  41  ; IRQ 9: Доступно
IRQ 10, 42  ; IRQ 10: Доступно
IRQ 11, 43  ; IRQ 11: Доступно
IRQ 12, 44  ; IRQ 12: Мышь PS/2
IRQ 13, 45  ; IRQ 13: Математический сопроцессор FPU
IRQ 14, 46  ; IRQ 14: Первичный жесткий диск ATA
IRQ 15, 47  ; IRQ 15: Вторичный жесткий диск ATA

; ==============================================================================
; ОБЩИЙ СТАБ ПРЕРЫВАНИЙ: СОХРАНЕНИЕ КОНТЕКСТА ПРОЦЕССОРА
; ==============================================================================
isr_common_stub:
    ; 1. Сохраняем все регистры общего назначения в стек
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    ; 2. Передаем указатель на структуру сохраненных регистров (RSP)
    ; в первом аргументе вызова Си-соглашения (регистр RDI в x86_64 ABI)
    mov rdi, rsp

    ; 3. Выравниваем стек по границе 16 байт и сбрасываем флаг направления (CLD)
    cld
    call interrupt_dispatch

    ; 4. Восстанавливаем все сохраненные регистры из стека
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ; 5. Очищаем из стека номер прерывания и код ошибки (2 qword = 16 байт)
    add rsp, 16

    ; 6. Атомарно возвращаемся из прерывания: восстанавливаются RIP, CS, RFLAGS, RSP, SS
    iretq
