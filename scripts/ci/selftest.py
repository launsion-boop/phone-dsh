#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Self-test for the phone-DSH static checkers.

For every checker the test builds a passing tree and a failing tree in a
temporary directory outside the repository, initialises each tree as a git
repository (so the ``git ls-files`` file-set rule is exercised), runs the
checker through its real CLI with ``--root``, and asserts the exit code and the
reported ``file:line: rule`` for every rule.  It also asserts that the real
production scan never descends into ``node_modules`` or the fixtures tree.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PHONE_DIR = Path(__file__).resolve().parent
REPO_ROOT = PHONE_DIR.parents[1]
PYTHON = sys.executable
sys.path.insert(0, str(PHONE_DIR))
import common

CHECKERS = {
    "hygiene": PHONE_DIR / "hygiene.py",
    "license": PHONE_DIR / "license.py",
    "modules": PHONE_DIR / "modules.py",
    "no_dsh_patch": PHONE_DIR / "no_dsh_patch.py",
}

def banned_words_sample():
    # Composed at run time so this checker's own source stays clean.
    return "\n".join(["Tono" + "AI", "Tono" + "Team", "Tono" + "Live", "to" + "no token"]) + "\n"


def email_sample():
    return "worker@" + "real.example.com"


def home_paths_sample():
    return "/" + "Users/alice/project\n/" + "home/bob/file\n"


def hostname_sample():
    return "https://" + "internal." + "corp.example.net\n"


def credentials_sample():
    return (
        "sk-" + "a" * 16 + "\n"
        "Authorization: Bearer " + "a" * 32 + "\n"
        "AKIA" + "ABCDEFGHIJKLMNOP" + "\n"
        "-----" + "BEGIN PRIVATE KEY-----\n"
    )


def excluded_banned_sample():
    return "Tono" + "AI\n/" + "Users/alice/secret\n"


PIN = json.dumps(
    {
        "repo": "https://github.com/deepseek-ai/deepseek-harness",
        "commit": "7be5505b0be06009d74891c869063c9cf19a0df0",
        "version": "0.2.1-rc.2",
    },
    indent=2,
) + "\n"

MODULES = [
    "PhoneDSHWire",
    "PhoneDSHLog",
    "PhoneDSHLoopback",
    "PhoneDSHGateway",
    "PhoneDSHController",
    "PhoneDSHEngine",
    "PhoneDSHShell",
    "PhoneDSH",
]

CORE_MODULE = "PhoneDSHAgentCore"


def line_of(text, needle):
    index = text.index(needle)
    return text.count("\n", 0, index) + 1


def package_text(
    gateway_dependencies='"PhoneDSHAgentCore"',
    wire_dependencies="",
    engine_has_tests=True,
    include_xz_shell=True,
    agent_core_dependencies="",
    loopback_test_dependencies="",
):
    wire_extra = f", dependencies: [{wire_dependencies}]" if wire_dependencies else ""
    engine_extra = "" if engine_has_tests else ", hasTests: false"
    agent_core_extra = f", dependencies: [{agent_core_dependencies}]" if agent_core_dependencies else ""
    loopback_test_extra = (
        f", testDependencies: [{loopback_test_dependencies}]"
        if loopback_test_dependencies
        else ""
    )
    pdsh_entry = (
        '    Module(name: "PhoneDSHShell", dependencies: ["PhoneDSHAgentCore"]),\n'
        if include_xz_shell
        else ""
    )
    return (
        "let modules: [Module] = [\n"
        f'    Module(name: "PhoneDSHAgentCore"{agent_core_extra}),\n'
        f'    Module(name: "PhoneDSHWire"{wire_extra}),\n'
        '    Module(name: "PhoneDSHLog", dependencies: ["PhoneDSHWire"]),\n'
        '    Module(name: "PhoneDSHLoopback",\n'
        f'           dependencies: ["PhoneDSHWire", "PhoneDSHAgentCore"]'
        f"{loopback_test_extra}),\n"
        '    Module(name: "PhoneDSHGateway",\n'
        f"           dependencies: [{gateway_dependencies}]),\n"
        '    Module(name: "PhoneDSHController",\n'
        '           dependencies: ["PhoneDSHWire", "PhoneDSHLog"]),\n'
        f'    Module(name: "PhoneDSHEngine", dependencies: ["PhoneDSHLoopback"]{engine_extra}),\n'
        f"{pdsh_entry}"
        '    Module(name: "PhoneDSH",\n'
        '           dependencies: ["PhoneDSHWire", "PhoneDSHLog", "PhoneDSHLoopback",\n'
        '                          "PhoneDSHGateway", "PhoneDSHController",\n'
        '                          "PhoneDSHEngine", "PhoneDSHShell", "PhoneDSHAgentCore"]),\n'
        "]\n"
        "var targets: [Target] = modules.flatMap { m -> [Target] in\n"
        "    var t: [Target] = [.target(name: m.name, dependencies: m.dependencies)]\n"
        "    if m.hasTests {\n"
        '        t.append(.testTarget(name: "\\(m.name)Tests",\n'
        "                             dependencies: [.target(name: m.name)] + m.testDependencies))\n"
        "    }\n"
        "    return t\n"
        "}\n"
    )


class CheckerFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pdsh-phone-ci-selftest-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.assertFalse(
            str(self.tmp.resolve()).startswith(str(REPO_ROOT.resolve()) + os.sep),
            "fixture trees must live outside the repository",
        )

    def git(self, tree, *args):
        proc = subprocess.run(
            ["git", "-C", str(tree), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if proc.returncode != 0:
            self.fail(f"git {' '.join(args)} failed: {proc.stderr}")

    def make_tree(self, files, force_add=()):
        tree = Path(tempfile.mkdtemp(prefix="tree-", dir=str(self.tmp)))
        for rel, content in files.items():
            path = tree / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content.encode("utf-8"))
        self.git(tree, "init", "-q")
        self.git(tree, "add", "-A")
        if force_add:
            self.git(tree, "add", "-f", *force_add)
        return tree

    def run_checker(self, name, tree, *extra):
        return subprocess.run(
            [PYTHON, str(CHECKERS[name]), "--root", str(tree), *extra],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=180,
        )

    def assert_pass(self, proc):
        self.assertEqual(
            proc.returncode,
            0,
            f"expected PASS\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )

    def assert_finding(self, proc, rel, line, rule):
        self.assertEqual(
            proc.returncode,
            1,
            f"expected FAIL\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        needle = f"{rel}:{line}: {rule}:"
        self.assertIn(
            needle,
            proc.stdout,
            f"missing {needle!r}\nstdout:\n{proc.stdout}",
        )


class HygieneTests(CheckerFixture):
    def test_passing_tree(self):
        tree = self.make_tree(
            {
                "spec/v1/README.md": (
                    "# Fixture\n\n"
                    "See https://github.com/deepseek-ai/deepseek-harness, https://docs.rs/,\n"
                    "https://modelcontextprotocol.io/ and http://127.0.0.1:<port>/dsh.\n"
                    "Reserved: https://model.example, https://dsh.invalid, https://dsh.internal,\n"
                    "https://evil.example, https://sub.example.com and http://localhost:1234.\n"
                ),
                "spec/v1/schema/a.json": (
                    '{\n  "$schema": "https://json-schema.org/draft/2020-12/schema"\n}\n'
                ),
                "scripts/ci/hygiene-allow.txt": "json-schema\\.org\n",
                ".gitignore": "plugins/ignored.txt\n",
                "plugins/ignored.txt": excluded_banned_sample(),
                "plugins/node_modules/evil/bad.txt": excluded_banned_sample(),
                "scripts/ci/fixtures/bad.txt": excluded_banned_sample(),
            },
            force_add=["plugins/node_modules/evil/bad.txt"],
        )
        proc = self.run_checker("hygiene", tree)
        self.assert_pass(proc)
        self.assertNotIn("ignored.txt", proc.stdout)

        listing = self.run_checker("hygiene", tree, "--list-files")
        self.assert_pass(listing)
        self.assertIn("spec/v1/schema/a.json", listing.stdout)
        self.assertNotIn("plugins/node_modules/evil/bad.txt", listing.stdout)
        self.assertNotIn("scripts/ci/fixtures/bad.txt", listing.stdout)
        self.assertNotIn("scripts/ci/hygiene-allow.txt", listing.stdout)

    def test_failing_tree(self):
        tree = self.make_tree(
            {
                "spec/v1/bad/words.md": banned_words_sample(),
                "spec/v1/bad/contact.txt": email_sample(),
                "spec/v1/bad/paths.txt": home_paths_sample(),
                "spec/v1/bad/urls.txt": hostname_sample(),
                "spec/v1/bad/bare-host.txt": (
                    "api." + "service." + "corp.example.net\n"
                ),
                "spec/v1/bad/creds.txt": credentials_sample(),
                ".gitignore": "spec/v1/bad/ignored.txt\n",
                "spec/v1/bad/ignored.txt": excluded_banned_sample(),
            }
        )
        proc = self.run_checker("hygiene", tree)
        for line in (1, 3):
            self.assert_finding(proc, "spec/v1/bad/words.md", line, "banned-word")
        self.assertNotIn("spec/v1/bad/words.md:2:", proc.stdout)
        self.assertNotIn("spec/v1/bad/words.md:4:", proc.stdout)
        self.assert_finding(proc, "spec/v1/bad/contact.txt", 1, "email")
        self.assert_finding(proc, "spec/v1/bad/paths.txt", 1, "home-path")
        self.assert_finding(proc, "spec/v1/bad/paths.txt", 2, "home-path")
        self.assert_finding(proc, "spec/v1/bad/urls.txt", 1, "hostname")
        self.assert_finding(proc, "spec/v1/bad/bare-host.txt", 1, "hostname")
        for line in (1, 2, 3, 4):
            self.assert_finding(proc, "spec/v1/bad/creds.txt", line, "credential")
        self.assertNotIn("ignored.txt", proc.stdout)

    def test_bare_reserved_documentation_hosts_pass(self):
        tree = self.make_tree(
            {
                "spec/v1/ok/reserved.txt": (
                    "https://example.com\n"
                    "https://example.org\n"
                    "https://example.net\n"
                ),
            }
        )
        self.assert_pass(self.run_checker("hygiene", tree))


class LicenseTests(CheckerFixture):
    def test_passing_tree(self):
        tree = self.make_tree(
            {
                "spec/v1/ok.py": (
                    "#!/usr/bin/env python3\n# SPDX-License-Identifier: MIT\nprint('ok')\n"
                ),
                "plugins/pkg/ok.ts": "// SPDX-License-Identifier: MIT\nexport const ok = 1;\n",
                "plugins/pkg/ok.mjs": (
                    "#!/usr/bin/env node\n// SPDX-License-Identifier: MIT\n"
                ),
                "plugins/ci/ok.yml": "# SPDX-License-Identifier: MIT\nname: fixture\n",
                "plugins/ci/ok.yaml": "# SPDX-License-Identifier: MIT\nname: fixture\n",
                "plugins/pkg/package.json": (
                    '{\n  "name": "pkg",\n  "license": "MIT"\n}\n'
                ),
                "shell/src/ok.rs": "// SPDX-License-Identifier: MIT\nfn main() {}\n",
                "shell/Cargo.toml": (
                    "[workspace]\n"
                    "members = [\n"
                    '    "crates/member",\n'
                    "]\n"
                    'resolver = "2"\n'
                    "\n"
                    "[workspace.package]\n"
                    'license = "MIT"\n'
                ),
                "shell/crates/member/Cargo.toml": (
                    "[package]\n"
                    'name = "member"\n'
                    "license.workspace = true\n"
                ),
                "Package.swift": (
                    "let modules: [Module] = [\n"
                    '    Module(name: "PhoneDSH", dependencies: ["XiaozhiLinkProviders"]),\n'
                    "]\n"
                    "let targets: [Target] = [\n"
                    '    .target(name: "PhoneDSHShell", dependencies: ["XiaozhiLinkProviders"]),\n'
                    '    .testTarget(name: "PhoneDSHTests",\n'
                    '                dependencies: [.target(name: "PhoneDSH")]),\n'
                    "]\n"
                ),
                "Sources/PhoneDSHShell/ok.swift": (
                    "// SPDX-License-Identifier: MIT\npublic enum X {}\n"
                ),
                "Tests/PhoneDSHShellTests/ok.swift": (
                    "// SPDX-License-Identifier: MIT\nimport XCTest\n"
                ),
                "scripts/ci/run.sh": (
                    "#!/usr/bin/env bash\n# SPDX-License-Identifier: MIT\nexit 0\n"
                ),
                "spec/v1/README.md": "# no header needed\n",
                "spec/v1/data.json": "{}\n",
            }
        )
        self.assert_pass(self.run_checker("license", tree))

    def test_failing_tree(self):
        tree = self.make_tree(
            {
                "spec/v1/bad.swift": "import Foundation\nlet value = 1\n",
                "shell/src/bad.py": (
                    '#!/usr/bin/env python3\n"""doc"""\nprint("x")\n'
                    "# SPDX-License-Identifier: MIT\n"
                ),
                "plugins/pkg/package.json": (
                    '{\n  "name": "pkg",\n  "license": "Apache-2.0"\n}\n'
                ),
                "plugins/other/package.json": '{\n  "name": "other"\n}\n',
            }
        )
        proc = self.run_checker("license", tree)
        self.assert_finding(proc, "spec/v1/bad.swift", 1, "license")
        self.assert_finding(proc, "shell/src/bad.py", 1, "license")
        self.assert_finding(proc, "plugins/pkg/package.json", 1, "package-license")
        self.assert_finding(proc, "plugins/other/package.json", 1, "package-license")

    def test_cargo_license_and_workspace_rules(self):
        workspace = (
            "[workspace]\n"
            "members = [\n"
            '    "crates/bad",\n'
            '    "crates/missing",\n'
            "]\n"
            "\n"
            "[workspace.package]\n"
            'license = "Apache-2.0"\n'
        )
        member = (
            "[package]\n"
            'name = "bad"\n'
            'license = "Apache-2.0"\n'
        )
        tree = self.make_tree(
            {
                "shell/Cargo.toml": workspace,
                "shell/crates/bad/Cargo.toml": member,
            }
        )
        proc = self.run_checker("license", tree)
        self.assert_finding(
            proc,
            "shell/Cargo.toml",
            line_of(workspace, 'license = "Apache-2.0"'),
            "cargo-license",
        )
        self.assert_finding(
            proc,
            "shell/crates/bad/Cargo.toml",
            line_of(member, 'license = "Apache-2.0"'),
            "cargo-license",
        )
        self.assert_finding(
            proc,
            "shell/Cargo.toml",
            line_of(workspace, '"crates/missing"'),
            "cargo-workspace",
        )

    def test_forbidden_toolbox_link(self):
        package = (
            "let modules: [Module] = [\n"
            '    Module(name: "PhoneDSH",\n'
            '           dependencies: ["PhoneDSHWire", "XiaozhiLinkToolboxCore"]),\n'
            "]\n"
            "let targets: [Target] = [\n"
            '    .target(name: "PhoneDSHShell", dependencies: ["XiaozhiLinkToolboxBridge"]),\n'
            '    .testTarget(name: "PhoneDSHTests",\n'
            '                dependencies: [.target(name: "PhoneDSH")],\n'
            '                testDependencies: ["XiaozhiLinkToolbox"]),\n'
            "]\n"
        )
        tree = self.make_tree({"Package.swift": package})
        proc = self.run_checker("license", tree)
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(package, '"XiaozhiLinkToolboxCore"'),
            "forbidden-toolbox-link",
        )
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(package, '"XiaozhiLinkToolboxBridge"'),
            "forbidden-toolbox-link",
        )
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(package, '"XiaozhiLinkToolbox"'),
            "forbidden-toolbox-link",
        )


