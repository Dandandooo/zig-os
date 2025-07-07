const assert = @import("std").debug.assert;
const config = @import("../config.zig");

// Constant Definitions
pub const PLIC_PRIO_MIN: comptime_int = 1;
pub const PLIC_PRIO_MAX: comptime_int = 7;
const PLIC_CTX_CNT: usize = config.PLIC_CTX_CNT;
const PLIC_SRC_CNT: usize = config.PLIC_SRC_CNT;

const PLIC_UINT_SIZE: comptime_int = @sizeOf(u32);

pub const NIRQ: comptime_int = config.NIRQ;

inline fn CTX(hart_id: u32, s_mode: bool) u32 {
    return 2 * hart_id + @intFromBool(s_mode);
}

// Internal Type Definitions
const plic_regs: type = struct {
    priority: union { data: [PLIC_SRC_CNT]u32, _reserved: [0x1000]u8 },
    pending: union { data: [PLIC_SRC_CNT / PLIC_UINT_SIZE]u32, _reserved: [0x1000]u8 },
    enable: union { data: [PLIC_CTX_CNT][PLIC_UINT_SIZE]u32, _reserved: [0x200000 - 0x2000]u8 },

    ctx: [PLIC_CTX_CNT]union { cntl: struct { threshold: u32, claim: u32 }, _reserved_ctxcntl: [0x1000]u8 },
    // ctx: [PLIC_CTX_CNT]plic_ctx_entry,
};

// Globals
const PLIC: *plic_regs = @ptrFromInt(config.PLIC_MMIO_BASE);

// Exported Functions
pub var initialized = false;
pub fn init() void {
    assert(initialized == false);

    // disable all interrupt sources
    for (0..PLIC_SRC_CNT) |i| set_source_priority(@intCast(i), 0);

    // Route all interrupts to S-mode
    for (0..PLIC_CTX_CNT) |i| disable_all_sources_for_context(CTX(@intCast(i), false));

    // CTX(i,0) is hartid /i/ M-mode context
    // CTX(i,1) is hartid /i/ S-mode context

    // init hart 0 S-mode context
    enable_all_sources_for_context(CTX(0, false));
    initialized = true;
}

pub fn enable_source(srcno: u32, prio: u32) void {
    assert(0 < srcno and srcno < PLIC_SRC_CNT);
    assert(prio > 0);
    set_source_priority(srcno, prio);
}

pub fn disable_source(srcno: u32) void {
    assert(0 < srcno and srcno < PLIC_SRC_CNT);
    set_source_priority(srcno, 0);
}

pub fn claim_interrupt() u32 {
    // hart 0 S-mode context
    return claim_context_interrupt(CTX(0, false));
}

pub fn finish_interrupt(srcno: u32) void {
    assert(srcno < PLIC_SRC_CNT);
    complete_context_interrupt(CTX(0, false), srcno);
}

// Internal Functions

inline fn set_source_priority(srcno: u32, level: u32) void {
    assert(srcno < PLIC_SRC_CNT);
    assert(PLIC_PRIO_MIN <= level and level <= PLIC_PRIO_MAX);
    PLIC.priority.data[srcno] = level;
}

inline fn source_pending(srcno: u32) u32 {
    assert(srcno < PLIC_SRC_CNT);
    return (PLIC.pending.data[srcno >> 5] & (1 << (srcno & 31))) >> (srcno & 31);
}

inline fn enable_source_for_context(ctxno: u32, srcno: u32) void {
    assert(ctxno <= PLIC_CTX_CNT);
    assert(srcno < PLIC_SRC_CNT);
    PLIC.enable.data[ctxno][srcno >> 5] |= (1 << (srcno & 31));
}

inline fn disable_source_for_context(ctxno: u32, srcno: u32) void {
    assert(ctxno <= PLIC_CTX_CNT);
    assert(srcno < PLIC_SRC_CNT);
    PLIC.enable.data[ctxno][srcno >> 5] &= ~(1 << (srcno & 31));
}

inline fn set_context_threshold(ctxno: u32, level: u32) void {
    assert(ctxno <= PLIC_CTX_CNT);
    PLIC.ctx[ctxno].cntl.threshold = level;
}

inline fn claim_context_interrupt(ctxno: u32) u32 {
    assert(ctxno <= PLIC_CTX_CNT);
    return PLIC.ctx[ctxno].cntl.claim;
}

inline fn complete_context_interrupt(ctxno: u32, srcno: u32) void {
    assert(ctxno <= PLIC_CTX_CNT);
    assert(srcno < PLIC_SRC_CNT);
    PLIC.ctx[ctxno].cntl.claim = srcno;
}

inline fn enable_all_sources_for_context(ctxno: u32) void {
    assert(ctxno <= PLIC_CTX_CNT);
    @memset(&PLIC.enable.data[ctxno], 0xFFFF_FFFF);
}

inline fn disable_all_sources_for_context(ctxno: u32) void {
    assert(ctxno <= PLIC_CTX_CNT);
    @memset(&PLIC.enable.data[ctxno], 0);
}
