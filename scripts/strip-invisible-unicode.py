#!/usr/bin/env python3
"""Deterministic invisible/exotic-Unicode hygiene scrubber.

Strips zero-width, bidi-control, variation-selector and Unicode "tag"
characters (a known steganographic carrier — invisible text can be hidden
byte-for-byte in the U+E0000-U+E007F tag block), and normalizes exotic space
characters to a plain U+0020. No model calls, no network, stdlib only.

Rationale for existing regardless of any specific vendor's watermarking:
invisible Unicode in source/docs is independently a security concern
(Trojan-Source-class attacks hide behind bidi overrides; tag-block text
hides arbitrary payloads). This is content hygiene, not a targeted
detection-evasion tool for any one mechanism.

Usage:
  strip-invisible-unicode.py --check FILE...      # report only, exit 1 if any found
  strip-invisible-unicode.py FILE...              # clean in place
  strip-invisible-unicode.py -o OUT FILE           # clean single file to OUT (stdout if OUT is '-')
"""
import argparse
import sys
import unicodedata

# Characters removed outright (zero-width, bidi control, variation
# selectors, deprecated formatting, the Unicode "tag" block).
STRIP_RANGES = [
    (0x200B, 0x200F),  # ZWSP, ZWNJ, ZWJ, LRM, RLM
    (0x202A, 0x202E),  # LRE, RLE, PDF, LRO, RLO
    (0x2060, 0x2064),  # word joiner, invisible +/=/x, invisible separator
    (0x2066, 0x2069),  # LRI, RLI, FSI, PDI
    (0xFE00, 0xFE0F),  # variation selectors 1-16
    (0xE0100, 0xE01EF),  # variation selectors 17-256
    (0xE0000, 0xE007F),  # tag block — steganographic payload carrier
]
STRIP_SINGLE = {0x00AD, 0x180E, 0xFEFF}  # soft hyphen, Mongolian vowel separator, ZWNBSP/BOM (mid-text)

# Exotic space characters normalized to a plain space rather than deleted,
# so word boundaries survive.
SPACE_CHARS = {
    0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
    0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000,
}


def _stripped(cp):
    if cp in STRIP_SINGLE:
        return True
    for lo, hi in STRIP_RANGES:
        if lo <= cp <= hi:
            return True
    return False


def clean(text):
    out = []
    removed = 0
    normalized = 0
    for i, ch in enumerate(text):
        cp = ord(ch)
        if cp == 0xFEFF and i == 0:
            out.append(ch)  # leave a genuine leading BOM alone
            continue
        if _stripped(cp):
            removed += 1
            continue
        if cp in SPACE_CHARS:
            out.append(" ")
            normalized += 1
            continue
        out.append(ch)
    return "".join(out), removed, normalized


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--check", action="store_true", help="report only, don't modify; exit 1 if anything found")
    ap.add_argument("-o", "--output", help="write single-file result here ('-' for stdout) instead of in place")
    args = ap.parse_args()

    if args.output and len(args.files) != 1:
        ap.error("-o/--output only valid with a single input file")

    any_found = False
    for path in args.files:
        try:
            with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
                text = f.read()
        except OSError as e:
            print(f"strip-invisible-unicode: {path}: {e}", file=sys.stderr)
            sys.exit(2)

        cleaned, removed, normalized = clean(text)
        if removed or normalized:
            any_found = True
            print(f"{path}: {removed} invisible/tag char(s) removed, {normalized} exotic space(s) normalized")

        if args.check:
            continue

        if args.output:
            if args.output == "-":
                sys.stdout.write(cleaned)
            else:
                with open(args.output, "w", encoding="utf-8") as f:
                    f.write(cleaned)
        elif cleaned != text:
            with open(path, "w", encoding="utf-8") as f:
                f.write(cleaned)

    if args.check and any_found:
        sys.exit(1)


if __name__ == "__main__":
    main()
