#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
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
* a stale contract provenance line (the anchor moved) — never ratcheted;
* the summary row counts the *labelled* actions and their unique wordings, so a
  page with 36 labelled actions is never printed beside 29 Android labels as if
  the difference were missing controls;
* a label inside `if (callback != null)` is conditional presence, not presence —
  and a guard the baseline itself uses (`if let errorText`) is accepted;
* a page title that differs from `.navigationTitle` is a divergence.

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
import extract_ios_pages as extract  # noqa: E402

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


class PositionalClickableLabelTests(unittest.TestCase):
    def test_positional_text_is_an_action_only_on_its_own_clickable_modifier(self):
        source = 'BasicText(UiStrings.RESTORE, modifier = Modifier.clickable { restore() })'
        labels, unresolved, _ = check.android_actions(source, check.mask_kotlin(source), {"RESTORE": "恢复"}, {})
        self.assertEqual(["恢复"], labels)
        self.assertEqual([], unresolved)
        plain = 'BasicText(UiStrings.RESTORE)'
        self.assertEqual([], check.android_actions(plain, check.mask_kotlin(plain), {"RESTORE": "恢复"}, {})[0])

    def test_inferred_type_string_constants_are_not_unresolved_actions(self):
        source = 'private const val IMPORT_LABEL = "导入文件"'
        self.assertEqual({"IMPORT_LABEL": "导入文件"}, check.local_constants(source))


SETTINGS_INDEX_MODEL = '''
private data class SettingsIndexSection(val id: String, val title: String,
    val entries: List<SettingsIndexEntry>)
private data class SettingsIndexEntry(val id: String, val title: String,
    val callback: (() -> Unit)? = null)
@Composable public fun SettingsPage() { SettingsIndexList() }
@Composable private fun SettingsIndexList() {
    val sections = listOf(
        SettingsIndexSection("general", "General", listOf(
            SettingsIndexEntry("providers", "Providers", callback = {}),
        )),
    )
    LazyColumn {
        sections.forEach { section ->
            item {
                SettingsSectionLabel(section.title)
                section.entries.forEachIndexed { index, entry ->
                    SettingsIndexRow(entry, dividerBelow = false)
                }
            }
        }
    }
}
'''


class VerifiedSettingsIndexModelTests(unittest.TestCase):
    def _read(self, source: str):
        return check.verified_settings_index_model(
            source, check.mask_kotlin(source), {}, {})

    def test_extracts_only_titles_and_actions_from_a_verified_rendered_model(self):
        model = self._read(SETTINGS_INDEX_MODEL)
        self.assertIsNotNone(model)
        self.assertEqual(["General"], model[0])
        self.assertEqual(["Providers"], model[2])

    def test_arbitrary_section_title_projection_is_not_treated_as_a_model(self):
        unrelated = '''
@Composable public fun SettingsPage() { SettingsIndexList() }
@Composable private fun SettingsIndexList() {
    val sections = listOf(OtherSection("General"))
    sections.forEach { section -> SettingsSectionLabel(section.title) }
}
'''
        self.assertIsNone(self._read(unrelated))

    def test_model_must_render_its_entries_through_the_owned_row(self):
        source = SETTINGS_INDEX_MODEL.replace(
            "SettingsIndexRow(entry, dividerBelow = false)",
            "Text(entry.title)")
        self.assertIsNone(self._read(source))


ABOUT_ROW_MODEL = '''
data class AboutRowView(val id: String, val title: String, val value: String?)
data class AboutSectionView(val id: String, val title: String,
    val rows: List<AboutRowView>)
data class AboutScreenState(val sections: List<AboutSectionView>) {
    companion object {
        const val VERSION_SECTION_ID = "about.version"
        fun from(): AboutScreenState {
            val versionRows = listOf(
                AboutRowView(id = "version.version", title = "版本", value = "0.1.0"),
                AboutRowView(id = "version.build", title = "构建", value = "42"),
            )
            val sections = buildList {
                add(AboutSectionView(VERSION_SECTION_ID, "版本", versionRows))
            }
            return AboutScreenState(sections = sections)
        }
    }
}
@Composable fun AboutPage(state: AboutScreenState) {
    BasicText(text = "Phone DSH")
    val cards = state.sections.map { section ->
        section to section.rows.filter { row -> !row.id.isEmpty() }
    }
    cards.forEach { (section, rows) ->
        SettingsGroupCard {
            rows.forEach { row -> SettingsFormRow(title = row.title, value = row.value) }
        }
    }
}
'''


class VerifiedAboutRowModelTests(unittest.TestCase):
    def test_about_rows_are_resolved_only_through_the_page_renderer(self):
        source = ABOUT_ROW_MODEL
        rows = check.android_row_positions(source, check.mask_kotlin(source), {}, {})
        self.assertEqual(["Phone DSH", "版本", "构建"], [label for label, _ in rows])

    def test_about_model_without_the_matching_renderer_does_not_satisfy_rows(self):
        source = ABOUT_ROW_MODEL.replace(
            "SettingsFormRow(title = row.title, value = row.value)",
            "BasicText(text = row.title)",
        )
        rows = check.android_row_positions(source, check.mask_kotlin(source), {}, {})
        self.assertEqual(["Phone DSH"], [label for label, _ in rows])


class VerifiedDeveloperToolsRowTests(unittest.TestCase):
    SOURCE = '''
@Composable fun ConversationSettingsPage(preferences: SettingsPreferences,
    onToggleDeveloperTools: ((Boolean) -> Unit)?, languageId: String?) {
    DeveloperToolsRow(preferences.developerTools, onToggleDeveloperTools, languageId)
}
@Composable private fun DeveloperToolsRow(value: FactState,
    onToggle: ((Boolean) -> Unit)?, languageId: String?) {
    val label = UiStrings.settingsNativeText(languageId, UiStrings.WORK_DETAILS_CODE_VIEW, UiStrings.WORK_DETAILS_CODE_VIEW_EN)
    val known = value != FactState.UNKNOWN && onToggle != null
    val checked = value == FactState.YES
    if (!known) return
    SettingsRowFrame(role = Role.Switch, onClick = { onToggle?.invoke(!checked) }) {
        SettingsRowLabel(text = label)
        SettingsSwitch(checked = checked, enabled = true)
    }
}
'''

    def _actions(self, source: str):
        strings = {
            "WORK_DETAILS_CODE_VIEW": "显示代码工作视图",
            "WORK_DETAILS_CODE_VIEW_EN": "Show code work",
        }
        return check.android_actions(source, check.mask_kotlin(source), strings, {})[0]

    def test_localized_developer_toggle_is_read_from_its_verified_switch_helper(self):
        self.assertEqual(["显示代码工作视图"], self._actions(self.SOURCE))

    def test_missing_renderer_callback_or_callsite_does_not_count_as_an_action(self):
        no_callback = self.SOURCE.replace(
            "onClick = { onToggle?.invoke(!checked) }", "onClick = {}")
        no_callsite = self.SOURCE.replace(
            "DeveloperToolsRow(preferences.developerTools, onToggleDeveloperTools, languageId)",
            "Unit")
        no_label = self.SOURCE.replace(
            "SettingsRowLabel(text = label)", "SettingsRowLabel(text = \"\")")
        self.assertEqual([], self._actions(no_callback))
        self.assertEqual([], self._actions(no_callsite))
        self.assertEqual([], self._actions(no_label))


class VerifiedChatArtifactsRouteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        (self.root / check.ANDROID_UI_REL / "nav").mkdir(parents=True)

    def tearDown(self) -> None:
        import shutil
        shutil.rmtree(self.root)

    def _write(self, body: str) -> bool:
        path = self.root / check.ANDROID_UI_REL / "nav" / "PdshNavHost.kt"
        path.write_text(body)
        return check.verified_chat_artifact_route_binding(self.root)

    def test_direct_chat_route_callback_makes_the_artifact_action_unconditional(self):
        self.assertTrue(self._write('''
fun PdshNavHost(route: PdshRoute) {
    when (route) { PdshRoute.Chat -> ChatRoute() }
}
fun ChatRoute() {
    ChatPage(onOpenArtifacts = {
        onNavigate(PdshRoute.SessionArtifacts(state?.sessionID.orEmpty()))
    })
}
'''))

    def test_missing_or_conditional_route_callback_is_not_promoted(self):
        self.assertFalse(self._write('''
fun PdshNavHost(route: PdshRoute) {
    when (route) { PdshRoute.Chat -> ChatRoute() }
}
fun ChatRoute() { ChatPage() }
'''))
        self.assertFalse(self._write('''
fun PdshNavHost(route: PdshRoute) {
    when (route) { PdshRoute.Chat -> ChatRoute() }
}
fun ChatRoute(available: Boolean) {
    ChatPage(onOpenArtifacts = if (available) ({ onNavigate(PdshRoute.SessionArtifacts("s")) }) else null)
}
'''))


    def test_conditional_lambda_bodies_are_not_promoted(self):
        for condition in ("if(available)", "if (available)", "if\n(available)"):
            with self.subTest(condition=condition):
                self.assertFalse(self._write("""
fun PdshNavHost(route: PdshRoute) {
    when (route) { PdshRoute.Chat -> ChatRoute() }
}
fun ChatRoute(available: Boolean) {
    ChatPage(onOpenArtifacts = { CONDITION
        onNavigate(PdshRoute.SessionArtifacts(state?.sessionID.orEmpty()))
    })
}
""".replace("CONDITION", condition)))


class DrawerActionExtractionTests(unittest.TestCase):
    def test_wrapper_trailing_click_lambda_does_not_hide_its_first_label(self):
        source = '''
private fun EntryRow(label: String, action: () -> Unit) {
    Row(Modifier.clickable(onClick = action)) { Text(label) }
}
fun HomeDrawer() { EntryRow("新会话") { create() } }
'''
        labels, unresolved, _ = check.android_actions(
            source, check.mask_kotlin(source), {}, {}, wrappers=frozenset())
        self.assertEqual(["新会话"], labels)
        self.assertEqual([], unresolved)

    def test_semantics_labeled_clickable_icon_wrapper_supplies_action_label(self):
        source = '''
private fun IconAction(label: String, action: () -> Unit) {
    Box(Modifier.clickable(onClick = action).semantics { contentDescription = label })
}
fun HomeDrawer() { IconAction("新建文件夹") { create() } }
'''
        labels, unresolved, _ = check.android_actions(
            source, check.mask_kotlin(source), {}, {}, wrappers=frozenset())
        self.assertEqual(["新建文件夹"], labels)
        self.assertEqual([], unresolved)


