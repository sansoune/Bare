const std = @import("std");
const cpu = @import("cpu.zig");
pub const isa = @import("isa.zig");
pub const assembler = @import("assembler.zig");

pub const Cpu = cpu.Cpu;

pub const Opcode = isa.Opcode;
pub const Func = isa.Func;
pub const Priv = isa.Priv;

pub const aluReg = isa.aluReg;
pub const aluImm = isa.aluImm;
pub const iT = isa.iT;
pub const lT = isa.lT;
pub const ebreak = isa.ebreak;
pub const loadT = isa.loadT;
pub const storeT = isa.storeT;

const zero = 0;
const a0 = 4;
const a1 = 5;
const a2 = 6;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("usage: emu <program.s\n>", .{});
        return;
    };

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(1 << 20));
    defer gpa.free(source);

    var ram: [4096]u8 = @splat(0);
    var machine = Cpu.init(&ram);

    var bad_line: usize = 0;
    const size = assembler.assembleBytes(source, &ram, &bad_line) catch |err| {
        std.debug.print("line {d}: {s}\n", .{ bad_line, @errorName(err) });
        return;
    };

    var steps: usize = 0;
    while (!machine.halted and steps < 1000) : (steps += 1) machine.step();

    std.debug.print("a0 = {d}, a1 = {d}, bytes = {d}, steps = {d}\n", .{ machine.getReg(a0), machine.getReg(a1), size, steps });
}
