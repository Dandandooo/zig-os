const std = @import("std");
const IO = @import("../api/io.zig");
const DLL = @import("../util/list.zig").DLL;
const assert = @import("../util/debug.zig").assert;

const Cache = @import("./cache.zig");

const log = std.log.scoped(.RBFS);

const RBFS = @This();

pub const ORDER = 9;
pub const BLKSZ = 1 << ORDER;
pub const INOSZ = 32;
pub const DENSZ = 16;

const MAX_FILENAME_LEN = DENSZ - @sizeOf(u16) - @sizeOf(u8);
const NAME_SIZE = MAX_FILENAME_LEN + @sizeOf(u8);
const NUM_DIRECT_DATA_BLOCKS = 3;
const NUM_DINDIRECT_BLOCKS = 2;
const DENTRIES_PER_BLOCK = BLKSZ / DENSZ;
const INODES_PER_BLOCK = BLKSZ / INOSZ;
const PTRS_PER_BLOCK = BLKSZ / @sizeOf(u32);

const DIRECT_CAPACITY = NUM_DIRECT_DATA_BLOCKS * BLKSZ;
const INDIRECT_CAPACITY = PTRS_PER_BLOCK * BLKSZ;
const DINDIRECT_CAPACITY = NUM_DINDIRECT_BLOCKS * PTRS_PER_BLOCK * PTRS_PER_BLOCK * BLKSZ;
const MAX_FILE_SIZE = DIRECT_CAPACITY + INDIRECT_CAPACITY + DINDIRECT_CAPACITY;

const FILE_IN_USE = 1 << 0;
const FILE_FREE = 0 << 0;

pub const Error = std.mem.Allocator.Error || IO.Error || error{NotFound};

const Superblock = packed struct {
    block_count: u32,
    bitmap_block_count: u32,
    inode_block_count: u32,
    root_directory_inode: u16,
};

const Inode = extern struct {
    size: u32,
    flags: u32,
    block: [NUM_DIRECT_DATA_BLOCKS]u32,
    indirect: u32,
    dindirect: [NUM_DINDIRECT_BLOCKS]u32,
};

const Dentry = extern struct {
    inode: u16,
    name: [NAME_SIZE]u8,
};

comptime {
    if (@sizeOf(Inode) != INOSZ)
        @compileError("rbfs inode size changed");
    if (@sizeOf(Dentry) != DENSZ)
        @compileError("rbfs dentry size changed");
}

pub const File = struct {
    io: IO = .from(File),
    size: u32,
    dentry: Dentry,
    flags: u16,
    position: u64 = 0,
    fs: *RBFS,
    next: ?*File = null,
    prev: ?*File = null,

    pub fn readat(io: *IO, buf: []u8, pos: u64) IO.Error!usize {
        const self: *File = @fieldParentPtr("io", io);
        return self.fs.read_file(self, pos, buf);
    }

    pub fn writeat(io: *IO, buf: []const u8, pos: u64) IO.Error!usize {
        const self: *File = @fieldParentPtr("io", io);
        return self.fs.write_file(self, pos, buf);
    }

    pub fn close(io: *IO) void {
        const self: *File = @fieldParentPtr("io", io);
        self.flags = FILE_FREE;
        self.fs.remove_open_file(self);
        self.fs.allocator.destroy(self);
    }

    pub fn cntl(io: *IO, cmd: i32, arg: ?*anyopaque) IO.Error!isize {
        const self: *File = @fieldParentPtr("io", io);

        return switch (cmd) {
            IO.IOCTL_GETBLKSZ => BLKSZ,
            IO.IOCTL_GETEND => @intCast(self.size),
            IO.IOCTL_GETPOS => @intCast(self.position),
            IO.IOCTL_SETPOS => blk: {
                const raw = arg orelse return IO.Error.Invalid;
                const pos: *const u64 = @ptrCast(@alignCast(raw));
                if (pos.* > self.size)
                    return IO.Error.Invalid;
                self.position = pos.*;
                break :blk @intCast(self.position);
            },
            IO.IOCTL_SETEND => blk: {
                const raw = arg orelse return IO.Error.Invalid;
                const target_size: *const u64 = @ptrCast(@alignCast(raw));
                try self.fs.set_end(self, target_size.*);
                break :blk @intCast(self.size);
            },
            else => IO.Error.Unsupported,
        };
    }
};