class NoDshPatchTests(CheckerFixture):
    def test_passing_tree(self):
        tree = self.make_tree(
            {
                "plugins/dsh-pin.json": PIN,
                "plugins/package.json": '{"name": "pkg", "license": "MIT"}\n',
                "plugins/src/use.ts": (
                    'import { createWorkerHost } from "@deepseek-ai/dsh";\n'
                    "// Comments may mention createWorkerHost, MemoryVfs and packVfsImage.\n"
                    'export { createWorkerHost } from "./shim";\n'
                    "export const enabled = true;\n"
                ),
                "plugins/tests/vendored.test.ts": (
                    "export function createWorkerHost() {\n  return null;\n}\n"
                ),
            }
        )
        self.assert_pass(self.run_checker("no_dsh_patch", tree))

    def test_missing_pin_warns_but_passes(self):
        tree = self.make_tree(
            {
                "plugins/src/use.ts": (
                    'import { createWorkerHost } from "@deepseek-ai/dsh";\n'
                    "export const enabled = true;\n"
                )
            }
        )
        proc = self.run_checker("no_dsh_patch", tree)
        self.assert_pass(proc)
        self.assertIn("WARN: plugins/dsh-pin.json is absent", proc.stdout)

    def test_malformed_pin_fails(self):
        broken = json.dumps(
            {
                "repo": "https://github.com/deepseek-ai/deepseek-harness",
                "commit": "not-a-commit",
                "version": "0.2.1-rc.2",
            },
            indent=2,
        ) + "\n"
        tree = self.make_tree({"plugins/dsh-pin.json": broken})
        proc = self.run_checker("no_dsh_patch", tree)
        self.assert_finding(proc, "plugins/dsh-pin.json", 1, "dsh-pin")

    def test_failing_tree(self):
        patched_manifest = (
            "{\n"
            '  "name": "pkg",\n'
            '  "license": "MIT",\n'
            '  "pnpm": {\n'
            '    "patchedDependencies": {\n'
            '      "@deepseek-ai/dsh": "patches/0001-dsh.patch"\n'
            "    }\n"
            "  }\n"
            "}\n"
        )
        patch_package_manifest = (
            "{\n"
            '  "name": "tools",\n'
            '  "license": "MIT",\n'
            '  "scripts": {\n'
            '    "postinstall": "patch-package"\n'
            "  }\n"
            "}\n"
        )
        tree = self.make_tree(
            {
                "plugins/dsh-pin.json": PIN,
                "plugins/package.json": patched_manifest,
                "plugins/src/vendor.ts": (
                    "// copied from upstream\n"
                    "export function createWorkerHost(env) {\n"
                    "  return env;\n"
                    "}\n"
                ),
                "plugins/tools/package.json": patch_package_manifest,
                "patches/0001-dsh.patch": (
                    "--- a/node_modules/@deepseek-ai/dsh/index.js\n"
                    "+++ b/node_modules/@deepseek-ai/dsh/index.js\n"
                ),
                "node_modules/@deepseek-ai/dsh/index.js": "module.exports = {};\n",
            },
            force_add=["node_modules/@deepseek-ai/dsh/index.js"],
        )
        proc = self.run_checker("no_dsh_patch", tree)
        self.assert_finding(proc, "plugins/src/vendor.ts", 2, "vendored-definition")
        self.assert_finding(proc, "patches/0001-dsh.patch", 1, "dsh-patch")
        self.assert_finding(
            proc,
            "node_modules/@deepseek-ai/dsh/index.js",
            1,
            "tracked-dsh-module",
        )
        self.assert_finding(
            proc,
            "plugins/package.json",
            line_of(patched_manifest, '"patchedDependencies"'),
            "patched-dependencies",
        )
        self.assert_finding(
            proc,
            "plugins/tools/package.json",
            line_of(patch_package_manifest, '"patch-package"'),
            "patch-package",
        )


