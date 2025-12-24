const std = @import("std");
const IO = @import("../api/io.zig");
const log = std.log.scoped(.KTFS);
const DLL = @import("../util/list.zig").DLL;
const assert = @import("../util/debug.zig").assert;
const heap = @import("../mem/heap.zig");

const Cache = @import("./cache.zig");

pub const ORDER = 9;
pub const BLKSZ = 1 << ORDER;
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
        const self: *File = @fieldParentPtr("io", io);
        if (buf.len + pos > self.size)
            return IO.Error.Invalid;



    }

    fn writeat(io: *IO, buf: []const u8, pos: u64) IO.Error!usize {
        const self: *File = @fieldParentPtr("io", io);
        if (buf.len + pos > self.size)
            return IO.Error.Invalid;

    }

    fn close(io: *IO) void {
        const self: *File = @fieldParentPtr("io", io);
        assert(self.fs.open_files.find(self) != null, "file not open");

    }

    fn cntl(io: *IO, cmd: i32, arg: ?*anyopaque) IO.Error!isize {
        const self: *File = @fieldParentPtr("io", io);
        switch (cmd) {
            IO.IOCTL_GETBLKSZ => return BLKSZ,
            IO.IOCTL_GETEND => return @intCast(self.size),
            IO.IOCTL_SETEND => {
                const target_size: usize = @intFromPtr(arg);
                if (target_size < self.size)
                    return IO.Error.Invalid;

            },
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
allocator: std.mem.Allocator,



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

// INTERNAL HELPERS
//

const Error = error {
    NoEntry,
    Full
};
const block_error = std.mem.Allocator.Error || IO.Error;
const get_error = block_error || Error;

fn find_free(self: *KTFS) get_error!u64 {
    return outer: for (1..1+self.superblock.bitmap_block_count) | i | {
        // Larger size for more granular search
        const blk: []u64 = @ptrCast(try self.cache.get_const(i << ORDER));
        for (0.., blk) | j, range | {
            if (~range > 0) {
                for (0.., @as([8]u8, @bitCast(range))) |k, byte| {
                    if (~byte > 0) {
                        inline for (0..8) |l| {
                            if ((1 << k) & ~byte){
                                // Give branch hint since
                                @branchHint(.unlikely);
                                break :outer ((i-1) << ORDER) + (j << 6) + (k << 3) + l;
                            }
                        }
                    }
                }
            }
        }
    } else Error.Full;
}

fn bitmap_modify(self: *KTFS, pos: u64, used: bool) block_error!void {
    assert((pos & (BLKSZ-1)) == 0, "must be block aligned!");
    const blkno = pos >> ORDER;
    const bitno = 1 + (blkno >> ORDER);

    const blk: []u8 = try self.cache.get(bitno << ORDER);
    defer self.cache.release(blk);

    const bitblk: *BitMapBlock = @ptrCast(blk.ptr[0]); // ([*]u8)[0] -> *BitMapBlock
    bitblk.bits[pos % (8 << ORDER)] = used;
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
                try dealloc_block(self, blkpos, @enumFromInt(lvl-1));
        }
    }

    // Free this block
    try self.bitmap_modify(pos, false);
}
