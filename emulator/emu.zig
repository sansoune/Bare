const std = @import("std");

pub const Cpu = struct {
    regs: [32]u64 = @splat(0),
    pc: u64 = 0,
    mem: []u8,
    halted: bool = false,

    pub fn setReg(self: *Cpu, index: u5, value: u64) void {
        if (index != 0) self.regs[index] = value;
    }
};

pub fn main() void {
    std.debug.print("hello world! \n", .{});
}
