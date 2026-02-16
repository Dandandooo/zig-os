const std = @import("std");
const log = std.log.scoped(.THREAD);
const Thread = @import("../../conc/thread.zig");
const util = @import("../util.zig");

pub fn run() util.test_results {
    return util.run_tests("THREAD",
    &.{
        .{.name = "multi_print", .func = multi_print},
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
