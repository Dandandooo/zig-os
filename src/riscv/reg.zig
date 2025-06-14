const std = @import("std");

//////////
// CSRs //
//////////

pub inline fn csrr(comptime reg: []const u8) usize {
    return asm volatile (std.fmt.comptimePrint("csrr %[ret], {s}", .{reg})
        : [ret] "=r" (-> isize),
    );
}

pub inline fn csrrw(comptime reg: []const u8, val: usize) usize {
    return asm volatile (std.fmt.comptimePrint("csrw %[ret], {s}, %[new]", .{reg})
        : [ret] "=r" (-> usize),
        : [new] "r" (val),
    );
}

pub inline fn csrs(comptime reg: []const u8, mask: usize) void {
    asm volatile (std.fmt.comptimePrint("csrs {s}, %[val]", .{reg})
        :
        : [val] "r" (mask),
    );
}

pub inline fn csrrs(comptime reg: []const u8, mask: usize) usize {
    return asm volatile (std.fmt.comptimePrint("csrrs %[ret], {s}, %[val]", .{reg})
        : [ret] "=r" (-> usize),
        : [val] "r" (mask),
    );
}

pub inline fn csrrsi(comptime reg: []const u8, mask: comptime_int) usize {
    return asm volatile (std.fmt.comptimePrint("csrrsi %[ret], {s}, %[val]", .{reg})
        : [ret] "=r" (-> usize),
        : [val] "I" (mask),
    );
}

pub inline fn csrc(comptime reg: []const u8, mask: usize) void {
    asm volatile (std.fmt.comptimePrint("csrc {s}, %[val]", .{reg})
        :
        : [val] "r" (mask),
    );
    // Or just call csrrc and discard value
}

pub inline fn csrrc(comptime reg: []const u8, mask: usize) usize {
    return asm volatile (std.fmt.comptimePrint("csrrc %[ret], {s}, %[val]", .{reg})
        : [ret] "=r" (-> usize),
        : [val] "r" (mask),
    );
}

pub inline fn csrrci(comptime reg: []const u8, mask: comptime_int) usize {
    return asm volatile (std.fmt.comptimePrint("csrrci %[ret], {s}, %[val]", .{reg})
        : [ret] "=r" (-> usize),
        : [val] "I" (mask),
    );
}

pub inline fn rdtime() u64 {
    return asm ("rdtime %[ret]"
        : [ret] "=r" (-> u64),
    );
}

// CSR Masks

pub const SCAUSE_SSI: usize = 1;
pub const SCAUSE_STI: usize = 5;
pub const SCAUSE_SEI: usize = 9;

// enum may be overkill
pub const scause = enum(usize) {
    INSTR_ADDR_MISALIGNED = 0,
    INSTR_ACCESS_FAULT,
    ILLEGAL_INSTR,
    BREAKPOINT,
    LOAD_ADDR_MISALIGNED,
    LOAD_ACCESS_FAULT,
    STORE_ADDR_MISALIGNED,
    STORE_ACCESS_FAULT,
    ECALL_FROM_UMODE,
    ECALL_FROM_SMODE,
    INSTR_PAGE_FAULT = 12,
    LOAD_PAGE_FAULT,
    STORE_PAGE_FAULT = 15,
};
pub const SCAUSE_INSTR_ADDR_MISALIGNED: usize = 0;
pub const SCAUSE_INSTR_ACCESS_FAULT: usize = 1;
pub const SCAUSE_ILLEGAL_INSTR: usize = 2;
pub const SCAUSE_BREAKPOINT: usize = 3;
pub const SCAUSE_LOAD_ADDR_MISALIGNED: usize = 4;
pub const SCAUSE_LOAD_ACCESS_FAULT: usize = 5;
pub const SCAUSE_STORE_ADDR_MISALIGNED: usize = 6;
pub const SCAUSE_STORE_ACCESS_FAULT: usize = 7;
pub const SCAUSE_ECALL_FROM_UMODE: usize = 8;
pub const SCAUSE_ECALL_FROM_SMODE: usize = 9;
pub const SCAUSE_INSTR_PAGE_FAULT: usize = 12;
pub const SCAUSE_LOAD_PAGE_FAULT: usize = 13;
pub const SCAUSE_STORE_PAGE_FAULT: usize = 15;

pub const STVEC_MODE_shift: usize = 0;
pub const STVEC_MODE_nbits: usize = 2;
pub const STVEC_BASE_shift: usize = 2;

pub const SIE_SSIE: usize = 1 << 1;
pub const SIE_STIE: usize = 1 << 5;
pub const SIE_SEIE: usize = 1 << 9;

pub const SIP_SSIP: usize = 1 << 1;
pub const SIP_STIP: usize = 1 << 5;
pub const SIP_SEIP: usize = 1 << 9;

pub const SSTATUS_SIE: usize = 1 << 1;
pub const SSTATUS_SPIE: usize = 1 << 3;
pub const SSTATUS_SPP: usize = 1 << 8;
pub const SSTATUS_SUM: usize = 1 << 18;

// Only support rv64
pub const satp_mode = enum(u4) { Sv39 = 8, Sv48 = 9, Sv57 = 10, Sv64 = 11 };
pub const satp = packed struct(u64) { ppn: u44, asid: u16, mode: satp_mode };

////////////
// Memory //
////////////

pub inline fn sfence_vma() void {
    asm volatile ("sfence.vma" ::: "memory");
}

pub inline fn __sync_synchronize() void {
    asm volatile ("fence");
}
