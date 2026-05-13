const std = @import("std");
const reg = @import("../riscv/reg.zig");
const page = @import("./page.zig");
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

	fn is_leaf(self: *const PTE) bool {
		return self.flags.read or self.flags.write or self.flags.exec;
	}

	fn children(self: *const PTE) ?*PTab {
		if (self.is_leaf() or self.ppn == 0) return null;
		return @ptrFromInt(self.get_pma());
	}

	fn get_pma(self: *const PTE) u64 {
		return @as(u64, self.ppn) << page.ORDER;
	}

	fn get_pp(self: *const PTE) ?*anyopaque {
		return @ptrFromInt(self.get_pma());
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
	AlreadyMapped,
	OOM,
};

/// Macros

inline fn VPN2(vma: usize) usize { return (VPN(vma) >> (2 * 9)) % PTE_CNT; }
inline fn VPN1(vma: usize) usize { return (VPN(vma) >> (1 * 9)) % PTE_CNT; }
inline fn VPN0(vma: usize) usize { return (VPN(vma) >> (0 * 9)) % PTE_CNT; }
inline fn VPN(vma: usize) usize { return vma >> page.ORDER; }

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
		main_pt2[VPN2(pma)] = .new_leaf(pma, .{.global = true, .read = true, .write = true});

	// Beginning of kernel region
	main_pt2[VPN2(config.RAM_START_PMA)] = .new_ptab(@intFromPtr(&main_pt1), true);
	main_pt1[VPN1(config.RAM_START_PMA)] = .new_ptab(@intFromPtr(&main_pt0), true);

	log.debug("text: 0x{X:0>8} -> 0x{X:0>8}", .{@intFromPtr(&_kimg_text_start), @intFromPtr(&_kimg_text_end)});
	pma = @intFromPtr(&_kimg_text_start);
	while (pma < @intFromPtr(&_kimg_text_end)) : (pma += page.SIZE)
		main_pt0[VPN0(pma)] = .new_leaf(pma, .{.global = true, .read = true, .exec = true});

	log.debug("rodata: 0x{X:0>8} -> 0x{X:0>8}", .{@intFromPtr(&_kimg_rodata_start), @intFromPtr(&_kimg_rodata_end)});
	pma = @intFromPtr(&_kimg_rodata_start);
	while (pma < @intFromPtr(&_kimg_rodata_end)) : (pma += page.SIZE)
		main_pt0[VPN0(pma)] = .new_leaf(pma, .{.global = true, .read = true});

	log.debug("data: 0x{X:0>8} -> 0x{X:0>8}", .{@intFromPtr(&_kimg_data_start), @intFromPtr(&_kimg_data_end)});
	pma = @intFromPtr(&_kimg_data_start);
	while (pma < @intFromPtr(&_kimg_data_end)) : (pma += page.SIZE)
		main_pt0[VPN0(pma)] = .new_leaf(pma, .{.global = true, .read = true, .write = true});

	pma = std.mem.alignForward(usize, @intFromPtr(&_kimg_data_end), page.SIZE);
	while (pma < config.RAM_START_PMA + page.MEGA_SIZE) : (pma += page.SIZE)
		main_pt0[VPN0(pma)] = .new_leaf(pma, .{.global = true, .read = true, .write = true});

	// Directly map remaining bits as MEGA pages
	pma = config.RAM_START_PMA + page.MEGA_SIZE;
	while (pma < config.RAM_END_PMA) : (pma += page.MEGA_SIZE)
		main_pt1[VPN1(pma)] = .new_leaf(pma, .{.global = true, .read = true, .write = true});

	// Enable Paging
	log.debug("Gonna enable paging 🫣 🤞", .{});
	main_mtag = to_mtag(to_ppn(@intFromPtr(&main_pt2)), 0);
	_ = reg.csrrw("satp", @bitCast(main_mtag));
	reg.sfence_vma();

	_ = reg.csrrs("sstatus", reg.SSTATUS_SUM);

	log.info("initialized", .{});
	initialized = true;
}

// -----------------------
// Memory Space Management
// -----------------------

pub fn active_mspace() MTAG {
	return @bitCast(reg.csrr("satp"));
}

pub fn switch_mspace(mtag: MTAG) MTAG {
	defer reg.sfence_vma();
	return @bitCast(reg.csrrw("satp", @bitCast(mtag)));
}

