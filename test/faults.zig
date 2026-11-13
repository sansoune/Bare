const emu = @import("emu");
const std = @import("std");

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
