const std = @import("std");
const gay = @import("build_options").gay;
const Uart = @import("./dev/uart.zig");
const intr = @import("./cntl/intr.zig");
const dev = @import("./dev/device.zig");
const Io = @import("./api/io.zig");
const assert = @import("./util/debug.zig").assert;

const writer = std.io.AnyWriter{ .context = undefined, .writeFn = writefn };

pub var initialized = false;
pub fn init() void {
	assert(initialized == false, "console already initialized!");

	Uart.uart0_init();

	initialized = true;
	std.log.scoped(.CONSOLE).info("initialized", .{});
	struct_log(
		.debug, .CONSOLE, "testing struct",
		.{"test_int: {d}", "test_hex: 0x{X}", "test_ptr: {p}"}, .{123, 160, &&writer}
	);
}

fn writefn(_: *const anyopaque, message: []const u8) anyerror!usize {
	assert(initialized == true, "where are you printing to?");
	for (message) |c|
		Uart.console_putc(c);
	return message.len;
}

pub fn print(comptime format: []const u8, args:anytype) void {
	writer.print(format, args) catch @panic("couldn't print!");
}

const chroma= [_][]const u8{"31", "38;5;216", "33", "32", "36", "34", "38;5;183", "35"};
var chroma_idx: usize = 0;

pub fn icon_print(
	comptime icon: []const u8,
	comptime scope: ?[]const u8,
	comptime format: []const u8,
	args: anytype
) void {
	const header, const head_args = if (scope) |name|
		.{"{s}\x1b[90;1m:\x1b[0;{s}m {s:<9} \x1b[34m>>\x1b[0m ", .{icon, if (gay) chroma[chroma_idx] else "33", name}}
		else .{"{s}\x1b[0;34m>>\x1b[0m ", .{icon}};

	chroma_idx = (chroma_idx + 1) % chroma.len;

	writer.print(header ++ format ++ "\n", head_args ++ args) catch @panic("print'nt");
}

pub fn log(
	comptime level: std.log.Level,
	comptime scope: @TypeOf(.EnumLiteral),
	comptime format: []const u8,
	args: anytype
) void {
	icon_print(switch (level) {
		.debug => "🐞",
		.info => "ℹ️ ",
		.warn => "⚠️ ",
		.err => "🚨",
	}, if (scope == .default) null else @tagName(scope), format, args);
}

pub fn struct_log(
	comptime level: std.log.Level,
	comptime scope: @TypeOf(.EnumLiteral),
	comptime message: []const u8,
	comptime fields: anytype,
	values: anytype
) void {
	log(level, scope, message, .{});
	inline for (fields, values) |field, value| {
		writer.print("               \x1b[35m>>\x1b[0m " ++ field ++ "\n", .{value}) catch @panic("struct print'nt");
	}
}
