const std = @import("std");
const reg = @import("../riscv/reg.zig");
const page = @import("./page.zig");
const heap = @import("./heap.zig");
const config = @import("../config.zig");
const assert = @import("../util/debug.zig").assert;

const log = std.log.scoped(.VMEM);

/// Internal Constant Definitions

pub const PTE_V = 1 << 0;
pub const PTE_R = 1 << 1;
pub const PTE_W = 1 << 2;
pub const PTE_X = 1 << 3;
pub const PTE_U = 1 << 4;
pub const PTE_G = 1 << 5;
pub const PTE_A = 1 << 6;
pub const PTE_D = 1 << 7;


const PTE_CNT = page.SIZE / @sizeOf(PTE);

/// Internal Type Definitions

pub const PTEFlags = packed struct(u8) {
	valid: bool = false,
	read: bool = false,
	write: bool = false,
	exec: bool = false,
	user: bool = false,
	global: bool = false,
	accessed: bool = false,
	dirty: bool = false
};

const PTE: type = packed struct(u64) {
	flags: PTEFlags = .{.valid = false},
	rsw: u2 = 0,
	ppn: u44 = 0,
	reserved: u7 = 0,
	pbmt: u2 = 0,
	n: u1 = 0,

	fn is_leaf(self: *PTE) bool {
		return self.flags.read or self.flags.write or self.flags.exec;
	}

	fn new_ptab(pma: usize, global: bool) PTE {
		return .{ .ppn = to_ppn(pma), .flags = .{.global = global, .valid = true} };
	}

	fn new_leaf(pma: usize, rwxug: PTEFlags) PTE {
		return .{ .ppn = to_ppn(pma), .flags = .{
			.read = rwxug.read, .write = rwxug.write, .exec = rwxug.exec,
			.user = rwxug.user, .global = rwxug.global, .valid = true
		} };
	}
};

fn to_ppn(pma: usize) u44 {
	return @truncate(pma >> page.ORDER);
}

fn to_pma(ppn: u44) usize {
	return @as(usize, @intCast(ppn)) << page.ORDER;
}

fn offset(pp: *align(page.SIZE) anyopaque) usize {
	return @intFromPtr(pp) & (page.SIZE - 1);
}

fn to_mtag(ppn: u44, asid: u16) MTAG {
	return .{ .ppn = ppn, .asid = asid, .mode = .Sv39 };
}


const PTab: type = [PTE_CNT]PTE;

const MTAG: type = reg.satp;

const Error: type = error{
	InvalidVMA,
	InvalidPMA,
	OOM,
};

/// Macros

inline fn vpn2(vma: usize) usize { return (vpn(vma) >> (2 * 9)) & (PTE_CNT - 1); }
inline fn vpn1(vma: usize) usize { return (vpn(vma) >> (1 * 9)) & (PTE_CNT - 1); }
inline fn vpn0(vma: usize) usize { return (vpn(vma) >> (0 * 9)) & (PTE_CNT - 1); }
inline fn vpn(vma: usize) usize { return vma >> page.ORDER; }

/// Globals

var main_mtag: MTAG = undefined;

var main_pt2: PTab align(page.SIZE) linksection(".bss.pagetable") = [_]PTE{.{}} ** PTE_CNT;
var main_pt1: PTab align(page.SIZE) linksection(".bss.pagetable") = [_]PTE{.{}} ** PTE_CNT;
var main_pt0: PTab align(page.SIZE) linksection(".bss.pagetable") = [_]PTE{.{}} ** PTE_CNT;

extern const _kimg_text_start: anyopaque;
extern const _kimg_text_end: anyopaque;
extern const _kimg_rodata_start: anyopaque;
extern const _kimg_rodata_end: anyopaque;
extern const _kimg_data_start: anyopaque;
extern const _kimg_data_end: anyopaque;

/// Exported Function Definitions
var initialized = false;
pub fn init() void {
	assert(initialized == false, "vmem already initialized!");

	// Everything until ram start is direct gigapage mapping (MMIO Region)
	log.debug("MMIO: 0x{X:0>8} -> 0x{X:0>8}", .{0, config.RAM_START_PMA});
	var pma: usize = 0;
	while (pma < config.RAM_START_PMA) : (pma += page.GIGA_SIZE)
		main_pt2[vpn2(pma)] = .new_leaf(pma, .{.global = true, .read = true});

	// Beginning of kernel region
	main_pt2[vpn2(config.RAM_START_PMA)] = .new_ptab(@intFromPtr(&main_pt1), true);
	main_pt1[vpn1(config.RAM_START_PMA)] = .new_ptab(@intFromPtr(&main_pt0), true);

	log.debug("text: 0x{X:0>8} -> 0x{X:0>8}", .{@intFromPtr(&_kimg_text_start), @intFromPtr(&_kimg_text_end)});
	pma = @intFromPtr(&_kimg_text_start);
	while (pma < @intFromPtr(&_kimg_text_end)) : (pma += page.SIZE)
		main_pt0[vpn0(pma)] = .new_leaf(pma, .{.global = true, .read = true, .exec = true});

	log.debug("rodata: 0x{X:0>8} -> 0x{X:0>8}", .{@intFromPtr(&_kimg_rodata_start), @intFromPtr(&_kimg_rodata_end)});
	pma = @intFromPtr(&_kimg_rodata_start);
	while (pma < @intFromPtr(&_kimg_rodata_end)) : (pma += page.SIZE)
		main_pt0[vpn0(pma)] = .new_leaf(pma, .{.global = true, .read = true});

	log.debug("data: 0x{X:0>8} -> 0x{X:0>8}", .{@intFromPtr(&_kimg_data_start), @intFromPtr(&_kimg_data_end)});
	pma = @intFromPtr(&_kimg_data_start);
	while (pma < @intFromPtr(&_kimg_data_end)) : (pma += page.SIZE)
		main_pt0[vpn0(pma)] = .new_leaf(pma, .{.global = true, .read = true, .write = true});

	// Directly map remaining bits as MEGA pages
	pma = config.RAM_START_PMA + page.MEGA_SIZE;
	while (pma < config.RAM_END_PMA) : (pma += page.MEGA_SIZE)
		main_pt1[vpn1(pma)] = .new_leaf(pma, .{.global = true, .read = true, .write = true});

	// Enable Paging
	log.debug("Gonna enable paging 🫣 🤞", .{});
	main_mtag = to_mtag(to_ppn(@intFromPtr(&main_mtag)), 0);
	_ = reg.csrrw("satp", @bitCast(main_mtag));


	// TODO: Init heap here


	_ = reg.csrrs("sstatus", reg.SSTATUS_SUM);

	log.info("initialized", .{});
	initialized = true;
}

// Internal Functions

pub fn alloc_and_map_range() void {}