const DentryL = struct {
    entry: Dentry,
    next: ?*DentryL = null,
    prev: ?*DentryL = null,
};

superblock: Superblock,
root_inode: Inode,
cwd_inode: Inode,
all_files: DLL(DentryL) = .{},
open_files: DLL(File) = .{},
io: *IO,
cache: Cache,
allocator: std.mem.Allocator,

pub fn mount(bkgio: *IO, allocator: std.mem.Allocator) Error!*RBFS {
    const fs = try allocator.create(RBFS);
    errdefer allocator.destroy(fs);

    fs.* = .{
        .superblock = undefined,
        .root_inode = undefined,
        .cwd_inode = undefined,
        .io = bkgio.addref(),
        .cache = Cache.init(bkgio, allocator),
        .allocator = allocator,
    };
    errdefer fs.io.close();
    errdefer fs.cache.deinit();

    const block = try fs.cache.get_const(0);
    defer fs.cache.release(block, .clean);

    fs.superblock = read_value(Superblock, block[0..@sizeOf(Superblock)]);
    try fs.populate_root_directory();
    fs.cwd_inode = fs.root_inode;

    log.info("mounted: {d} blocks, {d} bitmap blocks, {d} inode blocks, root inode {d}", .{
        fs.superblock.block_count,
        fs.superblock.bitmap_block_count,
        fs.superblock.inode_block_count,
        fs.superblock.root_directory_inode,
    });

    return fs;
}

pub fn deinit(self: *RBFS) void {
    _ = self.flush() catch {};

    while (self.open_files.pop(self.open_files.head)) |file|
        self.allocator.destroy(file);

    self.clear_file_list();
    self.cache.deinit();
    self.io.close();
    self.allocator.destroy(self);
}

pub fn open(self: *RBFS, name: []const u8) Error!*IO {
    if (!valid_name(name))
        return IO.Error.Invalid;

    const dentry = self.find_file(name) orelse return Error.NotFound;
    if (self.find_open_file(name) != null)
        return IO.Error.Busy;

    const inode = try self.fetch_inode(dentry.entry.inode);
    const file = try self.allocator.create(File);
    file.* = .{
        .size = inode.size,
        .dentry = dentry.entry,
        .flags = FILE_IN_USE,
        .fs = self,
    };

    self.prepend_open_file(file);
    return file.io.addref();
}

pub fn create(self: *RBFS, name: []const u8) Error!void {
    if (!valid_name(name))
        return IO.Error.Invalid;
    if (self.find_file(name) != null)
        return IO.Error.Invalid;

    const dentry_count = self.cwd_inode.size / DENSZ;
    const inode_no: u16 = @intCast(dentry_count + 1);

    try self.write_inode(inode_no, .{
        .size = 0,
        .flags = 0,
        .block = [_]u32{0} ** NUM_DIRECT_DATA_BLOCKS,
        .indirect = 0,
        .dindirect = [_]u32{0} ** NUM_DINDIRECT_BLOCKS,
    });

    var dentry: Dentry = .{
        .inode = inode_no,
        .name = [_]u8{0} ** NAME_SIZE,
    };
    copy_name(&dentry, name);

    try self.write_dentry(dentry_count, dentry);
    self.cwd_inode.size += DENSZ;
    self.root_inode = self.cwd_inode;
    try self.write_inode(self.superblock.root_directory_inode, self.cwd_inode);

    const node = try self.allocator.create(DentryL);
    node.* = .{ .entry = dentry };
    self.prepend_file(node);
}

