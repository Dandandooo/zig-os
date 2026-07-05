const std = @import("std");
const IO = @import("../../api/io.zig");
const RBFS = @import("../../file/rbfs.zig");
const heap = @import("../../mem/heap.zig");
const util = @import("../util.zig");

const BIGLEV_SIZE: usize = 10_133_912;
const TESTFILE_INITIAL_SIZE: usize = 0x1337;
const DATA_BLOCK_COUNT: u32 = 20_000;
const BITMAP_BLOCK_COUNT: u32 = DATA_BLOCK_COUNT / (RBFS.BLKSZ * 8) + 1;
const INODE_BLOCK_COUNT: u32 = 1;
const BLOCK_COUNT: u32 = 1 + BITMAP_BLOCK_COUNT + INODE_BLOCK_COUNT + DATA_BLOCK_COUNT;

const PTRS_PER_BLOCK = RBFS.BLKSZ / @sizeOf(u32);
const NUM_DIRECT_DATA_BLOCKS = 3;
const NUM_DINDIRECT_BLOCKS = 2;

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
	name: [13]u8,
};

comptime {
	if (@sizeOf(Inode) != RBFS.INOSZ)
		@compileError("rbfs inode size changed");
	if (@sizeOf(Dentry) != RBFS.DENSZ)
		@compileError("rbfs dentry size changed");
}

const Fixture = struct {
	allocator: std.mem.Allocator,
	image: []u8,
	backing: MemIO,
	fs: *RBFS,
	biglev: ?*IO = null,
};

const MemIO = struct {
	io: IO = .from(MemIO),
	image: []u8,

	pub fn readat(ioptr: *IO, buf: []u8, pos: u64) IO.Error!usize {
		const self: *MemIO = @fieldParentPtr("io", ioptr);
		const start: usize = @intCast(pos);
		const end = std.math.add(usize, start, buf.len) catch return IO.Error.Invalid;
		if (end > self.image.len)
			return IO.Error.Invalid;

		@memcpy(buf, self.image[start..end]);
		return buf.len;
	}

	pub fn writeat(ioptr: *IO, buf: []const u8, pos: u64) IO.Error!usize {
		const self: *MemIO = @fieldParentPtr("io", ioptr);
		const start: usize = @intCast(pos);
		const end = std.math.add(usize, start, buf.len) catch return IO.Error.Invalid;
		if (end > self.image.len)
			return IO.Error.Invalid;

		@memcpy(self.image[start..end], buf);
		return buf.len;
	}

	pub fn close(_: *IO) void {}
};

var context: Fixture = undefined;

pub fn run() util.test_results {
	init_fixture() catch |err| @panic(@errorName(err));
	defer teardown_fixture();

	return util.merge_results("RBFS", &.{
		util.run_tests("Initialization", &.{
			.{ .name = "Mount", .func = test_mount },
			.{ .name = "Load", .func = test_load },
			.{ .name = "IOCTL GETEND", .func = test_getend },
			.{ .name = "IOCTL GETBLKSZ", .func = test_getblksz },
		}),
		util.run_tests("Read", &.{
			.{ .name = "Direct read", .func = test_direct_read },
			.{ .name = "Indirect read", .func = test_indirect_read },
			.{ .name = "Rollover risk", .func = test_rollover_risk },
			.{ .name = "Dindirect read", .func = test_dindirect_read },
			.{ .name = "Double rollover risk", .func = test_double_rollover },
		}),
		util.run_tests("Read & Write", &.{
			.{ .name = "Direct overwrite", .func = test_direct_overwrite },
			.{ .name = "Direct restore", .func = test_direct_restore },
			.{ .name = "Indirect overwrite", .func = test_indirect_overwrite },
			.{ .name = "Indirect restore", .func = test_indirect_restore },
			.{ .name = "Dindirect overwrite", .func = test_dindirect_overwrite },
			.{ .name = "Dindirect restore", .func = test_dindirect_restore },
		}),
		util.run_tests("Create & Delete", &.{
			.{ .name = "Create file", .func = test_create_file },
			.{ .name = "Open created file", .func = test_open_created_file },
			.{ .name = "IOCTL SETEND", .func = test_setend },
			.{ .name = "Created file write", .func = test_fswrite },
			.{ .name = "Delete file", .func = test_delete_file },
			.{ .name = "Can't open deleted file", .func = test_cant_open_deleted_file },
		}),
	});
}

fn init_fixture() !void {
	const allocator = heap.allocator;
	context = .{
		.allocator = allocator,
		.image = try allocator.alloc(u8, @as(usize, BLOCK_COUNT) * RBFS.BLKSZ),
		.backing = undefined,
		.fs = undefined,
		.biglev = null,
	};

	@memset(context.image, 0);
	context.backing = .{ .image = context.image };

	try build_image(context.image);
	context.fs = try RBFS.mount(&context.backing.io, allocator);
}

