const std = @import("std");
const reg = @import("../riscv/reg.zig");
const trap = @import("trap.zig");
const assert = @import("../util/debug.zig").assert;
const kernel = @import("../kernel.zig");

const log = @import("std").log.scoped(.EXCEPTION);

// Exported Definitions

var initialized: bool = false;
pub fn init() void {
    assert(initialized == false, "exceptions already initialized!");
    // maybe do something
    log.info("initialized", .{});
    initialized = true;
}

export fn handle_smode_exception(cause: u32, tfr: *const trap.frame) void {
    const scause: reg.scause = @enumFromInt(cause);
    switch (scause) {
        .LOAD_PAGE_FAULT,
        .STORE_PAGE_FAULT,
        .INSTR_PAGE_FAULT,
        .LOAD_ADDR_MISALIGNED,
        .STORE_ADDR_MISALIGNED,
        .INSTR_ADDR_MISALIGNED,
        .LOAD_ACCESS_FAULT,
        .STORE_ACCESS_FAULT,
        .INSTR_ACCESS_FAULT => log.err("\x1b[31;1m{s}\x1b[0m at 0x{X} for 0x{X} in S mode", .{@tagName(scause), @intFromPtr(tfr.sepc), reg.csrr("stval")}),
        else => log.err("\x1b[31;1m{s}\x1b[0m at 0x{X} in S mode", .{@tagName(scause), @intFromPtr(tfr.sepc)})
    }
    kernel.crash();
}

export fn handle_umode_exception(cause: u32, tfr: *const trap.frame) void {
    const scause: reg.scause = @enumFromInt(cause);
    _ = scause;
    _ = tfr;
    // Complete after virtual memory
}
