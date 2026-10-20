# BARE64 ISA — Current Prototype

**Instruction width:** 32 bits.  
**Byte order:** little-endian.  
**Scope:** this document describes the current prototype, not a finalized ISA release.

## Design principles

- 32 general-purpose 64-bit registers: `r0`–`r31`.
- `r0` always reads as zero. Writes to `r0` are discarded.
- The program counter (`pc`) is a 64-bit byte address.
- Instructions are 4 bytes long and normally advance `pc` by 4.
- Arithmetic uses two-operand semantics: the destination is also the first source.
- Immediate arithmetic is supported.
- The current CPU halts on `ebreak` and on an illegal instruction.
- Memory instructions, CSR instructions, atomics, interrupts, and a full privilege model are not implemented in this prototype.

## Register naming

The emulator uses `r0`–`r31`. The sample program uses these conventional aliases:

| Alias | Register |
|---|---:|
| `zero` | `r0` |
| `a0` | `r4` |
| `a1` | `r5` |
| `a2` | `r6` |

These aliases are assembler/source-code conventions only; the current emulator stores numeric register indices.

## Instruction encoding

Every instruction is a 32-bit word stored little-endian.

### Opcode field

Bits `[31:26]` contain a 6-bit opcode.

| Opcode | Mnemonic/family | Status |
|---:|---|---|
| `0x00` | `illegal` | Reserved; all-zero word must not execute |
| `0x01` | `alu` | Implemented ALU family |
| `0x03` | `hi` | Implemented |
| `0x04` | `pchi` | Implemented |
| `0x18` | `beq` | Implemented |
| `0x19` | `bne` | Implemented |
| `0x1A` | `blt` | Implemented |
| `0x1B` | `bge` | Implemented |
| `0x1C` | `bltu` | Implemented |
| `0x1D` | `bgeu` | Implemented |
| `0x20` | `jal` | Implemented |
| `0x21` | `jalr` | Implemented |
| `0x2D` | `priv` | `ebreak` implemented; `ecall` currently halts as illegal |

All other opcodes currently halt as illegal instructions.

### ALU instruction format

The `alu` opcode uses the following fields:

| Bits | Width | Meaning |
|---|---:|---|
| `[31:26]` | 6 | Opcode (`0x01`) |
| `[25:21]` | 5 | `A`: destination and first source register |
| `[20:16]` | 5 | `Func`: ALU operation |
| `[15]` | 1 | `I`: `1` means immediate mode; `0` means register mode |
| `[14:0]` | 15 | Operand payload |

In register mode, the low five bits of the payload select the second source register. In immediate mode, the low 15 bits are a signed two's-complement immediate. Thus the immediate range is `-16384` through `16383`.

For now, the decoder does not validate every unused payload bit in register mode. Encodings that set those unused bits should be considered non-canonical and avoided.

### ALU function codes

The function code occupies bits `[20:16]`.

| Function | Code | Semantics |
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
| `lt` | 9 | Signed less-than: `A = signed(A) < signed(operand)` |
| `ltu` | 10 | Unsigned less-than |
| `mul` | 11 | Low 64 bits of multiplication |

`mov` is an exception to the normal two-operand pattern: in register mode it copies the selected source register to `A`; in immediate mode it loads the sign-extended immediate into `A`.

Arithmetic wraps modulo \(2^{64}\) for `add`, `sub`, and `mul`. Shift counts use the low six bits of the second operand.

For `lt` and `ltu`, the boolean result (`0` or `1`) replaces the destination register, as with all current ALU operations.

### `hi` and `pchi`

These instructions use:

- bits `[31:26]`: opcode;
- bits `[25:21]`: destination register `A`;
- bits `[20:0]`: signed 21-bit immediate.

The immediate is sign-extended and shifted left by 15 bits.

- `hi A, imm`: `A = sign_extend(imm21) << 15`
- `pchi A, imm`: `A = pc + (sign_extend(imm21) << 15)`

For `pchi`, `pc` is the address of the current instruction.

