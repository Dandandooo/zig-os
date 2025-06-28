const thread = @import("../conc/thread.zig");

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
