//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");

const io = @import("api/io.zig");

const intr = @import("cntl/intr.zig");
const excp = @import("cntl/excp.zig");
const cons = @import("console.zig");

const thread = @import("conc/thread.zig");
const process = @import("conc/process.zig");

const dev = @import("dev/device.zig");

const vmem = @import("mem/vmem.zig");

pub fn main() void {
    cons.init();
    intr.init();
    excp.init();
    dev.init();

    thread.init();

    // vmem.init(); // FIXME


}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
