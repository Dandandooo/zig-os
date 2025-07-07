const std = @import("std");
const DLL = @import("../util/list.zig").DLL;
const heap = @import("../mem/heap.zig");
const page = @import("../mem/page.zig");
const wait = @import("./wait.zig");
const process = @import("./process.zig");
const config = @import("../config.zig");
const intr = @import("../cntl/intr.zig");
const assert = @import("std").debug.assert;

const thread = @This();

// Externals
extern const _idle_stack_anchor: *stack_anchor;
extern const _idle_stack_lowest: *anyopaque;

extern const _main_stack_anchor: *stack_anchor;
extern const _main_stack_lowest: *anyopaque;

extern fn _thread_startup() void;
extern fn _thread_swtch(*thread) *thread;


// Globals
var thrtab: [config.NTHR]?*thread = [_]?*thread{null} ** config.NTHR;
const main_tid = 0;
const idle_tid = config.NTHR-1;

pub var ready_list: DLL(thread) = .{};

pub fn TP() *thread {
    return asm (
        "mv %[ret], tp"
        : [ret] "=r" (-> *thread)
    );
}

// Types

pub const context = struct {
    s: [12]u64 = [_]u64{0} ** 12,
    ra: *const anyopaque = undefined,
    sp: *anyopaque = undefined,

    fn new(entry_fn: *const anyopaque, ra: *const anyopaque, sp: *anyopaque) context {
        return context{
            .s = [_]u64{0} ** 8 ++ [_]u64{@intFromPtr(entry_fn)} ++ [_]u64{0} ** 3,
            .ra = ra, .sp = sp
        };
    }
};

const ctx_entry_fn_idx = 8;

const status = enum {
    uninitialized,
    waiting,
    running,
    ready,
    exited
};

const stack_anchor = struct {
    ktp: *thread,
    kgp: usize = 0
};

// Class Attributes
//

ctx: context = .{},
id: usize,
state: status = .uninitialized,
name: []const u8,

// Stack is page-aligned
anchor: *stack_anchor = undefined,
lowest: *align(page.SIZE) anyopaque = undefined,

parent: ?*thread = null,
child_exit: wait.Condition = .{.name = "child exit"},
wait_cond: ?*wait.Condition = null,

prev: ?*thread = null,
next: ?*thread = null,

proc: ?*process = null,

locks: DLL(wait.Lock) = .{},

// Global Threads
//

var main_thread: thread = .{
    .name = "main",
    .id = main_tid,
    .ctx = undefined,
    .state = .running,
    .child_exit = .{.name = "main child exit"},
};

var idle_thread: thread = .{
    .name = "idle",
    .id = idle_tid,

    .parent = &main_thread,
};

pub fn init() void {
    main_thread.anchor = _main_stack_anchor;
    main_thread.anchor.ktp = &main_thread;
    main_thread.lowest = _main_stack_lowest;

    idle_thread.anchor = _idle_stack_anchor;
    idle_thread.anchor.ktp = &idle_thread;
    idle_thread.lowest = _idle_stack_lowest;
    idle_thread.ctx = .new(@ptrCast(&idle_func), @ptrCast(&_thread_startup), _idle_stack_anchor);
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

    assert(next.state == .ready);
    next.state = .running;

    if (self.state == .exited)
        self.reclaim();


    // TODO: switch mspace
    const old = _thread_swtch(next);

    if (old.state == .exited)
        old.reclaim();
}

// Thread Creation

pub fn spawn(name: []const u8, entry: *anyopaque, ...) callconv(.c) *thread {
    const thr = create(name);
    thr.ctx.s[8] = @intFromPtr(entry);

    const ap = @cVaStart();
    for (0..8) |i| thr.*.ctx.s[i] = @cVaArg(ap, usize);
    @cVaEnd(ap);

    thr.ctx.ra = _thread_startup();
    thr.ctx.sp = thr.anchor;

    thr.state = .ready;

    const pie = intr.disable();
    ready_list.append(thr);
    intr.restore(pie);
}

fn create(name: []const u8) *thread {

    const tid: usize = for (1..idle_tid) |i| {
        if (thrtab[i] == null) break i;
    } else @panic("out of thread spots");

    const thr: *thread = heap.allocator.create(thread);

    const stack_page: *align(page.SIZE) anyopaque = page.alloc_phys_page();

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

pub fn join(child: *thread) void {
    assert(child != TP());
    assert(child.parent == TP());

    const pie = intr.disable();
    defer intr.restore(pie);

    while (child.state != .exited) child.child_exit.wait();
}

// Kills a thread
pub fn exit() void {
    const self = TP();
    if (self == &main_thread) @panic("Main thread exited");
    assert(self.state != .exited);
    self.state = .exited;

    while (self.locks.head) |lock| : (_ = self.*.locks.pop(self.*.locks.head)) {
        lock.release();
    }

    if (self.parent) | parent | parent.child_exit.broadcast();

    thread.yield();
}

export fn thread_exit() void { exit(); }

// Frees up a dead thread
fn reclaim(thr: *thread) void {
    assert(thr.state == .exited);

    for (1..idle_tid) |child| {
        if (thrtab[child] != null and thrtab[child].?.parent == thr)
            thrtab[child].?.parent = thr.parent;
    }

    thrtab[thr.id] = null;

    // I know what I'm doing >:(
    page.phys_free(@alignCast(@as([*]u8, @ptrFromInt(@intFromPtr(thr.lowest)))[0..page.SIZE]));

    heap.allocator.destroy(thr);
}

fn idle_func() void {
    while (true) {
        while (ready_list.size > 0)
            yield();

        // Sleep until runnable thread
        _ = intr.disable();
        if (ready_list.size == 0)
            asm volatile ("wfi");
        _ = intr.enable();
    }
}
