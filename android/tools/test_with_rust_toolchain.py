#!/usr/bin/env python3
"""Focused tests for isolated Rust bootstrap resolution and checksum failure."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WRAPPER = ROOT / "android/tools/with-rust-toolchain.sh"


def executable(path: Path, body: str) -> None:
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(0o755)


class RustToolchainWrapperTest(unittest.TestCase):
    def test_check_reuses_adequate_caller_toolchain_without_install(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            executable(bin_dir / "rustc", "echo 'rustc 1.99.1 (fixture)'\n")
            executable(bin_dir / "cargo", "echo 'cargo 1.99.1 (fixture)'\n")
            env = {
                **os.environ,
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "HOME": str(root / "home"),
                "XDG_CACHE_HOME": str(root / "cache"),
            }
            result = subprocess.run(
                ["bash", str(WRAPPER), "--check"], env=env, text=True,
                capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Rust toolchain OK", result.stdout)
            self.assertFalse((root / "cache/pdsh/rustup").exists())

    def test_check_fails_closed_when_rust_is_missing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            env = {
                **os.environ,
                "PATH": "/usr/bin:/bin",
                "HOME": str(root / "home"),
                "XDG_CACHE_HOME": str(root / "cache"),
            }
            result = subprocess.run(
                ["bash", str(WRAPPER), "--check"], env=env, text=True,
                capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("run android/tools/with-rust-toolchain.sh --install", result.stderr)
            self.assertFalse((root / "cache/pdsh/rustup").exists())

    def test_install_rejects_unverified_manifest_fixture_before_execution(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            executable(bin_dir / "curl", 'while [ "$1" != "--output" ]; do shift; done; shift; printf fixture > "$1"\n')
            env = {
                **os.environ,
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "HOME": str(root / "home"),
                "XDG_CACHE_HOME": str(root / "cache"),
                "TMPDIR": str(root),
            }
            result = subprocess.run(
                ["bash", str(WRAPPER), "--install"], env=env, text=True,
                capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("channel manifest checksum mismatch", result.stderr)
            self.assertFalse((root / "cache/pdsh/rustup/toolchains").exists())


if __name__ == "__main__":
    unittest.main()
