# SPDX-License-Identifier: MIT
"""Mutation tests for the extractor's action-ownership rule.

An action belongs to the page whose struct body contains it — that is what
`PageExtractor._live` has always meant. `_inline_presented_actions` used to copy the
actions of a *sibling* `private struct` (the presented sheet's content) into the
parent contract, bypassing that test: it put `刷新`/`完成` from
`NativeJobListSheet`/`NativeScheduleListSheet`/`CommandExecutionResultPage` into
`pages/chat.json` and `保存`/`修改计划时间` from `ScheduleEditorPage` into
`pages/native-automation.json`, although `ChatPage`/`NativeAutomationPage` never
render those structs.

These tests pin both directions of the rule:
  * a sibling screen (`private struct DemoSheet` at file scope) is not this page's;
  * a nested helper view (declared inside the page struct, no screen chrome) still is;
  * a nested screen (own `navigationTitle`/`.toolbar`) is not.
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import extract_ios_pages as E  # noqa: E402


class ToolbarPickerTests(unittest.TestCase):
    def test_picker_in_toolbar_is_extracted_without_duplicating_body_pickers(self) -> None:
        swift = '''import SwiftUI
struct NativeWorkbenchPage: View {
    @State private var section = 0
    var body: some View {
        NavigationStack {
            Section("Controls") {
                Picker("普通选项", selection: $section) {
                    Text("普通值").tag(2)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("工作区", selection: $section) {
                        Text("文件").tag(0)
                        Text("命令").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "examples/probe-app/PhoneDSHProbe/NativeWorkbenchPage.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(swift, encoding="utf-8")
            source = E.Source(source_path, root)
            page = E.PageExtractor(source, "NativeWorkbenchPage").run(E.page_structs(source))

        picker_actions = [action for action in page["actions"] if action["kind"] == "picker"]
        self.assertEqual(len(picker_actions), 2)
        ordinary = [action for action in picker_actions if action["label"] == "普通选项"]
        toolbar = [action for action in picker_actions if action["label"] == "工作区"]
        self.assertEqual(len(ordinary), 1, "ordinary body Picker must not be re-added by the toolbar scan")
        self.assertEqual(len(toolbar), 1)
        self.assertEqual(toolbar[0]["items"], ["工作区", "文件", "命令"])
        self.assertEqual(toolbar[0]["style"], "segmented")


CHAT_HELPER_PLAN = '''import SwiftUI
struct ChatPage: View {
    var body: some View {
        VStack {
            PermissionCardView(onAllow: { respond(.allowOnce) }, onDeny: { respond(.deny) })
            NativePlanReviewCard(onApprove: { submitPlanApproval(item) },
                                 onRequestChanges: { model.dismissQuestion() })
            NativeQuestionComposer(onSubmit: { submitQuestion($0) },
                                   onDiscard: { model.dismissQuestion() })
            if !model.todoDockItems.isEmpty {
                NativeTodoDock(todos: model.todoDockItems)
            }
        }
    }
}
struct PermissionCardView: View {
    var onAllow: () -> Void
    var onDeny: () -> Void
    var body: some View {
        VStack {
            Button { onAllow() } label: { Text("允许一次") }
            Button { onDeny() } label: { Text("拒绝") }
        }
    }
}
'''

PLAN_HELPER = '''import SwiftUI
struct NativePlanReviewCard: View {
    static let requestChangesText = "要求修改"
    static let approveText = "同意执行"
    var onRequestChanges: () -> Void
    var onApprove: () -> Void
    var body: some View {
        VStack {
            Button(action: onRequestChanges) { Text(Self.requestChangesText) }
            Button(action: onApprove) { Text(Self.approveText) }
        }
    }
}
'''

QUESTION_HELPER = '''import SwiftUI
enum NativeQuestionCopy { static let skip = "跳过" }
struct NativeQuestionComposer: View {
    var onSubmit: (String) -> Void
    var onDiscard: () -> Void
    var body: some View {
        NativeQuestionActionButton(title: NativeQuestionCopy.skip,
                                   enabled: !isSubmitting) { skipCurrent() }
    }
    private func skipCurrent() { drafts[index].skipped = true; submitDrafts() }
}
'''

TODO_HELPER = '''import SwiftUI
struct NativeTodoDock: View {
    public static let title = "任务"
    private var header: some View {
        Button { collapsed.toggle() } label: {
            HStack { Text(Self.title) }
        }
    }
}
'''


class VerifiedChatHelperActionTests(unittest.TestCase):
    def _extract(self, chat: str = CHAT_HELPER_PLAN, plan: str = PLAN_HELPER,
                 question: str = QUESTION_HELPER, todo: str = TODO_HELPER) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_dir = root / "examples/probe-app/PhoneDSHProbe"
            source_dir.mkdir(parents=True)
            (source_dir / "ChatPage.swift").write_text(chat, encoding="utf-8")
            (source_dir / "NativePlanReviewCard.swift").write_text(plan, encoding="utf-8")
            (source_dir / "NativeQuestionComposer.swift").write_text(question, encoding="utf-8")
            (source_dir / "NativeTodoDock.swift").write_text(todo, encoding="utf-8")
            source = E.Source(source_dir / "ChatPage.swift", root)
            return E.PageExtractor(source, "ChatPage").run(E.page_structs(source))

    def test_only_mounted_helpers_with_forwarded_callbacks_are_inlined(self) -> None:
        page = self._extract()
        labels = {action["label"] for action in page["actions"]}
        self.assertTrue({"允许一次", "拒绝", "要求修改", "同意执行", "跳过", "任务"}.issubset(labels))
        sources = {action["label"]: action["provenance"] for action in page["actions"]}
        self.assertEqual("NativePlanReviewCard.swift:3", sources["要求修改"])
        self.assertEqual("NativeQuestionComposer.swift:2", sources["跳过"])
        self.assertEqual("NativeTodoDock.swift:3", sources["任务"])

    def test_unmounted_helper_and_missing_callback_do_not_promote_actions(self) -> None:
        no_permission_call = CHAT_HELPER_PLAN.replace(
            "PermissionCardView(onAllow: { respond(.allowOnce) }, onDeny: { respond(.deny) })", "")
        labels = {action["label"] for action in self._extract(chat=no_permission_call)["actions"]}
        self.assertNotIn("允许一次", labels)
        self.assertNotIn("拒绝", labels)

        no_permission_handler = CHAT_HELPER_PLAN.replace(
            "onAllow: { respond(.allowOnce) }", "onAllow: { }")
        labels = {action["label"] for action in self._extract(chat=no_permission_handler)["actions"]}
        self.assertNotIn("允许一次", labels)
        self.assertNotIn("拒绝", labels)

        no_question_call = CHAT_HELPER_PLAN.replace(
            "NativeQuestionComposer(onSubmit: { submitQuestion($0) },\n                                   onDiscard: { model.dismissQuestion() })", "")
        labels = {action["label"] for action in self._extract(chat=no_question_call)["actions"]}
        self.assertNotIn("跳过", labels)

        no_plan_handler = CHAT_HELPER_PLAN.replace(
            "onRequestChanges: { model.dismissQuestion() }", "onRequestChanges: { }")
        labels = {action["label"] for action in self._extract(chat=no_plan_handler)["actions"]}
        self.assertNotIn("要求修改", labels)
        self.assertNotIn("同意执行", labels)

    def test_missing_helper_controls_stay_missing(self) -> None:
        no_deny_button = CHAT_HELPER_PLAN.replace(
            'Button { onDeny() } label: { Text("拒绝") }', 'Text("拒绝")')
        labels = {action["label"] for action in self._extract(chat=no_deny_button)["actions"]}
        self.assertNotIn("拒绝", labels)

        no_plan_approve = PLAN_HELPER.replace(
            'Button(action: onApprove) { Text(Self.approveText) }', 'Text(Self.approveText)')
        labels = {action["label"] for action in self._extract(plan=no_plan_approve)["actions"]}
        self.assertNotIn("同意执行", labels)

        no_skip = QUESTION_HELPER.replace(
            'NativeQuestionActionButton(title: NativeQuestionCopy.skip,\n                                   enabled: !isSubmitting) { skipCurrent() }',
            "Text(NativeQuestionCopy.skip)")
        labels = {action["label"] for action in self._extract(question=no_skip)["actions"]}
        self.assertNotIn("跳过", labels)

        no_skip_handler = QUESTION_HELPER.replace(
            "private func skipCurrent() { drafts[index].skipped = true; submitDrafts() }", "")
        labels = {action["label"] for action in self._extract(question=no_skip_handler)["actions"]}
        self.assertNotIn("跳过", labels)

        no_todo_toggle = TODO_HELPER.replace(
            'Button { collapsed.toggle() } label: {\n            HStack { Text(Self.title) }\n        }',
            'Text(Self.title)')
        labels = {action["label"] for action in self._extract(todo=no_todo_toggle)["actions"]}
        self.assertNotIn("任务", labels)

        no_todo_guard = CHAT_HELPER_PLAN.replace(
            "if !model.todoDockItems.isEmpty {\n                NativeTodoDock(todos: model.todoDockItems)\n            }",
            "NativeTodoDock(todos: model.todoDockItems)")
        labels = {action["label"] for action in self._extract(chat=no_todo_guard)["actions"]}
        self.assertNotIn("任务", labels)


class TitledSectionHelperTests(unittest.TestCase):
    def _extract(self, swift: str) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "examples/probe-app/PhoneDSHProbe/SettingsPage.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(swift, encoding="utf-8")
            source = E.Source(source_path, root)
            return E.PageExtractor(source, "FontSizeSettingsPage").run(E.page_structs(source))

    def test_native_font_role_section_call_sites_keep_their_own_titles_and_lines(self) -> None:
        swift = '''import SwiftUI
struct FontSizeSettingsPage: View {
    var body: some View {
        List {
            section(.text, NativeText("会话内容", "Conversation"))
            section(.code, NativeText("代码", "Code"))
            section(.terminal, NativeText("终端", "Terminal"))
        }
    }
    private func section(_ role: NativeFontRole, _ title: String) -> some View {
        return Section {
            Text("Size")
        } header: { Text(title) }
    }
}
'''
        page = self._extract(swift)
        self.assertEqual(["会话内容", "代码", "终端"], [section["title"] for section in page["sections"]])
        self.assertEqual([
            "SettingsPage.swift:5", "SettingsPage.swift:6", "SettingsPage.swift:7",
        ], [section["provenance"] for section in page["sections"]])
        self.assertEqual(3, page["extraction"]["sectionKeywordsInPage"])

    def test_dynamic_call_site_title_is_not_guessed_or_expanded(self) -> None:
        swift = '''import SwiftUI
struct FontSizeSettingsPage: View {
    var body: some View { List { section(.text, role.title) } }
    private func section(_ role: NativeFontRole, _ title: String) -> some View {
        return Section { Text("Size") } header: { Text(title) }
    }
}
'''
        page = self._extract(swift)
        self.assertEqual(1, len(page["sections"]))
        self.assertIsNone(page["sections"][0]["title"])
        self.assertEqual("title", page["sections"][0]["titleExpression"])


SIBLING_SHEET = """\
import SwiftUI

