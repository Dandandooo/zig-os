const reg = @import("../riscv/reg.zig");
const trap = @import("trap.zig");

// Exported Definitions

pub fn init() void {

}

export fn handle_smode_exception(cause: u32, tfr: *const trap.frame) void {
    _ = cause;
    _ = tfr;
}
