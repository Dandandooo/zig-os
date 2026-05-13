const config = @import("../../config.zig");
const page = @import("../../mem/page.zig");
const vmem = @import("../../mem/vmem.zig");
const util = @import("../util.zig");

const rw_user: vmem.PTEFlags = .{ .read = true, .write = true, .user = true };

const base_single = vmem.USER_REGION_START + 0x0010_0000;
const base_multi = vmem.USER_REGION_START + 0x0020_0000;
const base_partial = vmem.USER_REGION_START + 0x0030_0000;
const base_flags = vmem.USER_REGION_START + 0x0040_0000;
const base_invalid = vmem.USER_REGION_START + 0x0050_0000;
const base_odd = vmem.USER_REGION_START + 0x0060_0000;
const base_sparse = vmem.USER_REGION_START + 0x0070_0000;
const base_clone = vmem.USER_REGION_START + 0x0080_0000;
const base_clone_extra = vmem.USER_REGION_START + 0x0090_0000;
const base_double = vmem.USER_REGION_START + 0x00A0_0000;
const base_flag_multi = vmem.USER_REGION_START + 0x00B0_0000;
const base_cross_mega = vmem.USER_REGION_START + page.MEGA_SIZE - page.SIZE;

pub fn run() util.test_results {
    return util.run_tests("VMEM", &.{
        .{ .name = "Reject invalid ranges", .func = rejectInvalidRanges },
        .{ .name = "Boundary range validation", .func = boundaryRangeValidation },
        .{ .name = "Reject duplicate mapping", .func = rejectDuplicateMapping },
        .{ .name = "Map aliases physical page", .func = mapAliasesPhysicalPage },
        .{ .name = "Allocate and reset pages", .func = allocateAndResetPages },
        .{ .name = "Odd-sized mappings round up", .func = oddSizedMappingsRoundUp },
        .{ .name = "Cross mega boundary", .func = crossMegaBoundary },
        .{ .name = "Sparse mappings reset", .func = sparseMappingsReset },
        .{ .name = "Partial unmap keeps siblings", .func = partialUnmapKeepsSiblings },
        .{ .name = "Update mapped range flags", .func = updateMappedRangeFlags },
        .{ .name = "Update partial range flags", .func = updatePartialRangeFlags },
        .{ .name = "Clone isolates writes", .func = cloneIsolatesWrites },
        .{ .name = "Discard clone frees pages", .func = discardCloneFreesPages },
    });
}

fn rejectInvalidRanges() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();

    try util.expectError(error.InvalidVMA, vmem.alloc_and_map_range(vmem.USER_REGION_START - page.SIZE, page.SIZE, rw_user));
    try util.expect(page.free_page_cnt() == orig_count);

    const phys = page.phys_alloc(1);
    var phys_freed = false;
    errdefer if (!phys_freed) page.phys_free(phys);

    try util.expectError(error.InvalidVMA, vmem.map_range(vmem.USER_REGION_END, page.SIZE, phys.ptr, rw_user));
    try util.expectError(error.InvalidPMA, vmem.map_range(base_invalid, page.SIZE, @ptrFromInt(config.RAM_START_PMA + 1), rw_user));

    page.phys_free(phys);
    phys_freed = true;

    try util.expect(page.free_page_cnt() == orig_count);
}

fn boundaryRangeValidation() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();

    const first_any = try vmem.alloc_and_map_range(vmem.USER_REGION_START, page.SIZE, rw_user);
    const last_any = try vmem.alloc_and_map_range(vmem.USER_REGION_END - page.SIZE, page.SIZE, rw_user);

    const first: [*]u8 = @ptrCast(first_any);
    const last: [*]u8 = @ptrCast(last_any);
    first[0] = 0x01;
    last[page.SIZE - 1] = 0xFE;

    if (first[0] != 0x01) return error.BadFirstBoundary;
    if (last[page.SIZE - 1] != 0xFE) return error.BadLastBoundary;

    vmem.reset_active_mspace();
    if (page.free_page_cnt() != orig_count) return error.LeakedBoundaryPages;

    try util.expectError(error.InvalidVMA, vmem.alloc_and_map_range(vmem.USER_REGION_END - page.SIZE, 2 * page.SIZE, rw_user));
    try util.expectError(error.InvalidVMA, vmem.alloc_and_map_range(vmem.USER_REGION_START, 0, rw_user));
    try util.expect(page.free_page_cnt() == orig_count);
}

fn rejectDuplicateMapping() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();
    var first_phys = page.phys_alloc(1);
    var second_phys = page.phys_alloc(1);
    var mapped = false;
    errdefer if (!mapped) page.phys_free(first_phys);
    defer page.phys_free(second_phys);

    first_phys[0] = 0x1A;
    second_phys[0] = 0x2B;

    const vp_any = try vmem.map_range(base_double, page.SIZE, first_phys.ptr, rw_user);
    mapped = true;

    try util.expectError(error.AlreadyMapped, vmem.map_range(base_double, page.SIZE, second_phys.ptr, rw_user));

    const vp: [*]u8 = @ptrCast(vp_any);
    if (vp[0] != 0x1A) return error.DuplicateReplacedMapping;

    vmem.reset_active_mspace();
    if (page.free_page_cnt() != orig_count - 1) return error.BadDuplicateFreeCount;
}

