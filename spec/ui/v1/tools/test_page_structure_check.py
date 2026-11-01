#!/usr/bin/env python3
"""Mutation tests for `page_structure_check.py`.

Purpose: a gate nobody mutates is a gate nobody trusts. Each test builds a tiny
fixture tree (contract + iOS provenance lines + an Android page), then proves that
the checker is green when the two agree and red for every way they disagree:

* a section deleted from the Android page (the contract's title goes missing);
* a section added to the Android page (no contract title backs it);
* an action renamed;
* an accepted platform-forced difference (whitelist) and a whitelist that has gone
  stale or points at an unknown `spec/platform/whitelist.json` id;
* the known-divergence ratchet: a baselined divergence passes, a new one fails, a
  baseline entry that no longer diverges fails;
* a stale contract provenance line (the anchor moved) — never ratcheted.

Run:
    python3 -m unittest discover -s spec/ui/v1/tools -p 'test_*.py' -v
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import page_structure_check as check  # noqa: E402

PAGE_ID = "fake"
PAGE = "FakePage"
SWIFT_REL = "examples/probe-app/PhoneDSHProbe/FakePage.swift"
ANDROID_REL = "android/lib/src/main/kotlin/com/phonedsh/ui/page/FakePage.kt"
UISTRINGS_REL = "android/lib/src/main/kotlin/com/phonedsh/ui/UiStrings.kt"
PLATFORM_REL = "spec/platform/whitelist.json"
WHITELIST_REL = "spec/ui/v1/pages/_whitelist.json"
CONTRACT_REL = "spec/ui/v1/pages/fake.json"

SWIFT = """import SwiftUI
struct FakePage: View { var body: some View {
        Section("Alpha") {
            Button("Go") { open() }
        }
        Section("Beta") {
            Text("hi")
        }
} }
"""

ANDROID = """package com.phonedsh.ui.page

public fun FakePage() {
    SessionSectionLabel(text = UiStrings.ALPHA)
    SessionSectionLabel(text = UiStrings.BETA)
    SessionTextAction(label = UiStrings.GO, onClick = {})
}
"""

UISTRINGS = """package com.phonedsh.ui

public object UiStrings {
    public const val ALPHA: String = "Alpha"
    public const val BETA: String = "Beta"
    public const val GO: String = "Go"
}
"""


def contract() -> dict:
    # Line numbers are 1-based and must match SWIFT above.
    return {
        "schema": "pdsh.ui.page-structure/1",
        "page": PAGE,
        "pageId": PAGE_ID,
        "structure": "swiftui-view",
        "sectionModel": "section",
        "source": {"file": "FakePage.swift", "path": SWIFT_REL, "lines": 9, "structLine": 2,
                   "renderedFrom": ["body"]},
        "android": {"screen": PAGE, "file": ANDROID_REL, "match": "composable"},
        "sections": [
            {"id": "alpha", "title": "Alpha", "titleTemplate": None, "titleSource": "literal",
             "condition": None, "collection": None, "rows": [], "provenance": "FakePage.swift:3",
             "anchor": 'Section("Alpha") {', "extraction": "syntax"},
            {"id": "beta", "title": "Beta", "titleTemplate": None, "titleSource": "literal",
             "condition": None, "collection": None, "rows": [], "provenance": "FakePage.swift:6",
             "anchor": 'Section("Beta") {', "extraction": "syntax"},
        ],
        "actions": [
            {"id": "go", "label": "Go", "kind": "button", "trigger": "tap", "semantic": None,
             "writes": True, "destination": None, "condition": None, "provenance": "FakePage.swift:4",
             "anchor": 'Button("Go") { open() }', "extraction": "syntax"},
        ],
        "presentations": [],
        "states": {"advisory": True, "sites": {}, "absent": [], "coverage": {}},
        "subpages": [],
        "unreachable": [],
        "extraction": {"tool": "extract_ios_pages.py", "mode": "syntax",
                       "sectionKeywordsInPage": 2, "sectionsExtracted": 2, "warnings": []},
    }


def whitelist(entries=None) -> dict:
    return {
        "schema": "pdsh.ui.page-structure-whitelist/1",
        "note": "fixture",
        "entries": entries or [],
    }


def platform_whitelist() -> list:
    return [{"id": "platform.post-notifications-degraded", "capability": "notifier.permission-degraded"}]


class Fixture:
    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self._write(SWIFT_REL, SWIFT)
        self._write(ANDROID_REL, ANDROID)
        self._write(UISTRINGS_REL, UISTRINGS)
        self._write(PLATFORM_REL, json.dumps(platform_whitelist(), ensure_ascii=False))
        self._write(WHITELIST_REL, json.dumps(whitelist(), ensure_ascii=False))
        self.write_contract(contract())

    def _write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def write_contract(self, data: dict) -> None:
        self._write(CONTRACT_REL, json.dumps(data, ensure_ascii=False, indent=2))

    def write_android(self, text: str) -> None:
        self._write(ANDROID_REL, text)

    def android(self) -> str:
        return (self.root / ANDROID_REL).read_text(encoding="utf-8")

    def write_whitelist(self, entries: list) -> None:
        self._write(WHITELIST_REL, json.dumps(whitelist(entries), ensure_ascii=False))

    def write_swift(self, text: str) -> None:
        self._write(SWIFT_REL, text)

    def close(self) -> None:
        self.tmp.cleanup()


def run_check(root: Path, **kwargs) -> tuple:
    """`check.run` with the CLI's error handling: a CheckError is exit code 1."""
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            rc = check.run(root, strict=kwargs.get("strict", True),
                           baseline_path=kwargs.get("baseline_path"),
                           write_baseline=kwargs.get("write_baseline"),
                           only_page=None, verbose=True)
    except check.CheckError as exc:
        return 1, out.getvalue() + f"FAIL  {exc}"
    return rc, out.getvalue()


class PageStructureCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fx = Fixture()

    def tearDown(self) -> None:
        self.fx.close()

    # -- the green path ----------------------------------------------------

    def test_matching_page_passes(self) -> None:
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("ok (0 divergences", out)

    # -- the red paths the task calls out ----------------------------------

    def test_deleted_section_is_red(self) -> None:
        text = self.fx.android().replace("    SessionSectionLabel(text = UiStrings.BETA)\n", "")
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("missing-section", out)
        self.assertIn("'Beta'", out)

    def test_added_section_is_red(self) -> None:
        text = self.fx.android().replace(
            "    SessionSectionLabel(text = UiStrings.BETA)\n",
            "    SessionSectionLabel(text = UiStrings.BETA)\n    SessionSectionLabel(text = \"Gamma\")\n")
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("extra-section", out)
        self.assertIn("'Gamma'", out)

    def test_renamed_action_is_red(self) -> None:
        text = self.fx.android().replace("UiStrings.GO", "UiStrings.ALPHA")
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("missing-action", out)
        self.assertIn("'Go'", out)

    def test_untitled_section_uses_its_criterion_not_a_title(self) -> None:
        data = contract()
        data["sections"][1]["title"] = None
        data["sections"][1]["criterion"] = {"kind": "first-row", "label": "Beta",
                                            "provenance": "FakePage.swift:6"}
        self.fx.write_contract(data)
        text = self.fx.android().replace("    SessionSectionLabel(text = UiStrings.BETA)\n",
                                         '    Row {\n        Text(text = "Beta")\n    }\n')
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root)
        # No header before the criterion row: the baseline's untitled group is matched.
        self.assertEqual(rc, 0, out)

    # -- templates and normalisation ---------------------------------------

    def test_template_titles_match_numeric_labels(self) -> None:
        data = contract()
        data["sections"][0]["title"] = "Alpha N 个"
        data["sections"][0]["titleTemplate"] = "Alpha {count} 个"
        data["sections"][0]["dynamicTitle"] = True
        self.fx.write_contract(data)
        text = self.fx.android().replace("text = UiStrings.ALPHA)", 'text = "Alpha %d 个")')
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    # -- standard Compose controls -----------------------------------------

    def _compose_page(self, body: str) -> None:
        # Keep the two section labels the fixture contract expects; each test only
        # replaces the action part of the page.
        self.fx.write_android("package com.phonedsh.ui.page\n\npublic fun FakePage() {\n"
                              "    SessionSectionLabel(text = UiStrings.ALPHA)\n"
                              "    SessionSectionLabel(text = UiStrings.BETA)\n"
                              + body + "\n}\n")

    def _actions(self, *labels: str) -> None:
        data = contract()
        data["actions"] = [
            {"id": f"a{i}", "label": label, "kind": "button", "trigger": "tap", "semantic": None,
             "writes": True, "destination": None, "condition": None,
             "provenance": "FakePage.swift:4", "anchor": 'Button("Go") { open() }', "extraction": "syntax"}
            for i, label in enumerate(labels)
        ]
        self.fx.write_contract(data)

    def test_material_button_label_is_seen(self) -> None:
        self._actions("运行")
        self._compose_page('    Button(onClick = {}) {\n        Text(text = "运行")\n    }')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_material_button_without_label_is_missing(self) -> None:
        self._actions("运行")
        self._compose_page("    Button(onClick = {}) {\n    }")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("missing-action", out)
        self.assertIn("'运行'", out)

    def test_material_button_with_variable_label_is_unresolved(self) -> None:
        self._actions("运行")
        self._compose_page("    Button(onClick = {}) {\n        Text(text = state.label)\n    }")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("unresolved-action", out)
        self.assertIn("state.label", out)

    def test_button_takes_only_the_first_text(self) -> None:
        self._actions("标题")
        self._compose_page('    Button(onClick = {}) {\n        Column {\n'
                           '            Text(text = "标题")\n            Text(text = "副标题")\n        }\n    }')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_switch_takes_the_nearest_text_in_the_same_row(self) -> None:
        self._actions("后台运行")
        self._compose_page('    Row {\n        Text(text = "后台运行")\n'
                           '        Switch(checked = true, onCheckedChange = {})\n    }\n'
                           '    Column {\n        Text(text = "无关文本")\n    }')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_switch_does_not_cross_into_a_sibling_block(self) -> None:
        self._actions("后台运行")
        self._compose_page('    Row {\n        Switch(checked = true, onCheckedChange = {})\n    }\n'
                           '    Column {\n        Text(text = "后台运行")\n    }')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("missing-action", out)

    def test_disabled_dropdown_item_is_not_an_action(self) -> None:
        self._actions("可用")
        self._compose_page('    DropdownMenu(expanded = true, onDismissRequest = {}) {\n'
                           '        DropdownMenuItem(text = { Text("不可用") }, onClick = {}, enabled = false)\n'
                           '        DropdownMenuItem(text = { Text("可用") }, onClick = {})\n    }')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("不可用", out)

    def test_button_wrapper_resolves_its_call_site_label(self) -> None:
        self._actions("运行")
        self._compose_page('    WrappedAction(label = "运行", onClick = {})\n'
                           '}\n\n@Composable\nprivate fun WrappedAction(label: String, onClick: () -> Unit) {\n'
                           '    Button(onClick = onClick) {\n        Text(text = label)\n    }')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("'label'", out)

    # -- untitled groups are judged by their criterion, never reported blindly --

    def _untitled(self, label: str = "权限", kind: str = "first-clickable-row") -> None:
        data = contract()
        data["sections"][0]["title"] = None
        data["sections"][0]["criterion"] = {"kind": kind, "label": label,
                                            "provenance": "FakePage.swift:3"}
        self.fx.write_contract(data)

    def _compose_untitled(self, head: str = "", row: str = 'Text(text = "权限")') -> None:
        self.fx.write_android(
            "package com.phonedsh.ui.page\n\npublic fun FakePage() {\n"
            + head
            + "\n    SessionSectionLabel(text = UiStrings.BETA)\n"
            + "    Row {\n        " + row + "\n    }\n"
            + "    SessionTextAction(label = UiStrings.GO, onClick = {})\n}\n")

    def test_criterion_matches_when_the_group_has_no_header(self) -> None:
        self._untitled()
        self._compose_untitled()
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_criterion_row_missing_is_missing_section(self) -> None:
        self._untitled("不存在的行")
        self._compose_untitled()
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("missing-section", out)
        self.assertIn("不存在的行", out)

    def test_header_added_for_an_untitled_group_is_extra(self) -> None:
        self._untitled()
        self._compose_untitled(head='    SectionHeader(title = "权限", expanded = true, onToggle = {})\n')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("extra-section", out)
        self.assertIn("'权限'", out)

    def test_criterion_without_a_literal_label_is_unresolved(self) -> None:
        self._untitled()
        data = contract()
        data["sections"][0]["title"] = None
        data["sections"][0]["criterion"] = {"kind": "first-row-expression", "labelExpr": "row.title",
                                            "provenance": "FakePage.swift:3"}
        self.fx.write_contract(data)
        self._compose_untitled(row="Text(text = row.title)")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("unresolved-section", out)
        self.assertIn("row.title", out)

    # -- contract schema: rendered titles and templates ---------------------

    def test_section_title_with_source_text_is_rejected(self) -> None:
        data = contract()
        data["sections"][0]["title"] = "Rows ({count})"
        data["sections"][0]["titleTemplate"] = "Rows ({count})"
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("contains source text", out)

    def test_untitled_section_without_criterion_is_rejected(self) -> None:
        data = contract()
        data["sections"][0]["title"] = None
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("no criterion", out)

    def test_template_title_matches_the_rendered_number(self) -> None:
        data = contract()
        data["sections"][0]["title"] = "Rows (N)"
        data["sections"][0]["titleTemplate"] = "Rows ({count})"
        data["sections"][0]["dynamicTitle"] = True
        self.fx.write_contract(data)
        text = self.fx.android().replace("text = UiStrings.ALPHA", 'text = "Rows (4)"')
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_android_literal_source_expression_is_flagged(self) -> None:
        data = contract()
        data["sections"][0]["title"] = "Rows (N)"
        data["sections"][0]["titleTemplate"] = "Rows ({count})"
        data["sections"][0]["dynamicTitle"] = True
        self.fx.write_contract(data)
        text = self.fx.android().replace("text = UiStrings.ALPHA", 'text = "Rows ({count})"')
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("extra-section", out)
        self.assertIn("renders a source expression", out)
        self.assertIn("missing-section", out)

    # -- schema: template title vs data-as-title ---------------------------

    def test_dynamic_title_without_template_is_rejected(self) -> None:
        data = contract()
        data["sections"][0]["dynamicTitle"] = True
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("dynamicTitle", out)
        self.assertIn("titleTemplate", out)

    def test_title_expression_needs_a_criterion(self) -> None:
        data = contract()
        data["sections"][0]["title"] = None
        data["sections"][0]["titleExpression"] = "folderName"
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("title:null + criterion", out)

    # -- registered non-comparable items -----------------------------------

    def _registry(self, entries: list) -> None:
        (self.fx.root / "spec/ui/v1/pages/_unrecognized.json").write_text(json.dumps({
            "schema": "pdsh.ui.page-structure-unrecognized/1", "note": "fixture",
            "entries": entries}, ensure_ascii=False), encoding="utf-8")

    def test_registered_item_is_not_a_divergence(self) -> None:
        data = contract()
        data["sections"][0]["title"] = None
        data["sections"][0]["criterion"] = {"kind": "first-row-expression", "labelExpr": "row.title",
                                            "provenance": "FakePage.swift:3"}
        self.fx.write_contract(data)
        self._compose_untitled(row="Text(text = row.title)")  # criterion has no literal label
        self._registry([{"page": "fake", "kind": "unresolved-section",
                         "name": "<untitled: row.title>", "reason": "fixture: runtime-only row",
                         "owner": "ui-contract", "reviewBy": "2099-01-01"}])
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("registered", out)

    def test_stale_registration_is_rejected(self) -> None:
        self._registry([{"page": "fake", "kind": "unresolved-section", "name": "nothing",
                         "reason": "fixture", "owner": "ui-contract", "reviewBy": "2099-01-01"}])
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("match no finding", out)

    # -- dead UI and single-region pages -----------------------------------

    def test_dead_ui_presentation_is_not_an_orphan(self) -> None:
        data = contract()
        data["presentations"] = [{
            "id": "sheet-9", "kind": "sheet", "title": None, "destination": "FakePage",
            "triggerBindings": ["showFake"], "triggered": False, "deadUi": True,
            "deadUiEvidence": "showFake is never assigned outside its declaration",
            "provenance": "FakePage.swift:2", "anchor": "struct FakePage: View { var body: some View {",
        }]
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("dead UI", out)

    def test_dead_ui_without_evidence_is_rejected(self) -> None:
        data = contract()
        data["presentations"] = [{
            "id": "sheet-9", "kind": "sheet", "title": None, "destination": "FakePage",
            "triggerBindings": ["showFake"], "triggered": False, "deadUi": True,
            "provenance": "FakePage.swift:2", "anchor": "struct FakePage: View { var body: some View {",
        }]
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("deadUiEvidence", out)

    def test_single_region_page_is_not_compared(self) -> None:
        data = contract()
        data["sectionModel"] = "single-region"
        data["sectionNote"] = "flat list, no group header"
        data["sections"] = [{"id": "single-region-1", "kind": "single-region", "title": None,
                             "titleTemplate": None, "dynamicTitle": False, "titleSource": "absent",
                             "condition": None, "collection": None, "rows": [],
                             "criterion": {"kind": "single-region"},
                             "provenance": "FakePage.swift:2",
                             "anchor": "struct FakePage: View { var body: some View {"}]
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("single region", out)

    # -- androidOnly items -------------------------------------------------

    def _android_only(self, **overrides) -> dict:
        item = {
            "id": "extra", "label": "重试", "labelExpr": None, "kind": "button", "trigger": "tap",
            "semantic": None, "writes": True, "destination": None, "condition": None,
            "extraction": "manual",
            "androidOnly": {
                "reason": {"baselineLacks": "iOS local read cannot fail",
                           "androidNeeds": "host snapshot across a process boundary can fail",
                           "withoutIt": "a failed read is a dead page"},
                "owner": "android-ui", "reviewBy": "2099-01-01",
            },
        }
        item.update(overrides)
        data = contract()
        data["actions"] = [item]
        self.fx.write_contract(data)
        self._compose_page('    SessionTextAction(label = "重试", onClick = {})')
        return data

    def test_android_only_item_is_listed_not_counted(self) -> None:
        self._android_only()
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("android-only items", out)
        self.assertIn("重试", out)

    def test_android_only_reason_must_answer_three_questions(self) -> None:
        self._android_only()
        data = contract()
        data["actions"] = [{
            "id": "extra", "label": "重试", "kind": "button", "trigger": "tap",
            "androidOnly": {"reason": {"baselineLacks": "x", "androidNeeds": "", "withoutIt": "z"},
                            "owner": "android-ui", "reviewBy": "2099-01-01"},
        }]
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("androidNeeds", out)

    def test_android_only_review_by_must_not_be_past(self) -> None:
        self._android_only()
        data = contract()
        data["actions"] = [{
            "id": "extra", "label": "重试", "kind": "button", "trigger": "tap",
            "androidOnly": {"reason": {"baselineLacks": "x", "androidNeeds": "y", "withoutIt": "z"},
                            "owner": "android-ui", "reviewBy": "2000-01-01"},
        }]
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("in the past", out)

    def test_android_only_item_must_still_exist_on_android(self) -> None:
        self._android_only()
        self._compose_page("    SessionTextAction(label = UiStrings.GO, onClick = {})")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("android-only-stale", out)

    # -- printf templates and data menu rows -------------------------------

    def test_printf_label_is_a_template_not_an_action(self) -> None:
        self._actions("Go")
        self._compose_page('    SessionTextAction(label = UiStrings.GO, onClick = {})\n'
                           '    SessionTextAction(label = "%d 项需要处理", onClick = {})')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("%d", out)

    def test_dropdown_item_with_dynamic_text_is_a_data_row(self) -> None:
        self._actions("Go")
        self._compose_page('    SessionTextAction(label = UiStrings.GO, onClick = {})\n'
                           '    DropdownMenuItem(text = { Text(row.title) }, onClick = {})')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("row.title", out)

    def test_dropdown_item_with_literal_text_is_an_action(self) -> None:
        self._actions("Go")
        self._compose_page('    SessionTextAction(label = UiStrings.GO, onClick = {})\n'
                           '    DropdownMenuItem(text = { Text("复制") }, onClick = {})')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("extra-action", out)
        self.assertIn("复制", out)

    # -- fold headers, dead presentations, subpage sections ----------------

    def _add_section_title(self, title: str, data: dict | None = None) -> dict:
        data = data or contract()
        data["sections"].append({
            "id": title.lower(), "title": title, "titleTemplate": None, "titleSource": "literal",
            "condition": None, "collection": None, "rows": [], "provenance": "FakePage.swift:6",
            "anchor": 'Section("Beta") {', "extraction": "syntax",
        })
        self.fx.write_contract(data)
        return data

    def test_section_header_fold_is_an_action_when_the_baseline_has_one(self) -> None:
        data = self._add_section_title("已归档")
        data["actions"] = [{"id": "archived", "label": "已归档", "kind": "button", "trigger": "tap",
                            "provenance": "FakePage.swift:4", "anchor": 'Button("Go") { open() }'}]
        self.fx.write_contract(data)
        self._compose_page('    SectionHeader(title = "已归档", expanded = true, onToggle = {})')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_a_plain_fold_header_is_not_an_extra_action(self) -> None:
        data = self._add_section_title("工具")
        data["actions"] = [{"id": "go", "label": "Go", "kind": "button", "trigger": "tap",
                            "provenance": "FakePage.swift:4", "anchor": 'Button("Go") { open() }'}]
        self.fx.write_contract(data)
        self._compose_page('    SectionHeader(title = "工具", expanded = true, onToggle = {})\n'
                           '    SessionTextAction(label = UiStrings.GO, onClick = {})')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_actions_inside_a_dead_presentation_are_not_judged(self) -> None:
        data = contract()
        data["actions"] = [{"id": "add", "label": "添加", "kind": "button", "trigger": "tap",
                            "deadPresentation": "alert-381", "provenance": "FakePage.swift:4",
                            "anchor": 'Button("Go") { open() }'}]
        data["presentations"] = [{"id": "alert-381", "kind": "alert", "title": None,
                                  "destination": None, "triggerBindings": ["showAdd"],
                                  "triggered": False, "deadUi": True,
                                  "deadUiEvidence": "showAdd is never assigned",
                                  "provenance": "FakePage.swift:2",
                                  "anchor": "struct FakePage: View { var body: some View {"}]
        self.fx.write_contract(data)
        self._compose_page("")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("dead UI", out)

    def test_subpage_sections_are_printed_not_compared(self) -> None:
        data = contract()
        data["actions"] = [{"id": "go", "label": "Go", "kind": "button", "trigger": "tap",
                            "provenance": "FakePage.swift:4", "anchor": 'Button("Go") { open() }'}]
        data["subpages"] = [{"name": "SessionQueuePage", "line": 9, "private": True,
                             "sections": [{"title": "错误", "provenance": "FakePage.swift:9"}],
                             "provenance": "FakePage.swift:9"}]
        self.fx.write_contract(data)
        self._compose_page('    SessionSectionLabel(text = "错误")\n'
                           '    SessionTextAction(label = UiStrings.GO, onClick = {})')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("subpages", out)
        self.assertIn("错误", out)

    # -- §1 entrance sources -----------------------------------------------

    def test_entrance_source_parsing(self) -> None:
        self.assertEqual(check.entrance_source("设置行"), ("settings", True))
        self.assertEqual(check.entrance_source("抽屉「定时任务」"), ("shell", True))
        self.assertEqual(check.entrance_source("页头 `⋯` →「历史」"), ("chat", True))
        self.assertEqual(check.entrance_source("工作面板第二段"), ("native-workbench", True))
        self.assertEqual(check.entrance_source("设置"), ("settings", False))

    def test_no_spec_table_means_no_mismatch(self) -> None:
        # The fixture has no README; the entrance check must stay silent (no crash).
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("spec-baseline-mismatch", out)

    # -- `--page` is its own entry point -----------------------------------

    def test_every_page_id_runs_independently(self) -> None:
        """Each `--page <id>` must run, exit 0/1, and print only that page."""
        contracts = check.load_contracts(self.fx.root)
        out = io.StringIO()
        for page_id in sorted(contracts):
            with contextlib.redirect_stdout(out):
                rc = check.run(self.fx.root, strict=True, baseline_path=None,
                               write_baseline=None, only_page=page_id, verbose=False)
            self.assertIn(rc, (0, 1), page_id)
            text = out.getvalue()
            pages = [line.split()[1] for line in text.splitlines() if line.startswith("PAGE ")]
            self.assertTrue(all(name == page_id for name in pages), f"{page_id}: {pages}")
            out = io.StringIO()

    def test_every_repo_page_runs_independently(self) -> None:
        """`--page <id>` for every real page: no crash, rc 0/1, only that page printed."""
        repo = Path(__file__).resolve().parents[4]
        pages_dir = repo / "spec/ui/v1/pages"
        if not pages_dir.is_dir():
            self.skipTest("repo contracts not present")
        ids = sorted(p.stem for p in pages_dir.glob("*.json") if not p.name.startswith("_"))
        self.assertTrue(ids)
        for page_id in ids:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = check.run(repo, strict=True, baseline_path=None, write_baseline=None,
                               only_page=page_id, verbose=False)
            self.assertIn(rc, (0, 1), page_id)
            text = out.getvalue()
            pages = [line.split()[1] for line in text.splitlines() if line.startswith("PAGE ")]
            self.assertTrue(pages, f"{page_id}: no PAGE line")
            self.assertTrue(all(name == page_id for name in pages), f"{page_id}: {pages}")

    # -- provenance never ratchets -----------------------------------------

    def test_stale_provenance_is_red(self) -> None:
        self.fx.write_swift(SWIFT.replace('Section("Alpha") {', 'Section("Renamed") {'))
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("stale page contracts", out)

    # -- whitelist ---------------------------------------------------------

    def _gamma_entry(self, **overrides) -> dict:
        entry = {
            "id": "fake.gamma",
            "page": PAGE_ID,
            "kind": "extra-section",
            "name": "Gamma",
            "side": "android-only",
            "platformRef": "platform.post-notifications-degraded",
            "owner": "android-parity",
            "reviewBy": "2099-01-01",
            "reason": "fixture: platform-forced section",
        }
        entry.update(overrides)
        return entry

    def _add_gamma(self) -> None:
        text = self.fx.android().replace(
            "    SessionSectionLabel(text = UiStrings.BETA)\n",
            "    SessionSectionLabel(text = UiStrings.BETA)\n    SessionSectionLabel(text = \"Gamma\")\n")
        self.fx.write_android(text)

    def test_whitelisted_platform_difference_passes(self) -> None:
        self._add_gamma()
        self.fx.write_whitelist([self._gamma_entry()])
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("1 whitelisted", out)
        self.assertIn("fake.gamma", out)

    def test_unknown_platform_ref_is_red(self) -> None:
        self._add_gamma()
        self.fx.write_whitelist([self._gamma_entry(platformRef="platform.not-real")])
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("platform.not-real", out)

    def test_expired_whitelist_entry_is_red(self) -> None:
        self._add_gamma()
        self.fx.write_whitelist([self._gamma_entry(reviewBy="2000-01-01")])
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("past", out)

    def test_stale_whitelist_entry_is_red(self) -> None:
        self.fx.write_whitelist([self._gamma_entry()])
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("match no divergence", out)

    # -- the ratchet -------------------------------------------------------

    def test_ratchet_accepts_known_and_rejects_new(self) -> None:
        self._add_gamma()
        baseline = self.fx.root / "spec/ui/v1/pages/_baseline.json"
        rc, out = run_check(self.fx.root, write_baseline=baseline)
        self.assertEqual(rc, 0, out)
        rc, out = run_check(self.fx.root, baseline_path=baseline)
        self.assertEqual(rc, 0, out)
        self.assertIn("known divergence(s), 0 new", out)
        # A brand-new divergence is not covered by the baseline.
        text = self.fx.android().replace("UiStrings.GO", "UiStrings.ALPHA")
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root, baseline_path=baseline)
        self.assertEqual(rc, 1, out)
        self.assertIn("new divergence", out)

    def test_ratchet_rejects_stale_baseline_entry(self) -> None:
        self._add_gamma()
        baseline = self.fx.root / "spec/ui/v1/pages/_baseline.json"
        rc, out = run_check(self.fx.root, write_baseline=baseline)
        self.assertEqual(rc, 0, out)
        text = self.fx.android().replace("    SessionSectionLabel(text = \"Gamma\")\n", "")
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root, baseline_path=baseline)
        self.assertEqual(rc, 1, out)
        self.assertIn("stale baseline", out)

    # -- contract scope ----------------------------------------------------

    def test_missing_android_screen_is_red(self) -> None:
        data = contract()
        data["android"] = {"screen": PAGE, "file": None, "match": "missing"}
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("no Android screen", out)

    def test_states_must_stay_advisory(self) -> None:
        data = contract()
        data["states"] = {"sites": {}, "absent": [], "coverage": {}}
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("advisory", out)

    def test_orphan_presentation_is_red(self) -> None:
        data = contract()
        data["presentations"] = [{
            "id": "sheet-9", "kind": "sheet", "title": None, "destination": "FakePage",
            "triggerBindings": ["showFake"], "triggered": False,
            "provenance": "FakePage.swift:2", "anchor": "struct FakePage: View { var body: some View {",
        }]
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("orphan-presentation", out)
        self.assertIn("showFake", out)

    def test_region_titles_are_compared(self) -> None:
        data = contract()
        data["sectionModel"] = "regions"
        data["sections"][0]["kind"] = "region"
        data["sections"][1]["kind"] = "region"
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        text = self.fx.android().replace("text = UiStrings.BETA)", 'text = "Gamma")')
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("missing-section", out)
        self.assertIn("'Beta'", out)

    def test_unmodeled_page_reports_a_manual_region(self) -> None:
        data = contract()
        data["sectionModel"] = "unmodeled"
        data["sections"] = [{"id": "region-1", "kind": "implicit", "title": None,
                             "titleTemplate": None, "titleSource": "absent", "condition": None,
                             "collection": None, "rows": [], "provenance": "FakePage.swift:2",
                             "anchor": "struct FakePage: View { var body: some View {",
                             "criterion": {"kind": "implicit"}, "extraction": "manual"}]
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("unresolved-section", out)
        self.assertIn("manual region", out)

    def test_android_screen_must_be_covered(self) -> None:
        extra = self.fx.root / "android/lib/src/main/kotlin/com/phonedsh/ui/page/OrphanPage.kt"
        extra.write_text("public fun OrphanPage() {\n}\n", encoding="utf-8")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("unmapped-android-screen", out)
        self.assertIn("OrphanPage", out)
        reg = self.fx.root / "spec/ui/v1/pages/_android-only.json"
        reg.write_text(json.dumps({
            "schema": "pdsh.ui.page-structure-android-only/1", "note": "fixture",
            "screens": [{"screen": "OrphanPage",
                         "file": "android/lib/src/main/kotlin/com/phonedsh/ui/page/OrphanPage.kt",
                         "reason": "fixture: no iOS counterpart", "evidence": "fixture"}],
        }, ensure_ascii=False), encoding="utf-8")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_representable_page_skips_section_comparison(self) -> None:
        data = contract()
        data["sectionModel"] = "representable"
        data["sections"] = []
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("not compared", out)


if __name__ == "__main__":
    unittest.main()
