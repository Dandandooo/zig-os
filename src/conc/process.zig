const std = @import("std");
const reg = @import("../riscv/reg.zig");
const wait = @import("wait.zig");
const page = @import("../mem/page.zig");
const vmem = @import("../mem/vmem.zig");
const trap = @import("../cntl/trap.zig");
const math = @import("../util/math.zig");
const config = @import("../config.zig");

const assert = @import("../util/debug.zig").assert;

const IO = @import("../api/io.zig");
const Thread = @import("thread.zig");
const Process = @This();

// --------------------
// Definition & Globals
// --------------------

pid: u32,
thr: *Thread, // single managed thread
mtag: reg.satp,
iotab: [config.PROCESS_IOMAX]?*IO = [_]?*IO{null} ** config.PROCESS_IOMAX,
child: wait.Condition = .{ .name = "child exit"},
allocator: *const std.mem.Allocator,

var main_proc: Process = .{
    .pid = 0,
    .tid = undefined,
    .mtag = undefined,
    .child = .{ .name = "main" },
    .allocator = undefined,
};

var proctab: [config.NPROC]?*Process = [_]?*Process{null} ** config.NPROC;
var null_io: IO.NullIO = .{};

const Error = error {
    MaxProc, MaxThread, NoMem
};

// ------------------
// Core Functionality
// ------------------

var initialized = false;
pub fn init() void {
    assert(!initialized, "Processes already initialized");
    defer initialized = true;

    main_proc.thr = Thread.TP();
    main_proc.mtag = vmem.active_mspace();
    proctab[main_proc.pid] = &main_proc;
    Thread.TP().proc = &main_proc;
    main_proc.iotab[0] = &null_io.io;
}

pub fn exec(io: *IO, argc: u32, argv: [][]const u8) !void {
    _ = .{ io, argc, argv };
    // TODO

    const tmp_stack: *anyopaque = page.phys_alloc(1);
    errdefer page.phys_free(tmp_stack);

    const stksz: u32 = try build_stack();

    _ = stksz;

}

pub fn fork(tfr: *trap.Frame) !void {
    const cur = current() orelse @panic("Forking nothing");

    const child = try cur.allocator.create(Process);
    errdefer cur.allocator.destroy(child);

    child.* = .{
        .pid = idx: { for (proctab, 0..) | proc, i | { if (proc) break :idx i; } else return Error.MaxProc; },
        .thr = Thread.spawn(cur.thr.name, fork_func) orelse return Error.MaxThread,
        .mtag = vmem.clone_active_mspace(),
        .allocator = cur.allocator
    };
    child.thr.proc = child;

    // Copy over IO devices
    for (cur.iotab, child.iotab) |old, *new| {
        if (old) |io|
            new.* = io.addref();
    }

    // wait for child to run fork_func
    cur.child.wait();

    tfr.a[0] = child.thr.id;
    tfr.jump(Thread.TP().anchor);
}

pub fn exit() void {
    const cur = current() orelse { Thread.exit(); return; };

    vmem.discard_active_mspace();
    for (cur.iotab) | entry |
        if (entry) | io | io.close();

    proctab[cur.pid] = null;

    if (cur != &main_proc)
        cur.allocator.destroy(cur);

    Thread.exit();
}

// ----------------
// Helper Functions
// ----------------

pub fn current() ?*Process {
    return Thread.TP().proc;
}

fn build_stack(stack: *anyopaque, argv: [][:0]u8) !u32 {
    // We need to be able to fit argv[] on the initial stack page, so _argc_
    // cannot be too large. Note that argv[] contains argc+1 elements (last one
    // is a NULL pointer).
    var stksz = (argv.len + 1) * @sizeOf([*:0]u8);

    for (argv) |arg|
        stksz += arg.len;

    if (stksz > page.SIZE)
        return Error.NoMem;

    stksz = std.mem.alignForward(usize, stksz, 16);

    assert(stksz <= page.SIZE, "new stack too large!");

    // Set _newargv_ to point to the location of the argument vector on the new
    // stack and set _p_ to point to the stack space after it to which we will
    // copy the strings. Note that the string pointers we write to the new
    // argument vector must point to where the user process will see the stack.
    // The user stack will be at the highest page in user memory, the address of
    // which is `(UMEM_END_VMA - PAGE_SIZE)`. The offset of the _p_ within the
    // stack is given by `p - newargv'.
    const newargv: []usize = @ptrFromInt(@intFromPtr(stack) + page.SIZE - stksz);
    var p: [*:0]u8 = @ptrFromInt(@intFromPtr(newargv) + argv.len + 1);

    for (0.., argv) |i, arg| {
        newargv[i] = @intFromPtr(p);
        @memcpy(p, arg.ptr[0..arg.len + 2]);
        p = @ptrFromInt(@intFromPtr(p) + arg.len + 1);
    }


    return stksz;
}

fn fork_func(done: *wait.Condition, tfr: *trap.Frame) void {
    done.broadcast();
    // return 0 for the child process
    tfr.a[0] = 0;
    tfr.jump(Thread.TP().anchor);
}