fn mapAliasesPhysicalPage() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();
    var phys = page.phys_alloc(1);
    var mapped = false;
    errdefer if (!mapped) page.phys_free(phys);
    errdefer if (mapped) vmem.reset_active_mspace();

    phys[0] = 0xA5;
    phys[page.SIZE - 1] = 0x5A;

    const vp_any = try vmem.map_range(base_single, page.SIZE, phys.ptr, rw_user);
    mapped = true;

    const vp: [*]u8 = @ptrCast(vp_any);
    if (vp[0] != 0xA5) return error.BadFirstAlias;
    if (vp[page.SIZE - 1] != 0x5A) return error.BadLastAlias;

    vp[1] = 0x3C;
    vp[page.SIZE - 2] = 0xC3;
    if (phys[1] != 0x3C) return error.BadFirstWriteback;
    if (phys[page.SIZE - 2] != 0xC3) return error.BadLastWriteback;

    vmem.reset_active_mspace();
    if (page.free_page_cnt() != orig_count) return error.LeakedAliasPages;
}

fn allocateAndResetPages() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();

    const vp_any = try vmem.alloc_and_map_range(base_multi, 3 * page.SIZE, rw_user);
    const vp: [*]u8 = @ptrCast(vp_any);

    if (page.free_page_cnt() != orig_count - 5) return error.BadMultiAllocCount;

    vp[0] = 0x10;
    vp[page.SIZE] = 0x20;
    vp[2 * page.SIZE] = 0x30;

    if (vp[0] != 0x10) return error.BadFirstPage;
    if (vp[page.SIZE] != 0x20) return error.BadSecondPage;
    if (vp[2 * page.SIZE] != 0x30) return error.BadThirdPage;

    vmem.reset_active_mspace();
    if (page.free_page_cnt() != orig_count) return error.LeakedMultiPages;
}

fn oddSizedMappingsRoundUp() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();

    const one_any = try vmem.alloc_and_map_range(base_odd, 1, rw_user);
    const two_any = try vmem.alloc_and_map_range(base_odd + 2 * page.SIZE, page.SIZE + 1, rw_user);

    if (page.free_page_cnt() != orig_count - 5) return error.BadOddAllocCount;

    const one: [*]u8 = @ptrCast(one_any);
    const two: [*]u8 = @ptrCast(two_any);

    one[0] = 0x81;
    one[page.SIZE - 1] = 0x82;
    two[0] = 0x83;
    two[page.SIZE] = 0x84;

    if (one[0] != 0x81 or one[page.SIZE - 1] != 0x82) return error.BadOneByteMapping;
    if (two[0] != 0x83 or two[page.SIZE] != 0x84) return error.BadPlusOneMapping;

    vmem.unmap_and_free_range(one_any, 1);
    if (page.free_page_cnt() != orig_count - 4) return error.BadOddPartialFreeCount;

    vmem.reset_active_mspace();
    if (page.free_page_cnt() != orig_count) return error.LeakedOddPages;
}

fn crossMegaBoundary() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();

    const vp_any = try vmem.alloc_and_map_range(base_cross_mega, 2 * page.SIZE, rw_user);
    const vp: [*]u8 = @ptrCast(vp_any);

    vp[0] = 0x91;
    vp[page.SIZE] = 0x92;

    if (vp[0] != 0x91) return error.BadCrossFirstPage;
    if (vp[page.SIZE] != 0x92) return error.BadCrossSecondPage;

    vmem.reset_active_mspace();
    if (page.free_page_cnt() != orig_count) return error.LeakedCrossPages;
}

fn sparseMappingsReset() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();

    const first_any = try vmem.alloc_and_map_range(base_sparse, page.SIZE, rw_user);
    const far_any = try vmem.alloc_and_map_range(base_sparse + 1000 * page.SIZE, page.SIZE, rw_user);

    const first: [*]u8 = @ptrCast(first_any);
    const far: [*]u8 = @ptrCast(far_any);
    first[0] = 0xA1;
    far[0] = 0xA2;

    if (first[0] != 0xA1 or far[0] != 0xA2) return error.BadSparseMapping;

    vmem.reset_active_mspace();
    if (page.free_page_cnt() != orig_count) return error.LeakedSparsePages;
}

