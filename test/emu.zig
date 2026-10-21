const std = @import("std");
const emu = @import("emu");
const expectEqual = std.testing.expectEqual;

const zero = 0;
const a0 = 4;
const a1 = 5;
const a2 = 6;
const a3 = 7;
const all_ones = ~@as(u64, 0);

fn load(ram: []u8, prog: []const u32) void {
    for (prog, 0..) |w, i| std.mem.writeInt(u32, ram[i * 4 ..][0..4], w, .little);
}

fn run(cpu: *emu.Cpu, max_steps: usize) usize {
    var steps: usize = 0;
    while (!cpu.halted and steps < max_steps) : (steps += 1) cpu.step();
    return steps;
}

fn aluRR(f: emu.Func, x: u64, y: u64) u64 {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{ emu.aluReg(f, a0, a1), emu.ebreak() };
    load(&ram, &prog);
    cpu.setReg(a0, x);
    cpu.setReg(a1, y);
    _ = run(&cpu, 10);
    return cpu.getReg(a0);
}

fn aluRI(f: emu.Func, x: u64, imm: i32) u64 {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{ emu.aluImm(f, a0, imm), emu.ebreak() };
    load(&ram, &prog);
    cpu.setReg(a0, x);
    _ = run(&cpu, 10);
    return cpu.getReg(a0);
}

fn branchTaken(op: emu.Opcode, x: u64, y: u64) bool {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.iT(op, a0, a1, 3), //   0: if (a0 <op> a1) goto 3
        emu.aluImm(.mov, a2, 1), // 1: not taken: a2 = 1
        emu.ebreak(), //            2
        emu.aluImm(.mov, a2, 2), // 3: taken: a2 = 2
        emu.ebreak(), //            4
    };
    load(&ram, &prog);
    cpu.setReg(a0, x);
    cpu.setReg(a1, y);
    _ = run(&cpu, 10);
    return cpu.getReg(a2) == 2;
}

fn loadExtend(st: emu.Opcode, signed: emu.Opcode, unsigned: emu.Opcode) [2]u64 {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 128), //       0: a2 = data address
        emu.aluImm(.mov, a0, -2), //        1: a0 = -2
        emu.storeT(st, a0, a2, 0), //       2: store it
        emu.loadT(signed, a1, a2, 0), //    3: signed read-back
        emu.loadT(unsigned, a3, a2, 0), //  4: unsigned read-back
        emu.ebreak(), //                    5
    };
    load(&ram, &prog);
    _ = run(&cpu, 10);
    return .{ cpu.getReg(a1), cpu.getReg(a3) };
}

test "Cpu: writting to registers" {
    var ram: [4096]u8 = @splat(0);

    var cpu = emu.Cpu.init(&ram);

    cpu.setReg(5, 1234);

    try std.testing.expectEqual(@as(u64, 1234), cpu.getReg(5));
}

test "Cpu: r0 is hardwired to zero" {
    var ram: [4096]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);

    cpu.setReg(0, 99);
    try std.testing.expectEqual(@as(u64, 0), cpu.getReg(0));
}

test "Encoder: words match the hand-computed values" {
    try expectEqual(@as(u32, 0x04810005), emu.aluReg(.add, a0, a1));
    try expectEqual(@as(u32, 0x04A18001), emu.aluImm(.add, a1, 1));
    try expectEqual(@as(u32, 0x04808000), emu.aluImm(.mov, a0, 0));
    try expectEqual(@as(u32, 0x64A6FFFE), emu.iT(.bne, a1, a2, -2));
    try expectEqual(@as(u32, 0xB4010000), emu.ebreak());
}

test "Encoder: add is one instruction for registers and immediates" {
    const r = emu.aluReg(.add, a0, a1);
    const i = emu.aluImm(.add, a0, 5);
    try expectEqual(r >> 16, i >> 16); // same opcode, destination and function
    try expectEqual(@as(u32, 0), (r >> 15) & 1); // mode bit: register
    try expectEqual(@as(u32, 1), (i >> 15) & 1); // mode bit: immediate
}

