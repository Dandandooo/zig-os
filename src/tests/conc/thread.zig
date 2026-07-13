const std = @import("std");
const log = std.log.scoped(.THREAD);
const Thread = @import("../../conc/thread.zig");
const wait = @import("../../conc/wait.zig");
const util = @import("../util.zig");

pub fn run() util.test_results {
    return util.run_tests("THREAD",
    &.{
        .{.name = "multi_print", .func = multi_print},
        .{.name = "spawn args", .func = spawn_args},
        .{.name = "interleaved counters", .func = interleaved_counters},
        .{.name = "lock exclusion", .func = lock_exclusion},
        .{.name = "condition wakeup", .func = condition_wakeup},
        .{.name = "join after exit", .func = join_after_exit},
    });
}

fn multi_print() anyerror!void {
    log.debug("Spawning thread 1", .{});
    const t0: *Thread = Thread.spawn("test0", @constCast(@ptrCast(&print0))) orelse return util.test_error.Incorrect;
    log.debug("Spawning thread 2", .{});
    const t1: *Thread = Thread.spawn("test1", @constCast(@ptrCast(&print1)), @as(u64, 2)) orelse return util.test_error.Incorrect;
    log.debug("Spawning thread 3", .{});
    const t2: *Thread = Thread.spawn("test2", @constCast(@ptrCast(&print2)), "hello from thread", @as(u64, 3)) orelse return util.test_error.Incorrect;

    t0.join();
    t1.join();
    t2.join();
}

fn print0() anyerror!void { log.debug("hello from thread 1", .{}); }
fn print1(tid: u32) anyerror!void { log.debug("hello from thread {d}", .{tid}); }
fn print2(msg: [*:0]const u8, tid: u32) anyerror!void { log.debug("{s} {d}", .{msg, tid}); }

// Arguments given to spawn must arrive in the child in order.

var got_a: u64 = 0;
var got_b: u64 = 0;
var got_c: u64 = 0;

fn arg_catcher(a: u64, b: u64, c: u64) anyerror!void {
    got_a = a;
    got_b = b;
    got_c = c;
}

fn spawn_args() anyerror!void {
    got_a = 0;
    got_b = 0;
    got_c = 0;

    const t = Thread.spawn("args", @constCast(@ptrCast(&arg_catcher)),
        @as(u64, 0xAA), @as(u64, 0xBB), @as(u64, 0xCC)) orelse return util.test_error.Incorrect;
    t.join();

    try util.expect(got_a == 0xAA);
    try util.expect(got_b == 0xBB);
    try util.expect(got_c == 0xCC);
}

// Cooperative scheduling: every increment must survive the yields in between.

var bump_count: u64 = 0;

fn bumper(rounds: u64) anyerror!void {
    for (0..rounds) |_| {
        bump_count += 1;
        Thread.yield();
    }
}

fn interleaved_counters() anyerror!void {
    bump_count = 0;
    const rounds: u64 = 16;

    const t0 = Thread.spawn("bump0", @constCast(@ptrCast(&bumper)), rounds) orelse return util.test_error.Incorrect;
    const t1 = Thread.spawn("bump1", @constCast(@ptrCast(&bumper)), rounds) orelse return util.test_error.Incorrect;
    const t2 = Thread.spawn("bump2", @constCast(@ptrCast(&bumper)), rounds) orelse return util.test_error.Incorrect;

    t0.join();
    t1.join();
    t2.join();

    try util.expect(bump_count == 3 * rounds);
}

// A read-yield-write sequence loses updates unless the lock serializes it.

var shared: u64 = 0;
var shared_lock: wait.Lock = .new("thread test lock");

fn locked_adder(rounds: u64) anyerror!void {
    for (0..rounds) |_| {
        shared_lock.acquire();
        const v = shared;
        Thread.yield();
        shared = v + 1;
        shared_lock.release();
        Thread.yield();
    }
}

fn lock_exclusion() anyerror!void {
    shared = 0;
    const rounds: u64 = 8;

    const t0 = Thread.spawn("lock0", @constCast(@ptrCast(&locked_adder)), rounds) orelse return util.test_error.Incorrect;
    const t1 = Thread.spawn("lock1", @constCast(@ptrCast(&locked_adder)), rounds) orelse return util.test_error.Incorrect;

    t0.join();
    t1.join();

    try util.expect(shared == 2 * rounds);
    try util.expect(shared_lock.owner == null);
}

// A thread parked on a condition must wake on broadcast.

var waiter_parked = false;
var waiter_go = false;
var waiter_done = false;
var test_cond: wait.Condition = .{ .name = "thread test cond" };

fn cond_waiter() anyerror!void {
    waiter_parked = true;
    while (!waiter_go) test_cond.wait();
    waiter_done = true;
}

fn condition_wakeup() anyerror!void {
    waiter_parked = false;
    waiter_go = false;
    waiter_done = false;

    const t = Thread.spawn("waiter", @constCast(@ptrCast(&cond_waiter))) orelse return util.test_error.Incorrect;

    var spins: usize = 0;
    while (!waiter_parked and spins < 1000) : (spins += 1) Thread.yield();
    try util.expect(waiter_parked);
    try util.expect(!waiter_done);

    waiter_go = true;
    test_cond.broadcast();
    t.join();

    try util.expect(waiter_done);
}

// Joining a child that already exited must return immediately.

fn nop_thread() anyerror!void {}

fn join_after_exit() anyerror!void {
    const t = Thread.spawn("quick", @constCast(@ptrCast(&nop_thread))) orelse return util.test_error.Incorrect;

    var spins: usize = 0;
    while (t.state != .exited and spins < 1000) : (spins += 1) Thread.yield();
    try util.expect(t.state == .exited);

    t.join();
}
