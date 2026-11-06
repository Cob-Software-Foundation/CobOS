#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# List the host packages whose files ended up in the CobOS root filesystem, and flag
# the ones whose copyright file mentions the GPL family.
#
# Usage: os/audit-licenses.sh [path/to/rootfs]     (default: os/out/rootfs)
#
# This is a heuristic, not legal advice. Debian copyright files often mention the GPL
# for packaging scripts or optional parts, so a flag means "look at this package", not
# "this binary is GPL". Needs dpkg, so it works on Debian and Ubuntu.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(realpath -m "${1:-${OUT:-$HERE/out}/rootfs}")

die() { echo "audit-licenses.sh: $*" >&2; exit 1; }
[ -d "$ROOT" ] || die "$ROOT not found; run os/build.sh first or pass the rootfs directory"
command -v dpkg >/dev/null 2>&1 || die "this script needs dpkg, so it works on Debian/Ubuntu only"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Every regular file in the image, as an absolute path. Copied libraries and data keep
# their host paths, so dpkg can tell which package owns them. Each path is also tried
# with its symlinks resolved, because the package database may list either form.
(cd "$ROOT" && find . -type f -print0) | sed -z 's|^\./|/|' > "$tmp/paths"
while IFS= read -r -d '' p; do
    printf '%s\0' "$p"
    resolved=$(readlink -f "$p" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ "$resolved" != "$p" ]; then printf '%s\0' "$resolved"; fi
done < "$tmp/paths" > "$tmp/query"

xargs -0 -a "$tmp/query" dpkg -S -- 2>/dev/null | grep -v '^diversion' > "$tmp/owned" || true

# Files that no package owns: CobOS's own files and anything built locally.
declare -A owned=()
while IFS= read -r line; do owned["${line#*: }"]=1; done < "$tmp/owned"
unowned=()
while IFS= read -r -d '' p; do
    resolved=$(readlink -f "$p" 2>/dev/null || true)
    if [ -z "${owned[$p]:-}" ] && [ -z "${owned[$resolved]:-}" ]; then unowned+=("$p"); fi
done < "$tmp/paths"

sed -E 's/: \/.*$//' "$tmp/owned" | tr ',' '\n' | sed -E 's/^ +//; s/:[a-z0-9-]+$//' \
    | grep -v '^$' | sort -u > "$tmp/pkgs"

# The licences a package's copyright file declares.
licenses_of() {
    local f=/usr/share/doc/$1/copyright l
    if [ ! -r "$f" ]; then echo "(no copyright file)"; return; fi
    l=$(grep -E '^License:' "$f" | sed -E 's/^License: *//; s/ +$//' | grep -v '^$' \
        | sort -u | paste -sd ';' - | cut -c1-72 || true)
    if [ -n "$l" ]; then
        echo "$l"
    elif grep -qiE 'GNU (Lesser |Library )?General Public License' "$f"; then
        echo "(free-form text; mentions the GNU GPL/LGPL)"
    else
        echo "(free-form text; no GPL text found)"
    fi
}

# GPL, LGPL or AGPL, judged from that string.
flag_of() {
    local s=$1 out=""
    if printf '%s' "$s" | grep -qE '(^|[^LA])GPL|GNU General|mentions the GNU'; then out="GPL"; fi
    if printf '%s' "$s" | grep -qE 'AGPL'; then out="${out:+$out,}AGPL"; fi
    if printf '%s' "$s" | grep -qiE 'LGPL|Lesser|Library General'; then out="${out:+$out,}LGPL"; fi
    printf '%s' "${out:--}"
}

echo "Image: $ROOT"
echo "Files: $(tr -cd '\0' < "$tmp/paths" | wc -c), from $(wc -l < "$tmp/pkgs") packages, ${#unowned[@]} not from any package"
echo
printf '%-26s %-10s %s\n' PACKAGE FLAG LICENSES
gpl=()
lgpl=()
while IFS= read -r pkg; do
    lic=$(licenses_of "$pkg")
    flag=$(flag_of "$lic")
    printf '%-26s %-10s %s\n' "$pkg" "$flag" "$lic"
    case ",$flag," in *,GPL,*|*,AGPL,*) gpl+=("$pkg") ;; esac
    case ",$flag," in *,LGPL,*) lgpl+=("$pkg") ;; esac
done < "$tmp/pkgs"

echo
echo "Not from any package (CobOS files, locally built libraries):"
if [ "${#unowned[@]}" -eq 0 ]; then echo "  (none)"; else printf '  %s\n' "${unowned[@]}"; fi

echo
echo "Packages that mention GPL/AGPL (${#gpl[@]}): ${gpl[*]:-none}"
echo "Packages that mention LGPL     (${#lgpl[@]}): ${lgpl[*]:-none}"
echo
echo "A GPL flag needs a look: see /usr/share/doc/<package>/copyright to tell whether the"
echo "programs in the image are GPL or only the package's build scripts are."