struct DemoPage: View {
    @State private var showSheet = false

    var body: some View {
        List {
            Section("内容") {
                Button("提交") { submit() }
            }
        }
        .sheet(isPresented: $showSheet) {
            DemoSheet()
                .presentationDetents([.medium])
        }
    }
}

private struct DemoSheet: View {
    var body: some View {
        NavigationStack {
            List {
                Section("条目") {
                    Text("一")
                }
            }
            .navigationTitle("条目")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新") { refresh() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
"""

NESTED_HELPER = """\
import SwiftUI

struct DemoPage: View {
    @State private var showConfirm = false

    var body: some View {
        List {
            Section("内容") {
                Text("行")
            }
        }
        .sheet(isPresented: $showConfirm) {
            NestedConfirm()
        }
    }

    private struct NestedConfirm: View {
        var body: some View {
            VStack {
                Button("移除") { remove() }
                Button("保留") { keep() }
            }
        }
    }
}
"""

NESTED_SCREEN = """\
import SwiftUI

struct DemoPage: View {
    @State private var showEditor = false

    var body: some View {
        List {
            Section("内容") {
                Text("行")
            }
        }
        .sheet(isPresented: $showEditor) {
            NestedEditor()
        }
    }

    private struct NestedEditor: View {
        var body: some View {
            Form {
                Section("字段") {
                    Text("值")
                }
            }
            .navigationTitle("编辑")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }
}
"""


HEADERLESS_SECTION_WITH_COUNTER_ROW = """\
import SwiftUI

struct DemoPage: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Text("\\(report.itemCount) 条内容")
                    Spacer()
                    Text("新增 \\(report.newItemCount)")
                }
            }
            Section {
                Text("\\(count) 个会话")
            }
            Section("最新一期") {
                Text("行")
            }
        }
    }
}
"""


IF_SHAPED_LABEL = """\
import SwiftUI

