const thread = @import("../conc/thread.zig");
const intr = @import("./intr.zig");
const excp = @import("./excp.zig");

pub fn init() void {
    intr.init();
    excp.init();
}

// All RISC-V General Purpose Registers
pub const frame = struct {
    a: [8]usize,
    t: [7]usize,
    s: [12]usize,
    ra: *anyopaque,
    sp: *anyopaque,
    gp: *anyopaque,
    tp: *thread.context,
    sstatus: usize,
    instret: u64,
    fp: *anyopaque,
    sepc: *anyopaque
};
