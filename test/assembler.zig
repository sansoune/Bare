const std = @import("std");
const emu = @import("emu");

const assembler = emu.assembler;

const expectEqual = std.testing.expectEqual;

fn assembleProgram(source: []const u8, out: []u32) !usize {
    var bad_line: usize = 0;
    return assembler.assemble(source, out, &bad_line);
}

fn assembleBytes(source: []const u8, out: []u8) !usize {
    var bad_line: usize = 0;
    return assembler.assembleBytes(source, out, &bad_line);
}

test "Assembler: register operands" {
    try expectEqual(
        emu.aluReg(.add, 4, 5),
        try assembler.assembleLine("add a0, a1"),
    );

    try expectEqual(
        emu.aluReg(.add, 31, 30),
        try assembler.assembleLine("add fp, s10"),
    );

    try expectEqual(
        emu.aluReg(.add, 4, 5),
        try assembler.assembleLine("add r4, r5"),
    );
}

test "Assembler: immediate operands" {
    try expectEqual(
        emu.aluImm(.add, 4, 10),
        try assembler.assembleLine("add a0, 10"),
    );

    try expectEqual(
        emu.aluImm(.add, 4, -1),
        try assembler.assembleLine("add a0, -1"),
    );

    try expectEqual(
        emu.aluImm(.mov, 4, 0x100),
        try assembler.assembleLine("mov a0, 0x100"),
    );

    try expectEqual(
        emu.aluImm(.mov, 4, 0b1010),
        try assembler.assembleLine("mov a0, 0b1010"),
    );
}

test "Assembler: and and or mnemonics" {
    try expectEqual(
        emu.aluReg(.and_, 4, 5),
        try assembler.assembleLine("and a0, a1"),
    );

    try expectEqual(
        emu.aluReg(.or_, 4, 5),
        try assembler.assembleLine("or a0, a1"),
    );
}

test "Assembler: character immediates" {
    try expectEqual(
        emu.aluImm(.mov, 4, 'A'),
        try assembler.assembleLine("mov a0, 'A'"),
    );
}

test "Assembler: load instructions" {
    try expectEqual(
        emu.loadT(.lw, 4, 2, 0),
        try assembler.assembleLine("ld.w a0, [sp]"),
    );

    try expectEqual(
        emu.loadT(.lb, 4, 2, 12),
        try assembler.assembleLine("ld.b a0, [sp + 12]"),
    );

    try expectEqual(
        emu.loadT(.ld, 4, 2, -8),
        try assembler.assembleLine("ld.d a0, [sp - 8]"),
    );

    try expectEqual(
        emu.loadT(.lhu, 4, 2, 4),
        try assembler.assembleLine("ld.hu a0, [sp + 4]"),
    );
}

test "Assembler: store instructions" {
    try expectEqual(
        emu.storeT(.sw, 4, 2, 0),
        try assembler.assembleLine("st.w a0, [sp]"),
    );

    try expectEqual(
        emu.storeT(.sb, 5, 2, 8),
        try assembler.assembleLine("st.b a1, [sp + 8]"),
    );

    try expectEqual(
        emu.storeT(.sd, 4, 2, -16),
        try assembler.assembleLine("st.d a0, [sp - 16]"),
    );
}

test "Assembler: branch instructions" {
    try expectEqual(
        emu.iT(.beq, 4, 5, 3),
        try assembler.assembleLine("beq a0, a1, 3"),
    );

    try expectEqual(
        emu.iT(.bne, 4, 5, -2),
        try assembler.assembleLine("bne a0, a1, -2"),
    );

    try expectEqual(
        emu.iT(.blt, 4, 5, 10),
        try assembler.assembleLine("blt a0, a1, 10"),
    );
}

test "Assembler: greater-than aliases swap operands" {
    try expectEqual(
        emu.iT(.blt, 5, 4, 2),
        try assembler.assembleLine("bgt a0, a1, 2"),
    );

    try expectEqual(
        emu.iT(.bge, 5, 4, 2),
        try assembler.assembleLine("ble a0, a1, 2"),
    );

    try expectEqual(
        emu.iT(.bltu, 5, 4, 2),
        try assembler.assembleLine("bgtu a0, a1, 2"),
    );

    try expectEqual(
        emu.iT(.bgeu, 5, 4, 2),
        try assembler.assembleLine("bleu a0, a1, 2"),
    );
}

