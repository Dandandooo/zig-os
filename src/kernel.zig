//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const main = @import("main.zig").main;
const std = @import("std");
const builtin = @import("builtin");
const console = @import("./console.zig");

const ALIGN = 1 << 0;
const MEMINFO = 1 << 1;
const MAGIC = 0x1BADB002;
const FLAGS = ALIGN | MEMINFO;

const MultibootHeader = packed struct {
    magic: i32 = MAGIC,
    flags: i32,
    checksum: i32,
    padding: u32 = 0,
};

export var multiboot: MultibootHeader align(4) linksection(".multiboot") = .{
    .flags = FLAGS,
    .checksum = -(MAGIC + FLAGS),
};

// Entry point for the freestanding kernel
export fn _start() callconv(.{ .riscv64_lp64 = .{} }) noreturn {
    main();
    @panic("Job done, kernel exited");
}

pub const panic = std.debug.FullPanic(panicFn);

pub fn panicFn(message: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    std.log.scoped(.PANIC).err("{s}", .{message});
    while (true) {}
}

// Kernel-wide Options
pub const std_options = std.Options{
    .page_size_max = 4096,
    .page_size_min = 4096,

    .logFn = console.log,
    .log_level = .debug,
};
