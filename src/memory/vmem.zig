// Internal Constant Definitions
//

pub const PTE_V = 1 << 0;
pub const PTE_R = 1 << 1;
pub const PTE_W = 1 << 2;
pub const PTE_X = 1 << 3;
pub const PTE_U = 1 << 4;
pub const PTE_G = 1 << 5;
pub const PTE_A = 1 << 6;
pub const PTE_D = 1 << 7;


const PAGE_ORDER: usize = 12;
const PAGE_SIZE: usize = 1 << PAGE_ORDER;
const PTE_CNT = PAGE_SIZE / @sizeOf(pte_t);

// Internal Type Definitions
//
const pte_t: type = packed struct(u64) {
    flags: u8,
    rsw: u2 = 0,
    ppn: u44,
    reserved: u7 = 0,
    pbmt: u2 = 0,
    n: u1 = 0,

    fn new_ptab(pp: *const void, g_flag: u8) pte_t {
        return .{ .ppn = @as(usize, pp) >> PAGE_ORDER, .flags = g_flag | PTE_V };
    }

    fn new_leaf(pp: *const void, rwxug_flags: u8) pte_t {
        return .{ .ppn = @as(usize, pp) >> PAGE_ORDER, .flags = rwxug_flags | PTE_A | PTE_D | PTE_V };
    }
};
const ptab_t: type = [PTE_CNT]pte_t;

const mtag_t: type = packed struct(u64) { ppn: u44, asid: u16, mode: u4 };

const vmem_error: type = error{
    InvalidVMA,
    InvalidPMA,
    OOM,
};

const page_chunk_t: type = struct {
    next: *page_chunk_t,
    prev: *page_chunk_t,
    size: usize,
};

// Internal Macros
//
const ROUND_UP = @import("std").math.roundUp;
const ROUND_DOWN = @import("std").math.roundDown;

// Globals
//

@linkSection(".bss.pagetable"), var main_pt2: *ptab_t = null;

var free_chunks: *page_chunk_t;

// Exported Function Definitions
pub fn init() vmem_error!void {
    // TODO: get linker _kimg


}

// Internal Functions
/* Memory Management
 * Approach: Coalescing Free List
 * alloc_phys_page() - allocate a physical page
 * alloc_phys_pages() - allocate multiple physical pages
 * free_phys_page() - free a physical page
 * free_phys_pages() - free multiple physical pages
 */
pub fn alloc_phys_page() vmem_error!void* { return alloc_phys_pages(1); }

pub fn alloc_phys_pages(cnt: usize) vmem_error!void* {
    // TODO
}

pub fn free_phys_page(pp: *const void) vmem_error!void { return free_phys_pages(pp, 1);}

pub fn free_phys_pages(pp: *const void, cnt: usize) vmem_error!void {
    // TODO
}
