const std = @import("std");
const uart = @import("uart.zig");
const isa = @import("isa.zig");
const memory = @import("memory.zig");

pub const Fault = enum {
    illegal_instruction,
    fetch_misaligned, //    value = the pc
    fetch_access, //        value = the pc
    load_misaligned, //     value = the address
    load_access, //         value = the address
    store_misaligned, //    value = the address
    store_access, //        value = the address
};

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

pub const FaultInfo = struct { fault: Fault, pc: u64, value: u64 };

pub const Cpu = struct {
    regs: [32]u64 = @splat(0),
    pc: u64 = 0,
    mem: []u8,
    halted: bool = false,

    fault: ?FaultInfo = null,

    uart: uart.Buffer = .{},

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
        return self.uart.text();
    }

    pub fn fetch(self: *Cpu) ?u32 {
        if (self.pc & 3 != 0) {
            self.raise(.fetch_misaligned, self.pc);
            return null;
        }

        const mem_len: u64 = self.mem.len;
        if (mem_len < 4 or self.pc > mem_len - 4) {
            self.raise(.fetch_access, self.pc);
            return null;
        }

        const a: usize = @intCast(self.pc);

        return std.mem.readInt(u32, self.mem[a..][0..4], .little);
    }

    pub fn illegal(self: *Cpu, inst: u64) void {
        self.raise(.illegal_instruction, inst);
    }

    fn raise(self: *Cpu, cause: Fault, value: u64) void {
        self.fault = .{ .fault = cause, .pc = self.pc, .value = value };
        self.halted = true;
        if (self.uart.echo) std.debug.print("{s}: 0x{x} at pc=0x{x}\n", .{ @tagName(cause), value, self.pc });
    }

    fn memLoad(self: *Cpu, addr: u64, size: u64) ?u64 {
        if (uart.load(addr)) |value| return value;
        return memory.load(self.mem, addr, size);
    }

    fn memStore(self: *Cpu, addr: u64, size: u64, value: u64) bool {
        if (addr == uart.uart_tx) {
            self.uart.transmit(value);
            return true;
        }

        return memory.store(self.mem, addr, size, value);
    }

    pub fn step(self: *Cpu) void {
        const inst = self.fetch() orelse return;

        const op: isa.Opcode = @fromBackingInt(@intCast(@as(u6, @truncate(inst >> 26))));
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
                const func: isa.Func = @fromBackingInt(@intCast(funct));
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
                if (addr & (size - 1) != 0) return self.raise(.load_misaligned, addr);
                const raw = self.memLoad(addr, size) orelse
                    return self.raise(.load_access, addr);
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
                if (addr & (size - 1) != 0) return self.raise(.store_misaligned, addr);
                if (!self.memStore(addr, size, self.getReg(a))) {
                    return self.raise(.store_access, addr);
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
                const pf: isa.Priv = @fromBackingInt(@intCast(funct));
                if (pf == .ebreak) self.halted = true else self.illegal(inst);
            },
            else => self.illegal(inst),
        }

        if (self.fault == null) self.pc = next_pc;
    }
};
