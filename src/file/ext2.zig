// EXT2 rev 0/1 driver (flat root-directory namespace, like the other drivers).
//
// Supports 1K-4K blocks, multiple block groups, and the full direct /
// indirect / doubly / triply indirect block maps for both reads and writes.
// The underlying cache works in 512-byte sectors, so all disk access goes
// through read_bytes/write_bytes which split requests along sector lines.

const std = @import("std");
const IO = @import("../api/io.zig");
const DLL = @import("../util/list.zig").DLL;
const assert = @import("../util/debug.zig").assert;
const rtc = @import("../dev/rtc.zig");

const Cache = @import("./cache.zig");

const log = std.log.scoped(.EXT2);

const EXT2 = @This();

pub const MAGIC: u16 = 0xEF53;
pub const ROOT_INODE: u32 = 2;
pub const MAX_NAME_LEN = 255;

/// The superblock always lives at byte 1024, regardless of block size.
pub const SUPERBLOCK_POS: u64 = 1024;

const N_DIRECT = 12;
const IDX_INDIRECT = 12;
const IDX_DINDIRECT = 13;
const IDX_TRINDIRECT = 14;

/// Directory entries carry a type byte instead of a 16-bit name length.
const INCOMPAT_FILETYPE: u32 = 0x2;

const S_IFMT: u16 = 0xF000;
const S_IFDIR: u16 = 0x4000;
const S_IFREG: u16 = 0x8000;

const FT_REG_FILE: u8 = 1;

pub const Error = std.mem.Allocator.Error || IO.Error || error{NotFound};

// On-disk structures (little endian, matching the RISC-V target)

const Superblock = extern struct {
    n_inodes: u32,
    n_blocks: u32,
    n_reserved_blocks: u32,
    n_free_blocks: u32,
    n_free_inodes: u32,
    /// First block covered by block group 0 (1 for 1K blocks, else 0).
    first_data_block: u32,
    /// Block size is 1024 << log_block_size.
    log_block_size: u32,
    log_frag_size: u32,
    blocks_per_group: u32,
    frags_per_group: u32,
    inodes_per_group: u32,
    mount_time: u32,
    write_time: u32,
    mount_count: u16,
    max_mount_count: u16,
    magic: u16,
    state: u16,
    errors: u16,
    minor_rev: u16,
    last_check: u32,
    check_interval: u32,
    creator_os: u32,
    rev_level: u32,
    def_resuid: u16,
    def_resgid: u16,

    // Extended fields, only meaningful when rev_level >= 1.
    first_ino: u32,
    inode_size: u16,
    block_group_nr: u16,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,

    fn block_size(self: *const Superblock) u32 {
        return @as(u32, 1024) << @intCast(self.log_block_size);
    }

    fn inode_sz(self: *const Superblock) u32 {
        return if (self.rev_level >= 1) self.inode_size else 128;
    }

    fn group_count(self: *const Superblock) u32 {
        const covered = self.n_blocks - self.first_data_block;
        return (covered + self.blocks_per_group - 1) / self.blocks_per_group;
    }
};

const BlockGroupDescriptor = extern struct {
    block_bitmap: u32,
    inode_bitmap: u32,
    inode_table: u32,
    n_free_blocks: u16,
    n_free_inodes: u16,
    n_dirs: u16,
    _pad: u16,
    _reserved: [12]u8,
};

const Inode = extern struct {
    mode: u16,
    uid: u16,
    size: u32,
    atime: u32,
    ctime: u32,
    mtime: u32,
    dtime: u32,
    gid: u16,
    links: u16,
    /// Count of 512-byte sectors in use, including indirect blocks.
    sectors: u32,
    flags: u32,
    osd1: u32,
    block: [15]u32,
    generation: u32,
    file_acl: u32,
    dir_acl: u32,
    faddr: u32,
    osd2: [12]u8,
};

const DentryHeader = extern struct {
    inode: u32,
    rec_len: u16,
    name_len: u8,
    file_type: u8,
};

const DENTRY_HEADER_SIZE = @sizeOf(DentryHeader);

