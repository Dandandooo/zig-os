const std = @import("std");
const DLL = @import("../util/list.zig").DLL;
const heap = @import("../mem/heap.zig");
const page = @import("../mem/page.zig");
const wait = @import("./wait.zig");
const process = @import("./process.zig");
const config = @import("../config.zig");
const intr = @import("../cntl/intr.zig");
const assert = @import("../util/debug.zig").assert;
const kernel = @import("../kernel.zig");

const Thread = @This();
const log = std.log.scoped(.THREAD);

// Externals
extern const _idle_stack_anchor: stack_anchor;
extern const _idle_stack_lowest: [page.SIZE]u8 align(page.SIZE);

extern const _main_stack_anchor: stack_anchor;
extern const _main_stack_lowest: [page.SIZE]u8 align(page.SIZE);

extern fn _thread_startup() void;
extern fn _thread_swtch(*Thread) *Thread;

// Globals
var thrtab: [config.NTHR]?*Thread = [_]?*Thread{null} ** config.NTHR;
const main_tid = 0;
const idle_tid = config.NTHR - 1;

pub var ready_list: DLL(Thread) = .{};

pub fn TP() *Thread {
    return asm ("mv %[ret], tp"
        : [ret] "=r" (-> *Thread),
    );
}

inline fn set_running(thr: *Thread) void {
    asm volatile ("mv tp, %[thr]"
        :
        : [thr] "r" (thr),
        : "tp"
    );
}

// Types

pub const context = struct {
    s: [12]u64 = [_]u64{0} ** 12,
    ra: *const anyopaque = undefined,
    sp: *anyopaque = undefined,

    fn new(entry_fn: *const anyopaque, ra: *const anyopaque, sp: *anyopaque) context {
        return context{ .s = [_]u64{0} ** 8 ++ [_]u64{@intFromPtr(entry_fn)} ++ [_]u64{0} ** 3, .ra = ra, .sp = sp };
    }
};

const ctx_entry_fn_idx = 8;

const status = enum { uninitialized, waiting, running, ready, exited };

const stack_anchor = extern struct {
    ktp: *Thread,
    /// kgp is unused in this kernel
    kgp: *anyopaque = undefined,
};

// Class Attributes
//

ctx: context = .{},
id: usize,
state: status = .uninitialized,
name: []const u8,

// Stack is page-aligned
anchor: *stack_anchor = undefined,
lowest: []align(page.SIZE) u8 = undefined,

/// No parent means main thread
parent: ?*Thread = null,
child_exit: wait.Condition = .{ .name = "child exit" },
wait_cond: ?*wait.Condition = null,

/// For compatibility with util DLL spec
prev: ?*Thread = null,
next: ?*Thread = null,

/// No process signifies kernel thread
proc: ?*process = null,

locks: DLL(wait.Lock) = .{},
rwlocks: DLL(wait.RWLock) = .{},

// Global Threads
//

var main_thread: Thread = .{
    .name = "main",
    .id = main_tid,
    .ctx = undefined,
    .state = .running,
    .child_exit = .{ .name = "main child exit" },
};

var idle_thread: Thread = .{
    .name = "idle",
    .id = idle_tid,
    .state = .ready,
    .parent = &main_thread,
};

pub var initialized = false;
pub fn init() void {
    assert(!initialized, "threads already initialized!");
    log.debug("main thread: {*}", .{&main_thread});
    log.debug("main thread anchor = {*}", .{&main_thread.anchor});
    log.debug("main stack anchor = {*}", .{&_main_stack_anchor});
    log.debug("main stack lowest = {*}", .{&_main_stack_lowest});
    main_thread.anchor = @constCast(&_main_stack_anchor);
    main_thread.anchor.ktp = &main_thread;
    main_thread.lowest = @constCast(&_main_stack_lowest)[0..];

    // register main thread
    thrtab[main_tid] = &main_thread;

    log.debug("idle thread: {*}", .{&idle_thread});
    log.debug("idle thread anchor = {*}", .{&idle_thread.anchor});
    log.debug("idle stack anchor = {*}", .{&_idle_stack_anchor});
    log.debug("idle stack lowest = {*}", .{&_idle_stack_lowest});
    idle_thread.anchor = @constCast(&_idle_stack_anchor);
    idle_thread.anchor.ktp = &idle_thread;
    idle_thread.lowest = @constCast(&_idle_stack_lowest)[0..];

    // make idle ctx use the anchor pointer we've set above
    idle_thread.ctx = .new(@ptrCast(&idle_func), @ptrCast(&_thread_startup), idle_thread.anchor);

    // register idle thread
    thrtab[idle_tid] = &idle_thread;

    log.info("entering main thread", .{});
    set_running(&main_thread);
    initialized = true;
}

