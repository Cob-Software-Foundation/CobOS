# CobOS: a simple Wayland OS

CobOS is the Linux kernel in `Kernel-Source/` plus a tiny userspace that boots straight into a Wayland session. There is no X11 anywhere in the stack.

## What boots

1. The kernel starts and unpacks the root filesystem that is embedded in the kernel image.
2. `rootfs/init` (PID 1) mounts the basic filesystems.
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
| `audit-licenses.sh` | Lists which host packages ended up in the image and flags GPL/LGPL mentions |

## Build and run

On an x86_64 Linux host (Debian/Ubuntu package names):

```sh
sudo apt install build-essential bc flex bison libssl-dev libelf-dev toybox mksh weston qemu-system-x86
git clone https://github.com/illiliti/libudev-zero ~/libudev-zero
LIBUDEV_ZERO_SRC=~/libudev-zero os/build.sh     # produces os/out/bzImage
os/run-qemu.sh                                  # boots it; quit QEMU with Ctrl-A then X
os/audit-licenses.sh                            # shows what is in the image and under which licenses
```

`build.sh` copies toybox, mksh and Weston from the machine it runs on, so it needs Weston 10 or newer, and it builds libudev-zero from the checkout you point it at. The kernel build takes a while and the image is a few hundred MB.

## Licensing

The userspace code in this repository (everything in `os/`, plus the repository's own code outside `Kernel-Source/` and `vendor/`) is under the PolyForm Noncommercial License 1.0.0, see `LICENSE.md`. Each file in `os/` carries an SPDX identifier saying so.

**No GPL programs are in the image.** BusyBox (GPL-2.0) and systemd's udev (GPL-2.0-or-later) were replaced with:

| Role | Program | License |
|---|---|---|
| Shell | mksh | MirOS License (permissive) |
| Commands (`ls`, `mount`, ...) | toybox | 0BSD |
| Compositor | Weston | MIT |
| Device discovery for libinput and Weston | libudev-zero, which reads `/sys` directly so no udev daemon runs | ISC |

These are the upstream licenses as I know them. Do not rely on that alone: run `os/audit-licenses.sh` after a build to see what is really in the image on your machine.

**What is still copyleft.**
- **The C library.** The image uses the host's glibc (LGPL-2.1) and `libgcc_s` (GPL-3.0 with the GCC Runtime Library Exception). Every normal Linux program runs on these. Dynamically linking to them does not change your code's license, but distributing the image means shipping their license texts and offering their source. Getting rid of them means moving to a musl-based userspace (MIT), which is a much bigger change.
- **Libraries pulled in by Weston and `weston-terminal`.** Some of these, such as cairo, are LGPL or MPL. The audit script lists them.
- **The kernel.** Linux is GPL-2.0 with its syscall exception. That stays as it is, and the userspace is a separate work that happens to be packed into the same file.

None of this is legal advice. If you plan to distribute built images, have someone check the notices and source-offer requirements for what the audit shows.

## Wayland in the rest of CobOS

The vendored raylib in `vendor/raylib/` now builds its Linux desktop backend for Wayland by default instead of X11 (`GLFW_LINUX_ENABLE_WAYLAND` and `RGFW_LINUX_ENABLE_WAYLAND` default to `TRUE`, X11 to `FALSE`; the CMake and `build.zig` defaults match). To get X11 back, pass `GLFW_LINUX_ENABLE_X11=TRUE` (or `-DGLFW_BUILD_X11=ON`, or `linux_display_backend = .X11`). Building raylib this way needs `wayland-scanner` and the Wayland development packages.

## Kernel source: what was wrong and how it was fixed

`Kernel-Source/` is meant to be a verbatim copy of upstream Linux v7.2-rc2. As first imported it was not: it was missing 1,535 files, 90 symlinks were stored as empty files, and no file was executable. `make` failed with errors such as `No rule to make target 'arch/x86/boot/startup/efi-mixed.o'`. The causes were `.gitignore` rules:

- the kernel's own `*.s` rule (generated assembler output) also matches `*.S` on case-insensitive filesystems such as Windows and macOS, which dropped 1,341 hand-written assembly sources, including `usr/initramfs_data.S` and everything under `arch/x86/entry`;
- the generic C-template rules in the root `.gitignore` (`*.lib`, `*.d`, `*.map`, `*.hex`, `*.x86_64`, ...) dropped `scripts/Makefile.lib` and about 190 more files.

The tree has been restored from upstream. Every file name, mode and content hash now matches the `v7.2-rc2` tag (94,837 files), and the `.gitignore` files were changed so it cannot happen again. `build.sh` also checks for a few files that every x86_64 build needs and says what is wrong before `make` fails.

If you ever re-import the kernel, do it from a Linux checkout on a case-sensitive filesystem and use `git add -f`.

## Status

This setup has not been booted. In the environment where it was written there was no QEMU, no `flex`, no Weston, no toybox or mksh and no network, so the kernel could not be built or configured. What was checked: the shell scripts parse, every config symbol in `kernel/cobos.config` exists in this kernel's Kconfig, the library-resolution step produces a rootfs that runs under `chroot`, the initramfs packaging produces the expected archive (with `/dev/console`, `/dev/null` and an executable `init`), and the license audit script runs against a test image.

The parts most likely to need adjusting on a first boot are:
- **libudev-zero as a stand-in for libudev.** Weston and libinput have to find the keyboard, mouse and GPU through it. If there is no input, look here first.
- **toybox.** `init` needs `mount`, `mkdir`, `hostname`, `sleep`, `chmod` and `setsid`; `build.sh` checks that your toybox has them. A new enough toybox is needed.
- **The Weston kiosk `[autolaunch]` settings,** which depend on the Weston version on the build host.
