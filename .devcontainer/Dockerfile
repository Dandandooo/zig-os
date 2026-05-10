FROM alpine:latest

# Basic Utilities
RUN apk add --no-cache \
    curl git tzdata cloc

# Run & Debug
RUN apk add --no-cache \
    qemu-system-riscv64 gdb just

# Zig 0.16.0 is only available in edge under the community branch
RUN echo "@edge https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
RUN apk add --no-cache \
    zig@edge=0.16.0-r0
