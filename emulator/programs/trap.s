la a2, handler
csrw tvec, a2
ecall              ; trap into the handler
mov a1, 7          ; runs after eret
halt

handler:
  csrr a0, cause   ; 8 = ecall
  eret
