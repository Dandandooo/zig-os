// Host-side mkfs for ext2 rev 1 (as read by src/file/ext2.zig).
//
// Usage: mkfs_ext2 <image> <size> <files...>
//   e.g. mkfs_ext2 ext2.raw 16M files/wav/* files/bin/*
//
// Produces a real ext2 filesystem (verifiable with e2fsck): 1024-byte
// blocks, 8192 blocks per group, 512 inodes per group, filetype dentries.
// All given files land in the root directory. Every group carries a backup
// superblock and group descriptor table.

const std = @import("std");

const BLKSZ = 1024;
const INOSZ = 128;
const FIRST_DATA_BLOCK = 1;
const BLOCKS_PER_GROUP = 8 * BLKSZ; // block bitmap must fit one block
const INODES_PER_GROUP = 512;
const INODE_TABLE_BLOCKS = INODES_PER_GROUP * INOSZ / BLKSZ;
const PTRS_PER_BLOCK = BLKSZ / @sizeOf(u32);
const N_DIRECT = 12;
const FIRST_INO = 11;
const ROOT_INO = 2;
const MAGIC = 0xEF53;
const INCOMPAT_FILETYPE = 0x2;

const FT_REG_FILE = 1;
const FT_DIR = 2;

const MAX_FILE_SIZE = (N_DIRECT + PTRS_PER_BLOCK + PTRS_PER_BLOCK * PTRS_PER_BLOCK) * BLKSZ;

const Superblock = extern struct {
    n_inodes: u32,
    n_blocks: u32,
    n_reserved_blocks: u32,
    n_free_blocks: u32,
    n_free_inodes: u32,
    first_data_block: u32,
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
    first_ino: u32,
    inode_size: u16,
    block_group_nr: u16,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
};

const BlockGroupDescriptor = extern struct {
    block_bitmap: u32,
    inode_bitmap: u32,
    inode_table: u32,
    n_free_blocks: u16,
    n_free_inodes: u16,
    n_dirs: u16,
    _pad: u16 = 0,
    _reserved: [12]u8 = @splat(0),
};

const Inode = extern struct {
    mode: u16 = 0,
    uid: u16 = 0,
    size: u32 = 0,
    atime: u32 = 0,
    ctime: u32 = 0,
    mtime: u32 = 0,
    dtime: u32 = 0,
    gid: u16 = 0,
    links: u16 = 0,
    sectors: u32 = 0,
    flags: u32 = 0,
    osd1: u32 = 0,
    block: [15]u32 = @splat(0),
    generation: u32 = 0,
    file_acl: u32 = 0,
    dir_acl: u32 = 0,
    faddr: u32 = 0,
    osd2: [12]u8 = @splat(0),
};

