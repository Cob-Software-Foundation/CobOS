#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Boot CobOS in QEMU.   Usage: os/run-qemu.sh [path/to/bzImage]
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KERNEL=${1:-$HERE/out/bzImage}

[ -f "$KERNEL" ] || { echo "run-qemu.sh: $KERNEL not found; run os/build.sh first" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    echo "run-qemu.sh: qemu-system-x86_64 is not installed (Debian/Ubuntu: sudo apt install qemu-system-x86)" >&2
    exit 1
}

# Use hardware acceleration when KVM is available.
accel=(-cpu max)
if [ -w /dev/kvm ]; then accel=(-enable-kvm -cpu host); fi

# The last console= is where init's output goes: the QEMU window (tty0), with a copy of
# kernel messages on the serial port. A virtio GPU, keyboard and tablet (absolute
# pointer) give the Wayland session a display and input. Quit with Ctrl-A then X.
exec qemu-system-x86_64 "${accel[@]}" -m 1024 -smp 2 \
    -kernel "$KERNEL" \
    -append "console=ttyS0 console=tty0" \
    -device virtio-vga \
    -device virtio-keyboard-pci \
    -device virtio-tablet-pci \
    -serial mon:stdio
