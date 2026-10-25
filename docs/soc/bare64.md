# BARE64 — ISA and CPU Architecture Reference

> **Status:** prototype specification  
> **Implementation reference:** `emulator/emu.zig` and `emulator/assembler.zig`  
> **Instruction width:** 32 bits  
> **General-purpose register width:** 64 bits  
> **Memory byte order:** little-endian

This document describes the BARE64 instruction set and the CPU model implemented by the current emulator. It is intentionally an implementation-level reference, not a claim that the prototype already contains a synthesized hardware CPU, pipeline, cache hierarchy, interrupt controller, or complete privilege architecture.

When this document says “CPU,” it refers to the architectural state and execution logic modeled by the emulator. A future hardware implementation may divide the same behavior into physical blocks, but it must preserve the specified architectural results unless the ISA is deliberately revised.

## Contents

- [1. Architectural model](#1-architectural-model)
- [2. CPU state and components](#2-cpu-state-and-components)
- [3. Instruction execution lifecycle](#3-instruction-execution-lifecycle)
- [4. Instruction encoding](#4-instruction-encoding)
- [5. Register conventions](#5-register-conventions)
- [6. ALU instructions](#6-alu-instructions)
- [7. Constant construction](#7-constant-construction)
- [8. Loads and stores](#8-loads-and-stores)
- [9. Conditional branches](#9-conditional-branches)
- [10. Jumps and calls](#10-jumps-and-calls)
- [11. Privileged instruction family](#11-privileged-instruction-family)
- [12. Memory and UART model](#12-memory-and-uart-model)
- [13. Assembler reference](#13-assembler-reference)
- [14. Worked examples](#14-worked-examples)
- [15. Faults, reserved encodings, and current limitations](#15-faults-reserved-encodings-and-current-limitations)

---

## 1. Architectural model

BARE64 is a fixed-width, 64-bit-register ISA prototype. Every machine instruction occupies one 32-bit word. The program counter (`pc`) is a **byte address**, not an instruction index.

The core architectural rules are:

1. There are 32 general-purpose registers, `r0` through `r31`, each 64 bits wide.
2. `r0` is hardwired to zero at the architectural interface: reads return zero and writes are discarded.
3. The program counter is a 64-bit byte address.
4. Normal sequential execution advances the PC by 4 bytes.
5. Instructions and data are stored little-endian.
6. ALU instructions use two-operand semantics: the destination is also the first source.
7. Arithmetic addition, subtraction, and multiplication wrap modulo \(2^{64}\).
8. Comparisons produce integer values (`0` or `1`) in a destination register; there is no flags register.
9. Conditional branches compare registers directly.
10. `ebreak` halts the emulator. Illegal instructions and memory faults also halt it.

### Architectural state versus implementation details

| State | Width / form | Purpose |
|---|---|---|
| `regs[0..31]` | 32 × 64-bit | General-purpose register file |
| `pc` | 64-bit byte address | Address of the instruction currently being executed |
| `mem` | Mutable byte slice | RAM and the program image |
| `halted` | Boolean | Stops the execution loop when true |
| `uart_buf` | 256 bytes | Captures bytes written to the UART transmit address |
| `uart_len` | Integer | Number of captured UART bytes, capped at 256 |
| `echo` | Boolean | Controls whether UART bytes are also printed to the terminal |

The UART capture buffer, `echo`, and the emulator's fault messages are emulator facilities rather than general-purpose architectural registers.

## 2. CPU state and components

This section explains the logical blocks needed to understand the implementation. These are **functional responsibilities**, not a claim that the current project has already implemented each as a separate hardware module.

### 2.1 Program counter (PC)

The PC identifies the byte address of the instruction to fetch.

- Initial value: `0`.
- Sequential next address: `pc + 4`.
- Branches and jumps replace the sequential address with a computed target.
- `pchi` uses the address of the current instruction, not `pc + 4`.
- `jal` and `jalr` save `pc + 4` as the return address.

The emulator uses wrapping arithmetic for PC addition. It does not currently validate that the PC is aligned or that a full 4-byte instruction remains in memory before fetching.

### 2.2 Register file

The register file contains 32 entries, each holding a 64-bit value.

- Two register indices are commonly read by an instruction.
- An instruction may write one destination register.
- Register index fields are 5 bits wide because \(2^5 = 32\).
- `r0` is special: `setReg(0, value)` does nothing.
- All other registers preserve the complete 64-bit value.

The ISA does not reserve hardware flags for carry, zero, negative, or overflow. Instructions that need a comparison return a normal integer result.

### 2.3 Instruction fetch

The fetch operation reads four bytes beginning at the PC and interprets them as one little-endian `u32`.

For bytes at addresses `pc` through `pc + 3`:

\[
instruction = b_0 + (b_1 \ll 8) + (b_2 \ll 16) + (b_3 \ll 24)
\]

For example, the bytes `01 00 00 04` form the 32-bit word `0x04000001`.

In the current emulator, fetch is a direct RAM slice read. An invalid PC can trigger a runtime bounds failure rather than a modeled instruction-fetch exception.

### 2.4 Instruction decoder

The decoder extracts fields from the 32-bit instruction word:

- `opcode = inst[31:26]`
- `A = inst[25:21]`
- `B / function = inst[20:16]`, depending on the instruction family
- Immediate and payload bits come from the low 16, 21, or 15 bits depending on the format.

The opcode selects the instruction family. For ALU instructions, the function field selects the operation within the ALU family.

### 2.5 ALU

The arithmetic logic unit (ALU) performs integer operations on 64-bit operands:

- move/copy
- addition and subtraction
- bitwise AND, OR, XOR
- logical and arithmetic shifts
- signed and unsigned less-than comparisons
- low-64-bit multiplication

The first operand is the value already in register `A`. The second operand comes from either a register or a sign-extended immediate. The result is written back to `A`, unless `A` is `r0`.

There is no separate flags output. `lt` and `ltu` write `0` or `1` to the destination.

### 2.6 Load/store path

Loads and stores calculate an effective address from a base register plus a signed 16-bit byte offset:

\[
effective\_address = R[B] + sign\_extend(imm16)
\]

Loads read 1, 2, 4, or 8 bytes. Stores write 1, 2, 4, or 8 bytes from the low bits of the source register. Multi-byte values use little-endian byte order.

The emulator checks natural alignment and bounds before normal RAM accesses. An unaligned or out-of-range access sets `halted` and prints a diagnostic.

### 2.7 Control-flow path

Branches compare two registers and select either:

- the sequential PC, `pc + 4`; or
- a PC-relative target, `pc + (sign_extend(offset16) << 2)`.

`jal` and `jalr` also write a return address to a destination register. A destination of `r0` discards that link, which makes it useful for unconditional jumps.

### 2.8 RAM and memory-mapped I/O

The current emulator uses one mutable byte slice as RAM. It also recognizes two fixed addresses for a minimal UART model:

| Address | Access | Behavior |
|---|---|---|
| `0x10000000` | Store | Transmit the low byte of the stored value |
| `0x10000004` | Load | Returns `1` as a constant status value |

These addresses are not backed by the RAM slice. UART behavior is handled specially by the emulator's memory access functions.

### 2.9 What is not present yet

The current source does not model a pipeline, caches, a TLB, virtual memory, a bus arbitration protocol, interrupts, CSRs, atomic instructions, or privilege levels. These can be future microarchitecture or ISA work, but should not be described as implemented features.

## 3. Instruction execution lifecycle

The `step()` method models one instruction execution.

1. **Fetch:** read a 32-bit instruction at `pc`.
2. **Decode:** extract opcode, register fields, function field, and immediate fields.
3. **Prepare next PC:** initialize `next_pc = pc + 4`.
4. **Execute:** perform the ALU operation, calculate an address, evaluate a branch, or handle a privileged operation.
5. **Access memory if required:** validate alignment and range, then read or write bytes.
6. **Write back:** update the destination register when the instruction produces a result. Writes to `r0` are discarded.
7. **Commit PC:** assign `pc = next_pc`.

Branches and jumps modify `next_pc`. The default sequential address is used when a branch condition is false.

If the instruction is illegal or a memory access faults, the emulator sets `halted`. The function still reaches the final PC assignment for faults raised inside the instruction switch; the PC therefore generally advances by 4 on such paths. Fetch failures occur before that logic and are not converted into a CPU fault state.

## 4. Instruction encoding

All instructions are 32-bit words. Bit 31 is the most significant bit; bit 0 is the least significant bit. The assembler emits each word to memory in little-endian byte order.

### 4.1 Opcode map

The opcode occupies bits `[31:26]`.

| Opcode | Instruction / family | Current implementation |
|---:|---|---|
| `0x00` | `illegal` | Illegal |
| `0x01` | `alu` | ALU family |
| `0x03` | `hi` | Implemented |
| `0x04` | `pchi` | Implemented |
| `0x08` | `lb` | Implemented |
| `0x09` | `lbu` | Implemented |
| `0x0A` | `lh` | Implemented |
| `0x0B` | `lhu` | Implemented |
| `0x0C` | `lw` | Implemented |
| `0x0D` | `lwu` | Implemented |
| `0x0E` | `ld` | Implemented |
| `0x10` | `sb` | Implemented |
| `0x11` | `sh` | Implemented |
| `0x12` | `sw` | Implemented |
| `0x13` | `sd` | Implemented |
| `0x18` | `beq` | Implemented |
| `0x19` | `bne` | Implemented |
| `0x1A` | `blt` | Implemented |
| `0x1B` | `bge` | Implemented |
| `0x1C` | `bltu` | Implemented |
| `0x1D` | `bgeu` | Implemented |
| `0x20` | `jal` | Implemented |
| `0x21` | `jalr` | Implemented |
| `0x2D` | `priv` | `ebreak` works; `ecall` is not implemented |

Other opcode values are rejected by the instruction switch and halt the emulator.

### 4.2 ALU format

```text
 31       26 25       21 20       16 15 14             0
+-----------+-----------+-----------+-+----------------+
|  opcode   |     A     |   Func    |I|    payload     |
+-----------+-----------+-----------+-+----------------+
    6 bits     5 bits      5 bits   1      15 bits
```

| Bits | Width | Meaning |
|---|---:|---|
| `[31:26]` | 6 | Opcode `0x01` |
| `[25:21]` | 5 | `A`, destination and first source |
| `[20:16]` | 5 | ALU function code |
| `[15]` | 1 | `I`: immediate-mode selector |
| `[14:0]` | 15 | Register selector payload or signed immediate |

When `I = 0`, the low five bits select the second source register. Bits `[14:5]` are not used by the current decoder; avoid relying on nonzero values there.

When `I = 1`, bits `[14:0]` are interpreted as a signed two's-complement 15-bit immediate. Its range is `-16384` through `16383`. The immediate is sign-extended to 64 bits before the ALU operation.

### 4.3 `hi` and `pchi` format

```text
 31       26 25       21 20                            0
+-----------+-----------+-------------------------------+
|  opcode   |     A     |          signed imm21         |
+-----------+-----------+-------------------------------+
```

The low 21 bits form a signed immediate. The immediate is sign-extended and shifted left by 15 bits.

### 4.4 I-format: loads, stores, branches, and `jalr`

```text
 31       26 25       21 20       16 15                 0
+-----------+-----------+-----------+---------------------+
|  opcode   |     A     |     B     |       imm16        |
+-----------+-----------+-----------+---------------------+
```

The meaning of `A` and `B` depends on the opcode:

- Load: `A` is the destination; `B` is the base register.
- Store: `A` is the source/data register; `B` is the base register.
- Branch: `A` and `B` are compared.
- `jalr`: `A` is the link destination; `B` is the base register.

For loads, stores, and `jalr`, `imm16` is a signed **byte offset**. For conditional branches, `imm16` is a signed **instruction displacement**, scaled by four at execution time.

### 4.5 `jal` format

```text
 31       26 25       21 20                            0
+-----------+-----------+-------------------------------+
|  opcode   |     A     |          signed imm21         |
+-----------+-----------+-------------------------------+
```

The immediate is a signed displacement in 4-byte instruction units, relative to the address of the `jal` instruction.

### 4.6 Privileged format

The opcode is `0x2D`; bits `[20:16]` hold the `Priv` function code. The current implementation recognizes `ebreak` (`1`). Other function values, including `ecall` (`0`), are treated as illegal.

## 5. Register conventions

The hardware-visible register index is always `r0`–`r31`. The assembler additionally accepts these names:

| Index | Alias | Index | Alias |
|---:|---|---:|---|
| 0 | `zero` | 16 | `t4` |
| 1 | `ra` | 17 | `t5` |
| 2 | `sp` | 18 | `t6` |
| 3 | `tp` | 19 | `t7` |
| 4 | `a0` | 20 | `s0` |
| 5 | `a1` | 21 | `s1` |
| 6 | `a2` | 22 | `s2` |
| 7 | `a3` | 23 | `s3` |
| 8 | `a4` | 24 | `s4` |
| 9 | `a5` | 25 | `s5` |
| 10 | `a6` | 26 | `s6` |
| 11 | `a7` | 27 | `s7` |
| 12 | `t0` | 28 | `s8` |
| 13 | `t1` | 29 | `s9` |
| 14 | `t2` | 30 | `s10` |
| 15 | `t3` | 31 | `fp` |

The assembler also accepts numeric names `r0` through `r31`. These aliases are naming conventions; the emulator itself uses numeric register indices.

The current code does not enforce a calling convention for `ra`, `sp`, argument registers, or saved registers. The names are conveniences for assembly authors, not an ABI guarantee.

## 6. ALU instructions

All ALU mnemonics use this syntax:

```asm
mnemonic destination, register_or_immediate
```

The operation reads the old destination value as the left operand. In register mode, the second operand is another register; in immediate mode, it is a signed 15-bit integer.

For example:

```asm
mov a0, 10     ; a0 = 10
add a0, 5      ; a0 = a0 + 5 = 15
sub a0, 2      ; a0 = a0 - 2 = 13
```

### 6.1 Function-code table

| Mnemonic | Function | Operation |
|---|---:|---|
| `mov` | 0 | `A = operand` |
| `add` | 1 | `A = A + operand` |
| `sub` | 2 | `A = A - operand` |
| `and` | 3 | `A = A & operand` |
| `or` | 4 | `A = A \| operand` |
| `xor` | 5 | `A = A ^ operand` |
| `shl` | 6 | Logical left shift |
| `shr` | 7 | Logical right shift |
| `sar` | 8 | Arithmetic right shift |
| `lt` | 9 | Signed less-than |
| `ltu` | 10 | Unsigned less-than |
| `mul` | 11 | Low 64 bits of multiplication |

The function codes are encoded in bits `[20:16]`.

### 6.2 `mov`

**Syntax:** `mov A, operand`

Copies the second operand into `A`. In register mode, it copies the selected register. In immediate mode, it sign-extends the 15-bit immediate.

```asm
mov a0, a1      ; a0 = a1
mov a0, -1      ; a0 = 0xFFFFFFFFFFFFFFFF
```

The write is discarded if `A` is `zero`.

### 6.3 `add`

**Syntax:** `add A, operand`

Adds the second operand to the old value of `A`. The result wraps modulo \(2^{64}\); no carry or overflow flag is generated.

```asm
mov a0, 40
add a0, 2       ; a0 = 42
```

### 6.4 `sub`

**Syntax:** `sub A, operand`

Subtracts the second operand from the old value of `A`. The result wraps modulo \(2^{64}\).

```asm
mov a0, 3
sub a0, 5       ; a0 = 0xFFFFFFFFFFFFFFFE (-2 as signed)
```

### 6.5 `and`

**Syntax:** `and A, operand`

Performs a bitwise AND. Each result bit is `1` only when both corresponding input bits are `1`.

```asm
mov a0, 0b1100
and a0, 0b1010  ; a0 = 0b1000
```

### 6.6 `or`

**Syntax:** `or A, operand`

Performs a bitwise OR. Each result bit is `1` when either corresponding input bit is `1`.

```asm
mov a0, 0b1100
or a0, 0b0011   ; a0 = 0b1111
```

### 6.7 `xor`

**Syntax:** `xor A, operand`

Performs a bitwise exclusive OR. Each result bit is `1` when the input bits differ.

```asm
mov a0, 0b1100
xor a0, 0b1010  ; a0 = 0b0110
```

### 6.8 `shl`

**Syntax:** `shl A, operand`

Shifts the bits of `A` left. Zero bits enter from the right. Bits shifted out of the 64-bit result are discarded.

The shift amount is the low six bits of the second operand, so the effective count is `operand & 63`.

```asm
mov a0, 3
shl a0, 2       ; a0 = 12
```

### 6.9 `shr`

**Syntax:** `shr A, operand`

Performs a logical right shift. Zero bits enter from the left, regardless of the sign bit.

The effective shift count is the low six bits of the second operand.

```asm
mov a0, -1
shr a0, 1       ; a0 = 0x7FFFFFFFFFFFFFFF
```

### 6.10 `sar`

**Syntax:** `sar A, operand`

Performs an arithmetic right shift by interpreting `A` as a signed two's-complement 64-bit integer. The sign bit is replicated into the high bits.

The effective shift count is the low six bits of the second operand.

```asm
mov a0, -8
sar a0, 1       ; a0 = -4
```

### 6.11 `lt`

**Syntax:** `lt A, operand`

Compares the old value of `A` and the second operand as signed 64-bit integers. It writes `1` if `A < operand`, otherwise `0`.

```asm
mov a0, -3
lt a0, 2        ; a0 = 1, because -3 < 2
```

The comparison result replaces the original destination value.

### 6.12 `ltu`

**Syntax:** `ltu A, operand`

Compares both operands as unsigned 64-bit integers. It writes `1` if the old value of `A` is smaller, otherwise `0`.

```asm
mov a0, -1      ; bit pattern 0xFFFFFFFFFFFFFFFF
ltu a0, 1       ; a0 = 0, because unsigned max is not < 1
```

`lt` and `ltu` differ only in interpretation; the register bits are unchanged.

### 6.13 `mul`

**Syntax:** `mul A, operand`

Multiplies the two 64-bit operands and retains the low 64 bits. The high half of the 128-bit mathematical product is discarded. No overflow flag is produced.

```asm
mov a0, 7
mul a0, 9       ; a0 = 63
```

### 6.14 Immediate constraints

The immediate form uses a signed 15-bit value:

\[
-2^{14} \le immediate \le 2^{14}-1
\]

That is `-16384` through `16383`, inclusive. Larger constants should use `li` or an appropriate `hi`/`pchi` sequence.

## 7. Constant construction

### 7.1 `hi`

**Syntax:** `hi A, imm21`

Constructs a value by sign-extending a signed 21-bit immediate and shifting it left by 15:

\[
R[A] = sign\_extend(imm21) \ll 15
\]

It does not preserve or merge any existing low bits in the destination; the destination is replaced.

```asm
hi a0, 1        ; a0 = 0x0000000000008000
```

The immediate range is `-1048576` through `1048575`.

### 7.2 `pchi`

**Syntax:** `pchi A, imm21`

Adds the shifted, sign-extended immediate to the address of the current instruction:

\[
R[A] = pc + (sign\_extend(imm21) \ll 15)
\]

This is PC-relative construction. The base is the current instruction's PC, not the address of the following instruction.

```asm
pchi a0, 0      ; a0 = address of this pchi instruction
```

The assembler's `la` pseudo-instruction uses `pchi` followed by `add` to construct a label address.

### 7.3 `li` pseudo-instruction

`li A, value` is an assembler pseudo-instruction, not a single opcode.

- If the value fits in a signed 15-bit immediate, it emits one `mov A, immediate`.
- Otherwise, it emits `hi A, upper` and, when the computed lower part is nonzero, `add A, lower`.
- The current implementation checks both the overall value and the signed 21-bit upper part. The exact accepted range is defined by `encodeLi` in `emulator/assembler.zig`; do not assume arbitrary 64-bit constants can be represented by this pseudo-instruction.

For a multi-instruction `li`, labels in the program are calculated using the pseudo-instruction's emitted size.

## 8. Loads and stores

Memory instructions use:

```asm
ld.size destination, [base + offset]
st.size source,      [base + offset]
```

The offset is a signed 16-bit **byte offset**, not a word displacement. The effective address is the base register plus that offset, using wrapping 64-bit addition.

The assembler accepts forms such as:

```asm
ld.w a0, [sp]
ld.w a0, [sp + 4]
st.d ra, [sp - 8]
```

### 8.1 Load instructions

| Mnemonic | Opcode | Bytes | Result |
|---|---:|---:|---|
| `ld.b` | `0x08` | 1 | Sign-extend 8-bit value to 64 bits |
| `ld.bu` | `0x09` | 1 | Zero-extend 8-bit value |
| `ld.h` | `0x0A` | 2 | Sign-extend 16-bit value |
| `ld.hu` | `0x0B` | 2 | Zero-extend 16-bit value |
| `ld.w` | `0x0C` | 4 | Sign-extend 32-bit value |
| `ld.wu` | `0x0D` | 4 | Zero-extend 32-bit value |
| `ld.d` | `0x0E` | 8 | Read full 64-bit value |

The assembly mnemonics map to the internal opcodes `lb`, `lbu`, `lh`, `lhu`, `lw`, `lwu`, and `ld`.

**Example:** if memory contains the byte `0xFF`, `ld.b` produces `0xFFFFFFFFFFFFFFFF`, while `ld.bu` produces `0x00000000000000FF`.

### 8.2 Store instructions

| Mnemonic | Opcode | Bytes written | Value written |
|---|---:|---:|---|
| `st.b` | `0x10` | 1 | Low 8 bits of source register |
| `st.h` | `0x11` | 2 | Low 16 bits |
| `st.w` | `0x12` | 4 | Low 32 bits |
| `st.d` | `0x13` | 8 | All 64 bits |

The source register occupies field `A`; the base register occupies field `B`.

```asm
mov a0, 0x1234
st.b a0, [sp]       ; stores byte 0x34 at address sp
st.h a0, [sp + 2]   ; stores bytes 0x34, 0x12
```

### 8.3 Alignment rules

The emulator requires natural alignment:

| Access width | Required address condition |
|---|---|
| Byte | Any address |
| Halfword (2 bytes) | Address divisible by 2 |
| Word (4 bytes) | Address divisible by 4 |
| Doubleword (8 bytes) | Address divisible by 8 |

An unaligned access halts the CPU with a diagnostic such as `load address misaligned` or `store address misaligned`.

### 8.4 Bounds and memory faults

Normal RAM accesses must fit entirely within the supplied memory slice. A read or write beyond that slice halts the CPU with a load/store access fault.

The UART addresses are special-cased before normal RAM bounds checking. The current UART implementation only special-cases its exact transmit and status addresses; it is not a general peripheral bus.

## 9. Conditional branches

Branches compare two registers. They do not read or write a flags register.

**Syntax:** `branch register_a, register_b, offset_or_label`

The encoded immediate is a signed 16-bit instruction displacement. At execution time, it is shifted left by two bits, making the effective byte displacement a multiple of four:

\[
target = pc + (sign\_extend(imm16) \ll 2)
\]

The displacement is relative to the address of the branch instruction itself. If the condition is false, execution continues at `pc + 4`.

### 9.1 Branch table

| Mnemonic | Opcode | Condition |
|---|---:|---|
| `beq` | `0x18` | `R[A] == R[B]` |
| `bne` | `0x19` | `R[A] != R[B]` |
| `blt` | `0x1A` | signed `R[A] < R[B]` |
| `bge` | `0x1B` | signed `R[A] >= R[B]` |
| `bltu` | `0x1C` | unsigned `R[A] < R[B]` |
| `bgeu` | `0x1D` | unsigned `R[A] >= R[B]` |

The immediate range is `-32768` through `32767` instruction units, corresponding to byte displacements from `-131072` through `131068`.

### 9.2 Example

```asm
mov a0, 5
mov a1, 5
beq a0, a1, equal
mov a2, 0       ; skipped
equal:
mov a2, 1
```

Because `a0` equals `a1`, the branch is taken to `equal`.

### 9.3 Assembler branch aliases

The assembler supports these aliases:

| Alias | Equivalent comparison |
|---|---|
| `bgt A, B, target` | `blt B, A, target` |
| `ble A, B, target` | `bge B, A, target` |
| `bgtu A, B, target` | `bltu B, A, target` |
| `bleu A, B, target` | `bgeu B, A, target` |
| `bz A, target` | `beq A, r0, target` |
| `bnz A, target` | `bne A, r0, target` |

The zero-branch aliases compare the selected register against `r0`, which always reads as zero.

## 10. Jumps and calls

### 10.1 `jal`

**Encoding:** opcode `0x20`, destination/link register in `A`, signed 21-bit displacement in the low bits.

```text
link   = pc + 4
target = pc + (sign_extend(imm21) << 2)
R[A]   = link
pc     = target
```

The target is relative to the current instruction. The displacement is measured in instruction units and scaled by four.

- `jal ra, offset` jumps and saves the return address in `ra`.
- `jal zero, offset` jumps without retaining a link.
- Writing the link to `zero` is discarded, but the jump still occurs.

The signed displacement range is `-1048576` through `1048575` instruction units.

### 10.2 `jalr`

**Syntax at machine level:** `jalr A, B, byte_offset`

The effective target is calculated from register `B` and a signed 16-bit byte offset:

\[
target = (R[B] + sign\_extend(imm16)) \mathbin{\&} \sim 3
\]

Then the CPU writes `pc + 4` to register `A` and jumps to the target. The low two target bits are cleared, forcing the target to a 4-byte boundary.

The target is computed **before** the link register is written. Therefore `A` and `B` may be the same register without changing the address calculation.

### 10.3 Call and return conventions

The assembler provides convenient pseudo-instructions:

```asm
call function
ret
jmp target
jmpr register
```

- `call target` is encoded as `jal ra, offset`.
- `jmp target` is encoded as `jal zero, offset`.
- `ret` is encoded as `jalr zero, ra, 0`.
- `jmpr register` is encoded as `jalr zero, register, 0`.

`ret` therefore jumps to the address stored in `ra`, aligned down to a 4-byte boundary by `jalr`.

The current ISA implementation does not automatically push return addresses onto a stack. Nested calls require software to preserve `ra` when necessary.

## 11. Privileged instruction family

The privileged opcode is `0x2D`. The function code is stored in bits `[20:16]`.

| Mnemonic | Function code | Current behavior |
|---|---:|---|
| `ecall` | 0 | Not implemented; rejected as illegal |
| `ebreak` | 1 | Sets the emulator's `halted` state |

`halt` is an assembler pseudo-instruction that emits `ebreak`.

`ebreak` currently acts as a simple stop instruction, not as a debugger trap with a resumable exception handler. The emulator sets `halted = true`; its normal end-of-step PC assignment still occurs.

There is no implemented system-call ABI, exception vector, interrupt delivery, CSR file, privilege level, or return-from-trap instruction in the current prototype.

## 12. Memory and UART model

### 12.1 Little-endian representation

Multi-byte loads and stores use little-endian order. The least significant byte occupies the lowest address.

For a 64-bit value:

```text
value = 0x1122334455667788

lower address → 88 77 66 55 44 33 22 11 ← higher address
```

A `ld.d` from the first byte reconstructs the original value.

### 12.2 UART transmit

A store whose **effective address is exactly** `0x10000000` is treated as UART transmission, regardless of the store width.

- The low 8 bits of the source value are emitted as one byte.
- The byte is appended to the emulator's 256-byte UART capture buffer while space remains.
- If `echo` is true, the byte is also printed to the terminal.
- Once the capture buffer is full, further bytes may still be echoed, but are not appended to the capture buffer.

For portable output, software should use a byte store (`st.b`) to this address.

### 12.3 UART status

A load whose effective address is exactly `0x10000004` returns `1`. The current implementation does not model changing ready/busy bits or an empty transmit FIFO; the status value is constant.

### 12.4 Peripheral limitations

The UART is a minimal emulator convenience, not a complete UART controller. There is no configurable baud rate, receive path, interrupt signaling, FIFO register map, or bus timing model.

## 13. Assembler reference

The assembler in `emulator/assembler.zig` supports one-line instruction assembly and whole-program assembly. Whole-program assembly uses two passes so that labels can be resolved before instruction bytes are emitted.

### 13.1 Registers and numbers

Register names may be numeric (`r0`–`r31`) or aliases listed in [Register conventions](#5-register-conventions).

Numbers are parsed with base autodetection, so decimal, hexadecimal (`0x...`), and binary (`0b...`) forms are supported. A single character in single quotes, such as `'A'`, is also accepted as a numeric character value in supported numeric operands.

### 13.2 Comments and labels

A semicolon starts a comment outside quoted strings:

```asm
mov a0, 5 ; initialize counter
```

Labels end with a colon and must begin with a letter or underscore. Remaining characters may be letters, digits, underscores, or dots.

```asm
loop:
    sub a0, 1
    bnz a0, loop
```

The assembler supports up to 64 labels. Duplicate labels are rejected.

### 13.3 Branch and jump label semantics

For branch and `jal` label operands, the assembler calculates the displacement in 4-byte instruction units relative to the current instruction address. Labels must resolve to instruction-aligned addresses.

For `jalr`, the base register plus a byte offset is used directly; label-based `jalr` operands are not supported by the syntax shown here.

### 13.4 Pseudo-instructions

| Pseudo-instruction | Expansion / behavior |
|---|---|
| `li A, value` | One `mov` for signed 15-bit values; otherwise `hi` plus optional `add` |
| `la A, label` | `pchi` plus `add` to form a PC-relative label address |
| `jmp target` | `jal zero, target` |
| `call target` | `jal ra, target` |
| `jmpr R` | `jalr zero, R, 0` |
| `ret` | `jalr zero, ra, 0` |
| `halt` | `ebreak` |
| `nop` | `mov zero, 0` |

A `nop` has no architectural effect except normal PC advancement.

`la` emits two instructions. It uses the current instruction address as the base for the `pchi` calculation and adds a signed low part in a following ALU instruction.

### 13.5 Data and layout directives

| Directive | Meaning |
|---|---|
| `.byte n, ...` | Emit one byte per value |
| `.half n, ...` | Emit 16-bit values, little-endian |
| `.word n, ...` | Emit 32-bit values, little-endian |
| `.dword n, ...` | Emit 64-bit values, little-endian |
| `.ascii "..."` | Emit string bytes without a terminator |
| `.asciz "..."` | Emit string bytes followed by a zero byte |
| `.space n` | Emit `n` zero bytes |
| `.align n` | Emit zero padding until the current byte position is divisible by `n` |

String escapes supported by the current assembler include `\n`, `\t`, `\r`, `\0`, `\\`, and `\"`.

Instructions must begin at a byte position divisible by four. If data directives leave the output position misaligned, use `.align 4` before the next instruction.

The current `.align n` implementation aligns to a byte multiple of `n`; it does not interpret `n` as a power-of-two exponent.

### 13.6 Assembler APIs

- `assembleLine(line)` assembles one instruction line into one 32-bit word. It cannot resolve labels or return multi-instruction expansions; operations requiring a whole program return `NeedsProgram`.
- `assembleBytes(source, out, bad_line)` assembles a complete source string into `out`, resolves labels in two passes, writes instruction words little-endian, and returns the emitted byte count.
- On failure, `bad_line` is updated to the source line being processed.

The assembler reports structured errors for invalid mnemonics, wrong operand counts, invalid registers, malformed operands, out-of-range immediates, unknown or duplicate labels, unsupported directives, misaligned instructions/labels, and output buffers that are too small.

## 14. Worked examples

### 14.1 Summation loop

```asm
mov a0, 0       ; sum = 0
mov a1, 1       ; i = 1
mov a2, 11      ; limit = 11

loop:
add a0, a1      ; sum += i
add a1, 1       ; i += 1
bne a1, a2, loop
halt
```

The loop accumulates the integers from 1 through 10. When `a1` becomes 11, `bne` is not taken and the program halts. The final sum is `a0 = 55`.

### 14.2 Signed versus unsigned comparison

Because ALU instructions use the destination as the first source, a comparison must place the value being compared in the destination register. For example:

```asm
li a0, -1
lt a0, 1        ; signed -1 < 1, so a0 becomes 1

li a1, -1
ltu a1, 1       ; unsigned 0xFFFF...FFFF < 1 is false, so a1 becomes 0
```

The destination register is overwritten by the Boolean result.

### 14.3 Store then load

```asm
; Assume sp points to an 8-byte-aligned RAM address.
li a0, 0x12345678
st.w a0, [sp]
ld.w a1, [sp]
```

`st.w` stores the low 32 bits in little-endian order. `ld.w` sign-extends the loaded 32-bit value to 64 bits. For values whose top bit is zero, `a1` contains the same positive numeric value.

### 14.4 Call and return

```asm
call function
halt

function:
    ; function body
    ret
```

`call` writes the address of the instruction after the call into `ra`. `ret` jumps to that address. The example is illustrative; a real function that makes another call must preserve its own return address.

## 15. Faults, reserved encodings, and current limitations

The following details matter when writing software or designing tests.

1. **Fetch bounds are not modeled as a CPU fault.** Fetch directly indexes four bytes at the current PC; an invalid PC can cause a runtime bounds failure.
2. **Instruction fetch alignment is not checked explicitly.** Correct software should keep the PC 4-byte aligned.
3. **Load/store alignment is checked.** Accesses must be naturally aligned to their width.
4. **RAM bounds are checked.** Normal memory accesses outside the supplied byte slice halt with an access fault.
5. **Unknown opcodes are illegal.** Unknown ALU function codes are also illegal.
6. **`ecall` is not implemented.** It currently follows the illegal-instruction path.
7. **`ebreak` halts.** It does not invoke a resumable debug handler.
8. **There is no flags register.** ALU comparisons write `0` or `1` to a destination.
9. **Arithmetic wraps.** `add`, `sub`, and `mul` retain only the low 64 bits; no arithmetic trap or overflow flag is generated.
10. **Reserved ALU payload bits are not fully validated.** In register mode, only the low five payload bits select the second register.
11. **UART behavior is intentionally minimal.** The status read returns constant `1`, and only exact transmit/status addresses are special-cased.
12. **The ABI is not finalized.** Register aliases are provided, but caller/callee-save rules, stack layout, and system-call conventions are not enforced.
13. **The ISA remains a prototype.** Opcode assignments and encoding details should be frozen only alongside a versioned specification and tests.

When implementation and documentation disagree, treat the source code and tests as the current executable behavior, then update either the code or this document explicitly. Avoid silently changing instruction semantics: encoding and behavior changes should be accompanied by tests for both the normal case and relevant edge cases.

