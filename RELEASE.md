# CobOS v0.0.1

First release. This is an early build, not a finished system.

## What is in it

- `bzImage`: a Linux v7.2-rc2 kernel with the CobOS root filesystem built in.
- Userspace from Alpine Linux 3.22 (musl): the `cage` Wayland compositor, the `foot`
  terminal, `mksh`, and toybox 0.8.11 built from source.
- `THIRD-PARTY-LICENSES.txt`: the license of every package in the image.
- `SHA256SUMS`: checksums for the files above.

## How to run it

Download `bzImage`, install QEMU, then from a checkout of this repository:

    os/run-qemu.sh path/to/bzImage

Quit QEMU with Ctrl-A, then X.

## Known limitations

- Tested only in headless QEMU. The kernel boots, `/init` runs and a shell prompt appears.
- The Wayland session (`cage` + `foot`) started but exited in that headless test, so
  the graphical desktop is not verified yet.
- The image includes LGPL libraries (glib, graphite2, libblkid, libintl, libmount,
  libelf, libelogind). See `THIRD-PARTY-LICENSES.txt`.

## License

PolyForm Noncommercial 1.0.0. See `LICENSE.md`.