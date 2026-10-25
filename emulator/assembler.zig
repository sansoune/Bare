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
    UnknownLabel, // a jump names a label that does not exist
    DuplicateLabel, // the same label is defined twice
    TooManyLabels, // more than 64 labels
    BadLabel, // a label must start with a letter or _ and contain only letters, digits, _ or .
    ProgramTooLong, // the output buffer is too small
    NeedsProgram,
    UnknownDirective, // a line starting with . that we do not know
    MisalignedInstruction, // code must start at a multiple of 4: put `.align 4` after odd-sized data
    MisalignedLabel,
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

fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0; // 0 = outside quotes, otherwise the quote character we are inside
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == '\\') {
                i += 1; // skip the escaped character
            } else if (c == quote) {
                quote = 0;
            }
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == ';') {
            return line[0..i];
        }
    }
    return line;
}

const max_labels = 64;

/// Label names and the instruction index each one points at.
const Labels = struct {
    names: [max_labels][]const u8 = undefined,
    indexes: [max_labels]usize = undefined,
    count: usize = 0,

    fn add(self: *Labels, name: []const u8, index: usize) AsmError!void {
        if (self.find(name) != null) return error.DuplicateLabel;
        if (self.count == max_labels) return error.TooManyLabels;
        self.names[self.count] = name;
        self.indexes[self.count] = index;
        self.count += 1;
    }

    fn find(self: *const Labels, name: []const u8) ?usize {
        for (self.names[0..self.count], self.indexes[0..self.count]) |n, i| {
            if (std.mem.eql(u8, n, name)) return i;
        }
        return null;
    }
};

/// Where we are in a whole program: the current instruction's index and the labels.
const Context = struct { address: usize, labels: *const Labels };

fn validLabelName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') return false;
    }
    return true;
}

/// A jump distance, in instructions: either a plain number or a label name.
fn offsetOperand(text: []const u8, ctx: ?Context, min_v: i64, max_v: i64) AsmError!i64 {
    if (parseNumber(text) != null) return number(text, min_v, max_v);

    const c = ctx orelse return error.BadOperand; // one line alone: only numbers
    if (!validLabelName(text)) return error.BadOperand;
    const target = c.labels.find(text) orelse return error.UnknownLabel;
    if (target % 4 != 0) return error.MisalignedLabel;

    // Both addresses are multiples of 4, so the shift is exact.
    const distance = (@as(i64, @intCast(target)) - @as(i64, @intCast(c.address))) >> 2;
    if (distance < min_v or distance > max_v) return error.ImmediateOutOfRange;
    return distance;
}

fn encodeLi(rd: u5, v: i64, out: *[2]u32) AsmError!usize {
    if (v >= -16384 and v <= 16383) {
        out[0] = emu.aluImm(.mov, rd, @intCast(v));
        return 1;
    }
    if (v < -(1 << 36) or v > (1 << 36)) return error.ImmediateOutOfRange;
    const upper = (v + 16384) >> 15; // rounded, so that `lower` fits a signed 15-bit number
    const lower = v - (upper << 15);
    if (upper < -1048576 or upper > 1048575) return error.ImmediateOutOfRange;
    out[0] = emu.lT(.hi, rd, @intCast(upper));
    if (lower == 0) return 1;
    out[1] = emu.aluImm(.add, rd, @intCast(lower));
    return 2;
}