fn partialUnmapKeepsSiblings() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();

    const vp_any = try vmem.alloc_and_map_range(base_partial, 2 * page.SIZE, rw_user);
    const vp: [*]u8 = @ptrCast(vp_any);
    const mapped_count = page.free_page_cnt();

    vp[0] = 0x11;
    vp[page.SIZE] = 0x22;

    vmem.unmap_and_free_range(vp_any, page.SIZE);
    if (page.free_page_cnt() != mapped_count + 1) return error.BadPartialFreeCount;

    if (vp[page.SIZE] != 0x22) return error.BadSiblingRead;
    vp[page.SIZE] = 0x33;
    if (vp[page.SIZE] != 0x33) return error.BadSiblingWrite;

    vmem.unmap_and_free_range(@ptrFromInt(base_partial + page.SIZE), page.SIZE);
    if (page.free_page_cnt() != orig_count) return error.LeakedPartialPages;
}

fn updateMappedRangeFlags() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();
    var phys = page.phys_alloc(1);
    var mapped = false;
    errdefer if (!mapped) page.phys_free(phys);
    errdefer if (mapped) vmem.reset_active_mspace();

    phys[0] = 0x44;

    const vp_any = try vmem.map_range(base_flags, page.SIZE, phys.ptr, .{ .read = true });
    mapped = true;

    const vp: [*]u8 = @ptrCast(vp_any);
    if (vp[0] != 0x44) return error.BadReadonlyMapping;

    try vmem.set_range_flags(vp_any, page.SIZE, rw_user);

    vp[0] = 0x55;
    if (phys[0] != 0x55) return error.BadFlagWriteback;

    vmem.reset_active_mspace();
    if (page.free_page_cnt() != orig_count) return error.LeakedFlagPages;
}

fn updatePartialRangeFlags() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();

    const vp_any = try vmem.alloc_and_map_range(base_flag_multi, 3 * page.SIZE, .{ .read = true, .user = true });
    const vp: [*]u8 = @ptrCast(vp_any);

    try vmem.set_range_flags(@ptrFromInt(base_flag_multi + page.SIZE), page.SIZE, rw_user);

    vp[page.SIZE] = 0xB2;
    if (vp[page.SIZE] != 0xB2) return error.BadPartialFlagWrite;

    vmem.reset_active_mspace();
    if (page.free_page_cnt() != orig_count) return error.LeakedPartialFlagPages;
}

fn cloneIsolatesWrites() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();
    const main_mspace = vmem.active_mspace();

    const vp_any = try vmem.alloc_and_map_range(base_clone, page.SIZE, rw_user);
    const main_vp: [*]u8 = @ptrCast(vp_any);
    main_vp[0] = 0x12;
    main_vp[page.SIZE - 1] = 0x21;

    const clone_mspace = vmem.clone_active_mspace();

    _ = vmem.switch_mspace(clone_mspace);
    const clone_vp: [*]u8 = @ptrFromInt(base_clone);
    if (clone_vp[0] != 0x12) return error.BadCloneFirstCopy;
    if (clone_vp[page.SIZE - 1] != 0x21) return error.BadCloneLastCopy;
    clone_vp[0] = 0x34;
    clone_vp[page.SIZE - 1] = 0x43;

    _ = vmem.switch_mspace(main_mspace);
    if (main_vp[0] != 0x12) return error.CloneWriteTouchedMainFirst;
    if (main_vp[page.SIZE - 1] != 0x21) return error.CloneWriteTouchedMainLast;
    main_vp[0] = 0x56;

    _ = vmem.switch_mspace(clone_mspace);
    if (clone_vp[0] != 0x34) return error.MainWriteTouchedClone;

    _ = vmem.discard_active_mspace();
    if (main_vp[0] != 0x56) return error.DiscardDidNotReturnMain;

    vmem.reset_active_mspace();
    if (page.free_page_cnt() != orig_count) return error.LeakedClonePages;
}

fn discardCloneFreesPages() anyerror!void {
    vmem.reset_active_mspace();
    defer vmem.reset_active_mspace();

    const orig_count = page.free_page_cnt();
    const main_mspace = vmem.active_mspace();

    const main_any = try vmem.alloc_and_map_range(base_clone, page.SIZE, rw_user);
    const main_vp: [*]u8 = @ptrCast(main_any);
    main_vp[0] = 0xC1;

    const clone_mspace = vmem.clone_active_mspace();
    _ = vmem.switch_mspace(clone_mspace);

    const extra_any = try vmem.alloc_and_map_range(base_clone_extra, 2 * page.SIZE, rw_user);
    const extra_vp: [*]u8 = @ptrCast(extra_any);
    extra_vp[0] = 0xC2;
    extra_vp[page.SIZE] = 0xC3;

    _ = vmem.discard_active_mspace();
    if (vmem.active_mspace() != main_mspace) return error.DiscardWrongMspace;
    if (main_vp[0] != 0xC1) return error.DiscardCorruptedMain;

    vmem.reset_active_mspace();
    if (page.free_page_cnt() != orig_count) return error.LeakedDiscardPages;
}
