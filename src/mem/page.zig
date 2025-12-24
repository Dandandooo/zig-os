const std = @import("std");
const heap = @import("./heap.zig");
const wait = @import("../conc/wait.zig");
const assert = @import("../util/debug.zig").assert;
const config = @import("../config.zig");
const log = std.log.scoped(.PAGE);

pub var start: usize = undefined;
pub var end: usize = undefined;

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

pub const ORDER = config.PAGE_ORDER;
pub const SIZE = config.PAGE_SIZE;
pub const MEGA_SIZE = SIZE << 9;
pub const GIGA_SIZE = MEGA_SIZE << 9;

// Embedded DLL Storing

var free_chunk_list = DLL(chunk){};

pub const ty = []align(SIZE) u8;
pub const chunk = struct {
    cnt: usize,
    next: ?*chunk = null,
    prev: ?*chunk = null,
    // _pad: [SIZE-@sizeOf(usize)-2*@sizeOf(?*chunk)]u8 = undefined
};

pub var initialized: bool = false;
pub fn init() void {
    assert(!initialized, "already initialized!");
    assert(heap.initialized, "need heap to be initialized");
    start = round_up(heap.end);
    end = config.RAM_END_PMA;
    assert((end - start) % SIZE == 0, "heap doesn't end on page boundary!");

    log.debug("page start: 0x{X}", .{start});
    log.debug("page end: 0x{X}", .{end});

    log.debug("initializing page", .{});
    const begin: *chunk = @ptrFromInt(start);
    log.debug("initializing page", .{});
    begin.* = chunk{ .cnt = (end - start) >> ORDER};
    log.debug("initializing page", .{});
    free_chunk_list.append(begin);
    initialized = true;
}

// Coalescing Page Allocator
var allock: wait.Lock = .new("allock");

pub fn phys_alloc(cnt: usize) []align(SIZE) u8 {
    assert(initialized, "page manager uninitialized!");
    log.debug("Allocating {d} pages", .{cnt});

    var shortest_size: usize = 0xFFFF_FFFF_FFFF_FFFF;
    var total_free: usize = 0;

    var shortest: ?*chunk = null;

    allock.acquire();
    defer allock.release();

    var cur = free_chunk_list.head;
    while (cur) |node| : (cur = node.next) {
        log.debug("Free chunk: {d}", .{node.cnt});
        const free_node = node.cnt;

        total_free += free_node;
        if (shortest_size > free_node and free_node >= cnt) {
            shortest_size = free_node;
            if (free_node >= cnt) shortest = node;
            if (free_node == cnt) break; // cut early
        }
    }

    const shorty = shortest orelse @panic("OOM");

    assert(cnt <= shorty.cnt, "shorty ain't packing enough!");

    var new_shorty: *chunk = undefined;
    if (shorty.cnt == cnt) {
        new_shorty = free_chunk_list.pop(shorty).?;
    } else {
        shorty.cnt -= cnt;
        new_shorty = @ptrFromInt(@intFromPtr(shorty) + (shorty.cnt) * SIZE);
    }
    const new_page: []align(SIZE) u8 = @alignCast(@as([*]u8, @ptrCast(new_shorty))[0..cnt*SIZE]);
    defer @memset(new_page, 0);
    return new_page;
}

pub fn phys_free(pages: []align(SIZE) u8) void {
    assert(initialized, "page manager uninitialized!");
    const pma: usize = @intFromPtr(pages.ptr);
    assert(pma % SIZE == 0, "misaligned page free!");

    assert(pages.len % SIZE == 0, "mis-sized page free!");
    const cnt = pages.len / SIZE;

    log.debug("Freeing {d} pages at 0x{X}", .{cnt, pma});

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
            new_node = @alignCast(@ptrCast(pages.ptr));
            new_node.* = chunk{ .cnt = cnt, .prev = prev, .next = prev.next };
            prev.next = new_node;
            // free_chunk_list.insert(new_node, prev);
        }
    } else {
        new_node = @alignCast(@ptrCast(pages.ptr));
        new_node.* = chunk{ .cnt = cnt, .prev = null, .next = next_node };
        free_chunk_list.head = new_node;
    }

    if (next_node) |next| {
        next.prev = new_node;
        new_node.next = next;
        if (@intFromPtr(next) == @intFromPtr(new_node) + (new_node.cnt << ORDER)) { // coalesce
            new_node.cnt += next.cnt;
            new_node.next = next.next;
            if (next.next) |nn| {
                nn.prev = new_node;
            } else {
                free_chunk_list.tail = new_node;
            }
            // _ = free_chunk_list.pop(next);
        }
    } else free_chunk_list.tail = new_node;
}

pub fn free_page_cnt() usize {
    var sum: usize = 0;
    var cur = free_chunk_list.head;
    while (cur) |node| : (cur = node.next) { sum += node.cnt; }
    log.debug("Free pages: {d}", .{sum});
    return sum;
}

pub fn free_chunk_cnt() usize {
    var cnt: usize = 0;
    var cur = free_chunk_list.head;
    while (cur) |node| : (cur = node.next) { cnt += 1; }
    log.debug("Free chunks: {d}", .{cnt});
    return cnt;
}