test "Assembler: zero comparison branches" {
    try expectEqual(
        emu.iT(.beq, 4, 0, 5),
        try assembler.assembleLine("bz a0, 5"),
    );

    try expectEqual(
        emu.iT(.bne, 4, 0, -3),
        try assembler.assembleLine("bnz a0, -3"),
    );
}

test "Assembler: nop and halt" {
    try expectEqual(
        emu.aluImm(.mov, 0, 0),
        try assembler.assembleLine("nop"),
    );

    try expectEqual(
        emu.ebreak(),
        try assembler.assembleLine("halt"),
    );
}

test "Assembler: ret and jmpr" {
    try expectEqual(
        emu.iT(.jalr, 0, 1, 0),
        try assembler.assembleLine("ret"),
    );

    try expectEqual(
        emu.iT(.jalr, 0, 5, 0),
        try assembler.assembleLine("jmpr a1"),
    );
}

test "Assembler: small li expands to one instruction" {
    var out: [4]u32 = undefined;

    try expectEqual(
        @as(usize, 1),
        try assembleProgram("li a0, 123", &out),
    );

    try expectEqual(
        emu.aluImm(.mov, 4, 123),
        out[0],
    );
}

test "Assembler: large li expands to two instructions" {
    var out: [4]u32 = undefined;

    try expectEqual(
        @as(usize, 2),
        try assembleProgram("li a0, 305419896", &out),
    );

    try expectEqual(
        emu.lT(.hi, 4, 0x2469),
        out[0],
    );

    try expectEqual(
        emu.aluImm(.add, 4, -10632),
        out[1],
    );
}

test "Assembler: hi and pchi instructions" {
    try expectEqual(
        emu.lT(.hi, 4, 0x2000),
        try assembler.assembleLine("hi a0, 8192"),
    );

    try expectEqual(
        emu.lT(.pchi, 4, 1),
        try assembler.assembleLine("pchi a0, 1"),
    );
}

test "Assembler: labels resolve branch offsets" {
    var out: [8]u32 = undefined;

    const source =
        \\start:
        \\    add a0, 1
        \\    bne a0, zero, start
        \\    halt
    ;

    try expectEqual(@as(usize, 3), try assembleProgram(source, &out));

    try expectEqual(
        emu.aluImm(.add, 4, 1),
        out[0],
    );

    try expectEqual(
        emu.iT(.bne, 4, 0, -1),
        out[1],
    );

    try expectEqual(
        emu.ebreak(),
        out[2],
    );
}

test "Assembler: forward labels resolve correctly" {
    var out: [8]u32 = undefined;

    const source =
        \\    beq a0, zero, target
        \\    nop
        \\target:
        \\    halt
    ;

    try expectEqual(@as(usize, 3), try assembleProgram(source, &out));

    try expectEqual(
        emu.iT(.beq, 4, 0, 2),
        out[0],
    );
}

test "Assembler: jmp resolves a label" {
    var out: [8]u32 = undefined;

    const source =
        \\    jmp target
        \\    nop
        \\target:
        \\    halt
    ;

    try expectEqual(@as(usize, 3), try assembleProgram(source, &out));

    try expectEqual(
        emu.lT(.jal, 0, 2),
        out[0],
    );
}

test "Assembler: call resolves a label" {
    var out: [8]u32 = undefined;

    const source =
        \\    call target
        \\    nop
        \\target:
        \\    ret
    ;

    try expectEqual(@as(usize, 3), try assembleProgram(source, &out));

    try expectEqual(
        emu.lT(.jal, 1, 2),
        out[0],
    );
}

