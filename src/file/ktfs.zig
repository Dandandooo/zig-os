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

const INLINED_SIZE = @sizeOf(u32) * (N_DIRECT + N_INDIRECT + N_DINDIRECT);

inline fn blk_pos_to_num(blkpos: u64) u32 { return blkpos >> ORDER; }
inline fn blk_num_to_pos(blknum: u32) u64 { return blknum << ORDER; }

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
    comptime { assert(@sizeOf(Inode) == INOSZ, "incorrectly sized inode"); }
    size: u32,
    flags: u32,
    data: extern union {
        blocks: extern struct {
            direct: [N_DIRECT]u32,
            indirect: [N_INDIRECT]u32,
            dindirect: [N_DINDIRECT]u32,
        },
        inlined: [INLINED_SIZE]u8
    },


    inline fn get_blockno(fs: *KTFS, num: u16) u64 {
        assert(fs.superblock.inode_block_count * (BLKSZ / INOSZ) > num, "out of bounds inode");
        return 1 + fs.superblock.bitmap_block_count + num / (BLKSZ / INOSZ);
    }

    fn fetch(fs: *KTFS, num: u16) Inode {
        const block = try fs.cache.get_const(BLKSZ * Inode.get_blockno(fs, num));
        defer fs.cache.release(block, .clean);
        return @as([]Inode, block)[num % (BLKSZ / INOSZ)];
    }

    fn write(fs: *KTFS, num: u16, inode: Inode) void {
        const block = try fs.cache.get(BLKSZ * Inode.get_blockno(fs, num));
        defer fs.cache.release(block, .dirty);
        @as([]Inode, block)[num % (BLKSZ / INOSZ)] = inode;
    }

    inline fn is_inlined(inode: Inode) bool {
        return inode.size <= INLINED_SIZE;
    }
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

const IndirectBlock = packed struct {
    blocks: [BLKSZ / @sizeOf(u32)]u32
};

// Software Structs
//

const features = enum {

};

