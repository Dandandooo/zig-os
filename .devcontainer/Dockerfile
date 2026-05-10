FROM alpine:latest

# Basic Utilities
RUN apk add --no-cache \
    curl git tzdata cloc

# Build, Emulate, Debug
RUN apk add --no-cache \
    qemu-system-riscv64 gdb \
    zig==0.16.0-r0
