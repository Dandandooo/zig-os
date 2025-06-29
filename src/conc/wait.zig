const DLL = @import("../util/list.zig").DLL;
const heap = @import("../mem/heap.zig");
const intr = @import("../cntl/intr.zig");
const thread = @import("./thread.zig");
const assert = @import("std").debug.assert;

pub const condition = struct {
    name: []const u8,
    threads: DLL(thread) = .{},

    pub fn wait(cond: *condition) void {
        const pie = intr.disable();

        const self = thread.TP();
        assert(self.*.state == .running);
        assert(self.*.wait_cond == null and self.*.list_next == null);

        self.*.state = .waiting;

        self.*.wait_cond = cond;

        intr.restore(pie);
        thread.yield();
    }

    pub fn broadcast(cond: *condition) void {
        const pie = intr.disable();
        defer intr.restore(pie);

        while (cond.*.threads) | next_thread | {
            assert(next_thread.*.state == .waiting);
            next_thread.*.state = .ready;
            next_thread.*.wait_cond = null;
        }


        cond.*.threads = null;
    }

    pub fn signal(cond: *condition) void {
        const head = cond.*.threads orelse @panic("signaled empty condition");
        head.*.state = .ready;
        head.*.wait_cond = null;
        cond.*.threads = head.*.list_next;
        head.*.list_next = null;
        thread.enqueue(head);
    }
};

pub const lock = struct {
    owner: ?*thread = null,
    name: []const u8,
    cond: condition,
    next: ?*lock = null,
    prev: ?*lock = null,

    pub fn new(name: []const u8) lock {
        return lock{
            .name = name,
            .cond = .{.name = name}
        };
    }

    pub fn acquire(self: *lock) void {
        const pie = intr.disable();
        defer intr.restore(pie);

        while (self.*.owner != null) self.*.cond.wait();

        self.*.owner = thread.TP();
    }

    pub fn release(self: *lock) void {
        assert(self.*.owner == thread.TP());
        self.*.cond.signal();
    }
};