fn emitLa(args: []const []const u8, ctx: ?Context, out: *[2]u32) AsmError!usize {
    try needOperands(args, 2);
    const rd = try reg(args[0]);
    const c = ctx orelse return error.NeedsProgram;
    if (!validLabelName(args[1])) return error.BadOperand;
    const target = c.labels.find(args[1]) orelse return error.UnknownLabel;

    // The distance from this instruction to the label, in bytes.
    const bytes = @as(i64, @intCast(target)) - @as(i64, @intCast(c.address));
    const upper = (bytes + 16384) >> 15;
    const lower = bytes - (upper << 15);
    if (upper < -1048576 or upper > 1048575) return error.ImmediateOutOfRange;
    out[0] = emu.lT(.pchi, rd, @intCast(upper));
    out[1] = emu.aluImm(.add, rd, @intCast(lower));
    return 2;
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

fn asmBranch(br: Branch, args: []const []const u8, ctx: ?Context) AsmError!u32 {
    try needOperands(args, 3);
    var left = try reg(args[0]);
    var right = try reg(args[1]);
    if (br.swap) std.mem.swap(u5, &left, &right);
    const offset = try offsetOperand(args[2], ctx, -32768, 32767);
    return emu.iT(br.op, left, right, @intCast(offset));
}

fn asmBranchZero(op: emu.Opcode, args: []const []const u8, ctx: ?Context) AsmError!u32 {
    try needOperands(args, 2);
    const r = try reg(args[0]);
    const offset = try offsetOperand(args[1], ctx, -32768, 32767);
    return emu.iT(op, r, 0, @intCast(offset));
}

pub fn assembleLine(line: []const u8) AsmError!u32 {
    var words: [2]u32 = undefined;
    const n = try assembleInstruction(line, null, &words);
    if (n != 1) return error.NeedsProgram;
    return words[0];
}

const Parsed = struct { mnemonic: []const u8, ops: [4][]const u8, count: usize };

fn parseLine(line: []const u8) AsmError!Parsed {
    // Clean: drop the comment and the spaces around the line.
    var text = stripComment(line);
    text = std.mem.trim(u8, text, " \t\r");
    if (text.len == 0) return error.EmptyLine;

    // Split: "mnemonic operand, operand, ...".
    const split = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    var p: Parsed = .{ .mnemonic = text[0..split], .ops = undefined, .count = 0 };
    const rest = std.mem.trim(u8, text[split..], " \t");
    if (rest.len > 0) {
        var it = std.mem.splitScalar(u8, rest, ',');
        while (it.next()) |piece| {
            if (p.count == p.ops.len) return error.TooManyOperands;
            p.ops[p.count] = std.mem.trim(u8, piece, " \t");
            p.count += 1;
        }
    }
    return p;
}

fn assembleSingle(mnemonic: []const u8, args: []const []const u8, ctx: ?Context) AsmError!u32 {
    if (aluFunc(mnemonic)) |func| return asmAlu(func, args);
    for (mem_ops) |m| if (is(m.name, mnemonic)) return asmMem(m, args);
    for (branches) |br| if (is(br.name, mnemonic)) return asmBranch(br, args, ctx);

    if (is(mnemonic, "bz")) return asmBranchZero(.beq, args, ctx);
    if (is(mnemonic, "bnz")) return asmBranchZero(.bne, args, ctx);

    if (is(mnemonic, "nop")) {
        try needOperands(args, 0);
        return emu.aluImm(.mov, 0, 0); // mov zero, 0: writes nothing anywhere
    }
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
    if (is(mnemonic, "jmp")) { // jmp label, or jmp N (instructions, from the jmp itself)
        try needOperands(args, 1);
        const offset = try offsetOperand(args[0], ctx, -1048576, 1048575);
        return emu.lT(.jal, 0, @intCast(offset));
    }
    if (is(mnemonic, "call")) { // like jmp, but leaves the return address in ra
        try needOperands(args, 1);
        const offset = try offsetOperand(args[0], ctx, -1048576, 1048575);
        return emu.lT(.jal, 1, @intCast(offset));
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

fn assembleInstruction(code: []const u8, ctx: ?Context, out: *[2]u32) AsmError!usize {
    const p = try parseLine(code);
    const args = p.ops[0..p.count];

    if (is(p.mnemonic, "li")) {
        try needOperands(args, 2);
        const rd = try reg(args[0]);
        const value = try number(args[1], std.math.minInt(i64), std.math.maxInt(i64));
        return encodeLi(rd, value, out);
    }
    if (is(p.mnemonic, "la")) return emitLa(args, ctx, out);

    out[0] = try assembleSingle(p.mnemonic, args, ctx);
    return 1;
}

fn wordCount(code: []const u8) AsmError!usize {
    const p = try parseLine(code);
    const args = p.ops[0..p.count];

    if (is(p.mnemonic, "li")) {
        try needOperands(args, 2);
        const rd = try reg(args[0]);
        const value = try number(args[1], std.math.minInt(i64), std.math.maxInt(i64));
        var scratch: [2]u32 = undefined;
        return encodeLi(rd, value, &scratch);
    }
    if (is(p.mnemonic, "la")) return 2;
    return 1;
}

const Parts = struct { label: ?[]const u8, code: []const u8 };

fn splitLabel(line: []const u8) AsmError!Parts {
    const text = std.mem.trim(u8, stripComment(line), " \t\r");

    const split = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    const first = text[0..split];
    if (first.len > 0 and first[first.len - 1] == ':') {
        const name = first[0 .. first.len - 1];
        if (!validLabelName(name)) return error.BadLabel;
        return .{ .label = name, .code = std.mem.trim(u8, text[split..], " \t") };
    }
    return .{ .label = null, .code = text };
}

fn isDirective(code: []const u8) bool {
    return code.len > 0 and code[0] == '.';
}

fn put(out: ?[]u8, at: usize, byte: u8) AsmError!void {
    if (out) |o| {
        if (at >= o.len) return error.ProgramTooLong;
        o[at] = byte;
    }
}

fn fitsSize(v: i64, size: usize) bool {
    return switch (size) {
        1 => v >= -128 and v <= 255,
        2 => v >= -32768 and v <= 65535,
        4 => v >= -2147483648 and v <= 4294967295,
        else => true,
    };
}

fn emitNumbers(rest: []const u8, size: usize, pos: usize, out: ?[]u8) AsmError!usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |piece| {
        const text = std.mem.trim(u8, piece, " \t");
        const v = parseNumber(text) orelse return error.BadOperand;
        if (!fitsSize(v, size)) return error.ImmediateOutOfRange;
        const bits: u64 = @bitCast(v);
        for (0..size) |k| try put(out, pos + n + k, @truncate(bits >> @intCast(8 * k)));
        n += size;
    }
    return n;
}

fn emitString(rest: []const u8, zero_end: bool, pos: usize, out: ?[]u8) AsmError!usize {
    if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') return error.BadOperand;
    const body = rest[1 .. rest.len - 1];

    var n: usize = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        var c = body[i];
        if (c == '\\') {
            i += 1;
            if (i == body.len) return error.BadOperand;
            c = switch (body[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                '\\' => '\\',
                '"' => '"',
                else => return error.BadOperand,
            };
        }
        try put(out, pos + n, c);
        n += 1;
    }
    if (zero_end) {
        try put(out, pos + n, 0);
        n += 1;
    }
    return n;
}

fn emitDirective(code: []const u8, pos: usize, out: ?[]u8) AsmError!usize {
    const split = std.mem.indexOfAny(u8, code, " \t") orelse code.len;
    const name = code[0..split];
    const rest = std.mem.trim(u8, code[split..], " \t");

    if (is(name, ".byte")) return emitNumbers(rest, 1, pos, out);
    if (is(name, ".half")) return emitNumbers(rest, 2, pos, out);
    if (is(name, ".word")) return emitNumbers(rest, 4, pos, out);
    if (is(name, ".dword")) return emitNumbers(rest, 8, pos, out);
    if (is(name, ".ascii")) return emitString(rest, false, pos, out);
    if (is(name, ".asciz")) return emitString(rest, true, pos, out);
    if (is(name, ".space")) {
        const n: usize = @intCast(try number(rest, 0, 1 << 20));
        for (0..n) |i| try put(out, pos + i, 0);
        return n;
    }
    if (is(name, ".align")) {
        const a: usize = @intCast(try number(rest, 1, 4096));
        const rem = pos % a;
        const pad = if (rem == 0) 0 else a - rem;
        for (0..pad) |i| try put(out, pos + i, 0);
        return pad;
    }
    return error.UnknownDirective;
}

pub fn assembleBytes(source: []const u8, out: []u8, bad_line: *usize) AsmError!usize {
    var labels = Labels{};

    // Pass 1: find where every label points (a byte address), by measuring each line.
    var pos: usize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        bad_line.* = line_no;
        const parts = try splitLabel(raw);
        if (parts.label) |name| try labels.add(name, pos);
        if (parts.code.len == 0) continue;
        if (isDirective(parts.code)) {
            pos += try emitDirective(parts.code, pos, null);
        } else {
            if (pos % 4 != 0) return error.MisalignedInstruction;
            const words = try wordCount(parts.code);
            pos += 4 * words;
        }
    }

    // Pass 2: emit the bytes, with every label known.
    var tmp: [2]u32 = undefined;
    pos = 0;
    line_no = 0;
    lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        bad_line.* = line_no;
        const parts = try splitLabel(raw);
        if (parts.code.len == 0) continue;
        if (isDirective(parts.code)) {
            pos += try emitDirective(parts.code, pos, out);
        } else {
            const n = try assembleInstruction(parts.code, .{ .address = pos, .labels = &labels }, &tmp);
            if (pos + 4 * n > out.len) return error.ProgramTooLong;
            for (tmp[0..n], 0..) |w, k| std.mem.writeInt(u32, out[pos + 4 * k ..][0..4], w, .little);
            pos += 4 * n;
        }
    }
    return pos;
}

pub fn assemble(source: []const u8, out: []u32, bad_line: *usize) AsmError!usize {
    const bytes = try assembleBytes(source, std.mem.sliceAsBytes(out), bad_line);
    return (bytes + 3) / 4;
}
