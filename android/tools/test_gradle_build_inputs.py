#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Task-graph and fail-loud input checks for the PDSH Android build.

The bug this test locks down is a *graph* bug, not a string typo: `:app` used to
run `check(...)` for the 65 MB Worker bundle and the Android `.so` at
configuration time, so `:app:testDebugUnitTest` could not even configure on a
host without those device inputs. `:testkit` attached the same staging to
`preBuild`, which is a parent of its JVM tests. The checks below ask Gradle for
the real task graph (`--dry-run` plus an init script) and assert the actual
model relationships:

  * pure JVM test graphs contain no APK/device staging tasks;
  * `:app:assembleDebug` / `:app:assembleRelease` contain the per-variant
    `package<PdshJni>` tasks and `:engine:verifyWorkerBundle`;
  * `:testkit:assembleDebugAndroidTest` contains the Worker/scenario/JNI
    staging tasks.

The suite also executes the validators against deliberately empty or zero-byte
fixtures through dedicated test-only validator tasks. Production packaging always
uses canonical input paths, so no property can replace the shipped Worker/JNI.
The shared validators must reject an existing-but-empty Worker directory and a
zero-byte or non-ELF `.so`.

`--dry-run` still configures the projects, so a configuration-time `check(...)`
would fail here exactly as it did for callers. The real packaging tasks keep
their fail-loud validators; the Linux host may not have the real NDK output or
the 65 MB Worker image, and the Mac owner runs the full production APK assembly.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
ANDROID_DIR = REPO_ROOT / "android"
WRAPPER = ANDROID_DIR / "tools" / "with-android-toolchain.sh"
BOOTSTRAP = ANDROID_DIR / "tools" / "bootstrap-android-toolchain.sh"
GRADLEW = ANDROID_DIR / "gradlew"

# The Graph is populated after configuration; writing it from whenReady also
# proves configuration completed without the missing device inputs.
INIT_SCRIPT = r"""
gradle.taskGraph.whenReady { graph ->
    def out = new File(System.getenv("PDSH_TASK_GRAPH_OUT"))
    def lines = graph.allTasks.collect { it.path }
    out.text = lines.sort().join("\n") + "\n"
}
"""


def _run(command, env, timeout=1800):
    return subprocess.run(
        command,
        cwd=str(REPO_ROOT),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        universal_newlines=True,
        timeout=timeout,
        check=False,
    )


