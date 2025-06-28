const std = @import("std");
const page = @import("./page.zig");

extern const _kimg_end: usize;

const init_min = 256;

pub const start = _kimg_end;
// Round up to page size
pub const end = page.round_up(start + init_min);
pub const buffer: []u8 = @as([*]u8, @ptrFromInt(start))[0..(end-start)];

var gpa = std.heap.GeneralPurposeAllocator(.{
    .enable_memory_limit = true,
    .page_size = page.SIZE,
    .backing_allocator_zeroes = true,
}){
    .backing_allocator = page.allocator,
};

pub const allocator = gpa.allocator();
