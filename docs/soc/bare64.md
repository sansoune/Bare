# BARE64: ISA and Emulator Reference

> **Status:** prototype specification
> **Source of truth:** `emulator/isa.zig`, `emulator/cpu.zig`, `emulator/memory.zig`, `emulator/uart.zig`, `emulator/assembler.zig`, and the tests in `test/`
> **Instruction width:** 32 bits
> **Register width:** 64 bits
> **Byte order:** little-endian

This document describes the BARE64 instruction set and the emulator that implements it. It is a reference for the code as it exists today, not a plan. Where the project has not built something yet (interrupts, privilege levels, virtual memory, a pipeline, caches), the document says so in [section 14](#14-limitations-and-future-work) instead of describing it as if it existed.

When the documentation and the code disagree, the code and its tests are the current behavior. Fix the disagreement on purpose: change the code or this file, and add a test for the edge case.

## Contents

1. [Overview and source layout](#1-overview-and-source-layout)
2. [Architectural state](#2-architectural-state)
3. [Execution model](#3-execution-model)
4. [Instruction encoding](#4-instruction-encoding)
5. [Registers](#5-registers)
6. [ALU instructions](#6-alu-instructions)
7. [Building constants](#7-building-constants)
8. [Loads and stores](#8-loads-and-stores)
9. [Branches](#9-branches)
10. [Jumps and calls](#10-jumps-and-calls)
11. [Privileged instructions](#11-privileged-instructions)
12. [Memory map, RAM and UART](#12-memory-map-ram-and-uart)
13. [Faults](#13-faults)
14. [Limitations and future work](#14-limitations-and-future-work)
15. [Assembler reference](#15-assembler-reference)
16. [Worked examples](#16-worked-examples)
17. [Running and testing](#17-running-and-testing)

---

## 1. Overview and source layout

BARE64 is a small 64-bit RISC-style instruction set. Every instruction is one 32-bit word. There are 32 general-purpose registers, no flags register, and a simple load/store memory model. The emulator executes one instruction per `step()` call.

The emulator is split into small modules, each with one job:

| File | Responsibility |
|---|---|
| `emulator/isa.zig` | The instruction set definition: the `Opcode`, `Func` and `Priv` enums, and the functions that encode instructions into 32-bit words |
| `emulator/cpu.zig` | The CPU: registers, program counter, fetch, decode, execute, and the fault record |
| `emulator/memory.zig` | Plain RAM access: bounds-checked, little-endian loads and stores on a byte slice |
| `emulator/uart.zig` | The UART device: the transmit and status addresses and the output capture buffer |
| `emulator/assembler.zig` | The assembler: turns assembly text into machine-code bytes |
| `emulator/emu.zig` | The command-line program: assemble a `.s` file, run it, report the result |

The dependencies run in one direction. `cpu.zig` uses `isa.zig`, `memory.zig` and `uart.zig`. `memory.zig` and `uart.zig` know nothing about the CPU or about each other. `assembler.zig` uses `isa.zig` to encode instructions.

Throughout this document "the CPU" means the architectural behavior the emulator models. A future hardware design may split that behavior into different blocks, but it must produce the same architectural results unless the ISA is deliberately revised.

## 2. Architectural state

| State | Form | Purpose |
|---|---|---|
| `regs[0..31]` | 32 x 64-bit | General-purpose registers |
| `pc` | 64-bit byte address | Address of the instruction about to execute. Starts at `0` |
| `mem` | byte slice | RAM, which also holds the program image |
| `halted` | boolean | When true, the host stops calling `step()` |
| `fault` | optional `Fault` | Why the CPU stopped, when it stopped because of a fault. `null` otherwise |
| UART buffer | `uart.Buffer` | A copy of everything the program transmitted (see [section 12.3](#123-uart)) |

At reset every register is zero, `pc` is `0`, `halted` is false and `fault` is `null`.

### 2.1 Register file

- 32 registers, `r0` to `r31`, each 64 bits wide.
- `r0` is hardwired to zero. Reads return `0`; writes are discarded.
- An instruction reads up to two registers and writes at most one.
- There is no carry, zero, negative or overflow flag. Comparisons write `0` or `1` into a register.

### 2.2 Program counter

- `pc` is a byte address, not an instruction index.
- Sequential execution advances it by 4.
- Branches and jumps replace the sequential address with a computed target.
- `pc` arithmetic wraps modulo 2^64.
- Instruction addresses must be multiples of 4. See [section 13.2](#132-fetch-faults).

### 2.3 Programmatic access

The host program and the tests inspect the machine directly:

- `getReg(i)` and `setReg(i, v)` read and write registers. `setReg(0, v)` does nothing.
- `pc`, `halted` and `fault` are plain fields.
- The UART buffer's `text()` returns what the program transmitted.

## 3. Execution model

`step()` executes one instruction:

1. **Fetch.** Read the 32-bit little-endian word at `pc`. If `pc` is misaligned or the word does not fit in RAM, raise a fetch fault and stop (see [section 13.2](#132-fetch-faults)).
2. **Decode.** Split the word into the opcode, register fields, function code and immediates.
3. **Prepare the next pc.** `next_pc = pc + 4`.
4. **Execute.** Run the ALU operation, compute an address, evaluate a branch, or perform the privileged operation. Branches and jumps overwrite `next_pc`.
5. **Access memory** if the instruction is a load or store (see [section 8](#8-loads-and-stores)).
6. **Write back.** Update the destination register, when there is one. Writes to `r0` are discarded.
7. **Commit.** If no fault was raised, `pc = next_pc`.

Two rules follow from step 7:

- **A faulting instruction leaves `pc` on itself.** After a fault, `cpu.pc` equals `cpu.fault.?.pc`, and nothing the instruction would have written has been written.
- **`ebreak` is not a fault.** It sets `halted`, and `pc` advances past the `ebreak`.

A host drives the CPU with a loop such as:

```zig
var steps: usize = 0;
while (!cpu.halted and steps < max_steps) : (steps += 1) cpu.step();
```

The step limit protects the host from programs that never halt. Both the command-line program and the test helpers use it.

## 4. Instruction encoding

All instructions are 32-bit words. Bit 31 is the most significant bit. In memory the bytes are stored little-endian, so the word `0x04810005` appears as the bytes `05 00 81 04`.

The opcode always occupies bits `[31:26]`. The remaining bits depend on the format.

### 4.1 Opcode map

| Opcode | Name | Format | Notes |
|---:|---|---|---|
| `0x00` | `illegal` | n/a | An all-zero word is illegal by design |
| `0x01` | `alu` | ALU | All arithmetic and logic |
| `0x03` | `hi` | L | Load the upper part of a constant |
| `0x04` | `pchi` | L | PC-relative upper part |
| `0x08` | `lb` | I | Load byte, sign-extended |
| `0x09` | `lbu` | I | Load byte, zero-extended |
| `0x0A` | `lh` | I | Load halfword, sign-extended |
| `0x0B` | `lhu` | I | Load halfword, zero-extended |
| `0x0C` | `lw` | I | Load word, sign-extended |
| `0x0D` | `lwu` | I | Load word, zero-extended |
| `0x0E` | `ld` | I | Load doubleword |
| `0x10` | `sb` | I | Store byte |
| `0x11` | `sh` | I | Store halfword |
| `0x12` | `sw` | I | Store word |
| `0x13` | `sd` | I | Store doubleword |
| `0x18` | `beq` | I | Branch if equal |
| `0x19` | `bne` | I | Branch if not equal |
| `0x1A` | `blt` | I | Branch if signed less than |
| `0x1B` | `bge` | I | Branch if signed greater or equal |
| `0x1C` | `bltu` | I | Branch if unsigned less than |
| `0x1D` | `bgeu` | I | Branch if unsigned greater or equal |
| `0x20` | `jal` | L | Jump and link, PC-relative |
| `0x21` | `jalr` | I | Jump and link, register-based |
| `0x2D` | `priv` | P | Privileged family; only `ebreak` works |

Every other opcode value is illegal.

### 4.2 ALU format

```text
 31       26 25       21 20       16 15 14             0
+-----------+-----------+-----------+-+----------------+
|  opcode   |     A     |   Func    |I|    payload      |
+-----------+-----------+-----------+-+----------------+
    6 bits     5 bits      5 bits    1      15 bits
```

| Bits | Meaning |
|---|---|
| `[31:26]` | Opcode `0x01` |
| `[25:21]` | `A`: destination register, and also the first source |
| `[20:16]` | Function code (see [section 6](#6-alu-instructions)) |
| `[15]` | `I`: `0` = register operand, `1` = immediate operand |
| `[14:0]` | The second operand |

With `I = 0`, the low five bits of the payload select the second source register. Bits `[14:5]` are ignored by the current decoder, so software should leave them zero.

With `I = 1`, the payload is a signed 15-bit immediate (range `-16384` to `16383`), sign-extended to 64 bits before the operation.

The same opcode serves both modes. `add a0, a1` and `add a0, 5` differ only in bit 15.

### 4.3 L format: `hi`, `pchi`, `jal`

```text
 31       26 25       21 20                            0
+-----------+-----------+-------------------------------+
|  opcode   |     A     |          signed imm21         |
+-----------+-----------+-------------------------------+
```

The low 21 bits are a signed immediate. What it means depends on the opcode:

- `hi`, `pchi`: sign-extended, then shifted left by 15.
- `jal`: sign-extended, then shifted left by 2 (a distance in instructions).

### 4.4 I format: loads, stores, branches, `jalr`

```text
 31       26 25       21 20       16 15                 0
+-----------+-----------+-----------+--------------------+
|  opcode   |     A     |     B     |       imm16        |
+-----------+-----------+-----------+--------------------+
```

| Instruction | `A` | `B` | `imm16` |
|---|---|---|---|
| Load | destination | base register | signed byte offset |
| Store | source (data) register | base register | signed byte offset |
| Branch | first compared register | second compared register | signed distance in instructions |
| `jalr` | link destination | base register | signed byte offset |

Stores and branches share the layout: `A` is the register named first in the assembly.

### 4.5 P format: `priv`

The opcode is `0x2D` and bits `[20:16]` hold the function code (`ecall` = 0, `ebreak` = 1). The other bits are not used.

### 4.6 Encoder functions

`isa.zig` provides one encoder per format. The assembler and the tests both use them:

| Function | Produces |
|---|---|
| `aluReg(f, dst, src)` | ALU word, register mode |
| `aluImm(f, dst, imm)` | ALU word, immediate mode |
| `iT(op, a, b, imm)` | I-format word |
| `lT(op, rd, imm)` | L-format word |
| `loadT(op, rd, base, offset)` | Load (same layout as `iT`) |
| `storeT(op, src, base, offset)` | Store (same layout as `iT`) |
| `ebreak()` | The `ebreak` word |

Hand-computed examples, which the encoder tests check:

| Instruction | Word |
|---|---|
| `add a0, a1` | `0x04810005` |
| `add a1, 1` | `0x04A18001` |
| `mov a0, 0` | `0x04808000` |
| `bne a1, a2, -2` | `0x64A6FFFE` |
| `hi a0, 0x2000` | `0x0C802000` |
| `ebreak` | `0xB4010000` |

## 5. Registers

The machine knows registers only by number, `r0` to `r31`. The assembler also accepts these names, which are conventions and nothing more:

| Index | Name | Index | Name |
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

Intended roles are `ra` for the return address, `sp` for the stack pointer, `a0`-`a7` for arguments and results, `t0`-`t7` for temporaries and `s0`-`s10` for saved values. The hardware enforces none of this. There is no finalized ABI yet: nothing initializes `sp`, and no calling convention is checked.

## 6. ALU instructions

Every ALU instruction has the same shape:

```asm
mnemonic destination, register_or_immediate
```

The destination is also the left operand. `add a0, a1` means `a0 = a0 + a1`.

### 6.1 Function codes

| Mnemonic | Code | Result written to `A` |
|---|---:|---|
| `mov` | 0 | `operand` |
| `add` | 1 | `A + operand` |
| `sub` | 2 | `A - operand` |
| `and` | 3 | `A & operand` |
| `or` | 4 | `A \| operand` |
| `xor` | 5 | `A ^ operand` |
| `shl` | 6 | `A << (operand & 63)` |
| `shr` | 7 | `A >> (operand & 63)`, logical (zeros enter) |
| `sar` | 8 | `A >> (operand & 63)`, arithmetic (sign bit enters) |
| `lt` | 9 | `1` if `A < operand` as signed numbers, else `0` |
| `ltu` | 10 | `1` if `A < operand` as unsigned numbers, else `0` |
| `mul` | 11 | Low 64 bits of `A * operand` |

Function codes 12 to 31 are reserved. Using one is an illegal instruction and changes nothing.

### 6.2 Details

- **Wrapping.** `add`, `sub` and `mul` wrap modulo 2^64. No trap, no flag.
- **Shifts** use only the low six bits of the operand, so shifting by 64 is shifting by 0. A negative immediate also uses its low six bits.
- **Immediates** are sign-extended before the operation. `mov a0, -1` gives `0xFFFFFFFFFFFFFFFF`. For `ltu`, `ltu a0, -1` compares against 2^64 - 1.
- **Comparisons** overwrite the destination with the result, so the value you compared is lost. Copy it first if you still need it.
- **Writes to `zero`** are discarded.

```asm
mov a0, 40
add a0, 2        ; a0 = 42
mov a1, -8
sar a1, 1        ; a1 = -4
mov a2, -1
shr a2, 1        ; a2 = 0x7FFFFFFFFFFFFFFF
mov a3, -3
lt  a3, 2        ; a3 = 1, since -3 < 2
```

## 7. Building constants

An ALU immediate holds 15 bits. Larger constants are built in two steps.

### 7.1 `hi`

```text
hi A, imm21        A = sign_extend(imm21) << 15
```

It replaces the whole register; it does not merge with old bits. The immediate range is `-1048576` to `1048575`, so `hi` can produce any multiple of 2^15 from about -2^35 to 2^35.

```asm
hi a0, 1           ; a0 = 0x8000
hi a0, 0x2000      ; a0 = 0x10000000
```

### 7.2 `pchi`

```text
pchi A, imm21      A = pc + (sign_extend(imm21) << 15)
```

The base is the address of the `pchi` instruction itself, not `pc + 4`. It is the building block for PC-relative addresses, such as the labels that `la` loads.

### 7.3 Pseudo-instructions `li` and `la`

The assembler turns these into the instructions above (details in [section 15.5](#155-pseudo-instructions)):

- `li A, value` loads a constant. One `mov` if it fits in 15 bits, otherwise `hi` plus an `add` for the low part (the `add` is skipped when the low part is zero).
- `la A, label` loads the address of a label with `pchi` followed by `add`. It is always two instructions.

## 8. Loads and stores

### 8.1 Syntax

```asm
ld.size  destination, [base + offset]
st.size  source,      [base + offset]
```

The offset is optional (`[a2]`) and may be negative (`[sp - 8]`). The effective address is

```text
address = R[B] + sign_extend(imm16)        (wrapping 64-bit addition)
```

The offset range is `-32768` to `32767` bytes.

### 8.2 Loads

| Mnemonic | Bytes | Result |
|---|---:|---|
| `ld.b` | 1 | Sign-extended to 64 bits |
| `ld.bu` | 1 | Zero-extended |
| `ld.h` | 2 | Sign-extended |
| `ld.hu` | 2 | Zero-extended |
| `ld.w` | 4 | Sign-extended |
| `ld.wu` | 4 | Zero-extended |
| `ld.d` | 8 | Full 64 bits |

A memory byte `0xFE` loads as `0xFFFFFFFFFFFFFFFE` with `ld.b` and as `0xFE` with `ld.bu`.

### 8.3 Stores

| Mnemonic | Bytes written | Value written |
|---|---:|---|
| `st.b` | 1 | Low 8 bits of the source |
| `st.h` | 2 | Low 16 bits |
| `st.w` | 4 | Low 32 bits |
| `st.d` | 8 | All 64 bits |

A store writes only its own bytes. Storing the byte `0x7F` at address 129 changes nothing but that one byte.

### 8.4 How an access is carried out

The CPU performs every access in the same order:

1. Compute the effective address.
2. **Alignment check.** The address must be a multiple of the access size. If not, raise `load_misaligned` or `store_misaligned`.
3. **Device and RAM access.**
   - A load first asks the UART (`uart.load`). If the address is the UART status register, the load returns `1`. Otherwise the load goes to RAM through `memory.load`.
   - A store to the UART transmit address calls `uart.transmit` with the value. Any other store goes to RAM through `memory.store`.
4. If RAM rejects the access (it does not fit inside the RAM slice), raise `load_access` or `store_access`.
5. Otherwise a load writes the extended value to the destination register.

On any fault the instruction changes nothing: the destination register keeps its old value, and no byte of RAM is written. Because the alignment check comes first, a misaligned access to a device address is a misalignment fault, not a device access.

The CPU does the sign extension. `memory.load` returns the raw bytes as a zero-extended `u64`, and the CPU extends them for `lb`, `lh` and `lw`.

## 9. Branches

A branch compares two registers directly. There is no flags register.

```asm
beq  a0, a1, target
```

If the condition is true, `pc` becomes

```text
pc + (sign_extend(imm16) << 2)
```

The distance is measured in instructions from the branch itself. Otherwise execution continues at `pc + 4`.

### 9.1 Branch instructions

| Mnemonic | Taken when |
|---|---|
| `beq` | `R[A] == R[B]` |
| `bne` | `R[A] != R[B]` |
| `blt` | signed `R[A] < R[B]` |
| `bge` | signed `R[A] >= R[B]` |
| `bltu` | unsigned `R[A] < R[B]` |
| `bgeu` | unsigned `R[A] >= R[B]` |

The distance range is `-32768` to `32767` instructions, which is `-131072` to `131068` bytes.

### 9.2 Assembler aliases

The assembler also accepts these. The first four swap the registers; the last two compare against `zero`:

| Alias | Becomes |
|---|---|
| `bgt A, B, t` | `blt B, A, t` |
| `ble A, B, t` | `bge B, A, t` |
| `bgtu A, B, t` | `bltu B, A, t` |
| `bleu A, B, t` | `bgeu B, A, t` |
| `bz A, t` | `beq A, zero, t` |
| `bnz A, t` | `bne A, zero, t` |

### 9.3 Example

```asm
mov a0, 5
mov a1, 5
beq a0, a1, equal
mov a2, 0          ; skipped
equal:
mov a2, 1
```

## 10. Jumps and calls

### 10.1 `jal`

```text
R[A] = pc + 4
pc   = pc + (sign_extend(imm21) << 2)
```

The distance is in instructions, relative to the `jal`, with a range of `-1048576` to `1048575` instructions. If `A` is `zero`, the link is discarded and `jal` is a plain jump.

### 10.2 `jalr`

```text
target = (R[B] + sign_extend(imm16)) & ~3
R[A]   = pc + 4
pc     = target
```

The target is computed before the link is written, so `A` and `B` may be the same register. The low two bits of the target are cleared, so a `jalr` target is always 4-byte aligned.

### 10.3 Pseudo-instructions

| Assembly | Encoded as |
|---|---|
| `jmp target` | `jal zero, target` |
| `call target` | `jal ra, target` |
| `jmpr R` | `jalr zero, R, 0` |
| `ret` | `jalr zero, ra, 0` |

`call` puts the return address in `ra`; `ret` jumps back to it. Nothing saves `ra` for you: a function that makes another call must save it first.

## 11. Privileged instructions

| Mnemonic | Function code | Behavior |
|---|---:|---|
| `ecall` | 0 | Not implemented. Raises `illegal_instruction` |
| `ebreak` | 1 | Sets `halted`. No fault is recorded |

`halt` is an assembler pseudo-instruction that emits `ebreak`.

`ebreak` is a plain stop for now, not a debugger trap. Nothing can resume after it. Function codes 2 to 31 are reserved and raise `illegal_instruction`.

## 12. Memory map, RAM and UART

### 12.1 Address map

| Address | Meaning | Access |
|---|---|---|
| `0` to `len - 1` | RAM, where `len` is the size of the RAM slice | read, write |
| `0x1000_0000` | UART transmit | write only |
| `0x1000_0004` | UART status | read only |

The command-line program uses 4096 bytes of RAM. The program is loaded at address 0 and `pc` starts there. Code, data and the stack area (when you create one) share the same RAM.

The UART addresses are checked before RAM. Every other address that lies outside RAM is an access fault.

### 12.2 RAM (`memory.zig`)

`memory.zig` is a bare byte-slice accessor with two functions:

```zig
pub fn load(mem: []const u8, addr: u64, size: u64) ?u64
pub fn store(mem: []u8, addr: u64, size: u64, value: u64) bool
```

- `size` is 1, 2, 4 or 8. Anything else is a programming error in the caller.
- Values are little-endian: the least significant byte lives at the lowest address.
- `load` returns the bytes zero-extended into a `u64`, or `null` if the access does not fit.
- `store` writes the low `size` bytes of `value`, or returns `false` and writes nothing if the access does not fit.
- The bounds check is written as `addr > len - size` (after checking `size > len`), so a huge address cannot overflow.
- It checks bounds only. Alignment is the CPU's job.

The last byte of RAM is readable; one byte past it is an access fault.

### 12.3 UART (`uart.zig`)

The UART is a minimal output device, a convenience for printing from emulated programs. It is not a full UART controller.

```zig
pub const uart_tx: u64 = 0x1000_0000;
pub const uart_status: u64 = 0x1000_0004;

pub const Buffer = struct { bytes: [256]u8, len: usize, echo: bool = true, ... };
```

**Transmit.** A store whose effective address is exactly `0x1000_0000` calls `Buffer.transmit`:

- Only the low 8 bits of the stored value matter, whatever the store width. `st.w` of `0x1234` transmits `0x34`, the character `'4'`.
- The byte is appended to the 256-byte capture buffer while there is room. When the buffer is full, further bytes are not captured.
- If `echo` is true, the byte is also printed to the terminal. A full buffer does not stop echoing.
- For portable code, use `st.b`.

**Status.** `uart.load(addr)` returns `1` for the exact address `0x1000_0004` and `null` for anything else. The status is a constant "always ready"; there is no busy flag, receive path, FIFO or interrupt.

**Not readable.** Reading the transmit address is a `load_access` fault, because `uart.load` declines it and RAM does not reach that address. The status register is aligned for 1, 2 and 4-byte loads. An `ld.d` of it is misaligned, since the address is not a multiple of 8.

**Host side.** `Buffer.text()` returns the captured bytes. Tests set `echo = false` and compare the captured text.

Any other address next to the UART (such as `0x1000_0008`) is not a device: it faults.

## 13. Faults

A fault stops the machine and records what happened. The CPU stores it in `cpu.fault`, an optional `FaultInfo`:

```zig
pub const FaultInfo = struct {
    fault: Fault,
    pc: u64,      // address of the instruction that faulted
    value: u64,   // the word or address involved; see the table
};
```

Every fault is created in one place inside the CPU, which records the fault, sets `halted`, and does nothing else. The CPU does not print anything. The host decides how to report a fault, and the command-line program prints one line.

A faulting instruction changes no register and no memory, and `pc` stays on it. A fault never changes `fault` back to `null`: `fault == null` means the CPU has not faulted.

### 13.1 Fault causes

| `Fault` | Raised when | `value` holds |
|---|---|---|
| `illegal_instruction` | The word is all zeros, has an unknown opcode, uses a reserved ALU function, or is a `priv` word other than `ebreak` (including `ecall`) | the instruction word |
| `fetch_misaligned` | `pc` is not a multiple of 4 | the `pc` |
| `fetch_access` | The 4-byte word at `pc` does not fit inside RAM | the `pc` |
| `load_misaligned` | A load address is not a multiple of the access size | the address |
| `load_access` | A load address is not RAM and not the UART status register | the address |
| `store_misaligned` | A store address is not a multiple of the access size | the address |
| `store_access` | A store address is not RAM and not the UART transmit address | the address |

### 13.2 Fetch faults

Fetch reads one 4-byte word at `pc`, and it is checked before anything else happens.

- If `pc & 3 != 0`, the fault is `fetch_misaligned`.
- If the word does not fit (`pc > len - 4`, or RAM smaller than 4 bytes), the fault is `fetch_access`. The check is written so that a huge `pc` such as `0xFFFFFFFFFFFFFFFC` cannot overflow.
- The last aligned word of RAM can be fetched. If it is zeros, it faults as `illegal_instruction`, not as a fetch fault.

Normal programs cannot produce `fetch_misaligned`: `pc` starts at 0, branches and `jal` move it in steps of 4, and `jalr` clears the low two bits. It appears only when the host sets `pc` directly. `fetch_access` is common: a `jmpr` or `ret` to a bad address, or a program that runs off the end of its code without a `halt`.

### 13.3 Memory faults

Alignment is checked before the access, and bounds are checked by the access itself. See [section 8.4](#84-how-an-access-is-carried-out).

### 13.4 Reading a fault

```zig
if (cpu.fault) |f| switch (f.fault) {
    .illegal_instruction => // f.value is the instruction word
    else => // f.value is the offending address (or pc for fetch faults)
};
```

For the all-zero word, a typical sign of running into empty RAM, the fault is `illegal_instruction` with `value = 0`.

## 14. Limitations and future work

These do not exist yet. Do not describe them as features.

1. **No interrupts or exceptions to software.** A fault halts the emulator. There are no trap vectors, no way to resume, and no handler.
2. **No privilege levels, CSRs, or `ecall` semantics.** `ecall` is illegal, and there is no system-call convention.
3. **No virtual memory, TLB, caches or pipeline.** The emulator executes one instruction at a time against flat RAM.
4. **No atomics, no floating point, no division.** `mul` returns only the low half of the product, and there is no remainder.
5. **No finalized ABI.** Register names are conventions. Nothing sets up `sp`, and caller-saved and callee-saved rules are not defined.
6. **A minimal UART.** There is a transmit register and a constant status register, with no receive path and no timing.
7. **A single flat RAM region** of whatever size the host passes in. There is no memory map beyond RAM and the two UART addresses.
8. **The encoding is not frozen.** Opcode assignments may change. Freeze them together with a versioned spec and tests.

## 15. Assembler reference

`assembler.zig` supports two entry points:

- `assembleLine(line)` assembles one instruction into one 32-bit word. It cannot see labels, so it cannot assemble a label operand, a `la`, or a multi-word `li` (those return `NeedsProgram`).
- `assembleBytes(source, out, bad_line)` assembles a whole program into `out` and returns the byte count. `assemble(source, out_words, bad_line)` is the same call over a `u32` buffer.

On an error, `bad_line` holds the 1-based line number being processed. The command-line program prints it as `line N: ErrorName`.

### 15.1 Line syntax

```asm
label:   mnemonic  operand, operand      ; comment
```

- A semicolon starts a comment, unless it is inside a quoted string.
- A label ends with `:` and may stand alone on its line or in front of an instruction or directive.
- Mnemonics are written in lowercase. Operands are separated by commas. At most four operands are accepted.

### 15.2 Numbers and registers

- Registers: the names in [section 5](#5-registers) or `r0` to `r31`.
- Numbers are decimal, hexadecimal (`0x1F`) or binary (`0b1010`), with an optional leading minus.
- A single character in quotes, such as `'A'`, is its character code. Escapes are not supported inside character literals.

### 15.3 Labels

- A label must not start with a digit and may contain letters, digits, `_` and `.`.
- A program can define up to 64 labels. Defining one twice is an error.
- A label is a byte address, the position of the next emitted byte, and labels can point at data or code.
- A branch or `jal` to a label must hit an address that is a multiple of 4, otherwise `MisalignedLabel`.
- Label operands are accepted by branches, `bz`, `bnz`, `jmp`, `call` and `la`. A plain number in a branch or jump operand is a distance in instructions from that instruction.

### 15.4 Instruction summary

| Group | Mnemonics |
|---|---|
| ALU | `mov add sub and or xor shl shr sar lt ltu mul` |
| Loads | `ld.b ld.bu ld.h ld.hu ld.w ld.wu ld.d` |
| Stores | `st.b st.h st.w st.d` |
| Branches | `beq bne blt bge bltu bgeu`, aliases `bgt ble bgtu bleu bz bnz` |
| Jumps | `jmp call jmpr ret` |
| Constants | `li la hi pchi` |
| Other | `nop halt` |

### 15.5 Pseudo-instructions

| Pseudo-instruction | Expansion |
|---|---|
| `li A, v` | One `mov` if `v` fits in a signed 15-bit immediate; otherwise `hi` plus `add` of the low part (the `add` is omitted if the low part is 0) |
| `la A, label` | `pchi` plus `add`, always two instructions |
| `jmp t` | `jal zero, t` |
| `call t` | `jal ra, t` |
| `jmpr R` | `jalr zero, R, 0` |
| `ret` | `jalr zero, ra, 0` |
| `halt` | `ebreak` |
| `nop` | `mov zero, 0` |
| `bz A, t` / `bnz A, t` | `beq` / `bne` against `zero` |

`li` handles values up to about 35 bits (plus or minus). Larger values are rejected with `ImmediateOutOfRange`. The exact limit is whatever `encodeLi` accepts, so do not assume an arbitrary 64-bit `li` works.

`la` measures the distance from its own `pchi` to the label, in bytes, and splits it so the `add` part fits a signed 15-bit immediate.

Because `li` and `la` can emit more than one word, the assembler measures every line in a first pass, so the labels after them land in the right place.

### 15.6 Directives

| Directive | Effect |
|---|---|
| `.byte n, ...` | One byte per value (range `-128` to `255`) |
| `.half n, ...` | 16-bit values, little-endian |
| `.word n, ...` | 32-bit values, little-endian |
| `.dword n, ...` | 64-bit values, little-endian |
| `.ascii "text"` | The bytes of the string, no terminator |
| `.asciz "text"` | The bytes of the string plus a zero byte |
| `.space n` | `n` zero bytes (up to 1048576) |
| `.align n` | Zero padding until the position is a multiple of `n` (1 to 4096) |

String escapes: `\n`, `\t`, `\r`, `\0`, `\\` and `\"`.

`.align n` aligns to a multiple of `n`, not to `2^n`. Use `.align 4` for 4-byte alignment.

**Code must start at a multiple of 4.** If data of odd size comes before code, put `.align 4` after it, or the assembler reports `MisalignedInstruction`.

### 15.7 Two passes

Pass 1 walks every line to measure it and records each label's byte address. Pass 2 walks the lines again and emits the bytes, now that every label is known. Because the lines are measured the same way in both passes, a label can be used before it is defined.

### 15.8 Errors

| Error | Meaning |
|---|---|
| `EmptyLine` | Nothing but spaces or a comment (only from `assembleLine`) |
| `UnknownMnemonic` | The instruction name is not known |
| `TooManyOperands` | More than four operands |
| `WrongOperandCount` | For example `add a0` or `add a0, a1, a2` |
| `BadRegister` | The operand is not a register name |
| `BadOperand` | Neither a register nor a valid number or label |
| `ImmediateOutOfRange` | The value does not fit the field |
| `UnknownLabel` | A jump or `la` names a label that does not exist |
| `DuplicateLabel` | The same label is defined twice |
| `TooManyLabels` | More than 64 labels |
| `BadLabel` | An invalid label name |
| `ProgramTooLong` | The output buffer is too small |
| `NeedsProgram` | The line needs a whole program (labels or a multi-word expansion) |
| `UnknownDirective` | A line starting with `.` that is not a known directive |
| `MisalignedInstruction` | Code would start at a non-multiple of 4 |
| `MisalignedLabel` | A branch or jump target is not 4-byte aligned |

## 16. Worked examples

### 16.1 Sum of 1 to 10

```asm
mov a0, 0          ; sum
mov a1, 1          ; i
mov a2, 11         ; limit
loop:
add a0, a1         ; sum += i
add a1, 1          ; i += 1
bne a1, a2, loop
halt
```

When `a1` reaches 11 the branch is not taken and the program halts with `a0 = 55`.

### 16.2 Summing a table and measuring a string (`programs/data.s`)

```asm
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
```

The first loop adds the four words, so `a0 = 100`. The second loop counts the characters before the zero byte, so `a1 = 19`. The `.align 4` keeps `table` word-aligned, which `ld.w` requires.

### 16.3 Hello over the UART (`programs/hello.s`)

```asm
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
```

`li a0, 0x10000000` assembles to a single `hi a0, 0x2000`. Each `st.b` to that address transmits one character.

### 16.4 Signed and unsigned comparison

```asm
li a0, -1
lt a0, 1           ; signed:   -1 < 1, a0 = 1

li a1, -1
ltu a1, 1          ; unsigned: 2^64-1 < 1 is false, a1 = 0
```

### 16.5 Call and return

```asm
call function
halt

function:
  ; body
  ret
```

`call` stores the address after it in `ra`, and `ret` jumps there.

### 16.6 A fault (`programs/fault.s`)

```asm
li a2, 129
ld.w a1, [a2]
halt
```

Address 129 is not a multiple of 4, so the `ld.w` faults. The command-line program prints:

```text
fault: load_misaligned at pc=0x4, value=0x81
a0 = 0, a1 = 0, bytes = 12, steps = 2
```

`pc=0x4` is the `ld.w` (the second instruction), `value=0x81` is the address, and `a1` is still 0 because the faulting load wrote nothing.

## 17. Running and testing

### 17.1 Commands

```text
just run-emu emulator/programs/hello.s      # assemble and run a program
just test                                   # run every test
just test "Fault"                           # run tests whose name contains "Fault"
```

`run-emu` assembles the file into 4096 bytes of RAM, runs up to 1000 steps, prints any fault, then prints `a0`, `a1`, the program size in bytes and the step count.

### 17.2 Tests

Tests live in `test/emu.zig` (CPU, memory, UART, faults) and `test/assembler.zig` (the assembler). The CPU tests use small helpers:

- `load(ram, prog)` writes encoded words into RAM at address 0.
- `run(cpu, max_steps)` steps until the CPU halts or the limit is reached and returns the step count.
- `aluRR`, `aluRI`, `branchTaken` and `loadExtend` run tiny programs and return one result.
- `runFault(prog)` runs a program and returns `cpu.fault`.

Fault tests check `kind`, `pc` and `value`, so they cover the one thing a fault records. Tests for the UART set `echo = false` and compare the captured text.

### 17.3 Changing the ISA

1. Change `isa.zig` and the CPU together.
2. Update the assembler if a mnemonic or encoding changes.
3. Add a test for the normal case and for each edge case (faults, ranges, sign extension).
4. Update this document in the same commit.
