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

extern fn halt_success() noreturn;
extern fn halt_failure() noreturn;

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
    shutdown(true);
}

pub const panic = std.debug.FullPanic(panicFn);

pub fn panicFn(message: []const u8, first_trace: ?usize) noreturn {
    @branchHint(.cold);

    std.log.scoped(.PANIC).err("{s}", .{message});
    if (first_trace) |trace_addr| {
        std.log.scoped(.CAUSE).err("Trace Address: 0x{X}", .{trace_addr});
    } else {
        std.log.scoped(.CAUSE).err("NO STACK TRACE", .{});
    }
    shutdown(false);
}

pub fn shutdown(comptime success: bool) noreturn {
    @branchHint(.cold);

    console.icon_print("💀", "KILLED", "{s}\x1b[0m", .{if (success) "\x1b[32msuccess" else "\x1b[31mfailure"});

    asm volatile (
        \\ li a7, %[halt_eid]
        \\ li a6, %[exit_code]
        \\ ecall
        :
        : [halt_eid] "i" (0x0A484c54),
          [exit_code] "i" (@intFromBool(!success))
        : "a6", "a7"
    );

    while (true) {}
}

// Kernel-wide Options
pub const std_options = std.Options{
    .page_size_max = 4096,
    .page_size_min = 4096,

    .logFn = console.log,

    // .log_level = .err,
    .log_scope_levels = &.{
        // .{.scope = .PLIC, .level = .info}, // Don't need debug here anymore
    },
};
