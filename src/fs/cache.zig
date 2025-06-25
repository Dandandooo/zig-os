const std = @import("std");
const heap = @import("../mem/heap.zig");
const io = @import("../api/io.zig");
const DLL = @import("../util/list.zig").DLL;
const wait = @import("../conc/wait.zig");

// Constants
pub const BLKSZ = 512;
pub const CAPACITY = 64;

// Class Attributes
const cache = @This();

bkgio: *const io,
data: DLL(cache_elem) = .{ .allocator = heap.allocator },
parole: wait.condition = .{ .name = "parole" },

const cache_elem = struct {
    pos: u64,
    data: [BLKSZ]u8 = [_]u8{0} ** BLKSZ,
    lock: thread.lock = .{ .name = }
};

// Functions
pub fn get(self: cache, pos: u8) [BLKSZ]u8 {
    if (self.data.find_field("pos", pos)) |node| {
        node.*.data.lock.acquire();
    } else {

    }

}
