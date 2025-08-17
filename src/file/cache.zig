const std = @import("std");
const heap = @import("../mem/heap.zig");
const IO = @import("../api/io.zig");
const DLL = @import("../util/list.zig").DLL;
const wait = @import("../conc/wait.zig");

const log = std.log.scoped(.FSCACHE);

// Constants
pub const BLKSZ = 512;

pub const PURGE_UNTIL = 64;
pub const CAPACITY = 128;

// Class Attributes
const Cache = @This();

bkgio: *IO,
data: DLL(cache_elem) = .{},
parole: wait.Condition = .{ .name = "parole" },
allocator: std.mem.Allocator,

const cache_elem = struct {
    pos: u64,
    data: [BLKSZ]u8 = undefined,
    lock: wait.RWLock = .new("(b)lock"),
    dirty: bool = false,
    next: ?*cache_elem = null,
    prev: ?*cache_elem = null,
};

// Functions

const block_error = std.mem.Allocator.Error || IO.Error;

/// Get for writing. WILL mark block as dirty
pub fn get(self: *Cache, pos: u8) block_error![]u8 {
    return self.get_block(pos, false);
}

/// Get for reading
pub fn get_const(self: *Cache, pos: u8) block_error![]const u8 {
    return self.get_block(pos, true);
}

fn get_block(self: *Cache, pos: u8, ro: bool) block_error![]u8 {
    // Potential optimizations:
    // 1. only rearrange if block is behind the purge threshold
    const elem = if (self.data.find_field("pos", pos)) |node|
        self.data.pop(node).?
    else try self.fetch(pos);

    elem.lock.acquire(ro);
    if (!ro) elem.dirty = true;
}

fn fetch(self: *Cache, pos: u8) block_error!*cache_elem {
    const elem = try self.allocator.create(cache_elem);
    elem.* = .{ .pos = pos };
    _ = try self.bkgio.readat(elem.data, pos);
    self.data.prepend(elem);
}


/// Write-back cache, so no writing during this step (except for full)
pub fn release(self: *Cache, buf: []u8) void {
    const elem: *cache_elem = @fieldParentPtr("data", buf);
    elem.lock.release();
    if (self.data.size >= CAPACITY)
        self.clear_tail(CAPACITY - PURGE_UNTIL);
}

/// Write the `num` least-recently-used elements to disk (if dirty) and remove them.
/// Failed writes will keep elements in cache to try again later
fn clear_tail(self: *Cache, num: usize) IO.Error!void {
    var errored = false;
    var i = num;
    var cur = self.data.tail;
    while (cur) | elem | : ({cur = elem.next; i -= 1}) {
        if (i <= 0) break;

        if (elem.dirty) {
            self.bkgio.writeat(elem.data, elem.pos) catch |err| {
                log.err("Failed to save block {d} ({s}), keeping in cache", .{pos, @errorName(err)});
                continue;
            };
        }

        self.allocator.destroy(elem);
        _ = self.data.pop(cur)
    }

    if (errored)
        return IO.Error.Error;
}

/// Write-back cache.
pub fn flush(self: *Cache) IO.Error!void {
    return self.clear_tail(self.data.size);
}
