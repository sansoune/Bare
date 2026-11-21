pub const time_addr: u64 = 0x1000_1000;
pub const cmp_addr: u64 = 0x1000_1008;

pub const Timer = struct {
    time: u64 = 0,
    cmp: u64 = 0,

    pub fn tick(self: *Timer) void {
        self.time +%= 1;
    }

    pub fn pending(self: *const Timer) bool {
        return self.cmp != 0 and self.time >= self.cmp;
    }

    pub fn load(self: *const Timer, addr: u64, size: u64) ?u64 {
        if (size != 8) return null;
        if (addr == time_addr) return self.time;
        if (addr == cmp_addr) return self.cmp;
        return null;
    }

    pub fn store(self: *Timer, addr: u64, size: u64, value: u64) bool {
        if (size != 8 or addr != cmp_addr) return false;
        self.cmp = value;
        return true;
    }
};