pub fn delete(self: *RBFS, name: []const u8) Error!void {
    if (!valid_name(name))
        return IO.Error.Invalid;
    if (self.find_open_file(name) != null)
        return IO.Error.Busy;

    const dentry_count = self.cwd_inode.size / DENSZ;
    const found = try self.find_dentry_index(name) orelse return Error.NotFound;
    const victim = try self.read_dentry(found);
    const victim_inode = try self.fetch_inode(victim.inode);

    try self.free_inode_blocks(victim_inode);

    const last_index = dentry_count - 1;
    if (found != last_index) {
        var last_dentry = try self.read_dentry(last_index);
        const last_inode = try self.fetch_inode(last_dentry.inode);

        try self.write_inode(victim.inode, last_inode);
        last_dentry.inode = victim.inode;
        try self.write_dentry(found, last_dentry);
    }

    try self.write_inode(@intCast(last_index + 1), .{
        .size = 0,
        .flags = 0,
        .block = [_]u32{0} ** NUM_DIRECT_DATA_BLOCKS,
        .indirect = 0,
        .dindirect = [_]u32{0} ** NUM_DINDIRECT_BLOCKS,
    });

    self.cwd_inode.size -= DENSZ;
    self.root_inode = self.cwd_inode;
    try self.write_inode(self.superblock.root_directory_inode, self.cwd_inode);
    try self.clear_dentry(last_index);

    self.clear_file_list();
    try self.populate_root_directory();
    try self.flush();
}

pub fn flush(self: *RBFS) IO.Error!void {
    return self.cache.flush();
}

pub fn filecount(self: *RBFS) usize {
    return @intCast(self.all_files.size);
}

pub fn get_files(self: *RBFS, buf: []u8) Error!usize {
    var pos: usize = 0;
    var curr = self.all_files.head;
    while (curr) |node| : (curr = node.next) {
        const name = dentry_name(&node.entry);
        if (pos + name.len + 1 > buf.len)
            return IO.Error.Invalid;

        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
        buf[pos] = '\n';
        pos += 1;
    }
    return pos;
}

fn read_file(self: *RBFS, file: *File, pos: u64, buf: []u8) IO.Error!usize {
    const end = std.math.add(u64, pos, @intCast(buf.len)) catch return IO.Error.Invalid;
    if (end > file.size)
        return IO.Error.Invalid;
    if (buf.len == 0)
        return 0;

    const inode = try self.fetch_inode(file.dentry.inode);
    var copied: usize = 0;
    while (copied < buf.len) {
        const cursor = pos + copied;
        const blockno = try self.get_data_block(inode, cursor);
        const block = try self.cache.get_const(self.data_offset(blockno));
        const block_offset: usize = @intCast(cursor % BLKSZ);
        const nread = @min(BLKSZ - block_offset, buf.len - copied);

        @memcpy(buf[copied..][0..nread], block[block_offset..][0..nread]);
        self.cache.release(block, .clean);
        copied += nread;
    }

    file.position = end;
    return copied;
}

fn write_file(self: *RBFS, file: *File, pos: u64, buf: []const u8) IO.Error!usize {
    const end = std.math.add(u64, pos, @intCast(buf.len)) catch return IO.Error.Invalid;
    if (end > file.size)
        return IO.Error.Invalid;
    if (buf.len == 0)
        return 0;

    const inode = try self.fetch_inode(file.dentry.inode);
    var copied: usize = 0;
    while (copied < buf.len) {
        const cursor = pos + copied;
        const blockno = try self.get_data_block(inode, cursor);
        const block = try self.cache.get(self.data_offset(blockno));
        const block_offset: usize = @intCast(cursor % BLKSZ);
        const nwritten = @min(BLKSZ - block_offset, buf.len - copied);

        @memcpy(block[block_offset..][0..nwritten], buf[copied..][0..nwritten]);
        self.cache.release(block, .dirty);
        copied += nwritten;
    }

    file.position = end;
    return copied;
}