comptime {
    if (@sizeOf(Superblock) != 104)
        @compileError("ext2 superblock layout drifted");
    if (@sizeOf(BlockGroupDescriptor) != 32)
        @compileError("ext2 group descriptor layout drifted");
    if (@sizeOf(Inode) != 128)
        @compileError("ext2 inode layout drifted");
    if (DENTRY_HEADER_SIZE != 8)
        @compileError("ext2 dentry header layout drifted");
}

// Software structures

pub const File = struct {
    io: IO = .from(File),
    size: u32,
    inode_no: u32,
    name_len: u8,
    name_buf: [MAX_NAME_LEN]u8,
    position: u64 = 0,
    fs: *EXT2,
    next: ?*File = null,
    prev: ?*File = null,

    fn name(self: *const File) []const u8 {
        return self.name_buf[0..self.name_len];
    }

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
        _ = self.fs.open_files.pop(self);
        self.fs.allocator.destroy(self);
    }

    pub fn cntl(io: *IO, cmd: i32, arg: ?*anyopaque) IO.Error!isize {
        const self: *File = @fieldParentPtr("io", io);

        return switch (cmd) {
            IO.IOCTL_GETBLKSZ => @intCast(self.fs.blksz),
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
    inode: u32,
    name_len: u8,
    name_buf: [MAX_NAME_LEN]u8,
    next: ?*DentryL = null,
    prev: ?*DentryL = null,

    fn name(self: *const DentryL) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

superblock: Superblock,
blksz: u32,
all_files: DLL(DentryL) = .{},
open_files: DLL(File) = .{},
io: *IO,
cache: Cache,
allocator: std.mem.Allocator,

pub fn mount(bkgio: *IO, allocator: std.mem.Allocator) Error!*EXT2 {
    const fs = try allocator.create(EXT2);
    errdefer allocator.destroy(fs);

    fs.* = .{
        .superblock = undefined,
        .blksz = undefined,
        .io = bkgio.addref(),
        .cache = Cache.init(bkgio, allocator),
        .allocator = allocator,
    };
    errdefer fs.io.close();
    errdefer fs.cache.deinit();

    fs.superblock = try fs.read_struct(Superblock, SUPERBLOCK_POS);
    const sb = &fs.superblock;

    if (sb.magic != MAGIC)
        return IO.Error.BadFormat;
    if (sb.feature_incompat & ~INCOMPAT_FILETYPE != 0) {
        log.err("unsupported incompat features: 0x{X}", .{sb.feature_incompat});
        return IO.Error.Unsupported;
    }
    if (sb.log_block_size > 2)
        return IO.Error.Unsupported;
    if (sb.blocks_per_group == 0 or sb.inodes_per_group == 0)
        return IO.Error.BadFormat;
    if (sb.inode_sz() < @sizeOf(Inode))
        return IO.Error.BadFormat;

    fs.blksz = sb.block_size();

    errdefer fs.clear_file_list();
    try fs.populate_root_directory();

    log.info("mounted: {d} blocks of {d} bytes, {d} groups, {d} free blocks, {d} root files", .{
        sb.n_blocks,
        fs.blksz,
        sb.group_count(),
        sb.n_free_blocks,
        fs.all_files.size,
    });

    return fs;
}

pub fn deinit(self: *EXT2) void {
    self.flush() catch {};

    while (self.open_files.pop(self.open_files.head)) |file|
        self.allocator.destroy(file);

    self.clear_file_list();
    self.cache.deinit();
    self.io.close();
    self.allocator.destroy(self);
}

pub fn open(self: *EXT2, name: []const u8) Error!*IO {
    if (!valid_name(name))
        return IO.Error.Invalid;

    const dentry = self.find_file(name) orelse return Error.NotFound;
    if (self.find_open_file(name) != null)
        return IO.Error.Busy;

    const inode = try self.fetch_inode(dentry.inode);
    const file = try self.allocator.create(File);
    file.* = .{
        .size = inode.size,
        .inode_no = dentry.inode,
        .name_len = dentry.name_len,
        .name_buf = dentry.name_buf,
        .fs = self,
    };

    self.open_files.prepend(file);
    return file.io.addref();
}

pub fn create(self: *EXT2, name: []const u8) Error!void {
    if (!valid_name(name))
        return IO.Error.Invalid;
    if (self.find_file(name) != null)
        return IO.Error.Invalid;

    const inode_no = try self.alloc_inode();
    errdefer self.free_inode(inode_no) catch {};

    var inode = std.mem.zeroes(Inode);
    inode.mode = S_IFREG | 0o644;
    inode.links = 1;
    inode.atime = now();
    inode.ctime = inode.atime;
    inode.mtime = inode.atime;
    try self.write_full_inode(inode_no, inode);

    const file_type: u8 =
        if (self.superblock.feature_incompat & INCOMPAT_FILETYPE != 0) FT_REG_FILE else 0;
    try self.add_dentry(name, inode_no, file_type);

    const node = try self.allocator.create(DentryL);
    node.* = .{ .inode = inode_no, .name_len = @intCast(name.len), .name_buf = undefined };
    @memcpy(node.name_buf[0..name.len], name);
    self.all_files.prepend(node);
}

pub fn delete(self: *EXT2, name: []const u8) Error!void {
    if (!valid_name(name))
        return IO.Error.Invalid;
    if (self.find_open_file(name) != null)
        return IO.Error.Busy;

    const node = self.find_file(name) orelse return Error.NotFound;
    const inode_no = try self.remove_dentry(name) orelse return Error.NotFound;

    const inode = try self.fetch_inode(inode_no);
    try self.free_inode_blocks(inode);

    // fsck reads small dtime values as orphan-list links, so use real time.
    var dead = std.mem.zeroes(Inode);
    dead.dtime = now();
    try self.write_inode(inode_no, dead);
    try self.free_inode(inode_no);

    self.allocator.destroy(self.all_files.pop(node).?);
    try self.flush();
}

pub fn flush(self: *EXT2) IO.Error!void {
    return self.cache.flush();
}

pub fn filecount(self: *EXT2) usize {
    return @intCast(self.all_files.size);
}

pub fn get_files(self: *EXT2, buf: []u8) Error!usize {
    var pos: usize = 0;
    var curr = self.all_files.head;
    while (curr) |node| : (curr = node.next) {
        const name = node.name();
        if (pos + name.len + 1 > buf.len)
            return IO.Error.Invalid;

        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
        buf[pos] = '\n';
        pos += 1;
    }
    return pos;
}

// File content access

fn read_file(self: *EXT2, file: *File, pos: u64, buf: []u8) IO.Error!usize {
    const end = std.math.add(u64, pos, @intCast(buf.len)) catch return IO.Error.Invalid;
    if (end > file.size)
        return IO.Error.Invalid;
    if (buf.len == 0)
        return 0;

    const inode = try self.fetch_inode(file.inode_no);
    var copied: usize = 0;
    while (copied < buf.len) {
        const cursor = pos + copied;
        const blockno = try self.get_data_block(&inode, cursor / self.blksz);
        if (blockno == 0)
            return IO.Error.BadFormat;

        const offset = cursor % self.blksz;
        const nread: usize = @intCast(@min(self.blksz - offset, buf.len - copied));
        try self.read_bytes(self.blk_pos(blockno) + offset, buf[copied..][0..nread]);
        copied += nread;
    }

    file.position = end;
    return copied;
}

fn write_file(self: *EXT2, file: *File, pos: u64, buf: []const u8) IO.Error!usize {
    const end = std.math.add(u64, pos, @intCast(buf.len)) catch return IO.Error.Invalid;
    if (end > file.size)
        return IO.Error.Invalid;
    if (buf.len == 0)
        return 0;

    const inode = try self.fetch_inode(file.inode_no);
    var copied: usize = 0;
    while (copied < buf.len) {
        const cursor = pos + copied;
        const blockno = try self.get_data_block(&inode, cursor / self.blksz);
        if (blockno == 0)
            return IO.Error.BadFormat;

        const offset = cursor % self.blksz;
        const nwritten: usize = @intCast(@min(self.blksz - offset, buf.len - copied));
        try self.write_bytes(self.blk_pos(blockno) + offset, buf[copied..][0..nwritten]);
        copied += nwritten;
    }

    file.position = end;
    return copied;
}

fn set_end(self: *EXT2, file: *File, target_size: u64) IO.Error!void {
    if (target_size < file.size or target_size > std.math.maxInt(u32))
        return IO.Error.Invalid;
    if (target_size == file.size)
        return;

    var inode = try self.fetch_inode(file.inode_no);
    var logical = block_count(inode.size, self.blksz);
    const target_blocks = block_count(target_size, self.blksz);

    while (logical < target_blocks) : (logical += 1) {
        const blockno = try self.alloc_zeroed_block(&inode);
        try self.attach_data_block(&inode, logical, blockno);
    }

    inode.size = @intCast(target_size);
    try self.write_inode(file.inode_no, inode);
    file.size = inode.size;
}

// Block map (logical file block -> physical block)

fn get_data_block(self: *EXT2, inode: *const Inode, logical: u64) IO.Error!u32 {
    const ptrs: u64 = self.ptrs_per_block();

    if (logical < N_DIRECT)
        return inode.block[@intCast(logical)];

    var idx = logical - N_DIRECT;
    if (idx < ptrs) {
        if (inode.block[IDX_INDIRECT] == 0)
            return IO.Error.BadFormat;
        return self.read_ptr(inode.block[IDX_INDIRECT], idx);
    }

    idx -= ptrs;
    if (idx < ptrs * ptrs) {
        if (inode.block[IDX_DINDIRECT] == 0)
            return IO.Error.BadFormat;
        const mid = try self.read_ptr(inode.block[IDX_DINDIRECT], idx / ptrs);
        if (mid == 0)
            return IO.Error.BadFormat;
        return self.read_ptr(mid, idx % ptrs);
    }

    idx -= ptrs * ptrs;
    if (idx < ptrs * ptrs * ptrs) {
        if (inode.block[IDX_TRINDIRECT] == 0)
            return IO.Error.BadFormat;
        const outer = try self.read_ptr(inode.block[IDX_TRINDIRECT], idx / (ptrs * ptrs));
        if (outer == 0)
            return IO.Error.BadFormat;
        const mid = try self.read_ptr(outer, (idx / ptrs) % ptrs);
        if (mid == 0)
            return IO.Error.BadFormat;
        return self.read_ptr(mid, idx % ptrs);
    }

    return IO.Error.Invalid;
}

fn attach_data_block(self: *EXT2, inode: *Inode, logical: u64, blockno: u32) IO.Error!void {
    const ptrs: u64 = self.ptrs_per_block();

    if (logical < N_DIRECT) {
        inode.block[@intCast(logical)] = blockno;
        return;
    }

    var idx = logical - N_DIRECT;
    if (idx < ptrs) {
        if (inode.block[IDX_INDIRECT] == 0)
            inode.block[IDX_INDIRECT] = try self.alloc_zeroed_block(inode);
        return self.write_ptr(inode.block[IDX_INDIRECT], idx, blockno);
    }

    idx -= ptrs;
    if (idx < ptrs * ptrs) {
        if (inode.block[IDX_DINDIRECT] == 0)
            inode.block[IDX_DINDIRECT] = try self.alloc_zeroed_block(inode);
        const mid = try self.ensure_ptr(inode.block[IDX_DINDIRECT], idx / ptrs, inode);
        return self.write_ptr(mid, idx % ptrs, blockno);
    }

    idx -= ptrs * ptrs;
    if (idx < ptrs * ptrs * ptrs) {
        if (inode.block[IDX_TRINDIRECT] == 0)
            inode.block[IDX_TRINDIRECT] = try self.alloc_zeroed_block(inode);
        const outer = try self.ensure_ptr(inode.block[IDX_TRINDIRECT], idx / (ptrs * ptrs), inode);
        const mid = try self.ensure_ptr(outer, (idx / ptrs) % ptrs, inode);
        return self.write_ptr(mid, idx % ptrs, blockno);
    }

    return IO.Error.Invalid;
}

fn ensure_ptr(self: *EXT2, container: u32, index: u64, inode: *Inode) IO.Error!u32 {
    var blockno = try self.read_ptr(container, index);
    if (blockno == 0) {
        blockno = try self.alloc_zeroed_block(inode);
        try self.write_ptr(container, index, blockno);
    }
    return blockno;
}

fn free_inode_blocks(self: *EXT2, inode: Inode) IO.Error!void {
    for (inode.block[0..N_DIRECT]) |blockno|
        if (blockno != 0) try self.free_block(blockno);

    if (inode.block[IDX_INDIRECT] != 0)
        try self.free_block_tree(inode.block[IDX_INDIRECT], 1);
    if (inode.block[IDX_DINDIRECT] != 0)
        try self.free_block_tree(inode.block[IDX_DINDIRECT], 2);
    if (inode.block[IDX_TRINDIRECT] != 0)
        try self.free_block_tree(inode.block[IDX_TRINDIRECT], 3);
}

fn free_block_tree(self: *EXT2, blockno: u32, depth: u8) IO.Error!void {
    if (depth > 0) {
        var i: u64 = 0;
        while (i < self.ptrs_per_block()) : (i += 1) {
            const child = try self.read_ptr(blockno, i);
            if (child != 0)
                try self.free_block_tree(child, depth - 1);
        }
    }
    try self.free_block(blockno);
}

// Directory handling (root directory only)

const DirEntry = struct {
    header: DentryHeader,
    /// Absolute disk position of the entry header.
    pos: u64,
    /// Absolute disk position of the directory block holding the entry.
    block_start: u64,
    name_buf: [MAX_NAME_LEN]u8,

    fn name(self: *const DirEntry) []const u8 {
        return self.name_buf[0..@min(self.header.name_len, MAX_NAME_LEN)];
    }
};

const DirIter = struct {
    fs: *EXT2,
    inode: Inode,
    offset: u64 = 0,

    fn next(self: *DirIter) IO.Error!?DirEntry {
        const blksz = self.fs.blksz;
        if (self.offset >= self.inode.size)
            return null;

        const logical = self.offset / blksz;
        const in_block = self.offset % blksz;

        const blockno = try self.fs.get_data_block(&self.inode, logical);
        if (blockno == 0)
            return IO.Error.BadFormat;
        const block_start = self.fs.blk_pos(blockno);

        var entry: DirEntry = .{
            .header = undefined,
            .pos = block_start + in_block,
            .block_start = block_start,
            .name_buf = undefined,
        };
        entry.header = try self.fs.read_struct(DentryHeader, entry.pos);

        const rec_len = entry.header.rec_len;
        if (rec_len < DENTRY_HEADER_SIZE or rec_len % 4 != 0 or in_block + rec_len > blksz)
            return IO.Error.BadFormat;
        if (DENTRY_HEADER_SIZE + @as(u16, entry.header.name_len) > rec_len)
            return IO.Error.BadFormat;

        try self.fs.read_bytes(entry.pos + DENTRY_HEADER_SIZE, entry.name_buf[0..entry.header.name_len]);

        self.offset += rec_len;
        return entry;
    }
};

fn dir_iter(self: *EXT2, inode: Inode) DirIter {
    return .{ .fs = self, .inode = inode };
}

fn populate_root_directory(self: *EXT2) Error!void {
    self.clear_file_list();

    const root = try self.fetch_inode(ROOT_INODE);
    if (root.mode & S_IFMT != S_IFDIR)
        return IO.Error.BadFormat;

    var it = self.dir_iter(root);
    while (try it.next()) |entry| {
        if (entry.header.inode == 0)
            continue;

        const name = entry.name();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
            continue;

        const node = try self.allocator.create(DentryL);
        node.* = .{
            .inode = entry.header.inode,
            .name_len = @intCast(name.len),
            .name_buf = entry.name_buf,
        };
        self.all_files.prepend(node);
    }
}

fn add_dentry(self: *EXT2, name: []const u8, inode_no: u32, file_type: u8) Error!void {
    const needed = dentry_size(name.len);
    var root = try self.fetch_inode(ROOT_INODE);

    var it = self.dir_iter(root);
    while (try it.next()) |entry| {
        if (entry.header.inode == 0 and entry.header.rec_len >= needed) {
            var header = entry.header;
            header.inode = inode_no;
            header.name_len = @intCast(name.len);
            header.file_type = file_type;
            try self.write_struct(entry.pos, header);
            try self.write_bytes(entry.pos + DENTRY_HEADER_SIZE, name);
            return;
        }

        const used = dentry_size(entry.header.name_len);
        if (entry.header.inode != 0 and entry.header.rec_len >= used + needed) {
            var old = entry.header;
            const slack = old.rec_len - used;
            old.rec_len = used;
            try self.write_struct(entry.pos, old);

            const header = DentryHeader{
                .inode = inode_no,
                .rec_len = slack,
                .name_len = @intCast(name.len),
                .file_type = file_type,
            };
            try self.write_struct(entry.pos + used, header);
            try self.write_bytes(entry.pos + used + DENTRY_HEADER_SIZE, name);
            return;
        }
    }

    // No slack anywhere: grow the directory by one block.
    const blockno = try self.alloc_zeroed_block(&root);
    try self.attach_data_block(&root, root.size / self.blksz, blockno);
    root.size += self.blksz;
    try self.write_inode(ROOT_INODE, root);

    const header = DentryHeader{
        .inode = inode_no,
        .rec_len = @intCast(self.blksz),
        .name_len = @intCast(name.len),
        .file_type = file_type,
    };
    try self.write_struct(self.blk_pos(blockno), header);
    try self.write_bytes(self.blk_pos(blockno) + DENTRY_HEADER_SIZE, name);
}

fn remove_dentry(self: *EXT2, name: []const u8) Error!?u32 {
    const root = try self.fetch_inode(ROOT_INODE);
    var it = self.dir_iter(root);

    var prev: ?DirEntry = null;
    while (try it.next()) |entry| {
        if (entry.header.inode != 0 and std.mem.eql(u8, entry.name(), name)) {
            const inode_no = entry.header.inode;
            const same_block = if (prev) |p| p.block_start == entry.block_start else false;

            if (same_block) {
                // Fold the entry into its predecessor's record.
                var header = prev.?.header;
                header.rec_len += entry.header.rec_len;
                try self.write_struct(prev.?.pos, header);
            } else {
                // First entry of its block: leave a hole.
                var header = entry.header;
                header.inode = 0;
                try self.write_struct(entry.pos, header);
            }
            return inode_no;
        }
        prev = entry;
    }
    return null;
}

fn dentry_size(name_len: usize) u16 {
    return @intCast(std.mem.alignForward(usize, DENTRY_HEADER_SIZE + name_len, 4));
}

// Inode table access

fn inode_pos(self: *EXT2, inode_no: u32) IO.Error!u64 {
    if (inode_no == 0 or inode_no > self.superblock.n_inodes)
        return IO.Error.BadFormat;

    const index = inode_no - 1;
    const group = index / self.superblock.inodes_per_group;
    const slot = index % self.superblock.inodes_per_group;
    const desc = try self.read_struct(BlockGroupDescriptor, self.group_desc_pos(group));
    return self.blk_pos(desc.inode_table) + @as(u64, slot) * self.superblock.inode_sz();
}

fn fetch_inode(self: *EXT2, inode_no: u32) IO.Error!Inode {
    return self.read_struct(Inode, try self.inode_pos(inode_no));
}

fn write_inode(self: *EXT2, inode_no: u32, inode: Inode) IO.Error!void {
    try self.write_struct(try self.inode_pos(inode_no), inode);
}

/// Like write_inode, but also zeroes the extension bytes of larger on-disk
/// inodes so a freshly created inode carries no stale extended attributes.
fn write_full_inode(self: *EXT2, inode_no: u32, inode: Inode) IO.Error!void {
    const pos = try self.inode_pos(inode_no);
    try self.write_struct(pos, inode);

    const zeros = [_]u8{0} ** 64;
    var off: u64 = @sizeOf(Inode);
    while (off < self.superblock.inode_sz()) {
        const n: usize = @intCast(@min(self.superblock.inode_sz() - off, zeros.len));
        try self.write_bytes(pos + off, zeros[0..n]);
        off += n;
    }
}

// Block and inode allocation

fn alloc_block(self: *EXT2) IO.Error!u32 {
    const sb = &self.superblock;

    var group: u32 = 0;
    while (group < sb.group_count()) : (group += 1) {
        var desc = try self.read_struct(BlockGroupDescriptor, self.group_desc_pos(group));
        if (desc.n_free_blocks == 0)
            continue;

        const covered = sb.n_blocks - sb.first_data_block - group * sb.blocks_per_group;
        const limit = @min(sb.blocks_per_group, covered);
        const bit = (try self.bitmap_find_zero(desc.block_bitmap, limit)) orelse continue;

        try self.bitmap_set(desc.block_bitmap, bit, true);
        desc.n_free_blocks -= 1;
        try self.write_struct(self.group_desc_pos(group), desc);
        sb.n_free_blocks -= 1;
        try self.write_struct(SUPERBLOCK_POS, sb.*);

        return group * sb.blocks_per_group + bit + sb.first_data_block;
    }

    return IO.Error.Error;
}

fn free_block(self: *EXT2, blockno: u32) IO.Error!void {
    const sb = &self.superblock;
    if (blockno < sb.first_data_block or blockno >= sb.n_blocks)
        return IO.Error.BadFormat;

    const rel = blockno - sb.first_data_block;
    const group = rel / sb.blocks_per_group;
    const bit = rel % sb.blocks_per_group;

    var desc = try self.read_struct(BlockGroupDescriptor, self.group_desc_pos(group));
    try self.bitmap_set(desc.block_bitmap, bit, false);
    desc.n_free_blocks += 1;
    try self.write_struct(self.group_desc_pos(group), desc);
    sb.n_free_blocks += 1;
    try self.write_struct(SUPERBLOCK_POS, sb.*);
}

fn alloc_inode(self: *EXT2) IO.Error!u32 {
    const sb = &self.superblock;

    var group: u32 = 0;
    while (group < sb.group_count()) : (group += 1) {
        var desc = try self.read_struct(BlockGroupDescriptor, self.group_desc_pos(group));
        if (desc.n_free_inodes == 0)
            continue;

        const bit = (try self.bitmap_find_zero(desc.inode_bitmap, sb.inodes_per_group)) orelse continue;

        try self.bitmap_set(desc.inode_bitmap, bit, true);
        desc.n_free_inodes -= 1;
        try self.write_struct(self.group_desc_pos(group), desc);
        sb.n_free_inodes -= 1;
        try self.write_struct(SUPERBLOCK_POS, sb.*);

        return group * sb.inodes_per_group + bit + 1;
    }

    return IO.Error.Error;
}

fn free_inode(self: *EXT2, inode_no: u32) IO.Error!void {
    const sb = &self.superblock;
    if (inode_no == 0 or inode_no > sb.n_inodes)
        return IO.Error.BadFormat;

    const index = inode_no - 1;
    const group = index / sb.inodes_per_group;
    const bit = index % sb.inodes_per_group;

    var desc = try self.read_struct(BlockGroupDescriptor, self.group_desc_pos(group));
    try self.bitmap_set(desc.inode_bitmap, bit, false);
    desc.n_free_inodes += 1;
    try self.write_struct(self.group_desc_pos(group), desc);
    sb.n_free_inodes += 1;
    try self.write_struct(SUPERBLOCK_POS, sb.*);
}

fn alloc_zeroed_block(self: *EXT2, inode: *Inode) IO.Error!u32 {
    const blockno = try self.alloc_block();
    try self.zero_fs_block(blockno);
    inode.sectors += self.blksz / Cache.BLKSZ;
    return blockno;
}

fn zero_fs_block(self: *EXT2, blockno: u32) IO.Error!void {
    const base = self.blk_pos(blockno);
    var off: u32 = 0;
    while (off < self.blksz) : (off += Cache.BLKSZ) {
        const block = try self.cache.get(base + off);
        defer self.cache.release(block, .dirty);
        @memset(block, 0);
    }
}

fn bitmap_find_zero(self: *EXT2, bitmap_block: u32, limit: u32) IO.Error!?u32 {
    const base = self.blk_pos(bitmap_block);

    var chunk: u32 = 0;
    while (chunk * Cache.BLKSZ < self.blksz and chunk * Cache.BLKSZ * 8 < limit) : (chunk += 1) {
        const block = try self.cache.get_const(base + chunk * Cache.BLKSZ);
        defer self.cache.release(block, .clean);

        for (block, 0..) |byte, byte_idx| {
            if (byte == 0xFF)
                continue;

            var bit_idx: u3 = 0;
            while (true) : (bit_idx += 1) {
                const index = (chunk * Cache.BLKSZ + @as(u32, @intCast(byte_idx))) * 8 + bit_idx;
                if (index >= limit)
                    return null;
                if (byte & (@as(u8, 1) << bit_idx) == 0)
                    return index;
                if (bit_idx == 7)
                    break;
            }
        }
    }

    return null;
}

fn bitmap_set(self: *EXT2, bitmap_block: u32, index: u32, used: bool) IO.Error!void {
    const pos = self.blk_pos(bitmap_block) + index / 8;
    const base = pos & ~@as(u64, Cache.BLKSZ - 1);
    const offset: usize = @intCast(pos % Cache.BLKSZ);
    const bit: u3 = @intCast(index % 8);

    const block = try self.cache.get(base);
    defer self.cache.release(block, .dirty);

    if (used)
        block[offset] |= @as(u8, 1) << bit
    else
        block[offset] &= ~(@as(u8, 1) << bit);
}

// Byte-granular disk access on top of the 512-byte sector cache

fn read_bytes(self: *EXT2, pos: u64, buf: []u8) IO.Error!void {
    var copied: usize = 0;
    while (copied < buf.len) {
        const cur = pos + copied;
        const base = cur & ~@as(u64, Cache.BLKSZ - 1);
        const offset: usize = @intCast(cur % Cache.BLKSZ);
        const nread = @min(Cache.BLKSZ - offset, buf.len - copied);

        const block = try self.cache.get_const(base);
        defer self.cache.release(block, .clean);

        @memcpy(buf[copied..][0..nread], block[offset..][0..nread]);
        copied += nread;
    }
}

fn write_bytes(self: *EXT2, pos: u64, buf: []const u8) IO.Error!void {
    var copied: usize = 0;
    while (copied < buf.len) {
        const cur = pos + copied;
        const base = cur & ~@as(u64, Cache.BLKSZ - 1);
        const offset: usize = @intCast(cur % Cache.BLKSZ);
        const nwritten = @min(Cache.BLKSZ - offset, buf.len - copied);

        const block = try self.cache.get(base);
        defer self.cache.release(block, .dirty);

        @memcpy(block[offset..][0..nwritten], buf[copied..][0..nwritten]);
        copied += nwritten;
    }
}

fn read_ptr(self: *EXT2, blockno: u32, index: u64) IO.Error!u32 {
    var value: u32 = undefined;
    try self.read_bytes(self.blk_pos(blockno) + index * @sizeOf(u32), std.mem.asBytes(&value));
    return value;
}

fn write_ptr(self: *EXT2, blockno: u32, index: u64, value: u32) IO.Error!void {
    try self.write_bytes(self.blk_pos(blockno) + index * @sizeOf(u32), std.mem.asBytes(&value));
}

fn read_struct(self: *EXT2, comptime T: type, pos: u64) IO.Error!T {
    var value: T = undefined;
    try self.read_bytes(pos, std.mem.asBytes(&value));
    return value;
}

fn write_struct(self: *EXT2, pos: u64, value: anytype) IO.Error!void {
    try self.write_bytes(pos, std.mem.asBytes(&value));
}

// Position helpers

fn blk_pos(self: *const EXT2, blockno: u32) u64 {
    return @as(u64, blockno) * self.blksz;
}

/// The group descriptor table starts in the block after the superblock.
fn group_desc_pos(self: *const EXT2, group: u32) u64 {
    const table_block = self.superblock.first_data_block + 1;
    return self.blk_pos(table_block) + @as(u64, group) * @sizeOf(BlockGroupDescriptor);
}

fn ptrs_per_block(self: *const EXT2) u32 {
    return self.blksz / @sizeOf(u32);
}

fn block_count(size: u64, blksz: u32) u64 {
    return (size + blksz - 1) / blksz;
}

// Lookup helpers

fn find_file(self: *EXT2, name: []const u8) ?*DentryL {
    var curr = self.all_files.head;
    while (curr) |node| : (curr = node.next) {
        if (std.mem.eql(u8, node.name(), name))
            return node;
    }
    return null;
}

fn find_open_file(self: *EXT2, name: []const u8) ?*File {
    var curr = self.open_files.head;
    while (curr) |file| : (curr = file.next) {
        if (std.mem.eql(u8, file.name(), name))
            return file;
    }
    return null;
}

fn clear_file_list(self: *EXT2) void {
    while (self.all_files.pop(self.all_files.head)) |node|
        self.allocator.destroy(node);
}

fn now() u32 {
    return @truncate(rtc.time() / std.time.ns_per_s);
}

fn valid_name(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_LEN)
        return false;
    for (name) |char|
        if (char == 0 or char == '/')
            return false;
    return true;
}
