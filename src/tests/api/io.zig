const util = @import("../util.zig");
const Io = @import("../../api/io.zig");
const NullIO = Io.NullIO;
const MemIO = Io.MemIO;
const SeekIO = Io.SeekIO;

pub fn run() util.test_results {
    return util.run_tests("IO", .{
        // nullio
        .{"NullIO Read", nullio_read},
        .{"NullIO Write", nullio_write},
        // memio
        // seekio
    });
}


fn nullio_read() !void {
    var buf = [_]u8{0xFF, 1, 2};
    var self: NullIO = .{};
    const num = try self.io.read(&buf);
    try util.expect(num == buf.len);
    try util.expect(buf[0] == 0);
    try util.expect(buf[1] == 0);
    try util.expect(buf[2] == 0);
}

fn nullio_write() !void {
    // FIXME: I think I need to write my own allocator
    const exbuf: [5]u8 = [_]u8{1, 2, 3, 4, 5};
    var self: NullIO = .{};
    const written = try self.io.write(&exbuf);

    try util.expect(written == 5);
    try util.expect(exbuf[2] == 3);
}

// TODO: memio readat
// TODO: memio writeat
// TODO: memio