fn set_end(self: *RBFS, file: *File, target_size: u64) IO.Error!void {
    if (target_size < file.size or target_size > MAX_FILE_SIZE or target_size > std.math.maxInt(u32))
        return IO.Error.Invalid;
    if (target_size == file.size)
        return;

    var inode = try self.fetch_inode(file.dentry.inode);
    var block_idx = block_count(inode.size);
    const target_blocks = block_count(target_size);

    while (block_idx < target_blocks) : (block_idx += 1) {
        const blockno = try self.claim_free_block();
        try self.zero_block(blockno);
        try self.attach_data_block(&inode, block_idx, blockno);
    }

    inode.size = @intCast(target_size);
    try self.write_inode(file.dentry.inode, inode);
    file.size = inode.size;
}

fn populate_root_directory(self: *RBFS) Error!void {
    self.clear_file_list();
    self.root_inode = try self.fetch_inode(self.superblock.root_directory_inode);
    self.cwd_inode = self.root_inode;

    var file_count = self.root_inode.size / DENSZ;
    var direct_idx: usize = 0;
    while (file_count > 0 and direct_idx < NUM_DIRECT_DATA_BLOCKS) : (direct_idx += 1)
        try self.read_dentry_block(&file_count, self.root_inode.block[direct_idx]);

    if (file_count != 0)
        return IO.Error.Unsupported;
}

fn read_dentry_block(self: *RBFS, file_count: *u32, blockno: u32) Error!void {
    const block = try self.cache.get_const(self.data_offset(blockno));
    defer self.cache.release(block, .clean);

    var dentry_idx: usize = 0;
    while (dentry_idx < DENTRIES_PER_BLOCK and file_count.* > 0) : (dentry_idx += 1) {
        const offset = dentry_idx * DENSZ;
        const node = try self.allocator.create(DentryL);
        node.* = .{
            .entry = read_value(Dentry, block[offset..][0..DENSZ]),
        };
        self.prepend_file(node);
        file_count.* -= 1;
    }
}

fn read_dentry(self: *RBFS, index: u32) IO.Error!Dentry {
    const pos = dentry_position(index);
    if (pos.block_idx >= NUM_DIRECT_DATA_BLOCKS)
        return IO.Error.Unsupported;

    const blockno = self.cwd_inode.block[pos.block_idx];
    const block = try self.cache.get_const(self.data_offset(blockno));
    defer self.cache.release(block, .clean);

    return read_value(Dentry, block[pos.offset..][0..DENSZ]);
}

fn write_dentry(self: *RBFS, index: u32, dentry: Dentry) IO.Error!void {
    const pos = dentry_position(index);
    if (pos.block_idx >= NUM_DIRECT_DATA_BLOCKS)
        return IO.Error.Unsupported;

    const blockno = self.cwd_inode.block[pos.block_idx];
    const block = try self.cache.get(self.data_offset(blockno));
    defer self.cache.release(block, .dirty);

    write_value(Dentry, block[pos.offset..][0..DENSZ], dentry);
}

fn clear_dentry(self: *RBFS, index: u32) IO.Error!void {
    const pos = dentry_position(index);
    if (pos.block_idx >= NUM_DIRECT_DATA_BLOCKS)
        return IO.Error.Unsupported;

    const blockno = self.cwd_inode.block[pos.block_idx];
    const block = try self.cache.get(self.data_offset(blockno));
    defer self.cache.release(block, .dirty);

    @memset(block[pos.offset..][0..DENSZ], 0);
}

fn dentry_position(index: u32) struct { block_idx: usize, offset: usize } {
    const byte_offset: usize = @intCast(index * DENSZ);
    return .{
        .block_idx = byte_offset / BLKSZ,
        .offset = byte_offset % BLKSZ,
    };
}

fn fetch_inode(self: *RBFS, inode_no: u16) IO.Error!Inode {
    const inode_blk_offset = inode_no / INODES_PER_BLOCK;
    const block = try self.cache.get_const(self.inode_start() + (@as(u64, inode_blk_offset) * BLKSZ));
    defer self.cache.release(block, .clean);

    const offset = (@as(usize, inode_no) * INOSZ) % BLKSZ;
    return read_value(Inode, block[offset..][0..INOSZ]);
}