class GradleBuildInputTaskGraphTests(unittest.TestCase):
    maxDiff = None
    java_home = ""
    android_home = ""
    gradle_user_home = ""

    @classmethod
    def setUpClass(cls):
        if not GRADLEW.is_file():
            raise unittest.SkipTest("android/gradlew is absent")
        if not WRAPPER.is_file() or not BOOTSTRAP.is_file():
            raise unittest.SkipTest("toolchain wrapper/bootstrap is absent")
        if shutil.which("bash") is None:
            raise unittest.SkipTest("bash is absent")

        # Each isolated Gradle execution owns its environment. Verify first; on a
        # clean worker install the pinned toolchain, then verify again. The test
        # command list may run this suite before the explicit bootstrap command,
        # so relying on an earlier step would be a false assumption.
        env = os.environ.copy()
        # Install is idempotent and also seeds the wrapper's Gradle cache. A bare
        # --check can pass on a host with a JDK/SDK but no cached distribution,
        # which would make the first wrapper invocation fetch Gradle again.
        install = _run(["bash", str(BOOTSTRAP)], env)
        if install.returncode != 0:
            raise AssertionError(
                "bootstrap install failed (exit {}):\n{}".format(
                    install.returncode, install.stdout[-12000:]
                )
            )
        check = _run(["bash", str(BOOTSTRAP), "--check"], env)
        if check.returncode != 0:
            raise AssertionError(
                "bootstrap --check failed (exit {}):\n{}".format(
                    check.returncode, check.stdout[-12000:]
                )
            )
        for line in check.stdout.splitlines():
            key, _, value = line.partition("=")
            if key == "JAVA_HOME" and value:
                cls.java_home = value
            elif key == "ANDROID_HOME" and value:
                cls.android_home = value
            elif key == "GRADLE_USER_HOME" and value:
                cls.gradle_user_home = value
        if not cls.java_home or not cls.android_home or not cls.gradle_user_home:
            raise AssertionError(
                "bootstrap --check did not print JAVA_HOME/ANDROID_HOME/GRADLE_USER_HOME:\n"
                + check.stdout[-8000:]
            )
        # Install must have seeded the same cache the wrapper will use, not just
        # found a JDK/SDK; otherwise the first Gradle invocation can hit the
        # stalled GitHub redirect again.
        dists = Path(cls.gradle_user_home) / "wrapper" / "dists" / "gradle-8.13-bin"
        seeded = [
            child
            for child in dists.iterdir()
            if (child / "gradle-8.13" / "bin" / "gradle").is_file()
            and (child / "gradle-8.13-bin.zip.ok").is_file()
        ] if dists.is_dir() else []
        if not seeded:
            raise AssertionError(
                "bootstrap did not seed the Gradle wrapper cache under {}:\n{}".format(
                    dists, install.stdout[-8000:]
                )
            )

    def toolchain_env(self):
        env = os.environ.copy()
        env["PDSH_JAVA_HOME"] = self.java_home
        env["PDSH_ANDROID_HOME"] = self.android_home
        # Pin the exact cache the install seeded; otherwise a worker with a
        # pre-existing GRADLE_USER_HOME/XDG could make the wrapper resolve a
        # different distribution and fetch Gradle again.
        env["PDSH_GRADLE_USER_HOME"] = self.gradle_user_home
        return env

    def task_graph(self, tasks):
        """Return the configured task-path set for one Gradle invocation."""
        with tempfile.TemporaryDirectory() as temp:
            temp_dir = Path(temp)
            init = temp_dir / "capture-task-graph.gradle"
            out = temp_dir / "tasks.txt"
            init.write_text(INIT_SCRIPT, encoding="utf-8")
            env = self.toolchain_env()
            env["PDSH_TASK_GRAPH_OUT"] = str(out)
            command = [
                "bash",
                str(WRAPPER),
                "./gradlew",
                "--configure-on-demand",
                "--no-daemon",
                "--quiet",
                "-I",
                str(init),
                *tasks,
                "--dry-run",
            ]
            proc = _run(command, env)
            if proc.returncode != 0:
                self.fail(
                    "Gradle task-graph invocation failed (exit {}):\n{}\n{}".format(
                        proc.returncode, " ".join(command), proc.stdout[-12000:]
                    )
                )
            if not out.is_file():
                self.fail(
                    "Gradle did not populate the task graph (init script was not run):\n"
                    + proc.stdout[-12000:]
                )
            return {
                line.strip()
                for line in out.read_text(encoding="utf-8").splitlines()
                if line.strip()
            }

    def run_gradle(self, tasks, properties=None):
        """Run real tasks so a validator's failure (not just graph shape) is proved."""
        env = self.toolchain_env()
        command = [
            "bash",
            str(WRAPPER),
            "./gradlew",
            "--no-daemon",
            "--console=plain",
            *tasks,
        ]
        for key, value in (properties or {}).items():
            command.append("-P{}={}".format(key, value))
        return _run(command, env)

    def test_jvm_tests_do_not_require_apk_or_device_inputs(self):
        graph = self.task_graph(
            [
                ":app:testDebugUnitTest",
                ":lib:testDebugUnitTest",
                ":testkit:testDebugUnitTest",
            ]
        )
        requested = {
            ":app:testDebugUnitTest",
            ":lib:testDebugUnitTest",
            ":testkit:testDebugUnitTest",
            ":app:stageHostJniForTests",
            ":testkit:stageHostJniForTests",
        }
        self.assertTrue(requested.issubset(graph), sorted(requested - graph))

        forbidden = {
            ":app:packageDebugPdshJni",
            ":engine:packageWorkerBundle",
            ":engine:verifyWorkerBundle",
            ":testkit:packageWorkerBundleForTests",
            ":testkit:packageScenarioCatalogForTests",
            ":testkit:stageAndroidTestJni",
            ":testkit:verifyWorkerBundleForTests",
            ":testkit:verifyAndroidTestJni",
            ":testkit:verifyScenarioCatalog",
        }
        self.assertFalse(
            forbidden & graph,
            "pure JVM test graph must not require APK/device inputs: {}".format(
                sorted(forbidden & graph)
            ),
        )
        android_test_staging = {
            task
            for task in graph
            if "AndroidTestAssets" in task
            or "AndroidTestJni" in task
            or "AndroidTestNative" in task
        }
        self.assertFalse(
            android_test_staging,
            "pure JVM test graph must not merge Android-test staging: {}".format(
                sorted(android_test_staging)
            ),
        )

    def test_debug_and_release_apk_packaging_use_real_jni_and_worker_inputs(self):
        graph = self.task_graph([":app:assembleDebug", ":app:assembleRelease"])
        expected = {
            ":app:packageDebugPdshJni",
            ":app:packageReleasePdshJni",
            ":engine:packageWorkerBundle",
            ":engine:verifyWorkerBundle",
        }
        self.assertTrue(
            expected.issubset(graph),
            "APK packaging must depend on the real inputs; missing: {}".format(
                sorted(expected - graph)
            ),
        )
        # These are real consumers, not generated dummy outputs.
        self.assertIn(":app:mergeDebugJniLibFolders", graph)
        self.assertIn(":app:mergeReleaseJniLibFolders", graph)
        # Test-only fixture validators must not leak into the shipping graph.
        for fixture_task in (
            ":app:stageHostJniForTests",
            ":app:verifyPdshJniFixture",
            ":engine:verifyWorkerBundleFixture",
            ":testkit:verifyWorkerBundleForTestsFixture",
            ":testkit:verifyAndroidTestJniFixture",
        ):
            self.assertNotIn(fixture_task, graph)

    def test_testkit_instrumented_packaging_keeps_device_staging(self):
        graph = self.task_graph([":testkit:assembleDebugAndroidTest"])
        expected = {
            ":testkit:packageWorkerBundleForTests",
            ":testkit:packageScenarioCatalogForTests",
            ":testkit:stageAndroidTestJni",
            ":testkit:verifyWorkerBundleForTests",
            ":testkit:verifyAndroidTestJni",
            ":testkit:verifyScenarioCatalog",
        }
        self.assertTrue(
            expected.issubset(graph),
            "instrumented test APK must stage real device inputs; missing: {}".format(
                sorted(expected - graph)
            ),
        )
        # The merge tasks are the packaging consumers, not preBuild.
        self.assertTrue(
            any(task.endswith("AndroidTestAssets") for task in graph),
            sorted(graph),
        )
        self.assertTrue(
            any("AndroidTestJni" in task or "AndroidTestNative" in task for task in graph),
            sorted(graph),
        )
        self.assertNotIn(":testkit:stageHostJniForTests", graph)

    def test_empty_worker_bundle_fixture_fails_shared_validator(self):
        with tempfile.TemporaryDirectory() as temp:
            empty = Path(temp) / "worker"
            empty.mkdir()
            proc = self.run_gradle(
                [":engine:verifyWorkerBundleFixture"],
                {"pdsh.test.workerBundleDir": str(empty)},
            )
            output = proc.stdout
            self.assertNotEqual(proc.returncode, 0, output)
            self.assertIn("worker bundle is incomplete", output, output[-8000:])

    def test_incomplete_worker_bundle_fixture_fails_shared_validator(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / "worker"
            bundle.mkdir()
            for name in ("index.html", "boot.js", "worker-entry.js"):
                (bundle / name).write_text("real content\n", encoding="utf-8")
            # image.tar.gz exists but is empty: a Zip source can still exist while
            # the product lacks the real image.
            (bundle / "image.tar.gz").write_bytes(b"")
            proc = self.run_gradle(
                [":testkit:verifyWorkerBundleForTestsFixture"],
                {"pdsh.test.testkitWorkerBundleDir": str(bundle)},
            )
            output = proc.stdout
            self.assertNotEqual(proc.returncode, 0, output)
            self.assertIn("worker bundle is incomplete", output, output[-8000:])

    def test_zero_byte_and_non_elf_jni_fixtures_fail_shared_validator(self):
        with tempfile.TemporaryDirectory() as temp:
            empty = Path(temp) / "libpdsh_jni.so"
            empty.write_bytes(b"")
            proc = self.run_gradle(
                [":app:verifyPdshJniFixture"],
                {"pdsh.test.pdshJniSo": str(empty)},
            )
            output = proc.stdout
            self.assertNotEqual(proc.returncode, 0, output)
            self.assertIn("JNI library is empty", output, output[-8000:])

            text = Path(temp) / "text.so"
            text.write_bytes(b"not an elf")
            proc = self.run_gradle(
                [":app:verifyPdshJniFixture"],
                {"pdsh.test.pdshJniSo": str(text)},
            )
            output = proc.stdout
            self.assertNotEqual(proc.returncode, 0, output)
            self.assertIn("not an ELF shared object", output, output[-8000:])

            proc = self.run_gradle(
                [":testkit:verifyAndroidTestJniFixture"],
                {"pdsh.test.testkitAndroidJni": str(empty)},
            )
            output = proc.stdout
            self.assertNotEqual(proc.returncode, 0, output)
            self.assertIn("JNI library is empty", output, output[-8000:])

    def test_wrapper_no_xdg_gradle_home_matches_bootstrap_seed(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "home"
            home.mkdir()
            env = self.toolchain_env()
            for key in ("XDG_CACHE_HOME", "GRADLE_USER_HOME", "PDSH_GRADLE_USER_HOME"):
                env.pop(key, None)
            env["HOME"] = str(home)
            # A caller may already export options; the wrapper must append, not
            # replace them, and the test must not require exact-line equality.
            env["JAVA_TOOL_OPTIONS"] = "-Dfoo=bar"
            proc = _run(
                [
                    "bash",
                    str(WRAPPER),
                    "bash",
                    "-c",
                    'printf "%s\\n%s\\n" "$GRADLE_USER_HOME" "$JAVA_TOOL_OPTIONS"',
                ],
                env,
                timeout=120,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout)
            lines = proc.stdout.splitlines()
            self.assertIn(str(home / "pdsh" / "gradle"), lines, lines)
            # The wrapper appends to any pre-existing JAVA_TOOL_OPTIONS, so check
            # that one line contains the expected property rather than equals it.
            self.assertTrue(
                any(
                    "-Dfoo=bar" in line and "-Duser.home={}".format(home) in line
                    for line in lines
                ),
                lines,
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
