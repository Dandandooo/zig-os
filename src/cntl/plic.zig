const assert = @import("../util/debug.zig").assert;
const config = @import("../config.zig");
const log = @import("std").log.scoped(.PLIC);

// Constant Definitions
pub const PLIC_PRIO_MIN: comptime_int = 1;
pub const PLIC_PRIO_MAX: comptime_int = 7;
const PLIC_CTX_CNT: usize = config.PLIC_CTX_CNT;
const PLIC_SRC_CNT: usize = config.PLIC_SRC_CNT;

const PLIC_UINT_SIZE: comptime_int = 32;

pub const NIRQ: comptime_int = config.NIRQ;

inline fn CTX(hart_id: u32, s_mode: bool) u32 {
    return 2 * hart_id + @intFromBool(s_mode);
}


// Internal Type Definitions
const plic_regs: type = extern struct {
    // priority: union { data: [PLIC_SRC_CNT]u32, _reserved: [0x1000]u8 },
    // pending: union { data: [PLIC_SRC_CNT / PLIC_UINT_SIZE]u32, _reserved: [0x1000]u8 },
    // enable: union { data: [PLIC_CTX_CNT][PLIC_UINT_SIZE]u32, _reserved: [0x200000 - 0x2000]u8 },
    priority: [PLIC_SRC_CNT]u32 align(0x1000),
    // _pad1: [0x1000 - 4 * PLIC_SRC_CNT]u8,
    pending: [PLIC_SRC_CNT/PLIC_UINT_SIZE]u32 align(0x1000),
    enable: [PLIC_CTX_CNT]extern struct {
        pages: [PLIC_SRC_CNT/PLIC_UINT_SIZE]u32 align(0x80)
    } align(0x1000),

    ctx: [PLIC_CTX_CNT] extern struct {
        threshold: u32 align(0x1000),
        claim: u32
    } align(0x20000),
};

// Globals
const PLIC: *volatile plic_regs = @ptrFromInt(config.PLIC_MMIO_BASE);

// Exported Functions
pub var initialized = false;
pub fn init() void {
    assert(initialized == false, "PLIC already initialized!");

    log.debug("&PLIC.priority == {*}", .{&PLIC.priority});
    log.debug("&PLIC.pending == {*}", .{&PLIC.pending});
    log.debug("&PLIC.enable == {*}", .{&PLIC.enable});
    log.debug("&PLIC.ctx == {*}", .{&PLIC.ctx});

    // disable all interrupt sources
    for (1..PLIC_SRC_CNT) |i| set_source_priority(@intCast(i), 0);
    log.debug("Set source priorities to zero", .{});

    // Route all interrupts to S-mode
    for (0..PLIC_CTX_CNT) |i| disable_all_sources_for_context(@intCast(i));
    log.debug("Disabled all context sources", .{});

    // CTX(i,0) is hartid /i/ M-mode context
    // CTX(i,1) is hartid /i/ S-mode context

    // init hart 0 S-mode context
    enable_all_sources_for_context(CTX(0, true));
    log.debug("Enabled all CTX=1 sources", .{});

    log.info("initialized", .{});
    initialized = true;
}

pub fn enable_source(srcno: u32, prio: u32) void {
    assert(0 < srcno and srcno < PLIC_SRC_CNT, "invalid PLIC srcno!");
    assert(PLIC_PRIO_MIN <= prio and prio <= PLIC_PRIO_MAX, "invalid PLIC priority!");
    // log.info("srcno: {d}, prio: {d}", .{srcno, prio});
    set_source_priority(srcno, prio);
}

pub fn disable_source(srcno: u32) void {
    assert(0 < srcno and srcno < PLIC_SRC_CNT, "invalid PLIC srcno!");
    set_source_priority(srcno, 0);
}

pub fn claim_interrupt() u32 {
    // hart 0 S-mode context
    return claim_context_interrupt(CTX(0, true));
}

pub fn finish_interrupt(srcno: u32) void {
    assert(0 < srcno and srcno < PLIC_SRC_CNT, "invalid PLIC srcno!");
    complete_context_interrupt(CTX(0, true), srcno);
}

// Internal Functions

inline fn set_source_priority(srcno: u32, level: u32) void {
    assert(0 < srcno and srcno < PLIC_SRC_CNT, "invalid PLIC srcno!");
    assert(level <= PLIC_PRIO_MAX, "invalid PLIC priority!");
    // log.debug("srcno: {d}, prio: {d}", .{srcno, level});
    // log.debug("&PLIC.priority == {*}", .{&PLIC.priority});
    // log.debug("&PLIC.priority.data[{d}] == {*}", .{srcno, &PLIC.priority[srcno]});
    PLIC.priority[srcno] = level;
}

inline fn source_pending(srcno: u32) u32 {
    assert(0 < srcno and srcno < PLIC_SRC_CNT, "invalid PLIC srcno!");
    return (PLIC.pending[srcno / PLIC_UINT_SIZE] & (1 << (srcno & 31))) >> (srcno % PLIC_UINT_SIZE);
}

inline fn enable_source_for_context(ctxno: u32, srcno: u32) void {
    assert(ctxno < PLIC_CTX_CNT, "invalid PLIC ctxno!");
    assert(0 < srcno and srcno < PLIC_SRC_CNT, "invalid PLIC srcno!");
    PLIC.enable[ctxno].pages[srcno / PLIC_UINT_SIZE] |= (1 << @intCast(srcno % PLIC_UINT_SIZE));
}

inline fn disable_source_for_context(ctxno: u32, srcno: u32) void {
    assert(ctxno < PLIC_CTX_CNT, "invalid PLIC ctxno!");
    assert(0 < srcno and srcno < PLIC_SRC_CNT, "invalid PLIC srcno!");
    PLIC.enable[ctxno].pages[srcno / PLIC_UINT_SIZE] &= ~(1 << @intCast(srcno % PLIC_UINT_SIZE));
}

inline fn set_context_threshold(ctxno: u32, level: u32) void {
    assert(ctxno < PLIC_CTX_CNT, "invalid PLIC ctxno!");
    PLIC.ctx[ctxno].threshold = level;
}

inline fn claim_context_interrupt(ctxno: u32) u32 {
    assert(ctxno < PLIC_CTX_CNT, "invalid PLIC ctxno!");
    return PLIC.ctx[ctxno].claim;
}

inline fn complete_context_interrupt(ctxno: u32, srcno: u32) void {
    assert(ctxno < PLIC_CTX_CNT, "invalid PLIC ctxno!");
    assert(0 < srcno and srcno < PLIC_SRC_CNT, "invalid PLIC srcno!");
    PLIC.ctx[ctxno].claim = srcno;
}

inline fn enable_all_sources_for_context(ctxno: u32) void {
    assert(ctxno < PLIC_CTX_CNT, "invalid PLIC ctxno!");
    for (&PLIC.enable[ctxno].pages) |*elem| elem.* = 0xFFFF_FFFF;
}

inline fn disable_all_sources_for_context(ctxno: u32) void {
    assert(ctxno < PLIC_CTX_CNT, "invalid PLIC ctxno!");
    for (&PLIC.enable[ctxno].pages) |*elem| elem.* = 0x0000_0000;
}
