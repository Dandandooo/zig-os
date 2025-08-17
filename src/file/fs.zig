const KTFS = @import("./ktfs.zig");
const EXT2 = @import("./ext2.zig");
const BTRFS = @import("./btrfs.zig");

const std = @import("std");
const log = std.log.scoped(.FILES);
const assert = @import("../util/debug.zig").assert;

const FS = @This();

fs_type: FsType,


pub const Error = error {
    NotFound,
    Busy,
    Invalid,
};

pub const FsType = enum {
    fat,
    ktfs,
    ext2,
    ntfs,
    btrfs,
};

pub fn query_fs_type(fs: FsType) type {
    return switch (fs) {
        .ktfs => KTFS,
        .ext2 => EXT2,
        .btrfs => BTRFS,
    };
}

pub fn print_fs_sizes() void {
    inline for (comptime std.enums.values(FsType)) |f| {
        const T = query_fs_type(f);
        log.debug("{s}: {d} bytes", .{@tagName(f), @sizeOf(T)});
    }
}

pub fn mount(t: FsType, aux: *anyopaque) Error!void {
    const T = query_fs_type(t);
    assert(@hasDecl(T, "mount"), "unmountable filesystem");
    assert(@TypeOf(T.mount) == fn (*anyopaque) Error!void, "invalid mount function");

    return T.mount(aux);
}
