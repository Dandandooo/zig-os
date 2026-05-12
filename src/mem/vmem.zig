const std = @import("std");
const reg = @import("../riscv/reg.zig");
const page = @import("./page.zig");
const heap = @import("./heap.zig");
const config = @import("../config.zig");
const assert = @import("../util/debug.zig").assert;
const math = @import("../util/math.zig");

const log = std.log.scoped(.VMEM);

/// Internal Constant Definitions

pub const USER_REGION_START: usize = 0xC000_0000;
pub const USER_REGION_END: usize = 0x1_0000_0000;

pub const PTE_V = 1 << 0;
pub const PTE_R = 1 << 1;
pub const PTE_W = 1 << 2;
pub const PTE_X = 1 << 3;
pub const PTE_U = 1 << 4;
pub const PTE_G = 1 << 5;
pub const PTE_A = 1 << 6;
pub const PTE_D = 1 << 7;


const PTE_CNT = page.SIZE / @sizeOf(PTE);

/// VMA Utility

inline fn VPN(vma: u64) u44 { return @intCast(vma >> 20); }
inline fn VPN0(vma: u64) usize { return @intCast(VPN(vma) >> (0*9) % PTE_CNT); }
inline fn VPN1(vma: u64) usize { return @intCast(VPN(vma) >> (1*9) % PTE_CNT); }
inline fn VPN2(vma: u64) usize { return @intCast(VPN(vma) >> (2*9) % PTE_CNT); }

inline fn VMA_IDX0(vma: u64) usize { return @intCast((((1<<9-1) << (0*9)) & vma) >> (0*9)); }
inline fn VMA_IDX1(vma: u64) usize { return @intCast((((1<<9-1) << (1*9)) & vma) >> (1*9)); }
inline fn VMA_IDX2(vma: u64) usize { return @intCast((((1<<9-1) << (2*9)) & vma) >> (2*9)); }

