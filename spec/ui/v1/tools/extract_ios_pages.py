#!/usr/bin/env python3
"""Extract a machine-readable page structure from the iOS baseline.

Purpose: `spec/ui/v1/README.md` §1 gives each page one line of prose, so the two
platforms agreed on page *names* and never on page *structure*. This tool reads the
SwiftUI sources of the iOS baseline (`examples/probe-app/PhoneDSHProbe/*Page.swift`,
read-only) and writes one contract per page to `spec/ui/v1/pages/<page-id>.json`:

  sections  ordered list of groups: a SwiftUI `Section`, or — on the pages that
            group with `PageSection`/`GroupBox`/a bold header `Text` — a `region` of
            the same shape: title / title template / visibility condition / owning
            collection, plus the rows inside each one;
  rows      label or label expression, value source, clickability, destination;
  actions   every interactive affordance (buttons, navigation links, menus, pickers,
            toggles, search, toolbar, gestures, alert buttons) with its trigger,
            whether it can write, and `presents` — the sheet/alert/destination it
            opens, linked through the state binding the action assigns;
  states    what the page renders when empty / loading / failing / unknown / with data.
            Advisory only (`"advisory": true`): marker-based, it cannot tell a row's
            placeholder from a page state, so the checker never compares it;
  provenance `File.swift:line` plus a one-line `anchor` that must still be on that
            line, so a checker can tell a moved source from a stale contract.

The scan is syntactic: a comment masker plus a brace/paren matcher over the Swift
text, not a Swift parser and not a guess. Three consequences, all deliberate:

* a page that renders `body { mainGroup; toolsGroup; aboutGroup }` is scanned in
  that reference order; a view member `body` never references is reported under
  `unreachable` instead of being counted as a section on screen;
* a row whose visible label only exists as an expression
  (`displaySessionTitle(session)`) is emitted with `label: null`,
  `labelExpr: "..."` and `"extraction": "manual"` — the item is real, its wording
  is not machine-derivable;
* `extraction.coverage` is `sectionsExtracted / Section keywords in the page
  struct`, and `extraction.warnings` records control flow the scanner will not
  flatten. A gap is visible instead of silent.

Usage:
    python3 spec/ui/v1/tools/extract_ios_pages.py [--root DIR] [--page NAME]
    python3 spec/ui/v1/tools/extract_ios_pages.py --check   # fail when stale

Exit code 0 on success, 1 when --check finds a stale contract, 2 on usage/I-O error.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

UI_REL = Path("spec") / "ui" / "v1"
PAGES_REL = UI_REL / "pages"
PROBE_REL = Path("examples") / "probe-app" / "PhoneDSHProbe"
ANDROID_PAGE_REL = Path("android") / "lib" / "src" / "main" / "kotlin" / "com" / "phonedsh" / "ui" / "page"
SCHEMA = "pdsh.ui.page-structure/1"

#: Swift page name -> Android composable name where the two deliberately differ.
ANDROID_ALIASES = {"SettingsAboutPage": "AboutPage"}

#: Page structs that stay embedded in their parent (README §1): no contract of their
#: own unless an Android screen file exists for them.
EMBEDDED_HINTS = ("SessionQueuePage", "PermissionDefaultsPage", "LicensesPage",
                  "DevelopmentToolsPage", "DeveloperPage", "FilePreviewPage",
                  "ScheduleDetailPage", "ScheduleHistoryPage", "ScheduleEditorPage",
                  "ModelProviderEditorPage", "CommandExecutionResultPage")
TOOL = "extract_ios_pages.py"

STRUCT_RE = re.compile(
    r"^[ \t]*(?:public |internal |fileprivate |private |final )*struct[ \t]+(\w+)[ \t]*:"
    r"[ \t]*[^{]*(?:\bView\b|UIViewRepresentable|UIViewControllerRepresentable)[ \t]*\{",
    re.M,
)
PAGE_FILE_RE = re.compile(r"^(\w+Page)\.swift$")
MEMBER_RE = re.compile(r"\b(var|func)[ \t]+(\w+)")
SECTION_RE = re.compile(r"\bSection[ \t]*([({])")
IF_RE = re.compile(r"\bif[ \t]+")
FOREACH_RE = re.compile(r"\bForEach[ \t]*\(")
IDENT_RE = re.compile(r"\b([A-Za-z_]\w*)\b")
SYMBOL_LITERAL_RE = re.compile(r"^[a-z][a-z0-9._-]*$")

#: Literals that separate things on screen (they are not a row's name).
PUNCTUATION_ONLY = frozenset({"·", "—", "…", "-", ".", "/", "|", ":", "，", "、", "(", ")"})
#: A destination is a capitalised call that starts a word: `.presentationDetents(`
#: must not be read as a destination called "Detents".
NAV_CALL_RE = re.compile(r"(?<![A-Za-z_.])([A-Z]\w*)\s*\(")
WRITE_RE = re.compile(
    r"(^|[^=!<>])=(?!=)|\bawait\b|\bTask\s*\{|\bonChange\b|\$[A-Za-z_]\w*|"
    r"\b(?:set|toggle|create|rename|delete|archive|save|run|cancel)\w*\s*\("
)

#: Literal markers per page state. A state site is a *string literal* or a known
#: view, never an identifier: `userFacingError` is code, not a rendered state.
STATE_MARKERS = {
    "empty": re.compile(r"还没有|没有(?!更多)|未配置|暂无|空态|没有在排队|没有已归档"),
    "loading": re.compile(r"正在|读取中|加载中|等待|排队中"),
    "failure": re.compile(r"失败|错误|重试|读不到|无法读取|无法|出错"),
    "unknown": re.compile(r"未知|未测|未设置|未链接|—"),
}
STATE_KINDS = ("empty", "data", "failure", "unknown", "loading")

#: Helpers that are containers, not rows: the row is their first argument.
CONTAINER_HINTS = ("settingsRow",)

#: Non-`Section` group wrappers in the baseline: a titled card is a region.
REGION_CALLS = ("PageSection", "GroupBox")
HEADER_FONT_RE = re.compile(
    r"\.font\((?:[^)]*weight:\s*\.(?:semibold|bold)|\.headline|\.title2|\.title3|\.subheadline)")
UPPERCASE_RE = re.compile(r"\.textCase\(\.uppercase\)")

#: Pages whose body is one flat list with no visual grouping. This is a *manual*
#: judgement recorded after reading each `body`, not an extraction guess: the checker
#: skips section comparison for them and prints the note, instead of inventing a
#: criterion or silently skipping a page.
SINGLE_REGION_PAGES = {
    "WorkspaceFoldersPage": "flat List: one NavigationLink per workspace + one empty-state block; no group header",
    "SettingsAboutPage": "flat List: one version row + one sentence; no group header",
    "NativeWorkbenchPage": "NavigationStack/VStack: a segmented mode switch over two embedded pages; no group header",
}

#: How a Button's surrounding syntax names its trigger.
BUTTON_TRIGGERS = (
    (r"\.contextMenu[ \t]*\{", "long-press"),
    (r"\.toolbar[ \t]*\{", "toolbar"),
    (r"\.swipeActions[ \t]*\([^)]*\)[ \t]*\{", "swipe"),
    (r"\.alert[ \t]*\(", "alert-button"),
    (r"\.confirmationDialog[ \t]*\(", "dialog-button"),
    (r"\bMenu[ \t]*\{", "menu-item"),
)


class ExtractError(Exception):
    """A structural problem the extractor will not paper over."""


# ---------------------------------------------------------------------------
# Lexing helpers: comments masked, strings kept verbatim, indices preserved.
# ---------------------------------------------------------------------------


def mask_comments(text: str) -> str:
    """Structural mask: comments and string-literal bodies become spaces.

    Everything that matches braces, parentheses, commas or identifiers runs on
    this mask, so a `,` or `(` inside a user-visible string can never split an
    argument list (the labels themselves are read from the original text by
    `Source.literals`). Newlines and indices are preserved.
    """
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
        elif text[i] == '"':
            triple = text.startswith('"""', i)
            quote = '"""' if triple else '"'
            start = i
            j = i + len(quote)
            while j < n:
                if triple:
                    if text.startswith('"""', j):
                        j += 3
                        break
                    j += 1
                elif text[j] == "\\":
                    j += 2
                elif text[j] == '"':
                    j += 1
                    break
                else:
                    j += 1
            for k in range(start, min(j, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def match_delim(masked: str, open_pos: int, opener: str = "{", closer: str = "}") -> int:
    """Index of the closer matching `open_pos`, or -1."""
    depth = 0
    for i in range(open_pos, len(masked)):
        c = masked[i]
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return i
    return -1


def unescape(raw: str) -> str:
    return raw.replace('\\"', '"').replace("\\n", "\n")


def human_title(raw: str) -> str:
    """`Rows (\\(model.probeRows.count))` / `{report.itemCount} 条内容` -> the shown text.

    Rendered form replaces every interpolation or template slot with `N`
    (`Rows (N)`, `N 条内容`); the exact template stays in `titleTemplate`.
    """
    out = re.sub(r"\\\([^()]*(?:\([^()]*\)[^()]*)*\)", "N", raw)
    out = re.sub(r"\{[^{}]*\}", "N", out)
    return out.strip()


def template_of(raw: str) -> str:
    """`\\(count) 个会话` -> `{count} 个会话`; `%d` -> `{n}`."""
    out = re.sub(r"\\\(([^()]*(?:\([^()]*\)[^()]*)*)\)", lambda m: "{" + m.group(1).strip() + "}", raw)
    return re.sub(r"%(\d+\$)?d", "{n}", out).strip()


class Source:
    """One Swift file with line lookups and the constructs the extractor needs."""

    def __init__(self, path: Path, root: Path) -> None:
        self.path = path
        self.rel = str(path.relative_to(root))
        self.text = path.read_text(encoding="utf-8")
        self.masked = mask_comments(self.text)
        self._line_starts = [0]
        for m in re.finditer("\n", self.text):
            self._line_starts.append(m.end())

    def line_of(self, pos: int) -> int:
        lo, hi = 0, len(self._line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self._line_starts[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def line_text(self, line: int) -> str:
        start = self._line_starts[line - 1]
        end = self.text.find("\n", start)
        return self.text[start:] if end < 0 else self.text[start:end]

    def provenance(self, pos: int) -> tuple:
        """`File.swift:line` plus the trimmed line, used as a staleness anchor."""
        line = self.line_of(pos)
        return f"{self.path.name}:{line}", self.line_text(line).strip()[:80]

    def literals(self, start: int, end: int) -> list:
        """String literals in [start,end) as (raw_with_interpolation, pos)."""
        found = []
        i, end = start, min(end, len(self.text))
        while i < end:
            if self.text[i] != '"':
                i += 1
                continue
            triple = self.text.startswith('"""', i)
            quote = '"""' if triple else '"'
            j = i + len(quote)
            while j < end:
                if triple:
                    if self.text.startswith('"""', j):
                        j += 3
                        break
                    j += 1
                elif self.text[j] == "\\":
                    j += 2
                elif self.text[j] == '"':
                    j += 1
                    break
                else:
                    j += 1
            found.append((self.text[i + len(quote): j - len(quote)], i))
            i = j
        return found

    def statement_lines(self, start: int, end: int) -> str:
        """Collapse a source span to one readable line (the contract is JSON)."""
        return re.sub(r"\s+", " ", self.text[start:end]).strip()


def normalise_label(value: str) -> tuple:
    """(label, dynamic): `\(count) 个会话` becomes `{count} 个会话`, dynamic=True."""
    if "\\(" in value:
        return template_of(value), True
    return value, False


def first_label(source: Source, start: int, end: int) -> tuple:
    """First string literal that can be a user-visible label, with its position.

    SF Symbol names are image identifiers, not copy: a lowercase dotted or
    underscored literal, or one that follows `systemImage:`, is never a label.
    """
    for raw, pos in source.literals(start, end):
        value = unescape(raw)
        if not value.strip():
            continue
        prefix = source.text[max(0, pos - 40): pos]
        if SYMBOL_LITERAL_RE.match(value) and ("systemImage" in prefix or "." in value or "_" in value):
            continue
        return value, pos
    return None, None


# ---------------------------------------------------------------------------
# Page struct, members and what `body` actually renders.
# ---------------------------------------------------------------------------


def find_page_struct(source: Source, page_name: str) -> tuple:
    for m in STRUCT_RE.finditer(source.masked):
        if m.group(1) == page_name:
            body_start = m.end() - 1
            body_end = match_delim(source.masked, body_start)
            if body_end < 0:
                raise ExtractError(f"{source.path.name}: unbalanced braces in {page_name}")
            return m.start(), body_start, body_end
    raise ExtractError(f"{source.path.name}: no `struct {page_name}: View`")


def page_structs(source: Source) -> list:
    """Every `*Page` struct declared in the file (the page plus its subpages)."""
    out = []
    for m in STRUCT_RE.finditer(source.masked):
        name = m.group(1)
        if not name.endswith("Page"):
            continue
        body_start = m.end() - 1
        body_end = match_delim(source.masked, body_start)
        decl_line_start = source.masked.rfind("\n", 0, m.start()) + 1
        decl = source.text[decl_line_start: m.end()]
        out.append({
            "name": name,
            "line": source.line_of(m.start()),
            "private": bool(re.search(r"\bprivate\b|\bfileprivate\b", decl)),
            "body_start": body_start,
            "body_end": body_end,
        })
    return out


def view_structs(source: Source) -> list:
    """Every `struct X: View` in the file (pages, subpages and plain view structs)."""
    out = []
    for m in STRUCT_RE.finditer(source.masked):
        name = m.group(1)
        body_start = m.end() - 1
        body_end = match_delim(source.masked, body_start)
        decl_start = source.masked.rfind("\n", 0, m.start()) + 1
        decl = source.text[decl_start: m.end()]
        out.append({"name": name, "line": source.line_of(m.start()),
                    "private": bool(re.search(r"\bprivate\b|\bfileprivate\b", decl)),
                    "body_start": body_start, "body_end": body_end})
    return out


def members_of(source: Source, start: int, end: int) -> dict:
    """Top-level `var`/`func` blocks inside [start,end), keyed by name."""
    masked = source.masked
    members = {}
    i = start
    while i < end:
        if masked[i] != "{":
            i += 1
            continue
        segment_start = max(start, masked.rfind("}", start, i) + 1)
        # The block belongs to the *last* declaration before it, not the first:
        # `var host = ...` followed by `var body: some View {` must not hand the
        # body block (and its Sections) to `host`.
        decls = list(MEMBER_RE.finditer(masked[segment_start:i]))
        decl = decls[-1] if decls else None
        block_end = match_delim(masked, i)
        if block_end < 0:
            raise ExtractError(f"{source.path.name}: unbalanced braces at line {source.line_of(i)}")
        if decl:
            kind, name = decl.group(1), decl.group(2)
            head = source.text[segment_start + decl.start():i]
            param_text = ""
            if kind == "func":
                open_paren = masked.find("(", decl.end(), i)
                close_paren = match_delim(masked, open_paren, "(", ")") if open_paren >= 0 else -1
                if close_paren > 0:
                    param_text = source.text[open_paren + 1: close_paren]
            members.setdefault(name, {
                "kind": kind,
                "name": name,
                "head": head.strip(),
                "body_start": i,
                "body_end": block_end,
                "is_view": "some View" in head or "@ViewBuilder" in head,
                "params": param_text,
                "line": source.line_of(segment_start + decl.start()),
            })
        i = block_end + 1
    return members


def rendered_order(source: Source, members: dict) -> tuple:
    """View members reachable from `body`, in reference order, plus the unreached.

    The rendered order is the reference order (`body` -> mainGroup -> toolsGroup),
    not the declaration order. A view member with Sections that nothing references
    is dead code in the baseline; counting it as a rendered section is how a grep
    turns 3 sections into 27.
    """
    if "body" not in members:
        raise ExtractError(f"{source.path.name}: page struct has no `body`")
    order, seen = [], {"body"}

    def walk(name: str, depth: int) -> None:
        if depth > 8:
            return
        member = members[name]
        span = source.masked[member["body_start"]: member["body_end"]]
        for m in IDENT_RE.finditer(span):
            ref = m.group(1)
            if ref in seen or ref not in members:
                continue
            seen.add(ref)
            order.append(ref)
            walk(ref, depth + 1)

    walk("body", 0)
    return order, seen


def if_scopes(source: Source, start: int, end: int) -> list:
    """Every `if` body inside [start,end): (span_start, body_start, body_end, condition)."""
    masked = source.masked
    scopes = []
    for m in IF_RE.finditer(masked, start, end):
        brace = masked.find("{", m.end())
        if brace < 0 or brace >= end:
            continue
        close = match_delim(masked, brace)
        if close < 0:
            continue
        scopes.append((m.start(), brace, close, source.statement_lines(m.end(), brace)))
    return scopes


def innermost_condition(scopes: list, pos: int):
    best = None
    for _span_start, body_start, body_end, condition in scopes:
        if body_start < pos < body_end and (best is None or body_start > best[0]):
            best = (body_start, condition)
    return best[1] if best else None


def for_each_scopes(source: Source, start: int, end: int) -> list:
    """`ForEach(<collection>) { ... }`: (span_start, body_start, body_end, collection)."""
    masked = source.masked
    out = []
    for m in FOREACH_RE.finditer(masked, start, end):
        open_paren = m.end() - 1
        close_paren = match_delim(masked, open_paren, "(", ")")
        if close_paren < 0:
            continue
        brace = masked.find("{", close_paren)
        if brace < 0 or brace >= end:
            continue
        close = match_delim(masked, brace)
        if close < 0:
            continue
        out.append((m.start(), brace, close, source.statement_lines(open_paren + 1, close_paren)))
    return out


def enclosing_for_each(scopes: list, pos: int):
    best = None
    for _span_start, body_start, body_end, collection in scopes:
        if body_start < pos < body_end and (best is None or body_start > best[0]):
            best = (body_start, collection)
    return best[1] if best else None


def strip_closure_params(masked: str, start: int, end: int) -> int:
    """`{ item in ... }` -> the position after `item in` (a ForEach row body)."""
    m = re.match(r"[ \t]*[A-Za-z_]\w*(?:[ \t]*,[ \t]*[A-Za-z_]\w*)*[ \t]+in\b", masked[start:end])
    return start + m.end() if m else start


def split_statements(masked: str, start: int, end: int) -> list:
    """Direct children of a closure body as (start, end) spans.

    Depth-0 newlines split statements, except before a leading `.` (a modifier
    chain continues) or after an operator/comma (an expression continues).
    """
    statements = []
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
                head = masked[s:j].rstrip()
                if head.endswith((",", "=", "+", "&&", "||", ":", "?", "??")):
                    j += 1
                    continue
                break
            j += 1
        if j <= s:
            j = s + 1
        statements.append((s, j))
        i = j
    return statements


def _call_parts_closure_first(source: Source, start: int, end: int) -> dict:
    masked = source.masked
    m = re.match(r"[ \t]*([A-Za-z_][\w.]*)[ \t]*(?=\{)", masked[start:end])
    if not m:
        return {}
    callee = m.group(1)
    brace = start + m.end()
    close = match_delim(masked, brace)
    if close < 0:
        return {}
    named, trailing = {}, (brace, close)
    k = close + 1
    while k < end:
        while k < end and masked[k] in " \t\r\n":
            k += 1
        nm = re.match(r"([A-Za-z_]\w*)[ \t]*:[ \t]*(?=\{)", masked[k:end])
        if not nm:
            break
        ob = k + nm.end()
        oc = match_delim(masked, ob)
        if oc < 0:
            break
        named[nm.group(1)] = (ob + 1, oc)
        k = oc + 1
    return {"callee": callee, "args_start": brace + 1, "args_end": close,
            "positional": [], "named": named, "trailing": trailing, "end": close + 1}


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
    # No emptiness filter: a string argument masks to spaces, and it is still an
    # argument (the label is read from the original text at these indices).
    return spans


def call_parts(source: Source, start: int, end: int) -> dict:
    """Callee, arguments and closures of a statement, or {}.

    Two SwiftUI call shapes exist and both are parsed here:
    `Callee(a, b: c) { ... }` and `Callee { ... } label: { ... }` (the trailing
    closure first, which is how `Button`/`Menu`/`NavigationLink` are written when
    the label is a view rather than a string).
    """
    masked = source.masked
    m = re.match(r"[ \t]*([A-Za-z_][\w.]*)[ \t]*\(", masked[start:end])
    if not m:
        return _call_parts_closure_first(source, start, end)
    callee = m.group(1)
    open_paren = start + m.end() - 1
    close_paren = match_delim(masked, open_paren, "(", ")")
    if close_paren < 0:
        return {}
    positional, named = [], {}
    for a, b in split_args(masked, open_paren + 1, close_paren):
        nm = re.match(r"([A-Za-z_]\w*)[ \t]*:", masked[a:b])
        if nm:
            named[nm.group(1)] = (a + nm.end(), b)
        else:
            positional.append((a, b))
    trailing = None
    k = close_paren + 1
    while k < end and masked[k] in " \t\r\n":
        k += 1
    if k < end and masked[k] == "{":
        close = match_delim(masked, k)
        if close > 0:
            trailing = (k, close)
            k = close + 1
            # `Button(role: .destructive) { act } label: { Text("…") }`: the label is
            # a second trailing closure and must not be lost.
            while k < end:
                while k < end and masked[k] in " \t\r\n":
                    k += 1
                nm = re.match(r"([A-Za-z_]\w*)\s*:\s*(?=\{)", masked[k:end])
                if not nm:
                    break
                ob = k + nm.end()
                oc = match_delim(masked, ob)
                if oc < 0:
                    break
                named[nm.group(1)] = (ob + 1, oc)
                k = oc + 1
    return {"callee": callee, "args_start": open_paren + 1, "args_end": close_paren,
            "positional": positional, "named": named, "trailing": trailing, "end": close_paren + 1}


# ---------------------------------------------------------------------------
# Rows and actions.
# ---------------------------------------------------------------------------


def slug(text: str) -> str:
    out = re.sub(r"[^0-9A-Za-z\u4e00-\u9fff]+", "-", text).strip("-").lower()
    return out or "item"


def row_of(source: Source, pos: int, label, label_pos, kind: str, **extra) -> dict:
    prov, anchor = source.provenance(label_pos if label_pos is not None else pos)
    label, dynamic = normalise_label(label) if label else (label, False)
    if dynamic:
        extra.setdefault("dynamicLabel", True)
        extra.setdefault("extraction", "manual")
    row = {
        "id": slug(label) if label else f"{kind}-{source.line_of(pos)}",
        "label": label,
        "labelExpr": extra.pop("label_expr", None),
        "kind": kind,
        "value": extra.pop("value", None),
        "valueExpr": extra.pop("value_expr", None),
        "clickable": extra.pop("clickable", False),
        "destination": extra.pop("destination", None),
        "writes": extra.pop("writes", False),
        "condition": extra.pop("condition", None),
        "provenance": prov,
        "anchor": anchor,
        "extraction": extra.pop("extraction", "syntax" if label else "manual"),
    }
    row.update(extra)
    return row


def action_of(source: Source, pos: int, label, label_pos, kind: str, trigger: str, **extra) -> dict:
    prov, anchor = source.provenance(label_pos if label_pos is not None else pos)
    label, dynamic = normalise_label(label) if label else (label, False)
    if dynamic:
        extra.setdefault("dynamicLabel", True)
        extra.setdefault("extraction", "manual")
    action = {
        "id": slug(label) if label else f"{kind}-{source.line_of(pos)}",
        "label": label,
        "labelExpr": extra.pop("label_expr", None),
        "kind": kind,
        "trigger": trigger,
        "semantic": extra.pop("semantic", None),
        "writes": extra.pop("writes", False),
        "destination": extra.pop("destination", None),
        "condition": extra.pop("condition", None),
        "provenance": prov,
        "anchor": anchor,
        "extraction": extra.pop("extraction", "syntax" if label else "manual"),
    }
    action.update(extra)
    return action


def writes(source: Source, start: int, end: int) -> bool:
    return bool(WRITE_RE.search(source.text[start:end]))


def destination_of(source: Source, span) -> str:
    """The page a sheet/navigation closure shows: first `*Page`, else the first capital call."""
    if not span:
        return None
    text = source.statement_lines(span[0] + 1, span[1])
    names = re.findall(r"(?<![A-Za-z_.])([A-Z]\w*)\s*[({]", text)
    pages = [name for name in names if name.endswith("Page")]
    if pages:
        return pages[0]
    return names[0] if names else (text[:80] or None)


class PageExtractor:
    def __init__(self, source: Source, page_name: str, depth: int = 0) -> None:
        self.source = source
        self.name = page_name
        self.depth = depth
        self.warnings = []
        self.struct_start, self.body_start, self.body_end = find_page_struct(source, page_name)
        self.members = members_of(source, self.body_start + 1, self.body_end)
        self.has_body = "body" in self.members
        if self.has_body:
            self.ref_order, self.reachable = rendered_order(source, self.members)
        else:
            self.ref_order, self.reachable = [], set()
            self.warnings.append(
                "no SwiftUI `body`: the page is a UIKit representable, so it owns no "
                "Section/row tree; states and provenance still apply")
        self.view_order = ["body"] + [n for n in self.ref_order if self.members[n]["is_view"]]
        # Helpers `body` never reaches are dead code in the baseline; they must not
        # contribute sections, rows or actions (SettingsPage carries nine of them).
        self.dead_spans = [
            (m["body_start"], m["body_end"])
            for name, m in self.members.items()
            if name != "body" and name not in self.reachable
        ]
        # A `private struct XxxPage` nested inside the page is an embedded subpage
        # (SettingsPage nests PermissionDefaultsPage/LicensesPage): its Sections
        # belong to that subpage, not to the parent's contract.
        self.subpage_spans = [
            (st["body_start"], st["body_end"])
            for st in page_structs(source)
            if st["name"] != self.name and self.body_start < st["body_start"] < self.body_end
        ]
        self.dead_spans.extend(self.subpage_spans)
        self.sections = []
        self.actions = []
        self._action_keys = set()
        self.presentations = []
        self.if_scopes = if_scopes(source, self.body_start, self.body_end)
        self.for_each_scopes = for_each_scopes(source, self.body_start, self.body_end)
        live = [m.start() for m in SECTION_RE.finditer(source.masked, self.body_start, self.body_end)
                if self._live(m.start())]
        self.section_total = len(live)
        self.region_total = 0

    # -- driver ------------------------------------------------------------

    def run(self, structs: list) -> dict:
        if self.has_body:
            seen = []
            for m in SECTION_RE.finditer(self.source.masked, self.body_start, self.body_end):
                kw_pos = m.start()
                if not self._live(kw_pos):
                    continue
                if any(inner[0] < kw_pos < inner[1] for inner in seen):
                    continue  # nested Section: the outer one owns the rows
                section = self._section(m)
                if section is None:
                    continue
                seen.append((kw_pos, section.pop("_content_end")))
                self.sections.append(section)
            self._scan_page_actions()
            if not self.sections:
                if self.name in SINGLE_REGION_PAGES:
                    self.sections = [self._single_region()]
                else:
                    self._scan_regions()
            self._link_presentations()
            if self.depth == 0:
                self._inline_presented_actions()
        return {
            "schema": SCHEMA,
            "page": self.name,
            "pageId": page_id(self.name),
            "structure": "swiftui-view" if self.has_body else "ui-representable",
            "sectionModel": self._section_model(),
            "sectionNote": SINGLE_REGION_PAGES.get(self.name),
            "title": self._page_title(),
            "source": {
                "file": self.source.path.name,
                "path": self.source.rel,
                "lines": len(self.source.text.splitlines()),
                "structLine": self.source.line_of(self.struct_start),
                "renderedFrom": self.view_order,
                "sectionOrder": "declaration order inside the page struct",
            },
            "android": {"screen": self.name, "file": None, "match": "missing"},
            "sections": self.sections,
            "actions": self.actions,
            "presentations": self.presentations,
            "states": self._states(),
            "subpages": [
                {"name": st["name"], "line": st["line"], "private": st["private"],
                 "sections": self._section_titles_in(st["body_start"], st["body_end"]),
                 "provenance": f"{self.source.path.name}:{st['line']}"}
                for st in structs if st["name"] != self.name
            ],
            "unreachable": self._unreachable(),
            "extraction": {
                "tool": TOOL,
                "mode": "syntax",
                "sectionKeywordsInPage": self.section_total,
                "regionsExtracted": self.region_total,
                "sectionsExtracted": len(self.sections),
                "warnings": self.warnings,
            },
        }

    def _live(self, pos: int) -> bool:
        if not (self.body_start <= pos <= self.body_end):
            return False
        return not any(a < pos < b for a, b in self.dead_spans)

    # -- sections ----------------------------------------------------------

    def _section(self, match) -> dict:
        source = self.source
        masked = source.masked
        kw_pos = match.start()
        close_paren = -1
        if match.group(1) == "(":
            close_paren = match_delim(masked, match.end() - 1, "(", ")")
            if close_paren < 0:
                return None
            brace = masked.find("{", close_paren)
            if brace < 0:
                return None
            content = (brace, match_delim(masked, brace))
        else:
            content = (match.end() - 1, match_delim(masked, match.end() - 1))
        if content[1] < 0:
            return None

        title = title_pos = None
        title_source = "absent"
        title_template = None
        dynamic_title = False
        title_expression = None
        if match.group(1) == "(":
            label, pos = first_label(source, match.end(), close_paren)
            if label:
                if "\\(" in label:
                    title, title_template = human_title(label), template_of(label)
                    dynamic_title = True
                else:
                    title = label
                title_pos, title_source = pos, "literal"
            else:
                expr = source.statement_lines(match.end(), close_paren)
                if expr and not expr.startswith(("header:", "footer:")):
                    # The title *is* data (a folder name), not a fixed template: model it
                    # as `title: null` + criterion, with the expression kept for humans.
                    title_expression = expr
                    title_pos, title_source = match.end(), "expression"
        named_closures = self._named_closures_after(content[1])
        header = named_closures.get("header")
        footer = named_closures.get("footer")
        if header and title is None:
            label, pos = self._first_labeled_text(header)
            if label:
                if "\\(" in label:
                    title, title_template = human_title(label), template_of(label)
                    dynamic_title = True
                else:
                    title = label
                title_pos, title_source = pos, "header"
        if title is None and title_template is None:
            raw, pos = self._template_literal(content)
            if raw:
                title, title_template = human_title(raw), raw
                dynamic_title = True
                title_pos, title_source = pos, "template"

        section = {
            "id": slug(title) if title else (slug(title_template) if title_template else f"section-{source.line_of(kw_pos)}"),
            "title": title,
            "titleTemplate": title_template,
            "dynamicTitle": dynamic_title and bool(title_template),
            "titleExpression": title_expression,
            "titleSource": title_source,
            "condition": innermost_condition(self.if_scopes, kw_pos),
            "collection": enclosing_for_each(self.for_each_scopes, kw_pos),
            "rows": self._rows(content),
            "provenance": None,
            "anchor": None,
            "extraction": "syntax",
            "_content_end": content[1],
        }
        prov, anchor = source.provenance(title_pos if title_pos is not None else kw_pos)
        section["provenance"], section["anchor"] = prov, anchor
        if (header and title is None and title_template is None and title_pos is None
                and self._header_has_dynamic_text(header)):
            section["suppressed"] = True
            section["suppressReason"] = (
                "the header renders a runtime value (no literal title); a dynamic menu/list "
                "header is not a group the implementation can be judged on, and forcing it "
                "into a disabled menu item would be the gate dictating the UI")
        if header and title_pos is not None and self._header_is_ternary(header, title_pos):
            section["suppressed"] = True
            section["suppressReason"] = (
                "the header renders a ternary; its literals are alternatives or comparison "
                "operands (not a single rendered title), and this group's rows are already "
                "extracted as actions")
        if (section["title"] is None and section["titleTemplate"] is None
                and not section.get("suppressed")):
            section["criterion"] = self._untitled_criterion(section["rows"], prov)
        if header:
            section["hasHeader"] = True
        if footer:
            section["footer"] = self._footer_text(footer)
        return section

    def _first_labeled_text(self, closure: tuple) -> tuple:
        """First literal inside a header/footer closure, skipping symbol names."""
        for s, e in split_statements(self.source.masked, closure[0] + 1, closure[1]):
            for raw, pos in self.source.literals(s, e):
                value = unescape(raw)
                if not value.strip() or value.strip() in PUNCTUATION_ONLY:
                    continue
                prefix = self.source.text[max(0, pos - 40): pos]
                if SYMBOL_LITERAL_RE.match(value) and (
                        "systemName" in prefix or "systemImage" in prefix or "." in value or "_" in value):
                    continue
                return value, pos
        return None, None

    def _header_has_dynamic_text(self, header: tuple) -> bool:
        """Does the header render a `Text(<expression>)` (no literal)? Then it is dynamic."""
        masked = self.source.masked
        for match in re.finditer(r"\bText[ \t]*\(", masked[header[0]: header[1]]):
            open_paren = header[0] + match.end() - 1
            close = match_delim(masked, open_paren, "(", ")")
            if close < 0:
                continue
            literal, _pos = first_label(self.source, open_paren + 1, close)
            if literal is None:
                return True
        return False

    def _header_is_ternary(self, header: tuple, title_pos: int) -> bool:
        """Is the *title literal's own* Text a ternary? (A ternary elsewhere is fine.)

        `Text(cond ? "A" : "B")` has no single rendered title; `Text("已归档")` next to
        `Image(systemName: showArchived ? "down" : "right")` does.
        """
        masked = self.source.masked
        for match in re.finditer(r"\bText[ \t]*\(", masked[header[0]: header[1]]):
            open_paren = header[0] + match.end() - 1
            close = match_delim(masked, open_paren, "(", ")")
            if close < 0 or not (open_paren < title_pos < close):
                continue
            span = self.source.text[open_paren: close]
            return " ? " in span and " : " in span
        return False

    def _named_closures_after(self, pos: int) -> dict:
        """`header: { ... }` then `footer: { ... }` after a Section's content closure."""
        masked = self.source.masked
        found, k = {}, pos + 1
        while True:
            m = re.match(r"\s*(\w+)\s*:\s*\{", masked[k: k + 200])
            if not m:
                break
            brace = k + m.end() - 1
            close = match_delim(masked, brace)
            if close < 0:
                break
            if m.group(1) in ("header", "footer"):
                found[m.group(1)] = (brace, close)
            k = close + 1
        return found

    def _template_literal(self, content: tuple) -> tuple:
        """A headerless section still names its shape: `\\(count) 个会话`."""
        for raw, pos in self.source.literals(content[0] + 1, content[1]):
            if "\\(" in raw and re.search(r"个|条|次|项", raw):
                return template_of(raw), pos
        return None, None

    def _footer_text(self, footer: tuple) -> dict:
        source = self.source
        for m in re.finditer(r"\bText[ \t]*\(", source.masked[footer[0]: footer[1]]):
            start = footer[0] + m.start()
            open_paren = source.masked.find("(", start)
            close = match_delim(source.masked, open_paren, "(", ")")
            if close < 0:
                continue
            label, pos = first_label(source, open_paren + 1, close)
            if label is not None:
                prov, anchor = source.provenance(pos)
                return {"text": label, "labelExpr": None, "provenance": prov, "anchor": anchor}
            prov, anchor = source.provenance(start)
            return {"text": None, "labelExpr": source.statement_lines(open_paren + 1, close),
                    "provenance": prov, "anchor": anchor}
        prov, anchor = source.provenance(footer[0])
        return {"text": None, "labelExpr": None, "provenance": prov, "anchor": anchor}

    # -- rows --------------------------------------------------------------

    def _rows(self, content: tuple) -> list:
        rows = []
        for start, end in split_statements(self.source.masked, content[0] + 1, content[1]):
            rows.extend(self._classify(start, end, depth=0))
        return rows

    def _classify(self, start: int, end: int, depth: int) -> list:
        source = self.source
        masked = source.masked
        head = masked[start:end].lstrip()
        offset = start + (len(masked[start:end]) - len(head))
        if not head:
            return []
        if re.match(r"if\b", head):
            return self._classify_if(offset, end, depth)
        if re.match(r"(?:else|switch|for|while)\b", head):
            if re.match(r"switch\b", head):
                self.warnings.append(
                    f"unsupported control flow at {source.provenance(offset)[0]}: "
                    f"{source.statement_lines(offset, end)[:60]}")
            return []
        ident = re.match(r"([A-Za-z_]\w*)", head)
        if not ident:
            return []
        name = ident.group(1)
        if name in self.members and name != "body" and masked[offset:end].strip() == name:
            return self._classify_member(self.members[name], depth)
        call = call_parts(source, offset, end)
        if not call:
            return []
        callee = call["callee"]
        if callee == "ForEach":
            return self._classify_for_each(call, depth)
        if callee in self.members and self.members[callee]["kind"] == "func":
            return self._classify_helper(callee, call, offset, depth)
        return self._classify_element(callee, call, offset, end)

    def _classify_if(self, start: int, end: int, depth: int) -> list:
        source = self.source
        masked = source.masked
        brace = masked.find("{", start)
        if brace < 0 or brace > end:
            return []
        close = match_delim(masked, brace)
        if close < 0:
            return []
        condition = source.statement_lines(start + 2, brace)
        then_rows = []
        for s, e in split_statements(masked, brace + 1, close):
            then_rows.extend(self._classify(s, e, depth + 1))
        for row in then_rows:
            if row.get("condition") is None:
                row["condition"] = condition
        else_rows = []
        k = close + 1
        while k < end and masked[k] in " \t\r\n":
            k += 1
        if masked.startswith("else", k):
            rest = k + 4
            while rest < end and masked[rest] in " \t\r\n":
                rest += 1
            if masked.startswith("if", rest):
                else_rows.extend(self._classify_if(rest, end, depth))
            else:
                ebrace = masked.find("{", rest)
                if 0 <= ebrace < end:
                    eclose = match_delim(masked, ebrace)
                    for s, e in split_statements(masked, ebrace + 1, eclose):
                        else_rows.extend(self._classify(s, e, depth + 1))
        for row in else_rows:
            if row.get("condition") is None:
                row["condition"] = f"!({condition})"
        return then_rows + else_rows

    def _classify_for_each(self, call: dict, depth: int) -> list:
        source = self.source
        collection = source.statement_lines(call["args_start"], call["args_end"])
        rows = []
        if call["trailing"]:
            brace, close = call["trailing"]
            body_start = strip_closure_params(source.masked, brace + 1, close)
            for s, e in split_statements(source.masked, body_start, close):
                rows.extend(self._classify(s, e, depth + 1))
        if rows:
            for row in rows:
                row.setdefault("collection", collection)
            return rows
        return [row_of(source, call["args_start"], None, None, "dynamic",
                       label_expr=f"ForEach({collection})", collection=collection, extraction="manual")]

    def _classify_member(self, member: dict, depth: int) -> list:
        if depth > 3:
            return []
        rows = []
        for s, e in split_statements(self.source.masked, member["body_start"] + 1, member["body_end"]):
            rows.extend(self._classify(s, e, depth + 1))
        return rows

    def _classify_helper(self, callee: str, call: dict, start: int, depth: int) -> list:
        """A page-local view helper: resolve its shape, then its label."""
        source = self.source
        helper = self.members[callee]
        body = source.masked[helper["body_start"]: helper["body_end"]]
        is_container = (callee in CONTAINER_HINTS
                        or (helper["kind"] == "func" and re.search(r"_ \w+: some View", helper["params"])))
        if is_container and call["positional"]:
            return self._classify(call["positional"][0][0], call["positional"][0][1], depth + 1)
        statement_end = self._statement_end(start, call["end"] + 1)
        expr = source.statement_lines(start, statement_end)
        if "NavigationLink" in body:
            label, pos = first_label(source, *call["positional"][0]) if call["positional"] else (None, None)
            value_expr = source.statement_lines(*call["positional"][1]) if len(call["positional"]) > 1 else None
            dest = destination_of(source, call["trailing"]) or destination_of(source, (helper["body_start"], helper["body_end"]))
            self._add_action(action_of(source, pos if pos is not None else start, label, pos, "navigation",
                                       "tap", destination=dest, semantic=f"navigate:{dest}" if dest else None))
            return [row_of(source, pos if pos is not None else start, label, pos, "navigation",
                           value_expr=value_expr, clickable=True, destination=dest)]
        first_stmt = split_statements(source.masked, helper["body_start"] + 1, helper["body_end"])
        first_is_button = bool(first_stmt) and re.match(
            r"[ \t]*(Button|Menu)[ \t]*[({^]", source.masked[first_stmt[0][0]: first_stmt[0][1]]) is not None
        if first_is_button:
            inner = call_parts(source, first_stmt[0][0], first_stmt[0][1])
            label, pos, label_expr = self._button_label(inner, first_stmt[0][0], first_stmt[0][1]) \
                if inner else (None, None, None)
            self._add_action(action_of(source, pos if pos is not None else start, label, pos, "button", "tap",
                                       writes=writes(source, start, statement_end),
                                       label_expr=label_expr,
                                       extraction="syntax" if label else "manual"))
            return [row_of(source, pos if pos is not None else start, label, pos, "action", clickable=True,
                           label_expr=label_expr, extraction="syntax" if label else "manual")]
        if call["positional"]:
            first_value, first_pos = first_label(source, *call["positional"][0])
        else:
            first_value, first_pos = None, None
        if first_value is not None:
            value_expr = source.statement_lines(*call["positional"][1]) if len(call["positional"]) > 1 else None
            kind = "info" if value_expr is not None else "text"
            return [row_of(source, first_pos, first_value, first_pos, kind, value_expr=value_expr,
                           template=callee)]
        template_labels = []
        for raw, _ in source.literals(helper["body_start"], helper["body_end"]):
            value = template_of(unescape(raw)) if "\\(" in raw else unescape(raw)
            if value.strip() and value.strip() not in PUNCTUATION_ONLY and not SYMBOL_LITERAL_RE.match(value):
                template_labels.append(value)
        return [row_of(source, start, None, None, "dynamic", label_expr=expr,
                       templateLabels=template_labels[:6], extraction="manual")]

    def _label_from_view_closure(self, closure: tuple) -> tuple:
        """The visible label of a view closure: first `Text`/`Label`, else its expression.

        `HStack { Image(systemName: "plus"); Text("新建会话") }` labels the button
        `新建会话`; `HStack { Image(...); Text(displayWorkspaceTitle(w)) }` has an
        expression label and is reported as `labelExpr` with extraction manual.
        """
        source = self.source
        for s, e in split_statements(source.masked, closure[0] + 1, closure[1]):
            head = source.masked[s:e].lstrip()
            offset = s + (len(source.masked[s:e]) - len(head))
            if not head or head.startswith(("Image", "Spacer", "Divider", "Rectangle")):
                continue
            call = call_parts(source, offset, e)
            if not call:
                continue
            callee = call["callee"]
            if callee in ("Text", "Label", "LabeledContent"):
                label, pos = first_label(source, *call["positional"][0]) if call["positional"] else (None, None)
                if label is not None:
                    return label, pos, None
                expr = source.statement_lines(*call["positional"][0]) if call["positional"] else None
                return None, None, expr
            if callee in self.members and self.members[callee]["kind"] == "func" and call["positional"]:
                label, pos = first_label(source, *call["positional"][0])
                if label is not None:
                    return label, pos, None
            if callee in ("HStack", "VStack", "ZStack", "Group", "If"):
                pass
            if re.match(r"if\b", head):
                result = self._label_from_if(source, offset, e)
                if result[0] is not None or result[2] is not None:
                    return result
                continue
            if callee in ("HStack", "VStack", "ZStack", "Group"):
                inner = call["trailing"] or (call["named"].get("label") if "label" in call["named"] else None)
                if inner is None and call["named"]:
                    inner = next(iter(call["named"].values()))
                if inner:
                    result = self._label_from_view_closure(inner)
                    if result[0] is not None or result[2] is not None:
                        return result
                continue
            # A non-text view is the label (an icon only): no wording to extract.
            return None, None, None
        return None, None, None

    def _label_from_if(self, source: Source, start: int, end: int) -> tuple:
        """First label inside `if cond { … } else { … }` (both branches, in order)."""
        masked = source.masked
        brace = masked.find("{", start)
        if brace < 0 or brace > end:
            return None, None, None
        close = match_delim(masked, brace)
        if close < 0:
            return None, None, None
        result = self._label_from_view_closure((brace, close))
        if result[0] is not None or result[2] is not None:
            return result
        k = close + 1
        while k < end and masked[k] in " \t\r\n":
            k += 1
        if masked.startswith("else", k):
            ebrace = masked.find("{", k)
            if ebrace > 0:
                eclose = match_delim(masked, ebrace)
                return self._label_from_view_closure((ebrace, eclose))
        return None, None, None

    def _classify_element(self, callee: str, call: dict, start: int, end: int) -> list:
        source = self.source
        label, label_pos = first_label(source, *call["positional"][0]) if call["positional"] else (None, None)
        # Buttons/NavigationLinks/Menus take their label from a *view* closure, which
        # is resolved branch by branch (a literal deep inside is not the row's name).
        if label is None and callee not in ("Button", "NavigationLink", "Menu"):
            for name in ("title", "text", "label", "prompt"):
                if name in call["named"]:
                    label, label_pos = first_label(source, *call["named"][name])
                    if label:
                        break
        if callee in ("Text", "Label"):
            expr = None
            if label is None:
                span = call["positional"][0] if call["positional"] else (call["args_start"], call["args_end"])
                expr = source.statement_lines(*span)
            return [row_of(source, label_pos if label_pos is not None else start, label, label_pos, "text",
                           label_expr=expr)]
        if callee == "LabeledContent":
            value_expr = source.statement_lines(*call["named"]["value"]) if "value" in call["named"] else None
            rows = [row_of(source, label_pos if label_pos is not None else start, label, label_pos, "info",
                           value_expr=value_expr)]
            if call["trailing"]:
                for s, e in split_statements(source.masked, call["trailing"][0] + 1, call["trailing"][1]):
                    rows.extend(self._classify(s, e, depth=3))
            return rows
        if callee == "NavigationLink":
            dest = destination_of(source, call["trailing"])
            label_expr = None
            if label is None and "label" in call["named"]:
                # The label is a view: take its first real Text, and when that Text is
                # an expression keep it as `labelExpr` instead of the next literal
                # (`1 个会话` in WorkspaceFoldersPage's row is a trailing count, not a name).
                label, label_pos, label_expr = self._label_from_view_closure(call["named"]["label"])
            self._add_action(action_of(source, label_pos if label_pos is not None else start, label, label_pos,
                                       "navigation", "tap", destination=dest, label_expr=label_expr,
                                       semantic=f"navigate:{dest}" if dest else None,
                                       extraction="syntax" if label else "manual"))
            return [row_of(source, label_pos if label_pos is not None else start, label, label_pos, "navigation",
                           clickable=True, destination=dest, label_expr=label_expr,
                           extraction="syntax" if label else "manual")]
        if callee == "Button":
            self._last_alternatives = []
            row_label, pos, label_expr = self._button_label(call, start, end)
            alternatives = self._last_alternatives
            effect = source.statement_lines(*call["trailing"]) if call["trailing"] else None
            can_write = writes(source, start, end)
            self._add_action(action_of(source, pos if pos is not None else start, row_label, pos, "button", "tap",
                                       writes=can_write, semantic=effect, label_expr=label_expr,
                                       labelAlternatives=alternatives,
                                       extraction="syntax" if row_label else "manual"))
            return [row_of(source, pos if pos is not None else start, row_label, pos, "action",
                           clickable=True, writes=can_write, label_expr=label_expr,
                           extraction="syntax" if row_label else "manual")]
        if callee == "Menu":
            if label is None and "label" in call["named"]:
                label, label_pos, _expr = self._label_from_view_closure(call["named"]["label"])
            self._add_action(action_of(source, start, label, label_pos, "menu", "tap", writes=False,
                                       extraction="syntax" if label else "manual"))
            return [row_of(source, start, label, label_pos, "action", clickable=True,
                           extraction="syntax" if label else "manual")]
        if callee == "Toggle":
            binding = source.statement_lines(*call["named"]["isOn"]) if "isOn" in call["named"] else None
            self._add_action(action_of(source, label_pos if label_pos is not None else start, label, label_pos,
                                       "toggle", "tap", writes=True,
                                       semantic=f"binding:{binding}" if binding else None))
            return [row_of(source, label_pos if label_pos is not None else start, label, label_pos, "control",
                           clickable=True, writes=True)]
        if callee == "Picker":
            option_spans = [(call["args_start"], call["args_end"])]
            if call["trailing"]:
                option_spans.append((call["trailing"][0] + 1, call["trailing"][1]))
            options = [unescape(v) for a, b in option_spans for v, _ in source.literals(a, b)
                       if unescape(v).strip() and not SYMBOL_LITERAL_RE.match(unescape(v))]
            binding = source.statement_lines(*call["named"]["selection"]) if "selection" in call["named"] else None
            tail = source.text[end: end + 120]
            style = "segmented" if ".segmented" in tail else ("menu" if ".menu" in tail else "default")
            self._add_action(action_of(source, label_pos if label_pos is not None else start, label, label_pos,
                                       "picker", "tap", writes=True, items=options, style=style,
                                       semantic=f"binding:{binding}" if binding else None))
            return [row_of(source, label_pos if label_pos is not None else start, label, label_pos, "control",
                           clickable=True, writes=True, value=" | ".join(options) or None)]
        if callee.endswith(("TextField", "TextView", "SecureField", "TextEditor")):
            accessibility = re.search(r"\.accessibilityLabel\(\s*\"([^\"]+)\"", source.text[start:end + 200])
            field_label = accessibility.group(1) if accessibility else label
            return [row_of(source, label_pos if label_pos is not None else start, field_label, label_pos, "input",
                           clickable=True, writes=True)]
        if callee in ("ProgressView", "ContentUnavailableView"):
            return [row_of(source, label_pos if label_pos is not None else start, label, label_pos,
                           "loading" if callee == "ProgressView" else "empty",
                           extraction="syntax" if label else "manual")]
        if callee in ("EmptyView", "Spacer", "Divider", "Image"):
            return []
        if callee in ("HStack", "VStack", "ZStack", "LazyVStack", "LazyVGrid", "Grid", "Group", "ScrollView"):
            rows = []
            if call["trailing"]:
                for s, e in split_statements(source.masked, call["trailing"][0] + 1, call["trailing"][1]):
                    rows.extend(self._classify(s, e, depth=3))
            return rows
        if label is not None:
            return [row_of(source, label_pos, label, label_pos, "custom", template=callee)]
        return [row_of(source, start, None, None, "custom", label_expr=callee, extraction="manual",
                       template=callee)]

    def _button_label(self, call: dict, start: int, end: int) -> tuple:
        if call["positional"]:
            span = call["positional"][0]
            expr = self.source.text[span[0]:span[1]]
            if " ? " in expr and " : " in expr:
                # `Button(saving ? "添加中…" : "添加")`: both labels are visible; the
                # steady-state (last) one is the label, the transient one an alternative.
                literals = [unescape(raw) for raw, _ in self.source.literals(*span)
                            if unescape(raw).strip() and not SYMBOL_LITERAL_RE.match(unescape(raw))]
                if literals:
                    label, pos = first_label(self.source, *span)
                    for raw, p in self.source.literals(*span):
                        if unescape(raw) == literals[-1]:
                            pos = p
                            break
                    self._last_alternatives = literals[:-1]
                    return literals[-1], pos, None
            label, pos = first_label(self.source, *span)
            if label is not None:
                return label, pos, None
        closure = call["named"].get("label") or call["trailing"]
        if closure:
            return self._label_from_view_closure(closure)
        return None, None, None

    def _statement_end(self, start: int, end: int) -> int:
        for s, e in split_statements(self.source.masked, start, end + 1):
            if s <= start < e:
                return e
        return end

    def _add_action(self, action: dict) -> None:
        key = (action["label"], action["trigger"], action["provenance"])
        if key in self._action_keys:
            return
        self._action_keys.add(key)
        self.actions.append(action)

    # -- page-level chrome -------------------------------------------------

    def _scan_page_actions(self) -> None:
        source = self.source
        masked = source.masked
        start, end = self.body_start, self.body_end
        for m in re.finditer(r"\.searchable[ \t]*\(", masked[start:end]):
            pos = start + m.start()
            if not self._live(pos):
                continue
            close = match_delim(masked, pos + len(m.group(0)) - 1, "(", ")")
            label = None
            if close > 0:
                prompt = re.search(r"prompt\s*:\s*", masked[pos:close])
                if prompt:
                    label, _ = first_label(source, pos + prompt.end(), close)
                if label is None:
                    label, _ = first_label(source, pos, close)
            self._add_action(action_of(source, pos, label, None, "search", "search",
                                       extraction="syntax" if label else "manual"))
        for m in re.finditer(r"\.refreshable[ \t]*\{", masked[start:end]):
            if self._live(start + m.start()):
                self._add_action(action_of(source, start + m.start(), None, None, "gesture", "pull-to-refresh",
                                           writes=True, semantic="refresh", extraction="syntax"))
        for m in re.finditer(r"\.onTapGesture[ \t]*(\(|\{)", masked[start:end]):
            if self._live(start + m.start()):
                self._add_action(action_of(source, start + m.start(), None, None, "gesture", "tap",
                                           extraction="syntax"))
        for m in re.finditer(r"\bButton[ \t]*[({^]", masked[start:end]):
            pos = start + m.start()
            if not self._live(pos):
                continue
            stmt_end = self._statement_end(pos, end)
            call = call_parts(source, pos, stmt_end)
            if not call:
                continue
            label, label_pos, label_expr = self._button_label(call, pos, stmt_end)
            trigger = self._button_trigger(pos, start, end)
            effect = source.statement_lines(*call["trailing"]) if call["trailing"] else None
            self._add_action(action_of(source, label_pos if label_pos is not None else pos, label, label_pos,
                                       "button", trigger, writes=writes(source, pos, stmt_end),
                                       semantic=effect, label_expr=label_expr,
                                       extraction="syntax" if label else "manual"))
        # `ShareLink(item:subject:preview:) { Label("导出对话记录", …) }` is the
        # baseline's share affordance: the label is in the content closure, so the
        # gate can see it even though there is no Button.
        for m in re.finditer(r"\bShareLink[ \t]*\(", masked[start:end]):
            pos = start + m.start()
            if not self._live(pos):
                continue
            call = call_parts(source, pos, self._statement_end(pos, end))
            if not call:
                continue
            label = label_pos = None
            if call["trailing"]:
                label, label_pos = first_label(source, call["trailing"][0] + 1, call["trailing"][1])
            self._add_action(action_of(source, label_pos if label_pos is not None else pos, label, label_pos,
                                       "share", "tap", writes=False,
                                       extraction="syntax" if label else "manual"))
        for m in re.finditer(r"\bMenu[ \t]*\{", masked[start:end]):
            pos = start + m.start()
            if not self._live(pos):
                continue
            label = label_pos = None
            menu_call = call_parts(source, pos, self._statement_end(pos, self.body_end + 1))
            if menu_call and "label" in menu_call["named"]:
                label, label_pos, _expr = self._label_from_view_closure(menu_call["named"]["label"])
            if label is None:
                tail = source.text[pos: min(len(source.text), pos + 900)]
                acc = re.search(r"\.accessibilityLabel\(\s*\"([^\"]+)\"", tail)
                if acc:
                    label = acc.group(1)
                    label_pos = pos + acc.start(1)
            self._add_action(action_of(source, pos, label, label_pos, "menu", "tap", writes=False,
                                       extraction="syntax" if label else "manual"))
        seen_presentations = set()
        for m in re.finditer(r"\.(alert|confirmationDialog|sheet|navigationDestination)[ \t]*\(", masked[start:end]):
            pos = start + m.start()
            if not self._live(pos):
                continue
            kind = m.group(1)
            close = match_delim(masked, pos + len(m.group(0)) - 1, "(", ")")
            if close < 0:
                continue
            title, title_pos = first_label(source, pos, close)
            if title is not None:
                title, dynamic = normalise_label(title)
            braces, k = [], close + 1
            while k < end:
                while k < end and masked[k] in " \t\r\n":
                    k += 1
                if k < end and masked[k] == "{":
                    bc = match_delim(masked, k)
                    if bc < 0:
                        break
                    braces.append((k, bc))
                    k = bc + 1
                else:
                    break
            dest = None
            if kind in ("sheet", "navigationDestination") and braces:
                dest = destination_of(source, braces[0])
            bindings = sorted({
                *re.findall(r"\$\s*([A-Za-z_]\w*)", source.text[pos: close]),
                *re.findall(r"([A-Za-z_]\w*)\s*!=\s*nil", source.text[pos: close]),
                *re.findall(r"Binding\s*\(\s*get:\s*\{[^}]*?\b([A-Za-z_]\w*)", source.text[pos: close]),
            })
            # `$showActivity` and a custom `Binding(get: { debugSheet...})` both name a
            # state; only the declared state variable is a usable trigger key.
            bindings = [b for b in bindings if b not in ("self", "true", "false")]
            prov, anchor = source.provenance(title_pos if title_pos is not None else pos)
            key = (kind, title, dest, prov)
            if key in seen_presentations:
                continue
            seen_presentations.add(key)
            self.presentations.append({
                "id": f"{kind}-{source.line_of(pos)}",
                "kind": kind,
                "title": title,
                "destination": dest,
                "triggerBindings": bindings,
                "span": [source.line_of(pos), source.line_of(braces[-1][1]) if braces else source.line_of(pos)],
                "provenance": prov,
                "anchor": anchor,
            })

    def _button_trigger(self, pos: int, start: int, end: int) -> str:
        masked = self.source.masked
        for pattern, name in BUTTON_TRIGGERS:
            for c in re.finditer(pattern, masked[start:end]):
                brace = masked.find("{", start + c.start())
                if brace < 0:
                    continue
                close = match_delim(masked, brace)
                if brace < pos < close:
                    return name
        return "tap"

    # -- actions inside a presentation -------------------------------------

    def _inline_presented_actions(self) -> None:
        """A sheet/alert opened by this page renders actions the contract must declare.

        The baseline often puts the sheet's content in a sibling `private struct`
        (`DailyBriefSourceEditor`), so those buttons would otherwise be invisible to the
        page's contract while the Android page implements them inline. Each inlined
        action keeps its own `File.swift:line` and gains `presentedBy`.
        """
        # Only private view structs are inlined: a *public* presented page
        # (SettingsPage, NativeConfigurationPage) has its own contract and is compared
        # there, so copying its buttons here would count them twice.
        private_views = {st["name"] for st in view_structs(self.source) if st["private"]}
        for presentation in self.presentations:
            destination = presentation.get("destination")
            if not destination or destination == self.name or destination not in private_views:
                continue
            try:
                sub = PageExtractor(self.source, destination, depth=self.depth + 1)
                sub_page = sub.run([])
            except ExtractError:
                continue
            for action in sub_page["actions"]:
                inlined = dict(action)
                inlined["presentedBy"] = presentation["id"]
                self._add_action(inlined)

    # -- non-Section groups -------------------------------------------------

    def _section_model(self) -> str:
        if not self.has_body:
            return "representable"
        if self.section_total:
            return "section"
        if any(section.get("kind") == "region" for section in self.sections):
            return "regions"
        if self.name in SINGLE_REGION_PAGES:
            return "single-region"
        return "unmodeled"

    def _scan_regions(self) -> None:
        """The baseline's non-Section grouping: `PageSection`/`GroupBox`, or a bold header Text.

        Five pages (Background/Export/Memory/Probes/TaskScreen) group with the shared
        `PageSection("Title") { ... }` card. A page with no recognisable group gets one
        `implicit` region marked manual, so the checker stops skipping the whole page.
        """
        source = self.source
        masked = source.masked
        seen = []
        if True:  # one region idiom table; kept flat so a second idiom is a one-line change
            for m in re.finditer(r"\b(PageSection|GroupBox)[ \t]*[({]", masked[self.body_start:self.body_end]):
                pos = self.body_start + m.start()
                if not self._live(pos):
                    continue
                call = call_parts(source, pos, self._statement_end(pos, self.body_end + 1))
                if not call:
                    continue
                label, label_pos = first_label(source, *call["positional"][0]) if call["positional"] else (None, None)
                if label is None and "label" in call["named"]:
                    label, label_pos = first_label(source, *call["named"]["label"])
                title_template = None
                dynamic_title = False
                if label is not None and "\\(" in label:
                    title_template, dynamic_title = template_of(label), True
                    label = human_title(label)
                content = call["trailing"]
                rows = []
                if content:
                    for s, e in split_statements(masked, content[0] + 1, content[1]):
                        rows.extend(self._classify(s, e, depth=0))
                condition = innermost_condition(self.if_scopes, pos)
                prov, anchor = source.provenance(label_pos if label_pos is not None else pos)
                region_rows = rows
                region = {
                    "id": slug(label) if label else f"region-{source.line_of(pos)}",
                    "kind": "region",
                    "title": label,
                    "titleTemplate": title_template,
                    "dynamicTitle": dynamic_title,
                    "titleSource": "literal" if label else "absent",
                    "condition": condition,
                    "collection": enclosing_for_each(self.for_each_scopes, pos),
                    "rows": rows,
                    "provenance": prov,
                    "anchor": anchor,
                    "extraction": "syntax" if label else "manual",
                    "template": call["callee"],
                }
                if region["title"] is None and region["titleTemplate"] is None:
                    region["criterion"] = self._untitled_criterion(region_rows, prov)
                seen.append(region)
        if not seen:
            seen = self._header_text_regions()
        self.region_total = len(seen)
        if not seen:
            prov, anchor = source.provenance(self.body_start)
            seen = [{
                "id": f"region-{source.line_of(self.body_start)}",
                "kind": "implicit",
                "title": None,
                "titleTemplate": None,
                "titleSource": "absent",
                "condition": None,
                "collection": None,
                "rows": self._implicit_region_rows(),
                "provenance": prov,
                "anchor": anchor,
                "extraction": "manual",
                "criterion": {"kind": "implicit"},
                "note": "no Section/PageSection/GroupBox/header Text found: the whole body is "
                        "one region, so a human must say what the group is (or the page has none)",
            }]
        self.sections = seen

    def _single_region(self) -> dict:
        """The whole page is one region (manual judgement, no invented header)."""
        prov, anchor = self.source.provenance(self.body_start)
        return {
            "id": f"single-region-{self.source.line_of(self.body_start)}",
            "kind": "single-region",
            "title": None,
            "titleTemplate": None,
            "dynamicTitle": False,
            "titleSource": "absent",
            "condition": None,
            "collection": None,
            "rows": self._implicit_region_rows(),
            "provenance": prov,
            "anchor": anchor,
            "criterion": {"kind": "single-region"},
            "extraction": "manual",
            "note": SINGLE_REGION_PAGES[self.name],
        }

    def _implicit_region_rows(self) -> list:
        """Rows of a page whose body is one container (List/Form/ScrollView/VStack).

        An unmodeled page still has rows: dropping them would make its contract an
        empty shell, so the main container's direct children are classified here.
        """
        source = self.source
        masked = source.masked
        for m in re.finditer(r"\b(List|Form|ScrollView|VStack|LazyVStack)[ \t]*[({]",
                             masked[self.body_start:self.body_end]):
            pos = self.body_start + m.start()
            if not self._live(pos):
                continue
            call = call_parts(source, pos, self._statement_end(pos, self.body_end + 1))
            if not call or not call["trailing"]:
                continue
            rows = []
            for s, e in split_statements(masked, call["trailing"][0] + 1, call["trailing"][1]):
                rows.extend(self._classify(s, e, depth=0))
            if rows:
                return rows
        return []

    def _section_titles_in(self, start: int, end: int) -> list:
        """Literal titles of the Sections inside a subpage (printed, never compared here)."""
        out = []
        masked = self.source.masked
        for match in SECTION_RE.finditer(masked, start, end):
            title = None
            if match.group(1) == "(":
                close_paren = match_delim(masked, match.end() - 1, "(", ")")
                if close_paren > 0:
                    title, _pos = first_label(self.source, match.end(), close_paren)
                    content_end = match_delim(masked, masked.find("{", close_paren))
            else:
                content_end = match_delim(masked, match.end() - 1)
            if title is None and content_end and content_end > 0:
                header = self._named_closures_after(content_end).get("header")
                if header:
                    title, _pos = self._first_labeled_text(header)
            if title:
                out.append({"title": title,
                            "provenance": f"{self.source.path.name}:{self.source.line_of(match.start())}"})
        return out

    def _untitled_criterion(self, rows: list, provenance: str) -> dict:
        """What identifies an untitled group: its first labelled (preferably clickable) row.

        Position-based comparison is not used: reordering two untitled groups would then
        read as a difference. A first-row criterion is stable and machine-checkable, and
        the checker reports the group as unresolved instead of silently skipping it.
        """
        clickable = next((r for r in rows if r.get("clickable") and r.get("label")), None)
        labelled = next((r for r in rows if r.get("label")), None)
        expr = next((r for r in rows if r.get("labelExpr")), None)
        if clickable:
            return {"kind": "first-clickable-row", "label": clickable["label"],
                    "provenance": clickable["provenance"]}
        if labelled:
            return {"kind": "first-row", "label": labelled["label"],
                    "provenance": labelled["provenance"]}
        if expr:
            return {"kind": "first-row-expression", "labelExpr": expr["labelExpr"],
                    "provenance": expr["provenance"]}
        return {"kind": "empty", "provenance": provenance}

    def _header_text_regions(self) -> list:
        """A bold/small-caps header `Text` inside a VStack is a region title."""
        source = self.source
        masked = source.masked
        out = []
        for m in re.finditer(r"\bText[ \t]*\(", masked[self.body_start:self.body_end]):
            pos = self.body_start + m.start()
            if not self._live(pos):
                continue
            open_paren = masked.find("(", pos)
            close = match_delim(masked, open_paren, "(", ")")
            if close < 0:
                continue
            tail = source.text[close: close + 240]
            if not (HEADER_FONT_RE.search(tail) or UPPERCASE_RE.search(tail)):
                continue
            label, label_pos = first_label(source, open_paren + 1, close)
            if label is None:
                continue
            # An empty-state title and a button caption look bold too: they are not
            # group headers. Reject them, and require the Text to open its container.
            prefix = source.text[max(0, pos - 400): pos]
            if re.search(r"\bButton\s*(\{|\()|\bNavigationLink\b", prefix.split("\n")[-4:] and prefix[-400:]):
                if prefix.rfind("Button") > prefix.rfind("}"):
                    continue
            container = masked.rfind("{", self.body_start, pos)
            if container > 0 and masked[container - 60: container].strip().endswith(("if", "else")):
                continue
            if "isEmpty" in masked[max(0, pos - 600): pos][-600:]:
                continue
            prov, anchor = source.provenance(label_pos)
            out.append({
                "id": slug(label), "kind": "region", "title": label, "titleTemplate": None,
                "titleSource": "header-text", "condition": innermost_condition(self.if_scopes, pos),
                "collection": None, "rows": [], "provenance": prov, "anchor": anchor,
                "extraction": "syntax",
                "note": "header Text only; its rows are the following siblings in the same stack",
            })
        return out

    # -- action -> presentation link ---------------------------------------

    def _assigned_live(self, binding: str) -> bool:
        """True when `binding = ...` happens outside its `@State`/`var` declaration."""
        masked = self.source.masked
        for m in re.finditer(rf"\b{re.escape(binding)}\s*=(?!=)", masked[self.body_start:self.body_end]):
            pos = self.body_start + m.start()
            if not self._live(pos):
                continue
            prefix = masked[max(self.body_start, pos - 80): pos]
            if re.search(r"\b(var|let)\s+$", prefix) or "@State" in prefix[-40:]:
                continue
            return True
        return False

    def _link_presentations(self) -> None:
        """Link each sheet/alert to the action that opens it, or mark it as dead UI.

        Two passes: an action/row whose captured effect assigns the binding gets
        `presents: <presentation id>`; a presentation whose binding is never assigned
        anywhere live is `triggered: false` (the baseline's own dead sheet, e.g.
        SessionsPage's `showSchedules`).
        """
        items = list(self.actions) + [row for section in self.sections for row in section["rows"]]
        for presentation in self.presentations:
            bindings = presentation.get("triggerBindings", [])
            linked = False
            for binding in bindings:
                for item in items:
                    if re.search(rf"\b{re.escape(binding)}\s*=(?!=)", item.get("semantic") or ""):
                        item.setdefault("presents", presentation["id"])
                        linked = True
                        break
                if linked:
                    break
            if not linked and any(self._assigned_live(binding) for binding in bindings):
                linked = True  # opened by a row tap / gesture, not by a labelled action
            presentation["triggered"] = linked
            if not linked:
                start_line, end_line = presentation.get("span", [0, 0])
                for item in items:
                    line = int(str(item.get("provenance", "x:0")).rsplit(":", 1)[-1] or 0)
                    if start_line and start_line <= line <= end_line:
                        item.setdefault("deadPresentation", presentation["id"])
            if not linked:
                bindings = presentation.get("triggerBindings") or []
                presentation["deadUi"] = True
                presentation["deadUiEvidence"] = (
                    "the state binding "
                    + (", ".join(bindings) if bindings else "(none extracted)")
                    + " is never assigned outside its declaration, so nothing opens this "
                    + presentation["kind"])


    # -- states ------------------------------------------------------------

    def _states(self) -> dict:
        source = self.source
        sites = {kind: [] for kind in STATE_KINDS if kind != "data"}
        seen = set()
        for raw, pos in source.literals(self.body_start, self.body_end):
            if not self._live(pos):
                continue
            value = unescape(raw)
            if not value.strip() or len(value) > 60:
                continue
            for kind, rx in STATE_MARKERS.items():
                if rx.search(value):
                    prov, anchor = source.provenance(pos)
                    key = (kind, value, prov)
                    if key not in seen:
                        seen.add(key)
                        sites[kind].append({
                            "renders": value,
                            "when": innermost_condition(self.if_scopes, pos),
                            "provenance": prov,
                            "anchor": anchor,
                        })
                    break
        for m in re.finditer(r"\b(ContentUnavailableView|ProgressView)[ \t]*\(",
                             source.masked[self.body_start:self.body_end]):
            pos = self.body_start + m.start()
            if not self._live(pos):
                continue
            prov, anchor = source.provenance(pos)
            kind = "loading" if m.group(1) == "ProgressView" else "empty"
            sites[kind].append({"renders": m.group(1), "when": innermost_condition(self.if_scopes, pos),
                                "provenance": prov, "anchor": anchor})
        prov, anchor = source.provenance(self.body_start)
        sites["data"] = [{
            "renders": " | ".join(
                s["title"] or s["titleTemplate"] or f"untitled section at {s['provenance'].split(':')[1]}"
                for s in self.sections
            ) or "page body",
            "when": None,
            "provenance": prov,
            "anchor": anchor,
            "note": "structural default: the sections above, when no condition overrides them",
        }]
        return {
            "advisory": True,
            "note": "advisory only: marker-based; row placeholders (未配置/未设置/—) are "
                    "not page states, so the checker never compares this object",
            "sites": {kind: sites.get(kind, []) for kind in STATE_KINDS},
            "absent": [kind for kind in STATE_KINDS if not sites.get(kind)],
            "coverage": {kind: len(sites.get(kind, [])) for kind in STATE_KINDS},
        }

    # -- metadata ----------------------------------------------------------

    def _page_title(self):
        source = self.source
        if not self.has_body:
            return None
        for m in re.finditer(r"\.navigationTitle[ \t]*\(", source.masked[self.body_start:self.body_end]):
            if not self._live(self.body_start + m.start()):
                continue
            open_paren = self.body_start + m.end() - 1
            close = match_delim(source.masked, open_paren, "(", ")")
            if close < 0:
                continue
            label, label_pos = first_label(source, open_paren + 1, close)
            if label:
                prov, anchor = source.provenance(label_pos)
                return {"text": label, "provenance": prov, "anchor": anchor}
        return None

    def _unreachable(self) -> list:
        out = []
        for name, member in self.members.items():
            if name == "body" or name in self.reachable or not member["is_view"]:
                continue
            sections = len(SECTION_RE.findall(
                self.source.masked[member["body_start"]: member["body_end"]]))
            if sections:
                out.append({
                    "member": name,
                    "line": member["line"],
                    "endLine": self.source.line_of(member["body_end"]),
                    "sections": sections,
                    "note": "view member with Section(s) that body does not reference: dead in the page",
                })
        return out


# ---------------------------------------------------------------------------
# Android mapping: the contract must name the file that has to obey it.
# ---------------------------------------------------------------------------


def android_mapping(root: Path, page_name: str) -> dict:
    page_dir = root / ANDROID_PAGE_REL
    if not page_dir.is_dir():
        return {"screen": page_name, "file": None, "match": "no-android-sources"}
    files = sorted(page_dir.glob("*.kt"))
    screen_name = ANDROID_ALIASES.get(page_name, page_name)
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        if re.search(rf"^public fun {re.escape(screen_name)}\s*\(", text, re.M):
            return {"screen": screen_name, "file": path.relative_to(root).as_posix(),
                    "match": "composable" if screen_name == page_name else "alias"}
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        if re.search(rf"\b{re.escape(page_name)}\b", text):
            # The Android composable has a different name and the source only says
            # so in prose, so the screen name is not asserted (`screen: null`):
            # asserting a guessed name would fail the gate for the wrong reason.
            return {"screen": None, "file": path.relative_to(root).as_posix(),
                    "match": "kdoc-mention"}
    return {"screen": page_name, "file": None, "match": "missing"}


# ---------------------------------------------------------------------------
# Driver.
# ---------------------------------------------------------------------------


def page_id(name: str) -> str:
    stem = name[:-4] if name.endswith("Page") else name
    for prefix, short in (("PDSH", "pdsh"), ("MCP", "mcp")):
        if stem.startswith(prefix):
            stem = short + stem[len(prefix):]
    stem = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "-", stem)
    stem = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", "-", stem)
    return stem.lower().strip("-")


def primary_page(source: Source, file_stem: str) -> str:
    """The page a `*Page.swift` file is named after, or its first public page."""
    structs = page_structs(source)
    for st in structs:
        if st["name"] == file_stem:
            return file_stem
    public = [st for st in structs if not st["private"]]
    if not public:
        raise ExtractError(f"{source.path.name}: no public *Page struct")
    return public[0]["name"]


def extract_one(root: Path, path: Path) -> dict:
    source = Source(path, root)
    stem = PAGE_FILE_RE.match(path.name).group(1)
    name = primary_page(source, stem)
    page = PageExtractor(source, name).run(page_structs(source))
    page["android"] = android_mapping(root, name)
    return page


def dumps(page: dict) -> str:
    return json.dumps(page, ensure_ascii=False, indent=2) + "\n"


def discover_pages(root: Path) -> list:
    """(Source, page_name) for every page the contract tree covers.

    Every `*Page` struct in the probe app is a candidate now, not just the ones in a
    `*Page.swift` file: `WorkspaceFoldersPage`/`EgressAllowListPage`/`SettingsAboutPage`
    live in `NativeShell.swift`, `RuntimeDetailsPage` in `ChatPage.swift`. A `private`
    page stays embedded (README §1) unless the Android tree has a screen for it
    (MCPEditorPage does). `SessionHistoryPage`/`GoalDetailPage` exist only on Android
    and are listed in `_android-only.json`.
    """
    probe = root / PROBE_REL
    pages = []
    for path in sorted(probe.glob("*.swift")):
        source = Source(path, root)
        for struct in page_structs(source):
            if struct["private"]:
                # An embedded subpage gets a contract only when it is its own Android
                # screen file (MCPEditorPage.kt), not a composable inside a parent file.
                mapping = android_mapping(root, struct["name"])
                if mapping["match"] not in ("composable", "alias"):
                    continue
                if mapping["file"] and Path(mapping["file"]).stem != struct["name"]:
                    continue
            pages.append((path, struct["name"]))
    return pages


SPEC_REQUIRED_REL = PAGES_REL / "_spec-required.json"
ANDROID_ONLY_ITEMS_REL = PAGES_REL / "_android-only-items.json"


def load_android_only_items(root: Path) -> dict:
    """Android-must-have items with no iOS counterpart, keyed by page id."""
    path = root / ANDROID_ONLY_ITEMS_REL
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    out = {}
    for entry in data.get("entries", []):
        out.setdefault(entry["page"], []).append(entry)
    return out


def merge_android_only_items(page: dict, entries: list) -> None:
    """Add `androidOnly` actions/sections with their three-question reason."""
    for entry in entries:
        meta = {
            "reason": entry["reason"],
            "owner": entry["owner"],
            "reviewBy": entry["reviewBy"],
        }
        if entry["kind"] == "action":
            page["actions"].append({
                "id": slug(entry["label"]), "label": entry["label"], "labelExpr": None,
                "kind": entry.get("kind", "action"), "trigger": "tap", "semantic": None,
                "writes": entry.get("writes", False), "destination": entry.get("destination"),
                "condition": None, "extraction": "manual", "androidOnly": meta,
            })
        else:
            page["sections"].append({
                "id": slug(entry["title"]), "kind": "section", "title": entry["title"],
                "titleTemplate": None, "dynamicTitle": False, "titleSource": "literal",
                "condition": None, "collection": None, "rows": [], "extraction": "manual",
                "androidOnly": meta,
            })


def load_spec_required(root: Path) -> dict:
    """§1-required items the baseline never renders, keyed by page id."""
    path = root / SPEC_REQUIRED_REL
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    out = {}
    for entry in data.get("entries", []):
        out.setdefault(entry["page"], []).append(entry)
    return out


def merge_spec_required(page: dict, entries: list) -> None:
    """Append §1-required actions with both provenances (baseline line + README line)."""
    for entry in entries:
        destination = entry.get("destination")
        page["actions"].append({
            "id": slug(entry["label"]),
            "label": entry["label"],
            "labelExpr": None,
            "kind": entry.get("kind") or ("navigation" if destination else "button"),
            "trigger": "tap",
            "semantic": f"navigate:{destination}" if destination else None,
            "writes": entry.get("writes", False),
            "destination": destination,
            "condition": None,
            "provenance": entry["provenance"],
            "anchor": entry["anchor"],
            "extraction": "manual",
            "specRequired": bool(entry.get("specRef")),
            "specRef": entry.get("specRef"),
            "baselineReachable": entry.get("baselineReachable", False),
            "note": entry["reason"],
        })


def extract_page(root: Path, path: Path, name: str) -> dict:
    source = Source(path, root)
    page = PageExtractor(source, name).run(page_structs(source))
    page["android"] = android_mapping(root, name)
    merge_spec_required(page, load_spec_required(root).get(page["pageId"], []))
    merge_android_only_items(page, load_android_only_items(root).get(page["pageId"], []))
    return page


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(description="Extract the iOS page contracts (spec/ui/v1/pages).")
    parser.add_argument("--root", default=".", help="repository root (default: .)")
    parser.add_argument("--page", default=None, help="only this page (e.g. SessionsPage)")
    parser.add_argument("--check", action="store_true", help="fail when a contract file is stale")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    probe = root / PROBE_REL
    if not probe.is_dir():
        print(f"extract_ios_pages: {PROBE_REL} not present", file=sys.stderr)
        return 2
    out_dir = root / PAGES_REL
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        pages = discover_pages(root)
    except ExtractError as exc:
        print(f"extract_ios_pages: {exc}", file=sys.stderr)
        return 2
    if args.page:
        pages = [(path, name) for path, name in pages if name == args.page]
        if not pages:
            print(f"extract_ios_pages: no page named {args.page}", file=sys.stderr)
            return 2

    stale, totals, rows_out = [], [0, 0, 0], []
    for path, name in pages:
        try:
            page = extract_page(root, path, name)
        except ExtractError as exc:
            print(f"extract_ios_pages: {exc}", file=sys.stderr)
            return 2
        target = out_dir / f"{page['pageId']}.json"
        text = dumps(page)
        if args.check:
            old = target.read_text(encoding="utf-8") if target.exists() else ""
            if old != text:
                stale.append(page["pageId"])
        else:
            target.write_text(text, encoding="utf-8")
        sections = len(page["sections"])
        rows = sum(len(s["rows"]) for s in page["sections"])
        actions = len(page["actions"])
        totals[0] += sections
        totals[1] += rows
        totals[2] += actions
        cover = f"{page['extraction']['sectionsExtracted']}/{page['extraction']['sectionKeywordsInPage']}"
        rows_out.append((page["pageId"], page["page"], sections, rows, actions, cover,
                         page["android"]["match"]))
    width = max(len(r[0]) for r in rows_out)
    print(f"{'page-id'.ljust(width)}  {'page struct'.ljust(28)} sec rows act {'coverage':>12}  android")
    for pid, name, sections, rows, actions, cover, match in rows_out:
        print(f"{pid.ljust(width)}  {name.ljust(28)} {sections:3d} {rows:4d} {actions:3d} {cover:>12}  {match}")
    print(f"{len(rows_out)} pages, {totals[0]} sections, {totals[1]} rows, {totals[2]} actions")
    if args.check:
        if stale:
            print("stale contracts (rerun extract_ios_pages.py): " + ", ".join(stale), file=sys.stderr)
            return 1
        print("contracts up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
