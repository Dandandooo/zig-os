const util = @import("../util.zig");
const page = @import("../../mem/page.zig");

pub fn run() util.test_results {
    return util.run_tests("PAGE", &.{
        .{ .name = "Page rounding", .func = pageRounding },
        .{ .name = "Allocated pages are zeroed", .func = allocatedPagesAreZeroed },
        .{ .name = "Allocate all pages", .func = allocateAll },
        .{ .name = "Page coalescing", .func = coalescing },
        .{ .name = "Middle free coalescing", .func = middleFreeCoalescing },
        .{ .name = "Allocator interface", .func = allocatorInterface },
        .{ .name = "Alignment and overlap", .func = alignmentAndOverlap },
    });
}

/// page.allocator implements std.mem.Allocator on whole pages: odd sizes
/// round up and freeing returns every page. (No zeroing guarantee here —
/// the std interface poisons fresh memory with undefined in Debug builds.)
fn allocatorInterface() anyerror!void {
    const orig = page.free_page_cnt();

    const small = try page.allocator.alloc(u8, 100);
    try util.expect(page.free_page_cnt() == orig - 1);
    small[0] = 0xAB;
    small[99] = 0xBA;
    page.allocator.free(small);
    try util.expect(page.free_page_cnt() == orig);

    const big = try page.allocator.alloc(u8, page.SIZE + 1);
    try util.expect(page.free_page_cnt() == orig - 2);
    big[0] = 0xCD;
    big[page.SIZE] = 0xDC;
    page.allocator.free(big);
    try util.expect(page.free_page_cnt() == orig);
}

fn alignmentAndOverlap() anyerror!void {
    const orig = page.free_page_cnt();

    const one = page.phys_alloc(1);
    const three = page.phys_alloc(3);

    try util.expect(@intFromPtr(one.ptr) % page.SIZE == 0);
    try util.expect(@intFromPtr(three.ptr) % page.SIZE == 0);
    try util.expect(one.len == page.SIZE);
    try util.expect(three.len == 3 * page.SIZE);

    const one_end = @intFromPtr(one.ptr) + one.len;
    const three_end = @intFromPtr(three.ptr) + three.len;
    try util.expect(one_end <= @intFromPtr(three.ptr) or three_end <= @intFromPtr(one.ptr));

    page.phys_free(three);
    page.phys_free(one);
    try util.expect(page.free_page_cnt() == orig);
}

fn pageRounding() anyerror!void {
    try util.expect(page.round_down(0) == 0);
    try util.expect(page.round_up(0) == 0);
    try util.expect(page.round_down(page.SIZE - 1) == 0);
    try util.expect(page.round_up(page.SIZE - 1) == page.SIZE);
    try util.expect(page.round_down(page.SIZE + 1) == page.SIZE);
    try util.expect(page.round_up(page.SIZE + 1) == 2 * page.SIZE);
}

fn allocatedPagesAreZeroed() anyerror!void {
    const pp = page.phys_alloc(2);

    pp[0] = 0xAA;
    pp[page.SIZE] = 0xBB;
    pp[2 * page.SIZE - 1] = 0xCC;
    page.phys_free(pp);

    const pp2 = page.phys_alloc(2);
    defer page.phys_free(pp2);

    try util.expect(pp2[0] == 0);
    try util.expect(pp2[page.SIZE] == 0);
    try util.expect(pp2[2 * page.SIZE - 1] == 0);
}

fn allocateAll() anyerror!void {
    const orig = page.free_page_cnt();
    try util.expect(page.free_chunk_cnt() == 1);

    const pp = page.phys_alloc(orig);

    try util.expect(page.free_page_cnt() == 0);
    try util.expect(page.free_chunk_cnt() == 0);

    page.phys_free(pp);

    try util.expect(page.free_page_cnt() == orig);
    try util.expect(page.free_chunk_cnt() == 1);
}

fn middleFreeCoalescing() anyerror!void {
    const orig = page.free_page_cnt();
    try util.expect(page.free_chunk_cnt() == 1);

    const pp0 = page.phys_alloc(1);
    const pp1 = page.phys_alloc(1);
    const pp2 = page.phys_alloc(1);

    try util.expect(page.free_page_cnt() + 3 == orig);
    try util.expect(page.free_chunk_cnt() == 1);

    page.phys_free(pp1);
    try util.expect(page.free_page_cnt() + 2 == orig);
    try util.expect(page.free_chunk_cnt() == 2);

    page.phys_free(pp0);
    try util.expect(page.free_page_cnt() + 1 == orig);
    try util.expect(page.free_chunk_cnt() == 2);

    page.phys_free(pp2);
    try util.expect(page.free_page_cnt() == orig);
    try util.expect(page.free_chunk_cnt() == 1);
}

fn coalescing() anyerror!void {
    const orig = page.free_page_cnt();
    const num = 100;
    var pps: [num]page.ty = undefined;

    for (0..num) |i|
        pps[i] = page.phys_alloc(1);

    try util.expect(page.free_page_cnt() + num == orig);
    try util.expect(page.free_chunk_cnt() == 1);

    for (0..num) |i|
        page.phys_free(pps[(7 * i) % num]);

    try util.expect(page.free_page_cnt() == orig);
    try util.expect(page.free_chunk_cnt() == 1);
}
