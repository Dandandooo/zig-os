const reg = @import("./reg.zig");
const config = @import("../config.zig");

// Startup functions

pub fn mmode_start

// Physical Memory Protection
fn pmp_setup() void {
    // Guard Region (No Access): [0, 0x100)
    // cfg0: 1_00_11_000 == 0x98 (L, NAPOT)
    reg.csrrw("pmpaddr0", pmp_range(0, 0x100));

    // MMIO Region (R/W): [0, 0x8000_0000)
    // cfg1: 1_00_11_011 == 0x9B (L, NAPOT, W/R)
    reg.csrrw("pmpaddr1", pmp_range(0, 0x8000_0000));

    // RAM Region (R/W/X): [0x8000_0000, +RAM_SIZE)
    // cfg2: 1_00_11_111 == 0x9F (L, NAPOT, X/W/R)
    reg.csrrw("pmpaddr2", pmp_range(0x8000_0000, config.RAM_SIZE));

    // cfg2_cfg1_cfg0
    reg.csrrw("pmpcfg0", 0x9F9B98);
}

// [start, start+size)
fn pmp_range(start: comptime_int, size: comptime_int) comptime_int {
    return (start >> 2) | ((size >> 3) - 1);
}
