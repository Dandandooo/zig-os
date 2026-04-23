set quiet

_default:
    just --list --unsorted

#######################
## Zig Build Targets ##
#######################

exe := "zig-out/bin/kernel.elf"
texe := "zig-out/bin/kernel-test.elf"

# Build the regular and test executables
build:
    zig build

# Run the regular executable
run:
    zig build run

[private]
runn:
    zig build run -Dgay

# Run the test executable
test:
    zig build test

# Run the test executable in gdb
debug:
    zig build debug

# Attach gdb to the executable
gdb:
    gdb "zig-out/bin/kernel-test.elf" \
        -ex "set architecture riscv:rv64" \
        -ex "break kernel.crash" \
        -ex "target remote :1234"

# Return the size, in bytes, of the regular executable 
size: build
    du -h {{ exe }}

# Return the size, in bytes, of the test executable
tsize: build
    du -h {{ texe }}

# Return the line number at that address (regular)
addr address: build
    addr2line -e {{ exe }} {{ address }}

# Return the line number at that address (test)
taddr address: build
    addr2line -e {{ texe }} {{ address }}

###########################
## File System Utilities ##
###########################

# Build a ktfs file that contains the files/
mkfs_ktfs:
    ./util/fs/mkfs_ktfs ktfs.raw 64M 128 files/wav/* files/bin/*

#####################
## File Management ##
#####################

# Remove build and run artifacts
[no-quiet]
clean:
    rm -rf .zig-cache zig-out qemu.log qemu.wav

# Remove every temporary file
[no-quiet]
clean-all: clean
    rm -rf .zig-cache ktfs.raw


###################
## Miscellaneous ##
###################

# Print the number of lines of code in this project
cloc:
    cloc src/ build.zig kernel.ld justfile

# List available qemu audio drivers
[private]
listaudio:
    qemu-system-riscv64 -audio help
