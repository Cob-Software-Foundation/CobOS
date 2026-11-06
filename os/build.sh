#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Build CobOS: a Wayland-ready Linux kernel with its root filesystem embedded.
# Output: os/out/bzImage (boot it with os/run-qemu.sh).
#
# The root filesystem is assembled from this machine's toybox, mksh and Weston, plus
# libudev-zero built from source, so build on an x86_64 Linux host that has them.
# None of the programs in the image is GPL: toybox is 0BSD, mksh is MirOS-licensed,
# Weston is MIT and libudev-zero is ISC. Run os/audit-licenses.sh on the result to see
# exactly what ended up in the image (the C library is still LGPL; see os/README.md).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$HERE/../Kernel-Source
OUT=$(realpath -m "${OUT:-$HERE/out}")
KO=$OUT/kernel
ROOT=$OUT/rootfs
JOBS=${JOBS:-$(nproc)}

die() { echo "build.sh: $*" >&2; exit 1; }

# INITRAMFS_SOURCE is a space-separated list, so paths cannot contain spaces.
case "$HERE$OUT" in *" "*) die "the repository and output paths must not contain spaces" ;; esac

# ---- 1. Check the host has everything before doing any work ----
missing=()
for tool in gcc make bc flex bison toybox mksh weston weston-terminal ldd; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    die "missing tools: ${missing[*]}
On Debian/Ubuntu: sudo apt install build-essential bc flex bison libssl-dev libelf-dev toybox mksh weston"
fi

weston_major=$(weston --version 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)
if [ -n "$weston_major" ] && [ "$weston_major" -lt 10 ]; then
    die "Weston $weston_major is too old; the kiosk shell needs Weston 10 or newer"
fi

# toybox prints its list of commands when run with no arguments. init needs these.
toybox_cmds=$(toybox 2>/dev/null | tr -s ' \t\n' '\n' | grep -v '^$' || true)
if [ -n "$toybox_cmds" ]; then
    for cmd in mount mkdir hostname sleep chmod setsid; do
        printf '%s\n' "$toybox_cmds" | grep -qx "$cmd" \
            || die "this toybox does not provide '$cmd', which init needs; use a newer toybox"
    done
else
    echo "warning: could not list the commands of this toybox; the image may lack tools" >&2
fi

# libudev-zero replaces systemd's udev (GPL daemon, LGPL library). Get it with:
#   git clone https://github.com/illiliti/libudev-zero
LIBUDEV_ZERO_SRC=${LIBUDEV_ZERO_SRC:-}
if [ -z "$LIBUDEV_ZERO_SRC" ] || [ ! -f "$LIBUDEV_ZERO_SRC/Makefile" ]; then
    die "set LIBUDEV_ZERO_SRC to a checkout of libudev-zero (ISC licence), for example:
  git clone https://github.com/illiliti/libudev-zero ~/libudev-zero
  LIBUDEV_ZERO_SRC=~/libudev-zero os/build.sh
It replaces systemd's udev, which is GPL/LGPL and would otherwise end up in the image."
fi
LIBUDEV_ZERO_SRC=$(realpath "$LIBUDEV_ZERO_SRC")

# ---- 1b. Check that the kernel source tree is complete and runnable ----
# The repository's root .gitignore contained "*.lib", which also matches the kernel's
# scripts/Makefile.lib. If that file is missing, no kernel target can build.
if [ ! -f "$SRC/scripts/Makefile.lib" ]; then
    die "Kernel-Source/scripts/Makefile.lib is missing, so the kernel cannot be built.
The '*.lib' rule in .gitignore kept it out of git. Restore the file from the matching
upstream Linux release (7.2-rc2), then add it with:
  git add -f Kernel-Source/scripts/Makefile.lib"
fi

# The repository stores kernel scripts as non-executable, but the kernel build runs
# many of them directly. Restore the executable bit on the scripts the build needs.
(cd "$SRC" && grep -rIl -m1 '^#!' scripts usr arch/x86 tools 2>/dev/null | while read -r f; do
    if [ "$(head -c2 "$f")" = '#!' ]; then chmod +x "$f"; fi
done) || true

# ---- 2. Assemble the root filesystem ----
echo "==> assembling root filesystem in $ROOT"
rm -rf "$ROOT"
mkdir -p "$ROOT"/{bin,sbin,etc,proc,sys,run,tmp,root,var,usr/bin}
cp -a "$HERE/rootfs/." "$ROOT/"
chmod 0755 "$ROOT/init"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$ROOT/etc/passwd"
printf 'root:x:0:\n' > "$ROOT/etc/group"

