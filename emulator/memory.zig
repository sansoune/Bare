const std = @import("std");

pub fn load(mem: []const u8, addr: u64, size: u64) ?u64 {
    const len: u64 = mem.len;

    if (size > len or addr > len - size) return null;

    const off: usize = @intCast(addr);

    return switch (size) {
        1 => mem[off],
        2 => std.mem.readInt(u16, mem[off..][0..2], .little),
        4 => std.mem.readInt(u32, mem[off..][0..4], .little),
        8 => std.mem.readInt(u64, mem[off..][0..8], .little),
        else => unreachable,
    };
}

pub fn store(mem: []u8, addr: u64, size: u64, value: u64) bool {
    const len: u64 = mem.len;

    if (size > len or addr > len - size) return false;

    const off: usize = @intCast(addr);

    switch (size) {
        1 => mem[off] = @truncate(value),
        2 => std.mem.writeInt(
            u16,
            mem[off..][0..2],
            @truncate(value),
            .little,
        ),
        4 => std.mem.writeInt(
            u32,
            mem[off..][0..4],
            @truncate(value),
            .little,
        ),
        8 => std.mem.writeInt(
            u64,
            mem[off..][0..8],
            value,
            .little,
        ),
        else => unreachable,
    }

    return true;
}
