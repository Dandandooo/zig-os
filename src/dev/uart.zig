const config = @import("../config.zig");
const assert = @import("std").debug.assert;
const IO = @import("../api/io.zig");
const wait = @import("../conc/wait.zig");
const intr = @import("../cntl/intr.zig");
const page = @import("../mem/page.zig");
const cons = @import("../console.zig");


const RBUF_SIZE = 64;

const LCR_DLAB: u8 = 1 << 7;
const LSR_OE: u8 = 1 << 1;
const LSR_DR: u8 = 1 << 0;
const LSR_THRE: u8 = 1 << 5;
const IER_DRIE: u8 = 1 << 0;
const IER_THREIE: u8 = 1 << 1;


const uart_regs = packed struct {
    rw: packed union {
        rbr: u8, // DLAB=0 read
        thr: u8, // DLAB=0 write
        dll: u8, // DLAB=1
    },

    // Register 1: IER/DLM
    intr: packed union {
        ier: u8, // DLAB=0
        dlm: u8, // DLAB=1
    },

    // Register 2: IIR/FCR
    reg2: packed union {
        iir: u8, // read
        fcr: u8, // write
    },

    lcr: u8,
    mcr: u8,
    lsr: u8,
    msr: u8,
    scr: u8,
};

const ringbuf = struct {
    hpos: u16 = 0,
    tpos: u16 = 0,
    data: [RBUF_SIZE]u8 = [_]u8{0} ** RBUF_SIZE,

    fn empty(self: *const ringbuf) bool { return self.tpos == self.hpos; }
    fn full(self: *const ringbuf) bool { return self.tpos - self.hpos == RBUF_SIZE; }

    fn putc(self: *ringbuf, char: u8) void {
        self.data[self.tpos % RBUF_SIZE] = char;
        asm volatile("" ::: "memory"); // memory barrier
        self.tpos += 1;
    }

    fn getc(self: *ringbuf) u8 {
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

rxbuf: ringbuf = .{},
txbuf: ringbuf = .{},

full: wait.Condition = .{ .name = "uart full"},
empty: wait.Condition = .{ .name = "uart empty"},

// Console UART
pub var uart0: Uart = .{
    .regs = @ptrFromInt(config.UART0_MMIO_BASE),
    .irqno = config.UART0_INTR_SRCNO,
    .instno = undefined,
};

pub fn uart0_init() void {
    assert(cons.initialized == true);
    uart0.regs.intr.ier = 0x00;

    // Configure UART0. We set the baud rate divisor to 1, the lowest value,
    // for the fastest baud rate. In a physical system, the actual baud rate
    // depends on the attached oscillator frequency. In a virtualized system,
    // it doesn't matter.

    uart0.regs.lcr = LCR_DLAB;
    uart0.regs.rw.dll = 0x01;
    uart0.regs.intr.dlm = 0x00;

    uart0.regs.lcr = 0x00;

}


// IO FUNCTIONS
//

pub fn attach(mmio_base: *anyopaque, irqno: u32) void {
    const intf: IO.Intf(Uart) = .{
        .write = write,
        .close = close,
        .read = read
    };

    const self: *Uart = page.alloc_phys_page(); // TODO: figure out malloc

    self.* = .{
        .regs = @ptrCast(mmio_base),
        .uartio = IO.new0(&intf),
        .irqno = irqno,
        .instno = 0, // TODO
    };

}

pub fn open(aux: *anyopaque) IO.Error!*IO {
    const self: *Uart = @alignCast(@ptrCast(aux));
    intr.enable_source(self.irqno, 1, Uart.isr, aux);
    return &self.io;
}

fn close(ioptr: *IO) void {
    const self: *Uart = @fieldParentPtr("io", ioptr);
    intr.disable_source(self.irqno);
}

// Read up to buf.len bytes
fn read(ioptr: *IO, buf: []u8) IO.Error!usize {
    const self: *Uart = @fieldParentPtr("io", ioptr);
    const pie = intr.disable();
    while (self.rxbuf.empty()) { self.empty.wait(); }
    intr.restore(pie);

    for (buf, 0..) |_, i|  {
        if (self.rxbuf.empty())
            return i;
        buf[i] = self.rxbuf.getc();
        self.regs.intr.ier |= IER_DRIE;
    }

    return buf.len;
}

// Write exactly buf.len bytes
pub fn write(ioptr: *IO, buf: []const u8) IO.Error!usize {
    const self: *Uart = @fieldParentPtr("io", ioptr);
    for (buf) |c| {
        // const pie = intr.disable();
        // while (self.txbuf.full()) self.full.wait();
        // intr.restore(pie);
        while (self.txbuf.full()) continue; // spin until interrupt

        self.txbuf.putc(c);
        self.regs.intr.ier |= IER_THREIE;
    }

    return buf.len;
}

fn isr(aux: *anyopaque) void {
    const self: *Uart = @alignCast(@ptrCast(aux));
    if (self.regs.lsr & LSR_DR > 0) {
        if (!self.rxbuf.full()) {
            self.rxbuf.putc(self.regs.rw.rbr);
            self.empty.broadcast(); // Wake threads waiting on empty rbuf
        } else { self.regs.intr.ier &= ~IER_DRIE; }
    }

    if (self.regs.lsr & LSR_THRE > 0) {
        if (!self.txbuf.full()) {
            self.txbuf.putc(self.regs.rw.thr);
            self.full.broadcast(); // Wake threads waiting on full rbuf
        } else { self.regs.intr.ier &= ~IER_THREIE; }
    }
}