test "Assembler: la resolves a label" {
    var out: [8]u32 = undefined;

    const source =
        \\    la a0, target
        \\    nop
        \\target:
        \\    halt
    ;

    try expectEqual(@as(usize, 4), try assembleProgram(source, &out));

    try expectEqual(
        emu.lT(.pchi, 4, 0),
        out[0],
    );

    try expectEqual(
        emu.aluImm(.add, 4, 12),
        out[1],
    );
}

test "Assembler: byte half word and dword directives" {
    var out: [32]u8 = @splat(0);

    const source =
        \\.byte 0x12
        \\.half 0x3456
        \\.word 0x789ABCDE
        \\.dword 0x0102030405060708
    ;

    const size = try assembleBytes(source, &out);

    try expectEqual(@as(usize, 15), size);

    try expectEqual(@as(u8, 0x12), out[0]);
    try expectEqual(@as(u8, 0x56), out[1]);
    try expectEqual(@as(u8, 0x34), out[2]);

    try expectEqual(@as(u8, 0xDE), out[3]);
    try expectEqual(@as(u8, 0xBC), out[4]);
    try expectEqual(@as(u8, 0x9A), out[5]);
    try expectEqual(@as(u8, 0x78), out[6]);

    try expectEqual(@as(u8, 0x08), out[7]);
    try expectEqual(@as(u8, 0x01), out[14]);
}

test "Assembler: ascii and asciz strings" {
    var out: [32]u8 = @splat(0);

    const source =
        \\.ascii "Hi"
        \\.asciz "BARE"
    ;

    const size = try assembleBytes(source, &out);

    try expectEqual(@as(usize, 7), size);
    try std.testing.expectEqualSlices(u8, "HiBARE\x00", out[0..7]);
}

test "Assembler: string escape sequences" {
    var out: [32]u8 = @splat(0);

    const source =
        \\.asciz "A\nB\tC"
    ;

    const size = try assembleBytes(source, &out);

    try expectEqual(@as(usize, 6), size);
    try std.testing.expectEqualSlices(u8, "A\nB\tC\x00", out[0..6]);
}

test "Assembler: space reserves zeroed bytes" {
    var out: [32]u8 = @splat(0xFF);

    const size = try assembleBytes(".space 4", &out);

    try expectEqual(@as(usize, 4), size);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out[0..4]);
}

test "Assembler: align inserts padding" {
    var out: [32]u8 = @splat(0xFF);

    const size = try assembleBytes(
        \\.byte 1
        \\.align 4
        \\.byte 2
    , &out);

    try expectEqual(@as(usize, 5), size);

    try expectEqual(@as(u8, 1), out[0]);
    try expectEqual(@as(u8, 0), out[1]);
    try expectEqual(@as(u8, 0), out[2]);
    try expectEqual(@as(u8, 0), out[3]);
    try expectEqual(@as(u8, 2), out[4]);
}

test "Assembler: instructions after data require alignment" {
    var out: [32]u8 = @splat(0);
    var bad_line: usize = 0;

    try std.testing.expectError(
        error.MisalignedInstruction,
        assembler.assembleBytes(
            \\.byte 1
            \\halt
        , &out, &bad_line),
    );
}

test "Assembler: aligned instructions after data" {
    var out: [32]u8 = @splat(0);

    const source =
        \\.byte 1
        \\.align 4
        \\halt
    ;

    const size = try assembleBytes(source, &out);

    try expectEqual(@as(usize, 8), size);
    try expectEqual(
        emu.ebreak(),
        std.mem.readInt(u32, out[4..8], .little),
    );
}

test "Assembler: comments are ignored" {
    try expectEqual(
        emu.aluImm(.add, 4, 1),
        try assembler.assembleLine("add a0, 1 ; increment a0"),
    );
}

test "Assembler: whitespace is ignored" {
    try expectEqual(
        emu.aluReg(.add, 4, 5),
        try assembler.assembleLine("   add    a0 ,   a1   "),
    );
}

test "Assembler: blank lines and comment-only lines are ignored" {
    var out: [4]u32 = undefined;

    const source =
        \\; program comment
        \\
        \\nop
        \\; another comment
        \\halt
    ;

    try expectEqual(@as(usize, 2), try assembleProgram(source, &out));
}

