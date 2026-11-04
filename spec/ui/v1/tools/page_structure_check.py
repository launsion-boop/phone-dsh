#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check the Android pages against the iOS page-structure contract.

Purpose: `spec/ui/v1/pages/<page-id>.json` is the machine-readable structure of an
iOS baseline page (sections, rows, actions, states). This checker reads each Android
screen and fails when its section titles or action labels do not match, so the two
platforms cannot drift into two UI designs while the README's one-line page table
still looks aligned.

What is compared
---------------
* **sections**: the contract's titled sections against the titles the Android page
  declares. Order is not compared (the contract's order is documented, not enforced).
* **actions**: the contract's labelled actions (buttons, navigation rows, menus,
  pickers, toggles, search, toolbar, gestures) against the labels the Android page
  declares. Actions whose label only exists as an expression are `unresolved`, never
  silently equal. The summary row counts the **labelled** actions and the unique
  wordings they compare on (`labelled 36 of 67 actions (27 unlabelled, 4
  dynamicLabel) = 24 comparable keys` / `android 29 labels (24 keys)`), never "all
  actions" next to "Android labels": the 67 included 27 icon-only controls and 4
  data-driven labels, so printing 67 beside 29 read as 38 missing controls when
  both sides compared the same 24 keys.
* **titles**: the baseline's `.navigationTitle` against the title the Android page
  passes to its frame (`PageFrame(title = …)`, `SettingsSubPageFrame(title/largeTitle
  = …)`, `SettingsNavBar(title = …)`, and page-local `*Frame` / `*Bar` shells such as
  `AutomationFrame` / `ShellTopBar`). A title that differs is `title-mismatch`; a
  title only known at runtime is `unresolved-title`, never silently equal. A title
  the baseline itself renders through a condition (`directory.isEmpty ? … : …`) is
  data-driven on both sides and is not compared.
* **conditional controls**: a label (action or section title) inside `if (callback
  != null) { … }` or `callback?.let { … }`, where `callback` is a nullable
  parameter, exists only when the host supplies the callback. It is reported as
  `conditional-action` / `conditional-section` — never silently as present. This is
  the hole `files`'s `3D 示例` fell through: `FilesPage.kt:478` carried the label
  under `if (onOpenDemo != null)` while `PdshNavHost` never passed the callback, so
  the gate counted a control the pixels never showed. When the baseline guards the
  same item (its `condition`, or the Swift `if`/`else` around its provenance line),
  the guard is expected and the occurrence is listed, not failed; only an item the
  baseline always draws is a `conditional-*` divergence.
* **presentations**: a sheet/alert/destination is linked to the action that opens it
  (`presents`); one whose binding is never assigned is an `orphan-presentation` (the
  baseline's own dead UI, e.g. ChatPage's `showActivity`).
* **Android coverage**: every `public fun *Page()` in the Android page layer must be a
  contract screen, an embedded subpage named by a contract's `subpages`, or listed in
  `spec/ui/v1/pages/_android-only.json` (an Android screen the iOS baseline does not have).
* **provenance**: every contract item carries `File.swift:line` plus an `anchor`;
  the anchor must still be on that line, so a refactored baseline is reported as a
  stale contract instead of being compared forever against a moved page.
* **Android screen**: `android.file` must exist and still declare the mapped screen.

Android idioms this checker recognises (the machine-readable contract on that side)
-------------------------------------------------------------------------------
sections   `SessionSectionLabel(<title>)`, `SectionHeader(title = <title>)`,
           `<Name>SectionView(<id>, <title>, ...)` (second positional argument).
actions    `SessionTextAction(label = <label>)`, `InfoRow(title = <label>, ..., onClick = ...)`
           (only when the row is interactive), `SessionFailureLine(..., retryLabel = <label>)`.
           A group header's fold (`SectionHeader`) is chrome, not an action.
titles     `PageFrame(title = …)`, `SettingsSubPageFrame(title = … | largeTitle = …)`,
           `SettingsNavBar(title = …)`, plus page-local shells ending in `Frame`/`Bar`
           (`AutomationFrame(largeTitle = …)`, `ShellTopBar(title = …)`). The frame is
           looked up inside the mapped screen composable, so a subpage frame declared in
           the same file is not mistaken for the page's own title.

guards     `if (<param> != null) { … }`, `if (<param> == null) { … } else { … }` and
           `<param>?.let { … }` where `<param>` is a **nullable parameter of the enclosing
           composable**. A section title or action label inside such a block is
           conditionally present: it is reported as `conditional-section` /
           `conditional-action` (or listed as expected when the baseline guards the same
           item) and the summary row separates unconditional from conditional
           occurrences.

`<label>` resolves when it is a string literal or a `UiStrings.NAME` constant; any other
expression is reported as `unresolved` rather than guessed. The idioms are documented in
`spec/ui/v1/README.md` §1 so the Android lane knows what the gate reads.

`states` is **advisory**: the contract's state sites are marker-based and cannot tell a
row's placeholder (未配置/未设置/—) from a page state, so the checker never compares them.
A contract that tries to make `states` normative (no `"advisory": true`) is rejected.

Standard Compose controls are actions too, where the label is visible in the source:
`Button`/`OutlinedButton`/`TextButton`/`FilledTonalButton`/`ElevatedButton` (first `Text`
in the content lambda), `SegmentedButton`/`FilterChip` (`label = { }` or content), `Switch`/
`Checkbox` (nearest `Text` among the direct children of the same `Row`/`Column`, or `label =`),
`DropdownMenuItem` (its `text = { Text(…) }`), and page-local button wrappers such as
`ProbePrimaryButton(label = …)` (the wrapper declaration is skipped; the call site carries
the label). `DropdownMenu` itself is not an action: its trigger carries the label. A
`Button { Column { Text(title); Text(subtitle) } }` counts the first `Text` only.