fn write_inode(self: *RBFS, inode_no: u16, inode: Inode) IO.Error!void {
    const inode_blk_offset = inode_no / INODES_PER_BLOCK;
    const block = try self.cache.get(self.inode_start() + (@as(u64, inode_blk_offset) * BLKSZ));
    defer self.cache.release(block, .dirty);

    const offset = (@as(usize, inode_no) * INOSZ) % BLKSZ;
    write_value(Inode, block[offset..][0..INOSZ], inode);
}

fn get_data_block(self: *RBFS, inode: Inode, cursor: u64) IO.Error!u32 {
    var logical_block: usize = @intCast(cursor / BLKSZ);
    if (logical_block < NUM_DIRECT_DATA_BLOCKS)
        return inode.block[logical_block];

    logical_block -= NUM_DIRECT_DATA_BLOCKS;
    if (logical_block < PTRS_PER_BLOCK) {
        if (inode.indirect == 0)
            return IO.Error.BadFormat;
        return self.read_blockno(inode.indirect, logical_block);
    }

    logical_block -= PTRS_PER_BLOCK;
    const blocks_per_dindirect = PTRS_PER_BLOCK * PTRS_PER_BLOCK;
    const dindirect_idx = logical_block / blocks_per_dindirect;
    if (dindirect_idx >= NUM_DINDIRECT_BLOCKS or inode.dindirect[dindirect_idx] == 0)
        return IO.Error.BadFormat;

    const dindirect_offset = (logical_block % blocks_per_dindirect) / PTRS_PER_BLOCK;
    const indirect_offset = logical_block % PTRS_PER_BLOCK;
    const indirect_blockno = try self.read_blockno(inode.dindirect[dindirect_idx], dindirect_offset);
    if (indirect_blockno == 0)
        return IO.Error.BadFormat;

    return self.read_blockno(indirect_blockno, indirect_offset);
}

fn attach_data_block(self: *RBFS, inode: *Inode, logical_block: usize, blockno: u32) IO.Error!void {
    if (logical_block < NUM_DIRECT_DATA_BLOCKS) {
        inode.block[logical_block] = blockno;
        return;
    }

    var indirect_logical = logical_block - NUM_DIRECT_DATA_BLOCKS;
    if (indirect_logical < PTRS_PER_BLOCK) {
        if (inode.indirect == 0) {
            inode.indirect = try self.claim_free_block();
            try self.zero_block(inode.indirect);
        }
        return self.write_blockno(inode.indirect, indirect_logical, blockno);
    }

    indirect_logical -= PTRS_PER_BLOCK;
    const blocks_per_dindirect = PTRS_PER_BLOCK * PTRS_PER_BLOCK;
    const dindirect_idx = indirect_logical / blocks_per_dindirect;
    if (dindirect_idx >= NUM_DINDIRECT_BLOCKS)
        return IO.Error.Invalid;

    if (inode.dindirect[dindirect_idx] == 0) {
        inode.dindirect[dindirect_idx] = try self.claim_free_block();
        try self.zero_block(inode.dindirect[dindirect_idx]);
    }

    const dindirect_offset = (indirect_logical % blocks_per_dindirect) / PTRS_PER_BLOCK;
    const direct_offset = indirect_logical % PTRS_PER_BLOCK;
    var indirect_blockno = try self.read_blockno(inode.dindirect[dindirect_idx], dindirect_offset);
    if (indirect_blockno == 0) {
        indirect_blockno = try self.claim_free_block();
        try self.zero_block(indirect_blockno);
        try self.write_blockno(inode.dindirect[dindirect_idx], dindirect_offset, indirect_blockno);
    }

    try self.write_blockno(indirect_blockno, direct_offset, blockno);
}

