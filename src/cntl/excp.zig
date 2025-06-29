const reg = @import("../riscv/reg.zig");
const trap = @import("trap.zig");
const assert = @import("std").debug.assert;

// Exported Definitions

var initialized: bool = false;
pub fn init() void {
    assert(initialized == false);
    // maybe do something
    initialized = true;
}

export fn handle_smode_exception(cause: u32, tfr: *const trap.frame) void {
    _ = cause;
    _ = tfr;
}

export fn handle_umode_exception(cause: u32, tfr: *const trap.frame) void {
    _ = cause;
    _ = tfr;
}
