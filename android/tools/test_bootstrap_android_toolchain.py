#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Tests for android/tools/bootstrap-android-toolchain.sh.

The tests execute the real shell script. Network access is replaced by a fake
`curl` serving local fixture archives, and the extracted command-line-tools
fixture carries a fake `sdkmanager`. Every path is a temporary directory, so no
test writes a real JDK, SDK or Gradle distribution outside its own scratch tree.

Covered: HOME/XDG default resolution, explicit overrides, --check output and its
no-install guarantee, local.properties generation and key preservation,
idempotency, installer stdout visibility, checksum rejection, partial-download
cleanup and exit-code propagation for download/licence/package failures. A
java-11/javac-17 mix is rejected rather than accepted as "JDK 17".
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().with_name("bootstrap-android-toolchain.sh")
GRADLE_SHA256 = "20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78"
GRADLE_WRAPPER_URL = "https://downloads.gradle.org/distributions/gradle-8.13-bin.zip"


def wrapper_cache_hash(url: str) -> str:
    value = int.from_bytes(hashlib.md5(url.encode("utf-8")).digest(), "big")
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    while value:
        value, remainder = divmod(value, 36)
        out = digits[remainder] + out
    return out or "0"

FAKE_CURL = r"""#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:-/dev/null}"
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;;
    --fail|--location|--retry-all-errors) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ -n "${FAKE_CURL_MARKER:-}" ]; then
  echo "$FAKE_CURL_MARKER"
fi
if [ -n "${FAKE_CURL_FAIL_URL_CONTAINS:-}" ]; then
  case "$url" in
    *"$FAKE_CURL_FAIL_URL_CONTAINS"*)
      echo "fake curl: forced failure for $url" >&2
      exit 22
      ;;
  esac
fi
if [ -n "${FAKE_CURL_PARTIAL_EXIT:-}" ]; then
  [ -n "$out" ] || exit 2
  printf 'partial' > "$out"
  echo "fake curl: forced partial failure" >&2
  exit "$FAKE_CURL_PARTIAL_EXIT"
fi
if [ -n "${FAKE_CURL_EXIT:-}" ]; then
  echo "fake curl: forced download failure" >&2
  exit "$FAKE_CURL_EXIT"
fi
[ -n "$out" ] || { echo "fake curl: no --output" >&2; exit 2; }
case "$url" in
  *jdk*|*eclipse*) cp "${FAKE_JDK_ARCHIVE:?}" "$out" ;;
  *cmdline*|*commandline*) cp "${FAKE_SDK_ARCHIVE:?}" "$out" ;;
  *gradle*) cp "${FAKE_GRADLE_ARCHIVE:?}" "$out" ;;
  *) echo "fake curl: unexpected URL $url" >&2; exit 3 ;;
esac
"""

FAKE_SDKMANAGER = r"""#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FAKE_SDKMANAGER_LOG:-/dev/null}"
sdk_root=""
for arg in "$@"; do
  case "$arg" in
    --sdk_root=*) sdk_root="${arg#*=}" ;;
  esac
done
[ -n "$sdk_root" ] || { echo "fake sdkmanager: no --sdk_root" >&2; exit 2; }
echo "${FAKE_SDKMANAGER_MARKER:-fake sdkmanager output}"
args=" $* "
case "$args" in
  *" --licenses "*)
    IFS= read -r _ || true
    if [ -n "${FAKE_SDKMANAGER_LICENSE_EXIT:-}" ]; then
      echo "fake sdkmanager: forced licence failure" >&2
      exit "$FAKE_SDKMANAGER_LICENSE_EXIT"
    fi
    echo "All SDK package licenses accepted."
    exit 0
    ;;
  *" --list_installed "*)
    if [ -n "${FAKE_SDKMANAGER_LIST_OVERRIDE:-}" ]; then
      printf '%s' "$FAKE_SDKMANAGER_LIST_OVERRIDE"
      printf '%s' "${FAKE_SDKMANAGER_LIST_STDERR:-}" >&2
      exit "${FAKE_SDKMANAGER_LIST_EXIT:-0}"
    fi
    echo "Installed packages:"
    [ -d "$sdk_root/platform-tools" ] && echo "  platform-tools | 35.0.1 | Android SDK Platform-Tools"
    if [ "${FAKE_SDKMANAGER_LIST_FORMAT:-legacy}" = slash ]; then
      [ -d "$sdk_root/platforms/android-35" ] && echo "  platforms/android-35  2.0.0  Android SDK Platform 35"
      [ -d "$sdk_root/build-tools/35.0.0" ] && echo "  build-tools/35.0.0  35.0.0  Android SDK Build-Tools 35"
    else
      [ -d "$sdk_root/platforms/android-35" ] && echo "  platforms;android-35 | 2 | Android SDK Platform 35"
      [ -d "$sdk_root/build-tools/35.0.0" ] && echo "  build-tools;35.0.0 | 35.0.0 | Android SDK Build-Tools 35"
    fi
    exit 0
    ;;
esac
if [ -n "${FAKE_SDKMANAGER_INSTALL_EXIT:-}" ]; then
  echo "fake sdkmanager: forced package failure" >&2
  exit "$FAKE_SDKMANAGER_INSTALL_EXIT"
fi
for arg in "$@"; do
  case "$arg" in
    platform-tools)
      mkdir -p "$sdk_root/platform-tools"
      : > "$sdk_root/platform-tools/adb"
      chmod +x "$sdk_root/platform-tools/adb"
      ;;
    'platforms;android-35')
      mkdir -p "$sdk_root/platforms/android-35"
      : > "$sdk_root/platforms/android-35/android.jar"
      ;;
    'build-tools;35.0.0')
      mkdir -p "$sdk_root/build-tools/35.0.0"
      : > "$sdk_root/build-tools/35.0.0/aapt2"
      ;;
  esac
done
exit 0
"""