struct DemoPage: View {
    @State private var saving = false
    @State private var existing: String?

    var body: some View {
        Form {
            Section("块") {
                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView()
                    } else {
                        Text(existing == nil ? "保存并连接" : "保存修改并重连")
                    }
                }
                Button {
                    toggle()
                } label: {
                    if flags.allow {
                        Text("永远允许")
                    } else {
                        Text("询问")
                    }
                }
                Button {
                    toggle()
                } label: {
                    ZStack {
                        if saving {
                            ProgressView()
                        } else {
                            Text("保存")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                Button {
                    pick()
                } label: {
                    if chosen {
                        Text(currentName)
                    } else {
                        Text(alternateName)
                    }
                }
            }
        }
    }
}
"""


HEADERLESS_SECTION_CRITERION = """\
import SwiftUI

struct DemoPage: View {
    var body: some View {
        List {
            Section {
                Text(model.snapshot == nil ? "还没有简报" : "每日简报")
                if let date = model.lastSuccessfulAt {
                    Text("最近成功 \\(date, style: .relative)")
                } else {
                    Text("添加来源后，打开页面就会更新")
                }
            }
            Section("最新一期") {
                Text("行")
            }
        }
    }
}
"""


def extract(swift: str) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        path = root / "DemoPage.swift"
        path.write_text(swift, encoding="utf-8")
        source = E.Source(path, root)
        return E.PageExtractor(source, "DemoPage").run(E.page_structs(source))


def labels(page: dict) -> dict:
    return {action["label"]: action for action in page["actions"] if action.get("label")}


class ActionOwnershipTest(unittest.TestCase):
    def test_page_actions_still_extracted(self):
        page = extract(SIBLING_SHEET)
        self.assertIn("提交", labels(page), "the page's own button must survive")

    def test_a_presented_sheet_is_part_of_the_parent_contract(self):
        """README §1: 内嵌子页随父页实现、不单独排期.

