const std = @import("std");

pub const Opcode = enum(u6) {
    illegal = 0x00, // an all-zero word must never run
    alu = 0x01, // every arithmetic and logic instruction
    hi = 0x03, // was lui
    pchi = 0x04, // was auipc
    beq = 0x18,
    bne = 0x19,
    blt = 0x1A,
    bge = 0x1B,
    bltu = 0x1C,
    bgeu = 0x1D,
    jal = 0x20,
    jalr = 0x21,
    priv = 0x2D,
    _,
};

pub const Func = enum(u5) {
    mov = 0, // dst = src
    add,
    sub,
    and_,
    or_,
    xor,
    shl,
    shr,
    sar,
    lt,
    ltu,
    mul,
    _,
};

pub const Priv = enum(u5) {
    ecall = 0,
    ebreak = 1,
    _,
};

pub const Cpu = struct {
    regs: [32]u64 = @splat(0),
    pc: u64 = 0,
    mem: []u8,
    halted: bool = false,

    pub fn init(mem: []u8) Cpu {
        return .{ .mem = mem };
    }

    pub fn getReg(self: *Cpu, index: u5) u64 {
        return self.regs[index];
    }

    pub fn setReg(self: *Cpu, index: u5, value: u64) void {
        if (index != 0) self.regs[index] = value;
    }

    pub fn fetch(self: *Cpu) u32 {
        const a: usize = @intCast(self.pc);
        return std.mem.readInt(u32, self.mem[a..][0..4], .little);
    }

    pub fn illegal(self: *Cpu, inst: u64) void {
        std.debug.print("illegal instruction 0x{x:0>8} at pc=0x{x}\n", .{ inst, self.pc });
        self.halted = true;
    }

    pub fn step(self: *Cpu) void {
        const inst = self.fetch();

        const op: Opcode = @enumFromInt(@as(u6, @truncate(inst >> 26)));
        const a: u5 = @truncate(inst >> 21);
        const b: u5 = @truncate(inst >> 16);
        const funct: u5 = @truncate(inst >> 16);

        const is_imm = (inst >> 15) & 1 == 1;
        const src: u15 = @truncate(inst);
        const imm16: u16 = @truncate(inst);
        const imm21: u21 = @truncate(inst);

        const simm15: i64 = @as(i15, @bitCast(src));
        const simm16: i64 = @as(i16, @bitCast(imm16));
        const simm21: i64 = @as(i21, @bitCast(imm21));

        var next_pc = self.pc +% 4;

        switch (op) {
            .alu => {
                const x = self.regs[a];
                const y: u64 = if (is_imm) @bitCast(simm15) else self.regs[@as(u5, @truncate(src))];
                const func: Func = @enumFromInt(funct);
                const sx: i64 = @bitCast(x);
                const sy: i64 = @bitCast(y);
                const sh: u6 = @truncate(y);

                const result: u64 = switch (func) {
                    .mov => y,
                    .add => x +% y,
                    .sub => x -% y,
                    .and_ => x & y,
                    .or_ => x | y,
                    .xor => x ^ y,
                    .shl => x << sh,
                    .shr => x >> sh,
                    .sar => @bitCast(sx >> sh),
                    .lt => @intFromBool(sx < sy),
                    .ltu => @intFromBool(x < y),
                    .mul => x *% y,
                    else => return self.illegal(inst),
                };
                self.setReg(a, result);
            },
            .hi => self.setReg(a, @bitCast(simm21 << 15)),
            .pchi => self.setReg(a, self.pc +% @as(u64, @bitCast(simm21 << 15))),
            .beq, .bne, .blt, .bge, .bltu, .bgeu => {
                const x = self.regs[a];
                const y = self.regs[b];
                const sx: i64 = @bitCast(x);
                const sy: i64 = @bitCast(y);
                const taken = switch (op) {
                    .beq => x == y,
                    .bne => x != y,
                    .blt => sx < sy,
                    .bge => sx >= sy,
                    .bltu => x < y,
                    else => x >= y,
                };
                if (taken) next_pc = self.pc +% @as(u64, @bitCast(simm16 << 2));
            },
            .jal => {
                self.setReg(a, self.pc +% 4);
                next_pc = self.pc +% @as(u64, @bitCast(simm21 << 2));
            },
            .jalr => {
                // Compute the target BEFORE writing rd: rd and rs1 may be the same register.
                const target = (self.regs[b] +% @as(u64, @bitCast(simm16))) & ~@as(u64, 3);
                self.setReg(a, self.pc +% 4);
                next_pc = target;
            },
            .priv => {
                // Temporary: ebreak just stops the machine for now.
                const pf: Priv = @enumFromInt(funct);
                if (pf == .ebreak) self.halted = true else self.illegal(inst);
            },
            else => self.illegal(inst),
        }

        self.pc = next_pc;
    }
};

pub fn aluReg(f: Func, dst: u32, src: u32) u32 { // dst = dst <f> register
    return (@as(u32, @intFromEnum(Opcode.alu)) << 26) | (dst << 21) | (@as(u32, @intFromEnum(f)) << 16) | src;
}
pub fn aluImm(f: Func, dst: u32, imm: i32) u32 { // dst = dst <f> immediate
    return (@as(u32, @intFromEnum(Opcode.alu)) << 26) | (dst << 21) | (@as(u32, @intFromEnum(f)) << 16) | (1 << 15) | (@as(u32, @bitCast(imm)) & 0x7FFF);
}
pub fn iT(op: Opcode, a: u32, b: u32, imm: i32) u32 {
    return (@as(u32, @intFromEnum(op)) << 26) | (a << 21) | (b << 16) | (@as(u32, @bitCast(imm)) & 0xFFFF);
}
pub fn ebreak() u32 {
    return (@as(u32, @intFromEnum(Opcode.priv)) << 26) | (@as(u32, @intFromEnum(Priv.ebreak)) << 16);
}

pub fn lT(op: Opcode, rd: u32, imm: i32) u32 {
    return (@as(u32, @intFromEnum(op)) << 26) | (rd << 21) | (@as(u32, @bitCast(imm)) & 0x1FFFFF);
}

const zero = 0;
const a0 = 4;
const a1 = 5;
const a2 = 6;

pub fn main() void {
    var ram: [4096]u8 = @splat(0);

    // a0 = 1 + 2 + ... + 10
    const prog = [_]u32{
        aluImm(.mov, a0, 0), //   0: a0 = 0   (sum)
        aluImm(.mov, a1, 1), //   1: a1 = 1   (i)
        aluImm(.mov, a2, 11), //  2: a2 = 11  (limit)
        aluReg(.add, a0, a1), //  3: loop: a0 += a1
        aluImm(.add, a1, 1), //   4: a1 += 1
        iT(.bne, a1, a2, -2), //  5: if a1 != a2 goto 3
        ebreak(), //              6: halt
    };
    for (prog, 0..) |w, i| std.mem.writeInt(u32, ram[i * 4 ..][0..4], w, .little);

    var cpu = Cpu.init(&ram);
    var steps: usize = 0;
    while (!cpu.halted and steps < 1000) : (steps += 1) cpu.step();

    std.debug.print("a0 = {d}, a1 = {d}, steps = {d}\n", .{ cpu.regs[a0], cpu.regs[a1], steps });
}
