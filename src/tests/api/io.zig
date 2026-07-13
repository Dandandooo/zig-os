const std = @import("std");
const util = @import("../util.zig");
const Io = @import("../../api/io.zig");
const NullIO = Io.NullIO;

pub fn run() util.test_results {
    return util.run_tests("IO", &.{
        .{ .name = "NullIO Read", .func = nullio_read },
        .{ .name = "NullIO Write", .func = nullio_write },
        .{ .name = "Unsupported Defaults", .func = unsupported_defaults },
        .{ .name = "Fill Reads Multiple Chunks", .func = fill_reads_multiple_chunks },
        .{ .name = "Addref Close Once", .func = addref_close_once },
        .{ .name = "Close Without Close Fn", .func = close_without_close_fn },
        .{ .name = "Pipe Roundtrip (TODO)", .func = pipe_roundtrip },
    });
}

const MinimalIO = struct {
    io: Io = .from(MinimalIO),
};

const ChunkedIO = struct {
    io: Io = .from(ChunkedIO),
    read_chunk: usize = 2,
    read_calls: usize = 0,
    next_byte: u8 = 0,
    close_calls: usize = 0,

    pub fn read(ioptr: *Io, buf: []u8) Io.Error!usize {
        const self: *ChunkedIO = @fieldParentPtr("io", ioptr);
        const n = @min(buf.len, self.read_chunk);

        for (buf[0..n]) |*b| {
            b.* = self.next_byte;
            self.next_byte +%= 1;
        }

        self.read_calls += 1;
        return n;
    }

    pub fn close(ioptr: *Io) void {
        const self: *ChunkedIO = @fieldParentPtr("io", ioptr);
        self.close_calls += 1;
    }
};

fn nullio_read() anyerror!void {
    var buf = [_]u8{ 0xFF, 1, 2 };
    var self: NullIO = .{};
    const num = try self.io.read(&buf);
    try util.expect(num == buf.len);
    try util.expect(buf[0] == 0);
    try util.expect(buf[1] == 0);
    try util.expect(buf[2] == 0);
}

fn nullio_write() anyerror!void {
    const exbuf: [5]u8 = [_]u8{ 1, 2, 3, 4, 5 };
    var self: NullIO = .{};
    const written = try self.io.write(&exbuf);

    try util.expect(written == 5);
    try util.expect(exbuf[2] == 3);
}

fn unsupported_defaults() anyerror!void {
    var buf = [_]u8{ 1, 2, 3 };
    var self: MinimalIO = .{};

    try util.expect(try self.io.cntl(Io.IOCTL_GETBLKSZ, null) == 1);
    try util.expectError(Io.Error.Unsupported, self.io.read(&buf));
    try util.expectError(Io.Error.Unsupported, self.io.readat(&buf, 0));
    try util.expectError(Io.Error.Unsupported, self.io.write(&buf));
    try util.expectError(Io.Error.Unsupported, self.io.writeat(&buf, 0));
}

fn fill_reads_multiple_chunks() anyerror!void {
    var buf = [_]u8{0} ** 5;
    var self: ChunkedIO = .{};

    try self.io.fill(&buf);

    try util.expect(self.read_calls == 3);
    for (buf, 0..) |b, i|
        try util.expect(b == i);
}

fn close_without_close_fn() anyerror!void {
    var self: MinimalIO = .{};

    _ = Io.addref(&self.io);
    self.io.close();
    try util.expect(self.io.refcnt == 0);
}

/// create_pipe is still a stub. When implemented, bytes written to the write
/// end must come back out of the read end. Until then the pointers stay at
/// their sentinels and the test fails without dereferencing anything bogus.
fn pipe_roundtrip() anyerror!void {
    var wsent: NullIO = .{};
    var rsent: NullIO = .{};
    var wio: *Io = &wsent.io;
    var rio: *Io = &rsent.io;

    Io.create_pipe(&wio, &rio);

    if (wio == &wsent.io or rio == &rsent.io)
        return error.NotImplemented;

    defer wio.close();
    defer rio.close();

    const msg = "pipe dream";
    try util.expect(try wio.write(msg) == msg.len);

    var got = [_]u8{0} ** msg.len;
    try rio.fill(&got);
    try util.expect(std.mem.eql(u8, got[0..], msg));
}

fn addref_close_once() anyerror!void {
    var self: ChunkedIO = .{};

    _ = Io.addref(&self.io);
    _ = Io.addref(&self.io);

    self.io.close();
    try util.expect(self.close_calls == 0);
    try util.expect(self.io.refcnt == 1);

    self.io.close();
    try util.expect(self.close_calls == 1);
    try util.expect(self.io.refcnt == 0);
}
