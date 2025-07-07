const DLL = @import("../util/list.zig").DLL;
const heap = @import("../mem/heap.zig");
const intr = @import("../cntl/intr.zig");
const Thread = @import("./thread.zig");
const assert = @import("std").debug.assert;

pub const Condition = struct {
    name: []const u8,
    threads: DLL(Thread) = .{},

    pub fn wait(cond: *Condition) void {
        const pie = intr.disable();

        const self = Thread.TP();
        assert(self.state == .running);
        assert(self.wait_cond == null and self.next == null);

        self.state = .waiting;

        self.wait_cond = cond;

        intr.restore(pie);
        Thread.yield();
    }

    pub fn broadcast(cond: *Condition) void {
        const pie = intr.disable();
        defer intr.restore(pie);

        var node = cond.threads.head;
        while (node) | cur | : (node = cur.next) {
            assert(cur.state == .waiting);
            cur.state = .ready;
            cur.wait_cond = null;
        }

        Thread.ready_list.concat(&cond.threads);
    }

    pub fn signal(cond: *Condition) void {
        const head = cond.threads.pop(cond.threads.head) orelse return;
        assert(head.state == .waiting);
        head.state = .ready;
        head.wait_cond = null;
        Thread.ready_list.append(head);
    }
};

pub const Lock = struct {
    owner: ?*Thread = null,
    name: []const u8,
    cond: Condition,
    next: ?*Lock = null,
    prev: ?*Lock = null,

    pub fn new(name: []const u8) Lock {
        return Lock{
            .name = name,
            .cond = .{.name = name}
        };
    }

    pub fn acquire(self: *Lock) void {
        const pie = intr.disable();
        defer intr.restore(pie);

        while (self.owner != null) self.cond.wait();

        self.owner = Thread.TP();
    }

    pub fn release(self: *Lock) void {
        assert(self.owner == Thread.TP());
        self.cond.signal();
    }
};
