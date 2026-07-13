// Host-side mkfs for the KTFS on-disk format (as implemented by src/file/rbfs.zig).
//
// Usage: mkfs_ktfs <image> <size> <max_inodes> <files...>
//   e.g. mkfs_ktfs ktfs.raw 64M 128 files/wav/*.wav files/bin/*
//
// Layout (512-byte blocks):
//   block 0                : superblock
//   blocks 1 .. 1+B        : block bitmap (bit i = data block i used, LSB first)
//   blocks 1+B .. 1+B+I    : inode table (32-byte inodes)
//   blocks 1+B+I ..        : data blocks (block pointers are data-relative)
//
// Inode 0 is the root directory; file n (argv order) gets inode n+1, matching
// the kernel driver's create() convention.

const std = @import("std");

const BLKSZ = 512;
const INOSZ = 32;
const DENSZ = 16;
const NAME_SIZE = DENSZ - @sizeOf(u16);
const MAX_FILENAME_LEN = NAME_SIZE - 1;

const NUM_DIRECT = 3;
const NUM_DINDIRECT = 2;
const PTRS_PER_BLOCK = BLKSZ / @sizeOf(u32);

const MAX_FILE_SIZE = (NUM_DIRECT + PTRS_PER_BLOCK +
    NUM_DINDIRECT * PTRS_PER_BLOCK * PTRS_PER_BLOCK) * BLKSZ;

const Superblock = extern struct {
    block_count: u32 align(1),
    bitmap_block_count: u32 align(1),
    inode_block_count: u32 align(1),
    root_directory_inode: u16 align(1),
};

const Inode = extern struct {
    size: u32,
    flags: u32,
    block: [NUM_DIRECT]u32,
    indirect: u32,
    dindirect: [NUM_DINDIRECT]u32,
};

