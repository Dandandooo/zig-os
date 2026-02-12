const std = @import("std");
const IO = @import("../api/io.zig");
const dev = @import("./device.zig");
const log = @import("std").log.scoped(.RTC);
const heap = @import("../mem/heap.zig");
const assert = @import("../util/debug.zig").assert;
const config = @import("../config.zig");

const rtc_regs = extern struct { time_low: u32, time_high: u32, alarm_low: u32, alarm_high: u32, clear_interrupt: u32 };

const rtc_device = @This();

const BLKSZ = 8;

regs: *volatile rtc_regs,
instno: u32,
io: IO = .from(rtc_device),

// Exported functions
pub fn attach(mmio_base: *volatile rtc_regs) (dev.Error || std.mem.Allocator.Error)!void {
	const rtcdev: *rtc_device = try heap.allocator.create(rtc_device);
	rtcdev.* = .{
		.regs = mmio_base,
		.instno = try dev.register("rtc", open, rtcdev),
	};
}

fn open(aux: *anyopaque) IO.Error!*IO {
	return @as(*rtc_device, @alignCast(@ptrCast(aux))).io.addref();
}

/// IOCTL for RTC, currently only supports GETBLKSZ
pub fn cntl(_: *IO, cmd: i32, _: ?*anyopaque) IO.Error!isize {
	log.debug("ioctl, cmd={d}", .{cmd});
	return switch (cmd) {
		IO.IOCTL_GETBLKSZ => BLKSZ,
		else => IO.Error.Unsupported
	};
}

/// Reads real time into appropriately sized buffer
pub fn read(io: *IO, buf: []u8) IO.Error!usize {
	assert(buf.len == BLKSZ, "mis-sized read");
	assert((@intFromPtr(buf.ptr) & 3 == 0), "mis-aligned read");
	const buf32 = @as([*]u32, @ptrCast(@alignCast(buf.ptr)))[0..2];
	const self: *rtc_device = @fieldParentPtr("io", io);
	buf32.* = [2]u32{self.regs.time_low, self.regs.time_high};
	return BLKSZ;
}

pub fn time() u64 {
	const regs: *volatile rtc_regs = @ptrFromInt(config.RTC_MMIO_BASE);
	const lower: u64 = @intCast(regs.time_low);
	const upper: u64 = @intCast(regs.time_high);
	return (upper << 32) | lower;
}

pub fn log_time() void {
	log_time_zone(.UTC);
}

// NOTE: Does not account for daylight savings time
pub const TimeZone = enum {
	PST,
	CST,
	CDT,
	EST,
	EDT,
	UTC,
	GMT,
	CET,
	EET,

	fn offset(self: TimeZone) i8 {
		return switch (self) {
			.PST => -8,
			.CST => -6,
			.CDT,
			.EST => -5,
			.EDT => -4,
			.GMT,
			.UTC => 0,
			.CET => 1,
			.EET => 2,
		};
	}
};

pub fn log_time_zone_str(name: []const u8) void {
	log_time_zone(std.meta.stringToEnum(TimeZone, name) orelse .UTC);
}

pub fn log_time_zone(zone: TimeZone) void {
	const secs: u64 = time() / 1_000_000_000 % (24 * 3600);
	const mins: u64 = secs / 60;
	const hours: u64 = @as(u64, @intCast((@as(i64, @intCast(mins / 60 + 24))) + zone.offset())) % 24;
	log.info("Current Time: {d:>2}:{d:0>2}:{d:0>2} {s} {s}",
	.{(hours + 11) % 12 + 1, mins % 60, secs % 60, if (hours > 11) "PM" else "AM", @tagName(zone)});
}

pub fn log_all_zones() void {
	inline for (comptime std.enums.values(TimeZone)) |zone| {
		log_time_zone(zone);
	}
}
