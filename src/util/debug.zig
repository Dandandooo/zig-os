const std = @import("std");
const builtin = @import("builtin");

pub inline fn assert(ok: bool, comptime message: ?[]const u8) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (!ok) {
            const src = @src();
            if (message) |msg| {
                @panic(std.fmt.comptimePrint(
                    "{s}:{d} -> assert failed: {s}",
                    .{src.file, src.line, msg}
                ));
            }
            else
                @panic(std.fmt.comptimePrint(
                    "{s}:{d} -> assert failed",
                    .{src.file, src.line}
                ));
        }
    }
}