class VerifiedChatHelperProvenanceTests(unittest.TestCase):
    def _check(self, label: str, provenance: str, anchor: str) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            probe = root / "examples/probe-app/PhoneDSHProbe"
            probe.mkdir(parents=True)
            (probe / "ChatPage.swift").write_text("struct ChatPage: View {}\n", encoding="utf-8")
            (probe / "NativePlanReviewCard.swift").write_text(
                'struct NativePlanReviewCard {\n    public static let requestChangesText = "要求修改"\n}\n',
                encoding="utf-8")
            contract = {
                "pageId": "chat", "page": "ChatPage",
                "source": {"file": "ChatPage.swift", "path": "examples/probe-app/PhoneDSHProbe/ChatPage.swift"},
                "sections": [],
                "actions": [{"id": label, "label": label, "provenance": provenance, "anchor": anchor}],
            }
            stale = []
            check.check_provenance(root, contract, stale)
            return stale

    def test_only_allowlisted_chat_helper_source_and_anchor_are_accepted(self):
        self.assertEqual([], self._check(
            "要求修改", "NativePlanReviewCard.swift:2", 'public static let requestChangesText = "要求修改"'))
        with self.assertRaises(check.CheckError):
            self._check("未验证", "NativePlanReviewCard.swift:2", 'public static let requestChangesText = "要求修改"')
        with self.assertRaises(check.CheckError):
            self._check("要求修改", "Other.swift:2", 'public static let requestChangesText = "要求修改"')

    def test_removed_workspace_folder_switch_is_not_reintroduced_as_android_only_debt(self):
        root = Path(__file__).resolve().parents[4]
        android_only = json.loads((root / "spec/ui/v1/pages/_android-only-items.json").read_text())
        baseline = json.loads((root / "spec/ui/v1/pages/_baseline.json").read_text())
        self.assertFalse(any(entry.get("page") == "workspace-folders"
                             and entry.get("label") == "切换"
                             for entry in android_only["entries"]))
        self.assertFalse(any(entry.get("page") == "workspace-folders"
                             and entry.get("name") == "切换"
                             and entry.get("kind") == "android-only-stale"
                             for entry in baseline["divergences"]))

    def test_clickable_row_reads_positional_child_text(self):
        source = 'Row(Modifier.clickable { open() }) { Text("设置") }'
        labels, _, _ = check.android_actions(source, check.mask_kotlin(source), {}, {})
        self.assertEqual(["设置"], labels)

    def test_known_when_and_unavailable_label_branches_are_not_unresolved(self):
        self.assertEqual(["创建", "删除", "保存"], check.kotlin_label_variants(
            'when (dialog) { "create" -> "创建"; "delete" -> "删除"; else -> "保存" }', {}, {}))
        self.assertEqual(["归档"], check.kotlin_label_variants(
            'if (onArchive == null) "归档不可用" else "归档"', {}, {}))

    def test_verified_automation_save_conditional_resolves_steady_action_only(self):
        strings = {"AUTOMATION_EDITOR_SAVE": "保存"}
        consts = {"AUTOMATION_EDITOR_SAVING_LABEL": "保存中…"}
        expression = "if (editor.saving) AUTOMATION_EDITOR_SAVING_LABEL else UiStrings.AUTOMATION_EDITOR_SAVE"
        self.assertEqual(["保存"], check.kotlin_label_variants(expression, strings, consts))
        component = f'''SessionTextAction(
    label = {expression},
    onClick = {{ onSubmit(draft, UUID.randomUUID().toString()) }},
    enabled = editor.canSubmit,
)'''
        positions = []
        labels, unresolved, _ = check.android_actions(
            component, check.mask_kotlin(component), strings, consts, positions=positions)
        self.assertEqual(["保存"], labels)
        self.assertEqual([], unresolved)
        self.assertEqual(["保存"], [label for label, _ in positions])
        no_callback = f'''SessionTextAction(
    label = {expression},
    enabled = editor.canSubmit,
)'''
        _, unresolved, _ = check.android_actions(
            no_callback, check.mask_kotlin(no_callback), strings, consts)
        self.assertEqual([expression[:check.DYN_EXPR_MAX]], unresolved)
        arbitrary = 'SessionTextAction(label = if (toggle) "保存" else "取消")'
        labels, unresolved, _ = check.android_actions(
            arbitrary, check.mask_kotlin(arbitrary), {}, {})
        self.assertEqual([], labels)
        self.assertEqual(['if (toggle) "保存" else "取消"'], unresolved)
        wrong_enabled = component.replace("editor.canSubmit", "true")
        labels, unresolved, _ = check.android_actions(
            wrong_enabled, check.mask_kotlin(wrong_enabled), strings, consts)
        self.assertNotIn("保存", labels)
        self.assertEqual([expression[:check.DYN_EXPR_MAX]], unresolved)
        self.assertEqual([], check.kotlin_label_variants(
            "if (editor.saving) AUTOMATION_EDITOR_SAVING_LABEL else UiStrings.CANCEL",
            {"CANCEL": "取消"}, consts))
        self.assertEqual([], check.kotlin_label_variants(
            "if (state.saving) AUTOMATION_EDITOR_SAVING_LABEL else UiStrings.AUTOMATION_EDITOR_SAVE",
            strings, consts))
        self.assertEqual([], check.kotlin_label_variants(
            "if (editor.saving) AUTOMATION_EDITOR_SAVING_LABEL else UiStrings.AUTOMATION_EDITOR_SAVE",
            strings, {"AUTOMATION_EDITOR_SAVING_LABEL": "处理中…"}))


FONT_SIZE_ROLE_MODEL = '''
private data class FontSizeRole(val title: String, val rowId: String)
@Composable fun FontSizeSettingsPage(embedded: Boolean) {
    val content: @Composable () -> Unit = {
        val values = listOf(FontSizeRole("Conversation", "conversation"))
        values.forEach { role ->
            SettingsSectionLabel(role.title)
            FontSizeStepper(role = role)
        }
    }
    if (embedded) content() else SettingsSubPageFrame { content() }
}
'''


class VerifiedFontSizeRoleModelTests(unittest.TestCase):
    def _read(self, source: str):
        return check.verified_font_size_role_model(source, check.mask_kotlin(source), {}, {})

    def test_resolves_roles_only_when_the_page_builds_and_renders_the_role_model(self):
        model = self._read(FONT_SIZE_ROLE_MODEL)
        self.assertIsNotNone(model)
        self.assertEqual(["Conversation"], model[0])

    def test_unrelated_role_title_projection_stays_unresolved(self):
        source = FONT_SIZE_ROLE_MODEL.replace(
            "FontSizeStepper(role = role)", "Text(role.title)")
        self.assertIsNone(self._read(source))


class ContextMenuSurfaceTests(unittest.TestCase):
    """`PdshContextMenu(surfaceId = …)` labels come from the frozen token surface."""

    SURFACES = {
        "drawerSession": [{"label": "编辑名称", "kind": "action"}, {"label": "归档", "kind": "action"}],
        "botRow": [{"label": "隐藏", "altLabel": "取消隐藏", "kind": "action"},
                   {"label": "这是最后一个 Bot，不能删除。", "kind": "info"}],
    }

    def actions(self, src: str) -> tuple:
        masked = check.mask_kotlin(src)
        consts = check.local_constants(src)
        return check.context_menu_actions(src, masked, {}, consts, self.SURFACES)

    def test_constant_surface_id_yields_every_item_at_the_call(self) -> None:
        src = ('private const val S = "drawerSession"\n'
               "fun Row() {\n    PdshContextMenu(\n        surfaceId = S,\n"
               "        state = ContextMenuRowState(),\n    ) { Text(x) }\n}\n")
        labels, unresolved = self.actions(src)
        self.assertEqual([label for label, _ in labels], ["编辑名称", "归档"])
        self.assertEqual(unresolved, [])
        pos = src.index("PdshContextMenu(")
        self.assertTrue(all(p == pos for _, p in labels))

    def test_alt_label_counts_and_info_row_is_not_an_action(self) -> None:
        labels, _ = self.actions('fun R() { PdshContextMenu(surfaceId = "botRow") {} }\n')
        self.assertEqual([label for label, _ in labels], ["隐藏", "取消隐藏"])

    def test_unknown_or_missing_surface_is_unresolved_not_skipped(self) -> None:
        labels, unresolved = self.actions(
            'fun R() { PdshContextMenu(surfaceId = "nope") {}; PdshContextMenu(state = s) {} }\n')
        self.assertEqual(labels, [])
        self.assertEqual(len(unresolved), 2)

    def test_real_token_table_resolves_every_surface(self) -> None:
        surfaces = check.load_context_menu_surfaces(Path(__file__).resolve().parents[4])
        self.assertIn("sessionsRow", surfaces)
        self.assertTrue(all(items for items in surfaces.values()))


