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

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn needOperands(args: []const []const u8, n: usize) AsmError!void {
    if (args.len != n) return error.WrongOperandCount;
}

fn reg(text: []const u8) AsmError!u5 {
    const r = parseReg(text) orelse return error.BadRegister;
    return r;
}

fn number(text: []const u8, min_v: i64, max_v: i64) AsmError!i64 {
    const n = parseNumber(text) orelse return error.BadOperand;
    if (n < min_v or n > max_v) return error.ImmediateOutOfRange;
    return n;
}

fn asmAlu(func: emu.Func, args: []const []const u8) AsmError!u32 {
    try needOperands(args, 2);
    const dst = try reg(args[0]);
    if (parseReg(args[1])) |src| return emu.aluReg(func, dst, src);
    const imm = try number(args[1], -16384, 16383);
    return emu.aluImm(func, dst, @intCast(imm));
}

const MemOp = struct { name: []const u8, op: emu.Opcode, store: bool };

const mem_ops = [_]MemOp{
    .{ .name = "ld.b", .op = .lb, .store = false },
    .{ .name = "ld.bu", .op = .lbu, .store = false },
    .{ .name = "ld.h", .op = .lh, .store = false },
    .{ .name = "ld.hu", .op = .lhu, .store = false },
    .{ .name = "ld.w", .op = .lw, .store = false },
    .{ .name = "ld.wu", .op = .lwu, .store = false },
    .{ .name = "ld.d", .op = .ld, .store = false },
    .{ .name = "st.b", .op = .sb, .store = true },
    .{ .name = "st.h", .op = .sh, .store = true },
    .{ .name = "st.w", .op = .sw, .store = true },
    .{ .name = "st.d", .op = .sd, .store = true },
};

const MemOperand = struct { base: u5, offset: i16 };

fn parseMem(text: []const u8) AsmError!MemOperand {
    if (text.len < 3 or text[0] != '[' or text[text.len - 1] != ']') return error.BadOperand;
    const inner = std.mem.trim(u8, text[1 .. text.len - 1], " \t");

    const sign_at = std.mem.indexOfAny(u8, inner, "+-");
    const base_text = if (sign_at) |i| std.mem.trim(u8, inner[0..i], " \t") else inner;
    const base = try reg(base_text);

    var offset: i64 = 0;
    if (sign_at) |i| {
        const n = try number(std.mem.trim(u8, inner[i + 1 ..], " \t"), 0, 32768);
        offset = if (inner[i] == '-') -n else n;
    }
    if (offset < -32768 or offset > 32767) return error.ImmediateOutOfRange;
    return .{ .base = base, .offset = @intCast(offset) };
}

fn asmMem(m: MemOp, args: []const []const u8) AsmError!u32 {
    try needOperands(args, 2);
    const r = try reg(args[0]);
    const mem = try parseMem(args[1]);
    if (m.store) return emu.storeT(m.op, r, mem.base, mem.offset);
    return emu.loadT(m.op, r, mem.base, mem.offset);
}

const Branch = struct { name: []const u8, op: emu.Opcode, swap: bool };
const branches = [_]Branch{
    .{ .name = "beq", .op = .beq, .swap = false },
    .{ .name = "bne", .op = .bne, .swap = false },
    .{ .name = "blt", .op = .blt, .swap = false },
    .{ .name = "bge", .op = .bge, .swap = false },
    .{ .name = "bltu", .op = .bltu, .swap = false },
    .{ .name = "bgeu", .op = .bgeu, .swap = false },
    // Aliases: the same branch with its two registers swapped.
    .{ .name = "bgt", .op = .blt, .swap = true },
    .{ .name = "ble", .op = .bge, .swap = true },
    .{ .name = "bgtu", .op = .bltu, .swap = true },
    .{ .name = "bleu", .op = .bgeu, .swap = true },
};

fn asmBranch(br: Branch, args: []const []const u8) AsmError!u32 {
    try needOperands(args, 3);
    var left = try reg(args[0]);
    var right = try reg(args[1]);
    if (br.swap) std.mem.swap(u5, &left, &right);
    const offset = try number(args[2], -32768, 32767);
    return emu.iT(br.op, left, right, @intCast(offset));
}

fn asmBranchZero(op: emu.Opcode, args: []const []const u8) AsmError!u32 {
    try needOperands(args, 2);
    const r = try reg(args[0]);
    const offset = try number(args[1], -32768, 32767);
    return emu.iT(op, r, 0, @intCast(offset));
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
    const args = ops[0..count];

    if (aluFunc(mnemonic)) |func| return asmAlu(func, args);
    for (mem_ops) |m| if (is(m.name, mnemonic)) return asmMem(m, args);
    for (branches) |br| if (is(br.name, mnemonic)) return asmBranch(br, args);

    if (is(mnemonic, "bz")) return asmBranchZero(.beq, args);
    if (is(mnemonic, "bnz")) return asmBranchZero(.bne, args);

    if (is(mnemonic, "halt")) {
        try needOperands(args, 0);
        return emu.ebreak();
    }

    if (is(mnemonic, "ret")) {
        try needOperands(args, 0);
        return emu.iT(.jalr, 0, 1, 0); // jump to the address in ra
    }

    if (is(mnemonic, "jmpr")) {
        try needOperands(args, 1);
        return emu.iT(.jalr, 0, try reg(args[0]), 0);
    }

    if (is(mnemonic, "jmp")) { // jmp offset: counts instructions, from the jmp itself
        try needOperands(args, 1);
        const offset = try number(args[0], -1048576, 1048575);
        return emu.lT(.jal, 0, @intCast(offset));
    }

    if (is(mnemonic, "hi") or is(mnemonic, "pchi")) {
        try needOperands(args, 2);
        const rd = try reg(args[0]);
        const imm = try number(args[1], -1048576, 1048575);
        const op: emu.Opcode = if (is(mnemonic, "hi")) .hi else .pchi;
        return emu.lT(op, rd, @intCast(imm));
    }

    return error.UnknownMnemonic;
}