pub fn yield() void {
    const self = TP();

    const pie = intr.disable();
    defer intr.restore(pie);
    if (self.state == .running) {
        self.state = .ready;
        if (self != &idle_thread)
            ready_list.append(self);
    }

    const next = ready_list.pop(ready_list.head) orelse &idle_thread;

    assert(next.state == .ready, "yielding to unready thread!");
    next.state = .running;

    if (self.state == .exited)
        self.reclaim();

    // TODO: switch mspace
    log.debug("Switching to <{s}:{d}>", .{next.name, next.id});
    const old = _thread_swtch(next);
    log.debug("Switched back to <{s}:{d}>", .{ old.name, old.id });

    if (old.state == .exited)
        old.reclaim();
}

// Thread Creation

pub fn spawn(name: []const u8, entry: *anyopaque, ...) callconv(.c) *Thread {
    const thr = create(name);
    thr.ctx.s[8] = @intFromPtr(entry);

    const ap = @cVaStart();
    for (0..8) |i| thr.*.ctx.s[i] = @cVaArg(ap, usize);
    @cVaEnd(ap);

    thr.ctx.ra = @ptrCast(_thread_startup);
    thr.ctx.sp = thr.anchor;

    thr.state = .ready;

    const pie = intr.disable();
    ready_list.append(thr);
    intr.restore(pie);

    return thr;
}

fn create(name: []const u8) *Thread {
    log.debug("Creating thread {s}", .{name});
    const tid: usize = for (1..idle_tid) |i| {
        if (thrtab[i] == null) break i;
    } else @panic("out of thread spots");

    const thr: *Thread = heap.allocator.create(Thread);

    const stack_page: []align(page.SIZE) u8 = page.phys_alloc(1);

    thr.* = .{
        .id = tid,
        .name = name,
        .parent = TP(),

        .anchor = @ptrCast(stack_page + page.SIZE - 1),
        .lowest = stack_page,
    };

    thr.*.anchor.* = .{ .ktp = thr };

    thrtab[tid] = thr;
    return thr;
}

pub fn join(child: *Thread) void {
    assert(child != TP(), "can't join yourself!");
    assert(child.parent == TP(), "can't join someone else's child!");

    const pie = intr.disable();
    defer intr.restore(pie);

    while (child.state != .exited) child.child_exit.wait();
}

// Kills a thread
pub fn exit() noreturn {
    const self = TP();
    assert(self.state == .running, "you must be running to exit");
    if (self == &main_thread) kernel.shutdown(true);
    // assert(self.state != .exited, "double kill!");
    self.state = .exited;

    while (self.locks.head) |lock| : (_ = self.*.locks.pop(self.*.locks.head))
        lock.release();

    if (self.parent) |parent|
        parent.child_exit.broadcast();

    Thread.yield();

    // Should never get here
    @panic("Revived death thread!");
}

export fn thread_exit() noreturn {
    exit();
}

// Frees up a dead thread
fn reclaim(thr: *Thread) void {
    assert(thr.state == .exited, "kill me first!");
    log.debug("reclaiming thread <{s}:{d}>", .{thr.name, thr.id});

    for (1..idle_tid) |child| {
        if (thrtab[child] != null and thrtab[child].?.parent == thr)
            thrtab[child].?.parent = thr.parent;
    }

    thrtab[thr.id] = null;

    page.phys_free(thr.lowest);

    heap.allocator.destroy(thr);
}

fn idle_func() void {
    while (true) {
        while (ready_list.size > 0)
            yield();

        // Sleep until runnable thread
        log.debug("sleeping", .{});
        _ = intr.disable();
        if (ready_list.size == 0)
            asm volatile ("wfi");
        _ = intr.enable();
    }
}