comptime {
    if (@sizeOf(Superblock) != 104) @compileError("superblock layout drifted");
    if (@sizeOf(BlockGroupDescriptor) != 32) @compileError("group descriptor layout drifted");
    if (@sizeOf(Inode) != INOSZ) @compileError("inode layout drifted");
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("mkfs_ext2: " ++ fmt ++ "\n", args);
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
    block_count: u32,
    n_groups: u32,
    gdt_blocks: u32,
    group_used: []u32,
    cursor: u32 = FIRST_DATA_BLOCK,

    fn group_start(group: u32) u32 {
        return FIRST_DATA_BLOCK + group * BLOCKS_PER_GROUP;
    }

    fn group_blocks(self: *const Image, group: u32) u32 {
        return @min(BLOCKS_PER_GROUP, self.block_count - group_start(group));
    }

    fn block_bitmap_block(self: *const Image, group: u32) u32 {
        return group_start(group) + 1 + self.gdt_blocks;
    }

    fn inode_bitmap_block(self: *const Image, group: u32) u32 {
        return self.block_bitmap_block(group) + 1;
    }

    fn inode_table_block(self: *const Image, group: u32) u32 {
        return self.inode_bitmap_block(group) + 1;
    }

    fn block(self: *Image, blockno: u32) []u8 {
        const base = @as(usize, blockno) * BLKSZ;
        return self.buf[base .. base + BLKSZ];
    }

    fn block_used(self: *Image, blockno: u32) bool {
        const rel = blockno - FIRST_DATA_BLOCK;
        const bitmap = self.block(self.block_bitmap_block(rel / BLOCKS_PER_GROUP));
        const bit = rel % BLOCKS_PER_GROUP;
        return bitmap[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0;
    }

    fn mark_block(self: *Image, blockno: u32) void {
        const rel = blockno - FIRST_DATA_BLOCK;
        const group = rel / BLOCKS_PER_GROUP;
        const bitmap = self.block(self.block_bitmap_block(group));
        const bit = rel % BLOCKS_PER_GROUP;
        bitmap[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
        self.group_used[group] += 1;
    }

    fn take_block(self: *Image) u32 {
        while (self.cursor < self.block_count) : (self.cursor += 1) {
            if (!self.block_used(self.cursor)) {
                self.mark_block(self.cursor);
                defer self.cursor += 1;
                return self.cursor;
            }
        }
        fatal("image full: need a bigger size", .{});
    }

    fn mark_inode(self: *Image, ino: u32) void {
        const index = ino - 1;
        const bitmap = self.block(self.inode_bitmap_block(index / INODES_PER_GROUP));
        const bit = index % INODES_PER_GROUP;
        bitmap[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
    }

    fn write_inode(self: *Image, ino: u32, inode: Inode) void {
        const index = ino - 1;
        const table = self.inode_table_block(index / INODES_PER_GROUP);
        const slot = index % INODES_PER_GROUP;
        const base = @as(usize, table) * BLKSZ + @as(usize, slot) * INOSZ;
        @memcpy(self.buf[base .. base + INOSZ], std.mem.asBytes(&inode));
    }
};

fn store_file(img: *Image, data: []const u8, mode: u16) Inode {
    var inode = Inode{
        .mode = mode,
        .size = @intCast(data.len),
        .links = 1,
    };

    var off: usize = 0;
    var logical: usize = 0;
    while (off < data.len) : (logical += 1) {
        const blockno = img.take_block();
        inode.sectors += BLKSZ / 512;
        const chunk = data[off..@min(off + BLKSZ, data.len)];
        @memcpy(img.block(blockno)[0..chunk.len], chunk);
        off += BLKSZ;

        attach(img, &inode, logical, blockno);
    }

    return inode;
}

fn attach(img: *Image, inode: *Inode, logical: usize, blockno: u32) void {
    if (logical < N_DIRECT) {
        inode.block[logical] = blockno;
        return;
    }

    var idx = logical - N_DIRECT;
    if (idx < PTRS_PER_BLOCK) {
        if (inode.block[12] == 0) {
            inode.block[12] = img.take_block();
            inode.sectors += BLKSZ / 512;
        }
        put_ptr(img, inode.block[12], idx, blockno);
        return;
    }

    idx -= PTRS_PER_BLOCK;
    if (idx >= PTRS_PER_BLOCK * PTRS_PER_BLOCK)
        fatal("file exceeds max file size ({d} bytes)", .{MAX_FILE_SIZE});

    if (inode.block[13] == 0) {
        inode.block[13] = img.take_block();
        inode.sectors += BLKSZ / 512;
    }

    const outer_idx = idx / PTRS_PER_BLOCK;
    var inner = get_ptr(img, inode.block[13], outer_idx);
    if (inner == 0) {
        inner = img.take_block();
        inode.sectors += BLKSZ / 512;
        put_ptr(img, inode.block[13], outer_idx, inner);
    }
    put_ptr(img, inner, idx % PTRS_PER_BLOCK, blockno);
}

fn put_ptr(img: *Image, ptr_block: u32, idx: usize, value: u32) void {
    std.mem.writeInt(u32, img.block(ptr_block)[idx * 4 ..][0..4], value, .little);
}

fn get_ptr(img: *Image, ptr_block: u32, idx: usize) u32 {
    return std.mem.readInt(u32, img.block(ptr_block)[idx * 4 ..][0..4], .little);
}

const DirBuilder = struct {
    img: *Image,
    inode: Inode,
    blockno: u32 = 0,
    offset: usize = 0,
    last_offset: usize = 0,
    logical: usize = 0,

    fn add(self: *DirBuilder, ino: u32, name: []const u8, file_type: u8) void {
        const size = std.mem.alignForward(usize, 8 + name.len, 4);

        if (self.blockno == 0 or self.offset + size > BLKSZ)
            self.next_block();

        const entry = self.img.block(self.blockno)[self.offset..];
        std.mem.writeInt(u32, entry[0..4], ino, .little);
        std.mem.writeInt(u16, entry[4..6], @intCast(size), .little);
        entry[6] = @intCast(name.len);
        entry[7] = file_type;
        @memcpy(entry[8 .. 8 + name.len], name);

        self.last_offset = self.offset;
        self.offset += size;
    }

    fn next_block(self: *DirBuilder) void {
        self.finish_block();
        self.blockno = self.img.take_block();
        self.inode.sectors += BLKSZ / 512;
        attach(self.img, &self.inode, self.logical, self.blockno);
        self.logical += 1;
        self.inode.size += BLKSZ;
        self.offset = 0;
        self.last_offset = 0;
    }

    fn finish_block(self: *DirBuilder) void {
        if (self.blockno == 0)
            return;
        // The last entry's record extends to the end of the block.
        const entry = self.img.block(self.blockno)[self.last_offset..];
        std.mem.writeInt(u16, entry[4..6], @intCast(BLKSZ - self.last_offset), .little);
    }
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;

    var args_list: std.ArrayList([]const u8) = .empty;
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    while (args_it.next()) |arg| try args_list.append(alloc, arg);
    const args = args_list.items;
    if (args.len < 3)
        fatal("usage: mkfs_ext2 <image> <size> <files...>", .{});

    const out_path = args[1];
    const total_size = parse_size(args[2]);
    const paths = args[3..];

    if (total_size % BLKSZ != 0) fatal("size must be a multiple of {d}", .{BLKSZ});
    const block_count: u32 = @intCast(total_size / BLKSZ);
    if (block_count <= FIRST_DATA_BLOCK) fatal("image too small", .{});

    const n_groups: u32 = (block_count - FIRST_DATA_BLOCK + BLOCKS_PER_GROUP - 1) / BLOCKS_PER_GROUP;
    const gdt_blocks: u32 = (n_groups * @sizeOf(BlockGroupDescriptor) + BLKSZ - 1) / BLKSZ;
    const n_inodes = n_groups * INODES_PER_GROUP;

    if (paths.len + FIRST_INO > n_inodes) fatal("too many files for {d} inodes", .{n_inodes});

    var img = Image{
        .buf = try alloc.alloc(u8, total_size),
        .block_count = block_count,
        .n_groups = n_groups,
        .gdt_blocks = gdt_blocks,
        .group_used = try alloc.alloc(u32, n_groups),
    };
    @memset(img.buf, 0);
    @memset(img.group_used, 0);

    // Metadata blocks and bitmap padding first, so take_block skips them.
    for (0..n_groups) |g| {
        const group: u32 = @intCast(g);
        const start = Image.group_start(group);
        const overhead = 1 + gdt_blocks + 2 + INODE_TABLE_BLOCKS;
        if (img.group_blocks(group) <= overhead)
            fatal("last group too small; pick a different image size", .{});

        // Padding bits past the end of the group are set to 1.
        const bitmap = img.block(img.block_bitmap_block(group));
        var bit: u32 = img.group_blocks(group);
        while (bit < 8 * BLKSZ) : (bit += 1)
            bitmap[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);

        const ibitmap = img.block(img.inode_bitmap_block(group));
        bit = INODES_PER_GROUP;
        while (bit < 8 * BLKSZ) : (bit += 1)
            ibitmap[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);

        for (start..start + overhead) |b|
            img.mark_block(@intCast(b));
    }

    // Reserved inodes 1..10.
    for (1..FIRST_INO) |ino|
        img.mark_inode(@intCast(ino));

    // Root directory: ".", "..", then one entry per file.
    var root = DirBuilder{ .img = &img, .inode = .{ .mode = 0x4000 | 0o755, .links = 2 } };
    root.add(ROOT_INO, ".", FT_DIR);
    root.add(ROOT_INO, "..", FT_DIR);

    for (paths, 0..) |path, i| {
        const name = std.fs.path.basename(path);
        if (name.len == 0 or name.len > 255)
            fatal("bad file name: {s}", .{name});

        const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err|
            fatal("cannot read {s}: {s}", .{ path, @errorName(err) });
        if (data.len > MAX_FILE_SIZE)
            fatal("{s} is larger than the max file size ({d} bytes)", .{ path, MAX_FILE_SIZE });

        const ino: u32 = @intCast(FIRST_INO + i);
        img.mark_inode(ino);
        img.write_inode(ino, store_file(&img, data, 0x8000 | 0o644));
        root.add(ino, name, FT_REG_FILE);
    }

    root.finish_block();
    img.mark_inode(ROOT_INO);
    img.write_inode(ROOT_INO, root.inode);

    // Group descriptor table (identical copy in every group).
    var free_blocks: u32 = 0;
    for (0..n_groups) |g| {
        const group: u32 = @intCast(g);
        const gfree: u32 = img.group_blocks(group) - img.group_used[group];
        free_blocks += gfree;

        const used_inodes: u32 = if (g == 0) FIRST_INO - 1 + @as(u32, @intCast(paths.len)) else 0;
        const desc = BlockGroupDescriptor{
            .block_bitmap = img.block_bitmap_block(group),
            .inode_bitmap = img.inode_bitmap_block(group),
            .inode_table = img.inode_table_block(group),
            .n_free_blocks = @intCast(gfree),
            .n_free_inodes = @intCast(INODES_PER_GROUP - used_inodes),
            .n_dirs = if (g == 0) 1 else 0,
        };

        const base = @as(usize, Image.group_start(0) + 1) * BLKSZ + g * @sizeOf(BlockGroupDescriptor);
        @memcpy(img.buf[base .. base + @sizeOf(BlockGroupDescriptor)], std.mem.asBytes(&desc));
    }

    const superblock = Superblock{
        .n_inodes = n_inodes,
        .n_blocks = block_count,
        .n_reserved_blocks = 0,
        .n_free_blocks = free_blocks,
        .n_free_inodes = n_inodes - (FIRST_INO - 1) - @as(u32, @intCast(paths.len)),
        .first_data_block = FIRST_DATA_BLOCK,
        .log_block_size = 0,
        .log_frag_size = 0,
        .blocks_per_group = BLOCKS_PER_GROUP,
        .frags_per_group = BLOCKS_PER_GROUP,
        .inodes_per_group = INODES_PER_GROUP,
        .mount_time = 0,
        .write_time = 0,
        .mount_count = 0,
        .max_mount_count = 0xFFFF,
        .magic = MAGIC,
        .state = 1,
        .errors = 1,
        .minor_rev = 0,
        .last_check = 0,
        .check_interval = 0,
        .creator_os = 0,
        .rev_level = 1,
        .def_resuid = 0,
        .def_resgid = 0,
        .first_ino = FIRST_INO,
        .inode_size = INOSZ,
        .block_group_nr = 0,
        .feature_compat = 0,
        .feature_incompat = INCOMPAT_FILETYPE,
        .feature_ro_compat = 0,
    };
    @memcpy(img.block(FIRST_DATA_BLOCK)[0..@sizeOf(Superblock)], std.mem.asBytes(&superblock));

    // Backup superblock + descriptor table in every other group.
    for (1..n_groups) |g| {
        const group: u32 = @intCast(g);
        const start = Image.group_start(group);

        var backup = superblock;
        backup.block_group_nr = @intCast(g);
        @memcpy(img.block(start)[0..@sizeOf(Superblock)], std.mem.asBytes(&backup));

        for (0..gdt_blocks) |i| {
            const src = img.block(Image.group_start(0) + 1 + @as(u32, @intCast(i)));
            @memcpy(img.block(start + 1 + @as(u32, @intCast(i))), src);
        }
    }

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = img.buf }) catch |err|
        fatal("cannot write {s}: {s}", .{ out_path, @errorName(err) });

    std.debug.print("mkfs_ext2: wrote {s} ({d} blocks, {d} groups, {d} files, {d} blocks free)\n", .{
        out_path, block_count, n_groups, paths.len, free_blocks,
    });
}
