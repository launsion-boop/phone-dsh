#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for spec/tools/cross_check.py.

Every invariant gets a passing fixture and at least one mutation that must
turn it red.  The tests never touch the repository tree; each test builds a
minimal spec/ tree under a temporary directory.
"""

import contextlib
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cross_check  # noqa: E402

LABELS = {
    "bubble": "气泡",
    "toolRow": "工具行",
    "thinkingPill": "thinking_pill",
    "approvalCard": "审批卡",
    "composer": "composer",
    "failLoudBanner": "fail-loud 横幅",
}
KEBAB = {
    "bubble": "bubble",
    "toolRow": "tool-row",
    "thinkingPill": "thinking-pill",
    "approvalCard": "approval-card",
    "composer": "composer",
    "failLoudBanner": "fail-loud-banner",
}


class Fixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "spec").mkdir()
        self.addCleanup(self._tmp.cleanup)

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def write_json(self, rel, value):
        return self.write(rel, json.dumps(value, ensure_ascii=False, indent=2) + "\n")

    def assert_ok(self, result):
        self.assertTrue(result.ok, "\n".join(result.details))

    def assert_fail(self, result, needle=None):
        self.assertFalse(result.ok)
        if needle is not None:
            self.assertIn(needle, "\n".join(result.details))


class ReferenceTests(Fixture):
    def setUp(self):
        super().setUp()
        self.write("spec/README.md", "# Protocol baseline\n")
        self.write("AGENTS.md", "# Collaboration\n")
        self.write("CLAUDE.md", "@AGENTS.md\n")

    def test_reachable_reference_and_placeholder(self):
        self.write("spec/a/README.md", "See spec/a/b.md and spec/v1/file.md.\n")
        self.write("spec/a/b.md", "b\n")
        self.assert_ok(cross_check.check_references(self.root))

    def test_missing_reference_fails_with_location(self):
        self.write("spec/a/README.md", "See spec/a/missing.md.\n")
        result = cross_check.check_references(self.root)
        self.assert_fail(result, "spec/a/README.md:1 -> spec/a/missing.md")

    def test_json_reference_is_scanned(self):
        self.write_json("spec/a/meta.json", {"ref": "spec/a/missing.json"})
        self.assert_fail(cross_check.check_references(self.root), "missing.json")

    def test_jsonl_reference_keeps_its_extension(self):
        # A greedy `spec/...` match plus a bare `json` alternative used to
        # rewrite `expected.jsonl` into `expected.json`, so this reference was
        # reported missing even though the file is right there.
        self.write("spec/a/README.md", "See spec/a/expected.jsonl.\n")
        self.write("spec/a/expected.jsonl", '{"line": 1}\n')
        result = cross_check.check_references(self.root)
        self.assert_ok(result)
        self.assertIn("1 references", result.summary)

    def test_missing_jsonl_reference_names_the_jsonl_file(self):
        self.write("spec/a/README.md", "See spec/a/events.jsonl:2 and spec/a/notes.json.\n")
        self.write("spec/a/notes.json", "{}\n")
        self.assert_fail(
            cross_check.check_references(self.root),
            "spec/a/README.md:1 -> spec/a/events.jsonl (missing)",
        )

    def test_reference_extension_set_is_exact(self):
        text = (
            "spec/a/one.jsonl:2 spec/a/two.json "
            "spec/a/three.md spec/a/four.py spec/a/five.jsonnet"
        )
        # `.jsonnet` is not a spec reference kind: the lookahead refuses to
        # truncate it to `five.json` (the same truncation that `.jsonl`
        # suffered).  An unknown extension is left alone, never half-matched.
        self.assertEqual(
            [match.group(0) for match in cross_check.REF_RE.finditer(text)],
            [
                "spec/a/one.jsonl",
                "spec/a/two.json",
                "spec/a/three.md",
                "spec/a/four.py",
            ],
        )

    def test_baseline_links_resolve_sources_tests_and_directories(self):
        self.write("Sources/wire.ts", "// wire\n")
        (self.root / "Tests").mkdir()
        self.write("spec/README.md", "[source](../Sources/wire.ts) [tests](../Tests/)\n")
        self.write("AGENTS.md", "[baseline](spec/README.md#rules)\n")
        self.assert_ok(cross_check.check_references(self.root))

    def test_stale_baseline_source_link_fails(self):
        self.write("spec/README.md", "[source](../Sources/deleted.ts)\n")
        self.assert_fail(cross_check.check_references(self.root), "missing baseline link")

    def test_baseline_links_accept_titles_and_angle_destinations(self):
        self.write("Sources/wire.ts", "// wire\n")
        self.write("Sources/wire notes.md", "notes\n")
        self.write("spec/README.md", '[wire](../Sources/wire.ts "source") '
                   '[notes](<../Sources/wire notes.md> "details")\n')
        self.assert_ok(cross_check.check_references(self.root))

    def test_baseline_link_cannot_escape_repo(self):
        self.write("spec/README.md", "[outside](../../outside.md)\n")
        self.assert_fail(cross_check.check_references(self.root), "escapes the repository")

    def test_baseline_symlink_target_cannot_escape_repo(self):
        (self.root / "outside").symlink_to(self.root.parent, target_is_directory=True)
        self.write("spec/README.md", "[outside](../outside/)\n")
        self.assert_fail(cross_check.check_references(self.root), "escapes the repository")

    def test_external_urls_and_local_anchors_are_not_fetched(self):
        self.write("spec/README.md", "[source](https://example.invalid/a) [section](#rules)\n")
        self.assert_ok(cross_check.check_references(self.root))

    def test_missing_baseline_entrypoint_fails(self):
        (self.root / "spec/README.md").unlink()
        self.assert_fail(cross_check.check_references(self.root), "missing or unreadable baseline")

    def test_copied_claude_rules_fail_even_if_content_is_identical(self):
        (self.root / "CLAUDE.md").unlink()
        self.write("CLAUDE.md", (self.root / "AGENTS.md").read_text())
        self.assert_fail(cross_check.check_references(self.root), "first nonempty line must be @AGENTS.md")


    def test_claude_import_allows_initial_blank_lines(self):
        self.write("CLAUDE.md", "\n\n@AGENTS.md\n")
        self.assert_ok(cross_check.check_references(self.root))

    def test_claude_symlink_is_rejected(self):
        (self.root / "CLAUDE.md").unlink()
        self.write("import.md", "@AGENTS.md\n")
        (self.root / "CLAUDE.md").symlink_to("import.md")
        self.assert_fail(cross_check.check_references(self.root), "must be a regular file")

    def test_missing_or_empty_claude_fails(self):
        (self.root / "CLAUDE.md").unlink()
        self.assert_fail(cross_check.check_references(self.root), "must be a regular file")
        self.write("CLAUDE.md", "\n")
        self.assert_fail(cross_check.check_references(self.root), "first nonempty line")


class PlatformContractTests(Fixture):
    def whitelist(self):
        self.write_json("spec/platform/whitelist.json", [{
            "id": "platform.example",
            "capability": "example.capability",
            "spec_ref": "spec/v1/a.md §1",
        }])
        self.write("spec/v1/a.md", "# a\n")

    def test_entries_and_references_resolve(self):
        self.whitelist()
        self.write("spec/host/v1/README.md", "mentions platform.example\n")
        self.assert_ok(cross_check.check_platform_contract(self.root))

    def test_unknown_platform_mention_fails(self):
        self.whitelist()
        self.write("spec/ui/v1/README.md", "mentions platform.typo\n")
        self.assert_fail(
            cross_check.check_platform_contract(self.root),
            "unknown platform id 'platform.typo'",
        )

    def test_missing_spec_ref_fails(self):
        self.whitelist()
        (self.root / "spec/v1/a.md").unlink()
        self.assert_fail(
            cross_check.check_platform_contract(self.root),
            "spec_ref target is missing",
        )


class BridgeRegistryTests(Fixture):
    def bridge(self, methods=("a.b", "c.d")):
        rows = ["| `{}` | page→host | request | x |".format(method) for method in methods]
        self.write(
            "spec/v1/bridge.md",
            "# bridge\n\n## 11. Method registry\n\n"
            "| Method | Direction | Kind | Status |\n"
            "| --- | --- | --- | --- |\n"
            + "\n".join(rows)
            + "\n\n## 12. Status\n",
        )

    def golden(self, name, method, error=None):
        envelope = {"v": 1, "kind": "request", "method": method}
        if error is not None:
            envelope["kind"] = "error"
            envelope["error"] = {"code": error}
        self.write_json(
            "spec/v1/golden/bridge/{}.json".format(name),
            {"name": name, "instance": envelope},
        )

    def test_registry_and_goldens_agree_including_negative_vector(self):
        self.bridge()
        self.golden("a", "a.b")
        self.golden("c", "c.d")
        self.golden("unknown", "z.z", error="BRIDGE_METHOD_UNKNOWN")
        self.assert_ok(cross_check.check_bridge_registry(self.root))

    def test_registry_method_without_golden_fails(self):
        self.bridge()
        self.golden("a", "a.b")
        self.assert_fail(
            cross_check.check_bridge_registry(self.root),
            "registry method 'c.d' has no non-negative golden",
        )

    def test_golden_method_outside_registry_fails(self):
        self.bridge()
        self.golden("a", "a.b")
        self.golden("c", "c.d")
        self.golden("extra", "z.z")
        self.assert_fail(
            cross_check.check_bridge_registry(self.root),
            "golden method 'z.z' is absent from the registry",
        )

    def test_negative_vector_must_stay_unregistered(self):
        self.bridge(("a.b", "c.d", "z.z"))
        self.golden("a", "a.b")
        self.golden("c", "c.d")
        self.golden("unknown", "z.z", error="BRIDGE_METHOD_UNKNOWN")
        self.assert_fail(
            cross_check.check_bridge_registry(self.root),
            "negative vector carries registered method 'z.z'",
        )


class EventKindTests(Fixture):
    HOST_KINDS = ("assistant_message", "tool_call", "turn_ended")
    ROWS = (
        '{"type":"assistant/message"}',
        '{"type":"tool/call"}',
        '{"type":"turn/end"}',
        '{"type":"permission/result"}',
    )

    def host(self, kinds=None):
        kinds = kinds or self.HOST_KINDS
        schema = {"oneOf": [
            {"properties": {"kind": {"const": kind}}} for kind in kinds
        ]}
        self.write_json("spec/host/v1/schema/harness-event.schema.json", schema)

    def event_kinds(self):
        self.write(
            "spec/host/v1/event-kinds.md",
            "# Event kinds\n\n"
            "## 1. Mapping table\n\n"
            "| host kind | projection type | golden | producer |\n"
            "|---|---|---|---|\n"
            "| `assistant_message` | `assistant/message` | yes | `AM:82-88` |\n"
            "| `tool_call` | `tool/call` | yes | `AM:89-93` |\n"
            "| `turn_ended` | `turn/end` | yes | `AM:76-79` |\n\n"
            "### 1.1 Declared, not projected\n\n"
            "| type | class | reason |\n"
            "|---|---|---|\n"
            "| `metric/sample` | authoring type | dropped whole |\n\n"
            "## 2. Synthetic types\n\n"
            "| synthetic type | projected from | rule |\n"
            "|---|---|---|\n"
            "| `llm/retry` | `progress` | phase marker |\n"
            "| `compaction/*` | `progress` | phase marker |\n"
            "| `permission/result` | `permission_requested` | client ack |\n\n"
            "## 3. Projection rules\n\n"
            "Unknown authoring types are dropped.\n",
        )

    def trajectory(self, doc="Rows whose type is `metric/sample` are dropped whole.\n",
                   rows=None):
        self.write("spec/v1/trajectory.md", doc)
        self.write("spec/v1/schema/trajectory.schema.json", "{}\n")
        self.write(
            "spec/v1/golden/trajectory/case/expected.jsonl",
            "\n".join(self.ROWS if rows is None else rows) + "\n",
        )

    def ui(self, extra=""):
        self.write(
            "spec/ui/v1/README.md",
            "# UI\n\n## 3. 交互状态机\n\n"
            "| Event | From | To | Side effect |\n"
            "|---|---|---|---|\n"
            "| `assistant_message` | running | running | x |\n"
            "| `llm/retry*` | running | running | x |\n"
            "| `compaction/*` | running | running | x |\n"
            + extra
            + "\n## 4. 签名面\n",
        )

    def build(self):
        self.host()
        self.event_kinds()
        self.trajectory()
        self.ui()

    def rewrite(self, rel, old, new):
        path = self.root / rel
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def test_three_vocabularies_close(self):
        self.build()
        self.assert_ok(cross_check.check_event_kinds(self.root))

    def test_mapping_table_misses_a_host_kind(self):
        self.build()
        self.rewrite("spec/host/v1/event-kinds.md",
                     "| `tool_call` | `tool/call` | yes | `AM:89-93` |\n", "")
        self.assert_fail(
            cross_check.check_event_kinds(self.root),
            "mapping table misses host kind 'tool_call'",
        )

    def test_mapping_table_invents_a_host_kind(self):
        self.build()
        self.rewrite("spec/host/v1/event-kinds.md",
                     "| `turn_ended` | `turn/end` | yes | `AM:76-79` |\n",
                     "| `turn_ended` | `turn/end` | yes | `AM:76-79` |\n"
                     "| `user_message` | `user/message` | no | `AM:62-66` |\n")
        self.assert_fail(
            cross_check.check_event_kinds(self.root),
            "mapping table declares unknown host kind 'user_message'",
        )

    def test_fixture_type_outside_the_table_fails(self):
        self.build()
        self.trajectory(rows=self.ROWS + ('{"type":"invented/event"}',))
        self.assert_fail(
            cross_check.check_event_kinds(self.root),
            "fixture event type 'invented/event' is not covered",
        )

    def test_ui_event_outside_the_table_fails(self):
        self.build()
        self.ui(extra="| `turn/started` | running | running | x |\n")
        self.assert_fail(
            cross_check.check_event_kinds(self.root),
            "state-machine event 'turn/started' is not covered",
        )

    def test_declared_trajectory_type_outside_the_table_fails(self):
        self.build()
        self.trajectory(
            doc="Rows whose type is `metric/sample` are dropped. Also `invented/type`.\n")
        self.assert_fail(
            cross_check.check_event_kinds(self.root),
            "declared event type 'invented/type' is not covered",
        )


class SignatureSurfaceTests(Fixture):
    def build(self):
        surfaces = {}
        rows = []
        for index, surface in enumerate(cross_check.SIGNATURE_SURFACES):
            token = "colors.token{}".format(index)
            geometry = "geometry{}".format(index)
            surfaces[surface] = {"tokens": [token, "geometry." + geometry]}
            rows.append("| {} | `{}` | `{}` |".format(LABELS[surface], token, geometry))
        self.write_json("spec/ui/v1/tokens.json", {"signatureSurfaces": surfaces})
        self.write(
            "spec/ui/v1/README.md",
            "## 4. 签名面\n\n"
            "| 签名面 | 颜色 / 字号 / 圆角 / 描边 / 动效 | 页面层几何（`geometry.*`） |\n"
            "|---|---|---|\n"
            + "\n".join(rows)
            + "\n\n## 5. 平台差异\n",
        )
        self.write(
            "spec/v1/trajectory.md",
            "Pixel equality is required only for the six signature surfaces — "
            + ", ".join("`{}`".format(KEBAB[name]) for name in cross_check.SIGNATURE_SURFACES)
            + " — and is judged from a screenshot.\n",
        )

    def test_three_documents_agree(self):
        self.build()
        self.assert_ok(cross_check.check_signature_surfaces(self.root))

    def test_unknown_readme_label_fails(self):
        self.build()
        path = self.root / "spec/ui/v1/README.md"
        path.write_text(path.read_text(encoding="utf-8").replace("| 气泡 |", "| 泡 |"),
                        encoding="utf-8")
        self.assert_fail(
            cross_check.check_signature_surfaces(self.root),
            "unknown signature-surface label",
        )

    def test_missing_trajectory_surface_fails(self):
        self.build()
        path = self.root / "spec/v1/trajectory.md"
        path.write_text(path.read_text(encoding="utf-8").replace("`fail-loud-banner`", ""),
                        encoding="utf-8")
        self.assert_fail(
            cross_check.check_signature_surfaces(self.root),
            "surface 'failLoudBanner' is missing",
        )

    def test_token_composition_drift_fails(self):
        self.build()
        tokens = json.loads((self.root / "spec/ui/v1/tokens.json").read_text(encoding="utf-8"))
        tokens["signatureSurfaces"]["toolRow"]["tokens"].append("colors.extra")
        self.write_json("spec/ui/v1/tokens.json", tokens)
        self.assert_fail(
            cross_check.check_signature_surfaces(self.root),
            "surface 'toolRow' omits token 'colors.extra'",
        )


class CapabilityTests(Fixture):
    def build(self, capability="render.pixel"):
        self.write_json(
            "spec/host/v1/schema/device-capabilities.schema.json",
            {"properties": {"capabilities": {"properties": {
                "render.pixel": {},
                "display.text": {},
                "vehicle.*": {},
            }}}},
        )
        self.write_json(
            "spec/host/v1/golden/device-capabilities-test.json",
            {"name": "test", "instance": {"capabilities": {capability: {}}}},
        )

    def test_declared_capability_passes(self):
        self.build()
        self.assert_ok(cross_check.check_capabilities(self.root))

    def test_undeclared_capability_fails(self):
        self.build("render.pixl")
        self.assert_fail(
            cross_check.check_capabilities(self.root),
            "capability 'render.pixl' is not declared",
        )

    def test_vendor_wildcard_is_accepted(self):
        self.build("vehicle.state")
        self.assert_ok(cross_check.check_capabilities(self.root))


class FixtureCoverageTests(Fixture):
    def reader(self, pattern="*.json", recursive=False):
        self.write("spec/x/tools/check.py", "PATTERN = {!r}\n".format(pattern))
        return cross_check.GoldenReader("spec/x/golden", pattern, "spec/x/tools/check.py",
                                        recursive)

    def test_covered_file_passes(self):
        self.write("spec/x/golden/a.json", "{}\n")
        self.assert_ok(cross_check.check_fixture_coverage(self.root, [self.reader()]))

    def test_orphan_file_fails(self):
        self.write("spec/x/golden/a.json", "{}\n")
        self.write("spec/x/golden/sub/b.json", "{}\n")
        self.assert_fail(
            cross_check.check_fixture_coverage(self.root, [self.reader()]),
            "orphan golden",
        )

    def test_empty_glob_fails(self):
        (self.root / "spec/x/golden").mkdir(parents=True)
        self.assert_fail(
            cross_check.check_fixture_coverage(self.root, [self.reader()]),
            "is empty",
        )

    def test_checker_without_pattern_fails(self):
        self.write("spec/x/golden/a.json", "{}\n")
        reader = self.reader()
        self.write("spec/x/tools/check.py", "PATTERN = 'something else'\n")
        self.assert_fail(
            cross_check.check_fixture_coverage(self.root, [reader]),
            "does not contain the glob",
        )

    def test_recursive_notes_pattern_passes(self):
        self.write("spec/x/golden/case/notes.json", "{}\n")
        self.assert_ok(cross_check.check_fixture_coverage(
            self.root, [self.reader("notes.json", recursive=True)]))


class SchemaBasenameTests(Fixture):
    def test_unique_basenames_pass(self):
        self.write_json("spec/a/schema/one.schema.json", {})
        self.write_json("spec/b/schema/two.schema.json", {})
        self.assert_ok(cross_check.check_schema_basenames(self.root))

    def test_duplicate_basename_fails(self):
        self.write_json("spec/a/schema/same.schema.json", {})
        self.write_json("spec/b/schema/same.schema.json", {})
        self.assert_fail(
            cross_check.check_schema_basenames(self.root),
            "duplicate schema basename 'same.schema.json'",
        )


class OutputTests(Fixture):
    def test_main_always_prints_eight_invariants(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = cross_check.main(["--root", str(self.root)])
        text = output.getvalue()
        self.assertEqual(len(re.findall(r"^\[\d/8\]", text, re.M)), 8)
        self.assertIn(code, (0, 1))

    def test_missing_spec_root_is_a_usage_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cross_check.main(["--root", str(self.root / "nope")]), 2)


if __name__ == "__main__":
    unittest.main()
