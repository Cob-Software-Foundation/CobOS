#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Build CobOS: a Wayland-ready Linux kernel with its root filesystem embedded.
# Output: os/out/bzImage (boot it with os/run-qemu.sh).
#
# The userspace comes from Alpine Linux packages (built against musl, MIT) that are
# installed by os/mkrootfs.sh inside a container. os/check-licenses.py then reads the
# license of every package that ended up in the image and stops the build if any is
# copyleft, so what is in the image is checked, not assumed.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$HERE/../Kernel-Source
OUT=$(realpath -m "${OUT:-$HERE/out}")
KO=$OUT/kernel
ROOT=$OUT/rootfs
JOBS=${JOBS:-$(nproc)}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22}

die() { echo "build.sh: $*" >&2; exit 1; }

# INITRAMFS_SOURCE is a space-separated list, so paths cannot contain spaces.
case "$HERE$OUT" in *" "*) die "the repository and output paths must not contain spaces" ;; esac

# ---- 1. Check the host has everything before doing any work ----
missing=()
for tool in gcc make bc flex bison python3; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    die "missing tools: ${missing[*]}
On Debian/Ubuntu: sudo apt install build-essential bc flex bison libssl-dev libelf-dev python3"
fi

container=
for c in docker podman; do
    if command -v "$c" >/dev/null 2>&1; then container=$c; break; fi
done
[ -n "$container" ] || die "docker or podman is needed to install the Alpine (musl) userspace"
"$container" info >/dev/null 2>&1 \
    || die "$container is installed but not usable (is the daemon running, and are you allowed to use it?)"

# ---- 1b. Check that the kernel source tree is complete ----
# Earlier copies of this repository had lost kernel files to .gitignore rules: "*.lib"
# dropped scripts/Makefile.lib, and "*.s" also matched "*.S" on case-insensitive
# filesystems (Windows, macOS), which dropped every assembly source. The build then
# fails deep inside make with "No rule to make target ...". Check a few files that
# every x86_64 build needs, so the failure is explained up front.
tree_missing=()
for f in scripts/Makefile.lib usr/initramfs_data.S arch/x86/boot/startup/efi-mixed.S \
         arch/x86/boot/startup/la57toggle.S arch/x86/entry/entry_64.S; do
    [ -f "$SRC/$f" ] || tree_missing+=("$f")
done
if [ "${#tree_missing[@]}" -gt 0 ]; then
    die "Kernel-Source is incomplete, so the kernel cannot be built. Missing:
$(printf '  %s\n' "${tree_missing[@]}")
Ignore rules dropped these files from git. Update your checkout (git pull); if you are
re-importing the kernel, copy it from a Linux v7.2-rc2 checkout and add it with 'git add -f'."
fi

# The kernel build runs many of its scripts directly, so they must be executable. They are
# in git, but a checkout that drops the executable bit (a zip download, or a filesystem or
# git setting that ignores file modes) would break the build with "Permission denied".
# This only checks; it does not change files, so the tree stays identical to upstream.
if [ ! -x "$SRC/scripts/pahole-version.sh" ]; then
    die "the kernel scripts are not executable (Kernel-Source/scripts/pahole-version.sh).
Your checkout lost the executable bits. Check out the repository with git on a filesystem
that supports them, and make sure 'git config core.fileMode' is not false."
fi

# ---- 2. Install the userspace (Alpine packages) into the root filesystem ----
echo "==> installing the userspace with $container ($ALPINE_IMAGE)"
rm -rf "$ROOT" 2>/dev/null || die "cannot remove $ROOT (an earlier build may have run as root); remove it with: sudo rm -rf $ROOT"
mkdir -p "$ROOT"

# Files made inside the container belong to root. With a normal (rootful) docker, ask the
# container to hand them back to us; rootless docker and podman already map root to us.
owner_args=()
if [ "$(id -u)" != 0 ] && [ "$container" = docker ] \
   && ! "$container" info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    owner_args=(-e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)")
fi
"$container" run --rm ${owner_args[@]+"${owner_args[@]}"} \
    -v "$ROOT:/out" -v "$HERE/mkrootfs.sh:/mkrootfs.sh:ro" \
    "$ALPINE_IMAGE" sh /mkrootfs.sh

# ---- 3. Refuse to continue if anything copyleft got in ----
echo "==> checking the licenses of what is in the image"
python3 -I "$HERE/check-licenses.py" "$ROOT" \
    --waivers "$HERE/license-waivers.txt" \
    --notice "$ROOT/usr/share/doc/cobos/THIRD-PARTY-LICENSES.txt" \
    || die "the image contains copyleft or unrecognised licenses (see above)"

# ---- 4. Add the CobOS files and the license text ----
echo "==> adding CobOS files"
mkdir -p "$ROOT"/{proc,sys,run,tmp,root,var,etc}
cp -a "$HERE/rootfs/." "$ROOT/"
chmod 0755 "$ROOT/init"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$ROOT/etc/passwd"
printf 'root:x:0:\n' > "$ROOT/etc/group"
# PolyForm Noncommercial asks that copies of the software carry its terms and notices.
install -D -m 0644 "$HERE/../LICENSE.md" "$ROOT/usr/share/doc/cobos/LICENSE.md"
echo "    rootfs size: $(du -sh "$ROOT" | cut -f1)"

# ---- 5. Configure and build the kernel with the rootfs embedded ----
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