pub fn clone_active_mspace() MTAG {
	const old_mspace: MTAG = active_mspace();
	const oldtab2: *PTab = active_ptab();
	const newtab2: *PTab = alloc_ptab();

	for (oldtab2, newtab2) |oldpte2, *newpte2| {

		// Start with baseline
		newpte2.* = oldpte2;

		// If it's global or empty, we're done here
		if (oldpte2.flags.global or oldpte2.ppn == 0)
			continue;

		// TODO: Handle GigaPages
		assert(!oldpte2.is_leaf(), "Incorrect PTE Depth (2)");

		const newtab1: *PTab = alloc_ptab();

		newpte2.ppn = to_ppn(@intFromPtr(newtab1));

		for (oldpte2.children().?, newtab1) | oldpte1, *newpte1| {
			newpte1.* = oldpte1;

			if (oldpte1.flags.global or oldpte1.ppn == 0)
				continue;

			// TODO: Handle MegaPages
			assert(!oldpte1.is_leaf(), "Incorrect PTE Depth (1)");

			const newtab0: *PTab = alloc_ptab();

			newpte1.ppn = to_ppn(@intFromPtr(newtab0));

			for (oldpte1.children().?, newtab0) |oldleaf, *newleaf| {
				newleaf.* = oldleaf;

				if (oldleaf.flags.global or oldleaf.ppn == 0)
					continue;

				assert(oldleaf.is_leaf(), "Incorrect PTE Depth (0)");

				const newpage = page.phys_alloc(1);
				const oldpage: [*]const u8 = @ptrFromInt(oldleaf.get_pma());
				@memcpy(newpage, oldpage[0..page.SIZE]);
				newleaf.ppn = to_ppn(@intFromPtr(newpage.ptr));
			}
		}
	}

	var new_mtag: MTAG = old_mspace;
	new_mtag.ppn = to_ppn(@intFromPtr(newtab2));

	return new_mtag;
}

pub fn reset_active_mspace() void {
	unmap_and_free_range(@ptrFromInt(USER_REGION_START), USER_REGION_END - USER_REGION_START);
	return reg.sfence_vma();
}

pub fn discard_active_mspace() MTAG {
	const old_mspace = active_mspace();
	reset_active_mspace();
	if (old_mspace != main_mtag) {
		_ = switch_mspace(main_mtag);
		free_ptab(@ptrFromInt(to_pma(old_mspace.ppn)));
		return old_mspace;
	}
	return switch_mspace(main_mtag);
}

// ------------------
// Internal Functions
// ------------------

const traversal_func_t: type = *const fn (*PTE, *anyopaque) Error!void;
const traversal_pair: type = struct {
	func: traversal_func_t,
	arg: *anyopaque
};
const map_arg: type = struct {
	pp: *anyopaque,
	flags: PTEFlags,
};
const traversal_funcs: type = struct {
	p2_before: ?traversal_pair = null,
	p1_before: ?traversal_pair = null,
	p0_during: ?traversal_pair = null,
	p1_after: ?traversal_pair = null,
	p2_after: ?traversal_pair = null,
};

fn pagetable_traverse(vma: u64, size: usize, funcs: *const traversal_funcs) Error!void {
	const ptab2 = active_ptab();
	const last_vma = vma + size - 1;


	var cur_vma = vma;
	while (cur_vma <= last_vma) : (cur_vma += page.SIZE) {
		const idx2 = VPN2(cur_vma);
		const pte2: *PTE = &ptab2[idx2];

		if (funcs.p2_before) | p2b | {
			try p2b.func(pte2, p2b.arg);
		}

		const ptab1 = ptab2[idx2].children() orelse continue;

		const pte1: *PTE = &ptab1[VPN1(cur_vma)];

		if (funcs.p1_before) | p1b | {
			try p1b.func(pte1, p1b.arg);
		}

		const ptab0 = pte1.children() orelse continue;

		if (funcs.p0_during) |leaf| {
			try leaf.func(&ptab0[VPN0(cur_vma)], leaf.arg);
		}

		if (funcs.p1_after) | p1a | {
			try p1a.func(pte1, p1a.arg);
		}
		if (funcs.p2_after) | p2a | {
			try p2a.func(pte2, p2a.arg);
		}
	}

	return reg.sfence_vma();
}

// ------------------------
// Direct VMEM Modification
// ------------------------

pub fn map_range(vma: u64, size: usize, pp: *anyopaque, flags: PTEFlags) Error!*anyopaque {
	assert(vma % page.SIZE == 0, "vma must be page aligned");
	try validate_vma_range(vma, size);
	try validate_pma_range(@as(u64, @intFromPtr(pp)), size);

	var ptab_flags = flags;
	var pp_and_flags: map_arg = .{ .pp = pp, .flags = flags };

	try pagetable_traverse(vma, size, &.{
		.p2_before = .{ .func = create_ptab, .arg = @ptrCast(&ptab_flags) },
		.p1_before = .{ .func = create_ptab, .arg = @ptrCast(&ptab_flags) },
		.p0_during = .{ .func = create_leaf, .arg = @ptrCast(&pp_and_flags) }
	});

	return @ptrFromInt(vma);
}

pub fn alloc_and_map_range(vma: u64, size: usize, flags: PTEFlags) Error!*anyopaque {
	try validate_vma_range(vma, size);
	const pages = page.phys_alloc(math.DIV_CEIL(usize, size, page.SIZE));
	errdefer page.phys_free(pages);
	return map_range(vma, size, pages.ptr, flags);
}