comptime {
    if (@sizeOf(Inode) != INOSZ) @compileError("inode size drifted");
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("mkfs_ktfs: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn parse_size(text: []const u8) u64 {
    if (text.len == 0) fatal("empty size", .{});
    const unit: u64 = switch (text[text.len - 1]) {
        'K', 'k' => 1 << 10,
        'M', 'm' => 1 << 20,
        'G', 'g' => 1 << 30,
        else => 1,
    };
    const digits = if (unit == 1) text else text[0 .. text.len - 1];
    const n = std.fmt.parseInt(u64, digits, 10) catch fatal("invalid size: {s}", .{text});
    return n * unit;
}

const Image = struct {
    buf: []u8,
    bitmap_blocks: u32,
    inode_blocks: u32,
    data_blocks: u32,
    next_data: u32 = 0,

    fn data_base(self: *const Image) usize {
        return (1 + self.bitmap_blocks + self.inode_blocks) * BLKSZ;
    }

    fn take_block(self: *Image) u32 {
        if (self.next_data >= self.data_blocks) fatal("image full: need a bigger size", .{});
        const blockno = self.next_data;
        self.next_data += 1;

        const byte = 1 * BLKSZ + blockno / 8; // bitmap starts at block 1
        self.buf[byte] |= @as(u8, 1) << @intCast(blockno % 8);
        return blockno;
    }

    fn data_block(self: *Image, blockno: u32) []u8 {
        const base = self.data_base() + @as(usize, blockno) * BLKSZ;
        return self.buf[base .. base + BLKSZ];
    }

    fn write_inode(self: *Image, num: u16, inode: Inode) void {
        const base = (1 + self.bitmap_blocks) * BLKSZ + @as(usize, num) * INOSZ;
        @memcpy(self.buf[base .. base + INOSZ], std.mem.asBytes(&inode));
    }
};

fn store_file(img: *Image, data: []const u8) Inode {
    var inode = Inode{
        .size = @intCast(data.len),
        .flags = 0,
        .block = @splat(0),
        .indirect = 0,
        .dindirect = @splat(0),
    };

    var off: usize = 0;
    var logical: usize = 0;
    while (off < data.len) : (logical += 1) {
        const blockno = img.take_block();
        const chunk = data[off..@min(off + BLKSZ, data.len)];
        @memcpy(img.data_block(blockno)[0..chunk.len], chunk);
        off += BLKSZ;

        attach(img, &inode, logical, blockno);
    }

    return inode;
}

fn attach(img: *Image, inode: *Inode, logical: usize, blockno: u32) void {
    if (logical < NUM_DIRECT) {
        inode.block[logical] = blockno;
        return;
    }

    var idx = logical - NUM_DIRECT;
    if (idx < PTRS_PER_BLOCK) {
        if (inode.indirect == 0) inode.indirect = img.take_block();
        put_ptr(img, inode.indirect, idx, blockno);
        return;
    }

    idx -= PTRS_PER_BLOCK;
    const per_dindirect = PTRS_PER_BLOCK * PTRS_PER_BLOCK;
    const dind = idx / per_dindirect;
    if (dind >= NUM_DINDIRECT) fatal("file exceeds max file size ({d} bytes)", .{MAX_FILE_SIZE});

    if (inode.dindirect[dind] == 0) inode.dindirect[dind] = img.take_block();
    const outer = inode.dindirect[dind];
    const outer_idx = (idx % per_dindirect) / PTRS_PER_BLOCK;
    const inner_idx = idx % PTRS_PER_BLOCK;

    var inner = get_ptr(img, outer, outer_idx);
    if (inner == 0) {
        inner = img.take_block();
        put_ptr(img, outer, outer_idx, inner);
    }
    put_ptr(img, inner, inner_idx, blockno);
}

fn put_ptr(img: *Image, ptr_block: u32, idx: usize, value: u32) void {
    const block = img.data_block(ptr_block);
    std.mem.writeInt(u32, block[idx * 4 ..][0..4], value, .little);
}

fn get_ptr(img: *Image, ptr_block: u32, idx: usize) u32 {
    const block = img.data_block(ptr_block);
    return std.mem.readInt(u32, block[idx * 4 ..][0..4], .little);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;

    var args_list: std.ArrayList([]const u8) = .empty;
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    while (args_it.next()) |arg| try args_list.append(alloc, arg);
    const args = args_list.items;
    if (args.len < 4)
        fatal("usage: mkfs_ktfs <image> <size> <max_inodes> <files...>", .{});

    const out_path = args[1];
    const total_size = parse_size(args[2]);
    const max_inodes = std.fmt.parseInt(u32, args[3], 10) catch
        fatal("invalid inode count: {s}", .{args[3]});
    const paths = args[4..];

    if (total_size % BLKSZ != 0) fatal("size must be a multiple of {d}", .{BLKSZ});
    const block_count: u32 = @intCast(total_size / BLKSZ);
    const bitmap_blocks: u32 = (block_count + BLKSZ * 8 - 1) / (BLKSZ * 8);
    const inode_blocks: u32 = (max_inodes * INOSZ + BLKSZ - 1) / BLKSZ;
    if (paths.len + 1 > max_inodes) fatal("too many files for {d} inodes", .{max_inodes});

    // The kernel driver only reads root dentries from the direct blocks.
    const max_root_files = NUM_DIRECT * (BLKSZ / DENSZ);
    if (paths.len > max_root_files) fatal("too many files (max {d})", .{max_root_files});

    var img = Image{
        .buf = try alloc.alloc(u8, total_size),
        .bitmap_blocks = bitmap_blocks,
        .inode_blocks = inode_blocks,
        .data_blocks = block_count - 1 - bitmap_blocks - inode_blocks,
    };
    @memset(img.buf, 0);

    const superblock = Superblock{
        .block_count = block_count,
        .bitmap_block_count = bitmap_blocks,
        .inode_block_count = inode_blocks,
        .root_directory_inode = 0,
    };
    @memcpy(img.buf[0..@sizeOf(Superblock)], std.mem.asBytes(&superblock));

    // Root directory: as many direct blocks as the dentries need.
    var root = Inode{
        .size = @intCast(paths.len * DENSZ),
        .flags = 0,
        .block = @splat(0),
        .indirect = 0,
        .dindirect = @splat(0),
    };
    const root_blocks = (paths.len * DENSZ + BLKSZ - 1) / BLKSZ;
    for (0..@max(root_blocks, 1)) |i|
        root.block[i] = img.take_block();

    for (paths, 0..) |path, i| {
        const name = std.fs.path.basename(path);
        if (name.len > MAX_FILENAME_LEN)
            fatal("file name too long (max {d}): {s}", .{ MAX_FILENAME_LEN, name });

        const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err|
            fatal("cannot read {s}: {s}", .{ path, @errorName(err) });
        if (data.len > MAX_FILE_SIZE)
            fatal("{s} is larger than the max file size ({d} bytes)", .{ path, MAX_FILE_SIZE });

        const inode_no: u16 = @intCast(i + 1);
        img.write_inode(inode_no, store_file(&img, data));

        // Dentry in the root directory.
        const dentry_block = root.block[i / (BLKSZ / DENSZ)];
        const dentry = img.data_block(dentry_block)[(i % (BLKSZ / DENSZ)) * DENSZ ..][0..DENSZ];
        std.mem.writeInt(u16, dentry[0..2], inode_no, .little);
        @memset(dentry[2..], 0);
        @memcpy(dentry[2 .. 2 + name.len], name);
    }

    img.write_inode(0, root);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = img.buf }) catch |err|
        fatal("cannot write {s}: {s}", .{ out_path, @errorName(err) });

    std.debug.print("mkfs_ktfs: wrote {s} ({d} blocks, {d} files, {d} data blocks used)\n", .{
        out_path, block_count, paths.len, img.next_data,
    });
}
