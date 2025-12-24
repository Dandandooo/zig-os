//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");
const config = @import("config.zig");
// const tests = @import("tests.zig");
const build_options = @import("build_options");

const io = @import("api/io.zig");

const intr = @import("cntl/intr.zig");
const excp = @import("cntl/excp.zig");
const cons = @import("console.zig");

const thread = @import("conc/thread.zig");
const process = @import("conc/process.zig");

const heap = @import("mem/heap.zig");
const page = @import("mem/page.zig");
const vmem = @import("mem/vmem.zig");

// Devices
const dev = @import("dev/device.zig");
const rtc = @import("dev/rtc.zig");
// const fs = @import("file/fs.zig");


pub fn main() void {
    // Control
    cons.init();
    intr.init();
    excp.init();

    // Memory
    heap.init();



    // Concurrency
    thread.init();

    // Device Initialization
    dev.init();

    rtc.attach(@ptrFromInt(config.RTC_MMIO_BASE)) catch @panic("no time");

    // fs.print_fs_sizes();

    // vmem.init(); // FIXME


    rtc.log_time_zone(.EST);

    if (build_options.test_mode)
        return @import("tests/runner.zig").run();

}