        A presented sheet is therefore the parent's contract: Android is told to
        implement it together with the page, and the finding it produces when the
        sheet is missing ("this embedded screen does not exist") is the work item.
        Excluding these was tried and reverted — it hid five real gaps and turned
        sixteen faithfully-implemented inline controls into invented extra-actions.
        """
        page = extract(SIBLING_SHEET)
        names = labels(page)
        self.assertIn("刷新", names, "a presented sheet's toolbar is the parent's contract")
        self.assertIn("关闭", names)
        self.assertTrue([a for a in page["actions"] if a.get("presentedBy")],
                        "inlined actions carry presentedBy so the owner is still visible")

    def test_presentation_is_still_recorded(self):
        page = extract(SIBLING_SHEET)
        self.assertEqual(["DemoSheet"], [p["destination"] for p in page["presentations"]])

    def test_nested_helper_view_buttons_belong_to_the_page(self):
        page = extract(NESTED_HELPER)
        names = labels(page)
        self.assertIn("移除", names, "a nested helper row inside the page struct is the page's own")
        self.assertIn("保留", names)

    def test_a_nested_screen_is_also_part_of_the_parent_contract(self):
        """Same rule as the presented sheet, and for the same reason (§1)."""
        page = extract(NESTED_SCREEN)
        self.assertIn("保存", labels(page),
                      "an embedded screen ships with the page that presents it")


class UntitledGroupTitleTest(unittest.TestCase):
    """A group title is declared, never read out of the group's own rows.

