// RISCV constants and helper functions
//

// scause
pub const RISCV_SCAUSE_SSI: usize = 1;
pub const RISCV_SCAUSE_STI: usize = 5;
pub const RISCV_SCAUSE_SEI: usize = 9;

pub const RISCV_SCAUSE_INSTR_ADDR_MISALIGNED: usize = 0;
pub const RISCV_SCAUSE_INSTR_ACCESS_FAULT: usize = 1;
pub const RISCV_SCAUSE_ILLEGAL_INSTR: usize = 2;
pub const RISCV_SCAUSE_BREAKPOINT: usize = 3;
pub const RISCV_SCAUSE_LOAD_ADDR_MISALIGNED: usize = 4;
pub const RISCV_SCAUSE_LOAD_ACCESS_FAULT: usize = 5;
pub const RISCV_SCAUSE_STORE_ADDR_MISALIGNED: usize = 6;
pub const RISCV_SCAUSE_STORE_ACCESS_FAULT: usize = 7;
pub const RISCV_SCAUSE_ECALL_FROM_UMODE: usize = 8;
pub const RISCV_SCAUSE_ECALL_FROM_SMODE: usize = 9;
pub const RISCV_SCAUSE_INSTR_PAGE_FAULT: usize = 12;
pub const RISCV_SCAUSE_LOAD_PAGE_FAULT: usize = 13;
pub const RISCV_SCAUSE_STORE_PAGE_FAULT: usize = 15;

pub inline fn csrr_scause() isize {
    // FIXME: does this even work?
    return asm ("csrr %[ret], scause"
        : [ret] "=r" (-> isize),
    );
}

// stval

pub inline fn csrr_stval() usize {
    return asm ("csrr %[ret], stval"
        : [ret] "=r" (-> usize),
    );
}

// sepc

pub inline fn csrr_sepc() *const void {
    return asm ("csrr %[ret], sepc"
        : [ret] "=r" (-> *const void),
    );
}

pub inline fn csrw_sepc(pc: *const void) void {
    asm volatile ("csrw sepc, %[val]"
        :
        : [val] "r" (pc),
    );
}

// sscratch

pub inline fn csrr_sscratch() usize {
    return asm ("csrr %[ret], sscratch"
        : [ret] "=r" (-> *const void),
    );
}

pub inline fn csrw_sscratch(val: usize) void {
    asm volatile ("csrw sscratch, %[new]"
        :
        : [new] "r" (val),
    );
}

// stvec

pub const RISCV_STVEC_MODE_shift: usize = 0;
pub const RISCV_STVEC_MODE_nbits: usize = 2;
pub const RISCV_STVEC_BASE_shift: usize = 2;

// Works for 64 bit only
pub const RISCV_STVEC_BASE_nbits: usize = 62;

pub inline fn csrw_stvec(val: usize) void {
    asm volatile ("csrw stvec, %[new]"
        :
        : [new] "r" (val),
    );
}

// sie

pub const RISCV_SIE_SSIE: usize = 1 << 1;
pub const RISCV_SIE_STIE: usize = 1 << 5;
pub const RISCV_SIE_SEIE: usize = 1 << 9;

pub inline fn csrw_sie(mask: usize) void {
    asm volatile ("csrw sie, %[val]"
        :
        : [val] "r" (mask),
    );
}

pub inline fn csrs_sie(mask: usize) void {
    asm volatile ("csrrs zero, sie, %[val]"
        :
        : [val] "r" (mask),
    );
}

pub inline fn csrc_sie(mask: usize) void {
    asm volatile ("csrrc %[val], sie, %[val]"
        :
        : [val] "r" (mask),
    );
}

// sip

pub const RV32_SIP_SSIP: usize = 1 << 1;
pub const RV32_SIP_STIP: usize = 1 << 5;
pub const RV32_SIP_SEIP: usize = 1 << 9;

pub inline fn csrw_sip(mask: usize) void {
    asm volatile ("csrw sip, %[val]"
        :
        : [val] "r" (mask),
    );
}