test "Cpu: ALU functions with two registers" {
    try expectEqual(@as(u64, 7), aluRR(.mov, 99, 7)); // dst = src
    try expectEqual(@as(u64, 15), aluRR(.add, 10, 5));
    try expectEqual(@as(u64, 5), aluRR(.sub, 10, 5));
    try expectEqual(@as(u64, 8), aluRR(.and_, 12, 10));
    try expectEqual(@as(u64, 14), aluRR(.or_, 12, 10));
    try expectEqual(@as(u64, 6), aluRR(.xor, 12, 10));
    try expectEqual(@as(u64, 40), aluRR(.shl, 5, 3));
    try expectEqual(@as(u64, 2), aluRR(.shr, 20, 3));
    try expectEqual(@as(u64, 42), aluRR(.mul, 6, 7));
}

test "Cpu: sar keeps the sign, shr does not" {
    const neg16: u64 = @bitCast(@as(i64, -16));
    const neg4: u64 = @bitCast(@as(i64, -4));
    try expectEqual(neg4, aluRR(.sar, neg16, 2));
    try expectEqual(@as(u64, 0x3FFF_FFFF_FFFF_FFFC), aluRR(.shr, neg16, 2));
}

test "Cpu: lt is signed, ltu is unsigned" {
    try expectEqual(@as(u64, 1), aluRR(.lt, all_ones, 1)); // -1 < 1
    try expectEqual(@as(u64, 0), aluRR(.ltu, all_ones, 1)); // 2^64-1 is not < 1
    try expectEqual(@as(u64, 0), aluRR(.lt, 1, all_ones));
    try expectEqual(@as(u64, 1), aluRR(.ltu, 1, all_ones));
}

test "Cpu: immediates are signed 15-bit numbers" {
    try expectEqual(@as(u64, 9), aluRI(.add, 10, -1));
    try expectEqual(@as(u64, 20), aluRI(.shl, 5, 2));
    try expectEqual(~@as(u64, 4), aluRI(.mov, 99, -5)); // -5 is ~4
    try expectEqual(@as(u64, 16383), aluRI(.mov, 0, 16383)); // largest
    try expectEqual(@as(u64, @bitCast(@as(i64, -16384))), aluRI(.mov, 0, -16384)); // smallest
}

test "Cpu: ebreak halts the machine" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{emu.ebreak()};
    load(&ram, &prog);

    try expectEqual(@as(usize, 1), run(&cpu, 10));
    try std.testing.expect(cpu.halted);
}

test "Cpu: an all-zero word is illegal" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);

    try expectEqual(@as(usize, 1), run(&cpu, 10));
    try std.testing.expect(cpu.halted);
}

test "Cpu: a reserved ALU function is illegal and changes nothing" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{ emu.aluReg(@enumFromInt(31), a0, a1), emu.ebreak() };
    load(&ram, &prog);
    cpu.setReg(a0, 7);

    try expectEqual(@as(usize, 1), run(&cpu, 10));
    try std.testing.expect(cpu.halted);
    try expectEqual(@as(u64, 7), cpu.getReg(a0));
}

test "Cpu: branches" {
    try std.testing.expect(branchTaken(.beq, 5, 5));
    try std.testing.expect(!branchTaken(.beq, 5, 6));

    try std.testing.expect(branchTaken(.bne, 5, 6));
    try std.testing.expect(!branchTaken(.bne, 5, 5));

    try std.testing.expect(branchTaken(.blt, all_ones, 1)); // signed: -1 < 1
    try std.testing.expect(!branchTaken(.blt, 1, all_ones));
    try std.testing.expect(!branchTaken(.bltu, all_ones, 1)); // unsigned: huge is not < 1
    try std.testing.expect(branchTaken(.bltu, 1, all_ones));

    try std.testing.expect(branchTaken(.bge, 1, all_ones)); // signed: 1 >= -1
    try std.testing.expect(branchTaken(.bge, 5, 5));
    try std.testing.expect(!branchTaken(.bge, all_ones, 1));
    try std.testing.expect(branchTaken(.bgeu, all_ones, 1));
}

