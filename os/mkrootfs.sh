#!/bin/sh
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Install the CobOS userspace into /out. Runs INSIDE an Alpine Linux container (started
# by os/build.sh), because Alpine packages are built against musl (MIT) instead of glibc
# (LGPL). Which packages end up in the image is judged afterwards by os/check-licenses.py.
set -eu

OUT=${OUT:-/out}
TOYBOX_REF=${TOYBOX_REF:-0.8.11}   # used only if Alpine has no toybox package

# Every name here must be an Alpine package. Everything else (wlroots, libinput, pixman,
# wayland, ...) comes in as a dependency of these.
#   musl                      C library (MIT)
#   mksh                      the shell, /bin/sh (MirOS license)
#   cage                      Wayland kiosk compositor, built on wlroots (MIT)
#   foot                      the terminal cage runs (MIT)
#   seatd                     libseat, which wlroots uses to open the screen and input
#   libudev-zero              libudev replacement that reads /sys, no udev daemon (ISC)
#   xkeyboard-config          keyboard layouts
#   fontconfig, font-dejavu   fonts for the terminal
#   ncurses-terminfo-base     terminal definitions (foot is told to use xterm-256color)
PACKAGES="musl mksh cage foot seatd libudev-zero xkeyboard-config fontconfig font-dejavu ncurses-terminfo-base"

apk_into_root() {
    apk add --root "$OUT" --initdb --no-progress --update-cache --no-scripts \
        --arch "$(apk --print-arch)" --keys-dir /etc/apk/keys \
        --repositories-file /etc/apk/repositories "$@"
}

# Check every package name before installing anything, so a wrong name is reported
# together with all the others instead of one failed run at a time.
echo "==> checking that the packages exist"
apk update >/dev/null
not_found=
for p in $PACKAGES; do
    apk search -q -e "$p" | grep -qx "$p" || not_found="$not_found $p"
done
if [ -n "$not_found" ]; then
    echo "mkrootfs.sh: not available in this Alpine release:$not_found" >&2
    echo "Fix the PACKAGES list in os/mkrootfs.sh. To look for the right name:" >&2
    echo "  docker run --rm alpine:3.22 sh -c 'apk update >/dev/null; apk search <word>'" >&2
    exit 1
fi

# Remove packages from the rootfs without apk: delete the files the package database lists
# for them and drop their database entries. apk itself cannot do this, because many packages
# (mksh, fontconfig, ...) declare a dependency on /bin/sh, and in Alpine that is provided by
# busybox (GPL-2.0), so apk installs it whether we want it or not.
purge_packages() {
    db=$OUT/lib/apk/db/installed
    tmp=$(mktemp -d)
    awk -v names=" $* " -v root="$OUT" -v listfile="$tmp/files" -v newdb="$tmp/db" '
        function flush(   i, dir) {
            if (n == 0) return
            if (index(names, " " name " ") > 0) {
                dir = ""
                for (i = 1; i <= n; i++) {
                    if (substr(lines[i], 1, 2) == "F:") dir = substr(lines[i], 3)
                    else if (substr(lines[i], 1, 2) == "R:")
                        print root "/" (dir == "" ? "" : dir "/") substr(lines[i], 3) > listfile
                }
            } else {
                for (i = 1; i <= n; i++) print lines[i] > newdb
                print "" > newdb
            }
            n = 0
            name = ""
        }
        /^$/ { flush(); next }
        { lines[++n] = $0; if (substr($0, 1, 2) == "P:") name = substr($0, 3) }
        END { flush() }
    ' "$db"
    if [ -f "$tmp/files" ]; then
        while IFS= read -r f; do rm -f -- "$f"; done < "$tmp/files"
    fi
    : >> "$tmp/db"
    cat "$tmp/db" > "$db"
    rm -rf "$tmp"
}

echo "==> installing packages with apk"
# shellcheck disable=SC2086
apk_into_root $PACKAGES

# toybox provides the commands (ls, mount, ...). Use Alpine's package if there is one. This
# comes before busybox is removed: installing anything makes apk re-check every package's
# dependencies, which would bring busybox straight back.
echo "==> toybox"
if apk_into_root toybox >/dev/null 2>&1; then toybox_pkg=1; else toybox_pkg=0; fi

# apk pulled in busybox as the provider of /bin/sh. The image uses mksh and toybox
# instead, so take busybox back out. Nothing may be installed with apk after this.
echo "==> removing busybox"
purge_packages busybox busybox-binsh busybox-extras ssl_client

if [ "$toybox_pkg" = 1 ]; then
    echo "    using Alpine's toybox package"
else
    echo "    no toybox package; building toybox $TOYBOX_REF (0BSD) from source"
    # bash is needed to run toybox's build scripts (#!/bin/bash). It, the compiler and git are
    # installed in this throwaway container only, not in the image.
    apk add --no-progress --no-cache build-base linux-headers git bash >/dev/null
    rm -rf /tmp/toybox
    git clone --quiet --depth 1 --branch "$TOYBOX_REF" https://github.com/landley/toybox /tmp/toybox
    (cd /tmp/toybox && make defconfig >/dev/null && make -j"$(nproc)" >/dev/null)
    install -D -m 0755 /tmp/toybox/toybox "$OUT/bin/toybox"
fi

TB=
for c in "$OUT/bin/toybox" "$OUT/usr/bin/toybox"; do
    if [ -x "$c" ]; then TB=$c; break; fi
done
[ -n "$TB" ] || { echo "mkrootfs.sh: toybox was not installed" >&2; exit 1; }
mkdir -p "$OUT/bin"
for cmd in $("$TB"); do
    # Never replace the shell, or anything a package already put in /bin.
    if [ "$cmd" != sh ] && [ ! -e "$OUT/bin/$cmd" ] && [ ! -L "$OUT/bin/$cmd" ]; then
        ln -s "${TB#"$OUT"}" "$OUT/bin/$cmd"
    fi
done

# mksh is the shell. Alpine installs it as /bin/mksh.
mksh=
for c in "$OUT/bin/mksh" "$OUT/usr/bin/mksh"; do
    if [ -x "$c" ]; then mksh=${c#"$OUT"}; break; fi
done
[ -n "$mksh" ] || { echo "mkrootfs.sh: mksh was not installed" >&2; exit 1; }
rm -f "$OUT/bin/sh"
ln -s "$mksh" "$OUT/bin/sh"

# Keep the package database (os/check-licenses.py reads the licenses from it); drop the cache.
rm -rf "$OUT/var/cache/apk"

# Files made in the container belong to root. Give them back to whoever started the build.
if [ -n "${HOST_UID:-}" ]; then chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$OUT"; fi

echo "==> done: $(du -sh "$OUT" | cut -f1) in $OUT"
