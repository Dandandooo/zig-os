const std = @import("std");
const log = std.log.scoped(.THREAD);
const Thread = @import("../../conc/thread.zig");
const util = @import("../util.zig");

pub fn run() util.test_results {
    return util.run_tests("THREAD",
    .{
        .{"multi_print", multi_print},
    });
}

fn multi_print() !void {
    const t0: *Thread = try Thread.spawn("test0", print0);
    const t1: *Thread = try Thread.spawn("test1", print1, 2);
    const t2: *Thread = try Thread.spawn("test2", print2, "hello from thread", 3);

    t0.join();
    t1.join();
    t2.join();
}

fn print0() !void { log.debug("hello from thread 1", .{}); }
fn print1(tid: u32) !void { log.debug("hello from thread {d}", .{tid}); }
fn print2(msg: []const u8, tid: u32) !void { log.debug("{s} {d}", .{msg, tid}); }