test "Cpu: jal jumps and saves the return address" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.lT(.jal, a0, 2), //       0: a0 = pc + 4, goto 2
        emu.aluImm(.mov, a1, 111), // 1: skipped
        emu.aluImm(.mov, a2, 222), // 2
        emu.ebreak(), //              3
    };
    load(&ram, &prog);
    _ = run(&cpu, 10);

    try expectEqual(@as(u64, 4), cpu.getReg(a0));
    try expectEqual(@as(u64, 0), cpu.getReg(a1));
    try expectEqual(@as(u64, 222), cpu.getReg(a2));
}

test "Cpu: jalr jumps to a register address" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a1, 12), //  0: a1 = address of instruction 3
        emu.iT(.jalr, a0, a1, 0), //  1: a0 = pc + 4, goto [a1]
        emu.aluImm(.mov, a2, 111), // 2: skipped
        emu.aluImm(.mov, a2, 222), // 3
        emu.ebreak(), //              4
    };
    load(&ram, &prog);
    _ = run(&cpu, 10);

    try expectEqual(@as(u64, 8), cpu.getReg(a0));
    try expectEqual(@as(u64, 222), cpu.getReg(a2));
}

test "Cpu: hi + add builds a 32-bit constant" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.lT(.hi, a0, 0x2469), //         a0 = 0x2469 << 15 = 0x12348000
        emu.aluImm(.add, a0, -10632), //    a0 += -0x2988
        emu.ebreak(),
    };
    load(&ram, &prog);
    _ = run(&cpu, 10);

    try expectEqual(@as(u64, 0x12345678), cpu.getReg(a0));
}

test "Cpu: sum 1..10 loop" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a0, 0), //  a0 = 0   (sum)
        emu.aluImm(.mov, a1, 1), //  a1 = 1   (i)
        emu.aluImm(.mov, a2, 11), // a2 = 11  (limit)
        emu.aluReg(.add, a0, a1), // loop: a0 += a1
        emu.aluImm(.add, a1, 1), //  a1 += 1
        emu.iT(.bne, a1, a2, -2), // if a1 != a2 goto loop
        emu.ebreak(),
    };
    load(&ram, &prog);

    try expectEqual(@as(usize, 34), run(&cpu, 1000));
    try expectEqual(@as(u64, 55), cpu.getReg(a0));
}

test "Cpu: a word round trip is little-endian" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 128), //     0: a2 = data address
        emu.lT(.hi, a0, 0x2244), //       1: a0 = 0x11220000
        emu.aluImm(.add, a0, 0x3344), //  2: a0 = 0x11223344
        emu.storeT(.sw, a0, a2, 0), //    3: store the word
        emu.loadT(.lbu, a1, a2, 0), //    4: the first byte in memory
        emu.loadT(.lw, a3, a2, 0), //     5: the whole word back
        emu.ebreak(),
    };
    load(&ram, &prog);
    _ = run(&cpu, 20);

    try expectEqual(@as(u64, 0x44), cpu.getReg(a1)); // low byte comes first
    try expectEqual(@as(u64, 0x11223344), cpu.getReg(a3));
    try expectEqual(@as(u8, 0x44), ram[128]);
    try expectEqual(@as(u8, 0x11), ram[131]);
}