pub inline fn csrs_sip(mask: usize) void {
    asm volatile ("csrrs zero, sip, %[val]"
        :
        : [val] "r" (mask),
    );
}

pub inline fn csrc_sip(mask: usize) void {
    asm volatile ("csrrc %[val], sip, %[val]"
        :
        : [val] "r" (mask),
    );
}

// sstatus

pub const RISCV_SSTATUS_SIE: usize = 1 << 1;
pub const RISCV_SSTATUS_SPIE: usize = 1 << 3;
pub const RISCV_SSTATUS_SPP: usize = 1 << 8;
pub const RISCV_SSTATUS_SUM: usize = 1 << 18;

pub inline fn csrr_sstatus() usize {
    return asm ("csrr %[ret], sstatus"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn csrs_sstatus(mask: usize) void {
    asm volatile ("csrs sstatus, %[val]"
        :
        : [val] "r" (mask),
    );
}

pub inline fn csrc_sstatus(mask: usize) void {
    asm volatile ("csrrc sstatus, %[val]"
        :
        : [val] "r" (mask),
    );
}

// csrrsi_sstatus_SIE() and csrrci_sstatus_SIE() set and clear sstatus.SIE. They
// return the previous value of the sstatus CSR.
pub inline fn csrrsi_sstatus_SIE() isize {
    return asm volatile ("csrrsi %[out], sstatus, %[in]"
        : [out] "=r" (-> isize),
        : [in] "I" (RISCV_SSTATUS_SIE),
    );
}

pub inline fn csrrci_sstatus_SIE() isize {
    return asm volatile ("csrrci %[out], sstatus, %[in]"
        : [out] "=r" (-> isize),
        : [in] "I" (RISCV_SSTATUS_SIE),
    );
}

// csrwi_sstatus_SIE() updates the SIE bit in the sstatus CSR. If the
// corresponding bit is set is _val_, then csrwi_sstatus_SIE() sets sstatus.SIE.
// Otherwise, it clears SIE. Note that there is no csrwi instruction: the _i_ is
// meant to suggest that the value is masked by RISCV_SSTATUS_SIE before being
// written to the sstatus CSR.
pub inline fn csrwi_sstatus_SIE(newval: isize) void {
    asm volatile ("csrci sstatus %[c]" + "\n\t" +
            "csrs sstatus, %[s]"
        :
        : [c] "I" (RISCV_SSTATUS_SIE),
          [s] "r" (newval & RISCV_SSTATUS_SIE),
        : "memory"
    );
}

// satp

// Only support rv64
pub const RISCV_SATP_MODE_Sv39: usize = 8;
pub const RISCV_SATP_MODE_Sv48: usize = 9;
pub const RISCV_SATP_MODE_Sv57: usize = 10;
pub const RISCV_SATP_MODE_Sv64: usize = 11;
pub const RISCV_SATP_MODE_shift: usize = 60;
pub const RISCV_SATP_MODE_nbits: usize = 4;
pub const RISCV_SATP_ASID_shift: usize = 44;
pub const RISCV_SATP_ASID_nbits: usize = 16;
pub const RISCV_SATP_PPN_shift: usize = 0;
pub const RISCV_SATP_PPN_nbits: usize = 44;

pub inline fn csrr_satp() usize {
    return asm ("csrr %[ret], satp"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn csrw_satp(val: usize) void {
    asm volatile ("csrw satp %[new]"
        :
        : [new] "r" (val),
    );
}

pub inline fn csrrw_satp(val: usize) usize {
    return asm volatile ("csrrw %[ret], satp, %[new]"
        : [ret] "=r" (-> usize),
        : [new] "r" (val),
    );
}

pub inline fn sfence_vma() void {
    asm volatile ("sfence.vma" ::: "memory");
}

// rdtime

pub inline fn rdtime() u64 {
    return asm ("rdtime %[ret]"
        : [ret] "=r" (-> u64),
    );
}