fn teardown_fixture() void {
	if (context.biglev) |io| {
		io.close();
		context.biglev = null;
	}

	context.fs.deinit();
	context.allocator.free(context.image);
}

fn build_image(image: []u8) !void {
	write_value(Superblock, image[0..@sizeOf(Superblock)], .{
		.block_count = BLOCK_COUNT,
		.bitmap_block_count = BITMAP_BLOCK_COUNT,
		.inode_block_count = INODE_BLOCK_COUNT,
		.root_directory_inode = 0,
	});

	var builder = Builder{ .image = image };

	const root_blockno = builder.take_block();
	try util.expect(root_blockno == 0);

	var root_inode = Inode{
		.size = RBFS.DENSZ,
		.flags = 0,
		.block = [_]u32{0} ** NUM_DIRECT_DATA_BLOCKS,
		.indirect = 0,
		.dindirect = [_]u32{0} ** NUM_DINDIRECT_BLOCKS,
	};
	root_inode.block[0] = root_blockno;

	const biglev_dentry = Dentry{
		.inode = 1,
		.name = [_]u8{ 0, 0, 'b', 'i', 'g', 'l', 'e', 'v', 0, 0, 0, 0, 0 },
	};
	write_dentry(image, root_blockno, 0, biglev_dentry);

	var biglev_inode = Inode{
		.size = @intCast(BIGLEV_SIZE),
		.flags = 0,
		.block = [_]u32{0} ** NUM_DIRECT_DATA_BLOCKS,
		.indirect = 0,
		.dindirect = [_]u32{0} ** NUM_DINDIRECT_BLOCKS,
	};

	var file_offset: usize = 0;

	inline for (0..NUM_DIRECT_DATA_BLOCKS) |idx| {
		const data_blockno = builder.take_block();
		biglev_inode.block[idx] = data_blockno;
		write_file_block(image, data_blockno, file_offset);
		file_offset += RBFS.BLKSZ;
	}

	biglev_inode.indirect = builder.take_block();
	var indirect_ptrs = [_]u32{0} ** PTRS_PER_BLOCK;
	var indirect_idx: usize = 0;
	while (indirect_idx < PTRS_PER_BLOCK and file_offset < BIGLEV_SIZE) : (indirect_idx += 1) {
		const data_blockno = builder.take_block();
		indirect_ptrs[indirect_idx] = data_blockno;
		write_file_block(image, data_blockno, file_offset);
		file_offset += RBFS.BLKSZ;
	}
	write_ptr_block(image, biglev_inode.indirect, &indirect_ptrs);

	inline for (0..NUM_DINDIRECT_BLOCKS) |didx| {
		if (file_offset >= BIGLEV_SIZE)
			break;

		const outer_blockno = builder.take_block();
		biglev_inode.dindirect[didx] = outer_blockno;

		var outer_ptrs = [_]u32{0} ** PTRS_PER_BLOCK;
		var outer_idx: usize = 0;
		while (outer_idx < PTRS_PER_BLOCK and file_offset < BIGLEV_SIZE) : (outer_idx += 1) {
			const inner_blockno = builder.take_block();
			outer_ptrs[outer_idx] = inner_blockno;

			var inner_ptrs = [_]u32{0} ** PTRS_PER_BLOCK;
			var inner_idx: usize = 0;
			while (inner_idx < PTRS_PER_BLOCK and file_offset < BIGLEV_SIZE) : (inner_idx += 1) {
				const data_blockno = builder.take_block();
				inner_ptrs[inner_idx] = data_blockno;
				write_file_block(image, data_blockno, file_offset);
				file_offset += RBFS.BLKSZ;
			}

			write_ptr_block(image, inner_blockno, &inner_ptrs);
		}

		write_ptr_block(image, outer_blockno, &outer_ptrs);
	}

	const inode_base = (1 + BITMAP_BLOCK_COUNT) * RBFS.BLKSZ;
	write_value(Inode, image[inode_base..][0..@sizeOf(Inode)], root_inode);
	write_value(Inode, image[inode_base + @sizeOf(Inode)..][0..@sizeOf(Inode)], biglev_inode);
}

const Builder = struct {
	image: []u8,
	next_data_block: u32 = 0,

	fn take_block(self: *Builder) u32 {
		const blockno = self.next_data_block;
		self.next_data_block += 1;
		mark_used(self.image, blockno);
		return blockno;
	}
};

