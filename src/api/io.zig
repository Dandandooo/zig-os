// IO Operations

// Imports
//
const assert = @import("std").debug.assert;
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
pub const IOError = error{
    Unsupported,
    BadFormat,
    Invalid,
};

pub const iointf = struct {
    close: ?*const fn (self: *io) void = null,
    cntl: ?*const fn (self: *io, cmd: i32, arg: *const void) IOError!i32 = null,
    read: ?*const fn (self: *io, buf: *void, bufsz: usize) IOError!usize = null,
    readat: ?*const fn (self: *io, pos: u64, buf: *void, bufsz: usize) IOError!usize = null,
    write: ?*const fn (self: *io, buf: *const void, len: usize) IOError!usize = null,
    writeat: ?*const fn (self: *io, pos: u64, buf: *const void, len: usize) IOError!usize = null,
};

pub const io = struct {
    intf: *const iointf,
    refcnt: usize = 0,

    // IO Object Creation

    pub fn new0(intf: *const iointf) io {
        return .{ .intf = intf };
    }

    pub fn new1(intf: *const iointf) io {
        return .{ .intf = intf, .refcnt = 1 };
    }

    pub fn addref(ioptr: *io) *io {
        ioptr.refcnt += 1;
        return ioptr;
    }

    // IO Interface

    pub fn close(self: *const io) void {
        assert(self.refcnt > 0);
        self.refcnt -= 1;
        if (self.refcnt == 0)
            self.close();
    }

    pub fn cntl(self: *const io, cmd: i32, arg: *const void) IOError!i32 {
        assert(self.intf != 0);
        return if (self.intf.cntl)
            self.intf.cntl(self, cmd, arg)
        else if (cmd == IOCTL_GETBLKSZ)
            1 // defalt value
        else IOError.Unsupported;
    }

    pub fn read(self: *const io, buf: *void, bufsz: usize) IOError!usize {
        assert(self.intf != 0);
        return if (self.intf.read)
            self.intf.read(self, buf, bufsz)
        else IOError.Unsupported;
    }

    pub fn readat(self: *const io, pos: u64, buf: *void, bufsz: usize) IOError!usize {
        assert(self.intf != 0);
        return if (self.intf.readat)
            self.intf.readat(self, pos, buf, bufsz)
        else IOError.Unsupported;
    }

    pub fn write(self: *const io, buf: *const void, len: usize) IOError!usize {
        assert(self.intf != 0);
        return if (self.intf.write)
            self.intf.write(self, buf, len)
        else IOError.Unsupported;
    }

    pub fn writeat(self: *const io, pos: u64, buf: *const void, len: usize) IOError!usize {
        assert(self.intf != 0);
        return if (self.intf.writeat)
            self.intf.writeat(self, pos, buf, len)
        else IOError.Unsupported;
    }

    // TODO: support polling

    // Mock Devices

    pub fn new_memio(buf: *void, size: usize) *io {
        // FIXME: I think I need to write my own allocator
        const memio_dev: *memio_device = mem.Allocator.alloc(memio_device, 1);
        memio_dev = .{
            .memio = io.new1(&memio_intf),
            .buf = buf,
            .size = size
        };

        return &memio_dev.memio;
    }

    pub fn new_nullio(buf: *void, size: usize) *io {
        // FIXME: I think I need to write my own allocator
        const nullio: *io = mem.Allocator.alloc(io, 1);
        nullio.intf = &nullio_intf;
        return nullio;
    }

    pub fn to_seekio(self: *io) *io {}

    pub fn create_pipe(wioptr: **io, rioptr: **io) void {}
};

// Mem IO
const memio_device = struct {
    memio: io,

    buf: [*] u8,

    size: usize,
    end_pos: usize,
};

fn memio_attach() {
    // TODO
}

fn memio_readat(memio: *const io, pos: u64, buf: [*] u8, bufsz: usize) IOError!usize {
    const memio_dev: *const memio_device = @fieldParentPtr( "memio", memio);

    if (pos + bufsz > memio_dev.*.size)
        return IOError.Invalid;

    @memcpy(buf, memio_dev.*.buf[pos..pos+bufsz]);

    return bufsz;
}

fn memio_writeat(memio: *const io, pos: u64, buf: [*] const u8, len: usize) IOError!usize {
    const memio_dev: *memio_device = @fieldParentPtr("memio", memio);

    if (pos + len > memio_dev.*.size)
        return IOError.Invalid;

    @memcpy(memio_device.*.buf[pos..pos+len], buf);

    return len;
}

fn memio_close() void {}

fn memio_cntl(memio: *io, cmd: i32, arg: *anyopaque) !void {

}

const memio_intf = iointf{
    .writeat = memio_writeat,
    .readat = memio_readat,
    .close = memio_close,
    .cntl = memio_cntl
};

test "memio readat" {
    // TODO
}

test "memio writeat" {
    // TODO
}

// Null IO
fn nullio_read(nullio: *io, buf: *void, bufsz: usize) !usize {
    assert(nullio != 0);
    const cbuf = [bufsz]u8(buf);
    @memset(cbuf, 0);
    return bufsz;
}

fn nullio_write(nullio: *io, buf: *const void, len: usize) !usize {
    assert(nullio != 0);
    assert(buf != 0);
    return len;
}

fn nullio_close() void {}

const nullio_intf = iointf{
    .read = nullio_read,
    .write = nullio_close,
    .close = nullio_close,
};

test "nullio read" {
    // TODO
}

test "nullio write" {
    // FIXME: I think I need to write my own allocator
    const exbuf: [100]u8 = mem.Allocator.alloc(u8, 100);
    // TODO
}

// Seek IO
const seekio_device = struct {
    seekio: io,
    bkgio: *io,

    pos: u64,
    end: u64,

    blksz: u32, // of backing device
}
