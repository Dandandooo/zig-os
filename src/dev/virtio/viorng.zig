const std = @import("std");
const log = std.log.scoped(.VIORNG);
const assert = @import("../../util/debug.zig").assert;

const cons = @import("../../console.zig");
const intr = @import("../../cntl/intr.zig");
const heap = @import("../../mem/heap.zig");
const wait = @import("../../conc/wait.zig");
const dev = @import("../device.zig");
const virtio = @import("virtio.zig");
const IO = @import("../../api/io.zig");
const VIORNG = @This();

const BUFSZ: u32 = 256;
const NAME: []const u8 = "rng";
const IRQ_PRIO: u32 = 1;

regs: *volatile virtio.mmio_regs,
instno: u32,
irqno: u32,

io: IO = .new0(&.{
    .ctnl = cntl,
    .close = close,
    .readat = readat,
    .writeat = writeat,
}),

vq: struct {
    last_used_idx: u16 = 0,
    avail: virtio.virtq_avail(1) = .{},
    used: virtio.virtq_used(1) = .{},
    desc: virtio.virtq_desc
},

bufcnt: u32 = 0,
buf: [BUFSZ]u8 = undefined,
filled: wait.Condition = .{ .name = "viorng filled" },

pub fn attach(regs: *volatile virtio.mmio_regs, irqno: u32, allocator: *std.mem.Allocator) void {
    assert(regs.device_id == .rng, "should be attaching rng");

    regs.status.driver = true;

    const self: *VIORNG = try allocator.create(VIORNG);
    self.* = .{
        .regs = regs,
        .irqno = .irqno,
        .instno = dev.register(NAME, open, self),
        .vq = .{
            .desc = .{
                .flags = .{ .write = true },
                .addr = @intFromPtr(self.buf),
                .len = BUFSZ
            },
        },
    };

}