fn free_inode_blocks(self: *RBFS, inode: Inode) IO.Error!void {
    var remaining = block_count(inode.size);

    var i: usize = 0;
    while (i < NUM_DIRECT_DATA_BLOCKS and remaining > 0) : (i += 1) {
        try self.set_bitmap(inode.block[i], false);
        remaining -= 1;
    }

    if (remaining == 0 or inode.indirect == 0)
        return;

    const indirect_count = @min(remaining, PTRS_PER_BLOCK);
    try self.free_indirect(inode.indirect, indirect_count);
    remaining -= indirect_count;

    if (remaining == 0)
        return;

    for (inode.dindirect) |dindirect_blockno| {
        if (remaining == 0 or dindirect_blockno == 0)
            break;

        const count = @min(remaining, PTRS_PER_BLOCK * PTRS_PER_BLOCK);
        try self.free_dindirect(dindirect_blockno, count);
        remaining -= count;
    }
}

fn free_indirect(self: *RBFS, indirect_blockno: u32, count: usize) IO.Error!void {
    const block = try self.cache.get_const(self.data_offset(indirect_blockno));
    defer self.cache.release(block, .clean);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const blockno = read_u32(block, i);
        if (blockno != 0)
            try self.set_bitmap(blockno, false);
    }

    try self.set_bitmap(indirect_blockno, false);
}

fn free_dindirect(self: *RBFS, dindirect_blockno: u32, count: usize) IO.Error!void {
    const block = try self.cache.get_const(self.data_offset(dindirect_blockno));
    defer self.cache.release(block, .clean);

    var remaining = count;
    var i: usize = 0;
    while (i < PTRS_PER_BLOCK and remaining > 0) : (i += 1) {
        const indirect_blockno = read_u32(block, i);
        if (indirect_blockno != 0) {
            const indirect_count = @min(remaining, PTRS_PER_BLOCK);
            try self.free_indirect(indirect_blockno, indirect_count);
            remaining -= indirect_count;
        }
    }

    try self.set_bitmap(dindirect_blockno, false);
}

fn read_blockno(self: *RBFS, blockno: u32, index: usize) IO.Error!u32 {
    const block = try self.cache.get_const(self.data_offset(blockno));
    defer self.cache.release(block, .clean);

    return read_u32(block, index);
}

fn write_blockno(self: *RBFS, blockno: u32, index: usize, value: u32) IO.Error!void {
    const block = try self.cache.get(self.data_offset(blockno));
    defer self.cache.release(block, .dirty);

    write_u32(block, index, value);
}

fn claim_free_block(self: *RBFS) IO.Error!u32 {
    const blockno = try self.find_free_block();
    try self.set_bitmap(blockno, true);
    return blockno;
}

fn find_free_block(self: *RBFS) IO.Error!u32 {
    const data_blocks = self.data_block_count();
    var bitmap_block_idx: u32 = 0;
    while (bitmap_block_idx < self.superblock.bitmap_block_count) : (bitmap_block_idx += 1) {
        const block = try self.cache.get_const(BLKSZ * (1 + @as(u64, bitmap_block_idx)));
        defer self.cache.release(block, .clean);

        var byte_idx: usize = 0;
        while (byte_idx < BLKSZ) : (byte_idx += 1) {
            if (block[byte_idx] == 0xff)
                continue;

            var bit_idx: u3 = 0;
            while (true) : (bit_idx += 1) {
                const data_blockno = (@as(u32, bitmap_block_idx) * BLKSZ * 8) + (@as(u32, @intCast(byte_idx)) * 8) + bit_idx;
                if (data_blockno >= data_blocks)
                    return IO.Error.Error;
                if (data_blockno != 0 and (block[byte_idx] & (@as(u8, 1) << bit_idx)) == 0)
                    return data_blockno;
                if (bit_idx == 7)
                    break;
            }
        }
    }

    return IO.Error.Error;
}

fn set_bitmap(self: *RBFS, blockno: u32, used: bool) IO.Error!void {
    if (blockno >= self.data_block_count())
        return IO.Error.BadFormat;

    const bitmap_block_idx = blockno / (BLKSZ * 8);
    const bit_in_block = blockno % (BLKSZ * 8);
    const byte_idx: usize = @intCast(bit_in_block / 8);
    const bit_idx: u3 = @intCast(bit_in_block % 8);
    const block = try self.cache.get(BLKSZ * (1 + @as(u64, bitmap_block_idx)));
    defer self.cache.release(block, .dirty);

    if (used)
        block[byte_idx] |= @as(u8, 1) << bit_idx
    else
        block[byte_idx] &= ~(@as(u8, 1) << bit_idx);
}

