OUTPUT_ARCH("riscv")
/* ENTRY(_start) */


PHDRS {
  text PT_LOAD;
  rodata PT_LOAD;
  data PT_LOAD;
}

PROVIDE(_ram_size = 16M);
PROVIDE(_ram_start = 0x80000000);

PROVIDE(_page_size = 4096);

MEMORY {
  mmio (w)  : ORIGIN = 0x0, LENGTH = _ram_start
  ram (wxa) : ORIGIN = _ram_start, LENGTH = _ram_size
}

SECTIONS {
  . = _ram_start;

  PROVIDE(_kimg_start = .);

  .text : {
    . = ALIGN(_page_size);
    PROVIDE(_kimg_text_start = .);
    *(.text.start) /* entry */
    *(.text .text.*)
    . = ALIGN(16);
    PROVIDE(_kimg_text_end = .);
  } >ram AT>ram :text

  .rodata : {
    . = ALIGN(_page_size);
    PROVIDE(_kimg_rodata_start = .);
    PROVIDE(_kimg_blob_start = .);
    *(*.rodata.blob)
    PROVIDE(_kimg_blob_end = .);
    . = ALIGN(16);
    *(.srodata .srodata.*)
    . = ALIGN(16);
    *(.rodata .rodata.*)
    PROVIDE(_kimg_rodata_end = .);
  } >ram AT>ram :rodata

  .data : {
    . = ALIGN(_page_size);
    PROVIDE(_kimg_data_start = .);
    *(.sdata .sdata.*)
    . = ALIGN(16);
    *(.data .data.*)
    . = ALIGN(16);
  } >ram AT>ram :data

  .bss : {
    *(.data.pagetable)
    *(.sbss .sbss.*)
    . = ALIGN(16);
    *(.bss .bss.*)
    . = ALIGN(16);
    PROVIDE(_kimg_data_end = .);
  } >ram AT>ram :data

  PROVIDE(_kimg_end = .);
}
