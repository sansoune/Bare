const emu = @import("emu");
const std = @import("std");

const expectEqual = std.testing.expectEqual;

const zero = 0;
const a0 = 4;
const a1 = 5;
const a2 = 6;
const a3 = 7;
const t0 = 12;
const all_ones = ~@as(u64, 0);

fn load(ram: []u8, prog: []const u32) void {
    for (prog, 0..) |w, i| std.mem.writeInt(u32, ram[i * 4 ..][0..4], w, .little);
}

fn run(cpu: *emu.Cpu, max_steps: usize) usize {
    var steps: usize = 0;
    while (!cpu.halted and steps < max_steps) : (steps += 1) cpu.step();
    return steps;
}

fn runFault(prog: []const u32) ?emu.FaultInfo {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.uart.echo = false;
    load(&ram, prog);
    _ = run(&cpu, 20);
    return cpu.fault;
}

test "Fault: an illegal word records the word and the pc" {
    const prog = [_]u32{
        emu.aluImm(.mov, a0, 1),
        emu.aluReg(@fromBackingInt(@intCast(31)), a0, a1), // reserved ALU function
    };
    const f = runFault(&prog).?;
    try expectEqual(emu.Fault.illegal_instruction, f.fault);
    try expectEqual(@as(u64, 4), f.pc);
    try expectEqual(@as(u64, prog[1]), f.value);
}

test "Fault: an unknown opcode leaves pc on the instruction" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.uart.echo = false;
    std.mem.writeInt(u32, ram[0..4], @as(u32, 0x3F) << 26, .little);
    _ = run(&cpu, 10);

    try expectEqual(emu.Fault.illegal_instruction, cpu.fault.?.fault);
    try expectEqual(@as(u64, 0), cpu.pc);
}

test "Fault: fetch past the end of RAM" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.uart.echo = false;
    cpu.pc = 64;

    try expectEqual(@as(usize, 1), run(&cpu, 10));
    const f = cpu.fault.?;
    try expectEqual(emu.Fault.fetch_access, f.fault);
    try expectEqual(@as(u64, 64), f.pc);
    try expectEqual(@as(u64, 64), f.value);
}

test "Fault: the last word of RAM can be fetched" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.uart.echo = false;
    cpu.pc = 60;
    _ = run(&cpu, 10);

    // It is the all-zero word: illegal, but fetched fine.
    try expectEqual(emu.Fault.illegal_instruction, cpu.fault.?.fault);
}

test "Fault: a huge pc does not overflow" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.uart.echo = false;
    cpu.pc = all_ones - 3;
    _ = run(&cpu, 10);

    try expectEqual(emu.Fault.fetch_access, cpu.fault.?.fault);
}

test "Fault: a misaligned pc" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.uart.echo = false;
    cpu.pc = 2;
    _ = run(&cpu, 10);

    const f = cpu.fault.?;
    try expectEqual(emu.Fault.fetch_misaligned, f.fault);
    try expectEqual(@as(u64, 2), f.value);
}

test "Fault: jumping out of RAM faults on the next fetch" {
    var ram: [64]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.uart.echo = false;
    const prog = [_]u32{
        emu.aluImm(.mov, a1, 4096),
        emu.iT(.jalr, zero, a1, 0),
    };
    load(&ram, &prog);

    try expectEqual(@as(usize, 3), run(&cpu, 10)); // mov, jalr, failed fetch
    const f = cpu.fault.?;
    try expectEqual(emu.Fault.fetch_access, f.fault);
    try expectEqual(@as(u64, 4096), f.pc);
}

test "Fault: a misaligned load records the address" {
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 129),
        emu.loadT(.lw, a1, a2, 0),
    };
    const f = runFault(&prog).?;
    try expectEqual(emu.Fault.load_misaligned, f.fault);
    try expectEqual(@as(u64, 4), f.pc);
    try expectEqual(@as(u64, 129), f.value);
}

test "Fault: a load past the end of RAM records the address" {
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 256),
        emu.loadT(.lbu, a1, a2, 0),
    };
    const f = runFault(&prog).?;
    try expectEqual(emu.Fault.load_access, f.fault);
    try expectEqual(@as(u64, 256), f.value);
}

test "Fault: a misaligned store records the address" {
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 129),
        emu.storeT(.sw, a0, a2, 0),
    };
    const f = runFault(&prog).?;
    try expectEqual(emu.Fault.store_misaligned, f.fault);
    try expectEqual(@as(u64, 129), f.value);
}

test "Fault: a store past the end of RAM records the address" {
    const prog = [_]u32{
        emu.aluImm(.mov, a2, 256),
        emu.storeT(.sb, a0, a2, 0),
    };
    const f = runFault(&prog).?;
    try expectEqual(emu.Fault.store_access, f.fault);
    try expectEqual(@as(u64, 256), f.value);
}

test "Fault: reading the UART transmit register is a load access fault" {
    const prog = [_]u32{
        emu.lT(.hi, a2, 0x2000),
        emu.loadT(.lbu, a1, a2, 0),
    };
    const f = runFault(&prog).?;
    try expectEqual(emu.Fault.load_access, f.fault);
    try expectEqual(@as(u64, 0x1000_0000), f.value);
}

test "Fault: ebreak halts without a fault" {
    const prog = [_]u32{emu.ebreak()};
    try std.testing.expect(runFault(&prog) == null);
}

test "Encoder: trap instruction words" {
    try expectEqual(@as(u32, 0xB4000000), emu.ecall());
    try expectEqual(@as(u32, 0xB4020000), emu.eret());
    try expectEqual(@as(u32, 0xB4830000), emu.csrr(a0, .tvec));
    try expectEqual(@as(u32, 0xB4A40001), emu.csrw(.epc, a1));
}

