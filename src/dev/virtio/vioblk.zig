const std = @import("std");
const log = std.log.scoped(.VIOBLK);
const assert = @import("../../util/debug.zig").assert;

const cons = @import("../../console.zig");
const intr = @import("../../cntl/intr.zig");
const heap = @import("../../mem/heap.zig");
const wait = @import("../../conc/wait.zig");
const dev = @import("../device.zig");
const virtio = @import("virtio.zig");
const IO = @import("../../api/io.zig");
const VIOBLK = @This();

const INTR_PRIO = 1;

const BLKSZ = 512;

const types = enum(u32) {
    in = 0,
    out = 1,
    flush = 4,
    get_id = 8,
    get_lifetime = 10,
    discard = 11,
    write_zeroes = 13,
    secure_erase = 14,
};

const Status = enum(u8) {
    OK = 0,
    IOError = 1,
    Unsupported = 2,
    Unfinished = 255,
};

const Header = extern struct {
    req_type: types,
    reserved: u32,
    sector: u64,
};

const DESC_MAIN: comptime_int = 0;
const DESC_HEAD: comptime_int = 1;
const DESC_DATA: comptime_int = 2;
const DESC_STAT: comptime_int = 3;

regs: *volatile virtio.mmio_regs,
instno: u32,
irqno: u32,

io: IO = .new0(.{
    .ctnl = cntl,
    .close = close,
    .readat = readat,
    .writeat = writeat,
}),

vq: struct {
    last_used_idx: u16 = 0,
    avail: virtio.virtq_avail(1) = .{},
    used: virtio.virtq_used(1) = .{},
    desc: [4]virtio.virtq_desc,

    head: Header,
    stat: Status,
},

bCond: wait.Condition = .{ .name = "vioblk wait" },
bLock: wait.Lock = .new("vioblk busy"),

blksz: usize = BLKSZ,

pub fn attach(regs: *volatile virtio.mmio_regs, irqno: u32, allocator: *std.mem.Allocator) (dev.Error || std.mem.Allocator.Error)!void {
    assert(regs.device_id == .block, "attaching to wrong device!");

    regs.status.driver = true;

    // Needed Features
    try regs.add_feature(.ring_reset);
    try regs.add_feature(.indirect_desc);

    // Wanted Features
    regs.add_feature(.blk_blk_size) catch void;


    const self: *VIOBLK = try allocator.create(VIOBLK);
    self.* = .{
        .regs = regs,
        .irqno = irqno,
        .instno = try dev.register("vioblk", open, @ptrCast(self)),
        .vq = .{
            .desc = .{
                .{
                    .flags = .{ .indirect_desc = true },
                    .addr = @intFromPtr(&self.vq.desc[DESC_HEAD]),
                    .len = @sizeOf(virtio.virtq_desc) * DESC_STAT
                },
                .{
                    .flags = .{ .next = true },
                    .addr = @intFromPtr(&self.vq.head),
                    .len = @sizeOf(Header),
                    .next = DESC_DATA - 1,
                },
                .{
                    .flags = .{ .next = true },
                    // addr determined by readat/writeat
                    .len = BLKSZ,
                    .next = DESC_STAT - 1,
                },
                .{
                    .flags = .{ .write = true },
                    .addr = @intFromPtr(&self.vq.stat),
                    .len = @sizeOf(Status),
                }
            }
        },

        .blksz = if (regs.check_feature(.blk_blk_size)) regs.config.blk.blk_size else BLKSZ,
    };

    assert((self.blksz & (self.blksz - 1)) == 0, "Block Size must be a power of 2");

    cons.struct_log(.debug, .VIOBLK, "vioblk initialized",
    .{"Device ID: {s}", "IRQNO: {d}", "INSTNO: {d}", "BLKSZ: {d}"},
    .{@tagName(regs.device_id), self.irqno, self.instno, self.blksz});

    regs.attach_virtq(0, 1, &self.vq.desc, @intFromPtr(&self.vq.used), @intFromPtr(&self.vq.avail));
}

fn open(aux: *anyopaque) dev.Error!*IO {
    const self: *VIOBLK = @ptrCast(aux);

    if (self.io.refcnt > 0)
        return dev.Error.Busy;

    self.regs.enable_virtq(0);
    intr.enable_source(self.irqno, INTR_PRIO, isr, aux);

    return self.io.addref();
}

fn close(io: *IO) void {
    const self: *VIOBLK = @fieldParentPtr("io", io);

    self.regs.reset_virtq(0);
    intr.disable_source(self.irqno);
}

fn interact(io: *IO, request: types, data_addr: u64, len: u32, pos: u64) IO.Error!usize {
    const self: *VIOBLK = @fieldParentPtr("io", io);

    self.bLock.acquire();
    defer self.bLock.release();

    if (len % self.blksz != 0) {
        log.err("write length must be multiple of block size");
        return IO.Error.Invalid;
    }

    self.vq.head.req_type = request;
    self.vq.head.sector = pos;
    self.vq.desc[DESC_DATA].addr = @intFromPtr(buf.ptr);
    self.vq.desc[DESC_DATA].len = @intCast(buf.len);

    switch (request) {
        .in => self.vq.desc[DESC_DATA].flags.write = false,
        .out => self.vq.desc[DESC_DATA].flags.write = true,
        else => return IO.Error.Unsupported,
    }

    self.vq.stat = .Unfinished;

    self.vq.avail.idx += 1;

    const pie = intr.disable();

    self.regs.notify_avail(0);

    while (self.vq.stat == .Unfinished)
        self.bCond.wait();

    intr.restore(pie);

    return switch (self.vq.stat) {
        .OK => buf.len,
        .IOError => IO.Error.Error,
        .Unsupported => IO.Error.Unsupported,
        else => unreachable
    };
}

fn writeat(io: *IO, buf: []const u8, pos: u64) IO.Error!usize {
    return interact(io, .out, @intFromPtr(buf.ptr), buf.len, pos);
}

fn readat(io: *IO, buf: []u8, pos: u64) IO.Error!usize {
    return interact(io, .in, @intFromPtr(buf.ptr), buf.len, pos);
}

fn cntl(io: *IO, cmd: i32, _: ?*anyopaque) IO.Error!isize {
    const self: *VIOBLK = @fieldParentPtr("io", io);

    return switch (cmd) {
        IO.IOCTL_GETBLKSZ => self.blksz,
        IO.IOCTL_GETEND => self.regs.config.blk.capacity * self.blksz,
        else => IO.Error.Unsupported
    };
}

fn isr(aux: *anyopaque) void {
    log.debug("ISR FIRED", .{});
    const self: *VIOBLK = @ptrCast(aux);

    // self.vq.last_used_idx = self.vq.used.idx;
    self.regs.interrupt_ack = 1;
    self.bCond.broadcast();
}
