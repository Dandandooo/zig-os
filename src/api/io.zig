
// IO Operations

// Imports
//
const std = @import("std");
const assert = @import("../util/debug.zig").assert;
const mem = @import("std").mem;

// Exported Constants
//
pub const IOCTL_GETBLKSZ: usize = 0;
pub const IOCTL_GETEND: usize = 2;
pub const IOCTL_SETEND: usize = 3;
pub const IOCTL_GETPOS: usize = 4;
pub const IOCTL_SETPOS: usize = 5;

// Internal Type Definitions
//
pub const Error = error{
    Unsupported,
    BadFormat,
    Invalid,
    Error,
};

pub const iointf = struct {
    close: ?*const fn (io: *IO) void = null,
    cntl: ?*const fn (io: *IO, cmd: i32, arg: ?*anyopaque) Error!isize = null,
    read: ?*const fn (io: *IO, buf: []u8) Error!usize = null,
    readat: ?*const fn (io: *IO, buf: []u8, pos: u64) Error!usize = null,
    write: ?*const fn (io: *IO, buf: []const u8) Error!usize = null,
    writeat: ?*const fn (io: *IO, buf: []const u8, pos: u64) Error!usize = null,
};

const IO = @This();

intf: iointf,
refcnt: usize = 0,

// IO Object Creation

pub fn new0(intf: iointf) IO { return .{ .intf = intf}; }

pub fn from(comptime T: type) IO {
    _ = T;
    @compileError("this only reads public");
    // return .new0(.{
    //     .cntl = if (@hasDecl(T, "cntl")) T.cntl else null,
    //     .read = if (@hasDecl(T, "read")) T.read else null,
    //     .readat = if (@hasDecl(T, "readat")) T.readat else null,
    //     .write = if (@hasDecl(T, "write")) T.write else null,
    //     .writeat = if (@hasDecl(T, "writeat")) T.writeat else null,
    //     .close = if (@hasDecl(T, "close")) T.close else null,
    // });
}

// pub fn new1(comptime T: type, intf: iointf) io { return .{ .intf = intf, .refcnt = 1 }; }

pub fn addref(ioptr: *IO) *IO {
    ioptr.refcnt += 1;
    return ioptr;
}

// IO Interface

pub fn close(self: *IO) void {
    assert(self.refcnt > 0, "IO already closed!");
    self.refcnt -= 1;
    if (self.refcnt == 0)
        if (self.intf.close) |close_fn| close_fn(self);
        // else @panic("this io doesn't close"); // doesn't have to be a problem
}

pub fn cntl(self: *IO, cmd: i32, arg: ?*anyopaque) Error!isize {
    return if (self.intf.cntl) |cntl_fn| cntl_fn(self, cmd, arg)
    else if (cmd == IOCTL_GETBLKSZ) 1 // defalt value
    else Error.Unsupported;
}

pub fn read(self: *IO, buf: []u8) Error!usize {
    return if (self.intf.read) |read_fn| read_fn(self, buf)
    else Error.Unsupported;
}

pub fn readat(self: *IO, buf: []u8, pos: u64) Error!usize {
    return if (self.intf.readat) |readat_fn| readat_fn(self, buf, pos)
    else Error.Unsupported;
}

pub fn write(self: *IO, buf: []const u8) Error!usize {
    return if (self.intf.write) |write_fn| write_fn(self, buf)
    else Error.Unsupported;
}

pub fn writeat(self: *IO, buf: []const u8, pos: u64) Error!usize {
    return if (self.intf.writeat) |writeat_fn| writeat_fn(self, buf, pos)
    else Error.Unsupported;
}

// TODO: support polling

// Mock Devices

pub fn to_seekio(self: *IO) *IO {_ = self; } // TODO

pub fn create_pipe(wioptr: **IO, rioptr: **IO) void {_ = wioptr; _ = rioptr; } // TODO

// Mem IO
//
const MemIO = struct {
    io: IO = new0(&.{
        .readat = MemIO.readat,
        .writeat = MemIO.writeat,
        .cntl = MemIO.cntl,

    }),

    buf: [] u8,

    size: usize,
    end_pos: usize,

    fn attach() void {
        // TODO
    }

    fn readat(ioptr: *IO, buf: [] u8, pos: u64) Error!usize {
        const self: *MemIO = @fieldParentPtr("io", ioptr);
        if (pos + buf.len > self.*.size)
            return Error.Invalid;

        @memcpy(buf, self.*.buf[pos..pos+buf.len]);

        return buf.len;
    }

    fn writeat(ioptr: *IO, buf: []const u8, pos: u64) Error!usize {
        const self: *MemIO = @fieldParentPtr("io", ioptr);
        if (pos + buf.len > self.*.size)
            return Error.Invalid;

        @memcpy(self.*.buf[pos..pos+buf.len], buf);

        return buf.len;
    }

    fn close() void {}

    fn cntl(ioptr: *IO, cmd: i32, arg: *anyopaque) Error!i32 {
        const self: *MemIO = @fieldParentPtr("io", ioptr);
        _ = arg;
        return switch (cmd) {
            IOCTL_GETBLKSZ => 1,
            IOCTL_GETEND => self.*.buf.len,
            else => Error.Unsupported
        };
    }
};


test "memio readat" {
    // TODO
}

test "memio writeat" {
    // TODO
}

// Null IO
pub const NullIO = struct {
    io: IO = new0(&.{
        .read = NullIO.read,
        .write = NullIO.write,
        .close = NullIO.close,
    }),

    fn read(_: *IO, buf: []u8) Error!usize {
        @memset(buf, 0);
        return buf.len;
    }

    fn write(_: *IO, buf: []const u8) Error!usize {
        return buf.len;
    }

    fn close(_: *IO) void {}
};


test "nullio read" {
    const buf = [_]u8{0xFF, 1, 2};
    const self: NullIO = .{};
    const num = self.read(buf);
    try std.testing.expect(num);
    try std.testing.expect(buf[0] == 0);
    try std.testing.expect(buf[1] == 0);
    try std.testing.expect(buf[2] == 0);
}

test "nullio write" {
    // FIXME: I think I need to write my own allocator
    const exbuf: [5]u8 = [_]u8{1, 2, 3, 4, 5};
    const self: NullIO = .{};
    self.write(&exbuf, 5);

    try std.testing.expect(exbuf[2] == 3);
}

// Seek IO
const SeekIO = struct {
    io: IO,
    bkgio: *IO,

    pos: u64,
    end: u64,

    blksz: u32, // of backing device
};