fn mark_used(image: []u8, blockno: u32) void {
	const bitmap_block_idx = blockno / (RBFS.BLKSZ * 8);
	const bit_in_block = blockno % (RBFS.BLKSZ * 8);
	const byte_idx: usize = @intCast(bit_in_block / 8);
	const bit_idx: u3 = @intCast(bit_in_block % 8);
	const bitmap_base: usize = @intCast((1 + bitmap_block_idx) * RBFS.BLKSZ);
	image[bitmap_base + byte_idx] |= @as(u8, 1) << bit_idx;
}

fn data_block_slice(image: []u8, blockno: u32) []u8 {
	const data_base: usize = @intCast((1 + BITMAP_BLOCK_COUNT + INODE_BLOCK_COUNT + blockno) * RBFS.BLKSZ);
	return image[data_base .. data_base + RBFS.BLKSZ];
}

fn write_file_block(image: []u8, blockno: u32, file_offset: usize) void {
	const block = data_block_slice(image, blockno);
	const remaining = BIGLEV_SIZE - file_offset;
	const count = @min(RBFS.BLKSZ, remaining);
	var i: usize = 0;
	while (i < count) : (i += 1)
		block[i] = file_byte(file_offset + i);
	if (count < RBFS.BLKSZ)
		@memset(block[count..], 0);
}

fn write_ptr_block(image: []u8, blockno: u32, ptrs: []const u32) void {
	const block = data_block_slice(image, blockno);
	@memset(block, 0);
	for (ptrs, 0..) |ptr, idx|
		std.mem.writeInt(u32, block[(idx * @sizeOf(u32))..][0..@sizeOf(u32)], ptr, .little);
}

fn write_dentry(image: []u8, blockno: u32, index: usize, dentry: Dentry) void {
	const block = data_block_slice(image, blockno);
	const offset = index * RBFS.DENSZ;
	write_value(Dentry, block[offset..][0..@sizeOf(Dentry)], dentry);
}

fn write_value(comptime T: type, bytes: []u8, value: T) void {
	@memcpy(bytes[0..@sizeOf(T)], std.mem.asBytes(&value));
}

fn biglev_io() anyerror!*IO {
	try util.expect(context.biglev != null);
	return context.biglev.?;
}

fn fill_expected(buf: []u8, pos: usize) void {
	for (buf, 0..) |*byte, idx|
		byte.* = file_byte(pos + idx);
}

fn file_byte(pos: usize) u8 {
	return @intCast((pos * 17 + (pos / 7) * 3 + 0x0a) & 0xff);
}

fn test_mount() anyerror!void {
	try util.expect(context.fs.filecount() == 1);
}

fn test_load() anyerror!void {
	context.biglev = try context.fs.open("biglev");
	try util.expect(context.biglev != null);
}

fn test_getend() anyerror!void {
	const biglev = try biglev_io();
	try util.expect(try biglev.cntl(IO.IOCTL_GETEND, null) == @as(isize, @intCast(BIGLEV_SIZE)));
}

fn test_getblksz() anyerror!void {
	const biglev = try biglev_io();
	try util.expect(try biglev.cntl(IO.IOCTL_GETBLKSZ, null) == @as(isize, @intCast(RBFS.BLKSZ)));
}

fn test_direct_read() anyerror!void {
	const biglev = try biglev_io();
	var buf = [_]u8{0} ** 16;
	try util.expect(try biglev.readat(buf[0..], 0) == buf.len);

	var expected = [_]u8{0} ** 16;
	fill_expected(expected[0..], 0);
	try util.expect(std.mem.eql(u8, buf[0..], expected[0..]));
}

fn test_indirect_read() anyerror!void {
	const biglev = try biglev_io();
	var buf = [_]u8{0} ** 4;
	try util.expect(try biglev.readat(buf[0..], 0x1000) == buf.len);

	var expected = [_]u8{0} ** 4;
	fill_expected(expected[0..], 0x1000);
	try util.expect(std.mem.eql(u8, buf[0..], expected[0..]));
}

fn test_rollover_risk() anyerror!void {
	const biglev = try biglev_io();
	var buf = [_]u8{0} ** 32;
	try util.expect(try biglev.readat(buf[0..], 0x5f0) == buf.len);

	var expected = [_]u8{0} ** 32;
	fill_expected(expected[0..], 0x5f0);
	try util.expect(std.mem.eql(u8, buf[0..], expected[0..]));
}

fn test_dindirect_read() anyerror!void {
	const biglev = try biglev_io();
	var buf = [_]u8{0} ** 16;
	try util.expect(try biglev.readat(buf[0..], 0x10600) == buf.len);

	var expected = [_]u8{0} ** 16;
	fill_expected(expected[0..], 0x10600);
	try util.expect(std.mem.eql(u8, buf[0..], expected[0..]));
}

fn test_double_rollover() anyerror!void {
	const biglev = try biglev_io();
	var buf = [_]u8{0} ** 32;
	try util.expect(try biglev.readat(buf[0..], 0xfff0) == buf.len);

	var expected = [_]u8{0} ** 32;
	fill_expected(expected[0..], 0xfff0);
	try util.expect(std.mem.eql(u8, buf[0..], expected[0..]));
}