Nullability of host-supplied data
--------------------------------
A non-null field with an `emptyList()` / `""` default forces the host to assert a fact it
does not have. If the host can lack the data, the field must be nullable: `null` means
"not reported" (the page renders 未知 / its own untitled policy), while `emptyList()` and
`""` mean "reported, and it is empty". This is the same rule as "an unknown value never
renders as 0", and `pinnedSessionIDs`, `workspaceOrder` and `SessionListing.title` are
three occurrences of it. The fields live in the Android host model (outside this
checker's tree); the rule is recorded here so the contract and the host stay aligned.

Gate or implementation? — the rule this gate follows
----------------------------------------------------
When the gate cannot see a correct implementation, **fix the gate**. When the
implementation hides the information (a data-driven title, a string assembled at
runtime), **fix the implementation**. The difference is whether the information is
*explicitly visible in the source*: `Button { Text("Run all probes") }` is visible, so the
gate must see it; `SettingsRowItem(row.title)` is only known at runtime, so the page has to
declare it (`UiStrings.X`). When this gate and a correct implementation disagree, check
which side hides the information before changing either.

Platform-forced differences: an explicit whitelist
--------------------------------------------------
`spec/ui/v1/pages/_whitelist.json` lists accepted differences. Each entry names the
page, the divergence kind, the affected title/label, the side (`ios-only` or
`android-only`), a `platformRef` that must be an `id` in `spec/platform/whitelist.json`,
an owner, a review date and a reason. Anything outside the whitelist is a failure. An
entry that no longer matches an observed divergence is a failure too (promote or delete
it), and a `reviewBy` date in the past is a failure (the debt gets re-reviewed).

The known-divergence ratchet
----------------------------
`--baseline FILE` accepts a set of already-known divergences so the gate can be wired
into CI while the Android lane works through them. A divergence that is *not* in the
baseline fails; a baseline entry that no longer diverges fails (it must be removed, so
the ratchet only shrinks). `--strict` ignores the baseline: that is the real measure of
the gap and the list of what the Android lane has left. `--write-baseline FILE` records
the current set; do that only when the change is reviewed as a ratchet move.

Usage:
    python3 spec/ui/v1/tools/page_structure_check.py [--root DIR] [--strict]
    python3 spec/ui/v1/tools/page_structure_check.py [--root DIR] --baseline FILE
    python3 spec/ui/v1/tools/page_structure_check.py [--root DIR] --write-baseline FILE

Exit code 0 when every rule passes, 1 on any mismatch, 2 on a usage or I/O error.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
import unicodedata
from pathlib import Path

UI_REL = Path("spec") / "ui" / "v1"
PAGES_REL = UI_REL / "pages"
WHITELIST_REL = PAGES_REL / "_whitelist.json"
BASELINE_REL = PAGES_REL / "_baseline.json"
PLATFORM_WHITELIST_REL = Path("spec") / "platform" / "whitelist.json"
ANDROID_UI_REL = Path("android") / "lib" / "src" / "main" / "kotlin" / "com" / "phonedsh" / "ui"
PROBE_REL = Path("examples") / "probe-app" / "PhoneDSHProbe"
UISTRINGS_REL = ANDROID_UI_REL / "UiStrings.kt"
SCHEMA = "pdsh.ui.page-structure/1"
WHITELIST_SCHEMA = "pdsh.ui.page-structure-whitelist/1"
BASELINE_SCHEMA = "pdsh.ui.page-structure-baseline/1"
KINDS = (
    "missing-section",
    "extra-section",
    "missing-action",
    "extra-action",
    "unresolved-section",
    "unresolved-action",
    "orphan-presentation",
    "unmapped-android-screen",
    "spec-baseline-mismatch",
    "android-only-stale",
    "title-mismatch",
    "missing-title",
    "unresolved-title",
    "conditional-action",
    "conditional-section",
)
# Cross-file actions that ChatPage explicitly mounts and whose callbacks the
# extractor verifies at that callsite. No other helper provenance is accepted.
CHAT_HELPER_ACTION_SOURCES = {
    "允许一次": "ChatPage.swift",
    "拒绝": "ChatPage.swift",
    "要求修改": "NativePlanReviewCard.swift",
    "同意执行": "NativePlanReviewCard.swift",
    "跳过": "NativeQuestionComposer.swift",
    "任务": "NativeTodoDock.swift",
}
TITLE_KINDS = ("title-mismatch", "missing-title", "unresolved-title")
#: The re-baseline is owned by a lane: C chat, D composer, E drawer/sessions,
#: F settings/provider, G secondary files/device/workbench, H integration. A
#: `--write-baseline` output marks new rows UNREVIEWED so a silent relaxation
#: cannot be loaded; a reviewer assigns the lane (and a real reason) by hand.
BASELINE_LANES = frozenset({"C", "D", "E", "F", "G", "H"})
UNREVIEWED_LANE = "UNREVIEWED"
ANDROID_ONLY_REL = PAGES_REL / "_android-only.json"
IOS_ONLY_REL = PAGES_REL / "_ios-only.json"
UNRECOGNIZED_REL = PAGES_REL / "_unrecognized.json"
UNRECOGNIZED_SCHEMA = "pdsh.ui.page-structure-unrecognized/1"
ANDROID_ONLY_SCHEMA = "pdsh.ui.page-structure-android-only/1"
IOS_ONLY_SCHEMA = "pdsh.ui.page-structure-ios-only/1"
SCREEN_FUN_RE = re.compile(r"^public fun (\w*Page)\s*\(", re.M)
SPEC_ROW_RE = re.compile(r"^\|\s*([A-Za-z]+Page)\s*\|([^|]*)\|([^|]*)\|([^|]*)\|\s*(must|later)\s*\|")
#: §1's entrance text names a *source page* (or the app shell). "抽屉" is the
#: NativeShell's drawer, not the sessions page: the entry lives in NativeShell.swift.
SHELL_FILE = "NativeShell.swift"
ENTRANCE_RULES = (
    ("设置行", "settings", True),     # "a row in SettingsPage" — that page's own body
    ("设置 →", "settings", True),
    ("设置", "settings", False),      # bare "设置": the area may be the shell's list
    ("抽屉", "shell", True),
    ("页头", "chat", True),
    ("RootView", "chat", True),
    ("对话里", "chat", True),
    ("工作面板", "native-workbench", True),
)
MATERIAL_BUTTONS = ("Button", "OutlinedButton", "TextButton", "FilledTonalButton", "ElevatedButton")
#: Composables that already have an explicit idiom; a wrapper heuristic must not
#: count their call sites a second time.
EXPLICIT_ACTION_IDIOMS = frozenset({
    "SessionTextAction", "SessionFailureLine", "InfoRow", "SectionHeader",
    "SessionSectionLabel", "EmptyHint", "PageFrame",
})
CHIP_CONTROLS = ("SegmentedButton", "FilterChip", "AssistChip", "InputChip")
TOGGLE_CONTROLS = ("Switch", "Checkbox")
#: Named arguments that carry the page title, in priority order (a frame that has
#: both draws `title` in its bar and `largeTitle` in the body; they are one title).
TITLE_KEYS = ("title", "largeTitle", "barTitle")
TITLE_CALL_RE = re.compile(r"\b([A-Z]\w*)[ \t]*\(")
#: A `.navigationTitle` that is itself an expression: the baseline does not fix one
#: title, so a data-driven Android title on that page is not a divergence.
CONTRACT_DYNAMIC_TITLE_RE = re.compile(r"\bnil\b|\bif\b|\bswitch\b|\?\?|\s\?\s|\.isEmpty\b")
TITLE_TOKEN_RE = re.compile(
    r'UiStrings\.([A-Z][A-Z0-9_]*)|"((?:[^"\\]|\\.)*)"|([A-Z][A-Z0-9_]+)')
FUN_DECL_RE = re.compile(r"\bfun\s+(\w+)\s*\(")
SIDES = {"ios-only", "android-only"}
PROVENANCE_RE = re.compile(r"^([A-Za-z][A-Za-z0-9]*\.swift):([0-9]+)$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
UISTRING_RE = re.compile(
    r"^[ \t]*public const val ([A-Z][A-Z0-9_]*): String = \"((?:[^\"\\]|\\.)*)\"[ \t]*$", re.M)
LOCAL_CONST_RE = re.compile(
    r"^[ \t]*(?:private |internal |public )?const val ([A-Z][A-Z0-9_]*)(?:: String)? = "
    r"\"((?:[^\"\\]|\\.)*)\"[ \t]*$", re.M)
CJK_RE = re.compile(r"[\u4e00-\u9fff]")
SECTION_CALL_RE = re.compile(r"\b([A-Z]\w*)[ \t]*\(")
#: Composables that render a visible row label; `Text` is the bare case, the rest
#: are the settings/row wrappers the pages use so the label is still explicit.
ROW_CALLS = frozenset({
    "Text", "BasicText", "InfoRow", "SettingsFormRow", "SettingsGroupedRow",
    "SettingsBodyRow", "SettingsFootnoteRow",
})
DECLARATION_TAIL_RE = re.compile(r"(?:\b(?:data|enum|sealed|abstract|open|private|internal|public|inline|suspend)\s+)*"
                                 r"(?:class|fun|object|interface|typealias)\s+$")
DYN_EXPR_MAX = 60


class CheckError(Exception):
    """A failed rule; carries the message printed after ``FAIL``."""


# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CheckError(f"cannot read {path}: {exc}") from exc


def load_json(path: Path) -> object:
    try:
        return json.loads(read_text(path))
    except json.JSONDecodeError as exc:
        raise CheckError(f"{path}: invalid JSON: {exc}") from exc


def mask_kotlin(text: str) -> str:
    """Blank comments and string bodies; indices and newlines are preserved."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            for k in range(i, min(j, n)):
                if text[k] != "\n":
                    out[k] = " "
            i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            for k in range(i, min(j, n)):
                if text[k] != "\n":
                    out[k] = " "
            i = j
        elif text[i] == "'":
            # Kotlin char literal. Without this, the `"` inside `'"'` opens a
            # phantom string and the rest of the file is masked away — which is
            # how a page that does declare `fun SessionArtifactsPage(` was
            # reported as missing it. Bail at a newline so a stray apostrophe
            # cannot eat the file either.
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                elif text[j] == "'":
                    j += 1
                    break
                elif text[j] == "\n":
                    break
                else:
                    j += 1
            for k in range(i, min(j, n)):
                if text[k] != "\n":
                    out[k] = " "
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                elif text[j] == '"':
                    j += 1
                    break
                else:
                    j += 1
            for k in range(i, min(j, n)):
                if text[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def match_paren(masked: str, open_pos: int) -> int:
    return match_delim(masked, open_pos, "(", ")")


def match_delim(masked: str, open_pos: int, opener: str, closer: str) -> int:
    depth = 0
    for i in range(open_pos, len(masked)):
        if masked[i] == opener:
            depth += 1
        elif masked[i] == closer:
            depth -= 1
            if depth == 0:
                return i
    return -1


def named_args(masked: str, open_paren: int, close: int) -> tuple:
    named, positional = {}, []
    for a, b in split_args(masked, open_paren + 1, close):
        nm = re.match(r"\s*([a-z][A-Za-z0-9_]*)\s*=(?!=)", masked[a:b])
        if nm:
            named[nm.group(1)] = (a + nm.end(), b)
        else:
            positional.append((a, b))
    return named, positional


def split_args(masked: str, start: int, end: int) -> list:
    spans, depth, s = [], 0, start
    for i in range(start, end):
        c = masked[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            spans.append((s, i))
            s = i + 1
    spans.append((s, end))
    return spans


def collapse(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


PRINTF_SLOT_RE = re.compile(r"%\d+\$[ds@]|%[ds@]")


def is_template_label(value: str) -> bool:
    """`%d 项需要处理` is data rendered by the page, not a fixed action label."""
    return bool(value) and bool(PRINTF_SLOT_RE.search(value))


def shortened_copy(actual: str, wordings: list) -> str | None:
    """The wording `actual` is a truncated copy of (`保存` for `保存并连接`), if any.

    A control whose copy was cut short is ONE divergence, not two: the baseline's
    `保存并连接` is missing *and* Android's `保存` is unclaimed, and reporting both
    reads as "the page invented a button and lost another one". Pairing keeps one
    row per defect and leaves the finding red — the copy still differs.
    """
    a = normalize(actual)
    if len(a) < 2:
        return None
    for wording in wordings:
        if a != normalize(wording) and normalize(wording).startswith(a):
            return wording
    return None


def action_wording(action: dict) -> list:
    """Every literal the baseline renders for one action, primary wording first.

    `labelAlternatives` exists because one control can legitimately render more than
    one string: `Text(existing == nil ? "保存并连接" : "保存修改并重连")` on the MCP
    editor's save button. The alternative is not a second action and not a second
    contract row — it is the same affordance, so either wording satisfies the
    contract and neither may be reported as an invented (`extra-action`) button.
    """
    out = []
    for value in [action.get("label"), *(action.get("labelAlternatives") or [])]:
        if not isinstance(value, str) or not value.strip() or value in out:
            continue
        if is_template_label(value):
            continue
        out.append(value)
    return out


def normalize(text: str) -> str:
    """Compare titles/labels on meaning, not on spacing, digits or template syntax.

    A template slot (`{count}`), a Swift interpolation, a Kotlin `%d` and a concrete
    number all collapse to one `#`, so `Rows (N)` matches `Rows (4)` and
    `5 个会话` matches `{count} 个会话`.
    """
    t = unicodedata.normalize("NFKC", text or "")
    t = t.replace("…", "...")
    t = re.sub(r"\\\([^()]*\)", "#", t)
    t = re.sub(r"\{[^{}]*\}", "#", t)
    t = re.sub(r"%\d+\$[sd]|%[sd]", "#", t)
    t = re.sub(r"\d+", "#", t)
    t = re.sub(r"\s+", "", t)
    return t.strip("·•-—:：")


def load_uistrings(root: Path) -> dict:
    """The `UiStrings` copy table only (the qualified `UiStrings.NAME` namespace)."""
    path = root / UISTRINGS_REL
    if not path.is_file():
        return {}
    return {name: value.replace('\\"', '"').replace("\\n", "\n")
            for name, value in UISTRING_RE.findall(read_text(path))}


def load_page_consts(root: Path) -> dict:
    """Unqualified `const val` in the page layer (glyphs, shared labels).

    `UiPageTags.kt` is excluded on purpose: a test tag such as
    `pdsh.sessions.workspace.new` is an automation handle, never a user-visible
    label, and it may share a constant *name* with a `UiStrings` entry.
    """
    out = {}
    page_dir = root / ANDROID_UI_REL / "page"
    if not page_dir.is_dir():
        return out
    for kt in sorted(page_dir.glob("*.kt")):
        if kt.name == "UiPageTags.kt":
            continue
        for name, value in local_constants(read_text(kt)).items():
            if value.startswith("pdsh."):
                continue
            out[name] = value
    return out


def strip_kotlin_comments(snippet: str) -> str:
    snippet = re.sub(r"/\*.*?\*/", " ", snippet, flags=re.S)
    snippet = re.sub(r"//[^\n]*", " ", snippet)
    return collapse(snippet)


def local_constants(text: str) -> dict:
    out = {}
    for name, value in LOCAL_CONST_RE.findall(text):
        out[name] = value.replace('\\"', '"').replace("\\n", "\n")
    return out


def is_chrome_label(value: str) -> bool:
    """An icon glyph is a short non-CJK string with no letters or digits (`×`, `+`).

    "Go" and "OK" are two characters but they are words, so they stay labels.
    """
    stripped = (value or "").strip()
    return (bool(stripped) and len(stripped) <= 2 and not CJK_RE.search(stripped)
            and not any(ch.isalnum() for ch in stripped))


def resolve_kotlin_expr(expr: str, strings: dict, consts: dict | None = None) -> tuple:
    """(value, dynamic): a literal, `UiStrings.NAME` or a page const resolves.

    Anything else (`state.title`, `if (...) ... else ...`) is dynamic and is
    reported as unresolved rather than guessed.
    """
    consts = consts or {}
    text = collapse(expr)
    m = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', text)
    if m:
        value = m.group(1).replace('\\"', '"').replace("\\n", "\n")
        if re.search(r"\$\{|\$[A-Za-z_]", value):
            return None, True  # `"/${command.name}"`: assembled at runtime
        return value, False
    m = re.fullmatch(r"UiStrings\.([A-Z][A-Z0-9_]*)", text)
    if m and m.group(1) in strings:
        return strings[m.group(1)], False
    m = re.fullmatch(r"UiStrings\.([A-Z][A-Z0-9_]*)\.format\((.*)\)", text, re.S)
    if m and m.group(1) in strings:
        return strings[m.group(1)], False
    m = re.fullmatch(r"([A-Z][A-Z0-9_]*)", text)
    if m and m.group(1) in consts:
        return consts[m.group(1)], False
    # NativeText-style localization preserves the Chinese contract identity.
    # Only this known API and its verified local forwarder resolve; arbitrary
    # wrappers/conditionals remain dynamic and cannot hide missing controls.
    localized = re.fullmatch(r"(UiStrings\.settingsNativeText|native)\s*\((.*)\)", text, re.S)
    if localized:
        name = localized.group(1)
        body = localized.group(2)
        parts = split_args(mask_kotlin(body), 0, len(body))
        expected = 3 if name == "UiStrings.settingsNativeText" else 2
        verified = name != "native" or consts.get("__native_text_forwarder__") is True
        if len(parts) == expected and verified:
            start, end = parts[1 if expected == 3 else 0]
            return resolve_kotlin_expr(body[start:end], strings, consts)
    # A conditional that falls back to `null` still names a label when it is shown.
    m = re.fullmatch(r"if\s*\((.+)\)\s*(.+?)\s*else\s+null", text, re.S)
    if m:
        value, dynamic = resolve_kotlin_expr(m.group(2), strings, consts)
        if not dynamic:
            return value, False
    return None, True


def kotlin_label_variants(expr: str, strings: dict, consts: dict) -> list[str]:
    """Resolve the literal alternatives of a small Compose label expression.

    Supports a `when` whose every branch returns one static label, an availability
    ternary whose unavailable branch explicitly says `不可用`, and the verified
    automation saving label ternary. Other expressions remain unresolved so
    state-derived wording does not become a static action inventory.
    """
    value = strip_kotlin_comments(collapse(expr))
    when = re.fullmatch(r"when\s*\([^{}]*\)\s*\{(.*)\}", value, re.S)
    if when:
        body = when.group(1)
        branches = re.findall(r"->\s*(\"(?:[^\"\\]|\\.)*\"|UiStrings\.[A-Z][A-Z0-9_]*)", body)
        if len(branches) != body.count("->"):
            return []
        out = []
        for branch in branches:
            resolved, dynamic = resolve_kotlin_expr(branch, strings, consts)
            if dynamic or not resolved:
                return []
            if resolved not in out:
                out.append(resolved)
        return out
    conditional = re.fullmatch(
        r"if\s*\((.+)\)\s*(\"(?:[^\"\\]|\\.)*\")\s*else\s*(\"(?:[^\"\\]|\\.)*\")",
        value, re.S)
    if conditional:
        branches = [resolve_kotlin_expr(conditional.group(index), strings, consts)
                    for index in (2, 3)]
        if all(not dynamic and label for label, dynamic in branches):
            # A fallback such as `归档不可用` is a disabled-state explanation, not
            # the label of the action the user can perform.
            available = [label for label, _ in branches if "不可用" not in label]
            return available or [label for label, _ in branches]
    # A saving-state toolbar action keeps its ordinary action identity while its
    # label briefly changes to a progress word. Count the steady action only when
    # both branches resolve to the exact verified static labels and the guard is
    # the editor's saving flag.
    saving_action = re.fullmatch(
        r"if\s*\(editor\.saving\)\s*([A-Z][A-Z0-9_]*|UiStrings\.[A-Z][A-Z0-9_]*)"
        r"\s*else\s*(UiStrings\.[A-Z][A-Z0-9_]*)",
        value)
    if saving_action:
        saving_label, saving_dynamic = resolve_kotlin_expr(saving_action.group(1), strings, consts)
        action_label, action_dynamic = resolve_kotlin_expr(saving_action.group(2), strings, consts)
        if (not saving_dynamic and saving_label == "保存中…" and
                not action_dynamic and action_label == "保存"):
            return [action_label]
    return []


# ---------------------------------------------------------------------------
# Contract loading and validation.
# ---------------------------------------------------------------------------


def load_unrecognized(root: Path, contracts: dict) -> list:
    """Explicit registry of structural items that cannot be compared statically."""
    path = root / UNRECOGNIZED_REL
    if not path.is_file():
        return []
    data = load_json(path)
    if not isinstance(data, dict) or data.get("schema") != UNRECOGNIZED_SCHEMA:
        raise CheckError(f"{UNRECOGNIZED_REL}: not a {UNRECOGNIZED_SCHEMA} document")
    entries = data.get("entries")
    if not isinstance(entries, list):
        raise CheckError(f"{UNRECOGNIZED_REL}: `entries` must be a list")
    for note in data.get("notes", []):
        for key in ("page", "text", "owner", "reviewBy"):
            if key not in note:
                raise CheckError(f"{UNRECOGNIZED_REL}: a note misses `{key}`")
        if note["page"] != "spec" and note["page"] not in contracts:
            raise CheckError(f"{UNRECOGNIZED_REL}: note names unknown page {note['page']!r}")
    today = datetime.date.today()
    for entry in entries:
        for key in ("page", "kind", "name", "reason", "owner", "reviewBy"):
            if key not in entry:
                raise CheckError(f"{UNRECOGNIZED_REL}: an entry misses `{key}`")
        if entry["page"] not in contracts:
            raise CheckError(f"{UNRECOGNIZED_REL}: unknown page {entry['page']!r}")
        if entry["kind"] not in KINDS:
            raise CheckError(f"{UNRECOGNIZED_REL}: unknown kind {entry['kind']!r}")
        if not DATE_RE.match(str(entry["reviewBy"])):
            raise CheckError(f"{UNRECOGNIZED_REL}: reviewBy must be YYYY-MM-DD")
        if datetime.date.fromisoformat(entry["reviewBy"]) < today:
            raise CheckError(f"{UNRECOGNIZED_REL}: entry {entry['page']}/{entry['name']!r} reviewBy is in the past")
        if not str(entry["reason"]).strip() or not str(entry["owner"]).strip():
            raise CheckError(f"{UNRECOGNIZED_REL}: entry {entry['page']}/{entry['name']!r} needs reason and owner")
    return entries


def apply_unrecognized(report: "Report", entries: list) -> None:
    """Move registered items out of the divergence set; an entry that matches nothing is stale."""
    by_key = {}
    for entry in entries:
        by_key.setdefault((entry["page"], entry["kind"], normalize(entry["name"])), entry)
    kept, matched = [], set()
    for finding in report.findings:
        key = (finding[0], finding[1], normalize(finding[2]))
        if key in by_key and key not in matched:
            matched.add(key)
            report.registered.append((finding, by_key[key]))
            continue
        kept.append(finding)
    report.findings = kept
    stale = [key for key in by_key if key not in matched]
    if stale:
        raise CheckError("registered entries match no finding (delete them): "
                         + ", ".join(f"{p}/{k}/{n!r}" for p, k, n in sorted(stale)))


def load_android_only(root: Path) -> dict:
    """Android screens the iOS baseline does not declare; each needs a reason."""
    path = root / ANDROID_ONLY_REL
    if not path.is_file():
        return {}
    data = load_json(path)
    if not isinstance(data, dict) or data.get("schema") != ANDROID_ONLY_SCHEMA:
        raise CheckError(f"{ANDROID_ONLY_REL}: not a {ANDROID_ONLY_SCHEMA} document")
    screens = data.get("screens")
    if not isinstance(screens, list):
        raise CheckError(f"{ANDROID_ONLY_REL}: `screens` must be a list")
    out = {}
    for entry in screens:
        for key in ("screen", "file", "reason"):
            if key not in entry:
                raise CheckError(f"{ANDROID_ONLY_REL}: screen entry misses `{key}`")
        if not (root / entry["file"]).is_file():
            raise CheckError(f"{ANDROID_ONLY_REL}: {entry['screen']} names missing file {entry['file']}")
        out[entry["screen"]] = entry
    return out


def load_ios_only(root: Path, contracts: dict) -> dict:
    """iOS-only pages explicitly deferred from Android comparison until a milestone."""
    path = root / IOS_ONLY_REL
    if not path.is_file():
        return {}
    data = load_json(path)
    if not isinstance(data, dict) or data.get("schema") != IOS_ONLY_SCHEMA:
        raise CheckError(f"{IOS_ONLY_REL}: not a {IOS_ONLY_SCHEMA} document")
    entries = data.get("pages")
    if not isinstance(entries, list):
        raise CheckError(f"{IOS_ONLY_REL}: `pages` must be a list")
    out = {}
    today = datetime.date.today()
    for entry in entries:
        for key in ("page", "reason", "owner", "reviewBy", "milestone"):
            if key not in entry:
                raise CheckError(f"{IOS_ONLY_REL}: an entry misses `{key}`")
        page = entry["page"]
        contract = contracts.get(page)
        if contract is None:
            raise CheckError(f"{IOS_ONLY_REL}: unknown page {page!r}")
        if page in out:
            raise CheckError(f"{IOS_ONLY_REL}: duplicate page {page!r}")
        if contract["android"].get("file"):
            raise CheckError(f"{IOS_ONLY_REL}: {page!r} now has an Android mapping; remove the exception")
        if not str(entry["reason"]).strip() or not str(entry["owner"]).strip() or not str(entry["milestone"]).strip():
            raise CheckError(f"{IOS_ONLY_REL}: {page!r} needs reason, owner and milestone")
        if not DATE_RE.match(str(entry["reviewBy"])):
            raise CheckError(f"{IOS_ONLY_REL}: {page!r} reviewBy must be YYYY-MM-DD")
        if datetime.date.fromisoformat(entry["reviewBy"]) < today:
            raise CheckError(f"{IOS_ONLY_REL}: {page!r} reviewBy is in the past")
        out[page] = entry
    return out


#: Source text that must never appear as a rendered title: Swift interpolation,
#: Kotlin template, or a `{placeholder}` in a `title` (that belongs in titleTemplate).
SOURCE_EXPR_RE = re.compile(r"\\\(|\$\{|\{[^{}]*[A-Za-z_][^{}]*\}")


def reachable_targets(contract: dict) -> set:
    """Destinations a user can actually reach from this page's baseline body."""
    out = set()
    for action in contract.get("actions", []):
        if action.get("baselineReachable") is False:
            continue  # §1-required, but the baseline body never renders it
        if action.get("destination"):
            out.add(action["destination"])
        label_expr = action.get("labelExpr") or ""
        if label_expr.endswith("Page"):
            out.add(label_expr)
    for section in contract.get("sections", []):
        for row in section.get("rows", []):
            if row.get("destination"):
                out.add(row["destination"])
            label_expr = row.get("labelExpr") or ""
            if label_expr.endswith("Page"):
                out.add(label_expr)
    for presentation in contract.get("presentations", []):
        if presentation.get("triggered"):
            out.add(presentation.get("destination"))
    return {target for target in out if target}


def entrance_source(phrase: str) -> tuple:
    """(source, strict): where §1 says the entrance lives, and whether only that page counts."""
    for word, source, strict in ENTRANCE_RULES:
        if word in phrase:
            return source, strict
    return None, True


def shell_mentions(root: Path, page_name: str) -> bool:
    """The app shell (NativeShell.swift) is the drawer/settings area the baseline renders."""
    path = root / PROBE_REL / SHELL_FILE
    if not path.is_file():
        return False
    return bool(re.search(rf"\b{page_name}\b", read_text(path)))


def check_spec_entrances(root: Path, contracts: dict, report: "Report",
                         only_page: str | None = None) -> None:
    """README §1's 入口 column vs the baseline's reachable navigation.

    Direction that matters: §1 says a page is reached from somewhere the baseline
    never renders (RuntimeDetailsPage's settings row only exists in dead code).
    Such a mismatch is a fact; it is only *not counted* when a contract item
    acknowledges it with `specRef` pointing at that README line. The reverse
    direction — baseline declarations that never render — is printed from the
    contracts' `unreachable` inventory (dead code, do not copy).
    """
    readme = root / UI_REL / "README.md"
    if not readme.is_file():
        return
    refs = {}
    for contract in contracts.values():
        items = list(contract.get("actions", []))
        items += [row for section in contract.get("sections", []) for row in section.get("rows", [])]
        for item in items:
            ref = item.get("specRef") or ""
            if "README.md:" in ref:
                refs.setdefault(ref.rsplit(":", 1)[-1], []).append((contract["pageId"], item.get("label")))
    for line_no, line in enumerate(read_text(readme).splitlines(), 1):
        match = SPEC_ROW_RE.match(line)
        if not match:
            continue
        page, entrance, priority = match.group(1), match.group(3), match.group(5)
        target_id = next((pid for pid, contract in contracts.items()
                          if contract.get("page") == page), None)
        if target_id is None:
            continue  # an Android-only or unextracted page: nothing to compare against
        if priority != "must":
            continue  # `later` pages are not required yet; §1 already defers them
        for phrase in re.split(r"[、,，/]", entrance):
            phrase = phrase.strip()
            if not phrase or any(word in phrase for word in ("RootView", "默认", "不可达", "触发点缺失")):
                continue  # root/default self-description or an explicitly unreachable entry
            source, strict = entrance_source(phrase)
            if source is None:
                continue
            if only_page and source != only_page:
                continue  # `--page X` reports only the entrances hosted by X
            if source == "shell":
                if shell_mentions(root, page):
                    continue
                host_id = "(shell)"
            else:
                host = contracts.get(source)
                if not host or source == target_id:
                    continue
                if page in reachable_targets(host):
                    continue
                if not strict and shell_mentions(root, page):
                    continue  # the shell's settings list renders it
                host_id = source
            detail = (f"README.md:{line_no} entrance {phrase!r} → source {host_id}; "
                      f"the baseline has no reachable action, row or sheet to {page}")
            acknowledged = refs.get(str(line_no))
            report.spec_facts.append((page, host_id, line_no, phrase, bool(acknowledged)))
            if acknowledged:
                report.spec_ack.append((page, host_id, line_no, phrase, acknowledged))
            else:
                report.add(host_id, "spec-baseline-mismatch", f"{page} <- {host_id}", detail)

    for contract in contracts.values():
        if only_page and contract["pageId"] != only_page:
            continue
        for dead in contract.get("unreachable", []):
            report.dead_decls.append((contract["pageId"], contract["source"]["file"], dead))


def load_contracts(root: Path) -> dict:
    pages_dir = root / PAGES_REL
    if not pages_dir.is_dir():
        raise CheckError(f"{PAGES_REL} is missing; run extract_ios_pages.py first")
    contracts = {}
    for path in sorted(pages_dir.glob("*.json")):
        if path.name.startswith("_"):
            continue
        raw = load_json(path)
        if not isinstance(raw, dict) or raw.get("schema") != SCHEMA:
            raise CheckError(f"{path.name}: not a {SCHEMA} contract")
        for key in ("page", "pageId", "source", "android", "sections", "actions", "states"):
            if key not in raw:
                raise CheckError(f"{path.name}: missing `{key}`")
        if raw["pageId"] != path.stem:
            raise CheckError(f"{path.name}: pageId is {raw['pageId']!r}, expected {path.stem!r}")
        for presentation in raw.get("presentations", []):
            if presentation.get("deadUi"):
                if presentation.get("triggered") is not False:
                    raise CheckError(f"{path.name}: presentation {presentation.get('id')!r} is deadUi "
                                     f"but is triggered")
                if not presentation.get("deadUiEvidence"):
                    raise CheckError(f"{path.name}: presentation {presentation.get('id')!r} is deadUi "
                                     f"without deadUiEvidence")
        if not raw["states"].get("advisory"):
            raise CheckError(f"{path.name}: `states` must be advisory (\"advisory\": true); "
                             f"marker-based states are not a gate")
        def check_android_only(item, name):
            meta = item.get("androidOnly")
            if not meta:
                return
            reason = meta.get("reason")
            if not isinstance(reason, dict):
                raise CheckError(f"{path.name}: {name} androidOnly.reason must answer three "
                                 f"questions in an object: baselineLacks / androidNeeds / withoutIt")
            for key in ("baselineLacks", "androidNeeds", "withoutIt"):
                if not str(reason.get(key) or "").strip():
                    raise CheckError(f"{path.name}: {name} androidOnly.reason.{key} is empty; the "
                                     f"three answers separate a deliberate addition from an accident")
            for key in ("owner", "reviewBy"):
                if not str(meta.get(key) or "").strip():
                    raise CheckError(f"{path.name}: {name} androidOnly.{key} is required")
            if not DATE_RE.match(str(meta["reviewBy"])):
                raise CheckError(f"{path.name}: {name} androidOnly.reviewBy must be YYYY-MM-DD")
            if datetime.date.fromisoformat(meta["reviewBy"]) < datetime.date.today():
                raise CheckError(f"{path.name}: {name} androidOnly.reviewBy {meta['reviewBy']} is in "
                                 f"the past; re-review the addition")

        for action in raw["actions"]:
            check_android_only(action, f"action {action.get('label')!r}")
        for section in raw["sections"]:
            check_android_only(section, f"section {section.get('title') or section.get('id')!r}")
            title = section.get("title")
            if title and SOURCE_EXPR_RE.search(title):
                raise CheckError(
                    f"{path.name}: section {section.get('id')!r} title {title!r} contains source "
                    f"text; a title must be the rendered form (`Rows (N)`) and the template "
                    f"belongs in `titleTemplate`")
            if section.get("dynamicTitle") and not section.get("titleTemplate"):
                raise CheckError(f"{path.name}: section {section.get('id')!r} is dynamicTitle "
                                 f"without a titleTemplate (`dynamicTitle` means a fixed "
                                 f"template with one slot, e.g. `Rows (N)`)")
            if section.get("titleExpression") and not section.get("criterion"):
                raise CheckError(f"{path.name}: section {section.get('id')!r} takes its title "
                                 f"from data ({section['titleExpression']!r}), so it must be "
                                 f"modelled as title:null + criterion, not as a title")
            if (not title and not section.get("titleTemplate")
                    and not section.get("titleExpression") and not section.get("criterion")):
                raise CheckError(f"{path.name}: untitled section {section.get('id')!r} has no "
                                 f"criterion; give it a first-row/clickable-row criterion or "
                                 f"register the case in _whitelist.json")
        contracts[raw["pageId"]] = raw
    if not contracts:
        raise CheckError(f"no page contracts under {PAGES_REL}")
    return contracts


def check_provenance(root: Path, contract: dict, stale: list) -> None:
    """Every item's file:line must still carry its anchor. Staleness is never ratcheted."""
    source = contract["source"]
    swift = root / source["path"]
    if not swift.is_file():
        raise CheckError(f"{contract['pageId']}: Swift source {source['path']} is missing")
    lines = read_text(swift).splitlines()
    if f"struct {contract['page']}" not in read_text(swift):
        raise CheckError(f"{contract['pageId']}: {source['path']} no longer declares {contract['page']}")
    items = [("section", s) for s in contract["sections"]]
    items += [("row", r) for s in contract["sections"] for r in s["rows"]]
    items += [("action", a) for a in contract["actions"]]
    for kind, item in items:
        if item.get("androidOnly"):
            continue  # no iOS counterpart by definition: the Android call site is the evidence
        prov = item.get("provenance") or ""
        m = PROVENANCE_RE.match(prov)
        if not m:
            raise CheckError(f"{contract['pageId']}: {kind} {item.get('id')!r} has no `File.swift:line` provenance")
        helper_file = None
        if contract["pageId"] == "chat" and kind == "action":
            helper_file = CHAT_HELPER_ACTION_SOURCES.get(item.get("label"))
        if helper_file is None and m.group(1) != source["file"]:
            raise CheckError(f"{contract['pageId']}: {kind} {item.get('id')!r} points at {m.group(1)}, "
                             f"not {source['file']}")
        expected_file = helper_file or source["file"]
        if m.group(1) != expected_file:
            raise CheckError(f"{contract['pageId']}: action {item.get('id')!r} points at {m.group(1)}, "
                             f"not its verified helper {expected_file}")
        line_no = int(m.group(2))
        item_source = swift.parent / helper_file if helper_file else swift
        if not item_source.is_file():
            raise CheckError(f"{contract['pageId']}: Swift source {item_source} is missing")
        item_lines = read_text(item_source).splitlines()
        if not (1 <= line_no <= len(item_lines)):
            raise CheckError(f"{contract['pageId']}: {kind} {item.get('id')!r} line {line_no} is out of range")
        anchor = (item.get("anchor") or "").strip()
        if not anchor:
            raise CheckError(f"{contract['pageId']}: {kind} {item.get('id')!r} has no anchor")
        if anchor not in item_lines[line_no - 1]:
            stale.append(f"{contract['pageId']}/{kind}:{item.get('id')} {prov} no longer carries "
                         f"{anchor!r} (got {item_lines[line_no - 1].strip()!r})")


# ---------------------------------------------------------------------------
# The baseline's own conditions (Swift source).
# ---------------------------------------------------------------------------

#: `if` is the only conditional shape the Android-side comparison needs: an action
#: the baseline draws inside `if let errorText { … }` is already conditional, so the
#: Android page guarding the same control on its callback is not a divergence.
SWIFT_IF_RE = re.compile(r"\bif[ \t]+")
SWIFT_ELSE_RE = re.compile(r"\belse\b")


def swift_conditional_scopes(text: str) -> list:
    """(body_start, body_end, condition text) for every `if`/`else` body in Swift.

    Comments and string bodies are blanked with `mask_kotlin`: Swift and Kotlin
    share the `//`, `/* */`, `"…"` and `\"\"\"…\"\"\"` shapes the masker understands,
    and a brace inside a string must not close an `if` body. `switch`/`guard` are
    deliberately not modelled; a contract action only needs *a* known condition for
    the Android guard to be acceptable, and both of those are rarer than `if let`.
    """
    masked = mask_kotlin(text)
    scopes = []
    for m in SWIFT_IF_RE.finditer(masked):
        brace = masked.find("{", m.end())
        if brace < 0:
            continue
        close = match_delim(masked, brace, "{", "}")
        if close < 0:
            continue
        condition = collapse(text[m.start():brace])
        scopes.append((brace, close, condition))
        k = close + 1
        while k < len(masked) and masked[k] in " \t\r\n":
            k += 1
        if not SWIFT_ELSE_RE.match(masked, k):
            continue
        else_brace = masked.find("{", k)
        if else_brace < 0:
            continue
        else_close = match_delim(masked, else_brace, "{", "}")
        if else_close > 0:
            scopes.append((else_brace, else_close, f"else of `{condition}`"))
    return scopes


def baseline_conditional_actions(root: Path, contract: dict) -> dict:
    """Action id -> the baseline `if` that guards it, read from the Swift source.

    The contract's `condition` field is only filled for manually annotated actions:
    syntax extraction leaves it `null` even for `Button("重试")` inside `if let
    loadError { … }`. Using `condition` alone would therefore fail a correct Android
    guard (the platform says "draw the retry only when the host offers one", which
    matches the baseline's "only on error"). The baseline source is the truth; this
    reads the file `check_provenance` already mapped to this contract.
    """
    source = contract.get("source") or {}
    path = root / source["path"] if source.get("path") else None
    if path is None or not path.is_file():
        return {}
    text = read_text(path)
    scopes = swift_conditional_scopes(text)
    if not scopes:
        return {}
    offsets, pos = [], 0
    for line in text.splitlines(keepends=True):
        offsets.append((pos, pos + len(line)))
        pos += len(line)
    out = {}
    for action in contract.get("actions", []):
        match = PROVENANCE_RE.match(action.get("provenance") or "")
        if not match or match.group(1) != source.get("file"):
            continue
        line_no = int(match.group(2))
        if not (1 <= line_no <= len(offsets)):
            continue
        line_start, line_end = offsets[line_no - 1]
        for body_start, body_end, condition in scopes:
            if body_start < line_end and body_end > line_start:
                out[action.get("id")] = condition
                break
    return out


# ---------------------------------------------------------------------------
# Android extraction.
# ---------------------------------------------------------------------------


def is_declaration(masked: str, pos: int) -> bool:
    """`data class SettingsSectionView(` is a declaration, not a call site."""
    return bool(DECLARATION_TAIL_RE.search(masked[max(0, pos - 100): pos]))


#: `*SectionView` type names that are data-model constructors, never a rendered
#: header. PR22's AboutPage projects its cards through `data class AboutSectionView`;
#: reading those calls as Compose sections invented two extra titles (版本 / 更多)
#: that the page draws through `SettingsFormRow` instead.
NON_UI_SECTION_CONSTRUCTORS = frozenset({"AboutSectionView"})


def android_sections(text: str, masked: str, strings: dict, consts: dict,
                     positions: list | None = None) -> tuple:
    """(titled titles, unresolved expressions) declared by the page."""
    titles, unresolved = [], []
    for m in SECTION_CALL_RE.finditer(masked):
        callee = m.group(1)
        if not (callee.endswith(("SectionLabel", "SectionHeader", "SectionView", "SectionGroup"))):
            continue
        if is_declaration(masked, m.start()) or callee in NON_UI_SECTION_CONSTRUCTORS:
            continue
        open_paren = m.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0:
            continue
        args = split_args(masked, open_paren + 1, close)
        named, positional = {}, []
        for a, b in args:
            # Kotlin named arguments use `name = value` (not Swift's `name: value`).
            nm = re.match(r"\s*([a-z][A-Za-z0-9_]*)\s*=(?!=)", masked[a:b])
            if nm:
                named[nm.group(1)] = (a + nm.end(), b)
            else:
                positional.append((a, b))
        if callee.endswith(("SectionHeader", "SectionView", "SectionGroup")):
            span = named.get("title") or (positional[1] if (callee.endswith("SectionView")
                                                             and len(positional) > 1) else None)
            if span is None and callee.endswith("SectionHeader") and positional:
                span = positional[0]
        else:
            # `text` is the usual name; `SettingsSectionLabel` names it `title`.
            # Reading only `text` made every `SettingsSectionLabel(title = …)`
            # header invisible to the gate even though it renders on screen.
            span = named.get("text") or named.get("title") or (positional[0] if positional else None)
        if span is None:
            continue
        if is_declaration(masked, m.start()):
            continue
        raw_expr = collapse(text[span[0]:span[1]])
        if raw_expr in ("null", "Optional.empty()"):
            continue  # an explicitly untitled section: the contract has those too
        value, dynamic = resolve_kotlin_expr(raw_expr, strings, consts)
        if dynamic:
            unresolved.append(strip_kotlin_comments(raw_expr)[:DYN_EXPR_MAX])
        elif value and value.strip():
            titles.append(value)
            if positions is not None:
                positions.append((value, m.start()))
    return titles, unresolved


def verified_settings_index_model(text: str, masked: str, strings: dict,
                                  consts: dict) -> tuple | None:
    """Read the PR22 Settings index's data model only when its renderer owns it.

    This is deliberately tied to the source's `SettingsIndexSection` /
    `SettingsIndexEntry` model. A random `SectionLabel(section.title)` is not enough:
    the screen must call `SettingsIndexList`, the list must construct its own typed
    sections, and that same list must render each title and entry through the named
    row components. The returned positions remain at the model call sites so normal
    conditional/action accounting still applies.
    """
    functions = function_spans(masked)
    page = next((fn for fn in functions if fn["name"] == "SettingsPage"), None)
    renderer = next((fn for fn in functions if fn["name"] == "SettingsIndexList"), None)
    if page is None or renderer is None:
        return None

    # Verify the declared model types, rather than trusting constructor-shaped text.
    for name, required in (
        ("SettingsIndexSection", (r"\bval\s+title\s*:\s*String\b",
                                   r"\bval\s+entries\s*:\s*List\s*<\s*SettingsIndexEntry\s*>")),
        ("SettingsIndexEntry", (r"\bval\s+title\s*:\s*String\b",)),
    ):
        declaration = re.search(rf"\bdata\s+class\s+{name}\s*\(", masked)
        if declaration is None:
            return None
        close = match_paren(masked, declaration.end() - 1)
        if close < 0 or any(re.search(pattern, masked[declaration.end():close]) is None
                            for pattern in required):
            return None

    page_body = masked[page["body_start"]:page["body_end"]]
    if re.search(r"\bSettingsIndexList\s*\(", page_body) is None:
        return None

    body_start, body_end = renderer["body_start"], renderer["body_end"]
    renderer_body = masked[body_start:body_end]
    list_match = re.search(r"\bval\s+sections\s*=\s*listOf\s*\(", renderer_body)
    loop_match = re.search(r"\bsections\s*\.\s*forEach\s*\{\s*section\s*->", renderer_body)
    if list_match is None or loop_match is None:
        return None
    loop_open = body_start + renderer_body.find("{", loop_match.start(), loop_match.end())
    loop_close = match_delim(masked, loop_open, "{", "}")
    if loop_close < 0:
        return None
    loop_body = masked[loop_open + 1:loop_close]
    if re.search(r"\bSettingsSectionLabel\s*\(\s*section\s*\.\s*title\b", loop_body) is None:
        return None
    entry_loop = re.search(r"\bsection\s*\.\s*entries\s*\.\s*forEach(?:Indexed)?\s*\{\s*(?:index\s*,\s*)?entry\s*->", loop_body)
    if entry_loop is None:
        return None
    entry_open = loop_open + 1 + loop_body.find("{", entry_loop.start(), entry_loop.end())
    entry_close = match_delim(masked, entry_open, "{", "}")
    if entry_close < 0 or re.search(r"\bSettingsIndexRow\s*\(\s*entry\b",
                                    masked[entry_open + 1:entry_close]) is None:
        return None

    list_open = body_start + list_match.end() - 1
    list_close = match_paren(masked, list_open)
    if list_close < 0:
        return None

    titles, title_positions = [], []
    for match in re.finditer(r"\bSettingsIndexSection\s*\(", masked[list_open + 1:list_close]):
        pos = list_open + 1 + match.start()
        if is_declaration(masked, pos):
            continue
        open_paren = pos + match.group(0).rfind("(")
        close = match_paren(masked, open_paren)
        if close < 0 or close > list_close:
            continue
        named, positional = named_args(masked, open_paren, close)
        span = named.get("title") or (positional[1] if len(positional) > 1 else None)
        if span is None:
            continue
        value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
        if dynamic:
            continue
        if value and value.strip():
            titles.append(value)
            title_positions.append((value, span[0]))

    actions, action_positions = [], []
    entry_pattern = re.compile(r"\b(SettingsIndexEntry(?:\.menu)?)\s*\(")
    for match in entry_pattern.finditer(masked[list_open + 1:list_close]):
        pos = list_open + 1 + match.start()
        if is_declaration(masked, pos):
            continue
        callee = match.group(1)
        open_paren = pos + match.group(0).rfind("(")
        close = match_paren(masked, open_paren)
        if close < 0 or close > list_close:
            continue
        named, positional = named_args(masked, open_paren, close)
        interactive = callee.endswith(".menu") or any(
            name in named for name in ("callback", "onToggle", "options"))
        if not interactive:
            continue
        span = named.get("title") or (positional[1] if len(positional) > 1 else None)
        if span is None:
            continue
        value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
        if dynamic:
            continue
        if value and value.strip():
            actions.append(value)
            action_positions.append((value, span[0]))
    return titles, title_positions, actions, action_positions


def verified_about_row_positions(text: str, masked: str, strings: dict,
                                 consts: dict) -> list | None:
    """Resolve AboutRowView labels when AboutPage renders the complete projection."""
    functions = function_spans(masked)
    page = next((fn for fn in functions if fn["name"] == "AboutPage"), None)
    factory = next((fn for fn in functions if fn["name"] == "from" and
                    re.search(r"AboutScreenState\s*\(\s*sections\s*=\s*sections",
                              masked[fn["body_start"]:fn["body_end"]]) and
                    re.search(r"\bAboutRowView\s*\(", masked[fn["body_start"]:fn["body_end"]])), None)
    if page is None or factory is None:
        return None
    for model, field in (("AboutRowView", r"val\s+title\s*:\s*String"),
                         ("AboutSectionView", r"val\s+rows\s*:\s*List\s*<\s*AboutRowView\s*>"),
                         ("AboutScreenState", r"val\s+sections\s*:\s*List\s*<\s*AboutSectionView\s*>")):
        declaration = re.search(rf"\bdata\s+class\s+{model}\s*\(", masked)
        if declaration is None:
            return None
        declaration_close = match_paren(masked, declaration.end() - 1)
        if declaration_close < 0 or re.search(field, masked[declaration.end():declaration_close]) is None:
            return None
    page_body = masked[page["body_start"]:page["body_end"]]
    if (re.search(r"state\s*\.\s*sections\s*\.\s*map", page_body) is None
            or re.search(r"section\s*\.\s*rows\s*\.\s*filter", page_body) is None
            or re.search(r"SettingsGroupCard\s*(?:\(|\{)", page_body) is None
            or re.search(r"SettingsFormRow\s*\(\s*title\s*=\s*row\.title", page_body) is None):
        return None
    factory_body = masked[factory["body_start"]:factory["body_end"]]
    if re.search(r"AboutSectionView\s*\(\s*VERSION_SECTION_ID\s*,\s*[^,]+,\s*versionRows",
                 factory_body, re.S) is None:
        return None
    version_rows = re.search(r"\bval\s+versionRows\s*=\s*listOf\s*\(", factory_body)
    if version_rows is None:
        return None
    list_open = factory["body_start"] + version_rows.end() - 1
    list_close = match_paren(masked, list_open)
    if list_close < 0:
        return None
    out = []
    for call in SECTION_CALL_RE.finditer(masked, list_open + 1, list_close):
        if call.group(1) != "AboutRowView" or is_declaration(masked, call.start()):
            continue
        open_paren = call.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0 or close > list_close:
            continue
        named, _ = named_args(masked, open_paren, close)
        span = named.get("title")
        if span is None:
            continue
        label, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
        if not dynamic and label and label.strip():
            out.append((label, call.start()))
    return out


def verified_font_size_role_model(text: str, masked: str, strings: dict,
                                  consts: dict) -> tuple | None:
    """Resolve FontSizeSettingsPage's role titles through its verified role renderer."""
    page = next((fn for fn in function_spans(masked)
                 if fn["name"] == "FontSizeSettingsPage"), None)
    if page is None:
        return None
    declaration = re.search(r"\bdata\s+class\s+FontSizeRole\s*\(", masked)
    if declaration is None:
        return None
    model_end = match_paren(masked, declaration.end() - 1)
    if model_end < 0 or re.search(r"\bval\s+title\s*:\s*String\b",
                                  masked[declaration.end():model_end]) is None:
        return None
    body_start, body_end = page["body_start"], page["body_end"]
    body = masked[body_start:body_end]
    content = re.search(r"\bval\s+content\s*:[^=]+?=\s*\{", body)
    values = re.search(r"\bval\s+values\s*=\s*listOf\s*\(", body)
    loop = re.search(r"\bvalues\s*\.\s*forEach\s*\{\s*role\s*->", body)
    if (content is None or values is None or loop is None
            or re.search(r"if\s*\(embedded\)\s*content\s*\(\)", body) is None):
        return None
    content_open = body_start + body.find("{", content.start(), content.end())
    content_close = match_delim(masked, content_open, "{", "}")
    if content_open < 0 or content_close < 0:
        return None
    if not (content_open < body_start + values.start() < content_close
            and content_open < body_start + loop.start() < content_close):
        return None
    loop_open = body_start + body.find("{", loop.start(), loop.end())
    if loop_open < 0:
        return None
    loop_close = match_delim(masked, loop_open, "{", "}")
    if loop_close < 0:
        return None
    loop_body = masked[loop_open + 1:loop_close]
    if re.search(r"\bSettingsSectionLabel\s*\(\s*role\s*\.\s*title\b", loop_body) is None:
        return None
    if re.search(r"\bFontSizeStepper\s*\(\s*role\s*=\s*role\b", loop_body) is None:
        return None
    list_open = body_start + values.end() - 1
    list_close = match_paren(masked, list_open)
    if list_close < 0:
        return None
    titles, positions = [], []
    for match in re.finditer(r"\bFontSizeRole\s*\(", masked[list_open + 1:list_close]):
        pos = list_open + 1 + match.start()
        open_paren = pos + match.group(0).rfind("(")
        close = match_paren(masked, open_paren)
        if close < 0 or close > list_close:
            continue
        named, positional = named_args(masked, open_paren, close)
        span = named.get("title") or (positional[0] if positional else None)
        if span is None:
            continue
        value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
        if not dynamic and value and value.strip():
            titles.append(value)
            positions.append((value, span[0]))
    return titles, positions



# ---------------------------------------------------------------------------
# Compose control idioms (the label is visible in the source).
# ---------------------------------------------------------------------------


def split_statements_kotlin(masked: str, start: int, end: int) -> list:
    """Direct children of a Compose closure as (start, end) spans.

    A depth-0 newline ends a child unless the next line starts with `.` (modifier
    chain) or the previous line ends in an operator / comma (an argument list that
    continues). This is the boundary the `Switch` rule needs: its label is the
    nearest `Text` among the *same* container's direct children, never a sibling
    block's.
    """
    out = []
    i, end = start, min(end, len(masked))
    while i < end:
        while i < end and masked[i] in " \t\r\n":
            i += 1
        if i >= end or masked[i] == "}":
            break
        s = j = i
        depth = 0
        while j < end:
            c = masked[j]
            if c in "({[":
                depth += 1
            elif c in ")}]":
                if depth == 0:
                    break
                depth -= 1
            elif c == "\n" and depth == 0:
                k = j + 1
                while k < end and masked[k] in " \t\r\n":
                    k += 1
                if k < end and masked[k] == ".":
                    j = k
                    continue
                if masked[s:j].rstrip().endswith((".", ",", "=", "&&", "||", "->", "+")):
                    j += 1
                    continue
                break
            j += 1
        if j <= s:
            j = s + 1
        out.append((s, j))
        i = j
    return out


def call_at(masked: str, start: int) -> dict:
    """Callee, arguments and trailing closure for a call whose name is at `start`.

    Handles both Compose shapes: `Row(modifier = ...) { ... }` and `Row { ... }`
    (no argument list at all, which is how most layout containers are written).
    """
    m = re.match(r"([A-Za-z_]\w*)", masked[start:])
    if not m:
        return {}
    callee = m.group(1)
    k = start + m.end()
    while k < len(masked) and masked[k] in " \t\r\n":
        k += 1
    named, positional, open_paren, close = {}, [], -1, -1
    trailing = None
    if k < len(masked) and masked[k] == "(":
        open_paren = k
        close = match_paren(masked, open_paren)
        if close < 0:
            return {}
        named, positional = named_args(masked, open_paren, close)
        k = close + 1
        while k < len(masked) and masked[k] in " \t\r\n":
            k += 1
    if k < len(masked) and masked[k] == "{":
        close_brace = match_delim(masked, k, "{", "}")
        if close_brace > 0:
            trailing = (k, close_brace)
    return {"callee": callee, "open_paren": open_paren, "close_paren": close,
            "named": named, "positional": positional, "trailing": trailing}


def function_spans(masked: str) -> list:
    """(name, params, nullable params, body_start, body_end) per function declaration.

    `nullable` is the subset of parameters whose type ends in `?` (`onRetry: (() ->
    Unit)? = null`). It is what tells a *host-supplied* callback from a plain value:
    only a nullable parameter can be `null` at runtime, so only its `if (x != null)`
    guard makes the UI conditional.
    """
    out = []
    for m in FUN_DECL_RE.finditer(masked):
        open_paren = m.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0:
            continue
        brace = masked.find("{", close)
        if brace < 0:
            continue
        close_brace = match_delim(masked, brace, "{", "}")
        if close_brace < 0:
            continue
        params, nullable = [], set()
        for a, b in split_args(masked, open_paren + 1, close):
            nm = re.match(r"\s*([a-z][A-Za-z0-9_]*)\s*:", masked[a:b])
            if nm:
                params.append(nm.group(1))
                if "?" in masked[a:b]:
                    nullable.add(nm.group(1))
        out.append({"name": m.group(1), "params": params, "nullable": nullable,
                    "body_start": brace, "body_end": close_brace})
    return out


#: A nullable callback guarding a block: `if (onX != null) { … }` / `if (null != onX)`.
NULL_GUARD_IF_RE = re.compile(
    r"\bif\s*\(\s*(?:null\s*!=\s*([A-Za-z_]\w*)|([A-Za-z_]\w*)\s*!=\s*null)\s*\)\s*\{")
#: The same guard seen from the other side: `if (onX == null) { … } else { <UI> }`.
NULL_GUARD_NULL_RE = re.compile(
    r"\bif\s*\(\s*(?:null\s*==\s*([A-Za-z_]\w*)|([A-Za-z_]\w*)\s*==\s*null)\s*\)\s*\{")
#: `onX?.let { … }`: the block only runs when the callback is non-null.
NULL_GUARD_LET_RE = re.compile(r"\b([A-Za-z_]\w*)\s*\?\.\s*(?:let|run|also|apply)\s*\{")


def null_guards(masked: str, spans: list) -> list:
    """(block_start, block_end, parameter, snippet) for every nullable-callback guard.

    Only a parameter declared `?` counts. A local `val onX: (() -> Unit)?` or a
    nullable field is not host wiring this gate can judge, and a non-nullable
    parameter can never be null, so its `if (x != null)` is not a condition.
    """
    out = []

    def add(name: str, block_start: int, block_end: int, snippet: str) -> None:
        span = enclosing_function(spans, block_start)
        if span is None or name not in span["nullable"]:
            return
        if block_end > block_start:
            out.append((block_start, block_end, name, snippet))

    for m in NULL_GUARD_IF_RE.finditer(masked):
        name = m.group(1) or m.group(2)
        brace = m.end() - 1
        close = match_delim(masked, brace, "{", "}")
        if close > 0:
            add(name, brace, close, f"if ({name} != null)")
    for m in NULL_GUARD_LET_RE.finditer(masked):
        name = m.group(1)
        brace = m.end() - 1
        close = match_delim(masked, brace, "{", "}")
        if close > 0:
            add(name, brace, close, f"{name}?.let")
    for m in NULL_GUARD_NULL_RE.finditer(masked):
        name = m.group(1) or m.group(2)
        brace = m.end() - 1
        close = match_delim(masked, brace, "{", "}")
        if close < 0:
            continue
        k = close + 1
        while k < len(masked) and masked[k] in " \t\r\n":
            k += 1
        if not masked.startswith("else", k):
            continue
        else_brace = masked.find("{", k)
        if else_brace < 0:
            continue
        else_close = match_delim(masked, else_brace, "{", "}")
        if else_close > 0:
            add(name, else_brace, else_close, f"if ({name} == null) … else")
    return out


def null_guard_at(guards: list, pos: int) -> str | None:
    """The innermost nullable-callback guard whose block contains `pos`, if any."""
    hits = [guard for guard in guards if guard[0] < pos < guard[1]]
    if not hits:
        return None
    hits.sort(key=lambda guard: guard[1] - guard[0])
    # A control can sit behind two guards (`if (onShow != null) { if (onRetry !=
    # null) { … } }`); name both so the report is not half the wiring.
    return " inside ".join(dict.fromkeys(guard[3] for guard in hits))


def enclosing_function(spans: list, pos: int) -> dict | None:
    best = None
    for span in spans:
        if span["body_start"] < pos < span["body_end"]:
            if best is None or span["body_start"] > best["body_start"]:
                best = span
    return best


def text_label_in(text: str, masked: str, start: int, end: int, strings: dict, consts: dict,
                  skip_params: set) -> tuple:
    """First `Text`/`BasicText` in a span: (label, dynamic expression or None).

    Only the first one counts (`Button { Column { Text(title); Text(subtitle) } }`
    is the title); a first text that is an expression stops the search, and a bare
    parameter name means this is a wrapper template, not a rendered label.
    """
    for m in SECTION_CALL_RE.finditer(masked, start, end):
        if m.group(1) not in ("Text", "BasicText"):
            continue
        open_paren = m.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0:
            continue
        named, positional = named_args(masked, open_paren, close)
        span = named.get("text") or (positional[0] if positional else None)
        if span is None:
            continue
        raw = collapse(text[span[0]:span[1]])
        value, dynamic = resolve_kotlin_expr(raw, strings, consts)
        if dynamic:
            expr = strip_kotlin_comments(raw)
            if expr in skip_params:
                return None, None  # a wrapper's own parameter, not a label
            return None, expr
        if value is not None and is_chrome_label(value):
            continue
        if value:
            return value, None
    return None, None


def enclosing_container(text: str, masked: str, pos: int) -> tuple | None:
    """Innermost `Row`/`Column`/`Box` whose content closure contains `pos`."""
    best = None
    for m in re.finditer(r"\b(Row|Column|Box)\b", masked):
        call = call_at(masked, m.start())
        if not call or not call["trailing"]:
            continue
        brace, close = call["trailing"]
        if brace < pos < close:
            if best is None or brace > best[0]:
                best = (brace, close)
    return best


def button_wrappers(masked: str, spans: list) -> set:
    """Page-local composables that render a button from their first `label: String`."""
    out = set()
    for span in spans:
        # Only a wrapper whose *first* parameter is the visible `label` qualifies.
        # `InfoRow(title=)`, `SectionHeader(title=)`, `PageFrame(title=)` and
        # `NoticeLine(text=)` already have their own idioms or are chrome; treating
        # them as wrappers would count their call sites twice.
        if span["name"] in EXPLICIT_ACTION_IDIOMS:
            continue
        if not span["params"] or span["params"][0] not in ("label", "description", "glyph"):
            continue
        body = masked[span["body_body_start"]: span["body_end"]] if "body_body_start" in span \
            else masked[span["body_start"]: span["body_end"]]
        content_description = bool(re.search(
            rf"contentDescription\s*=\s*{re.escape(span['params'][0])}\b", body))
        tappable = bool(re.search(
            r"\b(Button|OutlinedButton|TextButton|FilledTonalButton|ElevatedButton|SegmentedButton)\s*\(",
            body)) or (bool(re.search(r"\b(BasicText|Text)\s*\(", body)) and ".clickable(" in body) \
            or (content_description and ".clickable(" in body)
        if tappable:
            out.add(span["name"])
    return out


def nearest_text_in_container(text: str, masked: str, container: tuple, pos: int,
                              strings: dict, consts: dict, skip_params: set) -> tuple:
    """Nearest direct-child `Text` in the container, preferring the one before `pos`."""
    brace, close = container
    texts = []
    for s, e in split_statements_kotlin(masked, brace + 1, close):
        m = re.match(r"[ \t]*(Text|BasicText)[ \t]*\(", masked[s:e])
        if not m:
            continue
        label, expr = text_label_in(text, masked, s, e, strings, consts, skip_params)
        texts.append((s, label, expr))
    if not texts:
        return None, None
    before = [item for item in texts if item[0] < pos]
    chosen = before[-1] if before else texts[0]
    return chosen[1], chosen[2]


def load_page_wrappers(root: Path) -> set:
    """Button-wrapper composables declared anywhere in the Android page layer.

    `ProbePrimaryButton` lives in `ProbesPage.kt` and is called from `ExportPage.kt`,
    so the index is layer-wide: a per-file index would miss every cross-file call.
    """
    out = set()
    ui_dir = root / ANDROID_UI_REL
    if not ui_dir.is_dir():
        return out
    # Every composable file under `ui/`, not just `ui/page`: a shared row such as
    # `ui/surface/ApprovalCard.kt`'s `FoldedPendingRow(label = …)` must be recognised
    # where it lives. A narrower scan pushes pages into duplicating the component so
    # that its label becomes visible to the gate — the gate causing redundancy.
    for kt in sorted(ui_dir.rglob("*.kt")):
        masked = mask_kotlin(read_text(kt))
        out |= button_wrappers(masked, function_spans(masked))
    return out


def verified_chat_artifact_route_binding(root: Path) -> bool:
    """Verify the shipping PdshNavHost always supplies ChatPage's artifact route."""
    path = root / ANDROID_UI_REL / "nav" / "PdshNavHost.kt"
    if not path.is_file():
        return False
    text = read_text(path)
    masked = mask_kotlin(text)
    functions = function_spans(masked)
    host = next((fn for fn in functions if fn["name"] == "PdshNavHost"), None)
    route = next((fn for fn in functions if fn["name"] == "ChatRoute"), None)
    if host is None or route is None:
        return False
    host_body = masked[host["body_start"]:host["body_end"]]
    if re.search(r"PdshRoute\.Chat\s*->\s*ChatRoute\s*\(", host_body) is None:
        return False
    calls = []
    for match in SECTION_CALL_RE.finditer(masked, route["body_start"], route["body_end"]):
        if match.group(1) != "ChatPage" or is_declaration(masked, match.start()):
            continue
        open_paren = match.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0 or close > route["body_end"]:
            continue
        named, _ = named_args(masked, open_paren, close)
        span = named.get("onOpenArtifacts")
        if span is None:
            continue
        expression = strip_kotlin_comments(collapse(text[span[0]:span[1]]))
        # Accept only this concrete direct route body. Unknown control flow
        # (including compact `if(...)`) must remain conditional/unresolved.
        direct_route = (
            r"\{\s*onNavigate\s*\(\s*PdshRoute\.SessionArtifacts\s*\(\s*"
            r"state\s*\?\.\s*sessionID\s*\.\s*orEmpty\s*\(\s*\)"
            r"\s*\)\s*\)\s*;?\s*\}"
        )
        if re.fullmatch(direct_route, expression):
            calls.append(match.start())
    return len(calls) == 1


def verified_developer_tools_action_positions(text: str, masked: str,
                                              strings: dict, consts: dict) -> list:
    """Read ConversationSettingsPage's named toggle through its verified row helper.

    `DeveloperToolsRow` is not a label-first button wrapper: it creates a SettingsRowFrame
    switch, puts the localized title in SettingsRowLabel, and invokes the host callback.
    Resolve the helper only when the page calls it for the stored preference.
    """
    functions = function_spans(masked)
    page = next((fn for fn in functions if fn["name"] == "ConversationSettingsPage"), None)
    helper = next((fn for fn in functions if fn["name"] == "DeveloperToolsRow"), None)
    if page is None or helper is None:
        return []
    page_body = masked[page["body_start"]:page["body_end"]]
    call = re.search(
        r"DeveloperToolsRow\s*\(\s*preferences\.developerTools\s*,\s*onToggleDeveloperTools\s*,\s*languageId\s*\)",
        page_body,
    )
    if call is None:
        return []
    helper_body = masked[helper["body_start"]:helper["body_end"]]
    frame = re.search(r"SettingsRowFrame\s*\(", helper_body)
    if frame is None:
        return []
    frame_open = helper["body_start"] + frame.end() - 1
    frame_close = match_paren(masked, frame_open)
    if frame_close < 0:
        return []
    frame_body = masked[frame_open + 1:frame_close]
    if (re.search(r"\brole\s*=\s*Role\.Switch\b", frame_body) is None
            or re.search(r"\bonClick\s*=\s*\{\s*onToggle\s*\?\.\s*invoke\s*\(", frame_body) is None
            or re.search(r"SettingsRowLabel\s*\(\s*text\s*=\s*label", helper_body) is None
            or re.search(r"SettingsSwitch\s*\(\s*checked\s*=\s*checked", helper_body) is None):
        return []
    label_expr = re.search(r"\bval\s+label\s*=\s*([^\n]+)", text[helper["body_start"]:helper["body_end"]])
    if label_expr is None:
        return []
    label, dynamic = resolve_kotlin_expr(label_expr.group(1), strings, consts)
    if dynamic or not label:
        return []
    return [(label, page["body_start"] + call.start())]


def android_actions(text: str, masked: str, strings: dict, consts: dict,
                    stats: dict | None = None, wrappers: frozenset | None = None,
                    positions: list | None = None,
                    fold_labels: frozenset | None = None) -> tuple:
    """(labelled action labels, unresolved expressions, (label, pos) occurrences).

    The third value is every resolved label with its source position, independent of
    `positions` (which only feeds the untitled-group criterion). The caller maps a
    position to a nullable-callback guard, so a label that exists only under
    `if (hostCallback != null)` is not reported as present.
    """
    labels, unresolved, found = [], [], []
    for m in SECTION_CALL_RE.finditer(masked):
        callee = m.group(1)
        if callee not in ("SessionTextAction", "InfoRow", "SessionFailureLine"):
            continue
        if is_declaration(masked, m.start()):
            continue
        open_paren = m.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0:
            continue
        args = split_args(masked, open_paren + 1, close)
        named, positional = {}, []
        for a, b in args:
            # Kotlin named arguments use `name = value` (not Swift's `name: value`).
            nm = re.match(r"\s*([a-z][A-Za-z0-9_]*)\s*=(?!=)", masked[a:b])
            if nm:
                named[nm.group(1)] = (a + nm.end(), b)
            else:
                positional.append((a, b))
        if callee == "SessionTextAction":
            span = named.get("label")
        elif callee == "SessionFailureLine":
            span = named.get("retryLabel")
        else:  # InfoRow: only an interactive row is an action
            # `SettingsFormRow` is deliberately absent: even with `onClick` it is the
            # Settings family's generic row, used for dialogs and chrome, and reading
            # it as a contract action invents 10 labels that the contract never had.
            # A page that needs an action row here uses `SessionTextAction`, which is
            # what the component is for.
            if "onClick" not in named or "title" not in named:
                continue
            span = named["title"]
        if span is None:
            continue
        value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
        if dynamic:
            raw_label = strip_kotlin_comments(collapse(text[span[0]:span[1]]))
            saving_expr = re.fullmatch(
                r"if\s*\(editor\.saving\)\s*AUTOMATION_EDITOR_SAVING_LABEL"
                r"\s*else\s*UiStrings\.AUTOMATION_EDITOR_SAVE",
                raw_label)
            variants = kotlin_label_variants(raw_label, strings, consts) if saving_expr else []
            if saving_expr:
                click_span = named.get("onClick")
                enabled_span = named.get("enabled")
                click = collapse(text[click_span[0]:click_span[1]]) if click_span else ""
                enabled = collapse(text[enabled_span[0]:enabled_span[1]]) if enabled_span else ""
                callback_verified = bool(re.search(
                    r"onSubmit\s*\(\s*draft\s*,\s*UUID\.randomUUID\(\)\.toString\(\)\s*\)", click))
                if not callback_verified or enabled != "editor.canSubmit":
                    variants = []
            if variants:
                for variant in variants:
                    labels.append(variant)
                    found.append((variant, m.start()))
                    if positions is not None:
                        positions.append((variant, m.start()))
            else:
                unresolved.append(strip_kotlin_comments(collapse(text[span[0]:span[1]]))[:DYN_EXPR_MAX])
        elif value and value.strip():
            labels.append(value)
            found.append((value, m.start()))
            if positions is not None:
                # The untitled-group criterion check locates a contract row by its
                # position in the page. Without this, a row drawn by one of these
                # three shared components read as "the label exists somewhere" and
                # then failed `find_row` anyway, which surfaced as a phantom
                # missing-section on a page that renders the row.
                positions.append((value, m.start()))
    # ChatPage has no action component: its affordances are a `BasicText` whose
    # own modifier chain carries `.clickable(...)`. Only that shape counts (a
    # clickable row around a label is not the label's own action).
    for m in SECTION_CALL_RE.finditer(masked):
        if m.group(1) not in ("BasicText", "Text"):
            continue
        open_paren = m.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0 or not re.search(r"\.clickable\s*(?:\(|\{)", masked[open_paren:close]):
            continue
        span = None
        for a, b in split_args(masked, open_paren + 1, close):
            nm = re.match(r"\s*([a-z][A-Za-z0-9_]*)\s*=(?!=)", masked[a:b])
            if nm and nm.group(1) == "text":
                span = (a + nm.end(), b)
                break
        if span is None:
            # Kotlin permits the text argument positionally. It is still an
            # action only when this Text's own modifier has .clickable(...).
            _, positional = named_args(masked, open_paren, close)
            span = positional[0] if positional else None
        if span is None:
            continue
        value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
        if dynamic:
            expr = collapse(text[span[0]:span[1]])
            enc = enclosing_function(function_spans(masked), open_paren)
            if enc and expr in enc["params"]:
                continue  # this BasicText renders a wrapper's parameter
            unresolved.append(expr[:DYN_EXPR_MAX])
        elif value and value.strip():
            labels.append(value)
            found.append((value, m.start()))
    # `Row(modifier = Modifier.clickable(...)) { BasicText(text = UiStrings.NEW) }`:
    # the label is a child, the tap target is the container. Take the first
    # non-glyph text child; a dynamic first child means the row's name comes from
    # data (a session title), which is not a named action, so it is skipped.
    for m in SECTION_CALL_RE.finditer(masked):
        if m.group(1) not in ("Row", "Column", "Box"):
            continue
        open_paren = m.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0 or not re.search(r"\.clickable\s*(?:\(|\{)", masked[open_paren:close]):
            continue
        k = close + 1
        while k < len(masked) and masked[k] in " \t\r\n":
            k += 1
        if k >= len(masked) or masked[k] != "{":
            continue
        body_end = match_delim(masked, k, "{", "}")
        if body_end < 0:
            continue
        label = None
        for child in SECTION_CALL_RE.finditer(masked, k, body_end):
            if child.group(1) not in ("BasicText", "Text"):
                continue
            cop = child.end() - 1
            ccl = match_paren(masked, cop)
            if ccl < 0:
                continue
            c_named, c_positional = named_args(masked, cop, ccl)
            span = c_named.get("text") or (c_positional[0] if c_positional else None)
            if span is None:
                continue
            value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
            if value is not None and is_chrome_label(value):
                continue
            if dynamic:
                expression = strip_kotlin_comments(collapse(text[span[0]:span[1]]))
                enc = enclosing_function(function_spans(masked), child.start())
                if enc and expression in enc["params"]:
                    continue
                break
            label = value
            break
        if label and label.strip():
            labels.append(label)
            found.append((label, m.start()))
    # A search field is the contract's `search` action: `ImeAction.Search` marks it,
    # and the label is the placeholder (or its accessibility description).
    for m in SECTION_CALL_RE.finditer(masked):
        if m.group(1) not in ("BasicTextField", "TextField"):
            continue
        open_paren = m.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0 or "ImeAction.Search" not in masked[open_paren:close]:
            continue
        field_named, _ = named_args(masked, open_paren, close)
        label = None
        for key in ("decorationBox", "placeholder"):
            span = field_named.get(key)
            if span is None:
                continue
            hit = re.search(r"\bBasicText[ \t]*\(", masked[span[0]:span[1]])
            if not hit:
                continue
            pop = span[0] + hit.end() - 1
            pcl = match_paren(masked, pop)
            if pcl < 0:
                continue
            p_named, _ = named_args(masked, pop, pcl)
            if "text" in p_named:
                value, dynamic = resolve_kotlin_expr(text[p_named["text"][0]:p_named["text"][1]], strings, consts)
                if value:
                    label = value
                    break
        if label:
            labels.append(label)
            found.append((label, m.start()))
    # -- standard Compose controls (the label is visible in the source) --------
    spans = function_spans(masked)
    wrappers = set(wrappers or ()) | button_wrappers(masked, spans)

    def record(value, dynamic, idiom: str, pos: int = 0) -> None:
        if dynamic:
            variants = kotlin_label_variants(dynamic, strings, consts)
            if variants:
                for variant in variants:
                    labels.append(variant)
                    found.append((variant, pos))
                    if positions is not None:
                        positions.append((variant, pos))
                return
            unresolved.append(strip_kotlin_comments(dynamic)[:DYN_EXPR_MAX])
            if stats is not None:
                stats[idiom + ".unresolved"] = stats.get(idiom + ".unresolved", 0) + 1
        elif value and value.strip():
            labels.append(value)
            found.append((value, pos))
            if positions is not None:
                positions.append((value, pos))
            if stats is not None:
                stats[idiom] = stats.get(idiom, 0) + 1

    for m in SECTION_CALL_RE.finditer(masked):
        callee = m.group(1)
        if is_declaration(masked, m.start()):
            continue
        if callee not in MATERIAL_BUTTONS + CHIP_CONTROLS + ("DropdownMenuItem",) and callee not in wrappers:
            continue
        call = call_at(masked, m.start())
        if not call:
            continue
        enc = enclosing_function(spans, m.start())
        skip = set(enc["params"]) if enc else set()
        # For page-local wrappers such as EntryRow(label, …) { onClick() }, the
        # trailing closure is the click handler, not visible button content.
        closure = call["trailing"] if callee in MATERIAL_BUTTONS + CHIP_CONTROLS + ("DropdownMenuItem",) else None
        if closure is None:
            for key in ("content", "label", "text"):
                if key in call["named"]:
                    span = call["named"][key]
                    if "{" in text[span[0]:span[1]]:
                        closure = (span[0], span[1])
                    break
        idiom = ("material-button" if callee in MATERIAL_BUTTONS
                 else "chip" if callee in CHIP_CONTROLS
                 else "dropdown-item" if callee == "DropdownMenuItem"
                 else "button-wrapper")
        if callee == "DropdownMenuItem":
            if "enabled" in call["named"] and "false" in text[call["named"]["enabled"][0]:
                                                           call["named"]["enabled"][1]].lower():
                continue
            # A disabled item is a status row. An enabled item with a no-op handler is
            # still tappable UI, so it stays (a no-op button is a bug, not a label).
        if closure is not None:
            value, dynamic = text_label_in(text, masked, closure[0], closure[1], strings, consts, skip)
            if (callee == "DropdownMenuItem" and value is None and dynamic
                    and not kotlin_label_variants(dynamic, strings, consts)):
                continue  # a data row: DropdownMenuItem(text = { Text(expr) }) is not a named action
            # A segmented control often renders only its value; the caption in the
            # same Row/Column is its label (`Text("方向"); SegmentedButton { … }`).
            # `dynamic` does not disqualify that: the dynamic text is the *value*
            # (the selected segment), while the caption beside it is the label and
            # is written literally in the source. Requiring `dynamic is None` made
            # every captioned segmented control read as an unlabelled action —
            # which is a false finding against a correct page.
            if value is None and callee in CHIP_CONTROLS:
                # A segmented control often renders only its value; the caption in the
                # same Row/Column is its label (`Text("方向"); SegmentedButton { … }`).
                container = enclosing_container(text, masked, m.start())
                if container:
                    value, dynamic = nearest_text_in_container(text, masked, container, m.start(),
                                                               strings, consts, skip)
            record(value, dynamic, idiom, m.start())
            continue
        span = None
        for key in (("label", "description", "text", "title") if callee in wrappers
                    else ("text", "label", "title")):
            if key in call["named"]:
                span = call["named"][key]
                break
        if span is None and call["positional"]:
            span = call["positional"][0]
        if span is None:
            continue
        value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
        record(value, None if not dynamic else collapse(text[span[0]:span[1]]), idiom, m.start())

    # Switch/Checkbox: label = same container's nearest direct-child Text, or `label =`.
    for m in SECTION_CALL_RE.finditer(masked):
        if m.group(1) not in TOGGLE_CONTROLS or is_declaration(masked, m.start()):
            continue
        call = call_at(masked, m.start())
        if not call:
            continue
        enc = enclosing_function(spans, m.start())
        skip = set(enc["params"]) if enc else set()
        label = expr = None
        if "label" in call["named"]:
            span = call["named"]["label"]
            if "{" in text[span[0]:span[1]]:
                label, expr = text_label_in(text, masked, span[0], span[1], strings, consts, skip)
            else:
                value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
                label, expr = (value, None) if not dynamic else (None, collapse(text[span[0]:span[1]]))
        else:
            container = enclosing_container(text, masked, m.start())
            if container:
                label, expr = nearest_text_in_container(text, masked, container, m.start(),
                                                        strings, consts, skip)
        record(label, expr, "toggle", m.start())
    # A collapsible `SectionHeader(title = …, onToggle = …)` is both a section title and a
    # tap target. It counts as an action only when the baseline declares that header as
    # one (SessionsPage's `已归档` is a Button); everywhere else the fold is chrome.
    fold_labels = fold_labels or frozenset()
    for m in SECTION_CALL_RE.finditer(masked):
        if m.group(1) != "SectionHeader" or is_declaration(masked, m.start()):
            continue
        call = call_at(masked, m.start())
        if not call or "onToggle" not in call["named"]:
            continue
        span = call["named"].get("title") or (call["positional"][0] if call["positional"] else None)
        if span is None:
            continue
        value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
        if dynamic or not value:
            continue
        if normalize(value) in fold_labels:
            labels.append(value)
            found.append((value, m.start()))
    for label, pos in verified_developer_tools_action_positions(text, masked, strings, consts):
        labels.append(label)
        found.append((label, pos))
        if positions is not None:
            positions.append((label, pos))
    # `%d 项需要处理` is rendered data, not a fixed action label: templates never
    # participate in missing/extra comparison (section titles keep them — the
    # contract's `titleTemplate` is exactly this shape).
    labels = [label for label in labels if not is_template_label(label)]
    found = [(label, pos) for label, pos in found if not is_template_label(label)]
    return labels, unresolved, found


# ---------------------------------------------------------------------------
# Page title.
# ---------------------------------------------------------------------------


def title_literals(expr: str, strings: dict, consts: dict) -> list:
    """Every literal an Android title expression can render, in source order.

    A dynamic title is not automatically incomparable: `preview?.artifact?.name ?:
    UiStrings.ARTIFACTS_TITLE` has a literal fallback, and `when { editing == null ->
    UiStrings.MODEL_PROVIDER_TITLE … }` has a literal branch per mode. Resolving the
    literals lets the check accept a page whose *one* mode renders the contract title
    while still catching a fallback that says something else.
    """
    out = []
    for m in TITLE_TOKEN_RE.finditer(expr):
        if m.group(1):
            value = strings.get(m.group(1))
        elif m.group(2) is not None:
            value = m.group(2).replace('\\"', '"').replace("\\n", "\n")
        else:
            value = consts.get(m.group(3))
        if value and value.strip() and value not in out:
            out.append(value)
    return out


def android_page_title(text: str, masked: str, spans: list, screen: str | None,
                       strings: dict, consts: dict) -> dict | None:
    """The title the mapped screen passes to its own frame, or None.

    The scan is scoped to the screen composable: `MCPSettingsPage.kt` also declares
    the editor's `PageFrame`, and reading the file's first title would compare the
    list page against the editor's heading. The frame name is matched by suffix
    (`PageFrame`, `SettingsSubPageFrame`, `SettingsNavBar`, `AutomationFrame`,
    `ShellTopBar`) so a page-local shell is read instead of reported as untitled.
    """
    span = next((item for item in spans if item["name"] == screen), None)
    if span is None:
        return None
    for m in TITLE_CALL_RE.finditer(masked, span["body_start"], span["body_end"]):
        callee = m.group(1)
        if not callee.endswith(("Frame", "Bar")):
            continue
        if is_declaration(masked, m.start()):
            continue
        call = call_at(masked, m.start())
        if not call:
            continue
        key = next((name for name in TITLE_KEYS if name in call["named"]), None)
        if key is None:
            continue
        start, end = call["named"][key]
        expr = collapse(text[start:end])
        value, dynamic = resolve_kotlin_expr(expr, strings, consts)
        return {
            "callee": callee,
            "key": key,
            "expr": expr,
            "value": None if dynamic else value,
            "dynamic": dynamic,
            "line": text.count("\n", 0, m.start()) + 1,
        }
    return None


def compare_title(contract: dict, report: "Report", android_file: str, text: str,
                  masked: str, spans: list, strings: dict, consts: dict) -> dict:
    """Compare the contract's `.navigationTitle` with the Android frame's title."""
    page_id = contract["pageId"]
    title = contract.get("title") or {}
    expected = title.get("text")
    summary = {"contract": expected, "android": None, "status": "none"}
    if not expected:
        return summary  # the baseline declares no page title (chat, sessions, …)
    got = android_page_title(text, masked, spans, contract["android"].get("screen"),
                             strings, consts)
    if got is None:
        summary["status"] = "missing"
        report.add(page_id, "missing-title", expected,
                   f"the baseline titles this page {expected!r} ({title.get('provenance')}); "
                   f"the Android page declares no `*Frame` / `*Bar` title the gate can read")
        return summary
    summary["dynamic"] = got["dynamic"]
    summary["android"] = (got["value"] if not got["dynamic"]
                          else got["expr"][:DYN_EXPR_MAX])
    if not got["dynamic"]:
        if normalize(got["value"]) == normalize(expected):
            summary["status"] = "match"
            return summary
        summary["status"] = "mismatch"
        report.add(page_id, "title-mismatch", expected,
                   f"the Android page titles itself {got['value']!r} "
                   f"({android_file}:{got['line']}, {got['callee']}.{got['key']}); the "
                   f"baseline's .navigationTitle is {expected!r} ({title.get('provenance')})")
        return summary
    literals = title_literals(got["expr"], strings, consts)
    if any(normalize(value) == normalize(expected) for value in literals):
        # One page with several headings (list / empty state / editor): the contract's
        # title is one of them, so the page does render it. A *different* fixed title
        # is the finding; a mode-specific one is not.
        summary["status"] = "dynamic-branch"
        return summary
    if CONTRACT_DYNAMIC_TITLE_RE.search(title.get("anchor") or ""):
        # The baseline itself computes its title (`directory.isEmpty ? … : …`), so
        # neither side fixes one string: nothing to compare, and saying so is better
        # than guessing a branch.
        summary["status"] = "dynamic-both"
        return summary
    if not literals:
        summary["status"] = "unresolved"
        report.add(page_id, "unresolved-title", got["expr"][:DYN_EXPR_MAX],
                   f"the Android title is an expression ({got['expr']!r}) that names no "
                   f"literal, so it cannot be compared with the contract's {expected!r}; "
                   f"give the frame a `UiStrings` title or a literal fallback")
        return summary
    summary["status"] = "mismatch"
    report.add(page_id, "title-mismatch", expected,
               f"the Android title is dynamic ({got['expr']!r}); it can render "
               + " / ".join(f"`{value}`" for value in literals)
               + f", none of which is the contract's {expected!r}")
    return summary


# ---------------------------------------------------------------------------
# Page outline: where a row/header sits, for untitled-group criteria.
# ---------------------------------------------------------------------------


def android_row_positions(text: str, masked: str, strings: dict, consts: dict) -> list:
    """(label, pos) for every visible row label, in source order.

    An untitled group is identified by a *row*, which may be a plain text line
    (`Text("还没有可显示的内容")`), not only a clickable action. The settings rows
    are the same fact through a wrapper (`SettingsFormRow(title = …)`), so PR22's
    AboutPage 版本 row must count even though it is not a bare `Text`.
    """
    out = []
    for m in SECTION_CALL_RE.finditer(masked):
        callee = m.group(1)
        if callee not in ROW_CALLS:
            continue
        open_paren = m.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0:
            continue
        named, positional = named_args(masked, open_paren, close)
        span = (named.get("title") or named.get("text") or named.get("label")
                or (positional[0] if positional else None))
        if span is None:
            continue
        value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
        if not dynamic and value and value.strip() and not is_chrome_label(value):
            out.append((value, m.start()))
    about_rows = verified_about_row_positions(text, masked, strings, consts)
    if about_rows is not None:
        out.extend(about_rows)
    return out


def find_row(rows: list, label: str) -> int | None:
    """Position of the first row whose label matches `label`, or None."""
    key = normalize(label)
    for value, pos in sorted(rows, key=lambda item: item[1]):
        if normalize(value) == key:
            return pos
    return None


def header_before(headers: list, pos: int) -> str | None:
    """Nearest section title declared before `pos`."""
    best = None
    for value, header_pos in sorted(headers, key=lambda item: item[1]):
        if header_pos < pos:
            best = value
    return best


# ---------------------------------------------------------------------------
# Findings, whitelist and baseline.
# ---------------------------------------------------------------------------


class Report:
    def __init__(self) -> None:
        self.findings = []          # (page_id, kind, name, detail)
        self.whitelisted = []       # (entry_id, page_id, kind, name)
        self.accepted = []          # entries matched (for stale detection)
        self.pages = []
        self.registered = []        # (finding, registry entry)
        self.dead = []              # (page_id, presentation)
        self.spec_ack = []          # (target, host_id, readme_line, phrase, refs)
        self.spec_facts = []        # (target, host_id, readme_line, phrase, acknowledged)
        self.suppressed = []        # (page_id, section)
        self.android_only = []      # (page_id, kind, name, meta)
        self.dead_actions = []      # (page_id, action)
        self.subpages = []          # (page_id, subpage entries)
        self.dead_decls = []        # (page_id, unreachable member)
        # (page_id, kind, label, guard, contract condition, divergent): a section
        # title or action label that only renders behind a nullable-callback guard.
        # Divergent entries also produce a `conditional-section` /
        # `conditional-action` finding; the others match the baseline's own condition.
        self.conditional = []
        self._keys = set()

    def add(self, page_id: str, kind: str, name: str, detail: str = "") -> None:
        # Two labels that normalise to the same title are one divergence: the
        # contract may spell `{count}` where the page spells `%d`, and counting that
        # twice would make the workload number depend on punctuation.
        # Titles/labels compare on meaning; ids (presentations, screen names) do not.
        key = (page_id, kind, normalize(name)
               if kind.startswith(("missing-", "extra-", "unresolved-")) else name)
        if key in self._keys:
            return
        self._keys.add(key)
        self.findings.append((page_id, kind, name, collapse(detail)))

    def for_page(self, page_id: str) -> list:
        return [f for f in self.findings if f[0] == page_id]


def load_platform_ids(root: Path) -> set:
    path = root / PLATFORM_WHITELIST_REL
    if not path.is_file():
        return set()
    data = load_json(path)
    if not isinstance(data, list):
        raise CheckError(f"{PLATFORM_WHITELIST_REL}: expected a list of entries")
    return {entry.get("id") for entry in data if isinstance(entry, dict)}


def load_whitelist(root: Path, contracts: dict, platform_ids: set) -> list:
    path = root / WHITELIST_REL
    if not path.is_file():
        raise CheckError(f"{WHITELIST_REL} is missing (write {{\"schema\": ..., \"entries\": []}})")
    data = load_json(path)
    if not isinstance(data, dict) or data.get("schema") != WHITELIST_SCHEMA:
        raise CheckError(f"{WHITELIST_REL}: not a {WHITELIST_SCHEMA} document")
    entries = data.get("entries")
    if not isinstance(entries, list):
        raise CheckError(f"{WHITELIST_REL}: `entries` must be a list")
    today = datetime.date.today()
    seen = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise CheckError(f"{WHITELIST_REL}: an entry is not an object")
        for key in ("id", "page", "kind", "name", "side", "platformRef", "owner", "reviewBy", "reason"):
            if key not in entry:
                raise CheckError(f"{WHITELIST_REL}: entry {entry.get('id')!r} misses `{key}`")
        if entry["id"] in seen:
            raise CheckError(f"{WHITELIST_REL}: duplicate entry id {entry['id']!r}")
        seen.add(entry["id"])
        if entry["page"] not in contracts:
            raise CheckError(f"{WHITELIST_REL}: entry {entry['id']!r} names unknown page {entry['page']!r}")
        if entry["kind"] not in KINDS:
            raise CheckError(f"{WHITELIST_REL}: entry {entry['id']!r} has unknown kind {entry['kind']!r}")
        if entry["side"] not in SIDES:
            raise CheckError(f"{WHITELIST_REL}: entry {entry['id']!r} side must be one of {sorted(SIDES)}")
        if entry["platformRef"] not in platform_ids:
            raise CheckError(f"{WHITELIST_REL}: entry {entry['id']!r} references unknown "
                             f"platform id {entry['platformRef']!r}")
        if not str(entry["reason"]).strip() or not str(entry["owner"]).strip():
            raise CheckError(f"{WHITELIST_REL}: entry {entry['id']!r} needs a reason and an owner")
        if not DATE_RE.match(str(entry["reviewBy"])):
            raise CheckError(f"{WHITELIST_REL}: entry {entry['id']!r} reviewBy must be YYYY-MM-DD")
        review_by = datetime.date.fromisoformat(entry["reviewBy"])
        if review_by < today:
            raise CheckError(f"{WHITELIST_REL}: entry {entry['id']!r} reviewBy {review_by} is in the past; "
                             f"re-review the divergence and extend it or delete it")
    return entries


def apply_whitelist(report: Report, entries: list) -> None:
    """Remove whitelisted findings; an entry that matches nothing is stale."""
    by_key = {}
    for entry in entries:
        by_key.setdefault((entry["page"], entry["kind"], normalize(entry["name"])), []).append(entry)
    kept = []
    for finding in report.findings:
        page_id, kind, name, detail = finding
        matched = by_key.get((page_id, kind, normalize(name)))
        if matched:
            entry = matched.pop(0)
            report.whitelisted.append((entry["id"], page_id, kind, name))
            report.accepted.append(entry["id"])
            continue
        kept.append(finding)
    report.findings = kept
    stale = [entry["id"] for entries in by_key.values() for entry in entries]
    if stale:
        raise CheckError("whitelist entries match no divergence (promote or delete them): " + ", ".join(sorted(stale)))


def load_baseline(path: Path) -> dict:
    data = load_json(path)
    if not isinstance(data, dict) or data.get("schema") != BASELINE_SCHEMA:
        raise CheckError(f"{path.name}: not a {BASELINE_SCHEMA} document")
    entries = data.get("divergences")
    if not isinstance(entries, list):
        raise CheckError(f"{path.name}: `divergences` must be a list")
    out = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise CheckError(f"{path.name}: a baseline entry is not an object")
        for key in ("page", "kind", "name", "reason", "lane"):
            if key not in entry:
                raise CheckError(f"{path.name}: a baseline entry misses `{key}`")
        if entry["kind"] not in KINDS:
            raise CheckError(f"{path.name}: unknown kind {entry['kind']!r}")
        if not str(entry["reason"]).strip():
            raise CheckError(f"{path.name}: {entry['page']}/{entry['name']!r} needs a real reason")
        if entry["lane"] == UNREVIEWED_LANE:
            raise CheckError(f"{path.name}: {entry['page']}/{entry['name']!r} is UNREVIEWED; "
                             f"assign lane C/D/E/F/G/H and a real reason before loading it")
        if entry["lane"] not in BASELINE_LANES:
            raise CheckError(f"{path.name}: {entry['page']}/{entry['name']!r} lane "
                             f"{entry['lane']!r} is not one of C/D/E/F/G/H")
        name = (normalize(entry["name"])
                if entry["kind"].startswith(("missing-", "extra-", "unresolved-")) else entry["name"])
        out.add((entry["page"], entry["kind"], name))
    return out


def _existing_baseline_rows(path: Path) -> dict:
    """Read the current baseline leniently, so `--write-baseline` can keep reviews."""
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    rows = {}
    for entry in data.get("divergences", []):
        if not isinstance(entry, dict):
            continue
        kind, name = entry.get("kind"), entry.get("name")
        if not isinstance(kind, str) or not isinstance(name, str):
            continue
        key = (entry.get("page"), kind,
               normalize(name) if kind.startswith(("missing-", "extra-", "unresolved-")) else name)
        rows[key] = entry
    return rows


def baseline_payload(report: Report, contracts: dict, existing: dict | None = None) -> dict:
    rows, seen = [], set()
    existing = existing or {}
    for page_id, kind, name, _detail in sorted(set(report.findings)):
        key = (page_id, kind, normalize(name)
               if kind.startswith(("missing-", "extra-", "unresolved-")) else name)
        if key in seen:
            continue
        seen.add(key)
        reviewed = existing.get(key) or {}
        rows.append({
            "page": page_id,
            "kind": kind,
            "name": name,
            "lane": reviewed.get("lane") or UNREVIEWED_LANE,
            "reason": reviewed.get("reason") or (
                f"new divergence on {page_id} ({kind}); review it, name the owning lane and "
                f"write why it is real before loading this baseline"),
        })
    note = ("Known page-structure divergences between the iOS contract and the Android "
            "screens. This ratchet only shrinks: fix one, delete its row. Regenerate with "
            "--write-baseline only when the change is reviewed as a ratchet move; new rows "
            "are written UNREVIEWED and refuse to load until a lane and reason are assigned.")
    return {"schema": BASELINE_SCHEMA, "note": note, "contracts": len(contracts),
            "divergences": rows}


# ---------------------------------------------------------------------------
# Per-page comparison.
# ---------------------------------------------------------------------------


def compare(root: Path, contract: dict, report: Report, strings: dict, shared_consts: dict,
            wrappers: frozenset = frozenset()) -> dict:
    page_id = contract["pageId"]
    android = contract["android"]
    summary = {"page": page_id, "screen": contract["page"], "android": android.get("file"),
               "sections": {"contract": 0, "titled": 0, "android": 0},
               # `contract` is the whole action inventory; `labelled` is what the gate
               # actually compares, and `keys` the unique wordings after normalisation.
               # Printing the inventory next to the Android label count read as "38
               # controls are missing" on chat (67 vs 29) when both sides compared the
               # same 24 wordings (36 labelled actions collapse to 24 by wording).
               "actions": {"contract": 0, "labelled": 0, "keys": 0, "unlabelled": 0,
                           "dynamic": 0, "dead": 0, "androidOnly": 0, "android": 0,
                           "android_keys": 0, "conditional": 0},
               "title": {"contract": None, "android": None, "status": "none",
                         "dynamic": False},
               "findings": 0}
    contract_sections = contract["sections"]
    suppressed = [s for s in contract_sections if s.get("suppressed")]
    contract_sections = [s for s in contract_sections if not s.get("suppressed")]
    summary["suppressed"] = len(suppressed)
    for section in suppressed:
        report.suppressed.append((page_id, section))
    subpage_titles = {normalize(sec.get("title") or "")
                      for page in contract.get("subpages", [])
                      for sec in page.get("sections", [])}
    if subpage_titles:
        report.subpages.append((page_id, contract.get("subpages", [])))
    android_only_sections = [s for s in contract_sections if s.get("androidOnly")]
    titled = [s for s in contract_sections
              if (s.get("title") or s.get("titleTemplate")) and not s.get("androidOnly")]
    android_only_titles = {normalize(s.get("title") or "") for s in android_only_sections}
    summary["sections"]["contract"] = len(contract_sections)
    summary["sections"]["titled"] = len(titled)
    contract_actions = contract["actions"]
    dead_presentation_ids = {p["id"] for p in contract.get("presentations", []) if p.get("deadUi")}
    dead_actions = [a for a in contract_actions
                    if a.get("presentedBy") in dead_presentation_ids
                    or a.get("deadPresentation") in dead_presentation_ids]
    live_actions = [a for a in contract_actions if a not in dead_actions]
    # Symmetric with the Android side above: a format template is rendered data on
    # BOTH sides. The Android reader already drops `%d 项需要处理`-shaped labels, but
    # the contract side kept `删除 %@` as a literal, so an action the page renders
    # correctly (the confirm key reads `删除 DeepSeek`) could never satisfy it.
    # A label is not always one string: the contract records the other wording of a
    # ternary/`if` label in `labelAlternatives`, so the comparison runs on the set.
    without_wording = [a for a in live_actions if not action_wording(a)]
    dynamic_labels = [a for a in live_actions
                      if action_wording(a) and a.get("dynamicLabel")]
    labelled = [a for a in live_actions
                if action_wording(a) and not a.get("dynamicLabel")]
    android_only_actions = [a for a in labelled if a.get("androidOnly")]
    labelled = [a for a in labelled if not a.get("androidOnly")]
    summary["actions"].update({
        "contract": len(contract_actions),
        "labelled": len(labelled),
        "unlabelled": len(without_wording),
        "dynamic": len(dynamic_labels),
        "dead": len(dead_actions),
        "androidOnly": len(android_only_actions),
    })

    path = root / android["file"] if android.get("file") else None
    if path is None or not path.is_file():
        report.add(page_id, "missing-section", "<android-screen>",
                   f"no Android screen for {contract['page']} "
                   f"(contract.android.match={android.get('match')!r})")
        summary["findings"] = 1
        return summary
    text = read_text(path)
    masked = mask_kotlin(text)
    if android.get("screen") and f"fun {android['screen']}(" not in masked:
        report.add(page_id, "missing-section", "<android-screen>",
                   f"{android['file']} no longer declares fun {android['screen']}()")
        summary["findings"] = 1
        return summary

    consts = {**shared_consts, **local_constants(text)}
    consts["__native_text_forwarder__"] = bool(re.search(
        r"fun\s+native\s*\(\s*chinese\s*:\s*String\s*,\s*english\s*:\s*String\s*\)\s*:\s*String\s*=\s*"
        r"UiStrings\.settingsNativeText\(\s*languageId\s*,\s*chinese\s*,\s*english\s*\)", text,
    ))
    section_positions, action_positions = [], []
    # A fold header whose wording is the action's alternative is still that action's
    # header, so the fold test reads every wording, not only the primary one.
    fold_labels = frozenset(normalize(value) for a in labelled for value in action_wording(a))
    android_titles, unresolved_titles = android_sections(text, masked, strings, consts,
                                                        positions=section_positions)
    android_labels, unresolved_labels, action_occurrences = android_actions(
        text, masked, strings, consts, wrappers=wrappers, positions=action_positions,
        fold_labels=fold_labels)
    verified_model = verified_settings_index_model(text, masked, strings, consts)
    if verified_model is not None:
        model_titles, model_section_positions, model_labels, model_action_positions = verified_model
        android_titles.extend(model_titles)
        section_positions.extend(model_section_positions)
        # The generic label scan sees the rendered projection `section.title`, which
        # is dynamic by itself. The verified constructor→renderer path above supplies
        # the literal titles from the model and makes only that projection resolvable.
        unresolved_titles = [expr for expr in unresolved_titles if expr != "section.title"]
        android_labels.extend(model_labels)
        action_occurrences.extend(model_action_positions)
        action_positions.extend(model_action_positions)
    verified_font_roles = verified_font_size_role_model(text, masked, strings, consts)
    if verified_font_roles is not None:
        role_titles, role_positions = verified_font_roles
        android_titles.extend(role_titles)
        section_positions.extend(role_positions)
        unresolved_titles = [expr for expr in unresolved_titles if expr != "role.title"]
    android_labels = [label for label in android_labels if not is_chrome_label(label)]
    action_occurrences = [(label, pos) for label, pos in action_occurrences
                          if not is_chrome_label(label)]
    # A label under `if (hostCallback != null)` / `callback?.let { … }` is present in
    # the source but not guaranteed on screen. Keep the two sets apart: only the
    # unconditional occurrences satisfy the contract, the conditional ones are
    # reported (`conditional-action`) instead of silently counting as present.
    spans = function_spans(masked)
    guards = null_guards(masked, spans)
    conditional_guard, unconditional_keys = {}, set()
    for label, pos in action_occurrences:
        key = normalize(label)
        guard = null_guard_at(guards, pos)
        if guard is None:
            unconditional_keys.add(key)
        else:
            conditional_guard.setdefault(key, guard)
    conditional_keys = set(conditional_guard) - unconditional_keys
    if page_id == "chat" and verified_chat_artifact_route_binding(root):
        # The reusable ChatPage prop defaults to null, but the actual PdshNavHost
        # ChatRoute passes this literal route callback unconditionally. Keep the
        # generic component guard while judging the shipped route as present.
        artifact_key = normalize("产物")
        if artifact_key in conditional_keys:
            conditional_keys.discard(artifact_key)
            unconditional_keys.add(artifact_key)
    # Section labels can be guarded the same way (`if (onShow != null) {
    # SessionSectionLabel(...) }`); the hole is about any labelled UI, not only
    # buttons. The contract records a section's `condition` from syntax extraction,
    # unlike an action's, so accepting a baseline-conditional section is direct.
    section_conditional_guard, section_unconditional = {}, set()
    for title, pos in section_positions:
        key = normalize(title)
        guard = null_guard_at(guards, pos)
        if guard is None:
            section_unconditional.add(key)
        else:
            section_conditional_guard.setdefault(key, guard)
    section_conditional_only = set(section_conditional_guard) - section_unconditional
    # The baseline's own `if` guards. A contract action the baseline also renders
    # conditionally is allowed to be conditional on Android; only an action the
    # baseline always draws is a divergence when Android only draws it behind a
    # nullable callback.
    baseline_conditions = baseline_conditional_actions(root, contract)
    summary["sections"]["android"] = len(android_titles)
    summary["actions"]["android"] = len(android_labels)
    summary["actions"]["conditional"] = len(conditional_keys)
    section_model = contract.get("sectionModel", "section")
    summary["sectionModel"] = section_model

    # A sheet/alert whose binding the page never assigns is dead UI in the baseline.
    for presentation in contract.get("presentations", []):
        if presentation.get("deadUi"):
            report.dead.append((page_id, presentation))
            continue
        if presentation.get("triggered") is False:
            report.add(page_id, "orphan-presentation", presentation["id"],
                       f"{presentation['kind']} at {presentation.get('provenance')} is never opened: "
                       f"{presentation.get('triggerBindings')} is never assigned")

    def section_key(section: dict) -> str:
        return normalize(section.get("titleTemplate") or section.get("title") or "")

    expected_titles = {section_key(s): (s.get("title") or s.get("titleTemplate")) for s in titled}
    actual_titles, literal_sections = {}, []
    for title in android_titles:
        if SOURCE_EXPR_RE.search(title):
            literal_sections.append(title)
            continue
        actual_titles[normalize(title)] = title
    # A group whose title is data (`Section(fileGroupTitle)`) is identified by its
    # criterion too: the title is not comparable, the row is.
    untitled = [s for s in contract_sections
                if not (s.get("title") or s.get("titleTemplate"))]
    if section_model in ("section", "regions"):
        # An untitled group is judged by its criterion, not reported unconditionally:
        # find the criterion row; no header before it is the baseline's shape, a header
        # the contract does not declare is the divergence, a missing row is the group.
        row_positions = action_positions + android_row_positions(text, masked, strings, consts)
        for section in untitled:
            criterion = section.get("criterion") or {}
            label = criterion.get("label")
            if not label:
                report.add(page_id, "unresolved-section",
                           f"<untitled: {criterion.get('labelExpr') or criterion.get('kind')}>",
                           f"criterion at {criterion.get('provenance') or section.get('provenance')} "
                           f"has no literal row label, so it cannot be matched against the Android page")
                continue
            row_pos = find_row(row_positions, label)
            if row_pos is None:
                report.add(page_id, "missing-section", label,
                           f"the untitled group's criterion row ({criterion.get('kind')} at "
                           f"{criterion.get('provenance')}) is absent from the Android page")
                continue
            header = header_before(section_positions, row_pos)
            if header is not None and normalize(header) not in expected_titles \
                    and normalize(header) not in android_only_titles:
                report.add(page_id, "extra-section", header,
                           f"the contract group at {section.get('provenance')} is untitled; the "
                           f"Android page declares a header ({header!r}) for it")
        for title in literal_sections:
            report.add(page_id, "extra-section", title,
                       "the Android page renders a source expression (interpolation inside a "
                       "string literal); render the value instead")
        by_key = {section_key(section): section for section in titled}
        for key, title in expected_titles.items():
            if key not in actual_titles:
                report.add(page_id, "missing-section", title,
                           "contract section title absent from the Android page")
                continue
            if key not in section_conditional_only:
                continue
            section = by_key[key]
            guard = section_conditional_guard[key]
            if section.get("condition"):
                report.conditional.append(
                    (page_id, "section", title, guard, section["condition"], False))
            else:
                report.conditional.append((page_id, "section", title, guard, None, True))
                report.add(page_id, "conditional-section", title,
                           f"only rendered behind `{guard}`; the contract declares the "
                           f"section unconditionally, so it exists only when the host "
                           f"passes that callback")
        for key, title in actual_titles.items():
            if key not in expected_titles and key not in android_only_titles \
                    and key not in subpage_titles:
                detail = "Android section title absent from the contract"
                guard = section_conditional_guard.get(key)
                if guard:
                    detail += f" (rendered only behind `{guard}`)"
                report.add(page_id, "extra-section", title, detail)
        for expr in sorted(set(unresolved_titles)):
            report.add(page_id, "unresolved-section", expr,
                       "section title is an expression, so it cannot be compared to the contract")
    elif section_model == "single-region":
        pass  # manual judgement recorded in the contract; the note is printed below
    elif section_model == "unmodeled":
        report.add(page_id, "unresolved-section", "<manual region>",
                   "the baseline groups this page without Section/PageSection/GroupBox/header Text; "
                   "a human must name the group before the sections can be compared")

    # Display wording -> every key that satisfies it. `保存并连接` with the
    # alternative `保存修改并重连` is satisfied by either string on Android; when
    # neither appears the finding names the primary wording and lists the rest.
    expected_labels = []
    for action in labelled:
        if action.get("kind") == "picker" and action.get("style") == "segmented":
            items = list(action.get("items") or [])
            if items and normalize(items[0]) == normalize(action["label"]):
                items = items[1:]
            for item in items:
                segment = dict(action, label=item, _segmentedOption=True)
                expected_labels.append((segment, [item], [normalize(item)]))
            continue
        wordings = action_wording(action)
        if wordings:
            expected_labels.append((action, wordings,
                                    [normalize(value) for value in wordings]))
    expected_keys = {key for _action, _wordings, keys in expected_labels for key in keys}
    actual_labels = {normalize(l): l for l in android_labels}
    summary["actions"]["keys"] = len(expected_keys)
    summary["actions"]["android_keys"] = len(actual_labels)
    for action in android_only_actions:
        if normalize(action["label"]) in actual_labels:
            report.android_only.append((page_id, "action", action["label"], action["androidOnly"]))
        else:
            report.add(page_id, "android-only-stale", action["label"],
                       "declared androidOnly but the Android page no longer declares it "
                       f"(owner {action['androidOnly']['owner']}); restore it or delete the entry")
    for action in dead_actions:
        report.dead_actions.append((page_id, action))
    for section in android_only_sections:
        title = section.get("title") or ""
        if normalize(title) in actual_titles or normalize(title) in actual_labels:
            report.android_only.append((page_id, "section", title, section["androidOnly"]))
        else:
            report.add(page_id, "android-only-stale", title,
                       "declared androidOnly but the Android page no longer declares it "
                       f"(owner {section['androidOnly']['owner']}); restore it or delete the entry")
    android_only_label_keys = {normalize(a["label"]) for a in android_only_actions}
    dead_action_keys = {normalize(a["label"]) for a in dead_actions if a.get("label")}
    # A `picker` is a control, not a page action: `.pickerStyle(.segmented)` never
    # renders the Picker's own label (only its segments appear), and the segments
    # are the picker's `items` — choices, not actions. Comparing either one against
    # the page's action set reports a control as a missing button and its options
    # as invented buttons, which is a finding against a correct page. The contract
    # already carries `kind: picker` + `items`, so this needs no new field.
    picker_option_keys = set()
    picker_label_keys = set()
    for action in contract_actions:
        if action.get("kind") == "picker":
            if action.get("label"):
                picker_label_keys.add(normalize(action["label"]))
            for item in action.get("items") or []:
                picker_option_keys.add(normalize(item))
    # Android labels that match nothing on the contract side. One that merely
    # shortens a contract wording (`保存` for `保存并连接`) is the same control with
    # different copy: pair it so the defect is reported once, still red.
    unclaimed = {key: label for key, label in actual_labels.items()
                 if key not in expected_keys and key not in android_only_label_keys
                 and key not in dead_action_keys and key not in picker_option_keys}
    paired = {}
    for _action, wordings, keys in expected_labels:
        if (not _action.get("_segmentedOption") and
                all(key in picker_label_keys or key in picker_option_keys for key in keys)):
            continue
        if any(key in actual_labels for key in keys):
            continue
        for key in sorted(unclaimed):
            if key in paired:
                continue
            if shortened_copy(unclaimed[key], wordings) is not None:
                paired[key] = wordings[0]
                break
    for action, wordings, keys in expected_labels:
        if (not action.get("_segmentedOption") and
                all(key in picker_label_keys or key in picker_option_keys for key in keys)):
            continue
        if any(key in actual_labels for key in keys):
            # Present, but is it present unconditionally? A label the page only draws
            # under `if (onOpenDemo != null)` is not the control the contract declares:
            # the host may never pass the callback, and then the source has a label the
            # pixels do not. `files`'s `3D 示例` passed the gate exactly this way.
            if any(key in unconditional_keys for key in keys):
                continue
            guard = next(conditional_guard[key] for key in keys if key in conditional_guard)
            label = action.get("label") or wordings[0]
            baseline_condition = baseline_conditions.get(action.get("id")) or action.get("condition")
            if baseline_condition:
                report.conditional.append(
                    (page_id, "action", label, guard, baseline_condition, False))
            else:
                report.conditional.append((page_id, "action", label, guard, None, True))
                report.add(page_id, "conditional-action", wordings[0],
                           f"only rendered behind `{guard}`; the contract declares it "
                           f"unconditionally, so it exists only when the host passes that "
                           f"callback — a host that never does leaves a dead label in the source")
            continue
        detail = "contract action label absent from the Android page"
        if len(wordings) > 1:
            detail += (" (the baseline renders this one control as "
                       + " or ".join(f"`{value}`" for value in wordings)
                       + "; any of them matches)")
        short = [label for key, label in unclaimed.items()
                 if paired.get(key) == wordings[0]]
        if short:
            detail += (f"; the Android page renders `{short[0]}`, a shortened copy of "
                       "that wording, so this is one control with different copy")
        report.add(page_id, "missing-action", wordings[0], detail)
    for key, label in actual_labels.items():
        if key in paired:
            continue
        if key not in expected_keys and key not in android_only_label_keys \
                and key not in dead_action_keys and key not in picker_option_keys:
            detail = "Android action label absent from the contract"
            guard = conditional_guard.get(key)
            if guard:
                detail += f" (rendered only behind `{guard}`)"
            report.add(page_id, "extra-action", label, detail)
    for expr in sorted(set(unresolved_labels)):
        report.add(page_id, "unresolved-action", expr,
                   "action label is an expression, so it cannot be compared to the contract")

    # The page title: the contract's `.navigationTitle` vs the Android frame's title.
    summary["title"] = compare_title(contract, report, Path(android["file"]).name,
                                     text, masked, spans, strings, consts)

    summary["findings"] = len(report.for_page(page_id))
    return summary


# ---------------------------------------------------------------------------
# Driver.
# ---------------------------------------------------------------------------


def run(root: Path, strict: bool, baseline_path: Path | None, write_baseline: Path | None,
        only_page: str | None, verbose: bool) -> int:
    report = Report()
    all_contracts = load_contracts(root)
    if only_page and only_page not in all_contracts:
        raise CheckError(f"no contract for page {only_page!r}")
    contracts = {only_page: all_contracts[only_page]} if only_page else all_contracts
    platform_ids = load_platform_ids(root)
    # Validate the whitelist against every contract, then narrow it to the pages
    # being checked, so `--page` neither fails on another page's entry nor calls it stale.
    entries = load_whitelist(root, all_contracts, platform_ids)
    if only_page:
        entries = [entry for entry in entries if entry["page"] == only_page]
    strings = load_uistrings(root)
    shared_consts = load_page_consts(root)
    wrappers = frozenset(load_page_wrappers(root))

    # Rule 1: contract provenance is still accurate (a moved baseline is not a match).
    stale_contracts = []
    for contract in contracts.values():
        check_provenance(root, contract, stale_contracts)
    if stale_contracts:
        raise CheckError("stale page contracts (rerun extract_ios_pages.py and review the diff): "
                         + "; ".join(stale_contracts[:5])
                         + (" ..." if len(stale_contracts) > 5 else ""))

    # Rule 2: the Android page exists and declares the mapped screen, unless an
    # explicit, reviewed iOS-only milestone exception covers the whole page.
    ios_only = load_ios_only(root, all_contracts)
    summaries = []
    for contract in contracts.values():
        page_id = contract["pageId"]
        if page_id in ios_only:
            summaries.append({
                "page": page_id, "screen": contract["page"], "android": None,
                "sections": {"contract": len(contract["sections"]),
                             "titled": len([s for s in contract["sections"] if s.get("title")]),
                             "android": 0},
                "actions": {"contract": len(contract["actions"]), "labelled": 0, "keys": 0,
                            "unlabelled": 0, "dynamic": 0, "dead": 0, "androidOnly": 0,
                            "android": 0, "android_keys": 0, "conditional": 0},
                "findings": 0, "iosOnly": ios_only[page_id],
            })
        else:
            summaries.append(compare(root, contract, report, strings, shared_consts, wrappers))

    # Rule 2a: §1 entrances vs the baseline's reachable navigation.
    check_spec_entrances(root, all_contracts, report, only_page=only_page)

    # Rule 2b: every Android screen is a contract screen, an embedded subpage named by
    # its parent contract, or an explicitly Android-only screen.
    android_only = load_android_only(root)
    covered = {contract["android"].get("screen") for contract in all_contracts.values()
               if contract["android"].get("screen")}
    covered |= set(android_only)
    for contract in all_contracts.values():
        covered |= {sub["name"] for sub in contract.get("subpages", [])}
        # A kdoc/alias mapping has no asserted screen name; the file it points at is
        # still the screen's home, so the file's own *Page composable counts as covered.
        android_file = contract["android"].get("file")
        if android_file:
            stem = Path(android_file).stem
            if stem.endswith("Page"):
                covered.add(stem)
    page_dir = root / ANDROID_UI_REL / "page"
    if page_dir.is_dir():
        for kt in sorted(page_dir.glob("*.kt")):
            for screen in SCREEN_FUN_RE.findall(read_text(kt)):
                if screen in covered:
                    continue
                report.add("(android)", "unmapped-android-screen", screen,
                           f"{kt.relative_to(root).as_posix()} declares {screen}() but no contract or "
                           f"_android-only.json entry covers it")

    # Rule 3: explicitly registered non-comparable items leave the divergence set.
    registry = load_unrecognized(root, all_contracts)
    if only_page:
        registry = [entry for entry in registry if entry["page"] == only_page]
    apply_unrecognized(report, registry)

    # Rule 4: platform-forced differences are the only accepted ones.
    apply_whitelist(report, entries)

    # Rule 5: the ratchet.
    new_findings, stale_baseline = [], []
    known = set()
    if baseline_path is not None and write_baseline is None:
        known = load_baseline(baseline_path)
        if only_page:
            known = {entry for entry in known if entry[0] == only_page}
        def key(finding: tuple) -> tuple:
            page_id, kind, name = finding[0], finding[1], finding[2]
            return (page_id, kind,
                    normalize(name) if kind.startswith(("missing-", "extra-", "unresolved-")) else name)

        observed = {key(finding) for finding in report.findings}
        new_findings = [finding for finding in report.findings if key(finding) not in known]
        stale_baseline = sorted(known - observed)

    # -- printing ---------------------------------------------------------

    print(f"page-structure: {len(contracts)} page contract(s), "
          f"{len({s['android'] for s in summaries if s['android']})} Android screen(s), "
          f"{len(report.whitelisted)} whitelisted divergence(s)")
    for summary in summaries:
        # Bind the contract for THIS page: the loop used to reuse whatever
        # `contract` the previous iteration left, so every single-region page
        # printed the same (last) page's `sectionNote`.
        contract = contracts.get(summary["page"], {})
        findings = [f for f in report.findings if f[0] == summary["page"]]
        page_new = [f for f in new_findings if f[0] == summary["page"]]
        print(f"PAGE {summary['page']}  {summary['screen']} → {Path(summary['android']).name}"
              if summary["android"] else
              (f"PAGE {summary['page']}  {summary['screen']} → "
               f"(iOS-only until {summary['iosOnly']['milestone']})" if "iosOnly" in summary else
               f"PAGE {summary['page']}  {summary['screen']} → (no Android screen)"))
        model = summary.get("sectionModel", "section")
        if model in ("section", "regions"):
            print(f"  sections  contract {summary['sections']['contract']} "
                  f"({summary['sections']['titled']} titled, model={model})   "
                  f"android {summary['sections']['android']}"
                  f"   divergences {len([f for f in findings if f[1].endswith('section')])}")
        elif model == "single-region":
            print(f"  sections  single region (manual judgement): "
                  f"{contract.get('sectionNote') or 'one flat list'}; "
                  f"android declares {summary['sections']['android']}")
        else:
            print(f"  sections  not compared: the baseline page has no Section tree "
                  f"(sectionModel={model}); android declares {summary['sections']['android']}")
        actions = summary["actions"]
        basis = [f"{actions['unlabelled']} unlabelled", f"{actions['dynamic']} dynamicLabel"]
        if actions["dead"]:
            basis.append(f"{actions['dead']} in dead UI")
        if actions["androidOnly"]:
            basis.append(f"{actions['androidOnly']} androidOnly")
        conditional = actions["conditional"]
        print(f"  actions   labelled {actions['labelled']} of {actions['contract']} actions "
              f"({', '.join(basis)}) = {actions['keys']} comparable keys   "
              f"android {actions['android']} labels "
              f"({actions['android_keys']} keys: "
              f"{actions['android_keys'] - conditional} unconditional, "
              f"{conditional} conditional)   "
              f"divergences {len([f for f in findings if f[1].endswith('action')])}")
        title = summary.get("title") or {}
        if title.get("contract") is None:
            print("  title     contract (none: the baseline declares no page title)")
        else:
            dynamic = " (dynamic)" if title.get("dynamic") else ""
            print(f"  title     contract {title['contract']!r}   "
                  f"android {title.get('android')!r}{dynamic}   "
                  f"divergences {len([f for f in findings if f[1] in TITLE_KINDS])}")
        for finding in (page_new if baseline_path is not None and not verbose else findings):
            _, kind, name, detail = finding
            print(f"    - {kind:<19} {name!r}  {detail}")
        if baseline_path is not None and not verbose and page_new:
            kept = len(findings) - len(page_new)
            if kept:
                print(f"    ({kept} known divergence(s) in the baseline)")

    # Findings that belong to no contract page (Android screens nobody asked for).
    page_ids = {summary["page"] for summary in summaries}
    global_findings = [f for f in report.findings if f[0] not in page_ids]
    if global_findings:
        print("GLOBAL  Android screens without a contract")
        for _, kind, name, detail in (global_findings if baseline_path is None or verbose else new_findings):
            print(f"    - {kind:<19} {name!r}  {detail}")

    # Summary table: the workload list.
    print("\n== divergences by page (contract vs Android) ==")
    print(f"{'page':<24} {'sections -/+':>14} {'actions -/+':>14} {'cond':>5} "
          f"{'unresolved':>11} {'title':>6}")
    for summary in summaries:
        page_id = summary["page"]
        findings = [f for f in report.findings if f[0] == page_id]
        ms = len([f for f in findings if f[1] == "missing-section"])
        xs = len([f for f in findings if f[1] == "extra-section"])
        ma = len([f for f in findings if f[1] == "missing-action"])
        xa = len([f for f in findings if f[1] == "extra-action"])
        cd = len([f for f in findings if f[1].startswith("conditional-")])
        un = len([f for f in findings if f[1].startswith("unresolved")
                  and f[1] not in TITLE_KINDS])
        ti = len([f for f in findings if f[1] in TITLE_KINDS])
        flag = "" if not findings else ("  <- new" if baseline_path is not None and any(
            f in new_findings for f in findings) else "")
        print(f"{page_id:<24} {f'{ms}/{xs}':>14} {f'{ma}/{xa}':>14} {cd:>5} "
              f"{un:>11} {ti:>6}{flag}")

    total = len(report.findings)
    if report.android_only:
        print("\nandroid-only items (deliberate additions over the baseline):")
        for page_id, kind, name, meta in sorted(report.android_only):
            print(f"  {page_id} {kind} {name!r}  owner={meta['owner']} reviewBy={meta['reviewBy']}")
            print(f"      baselineLacks: {meta['reason']['baselineLacks']}")
            print(f"      androidNeeds : {meta['reason']['androidNeeds']}")
            print(f"      withoutIt    : {meta['reason']['withoutIt']}")
    if report.suppressed:
        print("\nsuppressed sections (the baseline's header is not a rendered title):")
        for page_id, section in report.suppressed:
            print(f"  {page_id} {section.get('id')!r} at {section.get('provenance')}: "
                  f"{section.get('suppressReason')}")
    if report.spec_facts:
        print("\nspec-baseline-mismatch (README §1 entrance vs the baseline's reachable navigation):")
        for target, host_id, line_no, phrase, acknowledged in report.spec_facts:
            mark = "acknowledged" if acknowledged else "open"
            print(f"  [{mark}] {target} ← {host_id}  README.md:{line_no} {phrase!r}")
    if report.dead_decls:
        print("\nbaseline dead code (declared, never rendered — do not copy):")
        for page_id, source_file, dead in report.dead_decls:
            provenance = f"{source_file}:{dead.get('line')}"
            end = dead.get("endLine")
            span = f"{provenance}-{end}" if end else provenance
            print(f"  {page_id} {dead.get('member')}  {span}  ({dead.get('sections')} Section(s))")
    if report.conditional:
        print("\nconditionally present (the label is in the source, but the item renders "
              "only when the host passes the callback):")
        for page_id, kind, label, guard, condition, divergent in sorted(
                report.conditional, key=lambda item: (item[0], item[1], item[2])):
            if divergent:
                verdict = "divergence: the contract declares it unconditionally"
            else:
                verdict = f"matches the contract's own condition ({condition})"
            print(f"  {page_id} {kind} {label!r}  behind `{guard}`  — {verdict}")
    if report.registered:
        print("\nregistered (explicitly not statically comparable):")
        for (page_id, kind, name, _detail), entry in sorted(report.registered):
            print(f"  {page_id} {kind} {name!r}  owner={entry['owner']} reviewBy={entry['reviewBy']}")
    if report.dead:
        print("\ndead UI in the baseline (confirmed, do not implement; its actions are not judged):")
        for page_id, presentation in report.dead:
            print(f"  {page_id} {presentation['id']}  {presentation.get('deadUiEvidence')}")
    if report.dead_actions:
        print("\n  actions inside dead presentations (not missing, not extra):")
        for page_id, action in report.dead_actions:
            by = action.get("presentedBy") or action.get("deadPresentation")
            print(f"    {page_id} {action.get('label')!r}  inside {by}")
    if report.subpages:
        print("\nsubpages (separate screens; their sections are outside this contract but printed):")
        for page_id, pages in report.subpages:
            for page in pages:
                titles = ", ".join(f"{s['title']} ({s['provenance']})" for s in page.get("sections", []))
                print(f"  {page_id} → {page['name']} ({page['provenance']}): {titles or 'no titled Section'}")
    if report.whitelisted:
        print("\nwhitelisted (platform-forced, spec/platform whitelist ids):")
        for entry_id, page_id, kind, name in sorted(report.whitelisted):
            print(f"  {entry_id}: {page_id} {kind} {name!r}")
    if stale_baseline:
        print("\nstale baseline entries (no longer diverging: remove them):")
        for page_id, kind, name in stale_baseline:
            print(f"  {page_id} {kind} {name!r}")
    # -- verdict ----------------------------------------------------------
    if write_baseline is not None:
        if stale_baseline:
            raise CheckError("refusing to write a baseline while it has stale entries: " +
                             ", ".join(f"{p}/{k}/{n}" for p, k, n in stale_baseline))
        payload = baseline_payload(report, contracts,
                                   existing=_existing_baseline_rows(root / PAGES_REL / "_baseline.json"))
        write_baseline.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"\nwrote {len(payload['divergences'])} known divergence(s) to {write_baseline}")
        return 0

    if baseline_path is not None:
        if stale_baseline:
            print(f"\npage-structure: FAIL ({len(stale_baseline)} stale baseline entr(y/ies))")
            return 1
        if new_findings:
            print(f"\npage-structure: FAIL ({len(new_findings)} new divergence(s) outside the baseline)")
            return 1
        print(f"\npage-structure: ok ({len(known)} known divergence(s), 0 new, 0 stale; "
              f"{len(report.whitelisted)} whitelisted)")
        return 0

    if total:
        print(f"\npage-structure: FAIL ({total} divergence(s); the Android screens do not match the contract)")
        return 1
    print(f"\npage-structure: ok (0 divergences, {len(report.whitelisted)} whitelisted)")
    return 0


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(description="Check the Android pages against the iOS page contract.")
    parser.add_argument("--root", default=".", help="repository root (default: .)")
    parser.add_argument("--strict", action="store_true",
                        help="ignore the baseline: every non-whitelisted divergence fails (default anyway)")
    parser.add_argument("--baseline", default=None,
                        help=f"known-divergence ratchet (default: {BASELINE_REL})")
    parser.add_argument("--write-baseline", default=None, help="write the current divergences to this file")
    parser.add_argument("--page", default=None, help="only this page id (e.g. sessions)")
    parser.add_argument("--verbose", action="store_true", help="print divergences already in the baseline")
    args = parser.parse_args(argv)

    if args.strict and args.baseline:
        print("page_structure_check: --strict and --baseline are mutually exclusive", file=sys.stderr)
        return 2
    root = Path(args.root).resolve()
    try:
        return run(
            root,
            strict=args.strict,
            baseline_path=Path(args.baseline) if args.baseline else None,
            write_baseline=Path(args.write_baseline) if args.write_baseline else None,
            only_page=args.page,
            verbose=args.verbose,
        )
    except CheckError as exc:
        print(f"FAIL  {exc}")
        return 1
    except OSError as exc:
        print(f"page_structure_check: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
