set quiet

_default:
    just --list --unsorted

## Zig Build Targets
exe := "zig-out/bin/kernel.elf"
texe := "zig-out/bin/kernel-test.elf"

build:
    zig build

run:
    zig build run

test:
    zig build test

size: build
    du -h {{ exe }}

tsize: build
    du -h {{ texe }}

addr address: build
    addr2line -e {{ exe }} {{ address }}

taddr address: build
    addr2line -e {{ texe }} {{ address }}

## File System Utilities

mkfs_ktfs:
    ./util/fs/mkfs_ktfs ktfs.raw 64M 128 files/wav/* files/bin/*

## File Management

[no-quiet]
clean:
    rm -rf .zig-cache zig-out qemu.log qemu.wav

[no-quiet]
clean-all: clean
    rm -rf .zig-cache ktfs.raw

## Miscellaneous

cloc:
    cloc src/ build.zig kernel.ld justfile

[private]
listaudio:
    qemu-system-riscv64 -audio help