fn zero_block(self: *RBFS, blockno: u32) IO.Error!void {
    const block = try self.cache.get(self.data_offset(blockno));
    defer self.cache.release(block, .dirty);

    @memset(block, 0);
}

fn find_dentry_index(self: *RBFS, name: []const u8) IO.Error!?u32 {
    const count = self.cwd_inode.size / DENSZ;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const dentry = try self.read_dentry(i);
        if (std.mem.eql(u8, dentry_name(&dentry), name))
            return i;
    }

    return null;
}

fn find_file(self: *RBFS, name: []const u8) ?*DentryL {
    var curr = self.all_files.head;
    while (curr) |node| : (curr = node.next) {
        if (std.mem.eql(u8, dentry_name(&node.entry), name))
            return node;
    }
    return null;
}

fn find_open_file(self: *RBFS, name: []const u8) ?*File {
    var curr = self.open_files.head;
    while (curr) |file| : (curr = file.next) {
        if (std.mem.eql(u8, dentry_name(&file.dentry), name))
            return file;
    }
    return null;
}

fn prepend_file(self: *RBFS, node: *DentryL) void {
    self.all_files.prepend(node);
}

fn prepend_open_file(self: *RBFS, file: *File) void {
    self.open_files.prepend(file);
}

fn remove_open_file(self: *RBFS, file: *File) void {
    _ = self.open_files.pop(file);
}

fn clear_file_list(self: *RBFS) void {
    while (self.all_files.pop(self.all_files.head)) |node|
        self.allocator.destroy(node);
}

fn inode_start(self: *const RBFS) u64 {
    return BLKSZ * (1 + @as(u64, self.superblock.bitmap_block_count));
}

fn data_start(self: *const RBFS) u64 {
    return self.inode_start() + (BLKSZ * @as(u64, self.superblock.inode_block_count));
}

fn data_offset(self: *const RBFS, blockno: u32) u64 {
    return self.data_start() + (BLKSZ * @as(u64, blockno));
}

fn data_block_count(self: *const RBFS) u32 {
    return self.superblock.block_count - 1 - self.superblock.bitmap_block_count - self.superblock.inode_block_count;
}

fn block_count(size: u64) usize {
    if (size == 0)
        return 0;
    return @intCast(((size - 1) / BLKSZ) + 1);
}

fn valid_name(name: []const u8) bool {
    return name.len > 0 and name.len <= MAX_FILENAME_LEN and std.mem.indexOfScalar(u8, name, 0) == null;
}

fn copy_name(dentry: *Dentry, name: []const u8) void {
    @memset(&dentry.name, 0);
    @memcpy(dentry.name[0..name.len], name);
}

fn dentry_name(dentry: *const Dentry) []const u8 {
    const end = std.mem.indexOfScalar(u8, &dentry.name, 0) orelse dentry.name.len;
    return dentry.name[0..end];
}

fn read_value(comptime T: type, bytes: []const u8) T {
    assert(bytes.len >= @sizeOf(T), "short rbfs struct read");
    return std.mem.bytesToValue(T, bytes[0..@sizeOf(T)]);
}

fn write_value(comptime T: type, bytes: []u8, value: T) void {
    assert(bytes.len >= @sizeOf(T), "short rbfs struct write");
    @memcpy(bytes[0..@sizeOf(T)], std.mem.asBytes(&value));
}

fn read_u32(block: *const [BLKSZ]u8, index: usize) u32 {
    const offset = index * @sizeOf(u32);
    return std.mem.readInt(u32, block[offset..][0..@sizeOf(u32)], .little);
}

fn write_u32(block: *[BLKSZ]u8, index: usize, value: u32) void {
    const offset = index * @sizeOf(u32);
    std.mem.writeInt(u32, block[offset..][0..@sizeOf(u32)], value, .little);
}
