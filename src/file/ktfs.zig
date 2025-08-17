const std = @import("std");
const IO = @import("../api/io.zig");
const log = std.log.scoped(.KTFS);
const DLL = @import("../util/list.zig").DLL;
const assert = @import("../util/debug.zig").assert;
const heap = @import("../mem/heap.zig");

const Cache = @import("./cache.zig");

pub const BLKSZ = 512;
pub const INOSZ = 32;
pub const DENSZ = 16;

const MAX_FNAME_SIZE = DENSZ - 3;

const N_DIRECT = 3;
const N_INDIRECT = 1;
const N_DINDIRECT = 2;

const perDIR = BLKSZ;
const perINDIR = (BLKSZ / @sizeOf(u32)) * perDIR;
const perDINDIR = (BLKSZ / @sizeOf(u32)) * perINDIR;

const DIR_CAP = N_DIRECT * perDIR;
const INDIR_CAP = N_INDIRECT * perINDIR;
const DINDIR_CAP = N_DINDIRECT * perDINDIR;

// Physical Types
//

const Superblock = packed struct {
    block_count: u32,
    bitmap_block_count: u32,
    inode_block_count: u32,
    root_directory_inode: u16
};

/// Shouldn't have any padding. Compiler got angry at packed
const Inode = extern struct {
    size: u32,
    flags: u32,
    direct: [N_DIRECT]u32,
    indirect: [N_INDIRECT]u32,
    dindirect: [N_DINDIRECT]u32,
};

/// Shouldn't have any padding
const Dentry = extern struct {
    inode: u16,
    name: [MAX_FNAME_SIZE - 1 : 0]u8
};

const BitMapBlock = packed struct {
    bits: [8 * BLKSZ]bool = [_]bool{false} ** (8 * BLKSZ)
};

const DataBlock = packed struct {
    bytes: [BLKSZ]u8
};

// Software Structs
//

const features = enum {

};

pub const File = struct {
    io: IO = .new0(.{
        .cntl = File.cntl,
        .close = File.close,
        .readat = File.readat,
        .writeat = File.writeat,
    }),
    size: u32,
    dentry: Dentry,
    flags: u16,
    pos: u64,

    fs: *KTFS,

    next: ?*File,
    prev: ?*File,

    fn readat(io: *IO, buf: []u8, pos: u64) IO.Error!usize {

    }

    fn writeat(io: *IO, buf: []const u8, pos: u64) IO.Error!usize {

    }

    fn close(io: *IO) void {

    }

    fn cntl(io: *IO, cmd: i32, arg: ?*anyopaque) IO.Error!isize {
        const self: *File = @fieldParentPtr("io", io);
        switch (cmd) {
            IO.IOCTL_GETEND => return @intCast(self.size),
            // IO
            else => return IO.Error.Unsupported,
        }
    }

};


const DentryL = struct {
    dentry: Dentry,
    next: ?*DentryL,
    prev: ?*DentryL,
};

const KTFS = @This();

superblock: Superblock,
root_inode: Inode,
cwd_inode: Inode,
all_files: DLL(DentryL),
open_files: DLL(File),
io: IO = .new0(.{
    .cntl = KTFS.cntl,
    .close = KTFS.close,
    .readat = KTFS.readat,
    .writeat = KTFS.writeat,
}),
cache: Cache,
big_blk: [BLKSZ]u8,
allocator: std.mem.Allocator = heap.allocator,


// IO ENDPOINTS
//

fn open(aux: *anyopaque) *IO {
    const ktfs: *KTFS = @ptrCast(aux);
    return &ktfs.io;
}

fn cntl(io: *IO, cmd: i32, arg: ?*anyopaque) IO.Error!isize {
    const self: *KTFS = @fieldParentPtr("io", io);

    switch (cmd) {
        IO.IOCTL_GETBLKSZ => return BLKSZ,
        IO.IOCTL_GETEND => return self.cache.bkgio.cntl(IO.IOCTL_GETEND, arg),
    }
}


fn close(io: *IO) void {
}

fn readat(io: *IO, buf: []u8, pos: u64) IO.Error!usize {

}

fn writeat(io: *IO, buf: []const u8, pos: u64) IO.Error!usize {

}

// INTERNAL HELPERS
//

const block_error = (std.mem.Allocator.Error || IO.Error);

fn bitmap_modify(self: *KTFS, pos: u64, used: bool) block_error!void {
    assert((pos & (BLKSZ-1)) == 0, "must be block aligned!");
    const bitpos = 1 + pos / (8 * BLKSZ * BLKSZ);

    const blk: []u8 = try self.cache.get(blkno * BLKSZ);
    const bitblk: *BitMapBlock = @ptrCast(blk.ptr[0]);
    defer self.cache.release(blk, true);

    bitblk.bits[pos % (8 * BLKSZ)] = used;
}

const BlockLevel = enum(u8) {
    direct = 0,
    indirect = 1,
    dindirect = 2
};

fn dealloc_block(self: *KTFS, pos: u64, level: BlockLevel) block_error!void {
    assert(pos > 0, "Cannot deallocate superblock!");
    assert((pos & (BLKSZ-1)) == 0, "must be block aligned!");

    const lvl: u8 = @intFromEnum(level);

    // Free contained blocks
    if (lvl > 0) {
        const blk: []u64 = @ptrCast(try self.cache.get_const(pos));
        defer self.cache.release(blk, false);

        for (blk) |blkpos| {
            if (blkpos > 0)
                try dealloc_block(self, blkpos, @enumFromInt(lvl-1))
        }
    }

    // Free this block
    try self.bitmap_modify(pos, false);
}
