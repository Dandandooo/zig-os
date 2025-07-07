const std = @import("std");
const page = @import("./page.zig");

extern const _kimg_end: usize;

const init_min = 256 + 2 * page.SIZE;

pub const start: usize = undefined;
pub const end: usize = undefined;
pub const buffer: []u8 = undefined;

var initial_heap: std.heap.FixedBufferAllocator = undefined;
pub const initial_allocator: std.mem.Allocator = undefined;

pub var initialized: bool = false;
pub fn init() void {

    start = _kimg_end;
    end = std.mem.alignForward(usize, start + init_min, page.SIZE);
    buffer = @as([*]u8, @ptrFromInt(start))[0..(end-start)];

    initial_heap = .{.buffer = buffer};
    initial_allocator = initial_heap.allocator();
    initialized = true;
}

// var gpa = std.heap.GeneralPurposeAllocator(.{
//     .enable_memory_limit = true,
//     .page_size = page.SIZE,
//     .backing_allocator_zeroes = true,
// }){
//     .backing_allocator = page.allocator,
// };



// pub const allocator = gpa.allocator();

pub const allocator = page.allocator;

// Custom Heap Allocator
//

// Idea:
// 1. LinkedList kind

const chunk = packed struct {
    next: u16,
    data: []u8,

};
