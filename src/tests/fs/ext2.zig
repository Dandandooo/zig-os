// EXT2 driver tests against the real ext2.raw disk image.
//
// The image is built by `just mkfs_ext2` from the files/ folder and served
// through the second virtio block device; the "testfiles" manifest module
// records the name, size, and CRC32 of each file so the driver's reads can
// be verified byte-for-byte. Mutation tests are safe because `just test`
// rebuilds the image before every run. The fixture identifies the right
// vioblk instance by probing for the ext2 superblock magic, so the tests
// don't depend on device discovery order.

const std = @import("std");
const IO = @import("../../api/io.zig");
const EXT2 = @import("../../file/ext2.zig");
const RBFS = @import("../../file/rbfs.zig");
const FS = @import("../../file/fs.zig");
const dev = @import("../../dev/device.zig");
const heap = @import("../../mem/heap.zig");
const util = @import("../util.zig");
const cons = @import("../../console.zig");
const manifest = @import("testfiles");

const BLKSZ = 1024; // mkfs_ext2 always makes 1K-block images
const PTRS_PER_BLOCK = BLKSZ / @sizeOf(u32);
const DIRECT_CAP = 12 * BLKSZ;
const INDIRECT_CAP = DIRECT_CAP + PTRS_PER_BLOCK * BLKSZ;

const CHUNK_SIZE = 8 * BLKSZ;

var blkio: *IO = undefined;
var fs: *EXT2 = undefined;
var rbfs_nth: usize = 0;

pub fn run() util.test_results {
    comptime if (manifest.entries.len == 0)
        @compileError("files/ is empty; nothing to test against");

    init_fixture() catch |err| @panic(@errorName(err));
    defer teardown_fixture();

    return util.merge_results("EXT2", &.{
        util.run_tests("Mount", &.{
            .{ .name = "File count", .func = test_filecount },
            .{ .name = "Missing file", .func = test_missing_file },
            .{ .name = "Invalid names", .func = test_invalid_names },
            .{ .name = "Busy double open", .func = test_busy_double_open },
            .{ .name = "Reopen after close", .func = test_reopen_after_close },
            .{ .name = "Dot entries hidden", .func = test_dot_entries_hidden },
            .{ .name = "Directory listing", .func = test_list_files },
            .{ .name = "Listing overflow", .func = test_list_files_overflow },
        }),
        util.run_tests("VFS", &.{
            .{ .name = "Union mount", .func = test_vfs_mount },
            .{ .name = "Coexists with RBFS", .func = test_coexist_rbfs },
        }),
        util.run_tests("Content", &.{
            .{ .name = "File sizes", .func = test_sizes },
            .{ .name = "Checksums", .func = test_checksums },
            .{ .name = "Boundary reads", .func = test_boundary_reads },
            .{ .name = "Out of bounds read", .func = test_oob_read },
            .{ .name = "Zero-length IO", .func = test_zero_length_io },
        }),
        util.run_tests("Position", &.{
            .{ .name = "GETPOS/SETPOS", .func = test_position_ioctls },
            .{ .name = "SETEND shrink rejected", .func = test_setend_shrink },
            .{ .name = "Unknown IOCTL", .func = test_unknown_ioctl },
            .{ .name = "Sequential read (TODO)", .func = test_sequential_read },
        }),
        util.run_tests("Mutation", &.{
            .{ .name = "Overwrite & restore", .func = test_overwrite_restore },
            .{ .name = "Create file", .func = test_create },
            .{ .name = "Create duplicate", .func = test_create_duplicate },
            .{ .name = "IOCTL SETEND", .func = test_setend },
            .{ .name = "Write & readback", .func = test_write_readback },
            .{ .name = "Delete while open", .func = test_delete_while_open },
            .{ .name = "Delete missing", .func = test_delete_missing },
            .{ .name = "Delete file", .func = test_delete },
            .{ .name = "Remount sees mutations", .func = test_remount },
            .{ .name = "Originals intact", .func = test_originals_intact },
        }),
    });
}