### Branch instructions

`beq`, `bne`, `blt`, `bge`, `bltu`, and `bgeu` use:

| Bits | Meaning |
|---|---|
| `[31:26]` | Branch opcode |
| `[25:21]` | First register |
| `[20:16]` | Second register |
| `[15:0]` | Signed 16-bit word displacement |

If the condition is true:

`pc = current_pc + (sign_extend(imm16) << 2)`

The displacement is measured in 4-byte instructions, relative to the address of the branch itself. If the condition is false, `pc` advances by 4.

Comparison rules:
- `beq`: equal
- `bne`: not equal
- `blt`: signed less-than
- `bge`: signed greater-than-or-equal
- `bltu`: unsigned less-than
- `bgeu`: unsigned greater-than-or-equal

### `jal`

Fields:
- `[31:26]`: opcode `0x20`
- `[25:21]`: link/destination register `A`
- `[20:0]`: signed 21-bit word displacement

Semantics:

```text
A  = current_pc + 4
pc = current_pc + (sign_extend(imm21) << 2)
```

The target is relative to the address of the `jal` instruction.

### `jalr`

Fields:
- `[31:26]`: opcode `0x21`
- `[25:21]`: destination/link register `A`
- `[20:16]`: base register `B`
- `[15:0]`: signed 16-bit byte offset

Semantics:

```text
target = (R[B] + sign_extend(imm16)) & ~3
A      = current_pc + 4
pc     = target
```

The target is computed before writing `A`, so `A` and `B` may be the same register.

### Privileged family

Opcode `0x2D` uses the function field in bits `[20:16]`.

| Function | Code | Current behavior |
|---|---:|---|
| `ecall` | 0 | Not implemented; treated as illegal and halts |
| `ebreak` | 1 | Sets `halted = true` |

The current `step()` still advances `pc` by 4 after `ebreak`, because the normal `next_pc` is committed at the end of the step.

## Assembly examples

The current source is closer to an encoding demo than a complete assembler. These are the semantics represented by the helper encoders in `main`:

```asm
mov a0, 0       ; sum = 0
mov a1, 1       ; i = 1
mov a2, 11      ; limit = 11

loop:
add a0, a1      ; sum += i
add a1, 1       ; i += 1
bne a1, a2, -2  ; branch back two instructions if i != 11
ebreak
```

The example computes `1 + 2 + ... + 10 = 55`.

## Current implementation limitations and caveats

These are deliberate prototype limitations, not promises of the final ISA:

1. **Fetch safety:** `fetch()` currently indexes memory directly. An invalid or out-of-range `pc` can panic instead of producing an architectural trap.
2. **Alignment:** there is no explicit check that `pc` is four-byte aligned.
3. **Invalid encodings:** the CPU does not validate all reserved bits or all-zero instruction words specially beyond the opcode behavior.
4. **Enum decoding:** `@enumFromInt` with non-exhaustive enums accepts unknown values into the enum; the switch's `else` branch is what rejects unknown ALU functions.
5. **Immediate width:** ALU immediate mode uses a signed 15-bit immediate because bit 15 is the immediate-mode flag.
6. **No memory ISA yet:** loads/stores are not implemented.
7. **No full system behavior:** `ecall`, interrupts, CSR operations, privilege levels, and system-call handling are not implemented.
8. **No assembler:** the helper functions in the sample program manually encode machine words.
9. **No flags register:** comparisons write `0` or `1` into their destination; branches compare registers directly.
10. **No compatibility promise:** opcode assignments and encodings are provisional until frozen by a versioned specification and tests.

## Running tests

From the project root, assuming `cpu.zig` is in `src/` beside `cpu_test.zig`:

```sh
zig test src/cpu_test.zig
```

The tests exercise the sample summation program, two-operand arithmetic, signed immediates, basic ALU operations, `r0`, branches, jumps, and `ebreak`.

These tests describe the current prototype. If the instruction encoding or semantics change, update both the tests and this document in the same change.

