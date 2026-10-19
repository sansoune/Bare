const std = @import("std");
const emu = @import("emu");

test "Cpu: writting to registers" {
    var ram: [4096]u8 = @splat(0);

    var cpu = emu.Cpu{ .mem = &ram };

    cpu.setReg(5, 1234);

    try std.testing.expectEqual(@as(u64, 1234), cpu.regs[5]);
}

test "Cpu: r0 is hardwired to zero" {
    var ram: [4096]u8 = @splat(0);
    var cpu = emu.Cpu{ .mem = &ram };

    cpu.setReg(0, 99);
    try std.testing.expectEqual(@as(u64, 0), cpu.regs[0]);
}
