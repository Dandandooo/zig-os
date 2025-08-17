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

pub const Error = error {
    Unsupported,
    NotFound,
    NoSpace,
    Busy,
};

pub var initialized = false;
pub fn init() void {
    assert(initialized == false, "devmgr already initialized!");

    log.info("initialized", .{});
    initialized = true;
}

pub fn register(name: []const u8, open_fn: *const fn (*anyopaque) IO.Error!*IO, aux: *anyopaque) Error!u32 {
    return for (devtab, 0..) |cur, i| {
        if (cur == null) {
            devtab[i] = .{ .name = name, .open_fn = open_fn, .aux = aux };
            break @intCast(i);
        }
    } else Error.NoSpace;
}

pub fn open(name: []const u8) (IO.Error || Error)!*IO {
    return for (&devtab) |*maybe| {
        if (maybe.*) |*dev|
            if (std.mem.eql(u8, name, dev.name))
                break dev.open_fn(dev.aux);
    } else Error.NotFound;
}