# Copy host files or directories into the rootfs at their resolved paths.
copy_tree() {
    local p
    for p in "$@"; do
        if [ -e "$p" ]; then
            cp -a --parents "$(readlink -f "$p")" "$ROOT"
        fi
    done
}

# toybox (0BSD) provides the command-line tools, with a symlink per command;
# mksh (MirOS licence) is /bin/sh.
install -D -m 0755 "$(command -v toybox)" "$ROOT/bin/toybox"
for cmd in $toybox_cmds; do
    if [ "$cmd" != "sh" ]; then ln -sf toybox "$ROOT/bin/$cmd"; fi
done
install -D -m 0755 "$(command -v mksh)" "$ROOT/bin/mksh"
ln -sf mksh "$ROOT/bin/sh"

# the Wayland compositor and the program the session launches
install -D -m 0755 "$(command -v weston)" "$ROOT/usr/bin/weston"
install -D -m 0755 "$(command -v weston-terminal)" "$ROOT/usr/bin/weston-terminal"

# Weston loads its backends, renderers and shells at run time, so ldd cannot see
# them; copy those directories whole, along with keymaps and fonts.
copy_tree /usr/lib/x86_64-linux-gnu/weston /usr/lib/x86_64-linux-gnu/libweston-* \
          /usr/lib/weston /usr/lib64/weston \
          /usr/share/X11/xkb /etc/fonts /usr/share/fonts/truetype/dejavu

# Add the shared libraries every copied program needs.
echo "==> resolving shared libraries"
while IFS= read -r -d '' file; do
    if [ "$(LC_ALL=C head -c4 "$file" 2>/dev/null | tail -c3)" != "ELF" ]; then
        continue
    fi
    while IFS= read -r lib; do
        if [ -e "$lib" ] && [ ! -e "$ROOT$lib" ]; then
            cp -L --parents "$lib" "$ROOT"
        fi
    done < <(ldd "$file" 2>/dev/null | grep -oE '/[^ ]+' || true)
done < <(find "$ROOT" -type f -print0)

# Swap systemd's libudev (copied by the step above) for libudev-zero. Both are named
# libudev.so.1, which is what Weston and libinput load. It is built out of tree so the
# checkout stays clean.
echo "==> building libudev-zero"
rm -rf "$OUT/libudev-zero"
cp -a "$LIBUDEV_ZERO_SRC" "$OUT/libudev-zero"
make -C "$OUT/libudev-zero" -j"$JOBS" >/dev/null
udev_lib=$(ls "$OUT"/libudev-zero/libudev.so.1.* 2>/dev/null | head -n1 || true)
[ -n "$udev_lib" ] || die "libudev-zero did not produce a libudev.so.1.* library"
replaced=0
while IFS= read -r -d '' file; do
    install -m 0755 "$udev_lib" "$file"
    replaced=1
done < <(find "$ROOT" -name 'libudev.so.1*' -type f -print0)
if [ "$replaced" -eq 0 ]; then
    install -D -m 0755 "$udev_lib" "$ROOT/usr/lib/x86_64-linux-gnu/libudev.so.1"
fi

echo "    rootfs size: $(du -sh "$ROOT" | cut -f1)"

# ---- 3. Configure and build the kernel with the rootfs embedded ----
echo "==> configuring the kernel"
mkdir -p "$KO"
make -C "$SRC" O="$KO" x86_64_defconfig
"$SRC/scripts/kconfig/merge_config.sh" -m -O "$KO" "$KO/.config" "$HERE/kernel/cobos.config"
"$SRC/scripts/config" --file "$KO/.config" \
    --set-str INITRAMFS_SOURCE "$ROOT $HERE/kernel/dev.list" \
    --set-val INITRAMFS_ROOT_UID "$(id -u)" \
    --set-val INITRAMFS_ROOT_GID "$(id -g)"
make -C "$SRC" O="$KO" olddefconfig

echo "==> building the kernel (this takes a while)"
make -C "$SRC" O="$KO" -j"$JOBS" bzImage
cp "$KO/arch/x86/boot/bzImage" "$OUT/bzImage"

echo
echo "Built $OUT/bzImage ($(du -h "$OUT/bzImage" | cut -f1))"
echo "Check what is in it with: $HERE/audit-licenses.sh"
echo "Boot it with: $HERE/run-qemu.sh"