class DataLabelTests(unittest.TestCase):
    def test_host_data_only_expressions_are_data(self):
        for expr in ("row.name", "field.title", "mode.name", "state.note",
                     'if (draft.isEmpty()) field.title else "$draft"', '"${a.b}"'):
            self.assertTrue(check.is_data_label(expr), expr)

    def test_any_static_wording_keeps_an_expression_unresolved(self):
        for expr in ('if (x) field.title else "全部"', "UiStrings.TITLE", "TITLE_LABEL",
                     'native("工作步骤", "Steps")', "UiStrings.NAMED.format(row.name)",
                     '"共 ${count} 项"', "x" * check.DYN_EXPR_MAX):
            self.assertFalse(check.is_data_label(expr), expr)


class PairedLabelVariantTests(unittest.TestCase):
    STRINGS = {"FETCH": "获取模型", "FETCHING": "正在获取模型…", "SAVE": "保存", "CANCEL": "取消"}

    def test_static_pair_needs_one_contract_control_owning_both_wordings(self):
        expr = "if (fetching) UiStrings.FETCHING else UiStrings.FETCH"
        self.assertEqual([], check.kotlin_label_variants(expr, self.STRINGS, {}))
        owned = [frozenset({"获取模型", "正在获取模型…"})]
        self.assertEqual(["正在获取模型…", "获取模型"],
                         check.kotlin_label_variants(expr, self.STRINGS, {}, owned))
        # Two separate contract controls do not license one Android control to be both.
        split = [frozenset({"保存"}), frozenset({"取消"})]
        self.assertEqual([], check.kotlin_label_variants(
            "if (x) UiStrings.SAVE else UiStrings.CANCEL", self.STRINGS, {}, split))

    def test_null_callback_branch_is_the_disabled_explanation(self):
        consts = {"LABEL": "重新检查文件", "UNAVAILABLE": "宿主暂不支持重新检查"}
        self.assertEqual(["重新检查文件"], check.kotlin_label_variants(
            "if (onRefresh == null) UNAVAILABLE else LABEL", {}, consts))
        self.assertEqual(["重新检查文件"], check.kotlin_label_variants(
            "if (onRefresh != null) LABEL else UNAVAILABLE", {}, consts))

    def test_session_text_action_pair_resolves_only_when_owned(self):
        source = "SessionTextAction(label = if (fetching) UiStrings.FETCHING else UiStrings.FETCH, onClick = {})"
        labels, unresolved, _ = check.android_actions(
            source, check.mask_kotlin(source), self.STRINGS, {},
            wording_sets=[frozenset({"获取模型", "正在获取模型…"})])
        self.assertEqual(["正在获取模型…", "获取模型"], labels)
        self.assertEqual([], unresolved)
        labels, unresolved, _ = check.android_actions(
            source, check.mask_kotlin(source), self.STRINGS, {})
        self.assertEqual([], labels)
        self.assertEqual(1, len(unresolved))


class LocalizedLabelResolutionTests(unittest.TestCase):
    def test_trailing_comma_does_not_change_the_arity(self):
        value, dynamic = check.resolve_kotlin_expr(
            "UiStrings.settingsNativeText(\n    state.languageId,\n    UiStrings.NOTE,\n"
            "    UiStrings.NOTE_EN,\n)",
            {"NOTE": "只影响之后新开的会话，当前会话保持不变。", "NOTE_EN": "Only new sessions"},
        )
        self.assertEqual(("只影响之后新开的会话，当前会话保持不变。", False), (value, dynamic))

    def test_known_translation_keeps_chinese_contract_label(self):
        value, dynamic = check.resolve_kotlin_expr(
            'UiStrings.settingsNativeText(state.language, UiStrings.ROW, "English, label")',
            {"ROW": "工作步骤"},
        )
        self.assertEqual(("工作步骤", False), (value, dynamic))

    def test_local_forwarder_requires_verified_declaration(self):
        self.assertEqual((None, True), check.resolve_kotlin_expr('native("工作步骤", "Steps")', {}))
        self.assertEqual(("工作步骤", False), check.resolve_kotlin_expr(
            'native("工作步骤", "Steps")', {}, {"__native_text_forwarder__": True},
        ))

    def test_dynamic_chinese_label_does_not_become_a_contract_match(self):
        self.assertEqual((None, True), check.resolve_kotlin_expr(
            'UiStrings.settingsNativeText(locale, state.title, "Title")', {},
        ))


class QualifiedObjectConstantTests(unittest.TestCase):
    SOURCE = '''package com.phonedsh.ui.page

public object PcLinkText {
    public const val FULL_OWNER_WARNING: String =
        "连接后，这台手机可以完整使用这台电脑上的 DSH。"
    private val PAIRING_INTERRUPTED: String = "连接中断，请保持此页面打开后重试。"

    fun helper() {
        val LOCAL: String = "函数内的值不是常量"
    }
}

class Holder {
    companion object {
        const val TITLE: String = "标题"
    }
}
'''

    def test_object_and_companion_constants_resolve(self):
        consts = check.qualified_constants(self.SOURCE)
        self.assertEqual("连接后，这台手机可以完整使用这台电脑上的 DSH。",
                         consts["PcLinkText.FULL_OWNER_WARNING"])
        self.assertEqual("连接中断，请保持此页面打开后重试。",
                         consts["PcLinkText.PAIRING_INTERRUPTED"])
        self.assertEqual("标题", consts["Holder.TITLE"])
        self.assertEqual("标题", consts["Holder.Companion.TITLE"])
        self.assertNotIn("PcLinkText.LOCAL", consts)
        self.assertEqual(("连接中断，请保持此页面打开后重试。", False),
                         check.resolve_kotlin_expr("PcLinkText.PAIRING_INTERRUPTED", {}, consts))
        self.assertEqual((None, True),
                         check.resolve_kotlin_expr("PcLinkText.NOT_DECLARED", {}, consts))

    def test_page_constants_allow_a_line_break_after_equals(self):
        self.assertEqual({"ROW": "行"}, check.local_constants(
            'public const val ROW: String =\n        "行"\n'))
        self.assertEqual({"TOP": "顶"}, check.local_constants(
            'private val TOP: String =\n        "顶"\n'))

    def test_a_local_val_does_not_become_a_page_constant(self):
        self.assertEqual({}, check.local_constants('fun f() { val ROW = "行" }'))
        self.assertNotIn("ROW", check.qualified_constants(
            'public object O { fun f() { val ROW = "行" } }'))


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


