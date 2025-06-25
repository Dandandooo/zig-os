const std = @import("std");
const heap = @import("./heap.zig");
const assert = std.debug.assert;

const DLL = @import("../util/list.zig").DLL;

pub const size = 4096;
pub const mega_size = size * 1024;
pub const giga_size = mega_size * 1024;

pub fn round_down(comptime n: comptime_int) comptime_int
{ comptime return (n / size) * size; }

pub fn round_up(comptime n: comptime_int) comptime_int
{ comptime return round_down(n + size - 1); }

// Embedded DLL Storing
var free_chunk_list = DLL(usize){ .allocator = null };
const chunk: type = free_chunk_list.node;

// Coalescing Page Allocator
pub fn alloc_phys_page() *anyopaque { return alloc_phys_pages(1); }
pub fn alloc_phys_pages(cnt: usize) *anyopaque {
    var shortest_size: usize = 0;
    var total_free: usize = 0;

    var shorty: ?*chunk = null;

    const free_iter = free_chunk_list.iter();
    while (free_iter.next()) |node| {
        const free = node.*.data;

        total_free += free;
        if (shortest_size > free) {
            shortest_size = free;
            shorty = node;

            if (free == cnt) break; // cut early
        }
    }

    if (shorty == null) @panic("OOM");

    assert(cnt <= shorty.?.data);

    // TODO


}

pub fn free_phys_page(pp: *anyopaque) void { free_phys_pages(pp, 1); }
pub fn free_phys_pages(pp: *anyopaque, cnt: usize) void {

}