    `DailyBriefPage.swift:18` is a `Section { … }` with no header argument at all:
    the grouping is positional (a List gap). Its first row is a counter
    (`Text("\\(report.itemCount) 条内容")`), and the extractor used to adopt that
    row's label as the group's `titleTemplate` — inventing a section the page never
    renders and a `missing-section` finding on every implementation that does not
    render one either. The regressions pinned here are the two shapes that must
    stay apart.
    """

    def test_a_counter_row_inside_a_container_is_not_a_group_title(self):
        page = extract(HEADERLESS_SECTION_WITH_COUNTER_ROW)
        first = page["sections"][0]
        self.assertIsNone(first["title"],
                          "the HStack's counter is a row, not the group's name")
        self.assertIsNone(first["titleTemplate"])
        self.assertEqual("absent", first["titleSource"])

    def test_a_top_level_template_still_names_the_group(self):
        """The fallback is not dead: a direct-child template names the shape."""
        page = extract(HEADERLESS_SECTION_WITH_COUNTER_ROW)
        second = page["sections"][1]
        self.assertEqual("template", second["titleSource"])
        self.assertEqual("{count} 个会话", second["titleTemplate"])

    def test_a_literal_section_title_is_untouched(self):
        page = extract(HEADERLESS_SECTION_WITH_COUNTER_ROW)
        self.assertEqual("最新一期", page["sections"][2]["title"])


class LabelClosureTest(unittest.TestCase):
    """A label closure that *is* an `if` must be read, and only where that is safe.

    `MCPSettingsPage.swift:239` labels its save button with
    `if saving { ProgressView() } else { Text(existing == nil ? "保存并连接" : "保存修改并重连") }`.
    `_label_from_if` could already return `保存并连接` when called by hand, yet the
    real extraction produced `label: null`: `_label_from_view_closure` skipped the
    statement at `if not call: continue`, because `call_parts` answers `{}` for a
    bare `if`, so `_label_from_if` was never reached. These tests pin the chain and
    the three bounds that keep the fix from rewriting every label closure.
    """

    def test_an_if_shaped_label_resolves_with_its_other_wording(self) -> None:
        """The steady wording is the label; the other state's copy is the alternative.

        Same rule as `Button(saving ? "添加中…" : "添加")` — `添加` is the label — so
        the save button is `保存修改并重连` with `保存并连接` as the other wording.
        """
        page = extract(IF_SHAPED_LABEL)
        save = next(a for a in page["actions"] if a.get("label") == "保存修改并重连")
        self.assertEqual(["保存并连接"], save["labelAlternatives"])
        self.assertEqual("DemoPage.swift:16", save["provenance"],
                         "the anchor is the Text that renders the wording, not the Button")

    def test_both_branches_are_wordings_of_one_control(self) -> None:
        page = extract(IF_SHAPED_LABEL)
        other = next(a for a in page["actions"] if a.get("label") == "询问")
        self.assertEqual(["永远允许"], other["labelAlternatives"])
        self.assertEqual(1, len([a for a in page["actions"] if a.get("label") == "询问"]),
                         "an alternative is not a second action")

    def test_an_if_inside_a_container_stays_unresolved(self) -> None:
        """`ZStack { if … } .frame(…)` keeps its old shape: no invented label.

        Treating any nested `if` as the label would also have relabeled
        `WebSearchSettingsPage`'s save key, whose Android twin is built around the
        contract carrying no wording for it.
        """
        page = extract(IF_SHAPED_LABEL)
        self.assertNotIn("保存", labels(page))

    def test_an_expression_only_if_stays_unresolved(self) -> None:
        """No literal in either branch: no label, exactly as before the fix.

        `ChatPage.swift:2174` labels its model menu the same way
        (`Text(effortTitle(effort))`), so returning an expression here would rewrite
        three dozen labels this lane has no business deciding.
        """
        page = extract(IF_SHAPED_LABEL)
        last = page["actions"][-1]
        self.assertIsNone(last["label"])
        self.assertIsNone(last["labelExpr"])


class UntitledCriterionTest(unittest.TestCase):
    """What identifies a group with no header: a row that renders the same everywhere.