def approve_baseline(path: Path, lane: str = "H") -> None:
    """Simulate the human review step that a written baseline requires."""
    data = json.loads(path.read_text(encoding="utf-8"))
    for row in data["divergences"]:
        if row.get("lane") in (None, "", "UNREVIEWED"):
            row["lane"] = lane
        row["reason"] = "fixture divergence, reviewed for the test"
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


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

    # -- one control, several wordings -------------------------------------

    def test_an_alternative_wording_satisfies_the_same_action(self) -> None:
        """`labelAlternatives` is the other string one control renders.

        `Text(existing == nil ? "保存并连接" : "保存修改并重连")` is ONE save button.
        Rendering either wording must satisfy the contract, and neither may be
        reported as an invented button.
        """
        data = contract()
        data["actions"][0]["label"] = "Go"
        data["actions"][0]["labelAlternatives"] = ["Go now"]
        self.fx.write_contract(data)
        self.fx.write_android(ANDROID.replace("UiStrings.GO", "UiStrings.GO_NOW"))
        self.fx._write(UISTRINGS_REL, UISTRINGS.replace(
            'public const val GO: String = "Go"',
            'public const val GO: String = "Go"\n    public const val GO_NOW: String = "Go now"'))
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_an_action_with_only_alternatives_is_still_compared(self) -> None:
        """A control with no single rendered label is judged on its wordings."""
        data = contract()
        data["actions"][0]["label"] = None
        data["actions"][0]["labelAlternatives"] = ["Go"]
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_a_shortened_copy_is_one_divergence_not_two(self) -> None:
        """`保存` for `保存并连接`: one control, different copy — still red.

        Reporting both `missing-action '保存并连接'` and `extra-action '保存'` would
        put one defect in two ratchet rows and read as "lost one button, invented
        another". The finding stays red either way; only the count changes.
        """
        data = contract()
        data["actions"][0]["label"] = "Go now"
        data["actions"][0]["labelAlternatives"] = ["Go later"]
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("missing-action", out)
        self.assertIn("'Go now'", out)
        self.assertIn("shortened copy", out)
        self.assertNotIn("extra-action", out)

    def test_a_different_label_is_still_an_invented_action(self) -> None:
        """The pairing is prefix-only: an unrelated label stays an extra action."""
        data = contract()
        data["actions"][0]["label"] = "Submit"
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("extra-action", out)
        self.assertIn("'Go'", out)
        self.assertIn("missing-action", out)

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

    def test_segmented_picker_options_count_as_action_labels(self) -> None:
        data = contract()
        data["actions"].append({
            "id": "mode-picker", "label": "工作区", "labelExpr": None,
            "kind": "picker", "trigger": "tap", "semantic": "binding:section",
            "writes": True, "destination": None, "condition": None,
            "provenance": "FakePage.swift:2", "anchor": "struct FakePage: View { var body: some View {",
            "extraction": "syntax", "items": ["工作区", "文件", "命令"], "style": "segmented",
        })
        self.fx.write_contract(data)
        text = self.fx.android().replace(
            "    SessionTextAction(label = UiStrings.GO, onClick = {})\n",
            "    SessionTextAction(label = UiStrings.GO, onClick = {})\n"
            '    SegmentedButton(selected = true, onClick = {}) { Text("文件") }\n'
            '    SegmentedButton(selected = false, onClick = {}) { Text("命令") }\n')
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_segment_named_like_its_picker_title_is_still_required(self) -> None:
        data = contract()
        data["actions"].append({
            "id": "mode-picker", "label": "模式", "labelExpr": None,
            "kind": "picker", "trigger": "tap", "semantic": "binding:section",
            "writes": True, "destination": None, "condition": None,
            "provenance": "FakePage.swift:2", "anchor": "struct FakePage: View { var body: some View {",
            "extraction": "syntax", "items": ["模式", "模式", "文件"], "style": "segmented",
        })
        self.fx.write_contract(data)
        self.fx.write_android(self.fx.android().replace(
            "    SessionTextAction(label = UiStrings.GO, onClick = {})\n",
            "    SessionTextAction(label = UiStrings.GO, onClick = {})\n"
            '    SegmentedButton(selected = true, onClick = {}) { Text("文件") }\n'))
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("missing-action", out)
        self.assertIn("模式", out)

    def test_material_button_without_label_is_missing(self) -> None:
        self._actions("运行")
        self._compose_page("    Button(onClick = {}) {\n    }")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("missing-action", out)
        self.assertIn("'运行'", out)

    def test_material_button_with_a_data_label_is_not_compared_but_the_contract_label_is_missing(self) -> None:
        """A label made only of host data is data-labelled, like the contract's twin.

        It is not `unresolved` any more (the baseline's `Button { Text(name) }` is an
        unlabelled action that is never compared), but it cannot satisfy a literal
        contract label either: the contract's `运行` is still reported missing.
        """
        self._actions("运行")
        self._compose_page("    Button(onClick = {}) {\n        Text(text = state.label)\n    }")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertNotIn("unresolved-action", out)
        self.assertIn("missing-action", out)
        self.assertIn("'运行'", out)
        self.assertIn("data-labelled Android items", out)
        self.assertIn("state.label", out)

    def test_a_label_expression_with_static_wording_stays_unresolved(self) -> None:
        self._actions("运行")
        self._compose_page('    Button(onClick = {}) {\n'
                           '        Text(text = if (busy) state.label else "运行中")\n    }')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("unresolved-action", out)

    def test_a_data_labelled_section_title_is_not_a_divergence(self) -> None:
        text = self.fx.android().replace(
            "    SessionSectionLabel(text = UiStrings.BETA)\n",
            "    SessionSectionLabel(text = UiStrings.BETA)\n"
            "    SessionSectionLabel(text = group.title)\n")
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("data-labelled Android items", out)
        self.assertIn("group.title", out)

    def test_progress_pair_resolves_only_against_one_contract_control(self) -> None:
        """`if (testing) UiStrings.A else UiStrings.B` is one control with two wordings."""
        data = contract()
        data["actions"][0]["label"] = "Go"
        data["actions"][0]["labelAlternatives"] = ["Going…"]
        self.fx.write_contract(data)
        self.fx._write(UISTRINGS_REL, UISTRINGS.replace(
            'public const val GO: String = "Go"',
            'public const val GO: String = "Go"\n    public const val GOING: String = "Going…"'))
        self.fx.write_android(ANDROID.replace(
            "UiStrings.GO", "if (busy) UiStrings.GOING else UiStrings.GO"))
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        # Without the contract owning both wordings the same expression is unresolved.
        data["actions"][0]["labelAlternatives"] = []
        self.fx.write_contract(data)
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("unresolved-action", out)

    def test_trailing_nav_text_action_counts_and_leading_does_not(self) -> None:
        self._actions("保存")
        self._compose_page(
            "    SettingsSubPageFrame(\n"
            '        leading = { SettingsNavAction(text = "刷新", onClick = {}) },\n'
            '        trailing = if (editing) { { SettingsNavAction(text = "保存", onClick = {}, '
            'description = "Save") } } else null,\n'
            "    ) {}")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self._compose_page(
            "    SettingsSubPageFrame(\n"
            '        leading = { SettingsNavAction(text = "保存", onClick = {}) },\n'
            "    ) {}")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("missing-action", out)

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
        approve_baseline(baseline)
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
        approve_baseline(baseline)
        text = self.fx.android().replace("    SessionSectionLabel(text = \"Gamma\")\n", "")
        self.fx.write_android(text)
        rc, out = run_check(self.fx.root, baseline_path=baseline)
        self.assertEqual(rc, 1, out)
        self.assertIn("stale baseline", out)

    def test_write_baseline_marks_unreviewed_rows(self) -> None:
        """A bulk write cannot masquerade as a reviewed ratchet move."""
        self._add_gamma()
        baseline = self.fx.root / "spec/ui/v1/pages/_baseline.json"
        rc, out = run_check(self.fx.root, write_baseline=baseline)
        self.assertEqual(rc, 0, out)
        data = json.loads(baseline.read_text(encoding="utf-8"))
        self.assertTrue(data["divergences"])
        self.assertEqual({"UNREVIEWED"}, {row["lane"] for row in data["divergences"]})
        rc, out = run_check(self.fx.root, baseline_path=baseline)
        self.assertEqual(rc, 1, out)
        self.assertIn("UNREVIEWED", out)

    def test_baseline_entry_needs_an_owning_lane_and_reason(self) -> None:
        self._add_gamma()
        baseline = self.fx.root / "spec/ui/v1/pages/_baseline.json"
        rc, out = run_check(self.fx.root, write_baseline=baseline)
        self.assertEqual(rc, 0, out)
        data = json.loads(baseline.read_text(encoding="utf-8"))
        data["divergences"][0]["lane"] = "X"
        baseline.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        rc, out = run_check(self.fx.root, baseline_path=baseline)
        self.assertEqual(rc, 1, out)
        self.assertIn("not one of C/D/E/F/G/H", out)

    def test_a_reviewed_baseline_loads(self) -> None:
        self._add_gamma()
        baseline = self.fx.root / "spec/ui/v1/pages/_baseline.json"
        rc, out = run_check(self.fx.root, write_baseline=baseline)
        self.assertEqual(rc, 0, out)
        approve_baseline(baseline, lane="H")
        rc, out = run_check(self.fx.root, baseline_path=baseline)
        self.assertEqual(rc, 0, out)
        self.assertIn("known divergence(s), 0 new", out)

    def test_a_data_model_section_view_is_not_a_header(self) -> None:
        """PR22 AboutPage projects cards through `data class AboutSectionView`."""
        self.fx.write_android(self.fx.android() + """
public data class AboutSectionView(val id: String, val title: String)
private fun projection() = listOf(AboutSectionView("about.version", "版本"))
""")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("extra-section", out)
        self.assertNotIn("版本", out)

    def test_settings_form_row_satisfies_an_untitled_criterion(self) -> None:
        """A settings wrapper still renders the visible row the criterion names."""
        data = contract()
        data["sections"] = [{
            "id": "version", "title": None, "titleTemplate": None, "titleSource": "absent",
            "condition": None, "collection": None, "rows": [],
            "criterion": {"kind": "first-row", "label": "版本", "provenance": "FakePage.swift:3"},
            "provenance": "FakePage.swift:3", "anchor": 'Section {',
            "extraction": "syntax",
        }]
        data["actions"] = []
        self.fx.write_contract(data)
        self.fx.write_swift("""import SwiftUI
struct FakePage: View { var body: some View {
        Section {
            Text("版本")
        }
} }
""")
        self.fx.write_android("""package com.phonedsh.ui.page

public fun FakePage() {
    SettingsFormRow(title = "版本", value = "1.0")
}
""")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_write_baseline_preserves_an_existing_review(self) -> None:
        self._add_gamma()
        baseline = self.fx.root / "spec/ui/v1/pages/_baseline.json"
        rc, out = run_check(self.fx.root, write_baseline=baseline)
        self.assertEqual(rc, 0, out)
        approve_baseline(baseline, lane="E")
        rc, out = run_check(self.fx.root, write_baseline=baseline)
        self.assertEqual(rc, 0, out)
        data = json.loads(baseline.read_text(encoding="utf-8"))
        self.assertTrue(data["divergences"])
        self.assertEqual({"E"}, {row["lane"] for row in data["divergences"]})

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

    # -- ① the summary row: labelled actions, not the whole inventory -------
    #
    # The old row printed `contract 67 labelled` beside `android 29`. Chat's 67
    # actions were 27 icon-only + 4 dynamicLabel + 36 labelled, and the labelled
    # set deduplicated to the same keys as Android's labels — so the row said
    # "38 missing" about a page that matched. The row must print the labelled
    # count, its exclusions, and the unique wordings actually compared.

    def test_summary_prints_the_labelled_basis_not_the_whole_inventory(self) -> None:
        """Chat's real shape: 67 actions = 36 labelled + 27 icon-only + 4 dynamic.

        The old row printed `contract 67 labelled` beside `android 29`, reading as
        38 missing controls; the labelled set dedupes to the 29 wordings Android
        draws, so this must PASS and the row must show the labelled basis.
        """
        wordings = [f"动作{chr(0x4e00 + i)}" for i in range(29)]
        actions = []
        for label in wordings + wordings[:7]:          # 36 labelled, 29 wordings
            actions.append({"id": f"a{len(actions)}", "label": label, "kind": "button",
                            "trigger": "tap", "semantic": None, "writes": True,
                            "destination": None, "condition": None,
                            "provenance": "FakePage.swift:4",
                            "anchor": 'Button("Go") { open() }', "extraction": "syntax"})
        for _ in range(27):                            # icon-only controls, no wording
            actions.append({"id": f"a{len(actions)}", "label": None, "kind": "button",
                            "trigger": "tap", "semantic": None, "writes": True,
                            "destination": None, "condition": None,
                            "provenance": "FakePage.swift:4",
                            "anchor": 'Button("Go") { open() }', "extraction": "syntax"})
        for i in range(4):                             # data-driven labels
            actions.append({"id": f"a{len(actions)}", "label": f"动态{i}", "dynamicLabel": True,
                            "kind": "button", "trigger": "tap", "semantic": None,
                            "writes": True, "destination": None, "condition": None,
                            "provenance": "FakePage.swift:4",
                            "anchor": 'Button("Go") { open() }', "extraction": "syntax"})
        data = contract()
        data["actions"] = actions
        self.fx.write_contract(data)
        self.fx.write_android(
            "package com.phonedsh.ui.page\n\npublic fun FakePage() {\n"
            "    SessionSectionLabel(text = UiStrings.ALPHA)\n"
            "    SessionSectionLabel(text = UiStrings.BETA)\n"
            + "".join(f'    SessionTextAction(label = "{label}", onClick = {{}})\n'
                      for label in wordings)
            + "}\n")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("labelled 36 of 67 actions (27 unlabelled, 4 dynamicLabel) = 29 comparable keys", out)
        self.assertIn("android 29 labels (29 keys: 29 unconditional, 0 conditional)", out)
        # The ambiguous shape the finding was about: inventory beside Android labels.
        self.assertNotIn("contract 67 labelled", out)

    # -- ② null-callback guard: conditional presence, not presence ---------

    def _guarded_page(self, guard: str = "if (onOpenDemo != null) {") -> None:
        self.fx.write_android(
            "package com.phonedsh.ui.page\n\n"
            "public fun FakePage(onOpenDemo: (() -> Unit)? = null) {\n"
            "    SessionSectionLabel(text = UiStrings.ALPHA)\n"
            "    SessionSectionLabel(text = UiStrings.BETA)\n"
            f"    {guard}\n"
            "        SessionTextAction(label = UiStrings.GO, onClick = onOpenDemo)\n"
            "    }\n}\n")

    def test_label_inside_a_null_callback_guard_is_conditional_not_present(self) -> None:
        """The L64 hole: `if (onOpenDemo != null)` used to satisfy the contract.

        `FilesPage.kt:478` carried `3D 示例` under exactly that guard while
        `PdshNavHost` never passed the callback: the source had the label, the
        pixels had no control, and the gate was green. Source-level presence must
        be reported as conditional presence — not as present, and not as missing.
        """
        self._guarded_page()
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("conditional-action", out)
        self.assertIn("only rendered behind `if (onOpenDemo != null)`", out)
        self.assertIn("conditionally present", out)
        # The label is in the source: neither direction of the label diff applies.
        self.assertNotIn("missing-action", out)
        self.assertNotIn("extra-action", out)

    def test_let_guard_is_conditional_presence_too(self) -> None:
        """`onOpenDemo?.let { … }` is the same host-wiring condition."""
        self._guarded_page(guard="onOpenDemo?.let {")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("conditional-action", out)
        self.assertIn("onOpenDemo?.let", out)

    def test_a_guard_the_baseline_also_uses_is_not_a_divergence(self) -> None:
        """`if let onGo { Button("Go") }` in the baseline: Android's guard matches.

        The contract's `condition` is null for syntax-extracted actions (the
        extractor only fills it for manual ones), so the gate must read the
        baseline source. Without this, every correct retry-only-on-error control
        would be reported as a conditional-presence divergence.
        """
        self.fx.write_swift("""import SwiftUI
struct FakePage: View { var body: some View {
        Section("Alpha") {
            if let onGo {
                Button("Go") { onGo() }
            }
        }
        Section("Beta") {
            Text("hi")
        }
} }
""")
        data = contract()
        data["sections"][1]["provenance"] = "FakePage.swift:8"
        data["actions"][0]["provenance"] = "FakePage.swift:5"
        data["actions"][0]["anchor"] = 'Button("Go") { onGo() }'
        self.fx.write_contract(data)
        self.fx.write_android(
            "package com.phonedsh.ui.page\n\n"
            "public fun FakePage(onGo: (() -> Unit)? = null) {\n"
            "    SessionSectionLabel(text = UiStrings.ALPHA)\n"
            "    SessionSectionLabel(text = UiStrings.BETA)\n"
            "    if (onGo != null) {\n"
            "        SessionTextAction(label = UiStrings.GO, onClick = onGo)\n"
            "    }\n}\n")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("matches the contract's own condition (if let onGo)", out)

    def test_section_title_inside_a_null_callback_guard_is_conditional(self) -> None:
        """The hole is about any labelled UI: a section header counts too."""
        self.fx.write_android(
            "package com.phonedsh.ui.page\n\n"
            "public fun FakePage(onShowBeta: (() -> Unit)? = null) {\n"
            "    SessionSectionLabel(text = UiStrings.ALPHA)\n"
            "    if (onShowBeta != null) {\n"
            "        SessionSectionLabel(text = UiStrings.BETA)\n"
            "    }\n"
            '    SessionTextAction(label = UiStrings.GO, onClick = {})\n'
            "}\n")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("conditional-section", out)
        self.assertIn("only rendered behind `if (onShowBeta != null)`", out)
        self.assertNotIn("missing-section", out)

    def test_a_section_guard_the_contract_also_declares_is_listed_not_failed(self) -> None:
        data = contract()
        data["sections"][1]["condition"] = "onShowBeta != nil"
        self.fx.write_contract(data)
        self.fx.write_android(
            "package com.phonedsh.ui.page\n\n"
            "public fun FakePage(onShowBeta: (() -> Unit)? = null) {\n"
            "    SessionSectionLabel(text = UiStrings.ALPHA)\n"
            "    if (onShowBeta != null) {\n"
            "        SessionSectionLabel(text = UiStrings.BETA)\n"
            "    }\n"
            '    SessionTextAction(label = UiStrings.GO, onClick = {})\n'
            "}\n")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("section 'Beta'", out)
        self.assertIn("matches the contract's own condition (onShowBeta != nil)", out)

    # -- ③ the page title is compared --------------------------------------

    def _titled_android(self, title_expr: str) -> None:
        self.fx.write_android(
            "package com.phonedsh.ui.page\n\npublic fun FakePage() {\n"
            f"    PageFrame(title = {title_expr}) {{\n"
            "        SessionSectionLabel(text = UiStrings.ALPHA)\n"
            "        SessionSectionLabel(text = UiStrings.BETA)\n"
            "        SessionTextAction(label = UiStrings.GO, onClick = {})\n"
            "    }\n}\n")

    def _title(self, text: str, anchor: str = 'struct FakePage: View { var body: some View {') -> None:
        data = contract()
        data["title"] = {"text": text, "provenance": "FakePage.swift:2", "anchor": anchor}
        self.fx.write_contract(data)

    def test_page_title_mismatch_is_red(self) -> None:
        """Two pages with different headings used to be green: the title was never read."""
        self._title("Alpha")
        self._titled_android('"Beta"')
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("title-mismatch", out)
        self.assertIn("'Beta'", out)
        self.assertIn("title     contract 'Alpha'", out)

    def test_matching_page_title_passes(self) -> None:
        self._title("Alpha")
        self._titled_android("UiStrings.ALPHA")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)
        self.assertIn("title     contract 'Alpha'   android 'Alpha'", out)

    def test_a_title_only_known_at_runtime_is_unresolved(self) -> None:
        """`PageFrame(title = state.title)` cannot be compared; say so, do not guess."""
        self._title("Alpha")
        self._titled_android("state.title")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 1, out)
        self.assertIn("unresolved-title", out)
        self.assertIn("cannot be compared", out)

    def test_a_dynamic_title_with_the_contract_wording_is_accepted(self) -> None:
        """`currentTitle() ?: UiStrings.ALPHA` renders the contract title in a mode."""
        self._title("Alpha")
        self._titled_android("currentTitle() ?: UiStrings.ALPHA")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)

    def test_the_baselines_own_dynamic_title_is_not_compared(self) -> None:
        """`directory.isEmpty ? "手机工作区" : …` fixes no single title: skip, don't guess."""
        self._title("手机工作区", anchor='.navigationTitle(directory.isEmpty ? "手机工作区" : name)')
        self._titled_android("state.groupTitle")
        rc, out = run_check(self.fx.root)
        self.assertEqual(rc, 0, out)


