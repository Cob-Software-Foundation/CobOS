# CobOS: a simple Wayland OS

CobOS is the Linux kernel in `Kernel-Source/` plus a tiny userspace that boots straight into a Wayland session. There is no X11 anywhere in the stack, and no copyleft program or library in the userspace (see [Licensing](#licensing)).

## What boots

1. The kernel starts and unpacks the root filesystem that is embedded in the kernel image.
2. `rootfs/init` (PID 1) mounts the basic filesystems.
3. `init` runs `cage`, a Wayland kiosk compositor built on wlroots, which shows one program full screen: the `foot` terminal.

If the session ends, `init` drops to a console shell instead of crashing the machine. The session log is `/run/cage.log`.

## Layout

| Path | Purpose |
|---|---|
| `kernel/cobos.config` | Kernel config fragment (DRM/KMS, input, tmpfs, and so on) merged over `x86_64_defconfig` |
| `kernel/dev.list` | `/dev/console` and `/dev/null`, so the image builds without root |
| `rootfs/` | The files that are the OS itself: `init` and the terminal config |
| `mkrootfs.sh` | Runs inside an Alpine container and installs the userspace packages |
| `check-licenses.py` | Reads the license of every installed package and fails on copyleft |
| `license-waivers.txt` | Packages accepted on purpose, each with a reason |
| `build.sh` | Runs all of the above and builds `out/bzImage` |
| `run-qemu.sh` | Boots `out/bzImage` in QEMU |

## Build and run

On an x86_64 Linux host with Docker (or Podman) running and internet access (Debian/Ubuntu package names):

```sh
sudo apt install build-essential bc flex bison libssl-dev libelf-dev python3 qemu-system-x86
os/build.sh        # produces os/out/bzImage; run it as yourself, not with sudo
os/run-qemu.sh     # boots it; quit QEMU with Ctrl-A then X
```

`build.sh` installs the userspace from Alpine Linux packages, because Alpine is built on musl (MIT) instead of glibc (LGPL). It then checks the licenses, and only if that passes does it build the kernel. The kernel build takes a while.

## Licensing

The code in this repository outside `Kernel-Source/` and `vendor/` (everything in `os/`, for example) is under the PolyForm Noncommercial License 1.0.0, see `LICENSE.md`. Each file in `os/` carries an SPDX identifier saying so. `LICENSE.md` is copied into the image at `/usr/share/doc/cobos/`.

**The userspace is checked, not just intended, to be copyleft-free.** After the packages are installed, `check-licenses.py` reads the license of every package from apk's database and stops the build if any package could only be used under GPL, LGPL, AGPL, MPL, EPL or similar, or has a license it does not recognise. Dual-licensed packages pass when one option is permissive (FreeType is "FTL OR GPL", so FreeType's own license is used). What goes in:

| Role | Package | License |
|---|---|---|
| C library | musl | MIT |
| Shell | mksh | MirOS |
| Commands (`ls`, `mount`, ...) | toybox | 0BSD |
| Compositor | cage, wlroots | MIT |
| Terminal | foot | MIT |
| Device discovery (no udev daemon) | libudev-zero | ISC |

These are what the packages are meant to be. The real answer for your build is the table that `check-licenses.py` prints, and `/usr/share/doc/cobos/THIRD-PARTY-LICENSES.txt` inside the image lists every package, its license and its upstream URL.

**What is still GPL, and why that is allowed.**
- **`libgcc` and `libstdc++`** are GPL with the *GCC Runtime Library Exception*. The exception lets programs that use them keep any license, so they do not make your code copyleft. The libraries themselves are still GPL, so if you distribute an image you must include their license text and offer their source. The checker marks them `exception` and the notice file marks them with `*`. To avoid them completely you would need an LLVM toolchain and no C++ components, which is a much bigger change.
- **The Linux kernel** is GPL-2.0 with its syscall exception. That cannot change, and the userspace is a separate work packed into the same file. Its source is `Kernel-Source/`.

**If the check fails.** The error names the package. Either remove it (or the package that pulls it in) in `mkrootfs.sh`, or, if apk only shows the license of the whole source package and the part you ship is permissive, add a line `<package> <reason>` to `license-waivers.txt`. Waived packages are listed on every run.

None of this is legal advice. If you plan to distribute built images, have someone check the notices and source-offer requirements for the list the checker prints.

## Wayland in the rest of CobOS

The vendored raylib in `vendor/raylib/` builds its Linux desktop backend for Wayland by default instead of X11 (`GLFW_LINUX_ENABLE_WAYLAND` and `RGFW_LINUX_ENABLE_WAYLAND` default to `TRUE`, X11 to `FALSE`; the CMake and `build.zig` defaults match). To get X11 back, pass `GLFW_LINUX_ENABLE_X11=TRUE` (or `-DGLFW_BUILD_X11=ON`, or `linux_display_backend = .X11`). Building raylib this way needs `wayland-scanner` and the Wayland development packages.

## Kernel source: what was wrong and how it was fixed

`Kernel-Source/` is meant to be a verbatim copy of upstream Linux v7.2-rc2. As first imported it was not: it was missing 1,535 files, 90 symlinks were stored as empty files, and no file was executable. `make` failed with errors such as `No rule to make target 'arch/x86/boot/startup/efi-mixed.o'`. The causes were `.gitignore` rules:

- the kernel's own `*.s` rule (generated assembler output) also matches `*.S` on case-insensitive filesystems such as Windows and macOS, which dropped 1,341 hand-written assembly sources, including `usr/initramfs_data.S` and everything under `arch/x86/entry`;
- the generic C-template rules in the root `.gitignore` (`*.lib`, `*.d`, `*.map`, `*.hex`, `*.x86_64`, ...) dropped `scripts/Makefile.lib` and about 190 more files.

The tree has been restored from upstream. Every file name, mode and content hash now matches the `v7.2-rc2` tag (94,837 files), and the `.gitignore` files were changed so it cannot happen again. `build.sh` also checks for a few files that every x86_64 build needs and says what is wrong before `make` fails.

If you ever re-import the kernel, do it from a Linux checkout on a case-sensitive filesystem and use `git add -f`.

## Status

This setup has not been booted, and the Alpine package install has never been run: the environment where it was written had no Docker daemon, no access to Alpine's package servers, no `flex` and no QEMU. What was run and passed: the license checker on a fabricated package database (copyleft, dual-license, GCC-exception, waiver and malformed cases), `mkrootfs.sh` and `build.sh` end to end up to the kernel step with stand-ins for `docker` and `apk` (including building toybox 0.8.11 from source, which provides every command `init` uses), and a byte-for-byte comparison of `Kernel-Source/` with upstream.

Most likely to need adjusting on the first real run:
- **Package names and dependencies.** If `apk` reports an unknown package, fix the list in `mkrootfs.sh`. If a package pulls in something copyleft (for example `busybox` as a provider of `/bin/sh`, or `eudev-libs` as a provider of `libudev`), the license check will name it.
- **libseat's built-in backend.** `init` sets `LIBSEAT_BACKEND=builtin`. If Alpine's build lacks it, the session log `/run/cage.log` says so, and `seatd` has to be started in `init` instead.
- **Keyboard and mouse.** wlroots and libinput must find them through libudev-zero. If there is no input, look here first.
