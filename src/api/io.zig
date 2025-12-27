
// IO Operations

// Imports
//
const std = @import("std");
const assert = @import("../util/debug.zig").assert;
const mem = @import("std").mem;
const wait = @import("../conc/wait.zig");

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
    Busy,
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

intf: *const iointf,
refcnt: usize = 0,
lock: wait.Lock,

// IO Object Creation

pub fn new0(name: []const u8, intf: *const iointf) IO {
    return .{ .intf = intf, .lock = .new(name) };
}

pub fn from(comptime T: type) IO {
    return .new0(@typeName(T) ++ " io lock", &.{
        .cntl = if (@hasDecl(T, "cntl")) T.cntl else null,
        .read = if (@hasDecl(T, "read")) T.read else null,
        .readat = if (@hasDecl(T, "readat")) T.readat else null,
        .write = if (@hasDecl(T, "write")) T.write else null,
        .writeat = if (@hasDecl(T, "writeat")) T.writeat else null,
        .close = if (@hasDecl(T, "close")) T.close else null,
    });
}

// pub fn new1(comptime T: type, intf: iointf) io { return .{ .intf = intf, .refcnt = 1 }; }

pub fn addref(ioptr: *IO) *IO {
    ioptr.refcnt += 1;
    return ioptr;
}

// IO Interface

pub fn close(self: *IO) void {
    assert(self.refcnt > 0, "IO already closed!");
    self.lock.acquire();
    defer self.lock.release();
    self.refcnt -= 1;
    if (self.refcnt == 0)
        if (self.intf.close) |close_fn| close_fn(self);
        // else @panic("this io doesn't close"); // doesn't have to be a problem
}

pub fn cntl(self: *IO, cmd: i32, arg: ?*anyopaque) Error!isize {
    if (self.intf.cntl) | cntl_fn | {
        self.lock.acquire();
        defer self.lock.release();
        return cntl_fn(self, cmd, arg);
    } else if (cmd == IOCTL_GETBLKSZ) return 1
    else return Error.Unsupported;
}

pub fn read(self: *IO, buf: []u8) Error!usize {
    if (self.intf.read) | read_fn | {
        self.lock.acquire();
        defer self.lock.release();
        return read_fn(self, buf);
    } else return Error.Unsupported;
}

pub fn readat(self: *IO, buf: []u8, pos: u64) Error!usize {
    if (self.intf.readat) | readat_fn | {
        self.lock.acquire();
        defer self.lock.release();
        return readat_fn(self, buf, pos);
    } else return Error.Unsupported;
}

pub fn write(self: *IO, buf: []const u8) Error!usize {
    if (self.intf.write) | write_fn | {
        self.lock.acquire();
        defer self.lock.release();
        return write_fn(self, buf);
    } else return Error.Unsupported;
}

pub fn writeat(self: *IO, buf: []const u8, pos: u64) Error!usize {
    if (self.intf.writeat) | writeat_fn | {
        self.lock.acquire();
        defer self.lock.release();
        return writeat_fn(self, buf, pos);
    } else return Error.Unsupported;
}

pub fn fill(self: *IO, buf: []u8) Error!void {
    var bufpos: usize = 0;
    while (bufpos < buf.len)
        bufpos += try self.read(buf[bufpos..]);
}

pub fn blksz(self: *IO) Error!usize {
    return self.cntl(IOCTL_GETBLKSZ, null);
}

pub fn seek(self: *IO, pos: u64) Error!usize {
    return self.cntl(IOCTL_SETPOS, &pos);
}

// TODO: support polling

// Mock Devices

pub fn to_seekio(self: *IO) *IO {
    _ = self;
} // TODO

pub fn create_pipe(wioptr: **IO, rioptr: **IO) void {_ = wioptr; _ = rioptr; } // TODO

// Mem IO
//
const MemIO = struct {
    io: IO = .from(MemIO),

    buf: [] u8,

    size: usize,
    end_pos: usize,

    fn attach() void {
        // TODO
    }

    pub fn readat(ioptr: *IO, buf: [] u8, pos: u64) Error!usize {
        const self: *MemIO = @fieldParentPtr("io", ioptr);
        if (pos + buf.len > self.*.size)
            return Error.Invalid;

        @memcpy(buf, self.*.buf[pos..pos+buf.len]);

        return buf.len;
    }

    pub fn writeat(ioptr: *IO, buf: []const u8, pos: u64) Error!usize {
        const self: *MemIO = @fieldParentPtr("io", ioptr);
        if (pos + buf.len > self.*.size)
            return Error.Invalid;

        @memcpy(self.*.buf[pos..pos+buf.len], buf);

        return buf.len;
    }

    pub fn close() void {}

    pub fn cntl(ioptr: *IO, cmd: i32, arg: *anyopaque) Error!i32 {
        const self: *MemIO = @fieldParentPtr("io", ioptr);
        _ = arg;
        return switch (cmd) {
            IOCTL_GETBLKSZ => 1,
            IOCTL_GETEND => self.*.buf.len,
            else => Error.Unsupported
        };
    }
};


// Null IO
pub const NullIO = struct {
    io: IO = .from(NullIO),

    pub fn read(_: *IO, buf: []u8) Error!usize {
        @memset(buf, 0);
        return buf.len;
    }

    pub fn write(_: *IO, buf: []const u8) Error!usize {
        return buf.len;
    }

    pub fn close(_: *IO) void {}
};


// Seek IO
const SeekIO = struct {
    // io: IO = .new0(&SeekIO.intf),
    bkgio: *IO,

    pos: u64 = 0,
    end: u64 = 0,

    blksz: u32, // of backing device

    // const intf: iointf = .{
    //     .read = SeekIO.read,
    //     .write = SeekIO.write,
    //     .close = SeekIO.close,
    //     .cntl = SeekIO.cntl,
    // };

    // pub fn from(io: *IO) SeekIO {
    //     return .{ .bkgio = io };
    // }

    // fn read(self: *IO, buf: []u8) Error!usize {

    // }

    // fn write(self: *IO, buf: []const u8) Error!usize {

    // }

    // fn close(self: *IO) void {

    // }

    // fn cntl(self: *IO, cmd: i32, arg: ?*anyopaque) Error!usize {

    // }
};
