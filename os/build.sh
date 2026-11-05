#!/usr/bin/env bash
# Build CobOS: a Wayland-ready Linux kernel with its root filesystem embedded.
# Output: os/out/bzImage (boot it with os/run-qemu.sh).
#
# The root filesystem is assembled from this machine's busybox, Weston and udev,
# so build on an x86_64 Linux host that has them installed.
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
for tool in gcc make bc flex bison busybox weston weston-terminal ldd; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    die "missing tools: ${missing[*]}
On Debian/Ubuntu: sudo apt install build-essential bc flex bison libssl-dev libelf-dev busybox-static weston udev"
fi

weston_major=$(weston --version 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)
if [ -n "$weston_major" ] && [ "$weston_major" -lt 10 ]; then
    die "Weston $weston_major is too old; the kiosk shell needs Weston 10 or newer"
fi

# ---- 1b. Check that the kernel source tree is complete and runnable ----
# The repository's root .gitignore contains "*.lib", which also matches the kernel's
# scripts/Makefile.lib. That file was therefore never committed, and without it no
# kernel target can build.
if [ ! -f "$SRC/scripts/Makefile.lib" ]; then
    die "Kernel-Source/scripts/Makefile.lib is missing, so the kernel cannot be built.
The '*.lib' rule in .gitignore kept it out of git. Restore the file from the matching
upstream Linux release (7.2-rc2), then add it with:
  git add -f Kernel-Source/scripts/Makefile.lib"
fi

# The repository also stores every script as non-executable, but the kernel build runs
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

# busybox plus an applet symlink for every command it provides
install -D -m 0755 "$(command -v busybox)" "$ROOT/bin/busybox"
for applet in $("$ROOT/bin/busybox" --list); do
    ln -sf busybox "$ROOT/bin/$applet"
done

# the Wayland compositor and the program the session launches
install -D -m 0755 "$(command -v weston)" "$ROOT/usr/bin/weston"
install -D -m 0755 "$(command -v weston-terminal)" "$ROOT/usr/bin/weston-terminal"

# Weston loads its backends, renderers and shells at run time, so ldd cannot see
# them; copy those directories whole, along with keymaps and fonts.
copy_tree /usr/lib/x86_64-linux-gnu/weston /usr/lib/x86_64-linux-gnu/libweston-* \
          /usr/lib/weston /usr/lib64/weston \
          /usr/share/X11/xkb /etc/fonts /usr/share/fonts/truetype/dejavu

# udev, so libinput can find the keyboard and mouse
udevd=
for candidate in /lib/systemd/systemd-udevd /usr/lib/systemd/systemd-udevd /sbin/udevd; do
    if [ -x "$candidate" ]; then udevd=$(readlink -f "$candidate"); break; fi
done
if [ -n "$udevd" ] && command -v udevadm >/dev/null 2>&1; then
    install -D -m 0755 "$udevd" "$ROOT/sbin/udevd"
    install -D -m 0755 "$(command -v udevadm)" "$ROOT/sbin/udevadm"
    copy_tree /lib/udev /etc/udev/hwdb.bin /usr/lib/udev/hwdb.bin
else
    echo "warning: systemd-udevd/udevadm not found; the keyboard and mouse will not work" >&2
fi

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
echo "Boot it with: $HERE/run-qemu.sh"
