const thread = @import("../conc/thread.zig");
const intr = @import("./intr.zig");
const excp = @import("./excp.zig");

pub fn init() void {
    intr.init();
    excp.init();
}

// All RISC-V General Purpose Registers
pub const frame = extern struct {
    a: [8]usize,  // a0-a7
    t: [7]usize,  // t0-t6
    s: [11]usize, // s1-s11
    ra: *anyopaque,
    sp: *anyopaque,
    gp: *anyopaque,
    tp: *thread,
    sstatus: usize,
    instret: u64,
    fp: *anyopaque,
    sepc: *anyopaque
};
