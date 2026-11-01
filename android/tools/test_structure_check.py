#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for android/tools/structure_check.py.

Each test builds a small self-contained fixture repository, mutates exactly one
property the gate is supposed to protect, and asserts that the gate fails with
the matching check name. No Gradle, SDK or network access is used.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# Same directory as this test; unittest discovery puts the start directory on
# sys.path. Importing the checker lets the baseline assertion follow CHECKS
# instead of hard-coding a count that a new check would invalidate.
import structure_check

CHECKER = Path(__file__).resolve().with_name("structure_check.py")

SWIFT_MODULES = (
    "PhoneDSHAgentCore",
    "PhoneDSHWire",
    "PhoneDSHLog",
    "PhoneDSHLoopback",
    "PhoneDSHGateway",
    "PhoneDSHController",
    "PhoneDSHEngine",
    "PhoneDSHShell",
    "PhoneDSH",
    "PhoneDSHScenario",
    "PhoneDSHHarness",
)

KOTLIN_PACKAGES = {
    "PhoneDSHAgentCore": "com.phonedsh.agentcore",
    "PhoneDSHWire": "com.phonedsh.wire",
    "PhoneDSHLog": "com.phonedsh.log",
    "PhoneDSHLoopback": "com.phonedsh.loopback",
    "PhoneDSHGateway": "com.phonedsh.gateway",
    "PhoneDSHController": "com.phonedsh.controller",
    "PhoneDSHEngine": "com.phonedsh.engine",
    "PhoneDSHShell": "com.phonedsh.shell",
    "PhoneDSH": "com.phonedsh.dsh",
    "PhoneDSHScenario": "com.phonedsh.testkit.scenario",
    "PhoneDSHHarness": "com.phonedsh.testkit.harness",
}

MODULES = (
    "platform",
    "core",
    "net",
    "controller",
    "engine",
    "shell",
    "dsh",
    "lib",
    "testkit",
    "app",
)

SETTINGS = """// SPDX-License-Identifier: MIT
pluginManagement {
    repositories {
        google()
        mavenCentral()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "fixture"
include(":platform")
include(":core")
include(":net")
include(":controller")
include(":engine")
include(":shell")
include(":dsh")
include(":lib")
include(":testkit")
include(":app")
"""

CATALOG = """# SPDX-License-Identifier: MIT
[versions]
agp = "0.0.0"                # unverified pin
kotlin = "0.0.0"             # unverified pin
compose-bom = "0.0.0"        # unverified pin
junit = "0.0.0"              # unverified pin

[libraries]
junit = { module = "junit:junit", version.ref = "junit" }

[plugins]
android-library = { id = "com.android.library", version.ref = "agp" }
kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
"""

# The 16 KB link argument lives in the JNI crate's build script (it is the Rust
# link, outside android/), and the fixture must carry it or the baseline would
# fail for the wrong reason.
CARGO_16K = """// SPDX-License-Identifier: MIT
// A comment that mentions -Wl,-z,max-page-size=16384 must never satisfy the gate.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("android") {
        return;
    }
    println!("cargo:rustc-link-arg=-Wl,-z,max-page-size=16384");
}
"""


def elf64_with_load_alignments(alignments):
    """A minimal little-endian AArch64 ELF64 with one PT_LOAD per alignment."""
    import struct

    count = len(alignments)
    header_size = 64
    phentsize = 56
    data = bytearray(header_size + phentsize * count)
    data[0:4] = b"\x7fELF"
    data[4] = 2  # ELFCLASS64
    data[5] = 1  # ELFDATA2LSB
    struct.pack_into("<H", data, 16, 3)  # ET_DYN
    struct.pack_into("<H", data, 18, 183)  # EM_AARCH64
    struct.pack_into("<I", data, 20, 1)  # e_version
    struct.pack_into("<Q", data, 32, header_size)  # e_phoff
    struct.pack_into("<H", data, 52, header_size)  # e_ehsize
    struct.pack_into("<H", data, 54, phentsize)  # e_phentsize
    struct.pack_into("<H", data, 56, count)  # e_phnum
    for index, align in enumerate(alignments):
        base = header_size + index * phentsize
        struct.pack_into("<I", data, base, 1)  # p_type = PT_LOAD
        struct.pack_into("<I", data, base + 4, 5)  # p_flags = R|X
        struct.pack_into("<Q", data, base + 48, align)  # p_align
    return bytes(data)



