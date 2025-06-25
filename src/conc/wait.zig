const DLL = @import("../util/list.zig").DLL;
const heap = @import("../mem/heap.zig");
const thread = @import("./thread.zig");

pub const condition = struct {
    name: []const u8,
    threads: DLL(thread) = .{ .allocator = heap.allocator },

    pub fn new(name: []const u8) condition {
        return condition{ .name = name };
    }
};

pub const lock = struct {
    owner: isize,
    name: []const u8,
    cond: condition,

    pub fn new(name: []const u8) lock {
        return lock{
            .owner = -1,
            .name = name,
            .cond = condition.new(name)
        };
    }

    pub fn acquire() void { }
    pub fn release() void { }
};
