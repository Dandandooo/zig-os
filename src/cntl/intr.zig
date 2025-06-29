const config = @import("../config.zig");
const assert = @import("std").debug.assert;
const plic = @import("./plic.zig");
const thread = @import("../conc/thread.zig");
const timer = @import("../conc/timer.zig");
const reg = @import("../riscv/reg.zig");


// Constants

pub const INTR_PRIO_MIN = plic.PLIC_PRIO_MIN;
pub const INTR_PRIO_MAX: comptime_int = plic.PLIC_PRIO_MAX;

// Globals
const isrtab_entry: type = struct { isr: *const fn (u32, *anyopaque) void, aux: *anyopaque };
var isrtab: [config.NIRQ]?isrtab_entry = [_]?isrtab_entry{null} ** config.NIRQ;

// Exported functions
//

// Global Interrupt
var initialized: bool = false;
pub fn init() void {
    assert(initialized == false);
    _ = disable();
    plic.init();

    // Enable Timer and External interrupts
    _ = reg.csrrw("sie", reg.SIE_STIE | reg.SIE_SEIE);

    initialized = true;
}

pub inline fn enable() usize {
    return reg.csrrsi("sstatus", reg.SSTATUS_SIE);
}

pub inline fn disable() usize {
    return reg.csrrci("sstatus", reg.SSTATUS_SIE);
}

pub inline fn restore(prev: usize) void {
    assert((prev & ~reg.SSTATUS_SIE) == 0);
    reg.csrc("sstatus", reg.SSTATUS_SIE);
    reg.csrs("sstatus", prev);
}

pub inline fn enabled() bool {
    return (reg.csrr("sstatus") & reg.SSTATUS_SIE) != 0;
}

pub inline fn disabled() bool {
    return (reg.csrr("sstatus") & reg.SSTATUS_SIE) == 0;
}

// Handlers
pub export fn handle_smode_interrupt(cause: u32) void {
    handle_interrupt(cause);
}

pub export fn handle_umode_interrupt(cause: u32) void {
    handle_interrupt(cause);
    // thread.yield(); // FIXME
}

fn handle_interrupt(cause: u32) void {
    switch (cause) {
        // reg.SCAUSE_STI => timer.handle_interrupt(),
        reg.SCAUSE_SEI => handle_extern_interrupt(),
        else => @panic("unknown interrupt"),
    }
}

fn handle_extern_interrupt() void {
    const srcno: u32 = plic.claim_interrupt();
    assert(srcno < config.NIRQ);

    if (srcno == 0) return;

    if (isrtab[srcno] == null) @panic("can't find isr");

    isrtab[srcno].?.isr(srcno, isrtab[srcno].?.aux);

    plic.finish_interrupt(srcno);
}

// Registering ISRs
pub fn enable_source(srcno: u32, prio: u32, isr: *const fn (u32, *anyopaque) void, aux: *anyopaque) void {
    assert(0 < srcno and srcno < config.NIRQ);
    assert(0 < prio);
    assert(isrtab[srcno] == null);

    isrtab[srcno] = .{ .isr = isr, .aux = aux };
    plic.enable_source(srcno, prio);
}

pub fn disable_source(srcno: u32) void {
    assert(0 < srcno and srcno < config.NIRQ);
    assert(isrtab[srcno] != null);

    plic.disable_source(srcno);
    isrtab[srcno] = null;
}