test "Cpu: the four CSRs read back what was written" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, t0, 11), emu.csrw(.tvec, t0),
        emu.aluImm(.mov, t0, 22), emu.csrw(.epc, t0),
        emu.aluImm(.mov, t0, 33), emu.csrw(.cause, t0),
        emu.aluImm(.mov, t0, 44), emu.csrw(.tval, t0),
        emu.csrr(a0, .tvec),      emu.csrr(a1, .epc),
        emu.csrr(a2, .cause),     emu.csrr(a3, .tval),
        emu.ebreak(),
    };
    load(&ram, &prog);
    _ = run(&cpu, 50);

    try expectEqual(@as(u64, 11), cpu.getReg(a0));
    try expectEqual(@as(u64, 22), cpu.getReg(a1));
    try expectEqual(@as(u64, 33), cpu.getReg(a2));
    try expectEqual(@as(u64, 44), cpu.getReg(a3));
}

test "Trap: an unknown CSR is illegal" {
    const prog = [_]u32{emu.csrr(a0, @fromBackingInt(@intCast(99)))};
    const f = runFault(&prog).?;
    try expectEqual(emu.Fault.illegal_instruction, f.fault);
    try expectEqual(prog[0], @as(u32, @intCast(f.value)));
}

test "Trap: ecall with no handler halts with an ecall fault" {
    const prog = [_]u32{emu.ecall()};
    const f = runFault(&prog).?;
    try expectEqual(emu.Fault.ecall, f.fault);
    try expectEqual(@as(u64, 0), f.pc);
}

test "Trap: eret outside a handler is illegal" {
    const prog = [_]u32{emu.eret()};
    try expectEqual(emu.Fault.illegal_instruction, runFault(&prog).?.fault);
}

test "Trap: a fault jumps to the handler and records cause, tval and epc" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.uart.echo = false;
    const prog = [_]u32{
        emu.aluImm(.mov, a0, 24), //   0: handler address (word 6)
        emu.csrw(.tvec, a0), //        1
        emu.aluImm(.mov, a2, 129), //  2
        emu.loadT(.lw, a1, a2, 0), //  3: misaligned, faults at pc = 12
        emu.aluImm(.mov, a3, 1), //    4: never reached
        emu.ebreak(), //               5: never reached
        emu.csrr(a0, .cause), //       6: the handler
        emu.csrr(a1, .tval), //        7
        emu.csrr(a2, .epc), //         8
        emu.ebreak(), //               9
    };
    load(&ram, &prog);

    try expectEqual(@as(usize, 8), run(&cpu, 50));
    try std.testing.expect(cpu.fault == null); // handled, so not a stop
    try expectEqual(@as(u64, 4), cpu.getReg(a0)); // load_misaligned
    try expectEqual(@as(u64, 129), cpu.getReg(a1));
    try expectEqual(@as(u64, 12), cpu.getReg(a2));
    try expectEqual(@as(u64, 0), cpu.getReg(a3));
}

test "Trap: ecall then eret resumes after the ecall" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a0, 20), //  0: handler address (word 5)
        emu.csrw(.tvec, a0), //       1
        emu.ecall(), //               2: pc = 8, epc = 12
        emu.aluImm(.mov, a1, 7), //   3: runs after eret
        emu.ebreak(), //              4
        emu.aluImm(.mov, a2, 99), //  5: the handler
        emu.eret(), //                6
    };
    load(&ram, &prog);

    try expectEqual(@as(usize, 7), run(&cpu, 50));
    try expectEqual(@as(u64, 99), cpu.getReg(a2));
    try expectEqual(@as(u64, 7), cpu.getReg(a1));
    try expectEqual(@as(u64, 12), cpu.epc);
    try expectEqual(@as(u64, 8), cpu.cause);
}

test "Trap: a handler can skip the faulting instruction" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.uart.echo = false;
    const prog = [_]u32{
        emu.aluImm(.mov, a0, 24), //   0: handler address (word 6)
        emu.csrw(.tvec, a0), //        1
        emu.aluImm(.mov, a2, 129), //  2
        emu.loadT(.lw, a1, a2, 0), //  3: faults at pc = 12
        emu.aluImm(.mov, a3, 5), //    4: resumes here
        emu.ebreak(), //               5
        emu.csrr(t0, .epc), //         6: the handler
        emu.aluImm(.add, t0, 4), //    7: skip the bad instruction
        emu.csrw(.epc, t0), //         8
        emu.eret(), //                 9
    };
    load(&ram, &prog);
    _ = run(&cpu, 50);

    try expectEqual(@as(u64, 5), cpu.getReg(a3));
    try expectEqual(@as(u64, 0), cpu.getReg(a1)); // the load never happened
}

test "Trap: a fault inside a handler halts the machine" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    cpu.uart.echo = false;
    const prog = [_]u32{
        emu.aluImm(.mov, a0, 16), //   0: handler address (word 4)
        emu.csrw(.tvec, a0), //        1
        emu.ecall(), //                2: epc = 12
        emu.ebreak(), //               3
        emu.aluImm(.mov, a2, 129), //  4: the handler
        emu.loadT(.lw, a1, a2, 0), //  5: faults inside the handler, pc = 20
    };
    load(&ram, &prog);
    _ = run(&cpu, 50);

    try std.testing.expect(cpu.halted);
    const f = cpu.fault.?;
    try expectEqual(emu.Fault.load_misaligned, f.fault);
    try expectEqual(@as(u64, 20), f.pc);
    try expectEqual(@as(u64, 8), cpu.cause); // the first trap is still recorded
    try expectEqual(@as(u64, 12), cpu.epc);
}
