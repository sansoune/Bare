const std = @import("std");
const emu = @import("emu.zig");

pub const AsmError = error{
    EmptyLine, // nothing but spaces or a comment
    UnknownMnemonic, // the instruction name is not one we know
    TooManyOperands,
    WrongOperandCount, // e.g. `add a0` or `add a0, a1, a2`
    BadRegister, // the destination is not a register name
    BadOperand, // the second operand is neither a register nor a number
    ImmediateOutOfRange, // does not fit in a signed 15-bit number
};

const reg_names = [32][]const u8{
    "zero", "ra", "sp",  "tp",
    "a0",   "a1", "a2",  "a3",
    "a4",   "a5", "a6",  "a7",
    "t0",   "t1", "t2",  "t3",
    "t4",   "t5", "t6",  "t7",
    "s0",   "s1", "s2",  "s3",
    "s4",   "s5", "s6",  "s7",
    "s8",   "s9", "s10", "fp",
};

fn parseReg(text: []const u8) ?u5 {
    for (reg_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, text)) {
            const r: u5 = @intCast(i);
            return r;
        }
    }

    if (text.len >= 2 and text[0] == 'r') {
        const n = std.fmt.parseInt(u8, text[1..], 10) catch return null;
        if (n < 32) {
            const r: u5 = @intCast(n);
            return r;
        }
    }
    return null;
}

fn parseNumber(text: []const u8) ?i64 {
    if (text.len == 3 and text[0] == '\'' and text[2] == '\'') {
        const c: i64 = text[1];
        return c;
    }
    return std.fmt.parseInt(i64, text, 0) catch null; // base 0: understands 0x and 0b
}

fn aluFunc(name: []const u8) ?emu.Func {
    if (std.mem.eql(u8, name, "and")) return .and_;
    if (std.mem.eql(u8, name, "or")) return .or_;
    return std.meta.stringToEnum(emu.Func, name);
}

pub fn assembleLine(line: []const u8) AsmError!u32 {
    var text = line;
    if (std.mem.indexOfScalar(u8, text, ';')) |i| text = text[0..i];
    text = std.mem.trim(u8, text, " \t\r");
    if (text.len == 0) return error.EmptyLine;

    const split = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    const mnemonic = text[0..split];
    const rest = std.mem.trim(u8, text[split..], " \t");

    var ops: [4][]const u8 = undefined;
    var count: usize = 0;
    if (rest.len > 0) {
        var it = std.mem.splitScalar(u8, rest, ',');
        while (it.next()) |piece| {
            if (count == ops.len) return error.TooManyOperands;
            ops[count] = std.mem.trim(u8, piece, " \t");
            count += 1;
        }
    }

    const func = aluFunc(mnemonic) orelse return error.UnknownMnemonic;
    if (count != 2) return error.WrongOperandCount;

    const dst = parseReg(ops[0]) orelse return error.BadRegister;
    if (parseReg(ops[1])) |src| return emu.aluReg(func, dst, src);

    const imm = parseNumber(ops[1]) orelse return error.BadOperand;
    if (imm < -16384 or imm > 16383) return error.ImmediateOutOfRange;
    return emu.aluImm(func, dst, @intCast(imm));
}