test "Assembler: rejects unknown mnemonics" {
    try std.testing.expectError(
        error.UnknownMnemonic,
        assembler.assembleLine("foobar a0, a1"),
    );
}

test "Assembler: rejects invalid registers" {
    try std.testing.expectError(
        error.BadRegister,
        assembler.assembleLine("add a8, a1"),
    );

    try std.testing.expectError(
        error.BadRegister,
        assembler.assembleLine("add r32, a1"),
    );
}

test "Assembler: rejects invalid operands" {
    try std.testing.expectError(
        error.BadOperand,
        assembler.assembleLine("add a0, hello"),
    );
}

test "Assembler: rejects wrong operand counts" {
    try std.testing.expectError(
        error.WrongOperandCount,
        assembler.assembleLine("add a0"),
    );

    try std.testing.expectError(
        error.WrongOperandCount,
        assembler.assembleLine("add a0, a1, a2"),
    );
}

test "Assembler: rejects out-of-range immediates" {
    try std.testing.expectError(
        error.ImmediateOutOfRange,
        assembler.assembleLine("add a0, 16384"),
    );

    try std.testing.expectError(
        error.ImmediateOutOfRange,
        assembler.assembleLine("add a0, -16385"),
    );
}

test "Assembler: rejects empty instructions" {
    try std.testing.expectError(
        error.EmptyLine,
        assembler.assembleLine("   "),
    );

    try std.testing.expectError(
        error.EmptyLine,
        assembler.assembleLine("; comment only"),
    );
}

test "Assembler: rejects unknown labels" {
    var out: [8]u32 = undefined;
    var bad_line: usize = 0;

    try std.testing.expectError(
        error.UnknownLabel,
        assembler.assembleBytes(
            \\jmp missing
        , std.mem.sliceAsBytes(&out), &bad_line),
    );
}

test "Assembler: rejects duplicate labels" {
    var out: [8]u32 = undefined;
    var bad_line: usize = 0;

    try std.testing.expectError(
        error.DuplicateLabel,
        assembler.assembleBytes(
            \\loop:
            \\nop
            \\loop:
            \\halt
        , std.mem.sliceAsBytes(&out), &bad_line),
    );
}

test "Assembler: rejects invalid label names" {
    var out: [8]u32 = undefined;
    var bad_line: usize = 0;

    try std.testing.expectError(
        error.BadLabel,
        assembler.assembleBytes(
            \\9invalid:
            \\halt
        , std.mem.sliceAsBytes(&out), &bad_line),
    );
}

test "Assembler: rejects unknown directives" {
    var out: [8]u32 = undefined;
    var bad_line: usize = 0;

    try std.testing.expectError(
        error.UnknownDirective,
        assembler.assembleBytes(
            \\.unknown 123
        , std.mem.sliceAsBytes(&out), &bad_line),
    );
}

test "Assembler: rejects programs that exceed output capacity" {
    var out: [4]u8 = undefined;
    var bad_line: usize = 0;

    try std.testing.expectError(
        error.ProgramTooLong,
        assembler.assembleBytes(
            \\.dword 0x1234567890ABCDEF
        , &out, &bad_line),
    );
}

test "Assembler: too many operands are rejected" {
    try std.testing.expectError(
        error.TooManyOperands,
        assembler.assembleLine("add a0, a1, a2, a3, a4"),
    );
}

test "Assembler: assembled loop executes correctly" {
    var ram: [256]u8 = @splat(0);
    var cpu = emu.Cpu.init(&ram);

    const source =
        \\li a0, 0
        \\li a1, 1
        \\li a2, 6
        \\loop:
        \\    add a0, a1
        \\    add a1, 1
        \\    bne a1, a2, loop
        \\halt
    ;

    _ = try assembleBytes(source, &ram);

    var steps: usize = 0;
    while (!cpu.halted and steps < 100) : (steps += 1) {
        cpu.step();
    }

    try std.testing.expect(cpu.halted);
    try expectEqual(@as(u64, 15), cpu.getReg(4));
    try expectEqual(@as(u64, 6), cpu.getReg(5));
}