fn init_fixture() !void {
    cons.disable();
    defer cons.enable();

    // Several vioblk devices are attached; probe each one's superblock
    // position for the ext2 magic to find our disk (the other holds ktfs).
    var ext2_nth: ?usize = null;
    var nth: usize = 0;
    while (nth < 4) : (nth += 1) {
        const io = dev.open_nth("vioblk", nth) catch break;

        var sector = [_]u8{0} ** 512;
        const ok = (io.readat(sector[0..], EXT2.SUPERBLOCK_POS) catch 0) == sector.len;
        io.close();

        if (ok and std.mem.readInt(u16, sector[56..58], .little) == EXT2.MAGIC)
            ext2_nth = nth
        else
            rbfs_nth = nth;
    }

    blkio = try dev.open_nth("vioblk", ext2_nth orelse return error.NoExt2Disk);
    fs = try EXT2.mount(blkio, heap.allocator);
}

fn teardown_fixture() void {
    cons.disable();
    defer cons.enable();

    fs.deinit();
    blkio.close();
}

fn largest_entry() manifest.Entry {
    var best = manifest.entries[0];
    for (manifest.entries) |entry| {
        if (entry.size > best.size) best = entry;
    }
    return best;
}

fn smallest_entry() manifest.Entry {
    var best = manifest.entries[0];
    for (manifest.entries) |entry| {
        if (entry.size < best.size) best = entry;
    }
    return best;
}

fn file_crc(io: *IO, size: u32) !u32 {
    const chunk = try heap.allocator.alloc(u8, CHUNK_SIZE);
    defer heap.allocator.free(chunk);

    var crc = std.hash.Crc32.init();
    var pos: u32 = 0;
    while (pos < size) {
        const len = @min(CHUNK_SIZE, size - pos);
        try util.expect(try io.readat(chunk[0..len], pos) == len);
        crc.update(chunk[0..len]);
        pos += len;
    }
    return crc.final();
}

// Mount

fn test_filecount() anyerror!void {
    try util.expect(fs.filecount() == manifest.entries.len);
}

fn test_missing_file() anyerror!void {
    try util.expectError(EXT2.Error.NotFound, fs.open("no-such-file"));
}

fn test_invalid_names() anyerror!void {
    const too_long = [_]u8{'a'} ** (EXT2.MAX_NAME_LEN + 1);
    try util.expectError(IO.Error.Invalid, fs.open(""));
    try util.expectError(IO.Error.Invalid, fs.open("no/slashes"));
    try util.expectError(IO.Error.Invalid, fs.open(too_long[0..]));
}

fn test_busy_double_open() anyerror!void {
    const io = try fs.open(manifest.entries[0].name);
    defer io.close();

    try util.expectError(IO.Error.Busy, fs.open(manifest.entries[0].name));
}

fn test_reopen_after_close() anyerror!void {
    const first = try fs.open(manifest.entries[0].name);
    first.close();

    const second = try fs.open(manifest.entries[0].name);
    second.close();
}

/// "." and ".." are real dentries on disk but must not surface as files.
fn test_dot_entries_hidden() anyerror!void {
    try util.expectError(EXT2.Error.NotFound, fs.open("."));
    try util.expectError(EXT2.Error.NotFound, fs.open(".."));
}

fn test_list_files() anyerror!void {
    var needed: usize = 0;
    for (manifest.entries) |entry| needed += entry.name.len + 1;

    const buf = try heap.allocator.alloc(u8, needed + 64);
    defer heap.allocator.free(buf);

    const len = try fs.get_files(buf);
    try util.expect(len == needed);

    const listing = buf[0..len];
    var newlines: usize = 0;
    for (listing) |char| newlines += @intFromBool(char == '\n');
    try util.expect(newlines == manifest.entries.len);

    for (manifest.entries) |entry|
        try util.expect(std.mem.indexOf(u8, listing, entry.name) != null);
}