    `DailyBriefPage`'s first `Section` has no header argument, its first row is a
    ternary headline (two renderable strings) and its second is a counter template.
    Neither is a stable name for the group, so the criterion has to be the plain
    literal below them — otherwise the group is "missing" whenever the page happens
    to render the other branch.
    """

    def test_a_plain_literal_beats_a_ternary_and_a_template(self) -> None:
        page = extract(HEADERLESS_SECTION_CRITERION)
        criterion = page["sections"][0]["criterion"]
        self.assertEqual("first-row", criterion["kind"])
        self.assertEqual("添加来源后，打开页面就会更新", criterion["label"])
        self.assertEqual("DemoPage.swift:11", criterion["provenance"])


DYNAMIC_SECTION_HEADER = """\
import SwiftUI

struct DemoPage: View {
    var body: some View {
        List {
            Section {
                ForEach(group.fields) { field in
                    Text(field.title)
                }
            } header: {
                Text(nativeSettingsGroupTitle(group))
            }
        }
    }
}
"""

SETTINGS_ROW_LABEL = """\
import SwiftUI

struct DemoPage: View {
    var body: some View {
        List {
            Section("连接") {
                Button {
                    edit()
                } label: {
                    SettingsRowLabel(title: NativeText("模型服务", "Model providers"), icon: "cpu")
                }
            }
        }
    }
}
"""

DEEP_LINK_INIT = """\
import SwiftUI

struct DemoPage: View {
    @State private var deepLink: String?

    init(initial: String = "") {
        _deepLink = State(initialValue: initial.isEmpty ? nil : initial)
    }

    var body: some View {
        List {
            Section("索引") {
                Text("行")
            }
        }
        .navigationDestination(item: $deepLink) { tab in
            DetailPage(tab: tab)
        }
    }
}

private struct DetailPage: View {
    let tab: String
    var body: some View { Text(tab) }
}
"""

EMBEDDED_SUBPAGES = """\
import SwiftUI

struct DemoPage: View {
    var body: some View {
        List {
            Section("索引") {
                Text("行")
            }
        }
    }
}

private struct FontSizeSettingsPage: View {
    var body: some View { Text("字号") }
}

private struct ConversationSettingsPage: View {
    var body: some View {
        List { Section("工作步骤") { Text("行") } }
    }
}

private struct ArchivedSessionsPage: View {
    var body: some View { Text("已归档") }
}
"""


class Pr22ConstructTest(unittest.TestCase):
    """The PR22 constructs the scanner used to mishandle."""

    def test_a_data_driven_section_header_is_an_expression_not_suppressed(self) -> None:
        page = extract(DYNAMIC_SECTION_HEADER)
        section = page["sections"][0]
        self.assertEqual("expression", section["titleSource"])
        self.assertEqual("nativeSettingsGroupTitle(group)", section["titleExpression"])
        self.assertIsNone(section["title"])
        self.assertFalse(section.get("suppressed"))
        self.assertIn("criterion", section,
                      "a data-driven title must be identified by a row criterion")

    def test_a_settings_row_label_wrapper_supplies_the_action_wording(self) -> None:
        page = extract(SETTINGS_ROW_LABEL)
        self.assertIn("模型服务", labels(page))

    def test_a_state_seeded_in_init_is_a_live_presentation(self) -> None:
        page = extract(DEEP_LINK_INIT)
        destination = next(p for p in page["presentations"]
                           if p["kind"] == "navigationDestination")
        self.assertTrue(destination["triggered"])
        self.assertFalse(destination.get("deadUi", False))

    def test_pr22_settings_subpages_are_registered_as_embedded(self) -> None:
        page = extract(EMBEDDED_SUBPAGES)
        embedded = {sub["name"]: sub["embedded"] for sub in page["subpages"]}
        self.assertTrue(embedded["FontSizeSettingsPage"])
        self.assertTrue(embedded["ConversationSettingsPage"])
        self.assertTrue(embedded["ArchivedSessionsPage"])


class LicensesSingleRegionTest(unittest.TestCase):
    def _extract(self, content: str) -> dict:
        swift = """import SwiftUI
struct LicensesPage: View {
    var body: some View {
""" + content + """
    }
}
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "examples/probe-app/PhoneDSHProbe/SettingsPage.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(swift, encoding="utf-8")
            source = E.Source(source_path, root)
            return E.PageExtractor(source, "LicensesPage").run(E.page_structs(source))

    def test_exact_two_direct_license_rows_are_classified_as_one_region(self) -> None:
        page = self._extract('''
        List {
            LabeledContent("SwiftTerm", value: "MIT")
            LabeledContent("swift-nio", value: "Apache 2.0")
        }
        .homeGroupedList()
        .navigationTitle("开源许可")
''')
        self.assertEqual("single-region", page["sectionModel"])
        self.assertIn("direct LabeledContent license entries", page["sectionNote"])
        self.assertEqual(["SwiftTerm", "swift-nio"],
                         [row["label"] for row in page["sections"][0]["rows"]])

