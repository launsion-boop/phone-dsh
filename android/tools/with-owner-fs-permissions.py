#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run filesystem tests with ordinary owner permissions in root Fleet containers.

The phone and the Mac owner run unprivileged. Fleet's UID 0 otherwise bypasses
chmod and changes the meaning of the existing read-only-directory tests. Reduce
only this process tree's DAC bypass capabilities; never change test assertions,
file ownership, the container image, or a shared service.
"""
from __future__ import annotations

import ctypes
import os
from pathlib import Path
import sys
import tempfile


_VERIFY = "--verify-owner-permissions"

_LINUX_CAPABILITY_VERSION_3 = 0x20080522
_PR_CAPBSET_DROP = 24
_PR_SET_NO_NEW_PRIVS = 38
_PR_GET_NO_NEW_PRIVS = 39
_CAP_DAC_OVERRIDE = 1
_CAP_DAC_READ_SEARCH = 2
_DAC_CAPABILITIES = (_CAP_DAC_OVERRIDE, _CAP_DAC_READ_SEARCH)
_CAPABILITY_WORD_BITS = 32


class _CapHeader(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]


class _CapData(ctypes.Structure):
    _fields_ = [
        ("effective", ctypes.c_uint32),
        ("permitted", ctypes.c_uint32),
        ("inheritable", ctypes.c_uint32),
    ]


def _capabilities() -> dict[str, int]:
    status = dict(
        line.split(":", 1)
        for line in Path("/proc/self/status").read_text().splitlines()
        if ":" in line
    )
    return {
        name: int(status[name].strip(), 16)
        for name in ("CapInh", "CapPrm", "CapEff", "CapBnd")
    }


def _capability_word_without_dac(value: int, word_index: int) -> int:
    """Return one 32-bit capset word, clearing only DAC bits in their word."""
    if word_index not in (0, 1):
        raise ValueError(f"Linux capability word index must be 0 or 1, was {word_index}")
    shift = _CAPABILITY_WORD_BITS * word_index
    word = (value >> shift) & 0xFFFFFFFF
    for capability in _DAC_CAPABILITIES:
        local_bit = capability - shift
        if 0 <= local_bit < _CAPABILITY_WORD_BITS:
            word &= ~(1 << local_bit)
    return word


def _establish_no_new_privs(prctl) -> None:
    """Set and verify no_new_privs before the fallback exec."""
    if prctl(_PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        number = ctypes.get_errno()
        raise OSError(number, "cannot set no_new_privs for owner-permission fallback")
    observed = prctl(_PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0)
    if observed < 0:
        number = ctypes.get_errno()
        raise OSError(number, "cannot verify no_new_privs for owner-permission fallback")
    if observed != 1:
        raise RuntimeError("no_new_privs did not remain set for owner-permission fallback")


def _drop_dac_with_capset() -> None:
    """Clear the two DAC capabilities from this process's own capability sets.

    Some container seccomp policies deny ``PR_CAPBSET_DROP`` even for UID 0.
    ``capset`` still lets a process remove capabilities it already holds, and
    with verified ``no_new_privs`` the cleared sets survive the exec below. Only the two
    DAC bits are removed; every unrelated capability (chown, signals, ...) is
    preserved so this stays a test-environment adapter, not a policy rewrite.
    """
    capabilities = _capabilities()
    header = _CapHeader(_LINUX_CAPABILITY_VERSION_3, 0)
    data = (_CapData * 2)()
    library = ctypes.CDLL(None, use_errno=True)
    library.prctl.argtypes = [ctypes.c_int] + [ctypes.c_ulong] * 4
    library.prctl.restype = ctypes.c_int
    _establish_no_new_privs(library.prctl)
    for index in range(2):
        data[index].effective = _capability_word_without_dac(capabilities["CapEff"], index)
        data[index].permitted = _capability_word_without_dac(capabilities["CapPrm"], index)
        data[index].inheritable = _capability_word_without_dac(capabilities["CapInh"], index)
    library.capset.argtypes = [ctypes.POINTER(_CapHeader), ctypes.POINTER(_CapData)]
    library.capset.restype = ctypes.c_int
    if library.capset(ctypes.byref(header), data) != 0:
        number = ctypes.get_errno()
        raise OSError(
            number,
            "cannot reduce this test process's DAC capabilities with capset",
        )


def verify_owner_permissions() -> None:
    with tempfile.TemporaryDirectory(prefix="pdsh-owner-permissions-") as temporary:
        directory = Path(temporary) / "read-only"
        directory.mkdir(mode=0o500)
        try:
            try:
                (directory / "must-not-write").write_bytes(b"fixture")
            except PermissionError:
                return
            raise RuntimeError("test process still bypasses read-only owner permissions")
        finally:
            directory.chmod(0o700)


def main(arguments: list[str]) -> int:
    if not arguments:
        print("usage: with-owner-fs-permissions.py <command> [args...]", file=sys.stderr)
        return 2
    verify = arguments[0] == _VERIFY
    if verify:
        arguments = arguments[1:]
        if not arguments:
            return 2
        verify_owner_permissions()
        print("test permissions: verified ordinary owner write denial", file=sys.stderr)
    elif sys.platform.startswith("linux") and os.geteuid() == 0:
        # PR_CAPBSET_DROP removes a capability only from this process and its
        # descendants. Exec once so UID 0 cannot regain DAC capabilities from
        # its bounding set; all existing task-owned 0700 caches remain readable.
        library = ctypes.CDLL(None, use_errno=True)
        library.prctl.argtypes = [ctypes.c_int] + [ctypes.c_ulong] * 4
        library.prctl.restype = ctypes.c_int
        bounding = _capabilities()["CapBnd"]
        bounding_failure: OSError | None = None
        for capability in _DAC_CAPABILITIES:
            # Some hardened workers already dropped all capabilities. They need
            # no privileged operation; the exec+write-denial proof is still run.
            if bounding & (1 << capability) == 0:
                continue
            if library.prctl(_PR_CAPBSET_DROP, capability, 0, 0, 0) != 0:
                number = ctypes.get_errno()
                bounding_failure = OSError(
                    number,
                    "cannot drop CAP_DAC_* from this test process's bounding set",
                )
                break
        if bounding_failure is not None:
            # Seccomp may block PR_CAPBSET_DROP while still allowing a process to
            # drop its own effective/permitted/inheritable bits. If capset also
            # fails, or the exec'd write-denial proof fails, exit 2: the proof is
            # never skipped and production filesystem policy is untouched.
            try:
                _drop_dac_with_capset()
            except OSError as capset_failure:
                raise OSError(
                    capset_failure.errno,
                    f"{bounding_failure}; capset fallback failed: {capset_failure}",
                ) from capset_failure
        os.execv(sys.executable, [sys.executable, __file__, _VERIFY, *arguments])
    os.execvp(arguments[0], arguments)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, RuntimeError) as error:
        print(f"test permissions: {error}", file=sys.stderr)
        raise SystemExit(2)
