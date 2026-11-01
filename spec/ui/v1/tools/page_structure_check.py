#!/usr/bin/env python3
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
  silently equal.
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
)
ANDROID_ONLY_REL = PAGES_REL / "_android-only.json"
UNRECOGNIZED_REL = PAGES_REL / "_unrecognized.json"
UNRECOGNIZED_SCHEMA = "pdsh.ui.page-structure-unrecognized/1"
ANDROID_ONLY_SCHEMA = "pdsh.ui.page-structure-android-only/1"
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
FUN_DECL_RE = re.compile(r"\bfun\s+(\w+)\s*\(")
SIDES = {"ios-only", "android-only"}
PROVENANCE_RE = re.compile(r"^([A-Za-z][A-Za-z0-9]*\.swift):([0-9]+)$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
UISTRING_RE = re.compile(
    r"^[ \t]*public const val ([A-Z][A-Z0-9_]*): String = \"((?:[^\"\\]|\\.)*)\"[ \t]*$", re.M)
LOCAL_CONST_RE = re.compile(
    r"^[ \t]*(?:private |internal |public )?const val ([A-Z][A-Z0-9_]*): String = "
    r"\"((?:[^\"\\]|\\.)*)\"[ \t]*$", re.M)
CJK_RE = re.compile(r"[\u4e00-\u9fff]")
SECTION_CALL_RE = re.compile(r"\b([A-Z]\w*)[ \t]*\(")
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
    # A conditional that falls back to `null` still names a label when it is shown.
    m = re.fullmatch(r"if\s*\((.+)\)\s*(.+?)\s*else\s+null", text, re.S)
    if m:
        value, dynamic = resolve_kotlin_expr(m.group(2), strings, consts)
        if not dynamic:
            return value, False
    return None, True


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
        if m.group(1) != source["file"]:
            raise CheckError(f"{contract['pageId']}: {kind} {item.get('id')!r} points at {m.group(1)}, "
                             f"not {source['file']}")
        line_no = int(m.group(2))
        if not (1 <= line_no <= len(lines)):
            raise CheckError(f"{contract['pageId']}: {kind} {item.get('id')!r} line {line_no} is out of range")
        anchor = (item.get("anchor") or "").strip()
        if not anchor:
            raise CheckError(f"{contract['pageId']}: {kind} {item.get('id')!r} has no anchor")
        if anchor not in lines[line_no - 1]:
            stale.append(f"{contract['pageId']}/{kind}:{item.get('id')} {prov} no longer carries "
                         f"{anchor!r} (got {lines[line_no - 1].strip()!r})")


# ---------------------------------------------------------------------------
# Android extraction.
# ---------------------------------------------------------------------------


def is_declaration(masked: str, pos: int) -> bool:
    """`data class SettingsSectionView(` is a declaration, not a call site."""
    return bool(DECLARATION_TAIL_RE.search(masked[max(0, pos - 100): pos]))


def android_sections(text: str, masked: str, strings: dict, consts: dict,
                     positions: list | None = None) -> tuple:
    """(titled titles, unresolved expressions) declared by the page."""
    titles, unresolved = [], []
    for m in SECTION_CALL_RE.finditer(masked):
        callee = m.group(1)
        if not (callee.endswith(("SectionLabel", "SectionHeader", "SectionView", "SectionGroup"))):
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
        if callee.endswith(("SectionHeader", "SectionView", "SectionGroup")):
            span = named.get("title") or (positional[1] if (callee.endswith("SectionView")
                                                             and len(positional) > 1) else None)
            if span is None and callee.endswith("SectionHeader") and positional:
                span = positional[0]
        else:
            span = named.get("text") or (positional[0] if positional else None)
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
    """(name, params, body_start, body_end) for every function declaration."""
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
        params = []
        for a, b in split_args(masked, open_paren + 1, close):
            nm = re.match(r"\s*([a-z][A-Za-z0-9_]*)\s*:", masked[a:b])
            if nm:
                params.append(nm.group(1))
        out.append({"name": m.group(1), "params": params,
                    "body_start": brace, "body_end": close_brace})
    return out


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
        tappable = bool(re.search(
            r"\b(Button|OutlinedButton|TextButton|FilledTonalButton|ElevatedButton|SegmentedButton)\s*\(",
            body)) or (bool(re.search(r"\b(BasicText|Text)\s*\(", body)) and ".clickable(" in body)
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


def android_actions(text: str, masked: str, strings: dict, consts: dict,
                    stats: dict | None = None, wrappers: frozenset | None = None,
                    positions: list | None = None, fold_labels: frozenset | None = None) -> tuple:
    """(labelled action labels, unresolved expressions)."""
    labels, unresolved = [], []
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
            if "onClick" not in named or "title" not in named:
                continue
            span = named["title"]
        if span is None:
            continue
        value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
        if dynamic:
            unresolved.append(strip_kotlin_comments(collapse(text[span[0]:span[1]]))[:DYN_EXPR_MAX])
        elif value and value.strip():
            labels.append(value)
    # ChatPage has no action component: its affordances are a `BasicText` whose
    # own modifier chain carries `.clickable(...)`. Only that shape counts (a
    # clickable row around a label is not the label's own action).
    for m in SECTION_CALL_RE.finditer(masked):
        if m.group(1) not in ("BasicText", "Text"):
            continue
        open_paren = m.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0 or ".clickable(" not in masked[open_paren:close]:
            continue
        span = None
        for a, b in split_args(masked, open_paren + 1, close):
            nm = re.match(r"\s*([a-z][A-Za-z0-9_]*)\s*=(?!=)", masked[a:b])
            if nm and nm.group(1) == "text":
                span = (a + nm.end(), b)
                break
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
    # `Row(modifier = Modifier.clickable(...)) { BasicText(text = UiStrings.NEW) }`:
    # the label is a child, the tap target is the container. Take the first
    # non-glyph text child; a dynamic first child means the row's name comes from
    # data (a session title), which is not a named action, so it is skipped.
    for m in SECTION_CALL_RE.finditer(masked):
        if m.group(1) not in ("Row", "Column", "Box"):
            continue
        open_paren = m.end() - 1
        close = match_paren(masked, open_paren)
        if close < 0 or ".clickable(" not in masked[open_paren:close]:
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
            c_named, _ = named_args(masked, cop, ccl)
            span = c_named.get("text")
            if span is None:
                continue
            value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
            if value is not None and is_chrome_label(value):
                continue
            if dynamic:
                break
            label = value
            break
        if label and label.strip():
            labels.append(label)
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
    # -- standard Compose controls (the label is visible in the source) --------
    spans = function_spans(masked)
    wrappers = set(wrappers or ()) | button_wrappers(masked, spans)

    def record(value, dynamic, idiom: str, pos: int = 0) -> None:
        if dynamic:
            unresolved.append(strip_kotlin_comments(dynamic)[:DYN_EXPR_MAX])
            if stats is not None:
                stats[idiom + ".unresolved"] = stats.get(idiom + ".unresolved", 0) + 1
        elif value and value.strip():
            labels.append(value)
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
        closure = call["trailing"]
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
            if callee == "DropdownMenuItem" and value is None and dynamic:
                continue  # a data row: DropdownMenuItem(text = { Text(expr) }) is not a named action
            if value is None and dynamic is None and callee in CHIP_CONTROLS:
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
    # `%d 项需要处理` is rendered data, not a fixed action label: templates never
    # participate in missing/extra comparison (section titles keep them — the
    # contract's `titleTemplate` is exactly this shape).
    labels = [label for label in labels if not is_template_label(label)]
    return labels, unresolved


# ---------------------------------------------------------------------------
# Page outline: where a row/header sits, for untitled-group criteria.
# ---------------------------------------------------------------------------


def android_row_positions(text: str, masked: str, strings: dict, consts: dict) -> list:
    """(label, pos) for every visible Text/BasicText, in source order.

    An untitled group is identified by a *row*, which may be a plain text line
    (`Text("还没有可显示的内容")`), not only a clickable action.
    """
    out = []
    for m in SECTION_CALL_RE.finditer(masked):
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
        value, dynamic = resolve_kotlin_expr(text[span[0]:span[1]], strings, consts)
        if not dynamic and value and value.strip() and not is_chrome_label(value):
            out.append((value, m.start()))
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
        for key in ("page", "kind", "name"):
            if key not in entry:
                raise CheckError(f"{path.name}: a baseline entry misses `{key}`")
        if entry["kind"] not in KINDS:
            raise CheckError(f"{path.name}: unknown kind {entry['kind']!r}")
        name = (normalize(entry["name"])
                if entry["kind"].startswith(("missing-", "extra-", "unresolved-")) else entry["name"])
        out.add((entry["page"], entry["kind"], name))
    return out


def baseline_payload(report: Report, contracts: dict) -> dict:
    rows, seen = [], set()
    for page_id, kind, name, _detail in sorted(set(report.findings)):
        key = (page_id, kind, normalize(name)
               if kind.startswith(("missing-", "extra-", "unresolved-")) else name)
        if key in seen:
            continue
        seen.add(key)
        rows.append({
            "page": page_id,
            "kind": kind,
            "name": name,
            "reason": f"known divergence on {page_id} ({kind}); shrink only",
        })
    note = ("Known page-structure divergences between the iOS contract and the Android "
            "screens. This ratchet only shrinks: fix one, delete its row. Regenerate with "
            "--write-baseline only when the change is reviewed as a ratchet move.")
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
               "sections": {"contract": 0, "titled": 0, "android": 0}, "actions": {"contract": 0, "android": 0},
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
    labelled = [a for a in live_actions if a.get("label") and not a.get("dynamicLabel")]
    android_only_actions = [a for a in labelled if a.get("androidOnly")]
    labelled = [a for a in labelled if not a.get("androidOnly")]
    summary["actions"]["contract"] = len(contract_actions)

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
    section_positions, action_positions = [], []
    android_titles, unresolved_titles = android_sections(text, masked, strings, consts,
                                                        positions=section_positions)
    fold_labels = frozenset(normalize(a["label"]) for a in labelled if a.get("label"))
    android_labels, unresolved_labels = android_actions(text, masked, strings, consts,
                                                        wrappers=wrappers, positions=action_positions,
                                                        fold_labels=fold_labels)
    android_labels = [label for label in android_labels if not is_chrome_label(label)]
    summary["sections"]["android"] = len(android_titles)
    summary["actions"]["android"] = len(android_labels)
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
        for key, title in expected_titles.items():
            if key not in actual_titles:
                report.add(page_id, "missing-section", title,
                           "contract section title absent from the Android page")
        for key, title in actual_titles.items():
            if key not in expected_titles and key not in android_only_titles \
                    and key not in subpage_titles:
                report.add(page_id, "extra-section", title, "Android section title absent from the contract")
        for expr in sorted(set(unresolved_titles)):
            report.add(page_id, "unresolved-section", expr,
                       "section title is an expression, so it cannot be compared to the contract")
    elif section_model == "single-region":
        pass  # manual judgement recorded in the contract; the note is printed below
    elif section_model == "unmodeled":
        report.add(page_id, "unresolved-section", "<manual region>",
                   "the baseline groups this page without Section/PageSection/GroupBox/header Text; "
                   "a human must name the group before the sections can be compared")

    expected_labels = {normalize(a["label"]): a["label"] for a in labelled}
    actual_labels = {normalize(l): l for l in android_labels}
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
    for key, label in expected_labels.items():
        if key not in actual_labels:
            report.add(page_id, "missing-action", label, "contract action label absent from the Android page")
    for key, label in actual_labels.items():
        if key not in expected_labels and key not in android_only_label_keys \
                and key not in dead_action_keys:
            report.add(page_id, "extra-action", label, "Android action label absent from the contract")
    for expr in sorted(set(unresolved_labels)):
        report.add(page_id, "unresolved-action", expr,
                   "action label is an expression, so it cannot be compared to the contract")

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

    # Rule 2: the Android page exists and declares the mapped screen, and its
    # section titles / action labels are the contract's.
    summaries = [compare(root, contract, report, strings, shared_consts, wrappers)
                 for contract in contracts.values()]

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
        findings = [f for f in report.findings if f[0] == summary["page"]]
        page_new = [f for f in new_findings if f[0] == summary["page"]]
        print(f"PAGE {summary['page']}  {summary['screen']} → {Path(summary['android']).name}"
              if summary["android"] else f"PAGE {summary['page']}  {summary['screen']} → (no Android screen)")
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
        print(f"  actions   contract {summary['actions']['contract']} labelled   "
              f"android {summary['actions']['android']}   "
              f"divergences {len([f for f in findings if f[1].endswith('action')])}")
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
    print(f"{'page':<24} {'sections -/+':>14} {'actions -/+':>14} {'unresolved':>11}")
    for summary in summaries:
        page_id = summary["page"]
        findings = [f for f in report.findings if f[0] == page_id]
        ms = len([f for f in findings if f[1] == "missing-section"])
        xs = len([f for f in findings if f[1] == "extra-section"])
        ma = len([f for f in findings if f[1] == "missing-action"])
        xa = len([f for f in findings if f[1] == "extra-action"])
        un = len([f for f in findings if f[1].startswith("unresolved")])
        flag = "" if not findings else ("  <- new" if baseline_path is not None and any(
            f in new_findings for f in findings) else "")
        print(f"{page_id:<24} {f'{ms}/{xs}':>14} {f'{ma}/{xa}':>14} {un:>11}{flag}")

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
        payload = baseline_payload(report, contracts)
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