class ModulesTests(CheckerFixture):
    def source_files(self, gateway_files=None):
        files = {}
        for module in MODULES + [CORE_MODULE]:
            files[f"Sources/{module}/File.swift"] = (
                "// SPDX-License-Identifier: MIT\ntypealias Placeholder = Int\n"
            )
        if gateway_files:
            files.update(gateway_files)
        return files

    def test_passing_tree(self):
        files = self.source_files()
        files["Package.swift"] = package_text(
            loopback_test_dependencies='"PhoneDSHWire", "PhoneDSHAgentCore"')
        tree = self.make_tree(files)
        self.assert_pass(self.run_checker("modules", tree))

    def test_failing_tree(self):
        fail_text = package_text(
            gateway_dependencies='"PhoneDSHAgentCore", "XiaozhiLinkProviders", "PhoneDSHController"',
            wire_dependencies='"XiaozhiLinkToolboxCore"',
            engine_has_tests=False,
            include_xz_shell=False,
            loopback_test_dependencies='"PhoneDSHAgentCore", "XiaozhiLinkExecBridge"',
        )
        files = self.source_files(
            {
                "Sources/PhoneDSHGateway/UI.swift": (
                    "@MainActor\nfinal class UI {}\n"
                )
            }
        )
        files["Package.swift"] = fail_text
        tree = self.make_tree(files)
        proc = self.run_checker("modules", tree)
        self.assert_finding(proc, "Package.swift", 1, "module-missing")
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(fail_text, '"XiaozhiLinkToolboxCore"'),
            "forbidden-dependency",
        )
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(fail_text, '"XiaozhiLinkToolboxCore"'),
            "module-dependency",
        )
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(
                fail_text,
                'dependencies: ["PhoneDSHAgentCore", "XiaozhiLinkProviders", "PhoneDSHController"]',
            ),
            "module-dependency",
        )
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(
                fail_text,
                'dependencies: ["PhoneDSHAgentCore", "XiaozhiLinkProviders", "PhoneDSHController"]',
            ),
            "agentcore-boundary",
        )
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(fail_text, '"XiaozhiLinkExecBridge"'),
            "agentcore-boundary",
        )
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(fail_text, 'Module(name: "PhoneDSHEngine"'),
            "test-target",
        )
        self.assert_finding(
            proc,
            "Sources/PhoneDSHGateway/UI.swift",
            1,
            "main-actor",
        )

    def test_phone_test_targets_must_use_agent_core(self):
        text = package_text(
            loopback_test_dependencies=(
                '"PhoneDSHAgentCore", "XiaozhiLinkProviders", '
                '"XiaozhiLinkExecBridge", "XiaozhiLinkToolboxCore"'
            )
        )
        files = self.source_files()
        files["Package.swift"] = text
        tree = self.make_tree(files)
        proc = self.run_checker("modules", tree)
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(text, '"XiaozhiLinkProviders"'),
            "agentcore-boundary",
        )
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(text, '"XiaozhiLinkExecBridge"'),
            "agentcore-boundary",
        )
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(text, '"XiaozhiLinkToolboxCore"'),
            "forbidden-dependency",
        )

    def test_agent_core_must_stay_foundation_only(self):
        core_text = package_text(agent_core_dependencies='"PhoneDSHWire"')
        files = self.source_files()
        files["Package.swift"] = core_text
        tree = self.make_tree(files)
        proc = self.run_checker("modules", tree)
        self.assert_finding(
            proc,
            "Package.swift",
            line_of(core_text, 'Module(name: "PhoneDSHAgentCore", dependencies: ["PhoneDSHWire"])'),
            "core-dependency",
        )

    def test_missing_agent_core_module(self):
        text = package_text().replace(
            f'    Module(name: "{CORE_MODULE}"),\n', ""
        )
        files = self.source_files()
        files["Package.swift"] = text
        tree = self.make_tree(files)
        proc = self.run_checker("modules", tree)
        self.assert_finding(proc, "Package.swift", 1, "module-missing")