fn test_direct_overwrite() anyerror!void {
	const biglev = try biglev_io();
	const overwrite = [_]u8{ 0x13, 0x37, 0xc0, 0xd3, 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe, 0x12, 0x34, 0x56, 0x78 };
	try util.expect(try biglev.writeat(overwrite[0..], 0) == overwrite.len);

	var buf = [_]u8{0} ** 4;
	try util.expect(try biglev.readat(buf[0..], 0) == buf.len);
	try util.expect(std.mem.eql(u8, buf[0..], overwrite[0..4]));
}

fn test_direct_restore() anyerror!void {
	const biglev = try biglev_io();
	var expected = [_]u8{0} ** 16;
	fill_expected(expected[0..], 0);
	try util.expect(try biglev.writeat(expected[0..], 0) == expected.len);

	var buf = [_]u8{0} ** 16;
	try util.expect(try biglev.readat(buf[0..], 0) == buf.len);
	try util.expect(std.mem.eql(u8, buf[0..], expected[0..]));
}

fn test_indirect_overwrite() anyerror!void {
	const biglev = try biglev_io();
	const overwrite = [_]u8{ 0x13, 0x37, 0xc0, 0xd3 };
	try util.expect(try biglev.writeat(overwrite[0..], 0x1000) == overwrite.len);

	var buf = [_]u8{0} ** 4;
	try util.expect(try biglev.readat(buf[0..], 0x1000) == buf.len);
	try util.expect(std.mem.eql(u8, buf[0..], overwrite[0..]));
}

fn test_indirect_restore() anyerror!void {
	const biglev = try biglev_io();
	var expected = [_]u8{0} ** 4;
	fill_expected(expected[0..], 0x1000);
	try util.expect(try biglev.writeat(expected[0..], 0x1000) == expected.len);

	var buf = [_]u8{0} ** 4;
	try util.expect(try biglev.readat(buf[0..], 0x1000) == buf.len);
	try util.expect(std.mem.eql(u8, buf[0..], expected[0..]));
}

fn test_dindirect_overwrite() anyerror!void {
	const biglev = try biglev_io();
	const overwrite = [_]u8{ 0x13, 0x37, 0xc0, 0xd3, 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe, 0x12, 0x34, 0x56, 0x78 };
	try util.expect(try biglev.writeat(overwrite[0..], 0x10600) == overwrite.len);

	var buf = [_]u8{0} ** 16;
	try util.expect(try biglev.readat(buf[0..], 0x10600) == buf.len);
	try util.expect(std.mem.eql(u8, buf[0..], overwrite[0..]));
}

fn test_dindirect_restore() anyerror!void {
	const biglev = try biglev_io();
	var expected = [_]u8{0} ** 16;
	fill_expected(expected[0..], 0x10600);
	try util.expect(try biglev.writeat(expected[0..], 0x10600) == expected.len);

	var buf = [_]u8{0} ** 16;
	try util.expect(try biglev.readat(buf[0..], 0x10600) == buf.len);
	try util.expect(std.mem.eql(u8, buf[0..], expected[0..]));
}

fn test_create_file() anyerror!void {
	try context.fs.create("testfile");
}

fn test_open_created_file() anyerror!void {
	const fileio = try context.fs.open("testfile");
	defer fileio.close();

	try util.expectError(IO.Error.Busy, context.fs.open("testfile"));
}

fn test_setend() anyerror!void {
	const fileio = try context.fs.open("testfile");
	defer fileio.close();

	var size: u64 = TESTFILE_INITIAL_SIZE;
	try util.expect(try fileio.cntl(IO.IOCTL_SETEND, &size) >= 0);
	try util.expect(try fileio.cntl(IO.IOCTL_GETEND, null) == @as(isize, @intCast(TESTFILE_INITIAL_SIZE)));
}

fn test_fswrite() anyerror!void {
	const fileio = try context.fs.open("testfile");
	defer fileio.close();

	const text = "The FitnessGram Pacer test...";
	var buf = [_]u8{0} ** 32;
	@memcpy(buf[0..text.len], text);

	try util.expect(try fileio.writeat(buf[0..], 0) == buf.len);

	var readback = [_]u8{0} ** 32;
	try util.expect(try fileio.readat(readback[0..], 0) == readback.len);
	try util.expect(std.mem.eql(u8, buf[0..], readback[0..]));
}

fn test_delete_file() anyerror!void {
	try context.fs.delete("testfile");
}

fn test_cant_open_deleted_file() anyerror!void {
	try util.expectError(RBFS.Error.NotFound, context.fs.open("testfile"));
}
