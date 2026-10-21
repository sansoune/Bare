const std = @import("std");
const emu = @import("emu");
const expectEqual = std.testing.expectEqual;

const zero = 0;
const a0 = 4;
const a1 = 5;
const a2 = 6;
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
