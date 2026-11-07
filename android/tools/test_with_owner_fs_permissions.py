#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Tests for the root-container permission adapter used by the isolated JVM stage.

The adapter is not product policy: it only makes UID 0 behave like the ordinary
owner the phone/Mac actually runs as. These tests pin both the ordinary proof and
the capset fallback for containers whose seccomp policy refuses
``PR_CAPBSET_DROP`` (the case observed in this Fleet worker).
"""
from __future__ import annotations

import ctypes
import errno
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().with_name("with-owner-fs-permissions.py")
DAC_BITS = (1 << 1) | (1 << 2)  # CAP_DAC_OVERRIDE, CAP_DAC_READ_SEARCH


def root_linux_with_dac() -> bool:
    if not sys.platform.startswith("linux") or os.geteuid() != 0:
        return False
    try:
        status = dict(
            line.split(":", 1)
            for line in Path("/proc/self/status").read_text().splitlines()
            if ":" in line
        )
        effective = int(status["CapEff"].strip(), 16)
    except (KeyError, OSError, ValueError):
        return False
    return bool(effective & DAC_BITS)


def child_write_code() -> str:
    return textwrap.dedent(
        """
        import os
        if os.environ.get("REPORT_OWNER_CAPS") == "1":
            status = dict(line.split(":", 1) for line in open("/proc/self/status") if ":" in line)
            print("NO_NEW_PRIVS=" + status["NoNewPrivs"].strip())
            print("CAP_EFF=" + status["CapEff"].strip())
            print("CAP_PRM=" + status["CapPrm"].strip())
        try:
            with open(os.path.join(os.environ["RO_DIR"], "must-not-write"), "wb") as handle:
                handle.write(b"fixture")
        except PermissionError:
            print("WRITE_DENIED")
        else:
            print("WRITE_SUCCEEDED")
        print("COMMAND_RAN")
        """
    )


class CapsetFallbackTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("owner_fs", SCRIPT)
        cls.owner_fs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.owner_fs)

    def test_capability_mask_only_removes_dac_bits_from_their_word(self):
        # Use every Linux capability set shape. Bits 33/34 occupy bits 1/2 of
        # word 1 and must not be cleared by word 0's CAP_DAC mask.
        caps = DAC_BITS | (1 << 33) | (1 << 34) | (1 << 40)
        for set_name in ("CapEff", "CapPrm", "CapInh"):
            with self.subTest(capability_set=set_name):
                low = self.owner_fs._capability_word_without_dac(caps, 0)
                high = self.owner_fs._capability_word_without_dac(caps, 1)
                self.assertEqual(0, low & DAC_BITS)
                self.assertEqual((1 << 1) | (1 << 2) | (1 << 8), high)

    def test_capset_stub_receives_preserved_upper_bits_in_all_sets(self):
        # Capture the actual capset payload, not just the mask helper: upper
        # word bits 1/2 are capabilities 33/34 and must survive in E/P/I. Also
        # require no_new_privs set+verified before capset and fail closed.
        captured = {}

        class FakeFunction:
            argtypes = None
            restype = None

            def __init__(self, callback):
                self.callback = callback

            def __call__(self, *args):
                return self.callback(*args)

        class FakeLibrary:
            def __init__(self, owner_fs, no_new_privs_observed=1):
                self.owner_fs = owner_fs
                self.no_new_privs_observed = no_new_privs_observed
                self.calls = []
                self.prctl = FakeFunction(self.handle_prctl)
                self.capset = FakeFunction(self.capture)

            def handle_prctl(self, option, *_arguments):
                self.calls.append(("prctl", option))
                if option == self.owner_fs._PR_SET_NO_NEW_PRIVS:
                    return 0
                if option == self.owner_fs._PR_GET_NO_NEW_PRIVS:
                    return self.no_new_privs_observed
                raise AssertionError(f"unexpected prctl option: {option}")

            def capture(self, _header, words):
                self.calls.append(("capset",))
                captured["words"] = [
                    (words[index].effective, words[index].permitted, words[index].inheritable)
                    for index in range(2)
                ]
                return 0

        sample = DAC_BITS | (1 << 33) | (1 << 34) | (1 << 40)
        fake = FakeLibrary(self.owner_fs)
        with (
            mock.patch.object(self.owner_fs, "_capabilities", return_value={
                "CapEff": sample,
                "CapPrm": sample,
                "CapInh": sample,
            }),
            mock.patch.object(self.owner_fs.ctypes, "CDLL", return_value=fake),
        ):
            self.owner_fs._drop_dac_with_capset()

        self.assertEqual(
            [
                (0, 0, 0),
                ((1 << 1) | (1 << 2) | (1 << 8),) * 3,
            ],
            captured["words"],
        )
        self.assertEqual(
            [
                ("prctl", self.owner_fs._PR_SET_NO_NEW_PRIVS),
                ("prctl", self.owner_fs._PR_GET_NO_NEW_PRIVS),
                ("capset",),
            ],
            fake.calls,
        )

        # A fallback whose verified no_new_privs is absent or unreadable must
        # fail closed without attempting capset at all.
        for observed, expected_error in ((0, RuntimeError), (-1, OSError)):
            with self.subTest(no_new_privs_observed=observed):
                if observed < 0:
                    ctypes.set_errno(errno.EPERM)
                failing = FakeLibrary(self.owner_fs, no_new_privs_observed=observed)
                with (
                    mock.patch.object(self.owner_fs, "_capabilities", return_value={
                        "CapEff": sample,
                        "CapPrm": sample,
                        "CapInh": sample,
                    }),
                    mock.patch.object(self.owner_fs.ctypes, "CDLL", return_value=failing),
                ):
                    with self.assertRaises(expected_error):
                        self.owner_fs._drop_dac_with_capset()
                self.assertEqual(
                    [
                        ("prctl", self.owner_fs._PR_SET_NO_NEW_PRIVS),
                        ("prctl", self.owner_fs._PR_GET_NO_NEW_PRIVS),
                    ],
                    failing.calls,
                )

    def test_no_new_privs_is_set_and_verified_before_fallback_exec(self):
        calls = []

        def prctl(option, *arguments):
            calls.append((option, arguments))
            if option == self.owner_fs._PR_SET_NO_NEW_PRIVS:
                return 0
            if option == self.owner_fs._PR_GET_NO_NEW_PRIVS:
                return 1
            self.fail(f"unexpected prctl option: {option}")

        self.owner_fs._establish_no_new_privs(prctl)
        self.assertEqual(
            [
                (self.owner_fs._PR_SET_NO_NEW_PRIVS, (1, 0, 0, 0)),
                (self.owner_fs._PR_GET_NO_NEW_PRIVS, (0, 0, 0, 0)),
            ],
            calls,
        )

    def test_no_new_privs_prctl_errors_fail_closed(self):
        ctypes.set_errno(errno.EPERM)
        with self.assertRaises(OSError):
            self.owner_fs._establish_no_new_privs(lambda _option, *_args: -1)

        def not_set(option, *_args):
            return 0 if option == self.owner_fs._PR_SET_NO_NEW_PRIVS else 0

        with self.assertRaises(RuntimeError):
            self.owner_fs._establish_no_new_privs(not_set)

    def test_wrapper_passes_through_a_normal_owner_writable_command(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-owner-pass-through-") as temporary:
            owner_writable = Path(temporary) / "owner-writable"
            owner_writable.mkdir(mode=0o700)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), sys.executable, "-c", child_write_code()],
                env={**os.environ, "RO_DIR": str(owner_writable)},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("WRITE_SUCCEEDED", result.stdout)
            self.assertTrue((owner_writable / "must-not-write").exists())

    def test_direct_verify_fails_closed_for_root_but_passes_for_owner(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-owner-verify-direct-") as temporary:
            read_only = Path(temporary) / "read-only"
            read_only.mkdir(mode=0o500)
            try:
                result = subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPT),
                        "--verify-owner-permissions",
                        sys.executable,
                        "-c",
                        "print('COMMAND_RAN')",
                    ],
                    env={**os.environ, "RO_DIR": str(read_only)},
                    text=True,
                    capture_output=True,
                    check=False,
                )
                if root_linux_with_dac():
                    self.assertEqual(2, result.returncode, result.stderr)
                    self.assertIn("still bypasses read-only owner permissions", result.stderr)
                    self.assertNotIn("COMMAND_RAN", result.stdout)
                else:
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertIn("verified ordinary owner write denial", result.stderr)
                    self.assertIn("COMMAND_RAN", result.stdout)
            finally:
                read_only.chmod(0o700)

    def test_normal_wrapper_proves_denial_and_runs_the_verified_child(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-owner-wrapper-proof-") as temporary:
            read_only = Path(temporary) / "read-only"
            read_only.mkdir(mode=0o500)
            try:
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), sys.executable, "-c", child_write_code()],
                    env={
                        **os.environ,
                        "RO_DIR": str(read_only),
                        **({"REPORT_OWNER_CAPS": "1"} if root_linux_with_dac() else {}),
                    },
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn("WRITE_DENIED", result.stdout)
                self.assertNotIn("WRITE_SUCCEEDED", result.stdout)
                self.assertIn("COMMAND_RAN", result.stdout)
                if sys.platform.startswith("linux") and os.geteuid() == 0 and root_linux_with_dac():
                    self.assertIn("verified ordinary owner write denial", result.stderr)
                    reported = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
                    self.assertEqual(0, int(reported["CAP_EFF"], 16) & DAC_BITS)
                    self.assertEqual(0, int(reported["CAP_PRM"], 16) & DAC_BITS)
            finally:
                read_only.chmod(0o700)

    def test_capset_clears_dac_capabilities_and_survives_exec(self):
        if not root_linux_with_dac():
            raise unittest.SkipTest("needs Linux UID 0 with a DAC capability to drop")
        with tempfile.TemporaryDirectory(prefix="pdsh-capset-test-") as temporary:
            read_only = Path(temporary) / "read-only"
            read_only.mkdir(mode=0o500)
            try:
                code = textwrap.dedent(
                    f"""
                    import importlib.util, os, sys
                    spec = importlib.util.spec_from_file_location("owner_fs", {str(SCRIPT)!r})
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                    module._drop_dac_with_capset()
                    os.execv(sys.executable, [sys.executable, "-c", {child_write_code()!r}])
                    """
                )
                result = subprocess.run(
                    [sys.executable, "-c", code],
                    env={**os.environ, "RO_DIR": str(read_only), "REPORT_OWNER_CAPS": "1"},
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                reported = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
                self.assertEqual("1", reported.get("NO_NEW_PRIVS"))
                self.assertEqual(0, int(reported["CAP_EFF"], 16) & DAC_BITS)
                self.assertEqual(0, int(reported["CAP_PRM"], 16) & DAC_BITS)
                self.assertIn("WRITE_DENIED", result.stdout)
                self.assertNotIn("WRITE_SUCCEEDED", result.stdout)
            finally:
                read_only.chmod(0o700)

    def test_adapter_proves_write_denial_end_to_end(self):
        if not sys.platform.startswith("linux") or os.geteuid() != 0:
            raise unittest.SkipTest("the adapter's demotion branch is Linux UID 0 only")
        with tempfile.TemporaryDirectory(prefix="pdsh-owner-fs-test-") as temporary:
            read_only = Path(temporary) / "read-only"
            read_only.mkdir(mode=0o500)
            try:
                result = subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPT),
                        sys.executable,
                        "-c",
                        child_write_code(),
                    ],
                    env={**os.environ, "RO_DIR": str(read_only)},
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(
                    "verified ordinary owner write denial",
                    result.stderr,
                )
                self.assertIn("WRITE_DENIED", result.stdout)
                self.assertNotIn("WRITE_SUCCEEDED", result.stdout)
            finally:
                read_only.chmod(0o700)


if __name__ == "__main__":
    unittest.main()