FAKE_JAVA = """#!/usr/bin/env bash
echo 'openjdk version "17.0.13" 2024-10-15' >&2
echo 'OpenJDK Runtime Environment Temurin-17.0.13+11 (build 17.0.13+11)' >&2
"""

FAKE_JAVAC = """#!/usr/bin/env bash
echo 'javac 17.0.13'
"""

FAKE_JAVA_11 = """#!/usr/bin/env bash
echo 'openjdk version "11.0.24" 2024-07-16' >&2
echo 'OpenJDK Runtime Environment (build 11.0.24+8)' >&2
"""


def _tar_member(archive: tarfile.TarFile, name: str, data: bytes, executable: bool = False):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mtime = 0
    info.mode = 0o755 if executable else 0o644
    archive.addfile(info, io.BytesIO(data))


def write_jdk_archive(path: Path):
    with tarfile.open(path, "w:gz") as archive:
        _tar_member(archive, "jdk-17.0.13+11/bin/java", FAKE_JAVA.encode(), executable=True)
        _tar_member(archive, "jdk-17.0.13+11/bin/javac", FAKE_JAVAC.encode(), executable=True)
        _tar_member(archive, "jdk-17.0.13+11/release", b'JAVA_VERSION="17.0.13"\n')


def write_sdk_archive(path: Path):
    info = zipfile.ZipInfo("cmdline-tools/bin/sdkmanager")
    info.external_attr = 0o755 << 16
    info.create_system = 3
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(info, FAKE_SDKMANAGER.encode())


def write_gradle_archive(path: Path):
    launcher = zipfile.ZipInfo("gradle-8.13/bin/gradle")
    launcher.external_attr = 0o755 << 16
    launcher.create_system = 3
    jar = zipfile.ZipInfo("gradle-8.13/lib/gradle-launcher-8.13.jar")
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(launcher, "fake gradle launcher\n")
        archive.writestr(jar, "fake launcher jar\n")


def write_jdk_home(home: Path, java_text: str = FAKE_JAVA, javac_text: str = FAKE_JAVAC):
    (home / "bin").mkdir(parents=True)
    for name, text in (("java", java_text), ("javac", javac_text)):
        target = home / "bin" / name
        target.write_text(text, encoding="utf-8")
        target.chmod(0o755)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sha1(path: Path) -> str:
    return hashlib.sha1(path.read_bytes()).hexdigest()


