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
    eret = 2,
    csrr = 3,
    csrw = 4,
    _,
};

pub const Csr = enum(u16) {
    tvec = 0,
    epc = 1,
    cause = 2,
    tval = 3,
    ie = 4,
    _,
};

fn privWord(f: Priv, a: u32, payload: u32) u32 {
    return (@as(u32, @backingInt(Opcode.priv)) << 26) | (a << 21) | (@as(u32, @backingInt(f)) << 16) | (payload & 0xFFFF);
}

pub fn aluReg(f: Func, dst: u32, src: u32) u32 { // dst = dst <f> register
    return (@as(u32, @backingInt(Opcode.alu)) << 26) | (dst << 21) | (@as(u32, @backingInt(f)) << 16) | src;
}
pub fn aluImm(f: Func, dst: u32, imm: i32) u32 { // dst = dst <f> immediate
    return (@as(u32, @backingInt(Opcode.alu)) << 26) | (dst << 21) | (@as(u32, @backingInt(f)) << 16) | (1 << 15) | (@as(u32, @bitCast(imm)) & 0x7FFF);
}
pub fn iT(op: Opcode, a: u32, b: u32, imm: i32) u32 {
    return (@as(u32, @backingInt(op)) << 26) | (a << 21) | (b << 16) | (@as(u32, @bitCast(imm)) & 0xFFFF);
}
pub fn ebreak() u32 {
    return (@as(u32, @backingInt(Opcode.priv)) << 26) | (@as(u32, @backingInt(Priv.ebreak)) << 16);
}

pub fn ecall() u32 {
    return privWord(.ecall, 0, 0);
}

pub fn eret() u32 {
    return privWord(.eret, 0, 0);
}

pub fn csrr(rd: u32, csr: Csr) u32 {
    return privWord(.csrr, rd, @backingInt(csr));
}
pub fn csrw(csr: Csr, rs: u32) u32 {
    return privWord(.csrw, rs, @backingInt(csr));
}

pub fn lT(op: Opcode, rd: u32, imm: i32) u32 {
    return (@as(u32, @backingInt(op)) << 26) | (rd << 21) | (@as(u32, @bitCast(imm)) & 0x1FFFFF);
}

pub fn loadT(op: Opcode, rd: u32, base: u32, offset: i32) u32 {
    return iT(op, rd, base, offset);
}
// A holds the data register and B the base (the same layout as a branch).
pub fn storeT(op: Opcode, src: u32, base: u32, offset: i32) u32 {
    return iT(op, src, base, offset);
}
