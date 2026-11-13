const std = @import("std");

pub const uart_tx: u64 = 0x1000_0000;
pub const uart_status: u64 = 0x1000_0004;

pub const Buffer = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    echo: bool = true,

    pub fn text(self: *const Buffer) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn transmit(self: *Buffer, value: u64) void {
        const byte: u8 = @truncate(value);

        if (self.len < self.bytes.len) {
            self.bytes[self.len] = byte;
            self.len += 1;
        }

        if (self.echo) {
            std.debug.print("{c}", .{byte});
        }
    }
};

pub fn load(addr: u64) ?u64 {
    if (addr == uart_status) return 1;
    return null;
}
