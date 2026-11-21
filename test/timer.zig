const emu = @import("emu");
const std = @import("std");
const expectEqual = std.testing.expectEqual;

const zero = 0;
const a0 = 4;
const a1 = 5;
const a2 = 6;
const a3 = 7;
const a4 = 8;

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

test "Encoder: csrw ie" {
    try expectEqual(@as(u32, 0xB4840004), emu.csrw(.ie, a0));
}

test "Timer: the time register counts steps" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.lT(.hi, a2, 0x2000), //       step 1
        emu.aluImm(.add, a2, 4096), //    step 2: a2 = 0x1000_1000
        emu.loadT(.ld, a1, a2, 0), //     step 3: read time
        emu.ebreak(),
    };
    load(&ram, &prog);
    _ = run(&cpu, 10);

    try expectEqual(@as(u64, 3), cpu.getReg(a1));
}

test "Timer: the registers only accept 8-byte accesses" {
    const prog = [_]u32{
        emu.lT(.hi, a2, 0x2000),
        emu.aluImm(.add, a2, 4096),
        emu.storeT(.sw, a0, a2, 8), // 4 bytes to cmp: not allowed
    };
    const f = runFault(&prog).?;
    try expectEqual(emu.Fault.store_access, f.fault);
    try expectEqual(@as(u64, 0x1000_1008), f.value);
}

test "Timer: nothing happens while interrupts are off" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a0, 100), //     0: tvec set, ie left off
        emu.csrw(.tvec, a0),
        emu.lT(.hi, a2, 0x2000),
        emu.aluImm(.add, a2, 4096),
        emu.aluImm(.mov, a0, 3),
        emu.storeT(.sd, a0, a2, 8), //    5: cmp = 3, already in the past
        emu.aluImm(.add, a3, 1),
        emu.aluImm(.add, a3, 1),
        emu.ebreak(),
    };
    load(&ram, &prog);
    _ = run(&cpu, 50);

    try expectEqual(@as(u64, 2), cpu.getReg(a3));
    try expectEqual(@as(u64, 0), cpu.cause);
    try std.testing.expect(cpu.fault == null);
}

test "Timer: the interrupt fires exactly when time reaches cmp" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a0, 40), //      0: handler address (word 10)
        emu.csrw(.tvec, a0),
        emu.aluImm(.mov, a0, 1),
        emu.csrw(.ie, a0), //             3: interrupts on
        emu.lT(.hi, a2, 0x2000),
        emu.aluImm(.add, a2, 4096), //    5: a2 = timer base
        emu.aluImm(.mov, a0, 30),
        emu.storeT(.sd, a0, a2, 8), //    7: cmp = 30, this is step 8
        emu.aluImm(.add, a3, 1), //       8: loop, runs on odd steps
        emu.lT(.jal, zero, -1), //        9: back to word 8
        emu.csrr(a1, .cause), //          10: the handler
        emu.csrr(a0, .epc),
        emu.ebreak(),
    };
    load(&ram, &prog);

    // 29 normal steps, 1 interrupt step, 3 handler steps.
    try expectEqual(@as(usize, 33), run(&cpu, 100));
    try std.testing.expect(cpu.fault == null);
    try expectEqual(@as(u64, 16), cpu.getReg(a1)); // timer interrupt
    try expectEqual(@as(u64, 36), cpu.getReg(a0)); // the jal that was about to run
    try expectEqual(@as(u64, 11), cpu.getReg(a3)); // 11 loop passes before it fired
}

test "Timer: a handler acknowledges the timer and eret resumes" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);
    const prog = [_]u32{
        emu.aluImm(.mov, a0, 48), //      0: handler address (word 12)
        emu.csrw(.tvec, a0),
        emu.aluImm(.mov, a0, 1),
        emu.csrw(.ie, a0),
        emu.lT(.hi, a2, 0x2000),
        emu.aluImm(.add, a2, 4096),
        emu.aluImm(.mov, a0, 20),
        emu.storeT(.sd, a0, a2, 8), //    7: cmp = 20
        emu.aluImm(.add, a3, 1), //       8: loop
        emu.iT(.beq, a4, zero, -1), //    9: repeat while a4 == 0
        emu.aluImm(.mov, a1, 99), //      10: after the loop
        emu.ebreak(), //                  11
        emu.aluImm(.mov, a4, 1), //       12: the handler
        emu.storeT(.sd, zero, a2, 8), //  13: acknowledge: cmp = 0
        emu.eret(), //                    14
    };
    load(&ram, &prog);
    _ = run(&cpu, 100);

    try expectEqual(@as(u64, 1), cpu.getReg(a4));
    try expectEqual(@as(u64, 99), cpu.getReg(a1));
    try expectEqual(@as(u64, 6), cpu.getReg(a3));
    try std.testing.expect(!cpu.in_trap);
    try std.testing.expect(cpu.fault == null);
}
