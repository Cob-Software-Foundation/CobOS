#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Check that no copyleft package ended up in the CobOS root filesystem.

Reads the package database that apk left in the rootfs (lib/apk/db/installed), looks at
the SPDX license expression of every package, and fails if any package could only be used
under a copyleft license (GPL, LGPL, AGPL, MPL, EPL, ...) or under a license this script
does not recognise.

  check-licenses.py ROOTFS [--waivers FILE] [--notice FILE]

How an expression is judged:
  A AND B   both must be acceptable.
  A OR B    one acceptable choice is enough ("FTL OR GPL-2.0-or-later" is fine: use FTL).
  X WITH E  GPL/LGPL code with the GCC Runtime Library Exception is accepted, because that
            exception lets programs using libgcc/libstdc++ keep their own license. The
            library itself is still GPL-3.0, so it is listed as "exception" and its
            license text and source must be shipped with the image (see --notice).

A package that fails can be accepted deliberately by naming it in the waivers file with
a reason, for example when apk gives a subpackage the license of the whole source package.
Waived packages are always listed in the output; nothing is hidden.

This is a check of the package metadata, not legal advice.
"""
import argparse
import os
import re
import sys

# Licenses that impose no copyleft. Compared in lower case.
PERMISSIVE = {
    "mit", "mit-0", "mit-cmu", "mit-open-group", "x11", "xfree86-1.1", "isc", "0bsd",
    "bsd", "bsd-1-clause", "bsd-2-clause", "bsd-3-clause", "bsd-3-clause-clear",
    "bsd-4-clause", "zlib", "libpng", "libpng-2.0", "apache-2.0", "unlicense", "cc0-1.0",
    "curl", "mirOS".lower(), "ftl", "hpnd", "hpnd-sell-variant", "hpnd-uc", "bsl-1.0",
    "bzip2-1.0.6", "ijg", "unicode-3.0", "unicode-dfs-2016", "ntp", "blessing",
    "public-domain", "pd", "bitstream-vera", "icu", "sgi-b-2.0", "python-2.0", "psf-2.0",
    "tcl", "libtiff", "zlib-acknowledgement", "openssl", "boost", "wtfpl", "ofl-1.1-no-rfn",
}

# Licenses that are copyleft (strong or weak), matched anywhere in the identifier.
COPYLEFT = re.compile(
    r"gpl|lgpl|agpl|(^|[^a-z])mpl|(^|[^a-z])epl|cddl|(^|[^a-z])cpl|(^|[^a-z])osl|eupl|"
    r"sspl|cc-by-sa|sleepycat|(^|[^a-z])qpl|ms-rl|cecill|reciprocal"
)

# Exceptions that make GPL-family code usable without copyleft for the code that uses it.
GCC_EXCEPTIONS = {"gcc-exception-3.1", "gcc-exception-3.0", "gcc-exception-2.0", "gcc-exception"}

OK, EXCEPTION, COPYLEFT_V, UNKNOWN = "ok", "exception", "copyleft", "unknown"
_RANK = {OK: 0, EXCEPTION: 1, UNKNOWN: 2, COPYLEFT_V: 3}


def normalise(lic):
    lic = lic.strip().lower()
    for suffix in ("-or-later", "-only", "+"):
        if lic.endswith(suffix):
            lic = lic[: -len(suffix)]
    return lic


def judge_id(lic):
    n = normalise(lic)
    if n in PERMISSIVE or n.startswith(("hpnd", "mit-", "bsd-", "bsd ")):
        return OK
    if COPYLEFT.search(n):
        return COPYLEFT_V
    return UNKNOWN


def tokenize(expr):
    return re.findall(r"\(|\)|[^\s()]+", expr)


def judge(expr):
    """Judge an SPDX expression. Returns OK, EXCEPTION, UNKNOWN or COPYLEFT_V."""
    toks = tokenize(expr)
    pos = 0

    def peek():
        return toks[pos].upper() if pos < len(toks) else None

    def atom():
        nonlocal pos
        if pos >= len(toks):
            return UNKNOWN
        if toks[pos] == "(":
            pos += 1
            v = parse_or()
            if pos < len(toks) and toks[pos] == ")":
                pos += 1
                return v
            return UNKNOWN  # unbalanced parenthesis: do not guess
        lic = toks[pos]
        pos += 1
        v = judge_id(lic)
        if peek() == "WITH":
            pos += 1
            exc = toks[pos].lower() if pos < len(toks) else ""
            pos += 1
            if v == COPYLEFT_V and exc in GCC_EXCEPTIONS:
                return EXCEPTION
        return v

    def parse_and():
        nonlocal pos
        v = atom()
        while peek() == "AND":
            pos += 1
            w = atom()
            v = v if _RANK[v] >= _RANK[w] else w  # the worst of the two
        return v

    def parse_or():
        nonlocal pos
        v = parse_and()
        while peek() == "OR":
            pos += 1
            w = parse_and()
            v = v if _RANK[v] <= _RANK[w] else w  # the best of the two
        return v

    result = parse_or()
    if pos < len(toks) and toks[pos] != ")":
        return UNKNOWN  # trailing text we could not parse
    return result


def read_db(path):
    pkgs = []
    cur = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                if cur:
                    pkgs.append(cur)
                    cur = {}
                continue
            if len(line) > 2 and line[1] == ":":
                cur[line[0]] = line[2:]
    if cur:
        pkgs.append(cur)
    return pkgs


def read_waivers(path):
    waivers = {}
    if not path or not os.path.exists(path):
        return waivers
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, _, reason = line.partition(" ")
            if not reason.strip():
                sys.exit(f"{path}:{n}: waiver for '{name}' needs a reason after the package name")
            waivers[name] = reason.strip()
    return waivers


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("rootfs")
    ap.add_argument("--waivers")
    ap.add_argument("--notice", help="write a third-party license notice to this file")
    args = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)  # keep the table before any error text

    db =os.path.join(args.rootfs, "lib", "apk", "db", "installed")
    if not os.path.isfile(db):
        sys.exit(f"check-licenses.py: {db} not found; was the root filesystem built with apk?")
    pkgs = sorted(read_db(db), key=lambda p: p.get("P", ""))
    waivers = read_waivers(args.waivers)

    rows, bad = [], []
    for p in pkgs:
        name, ver, lic = p.get("P", "?"), p.get("V", "?"), p.get("L", "")
        verdict = judge(lic) if lic else UNKNOWN
        note = ""
        if verdict in (COPYLEFT_V, UNKNOWN) and name in waivers:
            note = "waived: " + waivers[name]
            verdict_shown = "waived"
        else:
            verdict_shown = verdict
            if verdict in (COPYLEFT_V, UNKNOWN):
                bad.append((name, lic or "(no license field)", verdict))
        rows.append((name, ver, lic or "(none)", verdict_shown, note))

    w = max([len(r[0]) for r in rows] + [7])
    print(f"{'PACKAGE':<{w}}  {'VERDICT':<9}  LICENSE")
    for name, ver, lic, verdict, note in rows:
        print(f"{name:<{w}}  {verdict:<9}  {lic}{('  [' + note + ']') if note else ''}")
    counts = {}
    for r in rows:
        counts[r[3]] = counts.get(r[3], 0) + 1
    print("\n" + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())) + f"  ({len(rows)} packages)")

    unused = sorted(set(waivers) - {r[0] for r in rows})
    if unused:
        print("note: waivers for packages that are not in the image: " + ", ".join(unused))

    if args.notice:
        os.makedirs(os.path.dirname(os.path.abspath(args.notice)), exist_ok=True)
        with open(args.notice, "w", encoding="utf-8") as f:
            f.write("Third-party software in this CobOS image\n"
                    "=======================================\n\n"
                    "Package, version, license and upstream URL, from the package database.\n"
                    "Packages marked * are GPL with the GCC Runtime Library Exception;\n"
                    "their source code is available from the project named in the URL.\n"
                    "The Linux kernel (not listed here) is GPL-2.0 with the syscall exception;\n"
                    "its source is the Kernel-Source directory of the CobOS repository.\n\n")
            for p, r in zip(pkgs, rows):
                star = "*" if r[3] == EXCEPTION else " "
                f.write(f"{star} {r[0]} {r[1]}\n    license: {r[2]}\n    url: {p.get('U', '')}\n")
        print(f"wrote {args.notice}")

    if bad:
        print("\nFAILED: these packages are copyleft or have an unrecognised license:", file=sys.stderr)
        for name, lic, verdict in bad:
            print(f"  {name}: {lic}  ({verdict})", file=sys.stderr)
        print("\nFix by removing the package (or the package that depends on it) in os/mkrootfs.sh.\n"
              "If apk only shows the license of the whole source package and the part you ship is\n"
              "permissive, add a line '<package> <reason>' to os/license-waivers.txt.", file=sys.stderr)
        return 1
    print("OK: no copyleft packages (apart from the GCC runtime exception libraries, if listed above).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