def readme_text():
    lines = [
        "<!-- SPDX-License-Identifier: MIT -->",
        "# Fixture Android tree",
        "",
        "| Swift 模块（`Sources/`） | Kotlin 包 | Gradle 模块 | 说明 |",
        "| --- | --- | --- | --- |",
    ]
    for module in SWIFT_MODULES:
        lines.append(
            "| {} | `{}` | `:core` | fixture |".format(module, KOTLIN_PACKAGES[module])
        )
    lines.append("")
    lines.append("Packages carry the 1:1 mirror; :core is only a build boundary.")
    return "\n".join(lines) + "\n"


def build_file(name):
    if name == "lib":
        return """// SPDX-License-Identifier: MIT
plugins {
    alias(libs.plugins.android.library)
}
group = "com.phonedsh"
version = "0.0.0-SNAPSHOT"
android {
    namespace = "com.phonedsh.lib"
    compileSdk = 35
    defaultConfig {
        minSdk = 26
        targetSdk = 35
    }
}
dependencies {
    api(project(":dsh"))
}
"""
    if name == "app":
        return """// SPDX-License-Identifier: MIT
plugins {
    alias(libs.plugins.android.application)
}
android {
    namespace = "com.phonedsh.probe"
    compileSdk = 35
    defaultConfig {
        minSdk = 26
        targetSdk = 35
    }
}
"""
    return """// SPDX-License-Identifier: MIT
plugins {
    alias(libs.plugins.kotlin.jvm)
}
android {
    namespace = "com.phonedsh.__NAME__"
    compileSdk = 35
    defaultConfig {
        minSdk = 26
    }
}
""".replace("__NAME__", name)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def make_fixture(root):
    for module in SWIFT_MODULES:
        (root / "Sources" / module).mkdir(parents=True, exist_ok=True)
    android = root / "android"
    write(android / "settings.gradle.kts", SETTINGS)
    write(android / "gradle" / "libs.versions.toml", CATALOG)
    write(android / "README.md", readme_text())
    write(root / "shell" / "crates" / "pdsh-jni" / "build.rs", CARGO_16K)
    for name in MODULES:
        write(android / name / "build.gradle.kts", build_file(name))
    write(
        android / "core" / "src" / "main" / "kotlin" / "com" / "phonedsh" / "wire" / "PackageMarker.kt",
        "// SPDX-License-Identifier: MIT\n// Fixture marker.\npackage com.phonedsh.wire\n",
    )


