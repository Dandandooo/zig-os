const Thread = @import("../conc/thread.zig");
const intr = @import("./intr.zig");
const excp = @import("./excp.zig");

pub fn init() void {
    intr.init();
    excp.init();
}

extern fn trap_frame_jump(tfr: *Frame, anchor: *Thread.stack_anchor) void;

// All RISC-V General Purpose Registers
pub const Frame = extern struct {
    a: [8]usize,  // a0-a7
    t: [7]usize,  // t0-t6
    s: [11]usize, // s1-s11
    ra: *anyopaque,
    sp: *anyopaque,
    gp: *anyopaque,
    tp: *Thread,
    sstatus: usize,
    instret: u64,
    fp: *anyopaque,
    sepc: *anyopaque,

    fn jump(self: *Frame, anchor: *Thread.stack_anchor) void {
        trap_frame_jump(self, anchor);
    }
};
