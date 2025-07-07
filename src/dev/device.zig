const std = @import("std");
const config = @import("../config.zig");
const IO = @import("../api/io.zig");

const device_type = enum {
    other,
    sound,
    network,
    graphics,
    filesystem,
};

const device = struct {
    name: []const u8,
    open_fn: *const fn (*anyopaque) IO.Error!*IO,
    aux: *anyopaque,
    devtype: device_type = .other,
};

var devtab: [config.NDEV]?device = [_]?device{null} ** config.NDEV;

const Error = error {
    NoSpace
};

pub var initialized = false;
pub fn init() void {
    std.debug.assert(initialized == false);

    initialized = true;
}

pub fn register(dev: device) Error!u32 {
    for (devtab, 0..) |cur, i| {
        if (cur == null) {
            devtab[i] = dev;
            return @intCast(i);
        }
    }
    return Error.NoSpace;
}
