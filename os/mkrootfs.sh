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
#   foot, foot-terminfo       the terminal cage runs (MIT)
#   seatd                     libseat, which wlroots uses to open the screen and input
#   libudev-zero              libudev replacement that reads /sys, no udev daemon (ISC)
#   xkeyboard-config          keyboard layouts
#   fontconfig, font-dejavu   fonts for the terminal
#   ncurses-terminfo-base     terminal definitions
PACKAGES="musl mksh cage foot foot-terminfo seatd libudev-zero xkeyboard-config fontconfig font-dejavu ncurses-terminfo-base"

apk_into_root() {
    apk add --root "$OUT" --initdb --no-progress --update-cache --no-scripts \
        --arch "$(apk --print-arch)" --keys-dir /etc/apk/keys \
        --repositories-file /etc/apk/repositories "$@"
}

echo "==> installing packages with apk"
# shellcheck disable=SC2086
apk_into_root $PACKAGES

# toybox provides the commands (ls, mount, ...). Use Alpine's package if there is one,
# otherwise build it (0BSD) here.
echo "==> toybox"
if apk_into_root toybox 2>/dev/null; then
    echo "    using Alpine's toybox package"
else
    echo "    no toybox package; building toybox $TOYBOX_REF from source"
    apk add --no-progress --no-cache build-base linux-headers git >/dev/null
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
