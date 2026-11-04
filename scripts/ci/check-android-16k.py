#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""16 KB page-alignment gate for the .so that actually ships.

`android/tools/check-native-alignment.py` proves the *cargo* artifact is 16 KB
aligned. That is necessary but not sufficient: the APK never contains that file.
`android/app/build.gradle.kts` copies it through `PackagePdshJni`, runs
`llvm-strip` on the copy, and AGP stores the copy in the APK zip. Three things
can regress between the cargo output and the device, and none of them is visible
to a check that only reads `shell/target/`:

  1. the strip step (a different `llvm-strip`, or a flag added to it) can rewrite
     the program headers of the copy;
  2. a *compressed* zip entry cannot be mapped from the APK, so the loader falls
     back to extracting it and the ELF's own alignment is no longer what the
     loader maps;
  3. the member's local-file-header offset inside the APK must be 16 KB aligned
     for the uncompressed mapping to land on a page boundary (`zipalign -P 16`).

This gate opens the APK, reads every `lib/**/*.so` local file header, and parses
the ELF program headers of the member bytes. A bare `.so` can be checked with
`--so` (the post-strip copies under `android/app/build/generated/jniLibs/`).

The ELF parse is not duplicated here: `android/tools/check-native-alignment.py`
owns it, so the two gates cannot drift into disagreeing about what "aligned"
means.

Exit codes, deliberately distinct:
  0  PASS -- every inspected `.so` has every PT_LOAD `p_align >= 16384`, and in
             the non-extracted mode it is also STORED and 16 KB aligned in the
             zip.
  1  FAIL -- one of those properties is wrong, or the target is malformed.
  2  SKIP -- no APK (and no `--so`) was found. Printed as SKIP with the build
             command; a missing build product is never a pass.

Extracted mode: `:app` declares `android:extractNativeLibs="true"` because the
Termux proot binaries and the Rust JNI library are executed from
`nativeLibraryDir`. PackageManager then extracts every `lib/**` member to app
data, so the zip entry's compression and data offset no longer describe the
file the loader maps; the ELF's own PT_LOAD alignment is the property that
matters. The gate auto-detects that declaration from the source manifest (or
`--extracted` forces it) and still checks every ELF, the required member, and
the malformed-archive paths. It never skips the ELF proof.

Usage:
    python3 scripts/ci/check-android-16k.py
    python3 scripts/ci/check-android-16k.py --apk android/app/build/outputs/apk/release/app-release-unsigned.apk
    python3 scripts/ci/check-android-16k.py --so android/app/build/generated/jniLibs/packageDebugPdshJni/arm64-v8a/libpdsh_jni.so
    python3 scripts/ci/check-android-16k.py --extracted --apk <apk>
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import struct
import sys
import zipfile
from pathlib import Path

PAGE_16K = 16384
LOCAL_HEADER_SIG = 0x04034B50
LOCAL_HEADER_LEN = 30

# The JNI library is the only member that must be present: androidx also ships
# `libandroidx.graphics.path.so`, which this gate checks when it appears but does
# not require.
DEFAULT_REQUIRED = ("lib/arm64-v8a/libpdsh_jni.so",)

APK_GLOBS = (
    "android/app/build/outputs/apk/debug/*.apk",
    "android/app/build/outputs/apk/release/*.apk",
)

REPO_ROOT = Path(__file__).resolve().parents[2]
ELF_PARSER = REPO_ROOT / "android/tools/check-native-alignment.py"
SOURCE_MANIFEST = Path("android/app/src/main/AndroidManifest.xml")
EXTRACT_NATIVE_RE = re.compile(r'android:extractNativeLibs\s*=\s*["\']true["\']')


class GateError(Exception):
    """A target could not be inspected at all (truncated / not a zip)."""


