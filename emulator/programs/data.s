la a2, table
la a3, table_end
mov a0, 0

sum:
  ld.w a1, [a2]
  add a0, a1
  add a2, 4
  bne a2, a3, sum

la a2, message
mov a1, 0
len:
  ld.bu a4, [a2]
  bz a4, done
  add a1, 1
  add a2, 1
  jmp len

done:
  halt


        .align 4
table:  .word 10, 20, 30, 40
table_end:
message: .asciz "Hello from BARE64!\n"
