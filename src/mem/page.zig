const std = @import("std");
const heap = @import("./heap.zig");
const wait = @import("../conc/wait.zig");
const assert = std.debug.assert;
const config = @import("../config.zig");

pub const start: usize = undefined;
pub const end: usize = undefined;

const DLL = @import("../util/list.zig").DLL;

pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = allocator_alloc,
        .remap = std.mem.Allocator.noRemap,
        .resize = std.mem.Allocator.noResize,
        .free = allocator_free
    }
};

fn allocator_alloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    return @ptrCast(phys_alloc(round_up(len) / SIZE));
}

fn allocator_free(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    phys_free(@alignCast(@as([*]u8, memory.ptr)[0..round_up(memory.len)]));
}

pub fn round_up(len: usize) usize { return std.mem.alignForward(usize, len, SIZE); }
pub fn round_down(len: usize) usize { return std.mem.alignBackward(usize, len, SIZE); }

// Physical Page Allocation

pub const ORDER = 12;
pub const SIZE = 1 << ORDER;
pub const MEGA_SIZE = SIZE << 9;
pub const GIGA_SIZE = MEGA_SIZE << 9;

// Embedded DLL Storing
var free_chunk_list = DLL(chunk){};
const chunk = struct {
    cnt: usize,
    next: ?*chunk = null,
    prev: ?*chunk = null,
};

pub var initialized: bool = false;
pub fn init() void {
    assert(heap.initialized);
    start = heap.end;
    end = config.RAM_END_VMA;
    assert((end - start) % SIZE == 0);

    const begin: *chunk = @ptrFromInt(start);
    begin.* = chunk{ .cnt = (end - start) >> ORDER};
    free_chunk_list.append(begin);
    initialized = true;
}

// Coalescing Page Allocator
var allock: wait.Lock = .new("allock");

pub fn alloc_phys_page() *align(SIZE) [SIZE]u8 { return phys_alloc(1); }
pub fn phys_alloc(cnt: usize) [*]align(SIZE) [SIZE]u8 {
    var shortest_size: usize = 0;
    var total_free: usize = 0;

    var shortest: ?*chunk = null;

    allock.acquire();
    defer allock.release();

    var cur = free_chunk_list.head;
    while (cur) |node| : (cur = node.next) {
        const free_node = node.cnt;

        total_free += free_node;
        if (shortest_size > free_node) {
            shortest_size = free_node;
            if (free_node >= cnt) shortest = node;
            if (free_node == cnt) break; // cut early
        }
    }

    const shorty = shortest orelse @panic("OOM");

    assert(cnt <= shorty.cnt);

    const new_shorty: *chunk = if (shortest_size == cnt) free_chunk_list.pop(shorty).? else @ptrFromInt(@intFromPtr(shorty) + (shorty.cnt - cnt) * SIZE);
    defer @memset(@as([*]u8, @ptrCast(new_shorty))[0..SIZE], 0);
    return @alignCast(@ptrCast(new_shorty));
}

pub fn phys_free(pages: []align(SIZE) u8) void {
    const pma: usize = @intFromPtr(pages.ptr);
    assert(pma % SIZE == 0);

    assert(pages.len % SIZE == 0);
    const cnt = pages.len / SIZE;

    allock.acquire();
    defer allock.release();

    var cur_node = free_chunk_list.head;
    const next_node: ?*chunk = while (cur_node) |node| : (cur_node = node.next) {
        if (@intFromPtr(node) > pma) break node;
    } else null;
    const prev_node: ?*chunk = if (next_node) |next| next.prev else free_chunk_list.tail;
    var new_node: *chunk = undefined;

    if (prev_node) |prev|{
        if (@intFromPtr(prev) + (prev.cnt << ORDER) == pma) {
            prev.cnt += cnt; // merge new free block with previous
            new_node = prev;
        } else {
            new_node = @alignCast(@ptrCast(pages));
            new_node.* = chunk{ .cnt = cnt, .prev = prev, .next = next_node };
            prev.next = new_node;
        }
    }

    if (next_node) |next| {
        next.prev = new_node;
        if (@intFromPtr(next) == pma + (cnt << ORDER)) { // coalesce
            new_node.cnt += next.cnt;
            _ = free_chunk_list.pop(next);
        }
    } else free_chunk_list.tail = new_node;
}

pub fn free_page_cnt() usize {
    var sum: usize = 0;
    var cur = free_chunk_list.head;
    while (cur) |node| : (cur = node.next) { sum += node.cnt; }
    return sum;
}

pub fn free_chunk_cnt() usize {
    var cnt = 0;
    var cur = free_chunk_list.head;
    while (cur) |node| : (cur = node.next) { cnt += 1; }
    return cnt;
}

// TESTING
const expect = std.testing.expect;
test "allocate all at once" {
    const orig = free_page_cnt();
    try expect(free_chunk_cnt() == 1);

    const pp = phys_alloc(orig);

    try expect(free_page_cnt() == 0);
    try expect(free_chunk_cnt() == 0);

    phys_free(pp, orig);

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
        phys_free(pps[(7 * i) % num]);

    try expect(free_page_cnt() == orig);
    try expect(free_chunk_cnt() == 1);
}