pub const File = struct {
    io: IO = .from(File),
    size: u32,
    dentry: Dentry,
    flags: u16,
    pos: u64,

    fs: *KTFS,

    next: ?*File,
    prev: ?*File,

    const Operation = enum {
        readat,
        writeat,

        inline fn cache_effect(self: Operation) Cache.Release {
            return switch (self) {
                .readat => .clean,
                .writeat => .dirty,
            };
        }
    };

    pub fn readat(io: *IO, buf: []u8, pos: u64) IO.Error!usize {
        return File._interact(io, @constCast(buf), pos, .readat);
    }

    pub fn writeat(io: *IO, buf: []const u8, pos: u64) IO.Error!usize {
        return File._interact(io, @constCast(buf), pos, .writeat);
    }

    pub fn close(io: *IO) void {
        const self: *File = @fieldParentPtr("io", io);
        assert(self.fs.open_files.find(self) != null, "file not open");

        self.fs.allocator.destroy(self.fs.open_files.pop(self).?);
    }

    pub fn cntl(io: *IO, cmd: i32, arg: ?*anyopaque) IO.Error!isize {
        const self: *File = @fieldParentPtr("io", io);
        switch (cmd) {
            IO.IOCTL_GETBLKSZ => return BLKSZ,
            IO.IOCTL_GETEND => return @intCast(self.size),
            IO.IOCTL_SETEND => {
                const target_size: usize = @intFromPtr(arg);
                if (target_size < self.size)
                    return IO.Error.Invalid;

                const inode: Inode = Inode.fetch(self.fs, self.dentry.inode);
                defer {
                    inode.size = target_size;
                    Inode.write(self.fs, self.dentry.inode, inode);
                }

                var allocated: usize = 0;

                if (inode.is_inlined()) {
                    if (target_size < INLINED_SIZE)
                        return target_size;

                    const blkpos = try self.fs.find_free();

                    const blk = try self.fs.cache.get(blkpos);
                    defer self.fs.cache.release(blk, .dirty);

                    // Modify after you are sure you can write
                    try self.fs.bitmap_modify(blkpos, true);

                    @memcpy(blk, inode.data.inlined);

                    inode.data.blocks[0] = blk_pos_to_num(blkpos);

                    @memset(inode.data.inlined[@sizeOf(u32)..], 0);

                    allocated += BLKSZ;
                }

                // Fill in direct blocks
                for (inode.data.blocks.direct) |*blkno| {
                    if (allocated >= target_size)
                        break;

                    if (blkno.* != 0)
                        continue;

                    const blkpos = try self.fs.find_free();
                    try self.fs.bitmap_modify(blkpos, true);

                    blkno.* = blk_pos_to_num(blkpos);

                    allocated += BLKSZ;
                }

                // Fill in indirect blocks
                for (inode.data.blocks.indirect) |*blkno| {
                    if (allocated >= target_size)
                        break;

                    if (blkno.* != 0)
                        continue;

                    const blkpos = try self.fs.find_free();
                    try self.fs.bitmap_modify(blkpos, true);

                    blkno.* = blk_pos_to_num(blkpos);
                }

                // Fill in dindirect blocks
                for (inode.data.blocks.dindirect) |*blkno| {
                    if (allocated >= target_size)
                        break;

                    if (blkno.* != 0)
                        continue;

                    const blkpos = try self.fs.find_free();
                    try self.fs.bitmap_modify(blkpos, true);

                    blkno.* = blk_pos_to_num(blkpos);
                }

                return target_size;
            },
            else => return IO.Error.Unsupported,
        }
    }

    fn _interact(io: *IO, buf: []u8, pos: u64, op: File.Operation) IO.Error!usize {
        const self: *File = @fieldParentPtr("io", io);
        if (buf.len + pos > self.size)
            return IO.Error.Invalid;

        const inode = Inode.fetch(self.fs, self.dentry.inode);

        if (inode.is_inlined()) {
            switch (op) {
                .readat => @memcpy(buf, inode.data.inlined[pos..]),
                .writeat => @memcpy(inode.data.inlined[pos..], buf),
            }
            return buf.len;
        }


        var cursor: usize = 0;
        var start: u64 = pos;

        while (cursor < buf.len) {
            if (start < DIR_CAP) {
                if (start + buf.len >= DIR_CAP) {
                    try self._interact_direct(buf[cursor..(start + buf.len - DIR_CAP)], start, op);
                    cursor += start + buf.len - DIR_CAP;
                } else {
                    try self._interact_direct(buf[cursor..], start, op);
                    break;
                }
            } else if (start < INDIR_CAP) {
                if (start + buf.len >= INDIR_CAP) {
                    try self._interact_indirect(buf[cursor..(start + buf.len - INDIR_CAP)], start, op);
                    cursor += start + buf.len - INDIR_CAP;
                } else {
                    try self._interact_indirect(buf[cursor..], start, op);
                    break;
                }
            } else if (start < DINDIR_CAP) {
                assert(start + buf.len < DINDIR_CAP, "file too big");

                try self._interact_dindirect(buf[cursor..], start, op);
                cursor = buf.len;
                break;
            } else @panic("above and beyond...");
            start = pos + @as(u64, cursor);
        }

        return buf.len;
    }

    // pos is the position in the file system
    fn _interact_direct(self: *File, blkno: u32, buf: []u8, pos: u64, op: File.Operation) IO.Error!void {
        assert(pos + buf.len <= perDIR, "interacting oob");

        const blk = try self.fs.cache.get(blkno * BLKSZ);
        defer self.fs.cache.release(blk, op.cache_effect());

        switch (op) {
            .readat => @memcpy(buf, blk[pos..]),
            .writeat => @memcpy(blk[pos..], buf),
        }
    }

    fn _interact_indirect(self: *File, blkno: u32, buf: []u8, pos: u64, op: File.Operation) IO.Error!void {
        assert(pos > DIR_CAP, "shouldn't be interacting here");
        assert(pos + buf.len <= perINDIR, "interacting oob (indirectly)");

        const iblk: []u32 = @ptrCast(try self.fs.cache.get(blkno * BLKSZ));
        defer self.fs.cache.release(iblk);

        const inner_pos = pos - DIR_CAP;
        const start_idx = std.mem.alignBackward(u64, inner_pos, perDIR);
        const end_idx = std.mem.alignForward(u64, inner_pos + buf.len, perDIR);

        var start = pos;
        var end = pos + perDIR - (pos % perDIR);
        var cursor: usize = 0;

        for (start_idx..end_idx-1) |i| {
            const next_cursor: usize = cursor + perDIR - (pos % perDIR);
            _interact_direct(self, iblk[i], buf[cursor..next_cursor], start, op);
            cursor = next_cursor;
            start = end;
            end = start + perDIR - (start % perDIR);
        }
        _interact_direct(self, iblk[end_idx-1], buf[cursor..], start, op);

    }

    fn _interact_dindirect(self: *File, blkno: u32, buf: []u8, pos: u64, op: File.Operation) IO.Error!void {
        assert(pos > INDIR_CAP, "shouldn't be interacting here");
        assert(pos + buf.len <= perDINDIR, "interacting oob (dindirectly)");

        const iiblk: []u32 = @ptrCast(try self.fs.cache.get(blkno * BLKSZ));
        defer self.fs.cache.release(iiblk);

        const inner_pos = pos - INDIR_CAP;
        const start_idx = std.mem.alignBackward(u64, inner_pos, perINDIR);
        const end_idx = std.mem.alignForward(u64, inner_pos + buf.len, perINDIR);

        var start = pos;
        var end = pos +  - (pos % perINDIR);
        var cursor: usize = 0;

        for (start_idx..end_idx-1) |i| {
            const next_cursor: usize = cursor + perINDIR - (pos % perINDIR);
            _interact_indirect(self, iiblk[i], buf[cursor..next_cursor], start, op);
            cursor = next_cursor;
            start = end;
            end = start + perINDIR - (start % perINDIR);
        }
        _interact_indirect(self, iiblk[end_idx-1], buf[cursor..], start, op);
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
// cwd_inode: Inode,
all_files: DLL(DentryL) = .{},
open_files: DLL(File) = .{},
io: IO = .from(KTFS),
cache: Cache,
big_blk: [BLKSZ]u8 = undefined,
allocator: std.mem.Allocator,

pub fn mount(bkgio: *IO, allocator: std.mem.Allocator) !*IO {
    const self = try allocator.create(KTFS);
    errdefer allocator.destroy(self);

    const cache = Cache.init(bkgio, allocator);

    const superblock = try cache.get_const(0);
    defer cache.release(superblock);

    self.* = .{
        .superblock = @as([]Superblock, superblock)[0],
        .root_inode = Inode.fetch(self, self.superblock.root_directory_inode),
        .cache = cache,
        .allocator = allocator,
    };

    return self.io.addref();
}

pub fn cntl(io: *IO, cmd: i32, arg: ?*anyopaque) IO.Error!isize {
    const self: *KTFS = @alignCast(@fieldParentPtr("io", io));

    switch (cmd) {
        IO.IOCTL_GETBLKSZ => return BLKSZ,
        IO.IOCTL_GETEND => return self.cache.bkgio.cntl(IO.IOCTL_GETEND, arg),
        else => return IO.Error.Unsupported,
    }
}

// File Management

fn find_file(self: *KTFS, name: []const u8) ?*Dentry {
    var cur: ?*DentryL = self.all_files.head;
    return while (cur) |elem| : (cur = elem.next) {
        if (std.mem.eql(u8, name, elem.dentry.name))
            break elem.dentry;
    } else null;
}

pub fn open(self: *KTFS, name: []const u8) !*File {
    try validate_filename(name);

    if (self.find_file(name)) |dentry| {
        _ = dentry;
    }

    return Error.NoEntry;
}

pub fn create(self: *KTFS, name: []const u8) !void {
    try validate_filename(name);

    if (self.find_file(name)) |_|
        return Error.Exists;

}

pub fn delete(self: *KTFS, name: []const u8) !void {
    try validate_filename(name);

    if (self.find_file(name)) |dentry| {
        if (self.open_files.find_field("dentry", *dentry)) |_|
            return Error.Busy;




    } else return Error.NoEntry;

}


// INTERNAL HELPERS
//

const Error = error {
    NoEntry,
    Invalid,
    Exists,
    Busy,
    Full,
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
                                // Convert found bit index to absolute block byte offset
                                break :outer (((((i-1) << (ORDER + 3)) + (j << 6) + (k << 3) + l) << ORDER));
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
    dindirect = 2,

    inline fn below(self: BlockLevel) BlockLevel {
        return switch (self) {
            .direct => @panic("at rock bottom"),
            .indirect => .direct,
            .dindirect => .indirect
        };
    }
};

// Returns total number of bytes allocated
fn alloc_space(self: *KTFS, blkno: *u32, level: BlockLevel, size: usize) get_error!usize {
    assert(size <= BLKSZ << ((ORDER - 2) * @intFromEnum(level)), "beyond block border");
    assert(blkno.* == 0, "block must be free!");

    const blkpos: u64 = try self.find_free();
    try self.bitmap_modify(blkpos, true);

    // dealloc on fail
    errdefer self.bitmap_modify(blkpos, false);

    // const allocated = try self.alloc_blocks(blkpos, level, size);

    // if (allocated < size)

    // inline for () |*num|{

    // }

    return blkpos;
}

// Returns total number of bytes allocated
fn alloc_blocks(self: *KTFS, pos: u64, level: BlockLevel, size: usize) get_error!usize {
    var allocated: usize = 0;

    const blk: []u32 = @ptrCast(try self.cache.get(pos));
    defer self.cache.release(blk, .dirty);

    if (level == .direct) {
        allocated += BLKSZ;
    } else for (blk) |*blkno| {
        if (allocated >= size)
            break;

        if (blkno.* != 0)
            continue;

        const blkpos: u64 = try self.find_free();
        try self.bitmap_modify(blkpos, true);

        errdefer self.bitmap_modify(blkpos, false);

        allocated += try self.alloc_blocks(blkpos, level.below(), size - allocated);



    }

    return allocated;
}


fn dealloc_block(self: *KTFS, pos: u64, level: BlockLevel, wipe: bool) block_error!void {
    assert(pos > 0, "Cannot deallocate superblock!");
    assert((pos & (BLKSZ-1)) == 0, "must be block aligned!");

    const lvl: u8 = @intFromEnum(level);

    // Free contained blocks
    if (lvl > 0) {
        const blk: []u32 = @ptrCast(try self.cache.get(pos));

        for (blk) |blkno| {
            if (blkno > 0)
                try dealloc_block(self, blkno << ORDER, @enumFromInt(lvl-1), wipe);
        }

        if (wipe) {
            @memset(blk, 0);
            self.cache.release(blk, .dirty);
        } else self.cache.release(blk, .clean);
    }

    // Free this block
    try self.bitmap_modify(pos, false);
}

fn build_charset(chars: []const u8) u256 {
    var charset: u256 = 0;
    for (chars) |char|
        charset |= 1 << char;
    return charset;
}

const allowed_chars: []const u8 = "abcdefghjiklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_";
const allowed_charset: u256 = build_charset(allowed_chars);

/// Does not yet support nesting (hence why '/' forbidden)
fn validate_filename(name: []const u8) !void {
    for (name) |char|
        if (allowed_charset & (1 << char)) {
            log.err("String \"{s}\" contains invalid characters!", .{name});
            return Error.Invalid;
        };
}
