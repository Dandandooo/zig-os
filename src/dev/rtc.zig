const io = @import("../api/io.zig").io;

const rtc_regs = struct {
    time_low: u32,
    time_high: u32,
    alarm_low: u32,
    alarm_high: u32,
    clear_interrupt: u32
};

const rtc_device = struct {
    regs: *volatile rtc_regs,
    instno: u32,
    io: io
};

// Exported functions
pub fn rtc_attach(mmio_base: *anyopaque) {

}
