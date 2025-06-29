const uart = @import("./dev/uart.zig");

const console: *uart.uart = uart.uart0;

pub const severity = enum {
    success,
    debug,
    info,
    warn,
    err,
    panic,
};

pub fn log(level: severity, message: []const u8) void {
    // TODO:
    console.puts(switch (level) {
        .success => "[✅]",
        .debug => "[🐞]",
        .info => "[ℹ️]",
        .warn => "[⚠️]",
        .err => "[🚨]",
        .panic => "[💀]"
    } ++ message);
}
