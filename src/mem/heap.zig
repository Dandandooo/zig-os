const std = @import("std");
const page = @import("./page.zig");
const log = std.log.scoped(.HEAP);

extern const _kimg_end: anyopaque;

const init_min = 256 + 2 * page.SIZE;

pub var start: usize = undefined;
pub var end: usize = undefined;
pub var buffer: []u8 = undefined;

var initial_heap: std.heap.FixedBufferAllocator = undefined;
pub const initial_allocator: std.mem.Allocator = undefined;

pub var initialized: bool = false;
pub fn init() void {

    start = @intFromPtr(&_kimg_end);
    end = std.mem.alignForward(usize, start + init_min, page.SIZE);
    log.debug("heap end: 0x{X}", .{start});
    buffer = @as([*]u8, @ptrFromInt(start))[0..(end-start)];


    initialized = true;
    page.init();

    // initial_heap = .{.buffer = buffer};
    // initial_allocator = initial_heap.allocator();
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