    def test_a_section_or_extra_direct_child_disables_that_classification(self) -> None:
        with_section = self._extract('''
        List {
            Section {
                LabeledContent("SwiftTerm", value: "MIT")
                LabeledContent("swift-nio", value: "Apache 2.0")
            }
        }
''')
        self.assertEqual("section", with_section["sectionModel"])
        self.assertIsNone(with_section["sectionNote"])

        with_extra_row = self._extract('''
        List {
            LabeledContent("SwiftTerm", value: "MIT")
            LabeledContent("swift-nio", value: "Apache 2.0")
            Text("More licenses")
        }
''')
        self.assertNotEqual("single-region", with_extra_row["sectionModel"])
        self.assertIsNone(with_extra_row["sectionNote"])


class ChromeContractTest(unittest.TestCase):
    """HomeDrawer/HomeSpec are chrome, not `*Page`, but must not leave the gate."""

    def _root(self, contract: bool = True) -> tuple:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        probe = root / E.PROBE_REL
        probe.mkdir(parents=True)
        (probe / "HomeDrawer.swift").write_text(
            "import SwiftUI\nstruct HomeDrawer: View { var body: some View { Text(\"x\") } }\n",
            encoding="utf-8")
        (probe / "HomeSpec.swift").write_text("enum HomeSpec {}\n", encoding="utf-8")
        if contract:
            pages = root / E.PAGES_REL
            pages.mkdir(parents=True)
            (pages / "home-drawer.json").write_text(json.dumps({
                "page": "HomeDrawer", "pageId": "home-drawer", "handRegistered": {"reason": "x"},
            }), encoding="utf-8")
        return tmp, root

    def test_the_hand_registered_chrome_contract_must_exist(self) -> None:
        tmp, root = self._root(contract=False)
        try:
            with self.assertRaises(E.ExtractError):
                E.check_chrome_contracts(root)
        finally:
            tmp.cleanup()

    def test_the_chrome_contract_and_home_spec_are_pinned(self) -> None:
        tmp, root = self._root()
        try:
            E.check_chrome_contracts(root)  # no raise
        finally:
            tmp.cleanup()

    def test_a_missing_home_spec_is_reported(self) -> None:
        tmp, root = self._root()
        try:
            (root / E.PROBE_REL / "HomeSpec.swift").unlink()
            with self.assertRaises(E.ExtractError):
                E.check_chrome_contracts(root)
        finally:
            tmp.cleanup()




class PageSourceCompletenessTests(unittest.TestCase):
    def test_shared_completeness_cases_use_real_extractor(self) -> None:
        import contextlib
        import io
        import shutil

        repo = Path(__file__).resolve().parents[4]
        shared = repo / "spec/ui/v1/golden/page-completeness"
        sys.path.insert(0, str(repo / "spec/v1/tools"))
        from spec_golden import load_json, validate_json
        sys.path.insert(0, str(repo / "spec/platform/tools"))
        from platform_check import lint_schema

