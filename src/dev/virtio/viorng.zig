const std = @import("std");
const log = std.log.scoped(.VIORNG);
const config = @import("../../config.zig");
const assert = @import("../../util/debug.zig").assert;

const cons = @import("../../console.zig");
const intr = @import("../../cntl/intr.zig");
const heap = @import("../../mem/heap.zig");
const wait = @import("../../conc/wait.zig");
const dev = @import("../device.zig");
const reg = @import("../../riscv/reg.zig");
const virtio = @import("virtio.zig");
const IO = @import("../../api/io.zig");
const VIORNG = @This();

const BUFSZ: u32 = 1024;
const NAME: []const u8 = "rng";
const IRQ_PRIO: u32 = 1;

regs: *volatile virtio.mmio_regs,
instno: u32,
irqno: u32,

io: IO = .from(VIORNG),

vq: struct {
    avail: virtio.virtq_avail(1) = .{},
    used: virtio.virtq_used(1) = .{},
    desc: [1]virtio.virtq_desc = undefined,
},

bufpos: usize = BUFSZ,
buf: [BUFSZ]u8 = undefined,
filled: wait.Condition = .{ .name = "viorng filled" },

// TODO: integrate with std.Random

pub fn attach(regs: *volatile virtio.mmio_regs, irqno: u32, allocator: *const std.mem.Allocator) virtio.Error!void {
    assert(regs.device_id == .rng, "should be attaching rng");

    const needed_features: virtio.FeatureSet = .{};
    const wanted_features: virtio.FeatureSet = .{};
    const enabled_features = try regs.negotiate_features(&needed_features, &wanted_features);
    _ = enabled_features;

    const self: *VIORNG = try allocator.create(VIORNG);
    self.* = .{
        .regs = regs,
        .irqno = irqno,
        .instno = try dev.register(NAME, open, self),
        .vq = .{
            .desc = .{
                .{
                    .flags = .{ .write = true },
                    .len = BUFSZ,
                    .addr = @intFromPtr(&self.buf),
                }
            },
        },
    };

    regs.attach_virtq(0, 1, &self.vq.desc[0],
        @intFromPtr(&self.vq.used), @intFromPtr(&self.vq.avail));
}

fn open(aux: *anyopaque) IO.Error!*IO {
    const self: *VIORNG = @alignCast(@ptrCast(aux));

    if (self.io.refcnt != 0)
        return IO.Error.Busy;

    self.regs.enable_virtq(0);
    intr.enable_source(self.irqno, config.VIORNG_INTR_PRIO, isr, aux);

    return self.io.addref();
}

pub fn close(io: *IO) void {
    const self: *VIORNG = @fieldParentPtr("io", io);
    self.regs.reset_virtq(0);
    intr.disable_source(self.irqno);
}

pub fn read(io: *IO, buf: []u8) !usize {
    const self: *VIORNG = @fieldParentPtr("io", io);

    if (self.bufpos >= BUFSZ) {
        log.debug("Refilling virtio buffer", .{});
        self.vq.avail.idx += 1;
        self.vq.avail.ring[0] = 0;

        const pie = intr.disable();
        self.regs.notify_avail(0);
        while (self.bufpos > 0)
            self.filled.wait();
        intr.restore(pie);
    }

    const available = BUFSZ - self.bufpos;
    const to_copy = @min(buf.len, available);
    @memcpy(buf[0..to_copy], self.buf[self.bufpos..self.bufpos+to_copy]);
    defer self.bufpos += to_copy;
    return to_copy;
}

fn isr(aux: *anyopaque) void {
    const self: *VIORNG = @alignCast(@ptrCast(aux));

    self.bufpos = 0;
    self.regs.interrupt_ack = 1;
    self.filled.broadcast();
}
