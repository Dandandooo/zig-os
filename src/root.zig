//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const main = @import("main.zig").main;

// Entry point for the freestanding kernel
pub export fn _start() noreturn {
    // Halt the CPU in an infinite loop
    // while (true) {}
    main();
}