class StructureCheckMutationTests(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory()
        self.root = Path(self._temp.name)
        make_fixture(self.root)

    def tearDown(self):
        self._temp.cleanup()

    def run_check(self):
        return subprocess.run(
            [sys.executable, str(CHECKER), "--root", str(self.root)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False,
        )

    def assert_fails(self, check_name):
        proc = self.run_check()
        combined = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 1, combined)
        self.assertIn("[FAIL] {}:".format(check_name), proc.stdout, combined)

    def assert_passes(self, check_name):
        proc = self.run_check()
        combined = proc.stdout + proc.stderr
        self.assertIn("[PASS] {}:".format(check_name), proc.stdout, combined)

    def mutate(self, relative, old, new):
        path = self.root / relative
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def test_baseline_passes(self):
        proc = self.run_check()
        combined = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, combined)
        self.assertNotIn("[FAIL]", proc.stdout, combined)
        # Derive the count from the checker's CHECKS tuple instead of freezing
        # "OK N checks passed": adding a check used to turn this baseline test
        # red for the wrong reason (the fixture passed; only the literal was stale).
        self.assertIn(
            "OK {} checks passed".format(len(structure_check.CHECKS)),
            proc.stdout,
            combined,
        )

    def test_extra_include_fails(self):
        path = self.root / "android" / "settings.gradle.kts"
        path.write_text(path.read_text(encoding="utf-8") + '\ninclude(":ghost")\n', encoding="utf-8")
        self.assert_fails("settings-includes")

    def test_missing_include_fails(self):
        self.mutate("android/settings.gradle.kts", 'include(":net")\n', "")
        self.assert_fails("settings-includes")

    def test_wrong_minsdk_fails(self):
        self.mutate("android/app/build.gradle.kts", "minSdk = 26", "minSdk = 24")
        self.assert_fails("sdk-levels")

    def test_readme_missing_swift_module_fails(self):
        path = self.root / "android" / "README.md"
        kept = [line for line in path.read_text(encoding="utf-8").splitlines() if "PhoneDSHScenario" not in line]
        path.write_text("\n".join(kept) + "\n", encoding="utf-8")
        self.assert_fails("readme-map")

    def test_real_kotlin_statement_passes(self):
        path = self.root / "android" / "core" / "src" / "main" / "kotlin" / "com" / "phonedsh" / "wire" / "PackageMarker.kt"
        path.write_text(path.read_text(encoding="utf-8") + "\nval answer = 42\n", encoding="utf-8")
        self.assert_passes("kotlin-stubs")

    def test_todo_stub_in_main_fails(self):
        path = self.root / "android" / "core" / "src" / "main" / "kotlin" / "com" / "phonedsh" / "wire" / "PackageMarker.kt"
        path.write_text(path.read_text(encoding="utf-8") + "\nfun later(): Int = TODO()\n", encoding="utf-8")
        self.assert_fails("kotlin-stubs")

    def test_todo_stub_in_tests_passes(self):
        path = self.root / "android" / "core" / "src" / "test" / "kotlin" / "Fake.kt"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("// SPDX-License-Identifier: MIT\nfun later(): Int = TODO()\n", encoding="utf-8")
        self.assert_passes("kotlin-stubs")

    def test_missing_build_file_fails(self):
        (self.root / "android" / "controller" / "build.gradle.kts").unlink()
        self.assert_fails("module-build-files")

    def test_forbidden_repository_fails(self):
        path = self.root / "android" / "settings.gradle.kts"
        path.write_text(path.read_text(encoding="utf-8") + "\nmavenLocal()\n", encoding="utf-8")
        self.assert_fails("repositories")

    def test_absolute_path_fails(self):
        bad_path = "/" + "Users" + "/someone" + "/sdk"
        write(self.root / "android" / "abspath-note.md", "bad = \"{}\"\n".format(bad_path))
        self.assert_fails("absolute-paths")

    def test_unverified_pin_annotation_required(self):
        self.mutate("android/gradle/libs.versions.toml", "# unverified pin", "# verified")
        self.assert_fails("catalog-pins")

    def test_16k_link_arg_removed_fails(self):
        path = self.root / "shell" / "crates" / "pdsh-jni" / "build.rs"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                '    println!("cargo:rustc-link-arg=-Wl,-z,max-page-size=16384");\n',
                "",
            ),
            encoding="utf-8",
        )
        self.assert_fails("android-16k-link-arg")

    def test_16k_flag_in_a_comment_only_fails(self):
        # The regression this catches: someone "disables" the flag with `//` and
        # the gate keeps reading the comment. Comments are stripped, so it fails.
        path = self.root / "shell" / "crates" / "pdsh-jni" / "build.rs"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                '    println!("cargo:rustc-link-arg=-Wl,-z,max-page-size=16384");',
                '    // println!("cargo:rustc-link-arg=-Wl,-z,max-page-size=16384");',
            ),
            encoding="utf-8",
        )
        self.assert_fails("android-16k-link-arg")

    def test_16k_page_size_below_threshold_fails(self):
        self.mutate(
            "shell/crates/pdsh-jni/build.rs",
            "link-arg=-Wl,-z,max-page-size=16384",
            "link-arg=-Wl,-z,max-page-size=4096",
        )
        self.assert_fails("android-16k-link-arg")

    def test_16k_flag_without_the_android_gate_fails(self):
        # The flag must not reach the host dylib (ld64 rejects it) or the wasm
        # products; an ungated build script is a scope regression, not a pass.
        self.mutate(
            "shell/crates/pdsh-jni/build.rs",
            'if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("android") {\n        return;\n    }\n',
            "",
        )
        self.assert_fails("android-16k-link-arg")

    def test_16k_artifact_misaligned_fails(self):
        artifact = (
            self.root
            / "shell"
            / "target"
            / "aarch64-linux-android"
            / "debug"
            / "libpdsh_jni.so"
        )
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_bytes(elf64_with_load_alignments([0x4000, 0x1000]))
        self.assert_fails("android-16k-artifact")

    def test_16k_artifact_aligned_passes(self):
        artifact = (
            self.root
            / "shell"
            / "target"
            / "aarch64-linux-android"
            / "debug"
            / "libpdsh_jni.so"
        )
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_bytes(elf64_with_load_alignments([0x4000, 0x4000]))
        self.assert_passes("android-16k-artifact")


if __name__ == "__main__":
    unittest.main(verbosity=2)
