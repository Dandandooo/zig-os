const std = @import("std");
const page = @import("./page.zig");

extern const _kimg_end: usize;

const heap_init_min = 256;

pub const heap_start = _kimg_end;
// Round up to page size
pub const heap_end = page.round_up(heap_start + heap_init_min);

var gpa = std.heap.GeneralPurposeAllocator(.{
    .enable_memory_limit = true,
    .page_size = page.size,
    .backing_allocator_zeroes = true,
}){
    .backing_allocator = page.allocator,
};

pub const allocator = gpa.allocator();
