const std = @import("std");
const DLL = @import("../util/list.zig").DLL;
const heap = @import("../mem/heap.zig");
const intr = @import("../cntl/intr.zig");
const Thread = @import("./thread.zig");
const assert = @import("../util/debug.zig").assert;
const log = std.log.scoped(.WAIT);

pub const Condition = struct {
    name: []const u8,
    threads: DLL(Thread) = .{},

    pub fn wait(cond: *Condition) void {
        log.debug("Waiting on \"{s}\" condition", .{cond.name});
        const pie = intr.disable();

        const self = Thread.TP();
        assert(self.state == .running, "only running thread can wait!");
        assert(self.wait_cond == null and self.next == null, "condition mixup!");

        self.state = .waiting;

        self.wait_cond = cond;

        intr.restore(pie);
        Thread.yield();
    }

    pub fn broadcast(cond: *Condition) void {
        log.debug("Broadcasting \"{s}\" condition", .{cond.name});
        const pie = intr.disable();
        defer intr.restore(pie);

        var node = cond.threads.head;
        while (node) |cur| : (node = cur.next) {
            assert(cur.state == .waiting, "already awake!");
            cur.state = .ready;
            cur.wait_cond = null;
        }

        Thread.ready_list.concat(&cond.threads);
    }

    pub fn signal(cond: *Condition) void {
        log.debug("Signaling \"{s}\" condition", .{cond.name});
        const head = cond.threads.pop(cond.threads.head) orelse return;
        assert(head.state == .waiting, "already awake!");
        head.state = .ready;
        head.wait_cond = null;
        Thread.ready_list.append(head);
    }
};

pub const Error = error{Busy};

/// Single owner lock, for either read or write.
pub const Lock = struct {
    owner: ?*Thread = null,
    name: []const u8,
    cond: Condition,
    next: ?*Lock = null,
    prev: ?*Lock = null,

    /// Initializes lock name, along with condition.
    pub fn new(name: []const u8) Lock {
        return Lock{ .name = name, .cond = .{ .name = name } };
    }

    /// Waits until lock is free before aquiring.
    pub fn acquire(self: *Lock) void {
        log.debug("Acquiring <Lock:{s}>", .{self.name});
        const pie = intr.disable();
        defer intr.restore(pie);

        while (self.owner != null) self.cond.wait();

        self.owner = Thread.TP();
        self.owner.?.locks.append(self);
    }

    /// Returns error if lock is busy.
    pub fn acquire_now(self: *Lock) Error!void {
        log.debug("Acquiring (now) <Lock:{s}>", .{self.name});
        const pie = intr.disable();
        defer intr.restore(pie);
        switch (self.owner) {
            Thread.TP() => return,
            null => {
                self.owner = Thread.TP();
                self.owner.?.locks.append(self);
            },
            else => return Error.Busy,
        }
    }

    /// Releases lock from thread ownership and removes from thread's lock list.
    /// Only signals the next thread in line.
    pub fn release(self: *Lock) void {
        log.debug("Releasing <Lock:{s}>", .{self.name});
        assert(self.owner == Thread.TP(), "not yours to release!");
        assert(self.owner.?.locks.find(self) != null, "owner unaware of this one");

        _ = self.owner.?.locks.pop(self);
        self.owner = null;
        self.cond.signal();
    }
};

/// One writer or many readers
pub const RWLock = struct {
    name: []const u8,
    readers: usize = 0, // won't compile as DLL
    writer: ?*Thread = null,

    reading: Condition,
    writing: Condition,

    prev: ?*RWLock = null,
    next: ?*RWLock = null,

    const Mode = enum {
        read,
        write,
        none
    };

    /// Creates new RWLock with name, and correctly names condition variables.
    pub fn new(name: []const u8) RWLock {
        return RWLock{
            .name = name,
            .reading = .{ .name = name ++ " reading" },
            .writing = .{ .name = name ++ " writing" },
        };
    }

    /// Either waits for all readers to release or the one writer.
    pub fn acquire(self: *RWLock, read: bool) void {
        log.debug("Acquiring <RWLock:{s}> as {s} ({d} readers, {d} writers)",
        .{self.name, if (read) "reader" else "writer", self.readers, @intFromBool(self.writer != null)});
        const pie = intr.disable();
        defer intr.restore(pie);

        if (read) {
            while (self.writer != null)
                self.reading.wait();
            self.readers += 1;
            Thread.TP().rwlocks.append(self);
        } else {
            while (self.readers > 0 or self.writer != null)
                self.writing.wait();
            self.writer = Thread.TP();
        }
    }

    /// Infers reading/writing mode
    pub fn release(self: *RWLock) void {
        const tp = Thread.TP();
        assert(tp.rwlocks.find(self), "not yours to release!");
        switch (self.mode()) {
            .read => {
                log.debug("Releasing <RWLock:{s}> as reader ({d} remain)", .{ self.name, self.readers.size });
                self.readers -= 1;
                if (self.readers.size == 0)
                    self.writing.signal();
            },
            .write => {
                log.debug("Releasing <RWLock:{s}> as writer", .{self.name});
                self.reading.broadcast();
                self.writer = null;
            },
            .none => @panic("unowned rwlock realeased")
        }
        _ = tp.rwlocks.pop(self);
    }

    /// Is it held by readers or by a writer?
    pub fn mode(self: *RWLock) RWLock.Mode {
        if (self.readers > 0)
            return .read;
        if (self.writer)
            return .write;
        return .none;
    }
};
