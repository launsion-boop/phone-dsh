#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Machine check that a JNI .so is loadable on Android 15+ 16 KB-page devices.

Android 15 allows 16 KB page sizes, and a shared library whose `PT_LOAD`
segments are aligned to less than 16 KB fails to load there
(`UnsatisfiedLinkError`, "empty/missing DT_HASH/DT_GNU_HASH" or a plain
alignment rejection). The property is invisible on a 4 KB emulator, so it needs
a check that survives a toolchain regression.

This script reads the ELF program headers directly (no readelf/llvm-readelf
dependency) and asserts `p_align >= 16384` for every `PT_LOAD` segment.

Exit codes, deliberately distinct:
  0  PASS  -- the file is ELF, has at least one PT_LOAD, all are aligned.
  1  FAIL  -- the file is unreadable/malformed, or a PT_LOAD is misaligned.
  2  SKIP  -- the target does not exist. This is printed as SKIP with a reason
              and is NOT a pass: a missing build product must never look green.

Usage:
    python3 android/tools/check-native-alignment.py [path/to/lib.so]
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

PAGE_16K = 16384
PT_LOAD = 1
ELF_MAGIC = b"\x7fELF"
DEFAULT_RELATIVE = Path("shell/target/aarch64-linux-android/debug/libpdsh_jni.so")
# android/tools/check-native-alignment.py -> android/tools -> android -> repo root
REPO_ROOT = Path(__file__).resolve().parents[2]


class ElfError(Exception):
    """The bytes are not an ELF file this checker can inspect."""


def parse_load_alignments(data):
    """Return [(program-header-index, p_align)] for every PT_LOAD segment."""
    if len(data) < 16:
        raise ElfError("file is shorter than an ELF identification header")
    if data[:4] != ELF_MAGIC:
        raise ElfError("bad ELF magic (not a shared library)")
    elf_class = data[4]
    encoding = data[5]
    if elf_class not in (1, 2):
        raise ElfError("unknown ELF class {}".format(elf_class))
    if encoding not in (1, 2):
        raise ElfError("unknown ELF data encoding {}".format(encoding))
    endian = "<" if encoding == 1 else ">"

    if elf_class == 2:
        if len(data) < 64:
            raise ElfError("truncated ELF64 header")
        phoff = struct.unpack_from(endian + "Q", data, 32)[0]
        phentsize = struct.unpack_from(endian + "H", data, 54)[0]
        phnum = struct.unpack_from(endian + "H", data, 56)[0]
        min_phentsize = 56
        align_offset = 48
        align_format = endian + "Q"
    else:
        if len(data) < 52:
            raise ElfError("truncated ELF32 header")
        phoff = struct.unpack_from(endian + "I", data, 28)[0]
        phentsize = struct.unpack_from(endian + "H", data, 42)[0]
        phnum = struct.unpack_from(endian + "H", data, 44)[0]
        min_phentsize = 32
        align_offset = 28
        align_format = endian + "I"

    if phnum == 0:
        raise ElfError("ELF has no program headers (not a loadable object?)")
    if phentsize < min_phentsize:
        raise ElfError(
            "e_phentsize {} is smaller than the ELF class minimum {}".format(
                phentsize, min_phentsize
            )
        )
    table_end = phoff + phnum * phentsize
    if phoff == 0 or table_end > len(data):
        raise ElfError(
            "program header table ({} entries at {}, {} bytes) runs past EOF {}".format(
                phnum, phoff, phentsize * phnum, len(data)
            )
        )

    loads = []
    for index in range(phnum):
        base = phoff + index * phentsize
        p_type = struct.unpack_from(endian + "I", data, base)[0]
        if p_type != PT_LOAD:
            continue
        p_align = struct.unpack_from(align_format, data, base + align_offset)[0]
        loads.append((index, p_align))
    if not loads:
        raise ElfError("ELF has zero PT_LOAD segments")
    return loads


def display_path(path):
    try:
        return str(path.resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(path)


def check(target):
    """Run the check; return the process exit code."""
    if not target.is_file():
        print("[SKIP] check-native-alignment: target not found: {}".format(target.resolve()))
        print(
            "[SKIP] reason: build it with `cd shell && cargo ndk -t arm64-v8a build -p pdsh-jni`; "
            "the alignment check did NOT run and is NOT a pass."
        )
        return 2

    try:
        data = target.read_bytes()
        loads = parse_load_alignments(data)
    except (OSError, ElfError, struct.error) as exc:
        print("[FAIL] check-native-alignment: {}: {}".format(display_path(target), exc))
        return 1

    bad = [(index, align) for index, align in loads if align < PAGE_16K]
    for index, align in loads:
        verdict = "OK" if align >= PAGE_16K else "MISALIGNED (need >= {})".format(PAGE_16K)
        print(
            "  LOAD[{}] p_align=0x{:x} ({} bytes) {}".format(index, align, align, verdict)
        )

    if bad:
        print(
            "[FAIL] check-native-alignment: {}: {}/{} PT_LOAD segment(s) below 16384; "
            "Android 15+ 16 KB devices will reject this .so".format(
                display_path(target), len(bad), len(loads)
            )
        )
        return 1

    smallest = min(align for _, align in loads)
    print(
        "[PASS] check-native-alignment: {}: {} PT_LOAD segment(s), min p_align=0x{:x} ({}) "
        "is 16 KB-page ready".format(display_path(target), len(loads), smallest, smallest)
    )
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Assert every PT_LOAD segment of an Android JNI .so has p_align >= 16384 "
            "(16 KB page). Exit codes: 0 pass, 1 fail, 2 skip (file absent)."
        )
    )
    parser.add_argument(
        "target",
        nargs="?",
        default=None,
        help="ELF shared library to inspect (default: {})".format(DEFAULT_RELATIVE),
    )
    args = parser.parse_args(argv)
    target = Path(args.target) if args.target else REPO_ROOT / DEFAULT_RELATIVE
    return check(target)


if __name__ == "__main__":
    sys.exit(main())