fn test_list_files_overflow() anyerror!void {
    var tiny = [_]u8{0} ** 1;
    try util.expectError(IO.Error.Invalid, fs.get_files(tiny[0..]));
}

// VFS

/// The fs.zig union must be able to mount and drive an ext2 volume.
fn test_vfs_mount() anyerror!void {
    var vfs = try FS.mount(.ext2, blkio, heap.allocator);
    defer vfs.deinit();

    try util.expect(vfs.filecount() == manifest.entries.len);

    const entry = smallest_entry();
    const io = try vfs.open(entry.name);
    defer io.close();
    try util.expect(try file_crc(io, entry.size) == entry.crc32);
}

/// RBFS (on its own disk) and EXT2 must be mountable at the same time.
fn test_coexist_rbfs() anyerror!void {
    const rio = try dev.open_nth("vioblk", rbfs_nth);
    defer rio.close();
    const rfs = try RBFS.mount(rio, heap.allocator);
    defer rfs.deinit();

    const entry = smallest_entry();
    const rbfs_file = try rfs.open(entry.name);
    defer rbfs_file.close();
    const ext2_file = try fs.open(entry.name);
    defer ext2_file.close();

    try util.expect(try file_crc(rbfs_file, entry.size) == entry.crc32);
    try util.expect(try file_crc(ext2_file, entry.size) == entry.crc32);
}

// Content

fn test_sizes() anyerror!void {
    for (manifest.entries) |entry| {
        const io = try fs.open(entry.name);
        defer io.close();

        try util.expect(try io.cntl(IO.IOCTL_GETBLKSZ, null) == BLKSZ);
        try util.expect(try io.cntl(IO.IOCTL_GETEND, null) == @as(isize, @intCast(entry.size)));
    }
}

fn test_checksums() anyerror!void {
    for (manifest.entries) |entry| {
        const io = try fs.open(entry.name);
        defer io.close();

        try util.expect(try file_crc(io, entry.size) == entry.crc32);
    }
}

/// Reads straddling the direct->indirect and indirect->dindirect boundaries
/// must agree with the same bytes read in halves that don't straddle.
fn test_boundary_reads() anyerror!void {
    const entry = largest_entry();
    const io = try fs.open(entry.name);
    defer io.close();

    for ([_]u32{ DIRECT_CAP, INDIRECT_CAP }) |boundary| {
        if (entry.size < boundary + 32) continue;

        var full = [_]u8{0} ** 64;
        var lo = [_]u8{0} ** 32;
        var hi = [_]u8{0} ** 32;
        try util.expect(try io.readat(full[0..], boundary - 32) == full.len);
        try util.expect(try io.readat(lo[0..], boundary - 32) == lo.len);
        try util.expect(try io.readat(hi[0..], boundary) == hi.len);

        try util.expect(std.mem.eql(u8, full[0..32], lo[0..]));
        try util.expect(std.mem.eql(u8, full[32..], hi[0..]));
    }
}

fn test_oob_read() anyerror!void {
    const entry = manifest.entries[0];
    const io = try fs.open(entry.name);
    defer io.close();

    var buf = [_]u8{0} ** 16;
    try util.expectError(IO.Error.Invalid, io.readat(buf[0..], entry.size - 8));
    try util.expectError(IO.Error.Invalid, io.readat(buf[0..], entry.size + 1));
}

/// Empty reads and writes are valid no-ops anywhere up to and including EOF.
fn test_zero_length_io() anyerror!void {
    const entry = manifest.entries[0];
    const io = try fs.open(entry.name);
    defer io.close();

    var buf = [_]u8{0} ** 1;
    try util.expect(try io.readat(buf[0..0], 0) == 0);
    try util.expect(try io.readat(buf[0..0], entry.size) == 0);
    try util.expect(try io.writeat(buf[0..0], entry.size) == 0);
}