inline fn INCR_VMA0(vma: u64) u64 { return vma + (1<<(0*9)); }
inline fn INCR_VMA1(vma: u64) u64 { return vma + (1<<(1*9)); }
inline fn INCR_VMA2(vma: u64) u64 { return vma + (1<<(2*9)); }

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

	fn children(self: *PTE) ?*PTab {
		if (self.is_leaf() or self.ppn == 0) return null;
		return @as(*PTab, self.pma());
	}

	fn pma(self: *PTE) u64 {
		return @as(u64, self.ppn) << 20;
	}

	fn pp(self: *PTE) ?*anyopaque {
		return @ptrFromInt(self.pma());
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

// -----------------------
// Memory Space Management
// -----------------------

pub fn active_mspace() MTAG {
	return reg.csrr("satp");
}

pub fn switch_mspace(mtag: MTAG) MTAG {
	defer reg.sfence_fma();
	return reg.csrrw("satp", @as(usize, mtag));
}

pub fn clone_active_mspace() MTAG {
	const old_mspace: MTAG = active_mspace();
	const oldtab2: *PTab = active_ptab();
	const newtab2: *PTab = page.phys_alloc(1);

	for (oldtab2, newtab2) |oldpte1, *newpte1| {

		// Start with baseline
		newpte1.* = oldpte1;

		// If it's global or empty, we're done here
		if (oldpte1.flags.global or oldpte1.ppn == 0)
			continue;

		// TODO: Handle GigaPages

		const newtab1: *PTab = page.phys_alloc(1);

		newpte1.ppn = @as(u64, newtab1) >> 20;

		for (oldpte1.children().?, newtab1) | oldpte0, *newpte0| {
			assert(!oldpte1.is_leaf(), "Incorrect PTE Depth (1)");
			newpte0.* = oldpte0;

			if (oldpte0.flags.global or oldpte0.ppn == 0)
				continue;

			// TODO: Handle MegaPages

			const newtab0: *PTab = page.phys_alloc(1);

			newpte0.ppn = @as(u64, newtab0) >> 20;

			for (oldpte0.children().?, newtab0) |oldleaf, *newleaf| {
				assert(oldleaf.is_leaf(), "Incorrect PTE Depth (1)");
				newleaf.* = oldleaf;

				if (oldleaf.flags.global or oldleaf.ppn == 0)
					continue;

				const newpage: *anyopaque = page.phys_alloc(1);

				@memcpy(newpage, @as(*anyopaque, oldleaf.pma()));
			}
		}
	}

	var new_mtag: MTAG = old_mspace;
	new_mtag.ppn = @as(usize, newtab2) >> 20;

	return new_mtag;
}

pub fn reset_active_mspace() void {
	unmap_and_free_range(@as(*anyopaque, USER_REGION_START), USER_REGION_END - USER_REGION_START);
	return reg.sfence_vma();
}

pub fn discard_active_mspace() MTAG {
	reset_active_mspace();
	if (active_mspace() != main_mtag) {
		page.phys_free(@as(u64, active_mspace().ppn) << 20);
	}
	return switch_mspace(main_mtag);
}

// ------------------
// Internal Functions
// ------------------

const traversal_func_t: type = (*fn (*PTE, *anyopaque) void);
const traversal_pair: type = struct {
	func: traversal_func_t,
	arg: ?*anyopaque
};
const traversal_funcs: type = struct {
	p2_before: ?traversal_pair = null,
	p1_before: ?traversal_pair = null,
	p0_during: ?traversal_pair = null,
	p1_after: ?traversal_pair = null,
	p2_after: ?traversal_pair = null,
};

fn pagetable_traverse(vma: u64, size: usize, funcs: *traversal_funcs) void {
	const ptab2 = active_ptab();


	for (VMA_IDX2(vma)..VMA_IDX2(vma + size)+1) | idx2 |{
		const pte2: *PTE = &ptab2[idx2];

		if (funcs.p2_before) | p2b | {
			p2b.func(pte2, p2b.arg);
		}

		const ptab1 = ptab2[idx2].children() orelse continue;

		for (VMA_IDX1(vma)..VMA_IDX1(vma + size)+1) | idx1 | {
			const pte1: *PTE = &ptab1[idx1];

			if (funcs.p1_before) | p1b | {
				p1b.func(pte1, p1b.arg);
			}

			const ptab0 = ptab1[idx1].children() orelse continue;

			for (VMA_IDX0(vma)..VMA_IDX1(vma + size)+1) | idx0 | {
				if (funcs.p0_during) |leaf| {
					leaf.func(&ptab0[idx0], leaf.arg);
				}
			}

			if (funcs.p1_after) | p1a | {
				p1a.func(pte1, p1a.arg);
			}
		}

		if (funcs.p2_after) | p2a | {
			p2a.func(pte2, p2a.arg);
		}
	}

	return reg.sfence_vma();
}

// ------------------------
// Direct VMEM Modification
// ------------------------

pub fn map_range(vma: u64, size: usize, pp: *anyopaque, flags: PTEFlags) *anyopaque {
	assert(vma % page.SIZE == 0, "vma must be page aligned");

	var pp_and_flags: struct { pp: *anyopaque, flags: PTEFlags } = .{ .pp = pp, .flags = flags };

	pagetable_traverse(vma, size, &.{
		.pt2_before = .{ .func = create_ptab, .arg = @ptrCast(&flags) },
		.pt1_before = .{ .func = create_ptab, .arg = @ptrCast(&flags) },
		.pt0_during = .{ .func = create_leaf, .arg = @ptrCast(&pp_and_flags) }
	});

	return @as(*anyopaque, vma);
}

pub fn alloc_and_map_range(vma: u64, size: usize, pp: *anyopaque, flags: PTEFlags) *anyopaque {
	return map_range(vma, size, page.phys_alloc(math.DIV_CEIL(usize, size, page.SIZE)), flags);
}

pub fn unmap_and_free_range(vp: *anyopaque, size: usize) void {
	return pagetable_traverse(@intFromPtr(vp), math.ROUND_UP(usize, size, page.SIZE), &.{
		.pt0_during = .{ .func = delete_leaf, .arg = vp },
		.pt1_after = .{ .func = delete_ptab, .arg = vp },
		.pt2_after = .{ .func = delete_ptab, .arg = vp }
	});
}

pub fn set_range_flags(vp: *anyopaque, size: usize, rwxug_flags: PTEFlags) void {
	return pagetable_traverse(@intFromPtr(vp), math.ROUND_UP(usize, size, page.SIZE), &.{
		.pt2_before = .{ .func = set_ptab_flags, .arg = &rwxug_flags },
		.pt1_before = .{ .func = set_ptab_flags, .arg = &rwxug_flags },
		.pt0_during = .{ .func = set_leaf_flags, .arg = &rwxug_flags }
	});
}

// ---------------
// Page Operations
// ---------------

fn active_ptab() *PTab {
	return @as(*PTab, active_mspace().ppn << 20);
}

/// Helper function for map_range
fn create_ptab(pte: *PTE, rwxug_flags: *anyopaque) void {
	if (pte.* == @as(PTE, 0)) {
		pte.* = .new_ptab(@intFromPtr(page.phys_alloc(1)), rwxug_flags);
	}
}

/// Helper function for map_range
fn create_leaf(pte: *PTE, pp_and_flags: *anyopaque) void {
	const arg: *(struct { pp: *anyopaque, flags: PTEFlags }) = @ptrCast(pp_and_flags);
	assert(pte.* == @as(PTE, 0), "must be allocating an empty leaf");

	pte.* = .new_leaf(@intFromPtr(arg.pp), arg.flags);
	arg.*.pp += page.SIZE;
}

/// Helper function for unmap_and_free_range
fn delete_ptab(pte: *PTE, _: *anyopaque) void {
	if (pte.children() != null and std.mem.allEqual(PTE, pte.children().?, 0))
		page.phys_free(@alignCast(@as([*]u8, pte.children().?)[0..page.SIZE]));
	pte.* = 0;
}

/// Helper function for unmap_and_free_range
fn delete_leaf(pte: *PTE, _: *anyopaque) void {
	if (pte.pp() != null) | pp |
		page.phys_free(@alignCast(@as([*]u8, pp)[0..page.SIZE]));
	pte.* = 0;
}

/// Helper function for set_range_flags.
/// Only sets the global flag.
fn set_ptab_flags(pte: *PTE, rwxug_flags: *anyopaque) void {
	pte.*.flags.global = @as(*PTEFlags, rwxug_flags).global;
}

/// Helper function for set_range_flags.
/// Overrides rwxug flags, but leaves accessed, dirty, valid.
fn set_leaf_flags(pte: *PTE, rwxug_flags: *anyopaque) void {
	pte.flags = .{ .accessed = pte.flags.accessed, .dirty = pte.flags.dirty, .valid = pte.flags.valid, .read = rwxug_flags.read,
	.write = rwxug_flags.write, .exec = rwxug_flags.exec, .user = rwxug_flags.user, .global = rwxug_flags.global };
}
