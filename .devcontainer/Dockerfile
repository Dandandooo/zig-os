FROM alpine:latest

# Basic Utilities
RUN apk add --no-cache \
    curl git tzdata cloc

# Build, Emulate, Debug
RUN apk add --no-cache \
    qemu-system-riscv64 gdb \
    zig==0.15.2-r0

# Audio
RUN apk add --no-cache \
    pulseaudio-utils libpulse alsa-utils alsa-lib \
    qemu-audio-pa qemu-audio-alsa