// Position

fn test_position_ioctls() anyerror!void {
    const entry = largest_entry();
    const io = try fs.open(entry.name);
    defer io.close();

    try util.expect(try io.cntl(IO.IOCTL_GETPOS, null) == 0);

    // readat advances the tracked position to the end of the read.
    var buf = [_]u8{0} ** 16;
    try util.expect(try io.readat(buf[0..], 0) == buf.len);
    try util.expect(try io.cntl(IO.IOCTL_GETPOS, null) == buf.len);

    var pos: u64 = 8;
    try util.expect(try io.cntl(IO.IOCTL_SETPOS, &pos) == 8);
    try util.expect(try io.cntl(IO.IOCTL_GETPOS, null) == 8);

    // Seeking exactly to EOF is allowed, past it is not.
    pos = entry.size;
    try util.expect(try io.cntl(IO.IOCTL_SETPOS, &pos) == @as(isize, @intCast(entry.size)));
    pos = @as(u64, entry.size) + 1;
    try util.expectError(IO.Error.Invalid, io.cntl(IO.IOCTL_SETPOS, &pos));

    try util.expectError(IO.Error.Invalid, io.cntl(IO.IOCTL_SETPOS, null));
    try util.expectError(IO.Error.Invalid, io.cntl(IO.IOCTL_SETEND, null));
}

fn test_setend_shrink() anyerror!void {
    const entry = largest_entry();
    const io = try fs.open(entry.name);
    defer io.close();

    var size: u64 = entry.size - 1;
    try util.expectError(IO.Error.Invalid, io.cntl(IO.IOCTL_SETEND, &size));
    try util.expect(try io.cntl(IO.IOCTL_GETEND, null) == @as(isize, @intCast(entry.size)));
}

fn test_unknown_ioctl() anyerror!void {
    const io = try fs.open(manifest.entries[0].name);
    defer io.close();

    try util.expectError(IO.Error.Unsupported, io.cntl(0x5A5A, null));
}

/// Files already track a position (GETPOS/SETPOS, and readat advances it),
/// but the sequential read() path is not wired up yet. This documents the
/// expected behavior and fails (Unsupported) until it lands.
fn test_sequential_read() anyerror!void {
    const entry = largest_entry();
    const io = try fs.open(entry.name);
    defer io.close();

    var want = [_]u8{0} ** 16;
    try util.expect(try io.readat(want[0..], 0) == want.len);

    var pos: u64 = 0;
    try util.expect(try io.cntl(IO.IOCTL_SETPOS, &pos) == 0);

    var got = [_]u8{0} ** 16;
    try util.expect(try io.read(got[0..]) == got.len);
    try util.expect(std.mem.eql(u8, want[0..], got[0..]));
    try util.expect(try io.cntl(IO.IOCTL_GETPOS, null) == got.len);
}

// Mutation

fn test_overwrite_restore() anyerror!void {
    const entry = largest_entry();
    const io = try fs.open(entry.name);
    defer io.close();

    // Overwrite a block-straddling range, verify, then restore and verify
    // the file checksum is back to canonical.
    const pos: u32 = BLKSZ - 8;
    var orig = [_]u8{0} ** 16;
    try util.expect(try io.readat(orig[0..], pos) == orig.len);

    var flipped = orig;
    for (&flipped) |*byte| byte.* ^= 0xFF;
    try util.expect(try io.writeat(flipped[0..], pos) == flipped.len);

    var check = [_]u8{0} ** 16;
    try util.expect(try io.readat(check[0..], pos) == check.len);
    try util.expect(std.mem.eql(u8, check[0..], flipped[0..]));

    try util.expect(try io.writeat(orig[0..], pos) == orig.len);
    try util.expect(try file_crc(io, entry.size) == entry.crc32);
}

