const std = @import("std");
const reg = @import("../riscv/reg.zig");
const wait = @import("wait.zig");
const page = @import("../mem/page.zig");
const vmem = @import("../mem/vmem.zig");
const config = @import("../config.zig");

const assert = @import("../util/debug.zig").assert;

const IO = @import("../api/io.zig");
const Thread = @import("thread.zig");
const Process = @This();

// --------------------
// Definition & Globals
// --------------------

pid: u32,
tid: u32, // single managed thread
mtag: reg.satp,
iotab: [config.PROCESS_IOMAX]?*IO = [_]?*IO{null} ** config.PROCESS_IOMAX,
child: wait.Condition = .{ .name = "child exit"},

var main_proc: Process = .{ .pid = 0, .tid = Thread.main_tid, .mtag = undefined };

const proctab: [config.NPROC]?*Process = [_]?*Process{null} ** config.NPROC;

// --------------
// Initialization
// --------------

var initialized = false;
pub fn init() void {
    assert(!initialized, "Processes already initialized");
    defer initialized = true;

    main_proc.mtag = vmem.active_mspace();
    proctab[main_proc.pid] = &main_proc;
}
