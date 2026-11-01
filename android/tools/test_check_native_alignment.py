#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for android/tools/check-native-alignment.py.

The point of these tests is not that a happy path prints PASS: it is that a
misaligned (or malformed, or absent) artifact produces a red/skip result. Two
tests build synthetic ELF64 files with a known-bad `p_align` and assert exit
code 1 plus the offending align value in the output. The real cargo artifact is
also checked when it exists; when it does not, unittest reports the real check
as skipped, mirroring the checker's own "skip is not a pass" contract.
"""

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECKER = Path(__file__).resolve().with_name("check-native-alignment.py")
REAL_SO = (
    Path(__file__).resolve().parents[2]
    / "shell/target/aarch64-linux-android/debug/libpdsh_jni.so"
)


def elf64_with_load_alignments(alignments):
    """Build a minimal little-endian AArch64 ELF64 with one PT_LOAD per align."""
    count = len(alignments)
    header_size = 64
    phentsize = 56
    data = bytearray(header_size + phentsize * count)
    data[0:4] = b"\x7fELF"
    data[4] = 2  # ELFCLASS64
    data[5] = 1  # ELFDATA2LSB
    data[6] = 1  # EV_CURRENT
    struct.pack_into("<H", data, 16, 3)  # ET_DYN
    struct.pack_into("<H", data, 18, 183)  # EM_AARCH64
    struct.pack_into("<I", data, 20, 1)  # e_version
    struct.pack_into("<Q", data, 32, header_size)  # e_phoff
    struct.pack_into("<H", data, 52, header_size)  # e_ehsize
    struct.pack_into("<H", data, 54, phentsize)  # e_phentsize
    struct.pack_into("<H", data, 56, count)  # e_phnum
    for index, align in enumerate(alignments):
        base = header_size + phentsize * index
        struct.pack_into("<I", data, base, 1)  # PT_LOAD
        struct.pack_into("<I", data, base + 4, 5)  # PF_R | PF_X
        struct.pack_into("<Q", data, base + 8, index * 0x1000)  # p_offset
        struct.pack_into("<Q", data, base + 16, index * 0x1000)  # p_vaddr
        struct.pack_into("<Q", data, base + 24, index * 0x1000)  # p_paddr
        struct.pack_into("<Q", data, base + 32, 0x1000)  # p_filesz
        struct.pack_into("<Q", data, base + 40, 0x1000)  # p_memsz
        struct.pack_into("<Q", data, base + 48, align)  # p_align
    return bytes(data)


class CheckNativeAlignmentTest(unittest.TestCase):
    def run_checker(self, target):
        return subprocess.run(
            [sys.executable, str(CHECKER), str(target)],
            capture_output=True,
            text=True,
            check=False,
        )

    def write_fixture(self, directory, payload):
        path = Path(directory) / "fixture.so"
        path.write_bytes(payload)
        return path

    def test_one_16k_load_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            target = self.write_fixture(directory, elf64_with_load_alignments([0x4000]))
            result = self.run_checker(target)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[PASS]", result.stdout)

    def test_two_16k_loads_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            target = self.write_fixture(
                directory, elf64_with_load_alignments([0x4000, 0x4000])
            )
            result = self.run_checker(target)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2 PT_LOAD", result.stdout)

    def test_4k_aligned_load_is_red(self):
        """The regression this check exists for: a 4 KB p_align must fail."""
        with tempfile.TemporaryDirectory() as directory:
            target = self.write_fixture(directory, elf64_with_load_alignments([0x1000]))
            result = self.run_checker(target)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[FAIL]", result.stdout)
        self.assertIn("4096", result.stdout)
        self.assertIn("16384", result.stdout)

    def test_one_bad_load_among_good_ones_is_red(self):
        with tempfile.TemporaryDirectory() as directory:
            target = self.write_fixture(
                directory, elf64_with_load_alignments([0x4000, 0x1000, 0x4000])
            )
            result = self.run_checker(target)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("1/3", result.stdout)

    def test_truncated_elf_is_red_not_skip(self):
        with tempfile.TemporaryDirectory() as directory:
            target = self.write_fixture(directory, b"\x7fELF\x02\x01\x01")
            result = self.run_checker(target)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[FAIL]", result.stdout)

    def test_missing_so_is_skip_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "not-built.so"
            result = self.run_checker(missing)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("[SKIP]", result.stdout)
        self.assertIn("NOT a pass", result.stdout)
        self.assertNotIn("[PASS]", result.stdout)

    @unittest.skipUnless(
        REAL_SO.is_file(), "libpdsh_jni.so is not built; skip is not a pass"
    )
    def test_real_cargo_artifact_is_16k_ready(self):
        result = self.run_checker(REAL_SO)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[PASS]", result.stdout)


if __name__ == "__main__":
    unittest.main()
