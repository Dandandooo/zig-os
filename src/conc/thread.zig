const DLL = @import("../util/list.zig").DLL;
const heap = @import("../mem/heap.zig");
const wait = @import("./wait.zig");
const process = @import("./process.zig");
const config = @import("../config.zig");
const intr = @import("../cntl/intr.zig");
const assert = @import("std").debug.assert;

const thread = @This();


// Externals
extern const _idle_stack_anchor: *const stack_anchor;
extern const _idle_stack_lowest: *const anyopaque;

extern const _main_stack_anchor: *const stack_anchor;
extern const _main_stack_lowest: *const anyopaque;

extern fn _thread_startup() void;
extern fn _thread_swtch() *thread;


// Globals
var thrtab: [config.NTHR]?*thread = [_]?thread{null} ** config.NTHR;
const main_tid = 0;
const idle_tid = config.NTHR-1;

var ready_list: DLL(*thread) = .{ .allocator = heap.allocator };




pub fn TP() *thread {
    return asm (
        "mv %[ret], tp"
        : [ret] "=r" (-> *thread)
    );
}

// Types

const context = struct {
    s: [12]u64 = [_]u64{0} ** 12,
    ra: *anyopaque,
    sp: *anyopaque,

    fn new(entry_fn: *anyopaque, ra: *anyopaque, sp: *anyopaque) context {
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
    ktp: *const thread,
    kgp: *anyopaque
};

// Class Attributes
ctx: context,
id: usize,
state: status = .uninitialized,
name: []const u8,

anchor: *stack_anchor,
lowest: *anyopaque,

parent: ?*thread = null,
child_exit: wait.condition = wait.condition.new("child exit"),
wait_cond: ?*wait.condition = null,

proc: ?*process = null,

locks: DLL(wait.lock) = .{ .allocator = heap.allocator },

// Global Threads

const main_thread: thread = .{
    .name = "main",
    .id = main_tid,
    .ctx = undefined,
    .state = .running,
    .child_exit = wait.condition.new("main child exit"),

    .anchor = _main_stack_anchor,
    .lowest = _main_stack_lowest,

};

const idle_thread: thread = .{
    .name = "idle",
    .id = idle_tid,
    .ctx = context.new(&idle_func, &_thread_startup, _idle_stack_anchor),

    .parent = &main_thread,

    .anchor = _idle_stack_anchor,
    .lowest = _idle_stack_lowest,

};

pub fn init() void {
    main_thread.anchor.*.ktp = &main_thread;
    idle_thread.anchor.*.ktp = &idle_thread;
}



fn yield() void {

}


fn create(name: []const u8) *thread {

    var tid: usize = for (1..idle_tid) |i| {
        if (thrtab[i] == null) break i;
    } else 0;

    if (tid == 0) @panic("out of thread spots");

    var thr: *thread = heap.allocator.create(thread);

    thr.* = .{
        .
    };

    thrtab[tid] = thr;
    return thr;
}

// Frees up a dead thread
fn reclaim(tid: usize) void {
    assert(0 < tid and tid < config.NTHR);

    const thr: *thread = thrtab[tid] orelse @panic("reclaiming nonexistent thread");

    assert(thr.*.state == .exited);

    for (1..idle_tid) |child| {
        if (thrtab[child] != null and thrtab[child].?.*.parent == thr)
            thrtab[child].?.*.parent = thr.*.parent;
    }

    thrtab[tid] = null;

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