def load_elf_parser(path=None):
    """Import `check-native-alignment.py` (a dash in the name blocks `import`)."""
    path = Path(path) if path else ELF_PARSER
    if not path.is_file():
        raise GateError(
            "missing ELF parser: {}: run this from a full checkout".format(path)
        )
    spec = importlib.util.spec_from_file_location("pdsh_check_native_alignment", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def is_so_member(name):
    """A packaged shared library: `lib/<abi>/<name>.so`."""
    return name.startswith("lib/") and name.endswith(".so")


def local_data_offset(handle, info):
    """Return the absolute offset of a zip member's first data byte."""
    handle.seek(info.header_offset)
    header = handle.read(LOCAL_HEADER_LEN)
    if len(header) < LOCAL_HEADER_LEN:
        raise GateError(
            "truncated local file header for {} at {:#x}".format(
                info.filename, info.header_offset
            )
        )
    (signature,) = struct.unpack_from("<I", header, 0)
    if signature != LOCAL_HEADER_SIG:
        raise GateError(
            "bad local file header signature {:#010x} for {} at {:#x}".format(
                signature, info.filename, info.header_offset
            )
        )
    name_len, extra_len = struct.unpack_from("<HH", header, 26)
    return info.header_offset + LOCAL_HEADER_LEN + name_len + extra_len


def check_elf_bytes(parser, data, label):
    """Return (problems, load_alignments) for one ELF image."""
    try:
        loads = parser.parse_load_alignments(data)
    except (parser.ElfError, struct.error) as exc:
        return ["{}: {}".format(label, exc)], []
    problems = []
    aligns = []
    for index, align in loads:
        aligns.append(align)
        if align < PAGE_16K:
            problems.append(
                "{}: LOAD[{}] p_align=0x{:x} is below 0x{:x}; Android 15+ 16 KB-page "
                "devices reject this .so".format(label, index, align, PAGE_16K)
            )
    return problems, aligns


def check_so(path, parser):
    """Check a bare `.so` (post-strip copy); return (problems, alignments)."""
    if not path.is_file():
        return ["{}: target does not exist".format(path)], []
    try:
        data = path.read_bytes()
    except OSError as exc:
        return ["{}: {}".format(path, exc)], []
    return check_elf_bytes(parser, data, str(path))


def check_apk(path, parser, required, extracted=False):
    """Check every `lib/**/*.so` of an APK; return (problems, alignments)."""
    if not path.is_file():
        return ["{}: target does not exist".format(path)], []
    problems = []
    aligns = []
    seen = set()
    try:
        with zipfile.ZipFile(path) as archive, open(path, "rb") as raw:
            members = [info for info in archive.infolist() if is_so_member(info.filename)]
            if not members:
                return [
                    "{}: contains no lib/**/*.so member; the JNI library was not "
                    "packaged".format(path)
                ], []
            for info in members:
                seen.add(info.filename)
                label = "{}!{}".format(path, info.filename)
                if not extracted:
                    if info.compress_type != zipfile.ZIP_STORED:
                        problems.append(
                            "{}: zip entry is compressed (method {}); an uncompressed "
                            "entry is required so the loader maps the ELF instead of "
                            "extracting it".format(label, info.compress_type)
                        )
                    try:
                        offset = local_data_offset(raw, info)
                    except GateError as exc:
                        problems.append(str(exc))
                        continue
                    if offset % PAGE_16K:
                        problems.append(
                            "{}: zip data offset {:#x} is not 16 KB aligned "
                            "({} bytes past the previous 16 KB boundary); run "
                            "`zipalign -P 16` or stop compressing the member".format(
                                label, offset, offset % PAGE_16K
                            )
                        )
                sub_problems, sub_aligns = check_elf_bytes(parser, archive.read(info), label)
                problems.extend(sub_problems)
                aligns.extend(sub_aligns)
    except (OSError, zipfile.BadZipFile) as exc:
        return ["{}: {}".format(path, exc)], []
    for member in required:
        if member not in seen:
            problems.append("{}: required member {} is missing".format(path, member))
    return problems, aligns


def detect_extracted(root):
    """Read the app's extractNativeLibs declaration from its source manifest."""
    manifest = Path(root) / SOURCE_MANIFEST
    try:
        text = manifest.read_text(encoding="utf-8")
    except OSError:
        return False
    return bool(EXTRACT_NATIVE_RE.search(text))


def discover_apks(root):
    """Every APK the debug/release builds left behind, newest name last."""
    found = []
    for pattern in APK_GLOBS:
        found.extend(sorted(root.glob(pattern)))
    return [path for path in found if path.is_file()]


def display(path, root):
    try:
        return str(path.resolve().relative_to(root))
    except ValueError:
        return str(path)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Assert that every packaged lib/**/*.so is STORED, 16 KB aligned in "
            "the APK zip and 16 KB aligned in its PT_LOAD segments. Exit codes: "
            "0 pass, 1 fail, 2 skip (no APK)."
        )
    )
    parser.add_argument("--root", default=None, help="repository root (default: this checkout)")
    parser.add_argument("--apk", action="append", default=None, help="APK to inspect (repeatable)")
    parser.add_argument("--so", action="append", default=None, help="bare .so to inspect (repeatable)")
    parser.add_argument(
        "--extracted",
        action="store_true",
        default=None,
        help="force extracted mode: skip zip compression/offset checks, keep the ELF checks",
    )
    parser.add_argument(
        "--no-extracted",
        action="store_false",
        dest="extracted",
        default=None,
        help="force packaged mode even if the manifest declares extractNativeLibs=true",
    )
    parser.add_argument(
        "--require",
        action="append",
        default=None,
        help="zip member that must be present (default: {})".format(DEFAULT_REQUIRED[0]),
    )
    args = parser.parse_args(argv)

    root = Path(args.root).resolve() if args.root else REPO_ROOT
    required = tuple(args.require) if args.require else DEFAULT_REQUIRED

    if args.apk or args.so:
        apks = [Path(path) for path in (args.apk or [])]
        sos = [Path(path) for path in (args.so or [])]
    else:
        apks = discover_apks(root)
        sos = []

    if not apks and not sos:
        print(
            "[SKIP] check-android-16k: no APK under android/app/build/outputs/apk/ "
            "and no --so target in {}".format(root)
        )
        print(
            "[SKIP] reason: build one with `cd android && ./gradlew :app:assembleDebug`; "
            "the packaged-alignment check did NOT run and is NOT a pass."
        )
        return 2

    try:
        elf_parser = load_elf_parser()
    except (GateError, ImportError, OSError) as exc:
        print("[FAIL] check-android-16k: {}".format(exc))
        return 1

    extracted = args.extracted if args.extracted is not None else detect_extracted(root)
    if extracted:
        print(
            "[i] check-android-16k: extracted mode (extractNativeLibs=true); "
            "zip compression/offset are not execution properties, ELF PT_LOAD "
            "alignment is still checked"
        )
    targets = [("apk", path) for path in apks] + [("so", path) for path in sos]
    failed = 0
    alignments = []
    for kind, path in targets:
        if kind == "apk":
            problems, aligns = check_apk(path, elf_parser, required, extracted=extracted)
        else:
            problems, aligns = check_so(path, elf_parser)
        alignments.extend(aligns)
        label = display(path, root)
        if problems:
            failed += 1
            for problem in problems:
                print("[FAIL] check-android-16k: {}".format(problem))
        else:
            smallest = min(aligns) if aligns else 0
            print(
                "[ok] {}: {} PT_LOAD segment(s), min p_align=0x{:x}".format(
                    label, len(aligns), smallest
                )
            )

    if failed:
        print(
            "[FAIL] check-android-16k: {}/{} target(s) are not 16 KB-page ready; "
            "a 16 KB-page device would reject the packaged .so".format(failed, len(targets))
        )
        return 1

    smallest = min(alignments) if alignments else 0
    print(
        "[PASS] check-android-16k: {} target(s), {} PT_LOAD segment(s), "
        "min p_align=0x{:x}; every inspected .so is 16 KB aligned in the ELF{}".format(
            len(targets),
            len(alignments),
            smallest,
            " (extracted mode: zip compression/offset not asserted)" if extracted else
            " and STORED/16 KB aligned in the zip",
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
