const util = @import("../util.zig");
const page = @import("../../mem/page.zig");


pub fn run() util.test_results {
    return util.run_tests("PAGE", &.{
        .{.name = "Allocate all pages", .func = allocateAll},
        .{.name = "Page coalescing", .func = coalescing}
    });
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
