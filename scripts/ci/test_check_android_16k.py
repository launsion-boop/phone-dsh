#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for scripts/ci/check-android-16k.py.

Each test builds a self-contained fixture APK (or bare .so) in a temporary
directory, mutates exactly one property the gate protects, and asserts the exit
code. No Gradle, NDK, network or SDK is used: the point is that the gate is
proven to go red without needing a build, so the proof runs on the smallest host.

The fixtures are hand-written because the three properties under test -- zip
compression method, the absolute offset of a member's first data byte, and the
ELF program headers -- are exactly the ones a normal zip writer does not let you
control.
"""

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

CHECKER = Path(__file__).resolve().with_name("check-android-16k.py")
PAGE_16K = 16384
JNI_MEMBER = "lib/arm64-v8a/libpdsh_jni.so"
ANDROIDX_MEMBER = "lib/arm64-v8a/libandroidx.graphics.path.so"


def elf64(p_align, payload=b"\x00" * 16):
    """A minimal little-endian ELF64 shared object with one PT_LOAD segment."""
    ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\x00" * 8
    ehdr = struct.pack(
        "<16sHHIQQQIHHHHHH",
        ident,
        3,  # ET_DYN
        183,  # EM_AARCH64
        1,  # e_version
        0,  # e_entry
        64,  # e_phoff
        0,  # e_shoff
        0,  # e_flags
        64,  # e_ehsize
        56,  # e_phentsize
        1,  # e_phnum
        64,  # e_shentsize
        0,  # e_shnum
        0,  # e_shstrndx
    )
    phdr = struct.pack(
        "<IIQQQQQQ",
        1,  # PT_LOAD
        5,  # R+X
        0,  # p_offset
        0,  # p_vaddr
        0,  # p_paddr
        len(payload),  # p_filesz
        len(payload),  # p_memsz
        p_align,  # p_align
    )
    return ehdr + phdr + payload


def zip_bytes(entries):
    """Build a zip; entries are (name, data, compress, align).

    `align` pads the local file header with a dummy extra field so the member's
    first data byte lands on that boundary (None leaves the writer's offset).
    Returns (bytes, {name: data_offset}).
    """
    out = bytearray()
    central = []
    offsets = {}
    for name, data, compress, align in entries:
        name_b = name.encode("utf-8")
        if compress:
            compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
            body = compressor.compress(data) + compressor.flush()
            method = 8
        else:
            body = data
            method = 0
        crc = zlib.crc32(data) & 0xFFFFFFFF
        base = len(out) + 30 + len(name_b)
        pad = 0
        if align:
            pad = (-base) % align
            # A zip extra field is a 4-byte header plus its payload, so a pad of
            # 1..3 bytes is impossible; round up to the next boundary.
            if 0 < pad < 4:
                pad += align
        extra = b""
        if pad:
            extra = struct.pack("<HH", 0x0000, pad - 4) + b"\x00" * (pad - 4)
        offset = len(out)
        out += struct.pack(
            "<IHHHHHIIIHH",
            0x04034B50,  # local file header signature
            20,  # version needed
            0,  # flags
            method,
            0,  # time
            0,  # date
            crc,
            len(body),  # compressed size
            len(data),  # uncompressed size
            len(name_b),
            len(extra),
        )
        out += name_b + extra + body
        offsets[name] = offset + 30 + len(name_b) + len(extra)
        central.append((name_b, method, crc, len(body), len(data), offset))

    cd_offset = len(out)
    for name_b, method, crc, csize, usize, offset in central:
        out += struct.pack(
            "<IHHHHHHIIIHHHHHII",
            0x02014B50,  # central directory signature
            20,  # version made by
            20,  # version needed
            0,  # flags
            method,
            0,  # time
            0,  # date
            crc,
            csize,
            usize,
            len(name_b),
            0,  # extra length
            0,  # comment length
            0,  # disk number
            0,  # internal attributes
            0,  # external attributes
            offset,
        )
        out += name_b
    cd_size = len(out) - cd_offset
    out += struct.pack(
        "<IHHHHIIH",
        0x06054B50,  # end of central directory signature
        0,  # disk number
        0,  # central directory disk
        len(central),  # entries on this disk
        len(central),  # entries total
        cd_size,
        cd_offset,
        0,  # comment length
    )
    return bytes(out), offsets


def run_checker(*args):
    return subprocess.run(
        [sys.executable, str(CHECKER), *args],
        capture_output=True,
        text=True,
    )


class CheckAndroid16kTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.apk_dir = self.root / "android/app/build/outputs/apk/debug"
        self.apk_dir.mkdir(parents=True)

    def write_apk(self, entries, name="app-debug.apk"):
        data, offsets = zip_bytes(entries)
        path = self.apk_dir / name
        path.write_bytes(data)
        return path, offsets

    def write_manifest(self, extracted):
        path = self.root / "android/app/src/main/AndroidManifest.xml"
        path.parent.mkdir(parents=True, exist_ok=True)
        value = "true" if extracted else "false"
        path.write_text(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
            f'<application android:extractNativeLibs="{value}" />'
            "</manifest>",
            encoding="utf-8",
        )

    def assert_rc(self, result, expected):
        self.assertEqual(
            result.returncode,
            expected,
            "expected rc {}, got {}\nstdout:\n{}\nstderr:\n{}".format(
                expected, result.returncode, result.stdout, result.stderr
            ),
        )

    # ---------------------------------------------------------------- green path
    def test_aligned_stored_member_passes(self):
        _, offsets = self.write_apk([(JNI_MEMBER, elf64(PAGE_16K), False, PAGE_16K)])
        self.assertEqual(offsets[JNI_MEMBER] % PAGE_16K, 0)
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 0)
        self.assertIn("[PASS]", result.stdout)

    def test_extra_aligned_members_are_checked_and_pass(self):
        self.write_apk(
            [
                (JNI_MEMBER, elf64(PAGE_16K), False, PAGE_16K),
                (ANDROIDX_MEMBER, elf64(PAGE_16K), False, PAGE_16K),
            ]
        )
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 0)

    # ------------------------------------------------- 16 KB ELF alignment (red)
    def test_four_kb_elf_fails(self):
        self.write_apk([(JNI_MEMBER, elf64(4096), False, PAGE_16K)])
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 1)
        self.assertIn("p_align=0x1000", result.stdout)
        self.assertIn("[FAIL]", result.stdout)

    def test_second_member_misaligned_fails(self):
        # A gate that only inspects the first .so member would pass this one.
        self.write_apk(
            [
                (JNI_MEMBER, elf64(PAGE_16K), False, PAGE_16K),
                (ANDROIDX_MEMBER, elf64(4096), False, PAGE_16K),
            ]
        )
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 1)
        self.assertIn(ANDROIDX_MEMBER, result.stdout)

    # ----------------------------------------------------- zip compression (red)
    def test_deflated_member_fails(self):
        self.write_apk([(JNI_MEMBER, elf64(PAGE_16K), True, None)])
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 1)
        self.assertIn("compressed", result.stdout)

    # ----------------------------------------------------- zip alignment (red)
    def test_misaligned_zip_offset_fails(self):
        _, offsets = self.write_apk([(JNI_MEMBER, elf64(PAGE_16K), False, 4096)])
        self.assertNotEqual(offsets[JNI_MEMBER] % PAGE_16K, 0)
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 1)
        self.assertIn("not 16 KB aligned", result.stdout)

    # ------------------------------------------------------------- other failures
    def test_missing_jni_member_fails(self):
        self.write_apk([(ANDROIDX_MEMBER, elf64(PAGE_16K), False, PAGE_16K)])
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 1)
        self.assertIn("required member {} is missing".format(JNI_MEMBER), result.stdout)

    def test_truncated_elf_fails(self):
        self.write_apk([(JNI_MEMBER, b"\x7fELF" + b"\x00" * 40, False, PAGE_16K)])
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 1)

    def test_not_a_zip_fails(self):
        (self.apk_dir / "app-debug.apk").write_bytes(b"this is not a zip")
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 1)

    def test_explicit_missing_apk_fails_not_skips(self):
        result = run_checker("--root", str(self.root), "--apk", str(self.root / "nope.apk"))
        self.assert_rc(result, 1)
        self.assertIn("does not exist", result.stdout)

    # ------------------------------------------------------------------ skip path
    def test_no_apk_skips_and_is_not_a_pass(self):
        empty = self.root / "empty"
        empty.mkdir()
        result = run_checker("--root", str(empty))
        self.assert_rc(result, 2)
        self.assertIn("[SKIP]", result.stdout)
        self.assertIn("NOT a pass", result.stdout)

    # ------------------------------------------------------- extracted mode
    def test_extracted_manifest_skips_zip_rules_but_checks_the_elf(self):
        # extractNativeLibs=true means PackageManager materializes the .so, so a
        # compressed or misaligned zip entry is not the bytes the loader maps.
        self.write_manifest(True)
        self.write_apk([(JNI_MEMBER, elf64(PAGE_16K), True, 4096)])
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 0)
        self.assertIn("extracted mode", result.stdout)

    def test_extracted_manifest_still_rejects_a_4k_elf(self):
        self.write_manifest(True)
        self.write_apk([(JNI_MEMBER, elf64(4096), True, 4096)])
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 1)
        self.assertIn("p_align=0x1000", result.stdout)

    def test_extracted_manifest_false_keeps_the_packaged_rules(self):
        self.write_manifest(False)
        self.write_apk([(JNI_MEMBER, elf64(PAGE_16K), True, 4096)])
        result = run_checker("--root", str(self.root))
        self.assert_rc(result, 1)
        self.assertIn("compressed", result.stdout)

    def test_explicit_extracted_flag_works_without_a_manifest(self):
        self.write_apk([(JNI_MEMBER, elf64(PAGE_16K), True, 4096)])
        result = run_checker("--root", str(self.root), "--extracted")
        self.assert_rc(result, 0)

    def test_no_extracted_flag_overrides_a_true_manifest(self):
        self.write_manifest(True)
        self.write_apk([(JNI_MEMBER, elf64(PAGE_16K), True, 4096)])
        result = run_checker("--root", str(self.root), "--no-extracted")
        self.assert_rc(result, 1)
        self.assertIn("compressed", result.stdout)

    # ------------------------------------------------------------ bare .so mode
    def test_bare_so_mode_passes_and_fails(self):
        good = self.root / "good.so"
        good.write_bytes(elf64(PAGE_16K))
        result = run_checker("--root", str(self.root), "--so", str(good))
        self.assert_rc(result, 0)

        bad = self.root / "bad.so"
        bad.write_bytes(elf64(4096))
        result = run_checker("--root", str(self.root), "--so", str(bad))
        self.assert_rc(result, 1)
        self.assertIn("p_align=0x1000", result.stdout)


if __name__ == "__main__":
    unittest.main()
