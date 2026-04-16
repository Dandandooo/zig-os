FROM alpine:latest

RUN apk add --no-cache \
    bash curl git gdb tzdata \
    qemu-system-riscv64 qemu-audio-pa \
    zig==0.15.2-r0 \
    pulseaudio-utils alsa-utils libpulse

# RUN adduser -D vscode || true && addgroup vscode audio
