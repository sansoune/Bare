const std = @import("std");

pub const Opcode = enum(u6) {
    illegal = 0x00, // an all-zero word must never run
    alu = 0x01, // every arithmetic and logic instruction
    hi = 0x03, // was lui
    pchi = 0x04, // was auipc
    lb = 0x08,
    lbu = 0x09,
    lh = 0x0A,
    lhu = 0x0B,
    lw = 0x0C,
    lwu = 0x0D,
    ld = 0x0E,
    sb = 0x10,
    sh = 0x11,
    sw = 0x12,
    sd = 0x13,
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

const uart_tx: u64 = 0x1000_0000;
const uart_status: u64 = 0x1000_0004;

fn sext8(v: u64) u64 {
    const t: u8 = @truncate(v);
    return @bitCast(@as(i64, @as(i8, @bitCast(t))));
}

fn sext16(v: u64) u64 {
    const t: u16 = @truncate(v);
    return @bitCast(@as(i64, @as(i16, @bitCast(t))));
}

fn sext32(v: u64) u64 {
    const t: u32 = @truncate(v);
    return @bitCast(@as(i64, @as(i32, @bitCast(t))));
}

pub const Cpu = struct {
    regs: [32]u64 = @splat(0),
    pc: u64 = 0,
    mem: []u8,
    halted: bool = false,
    echo: bool = true, // also print UART bytes to the terminal (tests turn this off)
    uart_buf: [256]u8 = undefined, // a copy of everything the program printed
    uart_len: usize = 0,

    pub fn init(mem: []u8) Cpu {
        return .{ .mem = mem };
    }

    pub fn getReg(self: *Cpu, index: u5) u64 {
        return self.regs[index];
    }

    pub fn setReg(self: *Cpu, index: u5, value: u64) void {
        if (index != 0) self.regs[index] = value;
    }

    pub fn uartText(self: *const Cpu) []const u8 {
        return self.uart_buf[0..self.uart_len];
    }

    pub fn fetch(self: *Cpu) u32 {
        const a: usize = @intCast(self.pc);
        return std.mem.readInt(u32, self.mem[a..][0..4], .little);
    }

    pub fn illegal(self: *Cpu, inst: u64) void {
        std.debug.print("illegal instruction 0x{x:0>8} at pc=0x{x}\n", .{ inst, self.pc });
        self.halted = true;
    }

    fn fault(self: *Cpu, what: []const u8, value: u64) void {
        std.debug.print("{s}: 0x{x} at pc=0x{x}\n", .{ what, value, self.pc });
        self.halted = true;
    }

    fn memLoad(self: *Cpu, addr: u64, size: u64) ?u64 {
        const len: u64 = self.mem.len;
        if (size > len or addr > len - size) return null; // out of range
        if (addr == uart_status) return 1;
        const off: usize = @intCast(addr);
        const v: u64 = switch (size) {
            1 => self.mem[off],
            2 => std.mem.readInt(u16, self.mem[off..][0..2], .little),
            4 => std.mem.readInt(u32, self.mem[off..][0..4], .little),
            8 => std.mem.readInt(u64, self.mem[off..][0..8], .little),
            else => unreachable,
        };
        return v;
    }

    fn memStore(self: *Cpu, addr: u64, size: u64, value: u64) bool {
        if (addr == uart_tx) {
            const byte: u8 = @truncate(value);
            if (self.uart_len < self.uart_buf.len) {
                self.uart_buf[self.uart_len] = byte;
                self.uart_len += 1;
            }
            if (self.echo) std.debug.print("{c}", .{byte});
            return true;
        }

        const len: u64 = self.mem.len;
        if (size > len or addr > len - size) return false; // out of range
        const off: usize = @intCast(addr);
        switch (size) {
            1 => self.mem[off] = @truncate(value),
            2 => std.mem.writeInt(u16, self.mem[off..][0..2], @truncate(value), .little),
            4 => std.mem.writeInt(u32, self.mem[off..][0..4], @truncate(value), .little),
            8 => std.mem.writeInt(u64, self.mem[off..][0..8], value, .little),
            else => unreachable,
        }
        return true;
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
                const x = self.getReg(a);
                const y: u64 = if (is_imm) @bitCast(simm15) else self.getReg(@as(u5, @truncate(src)));
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
            .lb, .lbu, .lh, .lhu, .lw, .lwu, .ld => {
                const addr = self.getReg(b) +% @as(u64, @bitCast(simm16));
                const size: u64 = switch (op) {
                    .lb, .lbu => 1,
                    .lh, .lhu => 2,
                    .lw, .lwu => 4,
                    else => 8,
                };
                if (addr & (size - 1) != 0) return self.fault("load address misaligned", addr);
                const raw = self.memLoad(addr, size) orelse
                    return self.fault("load access fault", addr);
                const v: u64 = switch (op) {
                    .lb => sext8(raw),
                    .lh => sext16(raw),
                    .lw => sext32(raw),
                    else => raw, // lbu, lhu, lwu, ld: already zero-extended
                };
                self.setReg(a, v);
            },
            .sb, .sh, .sw, .sd => {
                // For stores, A is the data register and B is the base address register.
                const addr = self.getReg(b) +% @as(u64, @bitCast(simm16));
                const size: u64 = switch (op) {
                    .sb => 1,
                    .sh => 2,
                    .sw => 4,
                    else => 8,
                };
                if (addr & (size - 1) != 0) return self.fault("store address misaligned", addr);
                if (!self.memStore(addr, size, self.getReg(a))) {
                    return self.fault("store access fault", addr);
                }
            },
            .beq, .bne, .blt, .bge, .bltu, .bgeu => {
                const x = self.getReg(a);
                const y = self.getReg(b);
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
                const target = (self.getReg(b) +% @as(u64, @bitCast(simm16))) & ~@as(u64, 3);
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

pub fn loadT(op: Opcode, rd: u32, base: u32, offset: i32) u32 {
    return iT(op, rd, base, offset);
}
// A holds the data register and B the base (the same layout as a branch).
pub fn storeT(op: Opcode, src: u32, base: u32, offset: i32) u32 {
    return iT(op, src, base, offset);
}

const zero = 0;
const a0 = 4;
const a1 = 5;
const a2 = 6;

pub fn main() void {
    var ram: [4096]u8 = @splat(0);
    var cpu = Cpu.init(&ram);

    const prog = [_]u32{
        lT(.hi, a0, 0x2000), //      0: a0 = 0x2000 << 15 = the UART address
        aluImm(.mov, a2, 128), //    1: a2 = address of the string
        loadT(.lbu, a1, a2, 0), //   2: loop: a1 = byte at [a2]
        iT(.beq, a1, zero, 4), //    3: if a1 == 0 goto 7 (done)
        storeT(.sb, a1, a0, 0), //   4: write a1 to the UART
        aluImm(.add, a2, 1), //      5: a2 += 1
        lT(.jal, zero, -4), //       6: goto 2
        ebreak(), //                 7: done
    };
    for (prog, 0..) |w, i| std.mem.writeInt(u32, ram[i * 4 ..][0..4], w, .little);

    const msg = "Hello from BARE64!\n\x00";
    @memcpy(ram[128..][0..msg.len], msg[0..msg.len]);

    var steps: usize = 0;
    while (!cpu.halted and steps < 1000) : (steps += 1) cpu.step();

    std.debug.print("steps = {d}\n", .{steps});
}