test "Cpu: lb/lh/lw sign-extend, lbu/lhu/lwu zero-extend" {
    const neg2: u64 = @bitCast(@as(i64, -2));
    try expectEqual([2]u64{ neg2, 0xFE }, loadExtend(.sb, .lb, .lbu));
    try expectEqual([2]u64{ neg2, 0xFFFE }, loadExtend(.sh, .lh, .lhu));
    try expectEqual([2]u64{ neg2, 0xFFFF_FFFE }, loadExtend(.sw, .lw, .lwu));
    try expectEqual([2]u64{ neg2, neg2 }, loadExtend(.sd, .ld, .ld)); // 64 bits: nothing to extend
}

test "Cpu: a store changes only its own bytes" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 128),
        emu.aluImm(.mov, a0, 0x7F),
        emu.storeT(.sb, a0, a2, 1), //   write only the byte at 129
        emu.loadT(.lw, a1, a2, 0), //    read the whole word at 128
        emu.ebreak(),
    };
    load(&ram, &prog);
    _ = run(&cpu, 10);

    try expectEqual(@as(u64, 0x7F00), cpu.getReg(a1));
}

test "Cpu: offsets are signed" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 132),
        emu.aluImm(.mov, a0, 55),
        emu.storeT(.sb, a0, a2, -4), //   address = 132 - 4 = 128
        emu.aluImm(.mov, a2, 128),
        emu.loadT(.lbu, a1, a2, 0),
        emu.ebreak(),
    };
    load(&ram, &prog);
    _ = run(&cpu, 10);

    try expectEqual(@as(u64, 55), cpu.getReg(a1));
}

test "Cpu: a misaligned load halts and changes nothing" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 129), //     not a multiple of 4
        emu.aluImm(.mov, a1, 7),
        emu.loadT(.lw, a1, a2, 0), //     faults
        emu.ebreak(), //                  never reached
    };
    load(&ram, &prog);

    try expectEqual(@as(usize, 3), run(&cpu, 10)); // 3 steps: stopped by the fault, not the ebreak
    try std.testing.expect(cpu.halted);
    try expectEqual(@as(u64, 7), cpu.getReg(a1));
}

test "Cpu: a misaligned store halts and writes nothing" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 129),
        emu.aluImm(.mov, a0, 5),
        emu.storeT(.sw, a0, a2, 0), //    faults
        emu.ebreak(), //                  never reached
    };
    load(&ram, &prog);

    try expectEqual(@as(usize, 3), run(&cpu, 10));
    try expectEqual(@as(u8, 0), ram[129]);
}

test "Cpu: the last byte of memory is readable, one past it is not" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    ram[255] = 9;
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 255),
        emu.loadT(.lbu, a1, a2, 0), //    the last byte: fine
        emu.aluImm(.mov, a2, 256),
        emu.aluImm(.mov, a3, 7),
        emu.loadT(.lbu, a3, a2, 0), //    one past the end: access fault
        emu.ebreak(), //                  never reached
    };
    load(&ram, &prog);

    try expectEqual(@as(usize, 5), run(&cpu, 10));
    try expectEqual(@as(u64, 9), cpu.getReg(a1));
    try expectEqual(@as(u64, 7), cpu.getReg(a3)); // the faulting load changed nothing
}

test "Cpu: sum an array in memory" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    for ([_]u32{ 1, 2, 3, 4 }, 0..) |v, i| {
        std.mem.writeInt(u32, ram[128 + i * 4 ..][0..4], v, .little);
    }
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 128), //     0: a2 = pointer to the array
        emu.aluImm(.mov, a1, 0), //       1: a1 = sum
        emu.aluImm(.mov, a3, 144), //     2: a3 = end of the array (128 + 4 words * 4 bytes)
        emu.loadT(.lw, a0, a2, 0), //     3: loop: a0 = next element
        emu.aluReg(.add, a1, a0), //      4: sum += a0
        emu.aluImm(.add, a2, 4), //       5: pointer += 4
        emu.iT(.bne, a2, a3, -3), //      6: if pointer != end goto loop
        emu.ebreak(), //                  7
    };
    load(&ram, &prog);

    try expectEqual(@as(usize, 20), run(&cpu, 100));
    try expectEqual(@as(u64, 10), cpu.getReg(a1));
}