pub fn unmap_and_free_range(vp: *anyopaque, size: usize) void {
	return pagetable_traverse(@intFromPtr(vp), math.ROUND_UP(usize, size, page.SIZE), &.{
		.p0_during = .{ .func = delete_leaf, .arg = vp },
		.p1_after = .{ .func = delete_ptab, .arg = vp },
		.p2_after = .{ .func = delete_ptab, .arg = vp }
	}) catch unreachable;
}

pub fn set_range_flags(vp: *anyopaque, size: usize, rwxug_flags: PTEFlags) Error!void {
	var flags = rwxug_flags;
	return pagetable_traverse(@intFromPtr(vp), math.ROUND_UP(usize, size, page.SIZE), &.{
		.p2_before = .{ .func = set_ptab_flags, .arg = @ptrCast(&flags) },
		.p1_before = .{ .func = set_ptab_flags, .arg = @ptrCast(&flags) },
		.p0_during = .{ .func = set_leaf_flags, .arg = @ptrCast(&flags) }
	});
}

// ----------------
// Helper Functions
// ----------------

fn validate_vma(vma: u64) Error!void {
	if (vma < USER_REGION_START or vma >= USER_REGION_END or vma % page.SIZE != 0)
		return Error.InvalidVMA;
}

fn validate_vma_range(vma: u64, size: usize) Error!void {
	if (size == 0) return Error.InvalidVMA;
	try validate_vma(vma);
	if (vma + size - 1 >= USER_REGION_END)
		return Error.InvalidVMA;
}

fn validate_pma(pma: u64) Error!void {
	if (pma < config.RAM_START_PMA or pma >= config.RAM_END_PMA or pma % page.SIZE != 0)
		return Error.InvalidPMA;
}

fn validate_pma_range(pma: u64, size: usize) Error!void {
	if (size == 0) return Error.InvalidPMA;
	try validate_pma(pma);
	if (pma + size - 1 >= config.RAM_END_PMA)
		return Error.InvalidPMA;
}

fn active_ptab() *PTab {
	return @ptrFromInt(@as(usize, active_mspace().ppn) << page.ORDER);
}

fn alloc_ptab() *PTab {
	return @ptrCast(page.phys_alloc(1).ptr);
}

fn free_ptab(ptab: *PTab) void {
	page.phys_free(@alignCast(@as([*]u8, @ptrCast(ptab))[0..page.SIZE]));
}

/// Helper function for map_range
fn create_ptab(pte: *PTE, rwxug_flags: *anyopaque) Error!void {
	if (pte.* == @as(PTE, .{})) {
		const flags: *PTEFlags = @alignCast(@ptrCast(rwxug_flags));
		pte.* = .new_ptab(@intFromPtr(page.phys_alloc(1).ptr), flags.global);
	}
}

/// Helper function for map_range
fn create_leaf(pte: *PTE, pp_and_flags: *anyopaque) Error!void {
	const arg: *map_arg = @alignCast(@ptrCast(pp_and_flags));
	if (pte.* != @as(PTE, .{}))
		return Error.AlreadyMapped;

	pte.* = .new_leaf(@intFromPtr(arg.pp), arg.flags);
	arg.*.pp = @ptrFromInt(@intFromPtr(arg.pp) + page.SIZE);
}

/// Helper function for unmap_and_free_range
fn delete_ptab(pte: *PTE, _: *anyopaque) Error!void {
	if (pte.children()) |children| {
		if (std.mem.allEqual(PTE, children, .{})) {
			free_ptab(children);
			pte.* = .{};
		}
	}
}

/// Helper function for unmap_and_free_range
fn delete_leaf(pte: *PTE, _: *anyopaque) Error!void {
	if (pte.get_pp()) | pp |
		page.phys_free(@alignCast(@as([*]u8, @ptrCast(pp))[0..page.SIZE]));
	pte.* = .{};
}

/// Helper function for set_range_flags.
/// Only sets the global flag.
fn set_ptab_flags(pte: *PTE, rwxug_flags: *anyopaque) Error!void {
	const flags: *PTEFlags = @alignCast(@ptrCast(rwxug_flags));
	pte.*.flags.global = flags.global;
}

/// Helper function for set_range_flags.
/// Overrides rwxug flags, but leaves accessed, dirty, valid.
fn set_leaf_flags(pte: *PTE, rwxug_flags: *anyopaque) Error!void {
	const flags: *PTEFlags = @alignCast(@ptrCast(rwxug_flags));
	pte.flags = .{ .accessed = pte.flags.accessed, .dirty = pte.flags.dirty, .valid = pte.flags.valid, .read = flags.read,
	.write = flags.write, .exec = flags.exec, .user = flags.user, .global = flags.global };
}
