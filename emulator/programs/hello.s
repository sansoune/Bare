li a0, 0x10000000
la a2, message

next:
  ld.bu a1, [a2]
  bz a1, done
  st.b a1, [a0]
  add a2, 1
  jmp next
done:
  halt

message: .asciz "Hello from BARE64!\n"
