const std = @import("std");
const builtin = @import("builtin");

pub fn assert(ok: bool, comptime message: []const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (!ok) {
            std.debug.panic( "0x{X} -> assert failed: {s}",
                .{@returnAddress(), message}
            );
        }
    }
}