class StaticSwiftLiteralAgreementTests(unittest.TestCase):
    """The extractor's Swift label and the checker's Kotlin constant must agree.

    This is the end-to-end mutation: `Text(DemoCopy.row)` resolves to the one plain
    Swift `static let`, and Android renders `DemoText.ROW` through the PcLink hint
    wrapper. Changing only the Swift literal must make the checker report the
    criterion row missing; changing the Kotlin constant the same way must too.
    """

    def _write(self, root: Path, rel: str, text: str) -> None:
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def _fixture(self, root: Path, swift_literal: str) -> dict:
        self._write(root, "examples/probe-app/PhoneDSHProbe/DemoPage.swift", """\
import SwiftUI

struct DemoPage: View {
    var body: some View {
        List {
            Section { Text(DemoCopy.row) }
        }
    }
}
""")
        self._write(root, "Sources/App/DemoCopy.swift", f'''\
struct DemoCopy {{
    static let row =
        "{swift_literal}"
}}
''')
        self._write(root, "android/lib/src/main/kotlin/com/phonedsh/ui/page/DemoPage.kt", f'''\
package com.phonedsh.ui.page

public object DemoText {{
    public const val ROW: String =
        "{swift_literal}"
}}

public fun DemoPage() {{
    PcPairingHint(DemoText.ROW)
}}

private fun PcPairingHint(text: String) {{
    BasicText(text = text)
}}
''')
        self._write(root, "spec/ui/v1/pages/_whitelist.json",
                    json.dumps(whitelist(), ensure_ascii=False))
        self._write(root, "spec/platform/whitelist.json",
                    json.dumps(platform_whitelist(), ensure_ascii=False))
        page_path = root / "examples/probe-app/PhoneDSHProbe/DemoPage.swift"
        page = extract.extract_page(root, page_path, "DemoPage")
        self._write(root, "spec/ui/v1/pages/demo.json",
                    json.dumps(page, ensure_ascii=False, indent=2))
        return page

    def test_matching_static_literal_passes_and_a_swift_mutation_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            page = self._fixture(root, "同一行")
            self.assertEqual("同一行", page["sections"][0]["criterion"]["label"])
            self.assertEqual("DemoCopy.swift:2",
                             page["sections"][0]["rows"][0]["labelSource"])
            rc, out = run_check(root)
            self.assertEqual(rc, 0, out)

            # Mutate only the Swift definition: the contract must follow it, and the
            # Android page that still renders the old wording must stop matching.
            self._write(root, "Sources/App/DemoCopy.swift", """\
struct DemoCopy {
    static let row =
        "改过的行"
}
""")
            page_path = root / "examples/probe-app/PhoneDSHProbe/DemoPage.swift"
            page = extract.extract_page(root, page_path, "DemoPage")
            self._write(root, "spec/ui/v1/pages/demo.json",
                        json.dumps(page, ensure_ascii=False, indent=2))
            self.assertEqual("改过的行", page["sections"][0]["criterion"]["label"])
            rc, out = run_check(root)
            self.assertEqual(rc, 1, out)
            self.assertIn("missing-section", out)
            self.assertIn("改过的行", out)


if __name__ == "__main__":
    unittest.main()