class BootstrapToolchainTests(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory()
        self.root = Path(self._temp.name)
        self.toolchain = self.root / "toolchain"
        self.repo = self.root / "repo"
        self.local_properties = self.repo / "android" / "local.properties"
        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        self.curl_log = self.root / "curl.log"
        self.sdkmanager_log = self.root / "sdkmanager.log"
        self.jdk_archive = self.root / "jdk17.tar.gz"
        self.sdk_archive = self.root / "cmdline-tools.zip"
        self.gradle_archive = self.root / "gradle-8.13-bin.zip"
        write_jdk_archive(self.jdk_archive)
        write_sdk_archive(self.sdk_archive)
        write_gradle_archive(self.gradle_archive)
        self.curl = self.fake_bin / "fake-curl"
        self.curl.write_text(FAKE_CURL, encoding="utf-8")
        self.curl.chmod(0o755)
        self._write_wrapper(self.repo)

    def tearDown(self):
        self._temp.cleanup()

    def _write_wrapper(self, checkout: Path, pinned: bool = True):
        wrapper = checkout / "android" / "gradle" / "wrapper" / "gradle-wrapper.properties"
        wrapper.parent.mkdir(parents=True, exist_ok=True)
        url = (
            "https\\://downloads.gradle.org/distributions/gradle-8.13-bin.zip"
            if pinned
            else "https\\://services.gradle.org/distributions/gradle-8.13-bin.zip"
        )
        sha = GRADLE_SHA256 if pinned else ""
        wrapper.write_text(
            "distributionBase=GRADLE_USER_HOME\n"
            "distributionPath=wrapper/dists\n"
            "distributionUrl={}\n".format(url)
            + ("distributionSha256Sum={}\n".format(sha) if sha else "")
            + "zipStoreBase=GRADLE_USER_HOME\n"
            "zipStorePath=wrapper/dists\n",
            encoding="utf-8",
        )

    def environment(self, **overrides):
        env = os.environ.copy()
        for key in (
            "PDSH_TOOLCHAIN_DIR",
            "PDSH_JAVA_HOME",
            "JAVA_HOME",
            "ANDROID_HOME",
            "PDSH_LOCAL_PROPERTIES",
            "PDSH_CURL",
            "PDSH_JDK_URL",
            "PDSH_JDK_SHA256",
            "PDSH_CMDLINE_TOOLS_URL",
            "PDSH_CMDLINE_TOOLS_SHA1",
            "PDSH_GRADLE_URL",
            "PDSH_GRADLE_SHA256",
            "PDSH_GRADLE_FALLBACK_URLS",
            "PDSH_GRADLE_PRIMARY_TIMEOUT",
            "GRADLE_USER_HOME",
            "PDSH_GRADLE_USER_HOME",
            "PDSH_CONNECT_TIMEOUT",
            "PDSH_DOWNLOAD_TIMEOUT",
            "FAKE_CURL_EXIT",
            "FAKE_CURL_PARTIAL_EXIT",
            "FAKE_CURL_MARKER",
            "FAKE_CURL_FAIL_URL_CONTAINS",
            "FAKE_CURL_LOG",
            "FAKE_JDK_ARCHIVE",
            "FAKE_SDK_ARCHIVE",
            "FAKE_GRADLE_ARCHIVE",
            "FAKE_SDKMANAGER_LOG",
            "FAKE_SDKMANAGER_MARKER",
            "FAKE_SDKMANAGER_LICENSE_EXIT",
            "FAKE_SDKMANAGER_INSTALL_EXIT",
            "FAKE_SDKMANAGER_LIST_FORMAT",
            "FAKE_SDKMANAGER_LIST_OVERRIDE",
            "FAKE_SDKMANAGER_LIST_EXIT",
            "FAKE_SDKMANAGER_LIST_STDERR",
        ):
            env.pop(key, None)
        env.update(
            {
                "HOME": str(self.root / "home"),
                "XDG_CACHE_HOME": str(self.root / "cache"),
                "PDSH_TOOLCHAIN_DIR": str(self.toolchain),
                "PDSH_LOCAL_PROPERTIES": str(self.local_properties),
                "PDSH_CURL": str(self.curl),
                "PDSH_JDK_URL": "https://fake.invalid/jdk17.tar.gz",
                "PDSH_JDK_SHA256": sha256(self.jdk_archive),
                "PDSH_CMDLINE_TOOLS_URL": "https://fake.invalid/cmdline-tools.zip",
                "PDSH_CMDLINE_TOOLS_SHA1": sha1(self.sdk_archive),
                "PDSH_GRADLE_URL": "https://fake.invalid/gradle-8.13-bin.zip",
                "PDSH_GRADLE_SHA256": sha256(self.gradle_archive),
                "FAKE_CURL_LOG": str(self.curl_log),
                "FAKE_JDK_ARCHIVE": str(self.jdk_archive),
                "FAKE_SDK_ARCHIVE": str(self.sdk_archive),
                "FAKE_GRADLE_ARCHIVE": str(self.gradle_archive),
                "FAKE_SDKMANAGER_LOG": str(self.sdkmanager_log),
            }
        )
        env.update(overrides)
        return env

    def run_script(self, *args, script=SCRIPT, **overrides):
        return subprocess.run(
            ["bash", str(script), *args],
            cwd=str(self.root),
            env=self.environment(**overrides),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False,
        )

    def combined(self, proc):
        return proc.stdout + proc.stderr

    def copy_script_to(self, checkout: Path, pinned_wrapper: bool = True):
        tools = checkout / "android" / "tools"
        tools.mkdir(parents=True, exist_ok=True)
        copied = tools / SCRIPT.name
        shutil.copy2(SCRIPT, copied)
        self._write_wrapper(checkout, pinned=pinned_wrapper)
        return copied

    def test_default_root_uses_xdg_cache_when_set(self):
        checkout = self.root / "checkout"
        copied = self.copy_script_to(checkout)
        env = self.environment()
        env.pop("PDSH_TOOLCHAIN_DIR")
        env.pop("PDSH_LOCAL_PROPERTIES")
        env["XDG_CACHE_HOME"] = str(self.root / "xdg-cache")
        env["HOME"] = str(self.root / "home")
        proc = subprocess.run(
            ["bash", str(copied), "--check"],
            cwd=str(self.root),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False,
        )
        output = self.combined(proc)
        self.assertNotEqual(proc.returncode, 0, output)
        root = self.root / "xdg-cache" / "pdsh" / "android"
        self.assertIn("PDSH_TOOLCHAIN_DIR={}".format(root), output)
        self.assertIn("ANDROID_HOME={}".format(root / "android-sdk"), output)
        self.assertIn("LOCAL_PROPERTIES={}".format(checkout / "android" / "local.properties"), output)
        self.assertFalse(root.exists(), "check mode must not create the install root")

    def test_default_root_uses_home_when_xdg_is_unset(self):
        checkout = self.root / "checkout2"
        copied = self.copy_script_to(checkout)
        env = self.environment()
        env.pop("PDSH_TOOLCHAIN_DIR")
        env.pop("PDSH_LOCAL_PROPERTIES")
        env.pop("XDG_CACHE_HOME", None)
        home = self.root / "home2"
        env["HOME"] = str(home)
        proc = subprocess.run(
            ["bash", str(copied), "--check"],
            cwd=str(self.root),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False,
        )
        output = self.combined(proc)
        self.assertNotEqual(proc.returncode, 0, output)
        root = home / "toolchains" / "pdsh-android"
        self.assertIn("PDSH_TOOLCHAIN_DIR={}".format(root), output)
        self.assertIn("ANDROID_HOME={}".format(root / "android-sdk"), output)

    def test_check_reports_missing_toolchain_without_installing(self):
        proc = self.run_script("--check")
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 1, output)
        self.assertIn("JAVA_HOME={}".format(self.toolchain / "jdk-17"), output)
        self.assertIn("JAVA=MISSING_OR_MISMATCHED", output)
        self.assertIn("SDKMANAGER=MISSING", output)
        self.assertIn("MODE=check", output)
        self.assertFalse(self.toolchain.exists(), "check mode must not create the toolchain")
        self.assertFalse(self.local_properties.exists(), "check mode must not write local.properties")
        self.assertFalse(self.curl_log.exists(), "check mode must not download")

    def test_check_rejects_unpinned_wrapper(self):
        checkout = self.root / "unpinned"
        copied = self.copy_script_to(checkout, pinned_wrapper=False)
        proc = self.run_script("--check", script=copied)
        output = self.combined(proc)
        self.assertNotEqual(proc.returncode, 0, output)
        self.assertIn("Gradle wrapper is not pinned to Gradle 8.13", output)
        self.assertIn("Gradle wrapper SHA-256 is not the pinned value", output)

    def test_install_is_idempotent_and_writes_local_properties(self):
        first = self.run_script()
        output = self.combined(first)
        self.assertEqual(first.returncode, 0, output)
        self.assertTrue((self.toolchain / "jdk-17" / "bin" / "javac").is_file())
        self.assertTrue((self.toolchain / "android-sdk" / "platforms" / "android-35").is_dir())
        self.assertTrue((self.toolchain / "android-sdk" / "build-tools" / "35.0.0").is_dir())
        self.assertTrue((self.toolchain / "android-sdk" / "platform-tools" / "adb").is_file())
        self.assertTrue((self.toolchain / "downloads" / "gradle-8.13-bin.zip").is_file())
        self.assertIn(
            "sdk.dir={}".format(self.toolchain / "android-sdk"),
            self.local_properties.read_text(encoding="utf-8"),
        )
        downloads = self.curl_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(downloads), 3, downloads)
        self.assertTrue(any("jdk17.tar.gz" in line for line in downloads), downloads)
        self.assertTrue(any("cmdline-tools.zip" in line for line in downloads), downloads)
        self.assertTrue(any("gradle-8.13-bin.zip" in line for line in downloads), downloads)
        for line in downloads:
            self.assertIn("--connect-timeout", line)
            self.assertIn("--max-time", line)

        second = self.run_script()
        output = self.combined(second)
        self.assertEqual(second.returncode, 0, output)
        self.assertIn("JDK 17 already present", output)
        self.assertIn("command-line tools already present", output)
        self.assertIn("reusing verified download", output)
        self.assertEqual(
            len(self.curl_log.read_text(encoding="utf-8").splitlines()),
            3,
            "an idempotent second run must not download again",
        )

    def test_installer_stdout_is_visible(self):
        proc = self.run_script(FAKE_CURL_MARKER="fake-curl talking", FAKE_SDKMANAGER_MARKER="fake-sdkmanager talking")
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 0, output)
        self.assertIn("fake-curl talking", output)
        self.assertIn("fake-sdkmanager talking", output)
        self.assertIn("All SDK package licenses accepted.", output)

    def test_check_after_install_prints_versions_and_packages(self):
        install = self.run_script()
        self.assertEqual(install.returncode, 0, self.combined(install))
        proc = self.run_script("--check")
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 0, output)
        self.assertIn('JAVA=openjdk version "17.0.13"', output)
        self.assertIn("JAVAC=javac 17.0.13", output)
        self.assertIn("PACKAGE platforms;android-35=installed", output)
        self.assertIn("PACKAGE build-tools;35.0.0=installed", output)
        self.assertIn("PACKAGE platform-tools=installed", output)
        self.assertIn("GRADLE_WRAPPER=gradle-8.13", output)
        self.assertIn("GRADLE_DIST_STATE=verified", output)
        self.assertIn("LOCAL_PROPERTIES_SDK={}".format(self.toolchain / "android-sdk"), output)
        self.assertIn("toolchain check passed", output)
        self.assertNotIn("fake-curl", output)

    def test_check_recognizes_current_sdkmanager_slash_package_rows(self):
        install = self.run_script()
        self.assertEqual(install.returncode, 0, self.combined(install))
        proc = self.run_script("--check", FAKE_SDKMANAGER_LIST_FORMAT="slash")
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 0, output)
        self.assertIn("PACKAGE platforms;android-35=installed", output)
        self.assertIn("PACKAGE build-tools;35.0.0=installed", output)
        self.assertIn("PACKAGE platform-tools=installed", output)

    def test_check_rejects_wrong_and_non_row_package_names(self):
        install = self.run_script()
        self.assertEqual(install.returncode, 0, self.combined(install))
        listing = "\n".join([
            "Installed packages:",
            "  platform-tools-extra 35.0.1 Other platform tools",
            "  platforms/android-350 2.0.0 Other platform",
            "  build-tools/135.0.0 135.0.0 Other build tools",
            "warning: platform-tools platforms;android-35 build-tools;35.0.0",
        ])
        proc = self.run_script("--check", FAKE_SDKMANAGER_LIST_OVERRIDE=listing)
        output = self.combined(proc)
        self.assertNotEqual(proc.returncode, 0, output)
        for package in ("platform-tools", "platforms;android-35", "build-tools;35.0.0"):
            self.assertIn("PACKAGE {}=MISSING".format(package), output)
        self.assertNotIn("directory-missing", output)

    def test_shared_sdk_listing_vectors_drive_real_adapter(self):
        install = self.run_script()
        self.assertEqual(install.returncode, 0, self.combined(install))
        fixture = SCRIPT.parents[2] / "spec/toolchain/v1/golden/sdk-manager-listing.jsonl"
        rows = [json.loads(line) for line in fixture.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(len(rows), 28)
        required = ("platform-tools", "platforms;android-35", "build-tools;35.0.0")
        for row in rows:
            with self.subTest(case=row["name"]):
                overrides = dict(FAKE_SDKMANAGER_LIST_OVERRIDE=row["listing"],
                                 FAKE_SDKMANAGER_LIST_EXIT=str(row["exit_code"]),
                                 FAKE_SDKMANAGER_LIST_STDERR=row["stderr"])
                fake_tee = self.fake_bin / "tee"
                capture_tmp = self.root / "capture-tmp"
                capture_tmp.mkdir(exist_ok=True)
                overrides["TMPDIR"] = str(capture_tmp)
                if row["capture_exit"] or row["capture_diverge"]:
                    real_tee = shutil.which("tee")
                    self.assertIsNotNone(real_tee, "tee is required by the adapter")
                    tee_command = shlex.quote(real_tee)
                    fake_tee.write_text(
                        "#!/bin/sh\n"
                        "if [ \"$FAKE_TEE_DIVERGE\" = 1 ]; then\n"
                        "  if mkdir \"$FAKE_TEE_MARKER\" 2>/dev/null; then\n"
                        "    cat > \"$FAKE_TEE_FULL\"; cat \"$FAKE_TEE_FULL\"\n"
                        "    printf '%s' \"$FAKE_TEE_PREFIX\" > \"$1\"; exit 0\n"
                        "  fi\n"
                        "  exec " + tee_command + " \"$@\"\n"
                        "fi\n"
                        "cat >/dev/null\nprintf '%s' \"$FAKE_TEE_PREFIX\" | " + tee_command + " \"$@\"\nexit \"$FAKE_TEE_EXIT\"\n",
                        encoding="utf-8")
                    fake_tee.chmod(0o755)
                    overrides.update(PATH=str(self.fake_bin) + os.pathsep + os.environ.get("PATH", ""),
                                     FAKE_TEE_PREFIX=row["capture_prefix"],
                                     FAKE_TEE_EXIT=str(row["capture_exit"]),
                                     FAKE_TEE_DIVERGE="1" if row["capture_diverge"] else "0",
                                     FAKE_TEE_MARKER=str(self.root / "tee-marker"),
                                     FAKE_TEE_FULL=str(self.root / "tee-full"))
                try:
                    proc = self.run_script("--check", **overrides)
                finally:
                    fake_tee.unlink(missing_ok=True)
                self.assertEqual(list(capture_tmp.glob("pdsh-sdkmanager-*")), [], row["name"])
                output = self.combined(proc)
                if row["stderr"]:
                    self.assertIn(row["stderr"], output)
                self.assertEqual(proc.returncode == 0,
                                 row["exit_code"] == 0 and row["capture_exit"] == 0 and not row["capture_diverge"] and len(row["installed"]) == 3,
                                 output)
                if row["capture_exit"]:
                    self.assertIn("sdkmanager output capture failed", output)
                if row["capture_diverge"]:
                    self.assertIn("sdkmanager output captures differ", output)
                for name in required:
                    if row["exit_code"] != 0 or row["capture_exit"] != 0 or row["capture_diverge"]:
                        self.assertNotIn("PACKAGE {}=installed".format(name), output)
                    else:
                        expected = "installed" if name in row["installed"] else "MISSING"
                        self.assertIn("PACKAGE {}={}".format(name, expected), output.splitlines())

    def test_each_capture_rejects_failure_and_silent_divergence(self):
        install = self.run_script()
        self.assertEqual(install.returncode, 0, self.combined(install))
        real_tee = shutil.which("tee")
        self.assertIsNotNone(real_tee, "tee is required by the adapter")
        tee_command = shlex.quote(real_tee)
        prefix = ("Installed packages:\nplatform-tools 37.0.1 Tools\n"
                  "platforms/android-35 2 Platform\nbuild-tools/35.0.0 35 Build\n")
        fake_tee = self.fake_bin / "tee"
        fake_tee.write_text(
            "#!/bin/sh\n"
            "case \"$1\" in *pdsh-sdkmanager-list.*) slot=list;; *pdsh-sdkmanager-mirror.*) slot=mirror;; *) exit 3;; esac\n"
            "if [ \"$slot\" != \"$FAKE_TEE_TARGET\" ]; then exec " + tee_command + " \"$@\"; fi\n"
            "cat > \"$FAKE_TEE_FULL\"\n"
            "if [ \"$FAKE_TEE_MODE\" = diverge ]; then cat \"$FAKE_TEE_FULL\"; printf '%s' \"$FAKE_TEE_PREFIX\" > \"$1\"; exit 0; fi\n"
            "printf '%s' \"$FAKE_TEE_PREFIX\" | " + tee_command + " \"$@\"; exit 1\n",
            encoding="utf-8")
        fake_tee.chmod(0o755)
        capture_tmp = self.root / "each-capture-tmp"
        capture_tmp.mkdir()
        try:
            for target in ("list", "mirror"):
                for mode in ("failure", "diverge"):
                    with self.subTest(target=target, mode=mode):
                        proc = self.run_script(
                            "--check", PATH=str(self.fake_bin) + os.pathsep + os.environ.get("PATH", ""),
                            TMPDIR=str(capture_tmp), FAKE_SDKMANAGER_LIST_OVERRIDE=prefix + "Available packages:\n",
                            FAKE_TEE_TARGET=target, FAKE_TEE_MODE=mode,
                            FAKE_TEE_PREFIX=prefix, FAKE_TEE_FULL=str(self.root / "each-tee-full"))
                        output = self.combined(proc)
                        self.assertNotEqual(proc.returncode, 0, output)
                        self.assertIn("sdkmanager output capture failed" if mode == "failure" else
                                      "sdkmanager output captures differ", output)
                        self.assertNotIn("PACKAGE platform-tools=installed", output)
                        self.assertEqual(list(capture_tmp.glob("pdsh-sdkmanager-*")), [])
        finally:
            fake_tee.unlink(missing_ok=True)

    def test_sdkmanager_listing_error_preserves_exit_code(self):
        install = self.run_script()
        self.assertEqual(install.returncode, 0, self.combined(install))
        listing = "Installed packages:\nplatform-tools 37.0.1 Tools\n"
        proc = self.run_script("--check", FAKE_SDKMANAGER_LIST_OVERRIDE=listing,
                               FAKE_SDKMANAGER_LIST_EXIT="7")
        self.assertEqual(proc.returncode, 7, self.combined(proc))
        self.assertIn("sdkmanager --list_installed failed (exit 7)", self.combined(proc))

    def test_android_home_override_is_honoured(self):
        sdk = self.root / "existing-sdk"
        proc = self.run_script(ANDROID_HOME=str(sdk))
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 0, output)
        self.assertTrue((sdk / "platforms" / "android-35").is_dir())
        self.assertIn("ANDROID_HOME={}".format(sdk), output)
        self.assertIn("sdk.dir={}".format(sdk), self.local_properties.read_text(encoding="utf-8"))

    def test_environment_scrubs_caller_gradle_cache_and_timeout(self):
        caller_gradle = self.root / "caller-gradle-home"
        caller_cache = self.root / "caller-pdsh-cache"
        with mock.patch.dict(
            os.environ,
            {
                "GRADLE_USER_HOME": str(caller_gradle),
                "PDSH_GRADLE_USER_HOME": str(caller_cache),
                "PDSH_GRADLE_PRIMARY_TIMEOUT": "180",
            },
        ):
            proc = self.run_script()
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 0, output)
        self.assertFalse(caller_gradle.exists(), "test must not use caller GRADLE_USER_HOME")
        self.assertFalse(caller_cache.exists(), "test must not use caller PDSH_GRADLE_USER_HOME")
        lines = self.curl_log.read_text(encoding="utf-8").splitlines()
        primary = [line for line in lines if "gradle-8.13-bin.zip" in line]
        self.assertTrue(primary, lines)
        self.assertIn("--max-time 30", primary[0])
        seeded = self.root / "cache" / "pdsh" / "gradle" / "wrapper" / "dists" / "gradle-8.13-bin"
        self.assertTrue(seeded.is_dir(), "seed must use the temporary XDG cache")

    def test_gradle_primary_failure_uses_verified_fallback_without_retries(self):
        primary = "https://fake.invalid/gradle-primary.zip"
        fallback = "https://fake.invalid/gradle-mirror.zip"
        proc = self.run_script(
            PDSH_GRADLE_URL=primary,
            PDSH_GRADLE_FALLBACK_URLS=fallback,
            FAKE_CURL_FAIL_URL_CONTAINS="gradle-primary",
        )
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 0, output)
        self.assertTrue(self.local_properties.is_file())
        lines = self.curl_log.read_text(encoding="utf-8").splitlines()
        gradle_lines = [line for line in lines if "gradle-primary" in line or "gradle-mirror" in line]
        self.assertEqual(len(gradle_lines), 2, gradle_lines)
        self.assertIn("gradle-primary", gradle_lines[0])
        self.assertIn("--retry 0", gradle_lines[0])
        self.assertIn("--max-time 30", gradle_lines[0])
        self.assertIn("gradle-mirror", gradle_lines[1])
        self.assertIn("--retry 3", gradle_lines[1])
        self.assertIn("downloaded and verified", output)

    def test_gradle_user_home_override_seeds_the_same_cache(self):
        custom = self.root / "custom-gradle-home"
        proc = self.run_script(PDSH_GRADLE_USER_HOME=str(custom))
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 0, output)
        seeded = custom / "wrapper" / "dists" / "gradle-8.13-bin"
        self.assertTrue(
            any(
                (child / "gradle-8.13" / "bin" / "gradle").is_file()
                for child in seeded.iterdir()
            ),
            output,
        )
        check = self.run_script("--check", PDSH_GRADLE_USER_HOME=str(custom))
        self.assertEqual(check.returncode, 0, self.combined(check))
        self.assertIn("GRADLE_USER_HOME={}".format(custom), self.combined(check))
        # The wrapper must resolve the same cache the install just seeded.
        wrapper = Path(__file__).resolve().with_name("with-android-toolchain.sh")
        wrapped = subprocess.run(
            ["bash", str(wrapper), "bash", "-c", 'printf "%s\\n" "$GRADLE_USER_HOME"'],
            cwd=str(self.root),
            env=self.environment(
                PDSH_GRADLE_USER_HOME=str(custom),
                PDSH_JAVA_HOME=str(self.toolchain / "jdk-17"),
                PDSH_ANDROID_HOME=str(self.toolchain / "android-sdk"),
            ),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
            check=False,
        )
        self.assertEqual(wrapped.returncode, 0, wrapped.stdout)
        self.assertIn(str(custom), wrapped.stdout.splitlines())

    def test_seed_repairs_incomplete_unpacked_gradle(self):
        cache = self.root / "broken-gradle-home"
        directory = (
            cache
            / "wrapper"
            / "dists"
            / "gradle-8.13-bin"
            / wrapper_cache_hash(GRADLE_WRAPPER_URL)
        )
        (directory / "gradle-8.13").mkdir(parents=True)
        (directory / "gradle-8.13-bin.zip.ok").write_text("", encoding="utf-8")
        proc = self.run_script(PDSH_GRADLE_USER_HOME=str(cache))
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 0, output)
        self.assertTrue((directory / "gradle-8.13" / "bin" / "gradle").is_file())
        self.assertTrue(
            (directory / "gradle-8.13" / "lib" / "gradle-launcher-8.13.jar").is_file()
        )

    def test_valid_java_home_is_reused_without_jdk_download(self):
        java_home = self.root / "jdk17"
        write_jdk_home(java_home)
        proc = self.run_script(PDSH_JAVA_HOME=str(java_home))
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 0, output)
        downloads = self.curl_log.read_text(encoding="utf-8").splitlines()
        self.assertFalse(any("jdk17.tar.gz" in line for line in downloads), downloads)
        self.assertIn("JAVA_HOME={}".format(java_home), output)

    def test_java11_javac17_mismatch_is_rejected(self):
        java_home = self.root / "mixed-jdk"
        write_jdk_home(java_home, java_text=FAKE_JAVA_11, javac_text=FAKE_JAVAC)
        proc = self.run_script("--check", PDSH_JAVA_HOME=str(java_home))
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 1, output)
        self.assertIn("PDSH_JAVA_HOME is not a consistent JDK 17", output)
        self.assertIn("java=11 javac=17", output)

    def test_local_properties_preserves_unrelated_keys_and_replaces_sdk_dir(self):
        self.local_properties.parent.mkdir(parents=True, exist_ok=True)
        self.local_properties.write_text("sdk.dir=/old/sdk\ncustom.key=keep\n", encoding="utf-8")
        proc = self.run_script()
        self.assertEqual(proc.returncode, 0, self.combined(proc))
        text = self.local_properties.read_text(encoding="utf-8")
        self.assertNotIn("/old/sdk", text)
        self.assertIn("custom.key=keep", text)
        self.assertEqual(text.count("sdk.dir="), 1, text)

    def test_download_failure_propagates_exit_code_and_command(self):
        proc = self.run_script(FAKE_CURL_EXIT="23")
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 23, output)
        self.assertIn("download failed (exit 23)", output)
        self.assertIn("fake-curl", output)
        self.assertIn("https://fake.invalid/jdk17.tar.gz", output)
        self.assertFalse(self.local_properties.exists())
        self.assertFalse(any(self.toolchain.glob("downloads/*.part")) if self.toolchain.exists() else [])

    def test_partial_download_is_removed(self):
        proc = self.run_script(FAKE_CURL_PARTIAL_EXIT="28")
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 28, output)
        self.assertFalse(list(self.toolchain.glob("downloads/*.part")) if self.toolchain.exists() else [])
        self.assertFalse(self.local_properties.exists())

    def test_checksum_mismatch_fails_and_removes_partial_file(self):
        proc = self.run_script(PDSH_JDK_SHA256="0" * 64)
        output = self.combined(proc)
        self.assertNotEqual(proc.returncode, 0, output)
        self.assertIn("checksum mismatch", output)
        self.assertFalse(list(self.toolchain.glob("downloads/*.part")) if self.toolchain.exists() else [])
        self.assertFalse(self.local_properties.exists())

    def test_licence_failure_propagates_exit_code_and_command(self):
        write_jdk_home(self.toolchain / "jdk-17")
        proc = self.run_script(FAKE_SDKMANAGER_LICENSE_EXIT="9")
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 9, output)
        self.assertIn("licence acceptance failed (exit 9)", output)
        self.assertIn("--licenses", output)
        self.assertFalse(self.local_properties.exists())

    def test_package_install_failure_propagates_exit_code_and_command(self):
        write_jdk_home(self.toolchain / "jdk-17")
        proc = self.run_script(FAKE_SDKMANAGER_INSTALL_EXIT="7")
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 7, output)
        self.assertIn("package installation failed (exit 7)", output)
        self.assertIn("platform-tools", output)
        self.assertFalse(self.local_properties.exists())

    def test_check_detects_missing_platform_package(self):
        install = self.run_script()
        self.assertEqual(install.returncode, 0, self.combined(install))
        platform = self.toolchain / "android-sdk" / "platforms" / "android-35"
        shutil.rmtree(platform)
        proc = self.run_script("--check")
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 1, output)
        self.assertIn("PACKAGE platforms;android-35=MISSING", output)
        self.assertIn("directory-missing", output)

    def test_check_never_downloads_even_with_a_failing_downloader(self):
        install = self.run_script()
        self.assertEqual(install.returncode, 0, self.combined(install))
        for archive in (self.toolchain / "downloads").iterdir():
            archive.unlink()
        proc = self.run_script("--check", FAKE_CURL_EXIT="99")
        output = self.combined(proc)
        self.assertEqual(proc.returncode, 0, output)
        self.assertNotIn("fake-curl", output)
        self.assertIn("GRADLE_DIST_STATE=not-downloaded", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