        schema = load_json(shared / "cases.schema.json")
        lint_schema(schema, "page completeness cases")
        cases = [json.loads(line) for line in (shared / "cases.jsonl").read_text(encoding="utf-8").splitlines() if line]
        self.assertEqual(len(cases), 5)
        for case in cases:
            validate_json(case, schema, "page completeness case")
            with self.subTest(case=case["name"]), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                probe = root / "examples/probe-app/PhoneDSHProbe"
                pages = root / "spec/ui/v1/pages"
                probe.mkdir(parents=True)
                pages.mkdir(parents=True)
                source = probe / "FixturePage.swift"
                shutil.copyfile(shared / "FixturePage.swift", source)
                contract = pages / "fixture.json"
                shutil.copyfile(shared / "fixture.json", contract)
                (probe / "HomeDrawer.swift").write_text("struct HomeDrawer {}\n", encoding="utf-8")
                (probe / "HomeSpec.swift").write_text("struct HomeSpec {}\n", encoding="utf-8")
                chrome = pages / "home-drawer.json"
                chrome.write_text(json.dumps({"page": "HomeDrawer", "handRegistered": {"reason": "fixture"}}), encoding="utf-8")
                mutation = case["mutation"]
                if mutation == "remove_contract":
                    contract.unlink()
                elif mutation == "change_source":
                    source.write_text(source.read_text(encoding="utf-8").replace("Continue", "Changed"), encoding="utf-8")
                elif mutation == "add_page":
                    (probe / "AnotherPage.swift").write_text(
                        "import SwiftUI\nstruct AnotherPage: View { var body: some View { Text(\"new\") } }\n", encoding="utf-8"
                    )
                    # The old README-name-only inventory is green even though
                    # AnotherPage has no structure contract. The real extractor
                    # below must still make this shared case red.
                    import ui_check
                    readme = root / "spec/ui/v1/README.md"
                    readme.write_text("FixturePage\nAnotherPage\n", encoding="utf-8")
                    self.assertEqual(ui_check.check_pages(root, readme.read_text(encoding="utf-8")), (2, True))
                elif mutation == "remove_chrome":
                    chrome.unlink()
                elif mutation != "none":
                    self.fail("unknown shared mutation " + mutation)
                output, errors = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                    status = E.main(["--root", str(root), "--check"])
                self.assertEqual(status == 0, case["valid"], output.getvalue() + errors.getvalue())


class InactiveBuildFlagTests(unittest.TestCase):
    SOURCE = """struct P: View {
    var body: some View {
        List {
            Button("live") { }
            #if PDSH_ENABLE_DEVICE_TASKS
            Toggle("gated", isOn: $x)
            #else
            Button("fallback") { }
            #endif
            #if DEBUG
            Button("debug") { }
            #endif
        }
    }
}
"""

    def test_inactive_flag_body_is_blanked_and_else_branch_kept(self) -> None:
        masked = E.mask_inactive_conditionals(E.mask_comments(self.SOURCE))
        self.assertEqual(len(masked), len(self.SOURCE))
        self.assertEqual(masked.count("\n"), self.SOURCE.count("\n"))
        self.assertNotIn("Toggle", masked)
        self.assertIn("Button(", masked.split("#else", 1)[1])
        self.assertIn("Button(", masked.split("#if DEBUG", 1)[1])

    def test_nested_inactive_region_stays_blank_until_outer_endif(self) -> None:
        src = "#if PDSH_ENABLE_DEVICE_TASKS\nA()\n#if DEBUG\nB()\n#endif\nC()\n#endif\nD()\n"
        masked = E.mask_inactive_conditionals(src)
        for gone in ("A()", "B()", "C()"):
            self.assertNotIn(gone, masked)
        self.assertIn("D()", masked)

    def test_app_target_does_not_define_an_inactive_flag(self) -> None:
        root = Path(__file__).resolve().parents[4]
        app = (root / "examples/probe-app/project.yml").read_text(encoding="utf-8")
        for flag in E.INACTIVE_BUILD_FLAGS:
            self.assertNotIn(flag, app, f"{flag} is set for the app target; it is product UI again")


class OutermostNavigationTitleTests(unittest.TestCase):
    def test_pushed_destination_title_does_not_become_the_page_title(self) -> None:
        swift = """import SwiftUI
struct LicensesPage: View {
    var body: some View {
        List {
            NavigationLink("全文") {
                Text("x").navigationTitle("子页")
            }
        }
        .navigationTitle("开源许可")
    }
}
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "examples/probe-app/PhoneDSHProbe/SettingsPage.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(swift, encoding="utf-8")
            source = E.Source(source_path, root)
            page = E.PageExtractor(source, "LicensesPage").run(E.page_structs(source))
        self.assertEqual("开源许可", page["title"]["text"])
        self.assertEqual("SettingsPage.swift:9", page["title"]["provenance"])

    def test_dynamic_outer_title_does_not_promote_a_nested_literal(self) -> None:
        swift = """import SwiftUI
struct LicensesPage: View {
    var title: String = "插件与工具"
    var body: some View {
        List {
            Text("x")
        }
        .navigationTitle(title)
        .sheet(isPresented: .constant(false)) {
            Text("y").navigationTitle("插件说明")
        }
    }
}
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "examples/probe-app/PhoneDSHProbe/SettingsPage.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(swift, encoding="utf-8")
            source = E.Source(source_path, root)
            page = E.PageExtractor(source, "LicensesPage").run(E.page_structs(source))
        self.assertIsNone(page["title"])


if __name__ == "__main__":
    unittest.main()
