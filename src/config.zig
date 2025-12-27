// const options = @import("build_options")
// https://stackoverflow.com/questions/76384694/how-to-do-conditional-compilation-with-zig

// PLIC & Interrupts

pub const PLIC_MMIO_BASE: usize = 0x0C00_0000;
pub const PLIC_SRC_CNT: comptime_int = 96; // QEMU VIRT_IRQCHIP_NUM_SOURCES
pub const PLIC_CTX_CNT: comptime_int = 2;

pub const NIRQ: i32 = PLIC_SRC_CNT;

pub const UART_INTR_PRIO: i32 = 3;
pub const VIOBLK_INTR_PRIO: i32 = 1;
pub const VIOCONS_INTR_PRIO: i32 = 2;
pub const VIORNG_INTR_PRIO: i32 = 1;
pub const VIOGPU_INTR_PRIO: i32 = 2;

// Devices & MMIO

pub const NDEV: u8 = 16;

pub const UART0_MMIO_BASE: usize = 0x1000_0000;
pub const UART0_INTR_SRCNO: u32 = 10;
// Currently, I won't patch QEMU to have more UARTs

const virtio = @import("dev/virtio/virtio.zig");

pub const VIRTQ0_INTR_SRCNO: u32 = 1;
pub fn VIRTQ_INTR_SRCNO(i: usize) u32 {
    return VIRTQ0_INTR_SRCNO + @as(u32, @intCast(i));
}

pub const VIRTIO0_MMIO_BASE: usize = 0x1000_1000;
pub fn VIRTIO_MMIO_BASE(i: usize) *volatile virtio.mmio_regs {
    return @ptrFromInt(VIRTIO0_MMIO_BASE + i * 0x1000);
}

pub const RTC_MMIO_BASE: usize = 0x00101000;

// RAM and Virtual Memory

pub const PAGE_ORDER: comptime_int = 12;
pub const PAGE_SIZE: comptime_int = 4096;

pub const RAM_SIZE: usize = 16 * 1024 * 1024;

pub const RAM_START_PMA: usize = 0x8000_0000;
pub const RAM_END_PMA: usize = RAM_START_PMA + RAM_SIZE;

pub const RAM_START: *anyopaque = @ptrFromInt(RAM_START_PMA);
pub const RAM_END: *anyopaque = @ptrFromInt(RAM_END_PMA);

pub const UMEM_START_VMA: usize = 0xC000_0000;
pub const UMEM_END_VMA: usize = 0x1_0000_0000;

pub const UMEM_START: *anyopaque = @ptrFromInt(UMEM_START_VMA);
pub const UMEM_END: *anyopaque = @ptrFromInt(UMEM_END_VMA);
pub const UMEM_SIZE: usize = UMEM_END_VMA - UMEM_START_VMA;

pub const HEAP_ALIGN: comptime_int = 16;

// Concurrency

pub const NTHR: comptime_int = 32;
pub const NPROC: comptime_int = 16;
pub const PROCESS_IOMAX: comptime_int = 16;
