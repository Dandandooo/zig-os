//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
pub const main = @import("main.zig").main;
const std = @import("std");
const builtin = @import("builtin");
const console = @import("./console.zig");

const ALIGN: u32 = 1 << 0;
const MEMINFO: u32 = 1 << 1;
const MAGIC: u32 = 0x1BADB002;
const FLAGS: u32 = ALIGN | MEMINFO;

extern fn halt_success() noreturn;
extern fn halt_failure() noreturn;

const MultibootHeader = packed struct(u128) {
    magic: u32 = MAGIC,
    flags: u32,
    checksum: u32,
    padding: u32 = 0,
};

export var multiboot: MultibootHeader align(4) linksection(".multiboot") = .{
    .flags = FLAGS,
    .checksum = 0 -% (MAGIC + FLAGS),
};

/// Entry point for the freestanding kernel.
/// Shutdown is only successful upon completion of main().
export fn _start() callconv(.{ .riscv64_lp64 = .{} }) noreturn {
    main();
    exit(true);
}

pub const panic = std.debug.FullPanic(panicFn);

/// Prints panic messages to the QEMU Console UART,
/// then exits with failure.
pub fn panicFn(message: []const u8, first_trace: ?usize) noreturn {
    @branchHint(.cold);

    std.log.scoped(.PANIC).err("{s}", .{message});
    if (first_trace) |trace_addr| {
        std.log.scoped(.CAUSE).err("Trace Address: 0x{X}", .{trace_addr});
    } else {
        std.log.scoped(.CAUSE).err("NO STACK TRACE", .{});
    }
    crash();
}

pub fn crash() noreturn {
    exit(false);
}

pub fn shutdown() noreturn {
    exit(true);
}

/// Interfaces with QEMU to execute kernel shutdown.
/// Magic numbers provided by UIUC's ECE 391 (idk where they got them).
fn exit(comptime success: bool) noreturn {
    @branchHint(.cold);

    console.icon_println("💀", "KILLED", "{s}\x1b[0m", .{if (success) "\x1b[32msuccess" else "\x1b[31mfailure"});

    asm volatile (
        \\ li a7, %[halt_eid]
        \\ li a6, %[exit_code]
        \\ ecall
        :
        : [halt_eid] "i" (0x0A484c54),
          [exit_code] "i" (@intFromBool(!success)),
        : .{ .x16 = true, .x17 = true });

    while (true) {}
}

/// Kernel-wide Options
pub const std_options = std.Options{
    .page_size_max = 4096,
    .page_size_min = 4096,

    .logFn = console.log,

    // .log_level = .err,
    .log_scope_levels = &.{
        .{ .scope = .PLIC, .level = .info }, // Don't need debug here anymore
        .{ .scope = .PAGE, .level = .info },
        // .{.scope = .WAIT, .level = .info},
    },
};
