const std = @import("std");
const heap = @import("./heap.zig");
const assert = std.debug.assert;
const config = @import("../config.zig");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const start: usize = heap.end;
pub const end: usize = config.RAM_END_VMA;
comptime {assert((end - start) % SIZE == 0);}

pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .remap = Allocator.noRemap,
        .resize = Allocator.noResize,
        .free = free,
    }
};

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    assert(alignment.toByteUnits() <= SIZE);
    const cnt = std.mem.alignForward(usize, len, SIZE) / SIZE;
    return @ptrCast(alloc_phys_pages(cnt));
}

fn free(_: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    assert(alignment.toByteUnits() <= SIZE);
    const cnt = std.mem.alignForward(usize, memory.len, SIZE) / SIZE;
    free_phys_pages(@alignCast(@ptrCast(memory.ptr)), cnt);
}

const DLL = @import("../util/list.zig").DLL;

pub const ORDER = 12;
pub const SIZE = 1 << ORDER;
pub const MEGA_SIZE = SIZE << 9;
pub const GIGA_SIZE = MEGA_SIZE << 9;

pub fn round_down(comptime n: comptime_int) comptime_int
{ comptime return (n / SIZE) * SIZE; }

pub fn round_up(comptime n: comptime_int) comptime_int
{ comptime return round_down(n + SIZE - 1); }

// Embedded DLL Storing
var free_chunk_list = DLL(chunk){};
const chunk align(SIZE) = struct {
    cnt: usize,
    next: ?*chunk = null,
    prev: ?*chunk = null,
};

pub fn init() void {
    const begin: *chunk = @ptrFromInt(start);
    begin.* = chunk{ .cnt = (end - start) >> ORDER};
    free_chunk_list.insert_back(begin);
}

// Coalescing Page Allocator
pub fn alloc_phys_page() *align(SIZE) [SIZE]u8 { return alloc_phys_pages(1); }
pub fn alloc_phys_pages(cnt: usize) [*]align(SIZE) [SIZE]u8 {
    var shortest_size: usize = 0;
    var total_free: usize = 0;

    var shortest: ?*chunk = null;

    var free_iter = free_chunk_list.iter();
    while (free_iter.next()) |node| {
        const free_node = node.*.data;

        total_free += free_node;
        if (shortest_size > free_node) {
            shortest_size = free_node;
            if (free_node >= cnt) shortest = node;
            if (free_node == cnt) break; // cut early
        }
    }

    const shorty = shortest orelse @panic("OOM");

    assert(cnt <= shorty.data);

    if (shortest_size == cnt) {
        defer _ = free_chunk_list.pop(shorty);
        return @alignCast(@ptrCast(shorty));
    }
    const new_shorty: *chunk = shorty + (shorty.data - cnt) * SIZE;
    defer @memset(new_shorty, 0);
    return @ptrCast(new_shorty);
}

pub fn free_phys_page(page: *align(SIZE) [SIZE]u8) void { free_phys_pages(@ptrCast(page), 1); }
pub fn free_phys_pages(pages: [*]align(SIZE) [SIZE]u8, cnt: usize) void {
    const pma: usize = @intFromPtr(pages);
    assert(pma % SIZE == 0);

    var free_iter = free_chunk_list.iter();
    const next_node: ?*chunk = while (free_iter.next()) |node| {
        if (@intFromPtr(node) > pma) break node;
    } else null;
    const prev_node: ?*chunk = if (next_node) |next| next.*.prev else free_chunk_list.tail;
    var new_node: ?*chunk = undefined;

    if (prev_node) |prev|{
        if (@intFromPtr(prev) + (prev.data << ORDER) == pma) {
            prev.*.data += cnt; // merge new free block with previous
            new_node = prev;
        } else {
            new_node = @alignCast(@ptrCast(pages));
            pages.* = chunk{ .data = cnt, .prev = prev, .next = next_node };
            prev.*.next = new_node;
        }
    }

    if (next_node) |next| {
        next.*.prev = new_node;
        if (@intFromPtr(next) == pma + (cnt << ORDER)) { // coalesce
            new_node.*.data += next.*.data;
            _ = free_chunk_list.pop(next);
        }
    } else {
        free_chunk_list.tail = new_node;
    }
}

pub fn free_page_cnt() usize {
    var sum: usize = 0;
    var cur = free_chunk_list.head;
    while (cur) |node| : (cur = node.*.next) {
        sum += node.*.cnt;
    }
    return sum;
}

pub fn free_chunk_cnt() usize {
    var cnt = 0;
    var cur = free_chunk_list.head;
    while (cur) |node| : (cur = node.*.next) {
        cnt += 1;
    }
    return cnt;
}

// TESTING
const expect = std.testing.expect;
test "allocate all at once" {
    const orig = free_page_cnt();
    try expect(free_chunk_cnt() == 1);

    const pp = alloc_phys_pages(orig);

    try expect(free_page_cnt() == 0);
    try expect(free_chunk_cnt() == 0);

    free_phys_pages(pp, orig);

    try expect(free_page_cnt() == orig);
    try expect(free_chunk_cnt() == 1);
}

test "coalescing" {
    const orig = free_page_cnt();
    const num = 100;
    const pps: [num]*anyopaque = undefined;

    for (0..num) |i|
        pps[i] = alloc_phys_page();

    try expect(free_page_cnt() + num == orig);
    try expect(free_chunk_cnt() == 1);

    for (0..num) |i|
        free_phys_page(pps[(7 * i) % num]);

    try expect(free_page_cnt() == orig);
    try expect(free_chunk_cnt() == 1);
}
