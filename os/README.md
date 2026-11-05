# CobOS: a simple Wayland OS

CobOS is the Linux kernel in `Kernel-Source/` plus a tiny userspace that boots straight into a Wayland session. There is no X11 anywhere in the stack.

## What boots

1. The kernel starts and unpacks the root filesystem that is embedded in the kernel image.
2. `rootfs/init` (PID 1) mounts the basic filesystems and starts udev.
3. `init` runs Weston, the reference Wayland compositor, on the DRM/KMS backend in kiosk mode.
4. Weston launches one full-screen program, `weston-terminal`, as configured in `rootfs/etc/xdg/weston/weston.ini`.

If Weston exits, `init` drops to a console shell instead of crashing the machine.

## Layout

| Path | Purpose |
|---|---|
| `kernel/cobos.config` | Kernel config fragment (DRM/KMS, input, tmpfs, and so on) merged over `x86_64_defconfig` |
| `kernel/dev.list` | `/dev/console` and `/dev/null`, so the image builds without root |
| `rootfs/` | The files that are the OS itself: `init` and the Weston config |
| `build.sh` | Assembles the rootfs and builds `out/bzImage` |
| `run-qemu.sh` | Boots `out/bzImage` in QEMU |

## Build and run

On an x86_64 Linux host (Debian/Ubuntu package names):

```sh
sudo apt install build-essential bc flex bison libssl-dev libelf-dev busybox-static weston udev qemu-system-x86
os/build.sh        # produces os/out/bzImage
os/run-qemu.sh     # boots it; quit QEMU with Ctrl-A then X
```

`build.sh` copies busybox, Weston and udev from the machine it runs on, so it needs Weston 10 or newer. The kernel build takes a while and the image is a few hundred MB.

## Wayland in the rest of CobOS

The vendored raylib in `vendor/raylib/` now builds its Linux desktop backend for Wayland by default instead of X11 (`GLFW_LINUX_ENABLE_WAYLAND` and `RGFW_LINUX_ENABLE_WAYLAND` default to `TRUE`, X11 to `FALSE`; the CMake and `build.zig` defaults match). To get X11 back, pass `GLFW_LINUX_ENABLE_X11=TRUE` (or `-DGLFW_BUILD_X11=ON`, or `linux_display_backend = .X11`). Building raylib this way needs `wayland-scanner` and the Wayland development packages.

## Known problems in this repository

These came with the repository as cloned and block the kernel build until they are fixed.

1. **`Kernel-Source/scripts/Makefile.lib` is missing.** The root `.gitignore` has a `*.lib` rule (from a generic C template) that also matches this file, so it was never committed. Restore it from upstream Linux 7.2-rc2 and add it with `git add -f Kernel-Source/scripts/Makefile.lib`. Consider replacing the `*.lib` rule with a narrower one, and check that other template rules (`*.a`, `*.so`, `*.map`, `*.hex`, `*.out` and so on) have not dropped other files.
2. **Every script is stored without its executable bit** (all tracked files are mode `100644`). `build.sh` restores the bit in your working tree before building. To fix it in git, commit the mode change.

`build.sh` checks for the first problem and stops with a clear message instead of a `make` error.

## Status

This setup has not been booted. In the environment where it was written there was no QEMU, no `flex` and no network, and the kernel could not be configured because of the problems above. What was checked: the shell scripts parse, every config symbol in `kernel/cobos.config` exists in this kernel's Kconfig, the library-resolution step produces a rootfs that runs under `chroot`, and the initramfs packaging produces the expected archive (with `/dev/console`, `/dev/null` and an executable `init`).

The parts most likely to need adjusting on a first boot are the udev setup (keyboard and mouse) and the Weston kiosk `[autolaunch]` settings, which depend on the Weston version on the build host.