test "Encoder: hi word matches the hand-computed value" {
    try expectEqual(@as(u32, 0x0C802000), emu.lT(.hi, a0, 0x2000));
}

test "Cpu: bytes written to the UART are captured" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.echo = false;
    const prog = [_]u32{
        emu.lT(.hi, a0, 0x2000), //      0: a0 = UART address
        emu.aluImm(.mov, a1, 'H'), //    1
        emu.storeT(.sb, a1, a0, 0), //   2: print 'H'
        emu.aluImm(.mov, a1, 'i'), //    3
        emu.storeT(.sb, a1, a0, 0), //   4: print 'i'
        emu.ebreak(), //                 5
    };
    load(&ram, &prog);
    _ = run(&cpu, 20);

    try std.testing.expectEqualStrings("Hi", cpu.uartText());
}

test "Cpu: a wider store to the UART prints only the low byte" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.echo = false;
    const prog = [_]u32{
        emu.lT(.hi, a2, 0x2000),
        emu.aluImm(.mov, a0, 0x1234), // low byte 0x34 is '4'
        emu.storeT(.sw, a0, a2, 0),
        emu.ebreak(),
    };
    load(&ram, &prog);
    _ = run(&cpu, 20);

    try std.testing.expectEqualStrings("4", cpu.uartText());
}

test "Cpu: the UART status register reads 1 (ready)" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.echo = false;
    const prog = [_]u32{
        emu.lT(.hi, a2, 0x2000),
        emu.loadT(.lbu, a1, a2, 4), // read the status register
        emu.ebreak(),
    };
    load(&ram, &prog);
    _ = run(&cpu, 10);

    try expectEqual(@as(u64, 1), cpu.getReg(a1));
}

test "Cpu: reading the UART transmit register faults" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.echo = false;
    const prog = [_]u32{
        emu.lT(.hi, a2, 0x2000),
        emu.aluImm(.mov, a1, 7),
        emu.loadT(.lbu, a1, a2, 0), // the transmit register is write-only
        emu.ebreak(), //               never reached
    };
    load(&ram, &prog);

    try expectEqual(@as(usize, 3), run(&cpu, 10));
    try expectEqual(@as(u64, 7), cpu.getReg(a1)); // the failed load changed nothing
}

test "Cpu: an address next to the UART faults and prints nothing" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.echo = false;
    const prog = [_]u32{
        emu.lT(.hi, a2, 0x2000),
        emu.storeT(.sb, a0, a2, 8), // 0x1000_0008: nothing lives there
        emu.ebreak(), //               never reached
    };
    load(&ram, &prog);

    try expectEqual(@as(usize, 2), run(&cpu, 10));
    try expectEqual(@as(usize, 0), cpu.uartText().len);
}

test "Cpu: hello program prints a string" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.echo = false;
    const prog = [_]u32{
        emu.lT(.hi, a0, 0x2000), //      0: a0 = UART address
        emu.aluImm(.mov, a2, 128), //    1: a2 = address of the string
        emu.loadT(.lbu, a1, a2, 0), //   2: loop: a1 = byte at [a2]
        emu.iT(.beq, a1, zero, 4), //    3: if a1 == 0 goto 7
        emu.storeT(.sb, a1, a0, 0), //   4: write a1 to the UART
        emu.aluImm(.add, a2, 1), //      5: a2 += 1
        emu.lT(.jal, zero, -4), //       6: goto 2
        emu.ebreak(), //                 7
    };
    load(&ram, &prog);
    const msg = "Hello from BARE64!\n\x00";
    @memcpy(ram[128..][0..msg.len], msg[0..msg.len]);

    try expectEqual(@as(usize, 100), run(&cpu, 1000));
    try std.testing.expectEqualStrings("Hello from BARE64!\n", cpu.uartText());
}