class ProductionScanTests(unittest.TestCase):
    def run_production(self, *extra):
        return subprocess.run(
            [PYTHON, str(CHECKERS["hygiene"]), "--root", str(REPO_ROOT), *extra],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=180,
        )

    def test_production_scan_does_not_descend_into_generated_dirs(self):
        listing = self.run_production("--list-files")
        self.assertEqual(
            listing.returncode,
            0,
            f"stdout:\n{listing.stdout}\nstderr:\n{listing.stderr}",
        )
        paths = [line for line in listing.stdout.splitlines() if line]
        self.assertTrue(paths, "the production file set must not be empty")
        for rel in paths:
            self.assertNotIn("/node_modules/", "/" + rel)
            self.assertFalse(rel.startswith("node_modules/"))
            self.assertFalse(rel.startswith("scripts/ci/fixtures/"))
            self.assertTrue(rel != "scripts/ci/hygiene-allow.txt")
            for name in (
                "common.py",
                "hygiene.py",
                "license.py",
                "modules.py",
                "no_dsh_patch.py",
                "selftest.py",
                "gates_test.py",
            ):
                self.assertNotEqual(rel, "scripts/ci/" + name)

        probe = self.run_production()
        self.assertEqual(
            probe.returncode,
            0,
            f"stdout:\n{probe.stdout}\nstderr:\n{probe.stderr}",
        )
        self.assertNotIn("fixtures/", probe.stdout)
        self.assertNotIn("node_modules", probe.stdout)

    def test_extracted_layout_sources_tests_and_plugin_manifests_are_scanned(self):
        with tempfile.TemporaryDirectory(prefix="pdsh-extracted-layout-") as temp:
            root = Path(temp)
            paths = (
                "Sources/PhoneDSHAgentCore/Agent.swift",
                "Sources/PhoneDSHScenario/Scenario.swift",
                "Tests/PhoneDSHProbeTests/Probe.swift",
                "Tests/PhoneDSHKillTests/Kill.swift",
                "Tests/PhoneDSHScenarioTests/Scenario.swift",
                "Tests/PhoneDSHSmokeTests/Smoke.swift",
                "scripts/ci/contract.py",
            )
            for rel in paths:
                path = root / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("import Foundation\n", encoding="utf-8")
            manifest = root / "plugins/channel/package.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(
                '{"name":"channel","license":"Apache-2.0"}\n',
                encoding="utf-8",
            )
            subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
            subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)

            scanned = set(common.scan_files(root))
            self.assertTrue(set(paths).issubset(scanned))
            self.assertIn("plugins/channel/package.json", scanned)
            result = subprocess.run(
                [PYTHON, str(CHECKERS["license"]), "--root", str(root)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            for rel in paths:
                self.assertIn(f"{rel}:1: license:", result.stdout)
            self.assertIn(
                "plugins/channel/package.json:1: package-license:", result.stdout
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
