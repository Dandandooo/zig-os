const std = @import("std");
const config = @import("../config.zig");
const assert = @import("../util/debug.zig").assert;
const IO = @import("../api/io.zig");
const dev = @import("../dev/device.zig");
const wait = @import("../conc/wait.zig");
const intr = @import("../cntl/intr.zig");
const page = @import("../mem/page.zig");
const cons = @import("../console.zig");


const RBUF_SIZE = 64;

const LCR_DLAB: u8 = 1 << 7;
const LSR_OE: u8 = 1 << 1;
const LSR_DR: u8 = 1 << 0;
const LSR_THRE: u8 = 1 << 5;
const LSR_TEMT: u8 = 1 << 6;
const IER_DRIE: u8 = 1 << 0;
const IER_THREIE: u8 = 1 << 1;


const uart_regs = extern struct {
    rw: extern union {
        rbr: u8, // DLAB=0 read
        thr: u8, // DLAB=0 write
        dll: u8, // DLAB=1
    },

    // Register 1: IER/DLM
    intr: extern union {
        ier: u8, // DLAB=0
        dlm: u8, // DLAB=1
    },

    // Register 2: IIR/FCR
    reg2: extern union {
        iir: u8, // read
        fcr: u8, // write
    },

    lcr: u8,
    mcr: u8,
    lsr: u8,
    msr: u8,
    scr: u8,
};

const RingBuf = struct {
    hpos: u32 = 0,
    tpos: u32 = 0,
    data: [RBUF_SIZE]u8 = [_]u8{0} ** RBUF_SIZE,

    fn empty(self: *const RingBuf) bool { return self.tpos == self.hpos; }
    fn full(self: *const RingBuf) bool { return self.tpos - self.hpos == RBUF_SIZE; }

    fn putc(self: *RingBuf, char: u8) void {
        self.data[self.tpos % RBUF_SIZE] = char;
        asm volatile("" ::: "memory"); // memory barrier
        self.tpos += 1;
    }

    fn getc(self: *RingBuf) u8 {
        defer self.hpos += 1;
        defer asm volatile("" ::: "memory");
        return self.data[self.hpos % RBUF_SIZE];
    }
};

const Uart = @This();


regs: *volatile uart_regs,
irqno: u32,
instno: u32,

io: IO = .from(Uart),

rxbuf: RingBuf = .{},
txbuf: RingBuf = .{},

full: wait.Condition = .{ .name = "uart full"},
empty: wait.Condition = .{ .name = "uart empty"},

// Console UART
pub var uart0: Uart = .{
    .regs = @ptrFromInt(config.UART0_MMIO_BASE),
    .irqno = config.UART0_INTR_SRCNO,
    .instno = undefined,
};

pub fn uart0_init() void {
    uart0.regs.intr.ier = 0x00;

    // Configure UART0. We set the baud rate divisor to 1, the lowest value,
    // for the fastest baud rate. In a physical system, the actual baud rate
    // depends on the attached oscillator frequency. In a virtualized system,
    // it doesn't matter.

    uart0.regs.lcr = LCR_DLAB;
    uart0.regs.rw.dll = 0x01;
    uart0.regs.intr.dlm = 0x00;

    uart0.regs.lcr = 0x03;
    uart0.regs.reg2.fcr = 0x07;
}


// IO FUNCTIONS
//

pub fn attach(mmio_base: *anyopaque, irqno: u32, allocator: std.mem.Allocator) (dev.Error || std.mem.Allocator.Error)!void {

    const self: *Uart = try allocator.create(Uart); // TODO: figure out malloc

    self.* = .{
        .regs = @ptrCast(mmio_base),
        .irqno = irqno,
        .instno = try dev.register("uart", open, @ptrCast(self)),
    };

}

pub fn open(aux: *anyopaque) IO.Error!*IO {
    const self: *Uart = @alignCast(@ptrCast(aux));
    _ = self.regs.rw.rbr;

    self.regs.lcr = 0x03;
    self.regs.reg2.fcr = 0x07;
    self.regs.intr.ier |= IER_DRIE | IER_THREIE;

    intr.enable_source(self.irqno, config.UART_INTR_PRIO, Uart.isr, aux);

    return &self.io;
}

pub fn close(ioptr: *IO) void {
    const self: *Uart = @fieldParentPtr("io", ioptr);
    intr.disable_source(self.irqno);
}

// Reads exactly buf.len bytes
pub fn read(ioptr: *IO, buf: []u8) IO.Error!usize {
    const self: *Uart = @fieldParentPtr("io", ioptr);

    for (buf) |*c|  {
        const pie = intr.disable();
        while (self.rxbuf.empty())
            self.empty.wait();
        intr.restore(pie);
        c.* = self.rxbuf.getc();
        self.regs.intr.ier |= IER_DRIE;
    }

    return buf.len;
}

// Write exactly buf.len bytes
pub fn write(ioptr: *IO, buf: []const u8) IO.Error!usize {
    const self: *Uart = @fieldParentPtr("io", ioptr);
    for (buf) |c| {
        const pie = intr.disable();
        while (self.txbuf.full())
            self.full.wait();
        intr.restore(pie);

        self.txbuf.putc(c);
        self.regs.intr.ier |= IER_THREIE;
    }

    return buf.len;
}

fn isr(aux: *anyopaque) void {
    const self: *Uart = @alignCast(@ptrCast(aux));
    if ((self.regs.lsr & LSR_DR) > 0) {
        if (!self.rxbuf.full()) {
            self.rxbuf.putc(self.regs.rw.rbr);
            self.empty.broadcast(); // Wake threads waiting on empty rbuf
        } else { self.regs.intr.ier &= ~IER_DRIE; }
    }

    if ((self.regs.lsr & LSR_THRE) > 0) {
        if (!self.txbuf.empty()) {
            self.regs.rw.thr = self.txbuf.getc();
            self.full.broadcast(); // Wake threads waiting on full rbuf
        } else { self.regs.intr.ier &= ~IER_THREIE; }
    }
}

var tx_lock: u8 = 0;

fn lock_tx() void {
    while (@cmpxchgStrong(u8, &tx_lock, 0, 1, .seq_cst, .seq_cst) != null) {}
}

fn unlock_tx() void {
    @atomicStore(u8, &tx_lock, 0, .seq_cst);
}

pub fn console_putc(c: u8) void {
    lock_tx();
    defer unlock_tx();

    while ((uart0.regs.lsr & LSR_THRE) == 0) {}
    uart0.regs.rw.thr = c;
    while ((uart0.regs.lsr & LSR_TEMT) == 0) {}
}

pub fn console_getc() u8 {
    while ((uart0.regs.lsr & LSR_DR) == 0) continue;
    return uart0.regs.rw.rbr;
}
