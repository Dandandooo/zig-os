const std = @import("std");
const dev = @import("../dev/device.zig");
const IO = @import("../api/io.zig");

const RBFS = @import("./rbfs.zig");
const KTFS = @import("./ktfs.zig");


const log = std.log.scoped(.FILES);

const FS = @This();

fs_type: FsType,
impl: Impl,

pub const Error = RBFS.Error || dev.Error;

pub const FsType = enum {
    rbfs,
    ktfs,
};

const Impl = union(FsType) {
    rbfs: *RBFS,
    ktfs: *KTFS,
};

pub fn print_fs_sizes() void {
    inline for (comptime std.enums.values(FsType)) |fs_type| {
        const T = query_fs_type(fs_type);
        log.debug("{s}: {d} bytes", .{ @tagName(fs_type), @sizeOf(T) });
    }
}

pub fn query_fs_type(fs_type: FsType) type {
    return switch (fs_type) {
        .rbfs => RBFS,
        .ktfs => KTFS,
    };
}

pub fn mount(fs_type: FsType, bkgio: *IO, allocator: std.mem.Allocator) Error!FS {
    return switch (fs_type) {
        .rbfs => .{
            .fs_type = .rbfs,
            .impl = .{ .rbfs = try RBFS.mount(bkgio, allocator) },
        },
    };
}

pub fn mount_device(fs_type: FsType, device_name: []const u8, allocator: std.mem.Allocator) Error!FS {
    const bkgio = try dev.open(device_name);
    errdefer bkgio.close();

    const filesystem = try mount(fs_type, bkgio, allocator);
    bkgio.close();
    return filesystem;
}

pub fn deinit(self: *FS) void {
    switch (self.impl) {
        .rbfs => |rbfs| rbfs.deinit(),
    }
}

pub fn open(self: *FS, name: []const u8) Error!*IO {
    return switch (self.impl) {
        .rbfs => |rbfs| rbfs.open(name),
    };
}

pub fn create(self: *FS, name: []const u8) Error!void {
    return switch (self.impl) {
        .rbfs => |rbfs| rbfs.create(name),
    };
}

pub fn delete(self: *FS, name: []const u8) Error!void {
    return switch (self.impl) {
        .rbfs => |rbfs| rbfs.delete(name),
    };
}

pub fn flush(self: *FS) IO.Error!void {
    return switch (self.impl) {
        .rbfs => |rbfs| rbfs.flush(),
    };
}

pub fn filecount(self: *FS) usize {
    return switch (self.impl) {
        .rbfs => |rbfs| rbfs.filecount(),
    };
}

pub fn get_files(self: *FS, buf: []u8) Error!usize {
    return switch (self.impl) {
        .rbfs => |rbfs| rbfs.get_files(buf),
    };
}
