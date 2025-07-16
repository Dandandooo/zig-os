const std = @import("std");
const config = @import("../config.zig");
const IO = @import("../api/io.zig");
const assert = @import("../util/debug.zig").assert;
const log = std.log.scoped(.DEVICES);

const device_type = enum {
    other,
    sound,
    console,
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
    assert(initialized == false, "devmgr already initialized!");

    log.info("initialized", .{});
    initialized = true;
}

pub fn register(dev: device) Error!u32 {
    return for (devtab, 0..) |cur, i| {
        if (cur == null) {
            devtab[i] = dev;
            break @intCast(i);
        }
    } else Error.NoSpace;
}
