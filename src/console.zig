const std = @import("std");
const Uart = @import("./dev/uart.zig");
const intr = @import("./cntl/intr.zig");
const dev = @import("./dev/device.zig");
const Io = @import("./api/io.zig");

const writer = std.io.AnyWriter{ .context = &Uart.uart0, .writeFn = writefn };

pub var initialized = false;
pub fn init() void {
    std.debug.assert(initialized == false);

    Uart.uart0.instno = dev.register(.{.name = "stdout", .open_fn = Uart.open, .aux = @ptrCast(&Uart.uart0)})
    catch unreachable;

    initialized = true;
}

fn writefn(aux: *const anyopaque, message: []const u8) anyerror!usize {
    const device: *Uart = @ptrCast(@constCast(@alignCast(aux)));
    return device.io.write(message);
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype
) void {
    const status = switch (level) {
        .debug => "🐞",
        .info => "ℹ️",
        .warn => "⚠️",
        .err => "🚨",
    };

    const header, const head_args = switch (scope) {
        .default => .{"[{s}] >> ", .{status}},
        else => .{"[{s}] : {s} >> ", .{status, @tagName(scope)}}
    };

    writer.print(header ++ format ++ "\n", head_args ++ args) catch @panic("print'nt");
}
