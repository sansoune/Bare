; Count in a loop until the timer interrupt fires, then stop.
la a2, handler
csrw tvec, a2
mov a0, 1
csrw ie, a0            ; interrupts on

li a2, 0x10001000      ; timer base address
mov a0, 50
st.d a0, [a2 + 8]      ; fire when time reaches 50

wait:
  add a3, 1
  beq a4, zero, wait   ; loop until the handler sets a4

mov a1, a3
halt

handler:
  mov a4, 1
  st.d zero, [a2 + 8]  ; acknowledge: timer off
  eret