fn test_create() anyerror!void {
    try fs.create("testfile");
    try util.expect(fs.filecount() == manifest.entries.len + 1);

    const io = try fs.open("testfile");
    defer io.close();
    try util.expect(try io.cntl(IO.IOCTL_GETEND, null) == 0);
}

fn test_setend() anyerror!void {
    const io = try fs.open("testfile");
    defer io.close();

    var size: u64 = 0x4337; // > DIRECT_CAP, so growth crosses into the indirect block
    try util.expect(try io.cntl(IO.IOCTL_SETEND, &size) >= 0);
    try util.expect(try io.cntl(IO.IOCTL_GETEND, null) == 0x4337);
}

fn test_write_readback() anyerror!void {
    const io = try fs.open("testfile");
    defer io.close();

    const text = "The FitnessGram Pacer test...";
    var buf = [_]u8{0} ** 32;
    @memcpy(buf[0..text.len], text);

    // One write at the start, one straddling a block boundary, one
    // straddling the direct->indirect boundary.
    try util.expect(try io.writeat(buf[0..], 0) == buf.len);
    try util.expect(try io.writeat(buf[0..], BLKSZ - 16) == buf.len);
    try util.expect(try io.writeat(buf[0..], DIRECT_CAP - 16) == buf.len);

    var readback = [_]u8{0} ** 32;
    try util.expect(try io.readat(readback[0..], 0) == readback.len);
    try util.expect(std.mem.eql(u8, buf[0..], readback[0..]));

    @memset(readback[0..], 0);
    try util.expect(try io.readat(readback[0..], BLKSZ - 16) == readback.len);
    try util.expect(std.mem.eql(u8, buf[0..], readback[0..]));

    @memset(readback[0..], 0);
    try util.expect(try io.readat(readback[0..], DIRECT_CAP - 16) == readback.len);
    try util.expect(std.mem.eql(u8, buf[0..], readback[0..]));
}

/// "testfile" (created above) and the originals must reject a second create.
fn test_create_duplicate() anyerror!void {
    try util.expectError(IO.Error.Invalid, fs.create("testfile"));
    try util.expectError(IO.Error.Invalid, fs.create(manifest.entries[0].name));
    try util.expect(fs.filecount() == manifest.entries.len + 1);
}

fn test_delete_while_open() anyerror!void {
    const io = try fs.open("testfile");
    defer io.close();

    try util.expectError(IO.Error.Busy, fs.delete("testfile"));
}

fn test_delete_missing() anyerror!void {
    try util.expectError(EXT2.Error.NotFound, fs.delete("no-such-file"));
    try util.expectError(IO.Error.Invalid, fs.delete("bad/name"));
    try util.expect(fs.filecount() == manifest.entries.len + 1);
}

fn test_delete() anyerror!void {
    try fs.delete("testfile");
    try util.expect(fs.filecount() == manifest.entries.len);
    try util.expectError(EXT2.Error.NotFound, fs.open("testfile"));
}

/// A second mount must reconstruct the directory from disk (create/delete
/// really landed in the on-disk directory, not just the in-memory list).
fn test_remount() anyerror!void {
    try fs.create("remountfile");

    const other = try EXT2.mount(blkio, heap.allocator);
    const found = other.filecount() == manifest.entries.len + 1;
    other.deinit();
    try util.expect(found);

    try fs.delete("remountfile");

    const again = try EXT2.mount(blkio, heap.allocator);
    const gone = again.filecount() == manifest.entries.len;
    again.deinit();
    try util.expect(gone);
}

/// Creating, growing, and deleting a file must not have corrupted any of the
/// real files that live in the image.
fn test_originals_intact() anyerror!void {
    for (manifest.entries) |entry| {
        const io = try fs.open(entry.name);
        defer io.close();

        try util.expect(try io.cntl(IO.IOCTL_GETEND, null) == @as(isize, @intCast(entry.size)));
        try util.expect(try file_crc(io, entry.size) == entry.crc32);
    }
}
